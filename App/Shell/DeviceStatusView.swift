import CrowCore
import SwiftUI
#if os(macOS)
import Security
#endif

struct AIUsageWindow: Decodable, Identifiable {
    var id: String { label }
    let label: String
    let used: Double
    let resets: Double?
}
struct AIProviderUsage: Decodable, Identifiable {
    var id: AgentProvider { provider }
    let provider: AgentProvider
    let windows: [AIUsageWindow]
    let error: String?
}
private struct AIUsageResponse: Decodable { let providers: [AIProviderUsage] }

struct AIUsageSource {
    let hostID: HostID?
    let state: WorkspaceState?
    let label: String
    var key: String { hostID?.rawValue.uuidString ?? "local" }
}

extension AppModel {
    var aiUsageSource: AIUsageSource {
        let agent = current.selectedAgent
        let hostID = agent?.reverseHostID ?? current.snapshot.workspace.hostID
        let state: WorkspaceState?
        if let reverseHostID = agent?.reverseHostID {
            state = states.first { $0.snapshot.workspace.hostID == reverseHostID && $0.remote?.isConnected == true }
                ?? states.first { $0.snapshot.workspace.hostID == reverseHostID }
        } else { state = current }
        let label = hostID.map { id in hosts.first { $0.id == id }?.userAtHost ?? "SSH host" } ?? "Local"
        return AIUsageSource(hostID: hostID, state: state, label: label)
    }
}

@MainActor @Observable final class DeviceStatusState {
    static let shared = DeviceStatusState()
    var memory: UInt64 = 0
    var cpu: Double = 0
    var usage: [AIProviderUsage] = []
    var usageDate: Date?
    var usageLoading = false
    @ObservationIgnored private var usageHost: String?
    @ObservationIgnored private var usageGeneration = UUID()
    @ObservationIgnored private var claudeToken: String?
    #if os(macOS)
    @ObservationIgnored private var previousCPU: (Date, Double)?
    func sampleResources() {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS { memory = info.resident_size }
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            let now = Date()
            if let previousCPU { cpu = max(0, (seconds - previousCPU.1) / max(0.1, now.timeIntervalSince(previousCPU.0)) * 100) }
            previousCPU = (now, seconds)
        }
    }
    #endif

    func refreshUsage(from source: AIUsageSource, providers enabled: [AgentProvider] = AgentProvider.allCases, force: Bool = false, allowKeychainPrompt: Bool = false) async {
        let host = source.key + ":" + enabled.map(\.rawValue).joined(separator: ",")
        if usageHost == host, !force, let usageDate, Date().timeIntervalSince(usageDate) < 300 { return }
        let generation = UUID(); usageGeneration = generation
        if usageHost != host { usage = []; usageDate = nil }
        usageHost = host; usageLoading = true
        defer { if usageGeneration == generation { usageLoading = false } }
        guard !enabled.isEmpty else { usage = []; usageDate = nil; return }
        do {
            guard let state = source.state else { throw CommandError("Connect the agent's SSH host to read its account usage.") }
            let data = try await AgentHistoryService.run(["workspace": state.snapshot.rootPath, "action": "usage", "providers": enabled.map(\.rawValue)], in: state)
            var providers = try JSONDecoder().decode(AIUsageResponse.self, from: data).providers
            #if os(macOS)
            if enabled.contains(.claude), !state.snapshot.workspace.isRemote, providers.first(where: { $0.provider == .claude })?.windows.isEmpty != false,
               let claude = await claudeKeychainUsage(allowPrompt: allowKeychainPrompt) {
                providers.removeAll { $0.provider == .claude }; providers.insert(claude, at: 0)
            }
            #endif
            try Task.checkCancellation()
            guard usageGeneration == generation else { return }
            usage = providers; usageDate = Date()
        } catch {
            guard !Task.isCancelled, usageGeneration == generation else { return }
            usage = enabled.map { AIProviderUsage(provider: $0, windows: [], error: error.localizedDescription) }
            usageDate = Date()
        }
    }

    #if os(macOS)
    private func claudeKeychainUsage(allowPrompt: Bool) async -> AIProviderUsage? {
        // Legacy Keychain items can ignore kSecUseAuthenticationUIFail. Query only
        // after an explicit Refresh, off the main thread, and retain the token in memory.
        if claudeToken == nil && !allowPrompt {
            return .init(provider: .claude, windows: [], error: "Click Refresh to allow access to Claude Code's Keychain login.")
        }
        if allowPrompt {
            claudeToken = await Task.detached(priority: .utility) {
                var item: CFTypeRef?
                let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "Claude Code-credentials",
                    kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &item)
                guard status == errSecSuccess, let data = item as? Data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil as String? }
                return oauth["accessToken"] as? String
            }.value
        }
        guard let token = claudeToken else {
            return .init(provider: .claude, windows: [], error: "Claude Code login is unavailable or Keychain access was declined.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 5
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Crow/1.0", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: UsageRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .init(provider: .claude, windows: [], error: "Could not read account limits. Check Claude Code login or try again later.")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let windows = [("five_hour", "5 hours"), ("seven_day", "Weekly")].compactMap { key, label -> AIUsageWindow? in
                guard let value = json[key] as? [String: Any], let used = value["utilization"] as? Double else { return nil }
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let reset = (value["resets_at"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                return .init(label: label, used: used, resets: reset?.timeIntervalSince1970)
            }
            return .init(provider: .claude, windows: windows, error: windows.isEmpty ? "This account did not report usage limits." : nil)
        } catch { return .init(provider: .claude, windows: [], error: "Could not contact Claude for usage.") }
    }
    #endif
}

