import XCTest
import CrowCore
import SwiftUI
@testable import Crow

@MainActor final class AutomationTests: XCTestCase {
    func testCronEditingPreservesCommentsEnvironmentAndDisabledJobs() throws {
        let source = "# Keep this\nSHELL=/bin/zsh\n0 9 * * * echo hello world\n# crow-disabled: @reboot echo restart\n"
        let jobs = CronJob.parse(source)
        XCTAssertEqual(jobs.count, 2); XCTAssertEqual(jobs[0].command, "echo hello world"); XCTAssertFalse(jobs[1].enabled)
        var job = jobs[0]; job.schedule = "0 10 * * *"; job.enabled = false
        let updated = try job.replacing(in: source)
        XCTAssertTrue(updated.hasPrefix("# Keep this\nSHELL=/bin/zsh\n# crow-disabled: 0 10 * * * echo hello world\n"))
        XCTAssertTrue(updated.hasSuffix("# crow-disabled: @reboot echo restart\n"))
        job.command = "one\ntwo"; XCTAssertThrowsError(try job.replacing(in: source))
    }

    func testLaunchStatusAndUnknownPlistSettingsArePreserved() throws {
        let values: [String: Any] = ["Label": "test.job", "ProgramArguments": ["/bin/echo", "hello"], "KeepAlive": ["SuccessfulExit": false], "StartCalendarInterval": [["Hour": 9], ["Hour": 18]]]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        var document = try LaunchDocument(data: data); document.values["StartInterval"] = 60
        let restored = try LaunchDocument(data: Data(document.xml().utf8))
        XCTAssertEqual((restored.values["StartCalendarInterval"] as? [[String: Int]])?.count, 2)
        XCTAssertEqual(restored.values["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        let output = "gui/501 = {\nservices = {\n123 - test.running\n0 0 test.idle\n0 (pe) test.waiting\n}\nenvironment = {\nHOME=/tmp\n}\n}"
        XCTAssertEqual(AutomationService.services(output, domain: "gui/501"), ["gui/501/test.running": 123, "gui/501/test.idle": 0, "gui/501/test.waiting": 0])
    }

    #if os(macOS)
    func testLocalAutomationIdentifiesDeviceAndHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-automation-device-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let snapshot = try await AutomationService(state: model.current).load()
        XCTAssertEqual(snapshot.os, "Darwin")
        XCTAssertEqual(snapshot.uid, String(getuid()))
        XCTAssertEqual(snapshot.home, ProcessInfo.processInfo.environment["HOME"])
    }

    func testAutomationControlsAreExcludedFromWindowDragging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-automation-click-" + UUID().uuidString)
        let model = AppModel(vaultURL: root)
        let hosting = NSHostingView(rootView: AutomationPanel().environment(model).windowDragBackground())
        let window = NSWindow(contentRect: .init(x: 200, y: 200, width: 320, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.close(); model.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(hosting.superview?.subviews.compactMap { $0 as? WindowMoveSurface }.first)
        for point in [NSPoint(x: 290, y: 30), NSPoint(x: 160, y: 120), NSPoint(x: 160, y: 300)] {
            XCTAssertFalse(surface.containsRegion(hosting.convert(point, to: surface)), "Automation controls must receive mouse clicks instead of dragging the window")
        }
    }
    func testCronSaveUsesOwningRunnerAndRefusesExternalChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-cron-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("crontab.txt"), executable = root.appendingPathComponent("crontab")
        let script = "#!/bin/sh\nif [ \"$1\" = -l ]; then if [ -f \"$CROW_TEST_CRON\" ]; then cat \"$CROW_TEST_CRON\"; else echo 'no crontab for fixture' >&2; exit 1; fi; else cp \"$1\" \"$CROW_TEST_CRON\"; fi\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = AutomationService { command in
            try await ReverseSSHCommand.run("/bin/sh", ["-c", command], environment: ["PATH": root.path + ":/usr/bin:/bin", "CROW_TEST_CRON": file.path])
        }
        let empty = try await service.readCron(); XCTAssertEqual(empty, "")
        let source = "# fixture\n* * * * * echo '$(touch \(root.path)/unexpected)'\n\n"
        try await service.saveCron(source, expected: "")
        let saved = try await service.readCron(); XCTAssertEqual(saved, source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
        try "# external edit\n".write(to: file, atomically: true, encoding: .utf8)
        do { try await service.saveCron("", expected: source); XCTFail("Concurrent edits must not be overwritten") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# external edit\n")
    }

    func testLaunchFileSaveValidatesAndDetectsChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crow-launch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("job.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "test.job", "Program": "/bin/true"], format: .binary, options: 0)
        try data.write(to: file)
        let service = AutomationService { command in try await ReverseSSHCommand.run("/bin/sh", ["-c", command]) }
        let job = LaunchJob(path: file.path, label: "test.job", schedule: "On demand", writable: true, system: false, daemon: false)
        let read = try await service.readLaunch(job); XCTAssertEqual(read, data)
        var document = try LaunchDocument(data: data); document.values["StartInterval"] = 120
        let xml = try document.xml()
        try await service.saveLaunch(xml, job: job, expected: data)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), xml)
        do { try await service.saveLaunch(xml, job: job, expected: data); XCTFail("Expected conflict") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }

    func testLaunchScannerRunsWithoutLoadingAnyJobs() async throws {
        let output = try await ReverseSSHCommand.run("/bin/sh", ["-c", AutomationService.launchListCommand])
        let jobs = try JSONDecoder().decode([LaunchJob].self, from: Data(output.utf8))
        XCTAssertFalse(jobs.isEmpty)
        XCTAssertTrue(jobs.allSatisfy { $0.path.hasSuffix(".plist") && !$0.label.isEmpty })
    }
    #endif
}
