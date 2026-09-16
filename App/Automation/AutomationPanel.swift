import CrowCore
import SwiftUI

private struct AutomationEdit: Identifiable {
    let id = UUID()
    let state: WorkspaceState
    let host: String
    let snapshot: AutomationSnapshot
    var cron: CronJob?
    var launch: LaunchJob?
    var isNew = false
}

struct AutomationPanel: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot: AutomationSnapshot?
    @State private var loading = false
    @State private var error: String?
    @State private var revision = 0
    @State private var search = ""
    @State private var showSystem = false
    @State private var editing: AutomationEdit?

    private var host: String {
        model.hosts.first { $0.id == model.current.snapshot.workspace.hostID }?.userAtHost ?? "Local"
    }
    private var loadID: String { "\(model.selectedWorkspaceID)-\(model.current.remote?.isConnected == true)-\(revision)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automations").font(.system(size: 13, weight: .semibold))
                    Text(host).font(.system(size: 11)).foregroundStyle(CrowTheme.textDim).lineLimit(1)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { revision += 1 } label: { PanelActionIcon(symbol: "arrow.clockwise") }
                    .help("Refresh automations").disabled(loading)
                    .windowDragExcluded().accessibilityIdentifier("crow.automation.refresh")
            }.padding(12)
            TextField("Search automations", text: $search).textFieldStyle(.roundedBorder).windowDragExcluded().padding(.horizontal, 12).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let error { Text(error).foregroundStyle(.orange).font(.caption).textSelection(.enabled) }
                    if let snapshot {
                        ForEach(snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                        HStack {
                            Text("CRON").font(.system(size: 11, weight: .semibold)).foregroundStyle(CrowTheme.textDim)
                            Spacer()
                            Button { editing = edit(snapshot, cron: .init(id: 0, schedule: "0 9 * * *", command: "", enabled: true), isNew: true) } label: { PanelActionIcon(symbol: "plus") }
                                .help("New cron job").disabled(!snapshot.cronAvailable)
                                .windowDragExcluded().accessibilityIdentifier("crow.automation.new-cron")
                            Button { editing = edit(snapshot) } label: { PanelActionIcon(symbol: "curlybraces") }
                                .help("Edit full crontab").disabled(!snapshot.cronAvailable)
                                .windowDragExcluded().accessibilityIdentifier("crow.automation.edit-cron")
                        }.padding(.top, 4)
                        let jobs = CronJob.parse(snapshot.cron)
                        if jobs.isEmpty && snapshot.cronAvailable { Text("No cron jobs for this user.").font(.caption).foregroundStyle(CrowTheme.textDim) }
                        ForEach(jobs.filter { search.isEmpty || ($0.schedule + " " + $0.command).localizedCaseInsensitiveContains(search) }) { job in
                            Button { editing = edit(snapshot, cron: job) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(job.enabled ? Color.green : CrowTheme.textDim).frame(width: 6, height: 6).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(job.command).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(job.schedule).font(.system(size: 10, design: .monospaced)).foregroundStyle(CrowTheme.textDim)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(CrowTheme.bg2, in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain).windowDragExcluded()
                        }
                        if snapshot.os == "Darwin" {
                            HStack {
                                Text("LAUNCHD").font(.system(size: 11, weight: .semibold)).foregroundStyle(CrowTheme.textDim)
                                Spacer()
                                Toggle("System", isOn: $showSystem).toggleStyle(.switch).controlSize(.mini).font(.caption)
                                    .windowDragExcluded().accessibilityIdentifier("crow.automation.system")
                            }.padding(.top, 16)
                            ForEach(snapshot.launchJobs.filter { (showSystem || !$0.system) && (search.isEmpty || $0.label.localizedCaseInsensitiveContains(search)) }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }) { job in
                                launchRow(job, snapshot: snapshot)
                            }
                            if snapshot.launchJobs.isEmpty { Text("No launchd definitions found.").font(.caption).foregroundStyle(CrowTheme.textDim) }
                        } else { Text("launchd is available on macOS hosts.").font(.caption).foregroundStyle(CrowTheme.textDim).padding(.top, 12) }
                    }
                }.padding(12)
            }
        }.background(CrowTheme.bg1).foregroundStyle(CrowTheme.text)
            .windowDragExcluded()
            .accessibilityIdentifier("crow.automation.panel")
            .task(id: loadID) {
                let state = model.current
                snapshot = nil; error = nil; loading = true
                defer { if !Task.isCancelled { loading = false } }
                do { let result = try await AutomationService(state: state).load(); try Task.checkCancellation(); snapshot = result }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .sheet(item: $editing) { request in AutomationEditor(request: request) { revision += 1 } }
    }

    private func edit(_ snapshot: AutomationSnapshot, cron: CronJob? = nil, launch: LaunchJob? = nil, isNew: Bool = false) -> AutomationEdit {
        .init(state: model.current, host: host, snapshot: snapshot, cron: cron, launch: launch, isNew: isNew)
    }

    private func launchRow(_ job: LaunchJob, snapshot: AutomationSnapshot) -> some View {
        let pid = snapshot.services[snapshot.domain(for: job) + "/" + job.label]
        return Button { editing = edit(snapshot, launch: job) } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill((pid ?? 0) > 0 ? Color.green : CrowTheme.textDim).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.label).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(job.schedule + " · " + (pid == nil ? "Not loaded" : pid! > 0 ? "Running" : "Loaded"))
                        .font(.system(size: 10)).foregroundStyle(CrowTheme.textDim)
                }
                Spacer(minLength: 0)
                if !job.writable { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(CrowTheme.textDim) }
            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(CrowTheme.bg2, in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).windowDragExcluded()
    }
}

