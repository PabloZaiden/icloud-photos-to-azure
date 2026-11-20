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
            case "config": try configure(args)
            case "authorize": try await authorize()
            case "doctor": try await doctor(configURL: args.configURL)
            case "sync": try await sync(args)
            case "service": try await service(args)
            default: throw BackupError.invalidArgument("unknown command; run photo-backup help")
            }
        } catch {
            let message: String
            if let e = error as? BackupError { message = e.description }
            else if let e = error as? BlobConditionFailed { message = e.description }
            else { message = "Operation failed (\(type(of: error)))" }
            fputs("photo-backup: \(message)\n", stderr)
            Foundation.exit(2)
        }
    }

    private static func configure(_ args: Arguments) throws {
        guard args.positionals.isEmpty else {
            throw BackupError.invalidArgument("usage: photo-backup config --storage-account NAME | --connection-string [--config PATH]")
        }
        let connectionString = args.connectionStringPrompt ? try readHiddenConnectionString() : nil
        try AppConfiguration.configure(connectionString: connectionString,
                                       storageAccountName: args.storageAccountName,
                                       at: args.configURL)
        if args.connectionStringPrompt { print("Saved Azure connection string.") }
        else { print("Saved Azure CLI storage account. Container: photos-backup.") }
    }

    private static func readHiddenConnectionString() throws -> String {
        guard isatty(STDIN_FILENO) == 1 else {
            throw BackupError.invalidArgument("--connection-string needs an interactive terminal so the value is not echoed")
        }
        let capacity = 16_384
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        defer {
            memset(buffer, 0, capacity)
            buffer.deallocate()
        }
        guard readpassphrase("Azure connection string (input hidden): ", buffer, capacity, 0) != nil else {
            throw BackupError.permission("could not read the connection string from the terminal")
        }
        let value = String(cString: buffer)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BackupError.invalidConfiguration("connection string cannot be empty")
        }
        return value
    }

    private static func authorize() async throws {
        #if canImport(Photos)
        try requirePhotoLibraryMetadata()
        let library = PhotoKitLibrary(libraryID: "authorization")
        var state = library.authorization()
        if state == "not-determined" { state = await library.requestAuthorization() }
        guard state == "authorized" else {
            throw BackupError.permission("full Photos access is required; current status is \(state). If macOS did not show a prompt, enable access in System Settings > Privacy & Security > Photos and rerun photo-backup authorize")
        }
        try library.checkAvailability()
        print("Photos access is authorized.")
        #else
        throw BackupError.permission("PhotoKit is available only on macOS")
        #endif
    }

    private static func doctor(configURL: URL) async throws {
        try requirePhotoLibraryMetadata()
        let config = try AppConfiguration.load(from: configURL)
        let logger = loggerFor(config)
        let library = PhotoKitLibrary(libraryID: config.libraryID)
        try library.checkAvailability()
        let store = try AzureBlobStore(configuration: config)
        _ = try OriginalsMirror(library: library, configuration: config, store: store, logger: logger)
        try await store.probe(prefix: "doctor")
        logger.info("Doctor completed: system Photos library access and Azure probe passed")
        print("Doctor passed: Photos is authorized, the system library is available, and an isolated Azure probe passed.")
    }

    private static func sync(_ args: Arguments) async throws {
        try requirePhotoLibraryMetadata()
        let config = try AppConfiguration.load(from: args.configURL)
        let log = loggerFor(config)
        prepareLaunchAgentOutput(log)
        let timeZone = TimeZone(identifier: config.timeZoneIdentifier)!
        let filter = try DateFilter(from: args.from, to: args.to, timeZone: timeZone)
        let lockURL = config.resolve(config.journalPath).deletingLastPathComponent().appendingPathComponent("sync.lock")
        let lock = try RunLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        let library = PhotoKitLibrary(libraryID: config.libraryID)
        try library.checkAvailability()
        let store = try AzureBlobStore(configuration: config)
        let mirror = try OriginalsMirror(library: library, configuration: config, store: store, logger: log)
        let summary = await mirror.sync(filter: filter, dryRun: args.dryRun)
        if summary.failed > 0 || summary.pending > 0 { Foundation.exit(1) }
    }

    private static func loggerFor(_ config: AppConfiguration) -> SafeLogger {
        let connectionString = config.connectionString ?? ""
        let privateValues = connectionString.components(separatedBy: ";").compactMap { component -> String? in
            for name in ["AccountKey=", "SharedAccessSignature="] where component.hasPrefix(name) {
                return String(component.dropFirst(name.count))
            }
            return nil
        }
        return SafeLogger(url: config.resolve(config.logPath), maxBytes: config.logMaxBytes, count: config.logFileCount,
                          secrets: [connectionString] + privateValues, outputToStandardOutput: true)
    }

    private static func prepareLaunchAgentOutput(_ logger: SafeLogger) {
        guard ProcessInfo.processInfo.environment["PHOTOS_BACKUP_LAUNCH_AGENT"] == "1" else { return }
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { continue }
            guard ftruncate(descriptor, 0) == 0 else {
                logger.error("Could not reset the previous LaunchAgent output log")
                continue
            }
            _ = lseek(descriptor, 0, SEEK_SET)
        }
    }

    private static func service(_ args: Arguments) async throws {
        guard let subcommand = args.positionals.first, ["install", "uninstall", "status"].contains(subcommand) else {
            throw BackupError.invalidArgument("usage: photo-backup service install|uninstall|status [--config PATH]")
        }
        let label = "com.photosbackup.daily"
        let domain = "gui/\(getuid())"
        let plistURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let controller = LaunchAgentController(label: label, domain: domain, plistURL: plistURL, runner: runLaunchctl)
        switch subcommand {
        case "install":
            try requirePhotoLibraryMetadata()
            let config = try AppConfiguration.load(from: args.configURL)
            try await authorize()
            try await doctor(configURL: args.configURL)
            try preflightLaunchAgentDirectory()
            let manager = LaunchAgent(config: config, configURL: args.configURL,
                                      executable: currentExecutableURL(),
                                      controller: controller)
            try manager.install()
            print("LaunchAgent installed and loaded for the current user. It runs daily at hour \(config.dailyHour) in the Mac's local time zone.")
        case "uninstall": try controller.uninstall(); print("LaunchAgent unloaded and removed; backups and configuration were kept.")
        default: print("LaunchAgent \(controller.status)")
        }
    }

    private static func preflightLaunchAgentDirectory() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let probe = directory.appendingPathComponent(".photos-backup-write-probe-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: probe.path)
            try FileManager.default.removeItem(at: probe)
        } catch {
            try? FileManager.default.removeItem(at: probe)
            throw BackupError.permission("the current user cannot write to Library/LaunchAgents; service was not installed")
        }
    }

    fileprivate static func runLaunchctl(_ args: [String]) -> Int32 {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = args.first == "print" ? FileHandle.nullDevice : FileHandle.standardError
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }

    private static func currentExecutableURL() -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        var bufferSize = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &bufferSize) == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        }
        let path = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func requirePhotoLibraryMetadata() throws {
        guard Bundle.main.bundleIdentifier == "com.photosbackup.cli",
              Bundle.main.infoDictionary?["NSPhotoLibraryUsageDescription"] as? String != nil else {
            throw BackupError.permission("this photo-backup executable is missing its embedded Photos permission metadata; download the signed release binary")
        }
    }

    private static let usage = """
    photo-backup config --storage-account NAME | --connection-string [--config PATH]
    photo-backup authorize
    photo-backup doctor [--config PATH]
    photo-backup sync [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--dry-run] [--config PATH]
    photo-backup service install|uninstall|status [--config PATH]
    """
}