#if os(macOS)
private final class UsageRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif

struct DeviceStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var status = DeviceStatusState.shared
    @State private var showingUsage = false
    private var source: AIUsageSource { model.aiUsageSource }

    var body: some View {
        HStack(spacing: 12) {
            #if os(macOS)
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                Text(ByteCountFormatter.string(fromByteCount: Int64(status.memory), countStyle: .memory))
                Text(String(format: "%.0f%%", status.cpu))
            }.monospacedDigit().foregroundStyle(CrowTheme.textDim).help("Crow process · memory and CPU (100% = one core).")
            #endif
            if !model.settings.enabledAgentProviders.isEmpty {
                Button { showingUsage.toggle() } label: {
                    HStack(spacing: 9) {
                        ForEach(model.settings.enabledAgentProviders) { provider in
                            HStack(spacing: 4) {
                                AgentProviderIcon(provider: provider, size: 12)
                                if let value = status.usage.first(where: { $0.provider == provider })?.windows.first {
                                    Text(String(format: "%.0f%%", value.used)).monospacedDigit()
                                } else { Text(status.usageLoading ? "…" : "—").foregroundStyle(CrowTheme.textDim) }
                            }
                        }
                    }
                }.help("AI account usage limits").accessibilityLabel("AI account usage").accessibilityIdentifier("crow.status.ai-usage")
                    .popover(isPresented: $showingUsage) { usageDetails }
            }
        }.buttonStyle(.plain).font(.system(size: 11)).fixedSize().windowDragExcluded()
            .task {
                #if os(macOS)
                while !Task.isCancelled {
                    status.sampleResources()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
                #endif
            }
            .task(id: source.key + "\(source.state?.remote?.isConnected == true)-\(model.settings.enabledAgentProviders)") {
                let source = source
                // Switching servers or reconnecting must not reuse a failed/stale result.
                await status.refreshUsage(from: source, providers: model.settings.enabledAgentProviders, force: true)
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    await status.refreshUsage(from: source, providers: model.settings.enabledAgentProviders)
                }
            }
    }
    private var usageDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI Account Usage").font(.headline)
                Spacer()
                Button { Task { await status.refreshUsage(from: source, providers: model.settings.enabledAgentProviders, force: true, allowKeychainPrompt: true) } } label: { Image(systemName: "arrow.clockwise") }.disabled(status.usageLoading)
            }
            Text(source.hostID != nil ? "Accounts on \(source.label)" : "Accounts signed in through the local CLIs")
                .font(.caption).foregroundStyle(CrowTheme.textDim)
            ForEach(model.settings.enabledAgentProviders) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    Label { Text(provider.title).font(.subheadline.bold()) } icon: { AgentProviderIcon(provider: provider, size: 14) }
                    if let value = status.usage.first(where: { $0.provider == provider }) {
                        ForEach(value.windows) { window in
                            HStack { Text(window.label); Spacer(); Text(String(format: "%.0f%% used", window.used)).monospacedDigit() }.font(.caption)
                            ProgressView(value: min(100, max(0, window.used)), total: 100)
                            if let reset = window.resets { Text("Resets \(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(CrowTheme.textDim) }
                        }
                        if let error = value.error { Text(error).font(.caption).foregroundStyle(CrowTheme.textDim).textSelection(.enabled) }
                    } else { Text(status.usageLoading ? "Loading…" : "Usage unavailable").font(.caption).foregroundStyle(CrowTheme.textDim) }
                }
            }
            if let date = status.usageDate { Text("Updated \(date.formatted(date: .omitted, time: .shortened)) · refreshes every 5 minutes").font(.caption2).foregroundStyle(CrowTheme.textDim) }
        }.padding(20).frame(width: 340)
    }
}
