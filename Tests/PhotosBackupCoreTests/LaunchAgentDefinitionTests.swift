import XCTest
@testable import PhotosBackupCore

final class LaunchAgentDefinitionTests: XCTestCase {
    func testScheduleUsesMinuteZeroAndExplicitConfigPath() throws {
        let config = URL(fileURLWithPath: "/tmp/private/config/custom.json")
        let log = URL(fileURLWithPath: "/tmp/private/logs/backup.log")
        let plist = try LaunchAgentDefinition.propertyList(label: "com.example.photos", executable: URL(fileURLWithPath: "/Users/example/.local/bin/photo-backup"),
                                                           config: config, hour: 2, log: log)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/Users/example/.local/bin/photo-backup", "sync", "--config", config.path])
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int], ["Hour": 2, "Minute": 0])
        XCTAssertEqual(plist["StandardErrorPath"] as? String, log.path + ".launchd")
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, false)
        XCTAssertThrowsError(try LaunchAgentDefinition.propertyList(label: "x", executable: URL(fileURLWithPath: "relative"), config: config, hour: 25, log: log))
    }

    func testStatusWorksWithoutConfigAndFindsLoadedJobWithoutPlist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launchagent-status-\(UUID().uuidString)")
        let fake = FakeLaunchctl(loaded: true)
        let controller = LaunchAgentController(label: "com.example.photos", domain: "gui/501",
                                                plistURL: root.appendingPathComponent("job.plist"), runner: fake.run)
        XCTAssertEqual(controller.status, "loaded")
    }

    func testUninstallVerifiesBootoutAndKeepsPlistWhenJobRemainsLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launchagent-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist = root.appendingPathComponent("job.plist")
        try Data("plist".utf8).write(to: plist)
        let fake = FakeLaunchctl(loaded: true, failBootout: true)
        let controller = LaunchAgentController(label: "com.example.photos", domain: "gui/501", plistURL: plist, runner: fake.run)
        XCTAssertThrowsError(try controller.uninstall())
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(controller.status, "loaded")
    }

    func testUninstallWithoutConfigIsIdempotentAndRemovesOnlyAfterUnload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launchagent-idempotent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist = root.appendingPathComponent("job.plist")
        try Data("plist".utf8).write(to: plist)
        let fake = FakeLaunchctl(loaded: true)
        let controller = LaunchAgentController(label: "com.example.photos", domain: "gui/501", plistURL: plist, runner: fake.run)
        try controller.uninstall()
        XCTAssertFalse(fake.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        try controller.uninstall()
        XCTAssertEqual(controller.status, "not installed")
    }
}

private final class FakeLaunchctl {
    var loaded: Bool
    var failBootout: Bool
    init(loaded: Bool, failBootout: Bool = false) { self.loaded = loaded; self.failBootout = failBootout }
    func run(_ arguments: [String]) -> Int32 {
        switch arguments.first {
        case "print": return loaded ? 0 : 1
        case "bootout":
            if failBootout { return 1 }
            loaded = false; return 0
        case "bootstrap": loaded = true; return 0
        default: return 1
        }
    }
}