private struct Arguments {
    let command: String
    var configURL = URL(fileURLWithPath: "~/Library/Application Support/PhotosBackup/config.json".expandingTilde).standardizedFileURL
    var from: String?
    var to: String?
    var dryRun = false
    var storageAccountName: String?
    var connectionStringPrompt = false
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
            case "--storage-account":
                guard index + 1 < values.count, !values[index + 1].hasPrefix("--") else {
                    throw BackupError.invalidArgument("--storage-account requires an account name")
                }
                storageAccountName = values[index + 1]; index += 2
            case "--connection-string": connectionStringPrompt = true; index += 1
            default:
                guard !value.hasPrefix("--") else { throw BackupError.invalidArgument("unknown option \(value)") }
                positionals.append(value); index += 1
            }
        }
        if self.command != "sync" && (from != nil || to != nil || dryRun) { throw BackupError.invalidArgument("date filters and --dry-run are valid only for sync") }
        if self.command == "sync" && !positionals.isEmpty { throw BackupError.invalidArgument("sync accepts no positional arguments") }
        if self.command == "config" {
            guard (storageAccountName != nil) != connectionStringPrompt else {
                throw BackupError.invalidArgument("choose exactly one: --storage-account NAME or --connection-string")
            }
            guard from == nil, to == nil, !dryRun else { throw BackupError.invalidArgument("config accepts only an authentication option and --config PATH") }
        } else if storageAccountName != nil || connectionStringPrompt {
            throw BackupError.invalidArgument("--storage-account and --connection-string are valid only for config")
        }
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
