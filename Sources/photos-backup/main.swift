import Foundation
import PhotosBackupCore
import Darwin
#if canImport(Photos)
import Photos
#endif

@main
struct PhotosBackupCommand {
    static func main() async {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            switch args.command {
            case "help", "--help", "-h": print(usage)
            case "authorize": try await authorize()
            case "doctor": try await doctor(configURL: args.configURL)
            case "sync": try await sync(args)
            case "service": try service(args)
            default: throw BackupError.invalidArgument("unknown command; run photos-backup help")
            }
        } catch {
            let message: String
            if let e = error as? BackupError { message = e.description }
            else if let e = error as? BlobConditionFailed { message = e.description }
            else { message = "Operation failed (\(type(of: error)))" }
            fputs("photos-backup: \(message)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func authorize() async throws {
        #if canImport(Photos)
        try requirePackagedApp()
        let library = PhotoKitLibrary(libraryID: "authorization")
        var state = library.authorization()
        if state == "not-determined" { state = await library.requestAuthorization() }
        guard state == "authorized" else {
            throw BackupError.permission("full Photos access is required; current status is \(state). If macOS did not show a prompt, enable access in System Settings > Privacy & Security > Photos and rerun authorize")
        }
        print("Photos access is authorized for this app bundle.")
        #else
        throw BackupError.permission("PhotoKit is available only on macOS")
        #endif
    }

    private static func doctor(configURL: URL) async throws {
        try requirePackagedApp()
        let config = try AppConfiguration.load(from: configURL)
        let logger = loggerFor(config)
        let library = PhotoKitLibrary(libraryID: config.libraryID)
        guard library.authorization() == "authorized" else {
            throw BackupError.permission("full read access is required; run authorize in the packaged app (status: \(library.authorization()))")
        }
        let spool = config.resolve(config.spoolDirectory)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.isWritableFile(atPath: spool.path) else { throw BackupError.storage("spool directory is not writable") }
        let store = try AzureBlobStore(configuration: config)
        try await store.probe(prefix: "doctor")
        logger.info("Doctor completed: Photos authorization, local spool write access, and Azure probe write/read/delete passed")
        print("Doctor passed: Photos is authorized, local spool is writable, and an isolated Azure probe was written, read, and deleted.")
        print("Doctor does not verify export fidelity, full-library coverage, Azure retention, or a real backup.")
    }

    private static func sync(_ args: Arguments) async throws {
        try requirePackagedApp()
        let config = try AppConfiguration.load(from: args.configURL)
        let log = loggerFor(config)
        let timeZone = TimeZone(identifier: config.timeZoneIdentifier)!
        let filter = try DateFilter(from: args.from, to: args.to, timeZone: timeZone)
        let lockURL = config.resolve(config.journalPath).deletingLastPathComponent().appendingPathComponent("sync.lock")
        let lock = try RunLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        let library = PhotoKitLibrary(libraryID: config.libraryID)
        let store = try AzureBlobStore(configuration: config)
        let engine = try BackupEngine(configuration: config, library: library, store: store, logger: log)
        let summary = await engine.sync(filter: filter, dryRun: args.dryRun)
        print("\(summary.dryRun ? "DRY RUN — " : "")examined \(summary.examined), skipped \(summary.skipped), would upload \(summary.wouldUpload), uploaded \(summary.uploaded), resumed \(summary.resumed), pending \(summary.pending), failed \(summary.failed), undated assets \(summary.unclassifiableAssets), transferred \(summary.bytesTransferred) bytes, reused \(summary.bytesReused) bytes")
        log.info("Sync completed: examined=\(summary.examined) skipped=\(summary.skipped) would_upload=\(summary.wouldUpload) uploaded=\(summary.uploaded) resumed=\(summary.resumed) pending=\(summary.pending) failed=\(summary.failed) bytes=\(summary.bytesTransferred) reused=\(summary.bytesReused) dry_run=\(summary.dryRun)")
        if summary.failed > 0 || summary.pending > 0 || summary.unclassifiableAssets > 0 { Foundation.exit(1) }
    }

    private static func loggerFor(_ config: AppConfiguration) -> SafeLogger {
        let privateValues = config.connectionString.components(separatedBy: ";").compactMap { component -> String? in
            for name in ["AccountKey=", "SharedAccessSignature="] where component.hasPrefix(name) {
                return String(component.dropFirst(name.count))
            }
            return nil
        }
        return SafeLogger(url: config.resolve(config.logPath), maxBytes: config.logMaxBytes, count: config.logFileCount,
                          secrets: [config.connectionString] + privateValues)
    }

    private static func service(_ args: Arguments) throws {
        guard let subcommand = args.positionals.first, ["install", "uninstall", "status"].contains(subcommand) else {
            throw BackupError.invalidArgument("usage: photos-backup service install|uninstall|status [--config PATH]")
        }
        let label = "com.photosbackup.daily"
        let domain = "gui/\(getuid())"
        let plistURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let controller = LaunchAgentController(label: label, domain: domain, plistURL: plistURL, runner: runLaunchctl)
        switch subcommand {
        case "install":
            try requirePackagedApp()
            let config = try AppConfiguration.load(from: args.configURL)
            let manager = LaunchAgent(config: config, configURL: args.configURL,
                                      executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                      controller: controller)
            try manager.install()
            print("LaunchAgent installed and loaded for the current user. It runs daily at hour \(config.dailyHour) in the Mac's local time zone.")
        case "uninstall": try controller.uninstall(); print("LaunchAgent unloaded and removed; backups and configuration were kept.")
        default: print("LaunchAgent \(controller.status)")
        }
    }

    fileprivate static func runLaunchctl(_ args: [String]) -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.standardError
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }

