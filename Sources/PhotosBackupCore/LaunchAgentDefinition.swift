import Foundation
import Darwin

public enum LaunchAgentDefinition {
    public static func propertyList(label: String, executable: URL, config: URL, hour: Int, log: URL) throws -> [String: Any] {
        guard (0...23).contains(hour), executable.path.hasPrefix("/"), config.path.hasPrefix("/"), log.path.hasPrefix("/") else {
            throw BackupError.invalidArgument("LaunchAgent paths must be absolute and hour must be 0 through 23")
        }
        return ["Label": label, "ProgramArguments": [executable.path, "sync", "--config", config.path],
                "StartCalendarInterval": ["Hour": hour, "Minute": 0], "RunAtLoad": false, "KeepAlive": false,
                "EnvironmentVariables": ["PHOTOS_BACKUP_LAUNCH_AGENT": "1"],
                "StandardOutPath": log.path + ".launchd", "StandardErrorPath": log.path + ".launchd"]
    }
}

public final class LaunchAgentController {
    public typealias Runner = ([String]) -> Int32
    public let label: String
    public let domain: String
    public let plistURL: URL
    private let run: Runner

    public init(label: String, domain: String, plistURL: URL, runner: @escaping Runner) {
        self.label = label; self.domain = domain; self.plistURL = plistURL; self.run = runner
    }

    public var isLoaded: Bool { run(["print", "\(domain)/\(label)"]) == 0 }

    public var status: String {
        if isLoaded { return "loaded" }
        return FileManager.default.fileExists(atPath: plistURL.path) ? "installed but not loaded" : "not installed"
    }

    public func unloadForReplacement() throws {
        guard isLoaded else { return }
        _ = run(["bootout", "\(domain)/\(label)"])
        guard !isLoaded else { throw BackupError.storage("LaunchAgent remains loaded after launchctl bootout") }
    }

    public func uninstall() throws {
        if isLoaded {
            _ = run(["bootout", "\(domain)/\(label)"])
            guard !isLoaded else { throw BackupError.storage("LaunchAgent remains loaded; its plist was kept") }
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        var info = stat()
        guard lstat(plistURL.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw BackupError.invalidConfiguration("LaunchAgent plist must be a regular file, not a symlink")
        }
        try FileManager.default.removeItem(at: plistURL)
    }
}