private struct AutomationEditor: View {
    let request: AutomationEdit
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var schedule = ""
    @State private var command = ""
    @State private var enabled = true
    @State private var source = ""
    @State private var original: Data?
    @State private var launch: LaunchDocument?
    @State private var executable = ""
    @State private var arguments = ""
    @State private var directory = ""
    @State private var interval = ""
    @State private var raw = false
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    private var editable: Bool { request.launch?.writable ?? true }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.launch?.label ?? (request.cron == nil ? "Crontab" : request.isNew ? "New Cron Job" : "Cron Job")).font(.title3.bold()).lineLimit(2)
                    Text(request.host).font(.subheadline).foregroundStyle(CrowTheme.textDim)
                }
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if saved { Text("Saved. Reload the launchd job to apply the updated file.").font(.callout).foregroundStyle(.green) }
            if busy { ProgressView().controlSize(.small) }
            if request.launch != nil {
                if !editable { Text("Read-only for this user.").font(.callout).foregroundStyle(CrowTheme.textDim) }
                Picker("Editor", selection: $raw) { Text("Fields").tag(false); Text("Plist Source").tag(true) }
                    .pickerStyle(.segmented).disabled(busy || original == nil)
                    .onChange(of: raw) { old, new in
                        do { if new { source = try editedLaunch().xml() } else { launch = try LaunchDocument(data: Data(source.utf8)); readFields() } }
                        catch { self.error = error.localizedDescription; raw = old }
                    }
                if raw { sourceEditor }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            field("Executable", text: $executable)
                            Text("Arguments · one per line").font(.caption).foregroundStyle(CrowTheme.textDim)
                            TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 100).padding(6).background(CrowTheme.bg0, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(CrowTheme.border))
                            field("Working directory", text: $directory)
                            field("Repeat interval · seconds, empty to remove", text: $interval)
                            Text("Calendar schedules, KeepAlive, environment variables and other options are preserved. Edit them in Plist Source.").font(.caption).foregroundStyle(CrowTheme.textDim)
                        }.disabled(!editable)
                    }
                }
                HStack {
                    Text(request.launch?.path ?? "").font(.caption).foregroundStyle(CrowTheme.textDim).textSelection(.enabled)
                    Spacer()
                    Button("Reload Job") { reload() }.disabled(!editable || original == nil || busy)
                        .help("Reload the saved plist. RunAtLoad jobs can run immediately.")
                    Button("Save File") { save() }.buttonStyle(.borderedProminent).disabled(!editable || original == nil || busy)
                }
            } else if request.cron != nil {
                HStack {
                    Text("Schedule").font(.caption).foregroundStyle(CrowTheme.textDim)
                    Spacer()
                    CrowMenu("Presets") {
                        Button("Every minute") { schedule = "* * * * *" }
                        Button("Every hour") { schedule = "0 * * * *" }
                        Button("Daily at 9:00") { schedule = "0 9 * * *" }
                        Button("At reboot") { schedule = "@reboot" }
                    }
                }
                TextField("Minute Hour Day Month Weekday", text: $schedule).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                Text("Minute · Hour · Day of month · Month · Day of week").font(.caption).foregroundStyle(CrowTheme.textDim)
                field("Command", text: $command)
                Toggle("Enabled", isOn: $enabled)
                Spacer(minLength: 16)
                HStack { Spacer(); Button("Save Cron Job") { save() }.buttonStyle(.borderedProminent).disabled(busy) }
            } else {
                Text("This user's full crontab, including comments and environment variables.").font(.callout).foregroundStyle(CrowTheme.textDim)
                sourceEditor
                HStack { Spacer(); Button("Save Crontab") { save() }.buttonStyle(.borderedProminent).disabled(busy) }
            }
        }.padding(24).frame(minWidth: 320, idealWidth: 760, minHeight: 500, idealHeight: 620)
            .background(CrowTheme.bg1).foregroundStyle(CrowTheme.text).interactiveDismissDisabled(busy)
            .task {
                source = request.snapshot.cron
                if let cron = request.cron { schedule = cron.schedule; command = cron.command; enabled = cron.enabled }
                guard let job = request.launch else { return }
                busy = true; defer { busy = false }
                do { let data = try await AutomationService(state: request.state).readLaunch(job); original = data; launch = try LaunchDocument(data: data); source = try launch!.xml(); readFields() }
                catch { self.error = error.localizedDescription }
            }
    }

    private var sourceEditor: some View {
        TextEditor(text: $source).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
            .padding(8).background(CrowTheme.bg0, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CrowTheme.border)).disabled(!editable || busy)
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(CrowTheme.textDim)
            TextField(title, text: text).textFieldStyle(.roundedBorder)
        }
    }
    private func readFields() {
        let values = launch?.values ?? [:], args = values["ProgramArguments"] as? [String] ?? []
        executable = values["Program"] as? String ?? args.first ?? ""
        arguments = (values["Program"] != nil ? args : Array(args.dropFirst())).joined(separator: "\n")
        directory = values["WorkingDirectory"] as? String ?? ""
        interval = (values["StartInterval"] as? Int).map(String.init) ?? ""
    }
    private func editedLaunch() throws -> LaunchDocument {
        guard var document = launch else { throw CommandError("Wait for the plist to load.") }
        let args = arguments.isEmpty ? [] : arguments.components(separatedBy: "\n")
        guard !executable.isEmpty else { throw CommandError("Enter an executable path.") }
        if document.values["Program"] != nil { document.values["Program"] = executable; document.values["ProgramArguments"] = args.isEmpty ? nil : args }
        else { document.values["ProgramArguments"] = [executable] + args }
        document.values["WorkingDirectory"] = directory.isEmpty ? nil : directory
        if interval.isEmpty { document.values.removeValue(forKey: "StartInterval") }
        else {
            guard let seconds = Int(interval), seconds > 0 else { throw CommandError("Repeat interval must be a positive number of seconds.") }
            document.values["StartInterval"] = seconds
        }
        return document
    }
    private func save() {
        busy = true; error = nil; saved = false
        Task {
            defer { busy = false }
            do {
                let service = AutomationService(state: request.state)
                if let job = request.launch, let original {
                    let xml = try raw ? LaunchDocument(data: Data(source.utf8)).xml() : editedLaunch().xml()
                    try await service.saveLaunch(xml, job: job, expected: original)
                    self.original = Data(xml.utf8); source = xml; launch = try LaunchDocument(data: Data(xml.utf8)); saved = true
                } else {
                    let updated = try request.cron.map { try CronJob(id: $0.id, schedule: schedule, command: command, enabled: enabled).replacing(in: request.snapshot.cron, isNew: request.isNew) } ?? source
                    try await service.saveCron(updated, expected: request.snapshot.cron); dismiss()
                }
                onSave()
            } catch { self.error = error.localizedDescription }
        }
    }
    private func reload() {
        guard let job = request.launch else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await AutomationService(state: request.state).reloadLaunch(job, domain: request.snapshot.domain(for: job)); saved = false; onSave() }
            catch { self.error = error.localizedDescription }
        }
    }
}