    private static func requirePackagedApp() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.infoDictionary?["NSPhotoLibraryUsageDescription"] as? String != nil else {
            throw BackupError.permission("run this command from the packaged Photos Backup.app so macOS can associate Photos permission with its bundle")
        }
    }

    private static let usage = """
    photos-backup authorize
    photos-backup doctor [--config PATH]
    photos-backup sync [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--dry-run] [--config PATH]
    photos-backup service install|uninstall|status [--config PATH]

    With no date filters, sync scans the full Photos library. Date limits are inclusive in the
    configured time zone. Use the packaged .app executable for Photos authorization.
    """
}

private struct Arguments {
    let command: String
    var configURL = URL(fileURLWithPath: "~/Library/Application Support/PhotosBackup/config.json".expandingTilde).standardizedFileURL
    var from: String?
    var to: String?
    var dryRun = false
    var positionals: [String] = []
    init(_ values: [String]) throws {
        guard let command = values.first else { self.command = "help"; return }
        self.command = command
        var index = 1
        while index < values.count {
            let value = values[index]
            switch value {
            case "--config":
                guard index + 1 < values.count else { throw BackupError.invalidArgument("--config requires a path") }
                configURL = URL(fileURLWithPath: values[index + 1].expandingTilde).standardizedFileURL; index += 2
            case "--from":
                guard index + 1 < values.count else { throw BackupError.invalidArgument("--from requires YYYY-MM-DD") }
                from = values[index + 1]; index += 2
            case "--to":
                guard index + 1 < values.count else { throw BackupError.invalidArgument("--to requires YYYY-MM-DD") }
                to = values[index + 1]; index += 2
            case "--dry-run": dryRun = true; index += 1
            default:
                guard !value.hasPrefix("--") else { throw BackupError.invalidArgument("unknown option \(value)") }
                positionals.append(value); index += 1
            }
        }
        if self.command != "sync" && (from != nil || to != nil || dryRun) { throw BackupError.invalidArgument("date filters and --dry-run are valid only for sync") }
        if self.command == "sync" && !positionals.isEmpty { throw BackupError.invalidArgument("sync accepts no positional arguments") }
    }
}

private extension String { var expandingTilde: String { (self as NSString).expandingTildeInPath } }

private struct LaunchAgent {
    let config: AppConfiguration
    let configURL: URL
    let executable: URL
    let controller: LaunchAgentController
    var label: String { controller.label }
    var plistURL: URL { controller.plistURL }

    func install() throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let logURL = config.resolve(config.logPath)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try controller.unloadForReplacement()
        let dict = try LaunchAgentDefinition.propertyList(label: label, executable: executable, config: configURL,
                                                          hour: config.dailyHour, log: logURL)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
        if !FileManager.default.fileExists(atPath: logURL.path + ".launchd") {
            _ = FileManager.default.createFile(atPath: logURL.path + ".launchd", contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        try runBootstrap(["bootstrap", "\(controller.domain)", plistURL.path])
        guard controller.isLoaded else { throw BackupError.storage("LaunchAgent bootstrap returned but the job is not loaded") }
    }
    private func runBootstrap(_ args: [String]) throws {
        guard PhotosBackupCommand.runLaunchctl(args) == 0 else { throw BackupError.storage("launchctl bootstrap failed") }
    }
}
