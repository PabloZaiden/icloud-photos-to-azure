import Foundation
import Darwin

public enum AzureAuthenticationMode: String, Codable {
    case connectionString
    case azureCli
}

private struct ConfigurationDocument: Decodable {
    var connectionString: String?
    var storageAccountName: String?

    // Read once from the previous, expanded config format so existing installs retain
    // their destination and operational choices after the external file is simplified.
    var blobEndpoint: String?
    var azureCliPath: String?
    var azureCliSubscription: String?
    var container: String?
    var prefix: String?
    var libraryID: String?
    var spoolDirectory: String?
    var journalPath: String?
    var logPath: String?
    var maxSpoolBytes: Int64?
    var blockSize: Int?
    var maxRetries: Int?
    var dailyHour: Int?
    var timeZoneIdentifier: String?
    var allowInsecureLocalHTTP: Bool?
    var logMaxBytes: Int64?
    var logFileCount: Int?

    var authenticationMode: AzureAuthenticationMode?

    func authentication() throws -> (connectionString: String?, storageAccountName: String?, mode: AzureAuthenticationMode) {
        let connectionString = connectionString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            ? nil : connectionString
        let accountName = storageAccountName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storageAccountName = accountName?.isEmpty == false ? accountName : nil
        guard (connectionString == nil) != (storageAccountName == nil) else {
            throw BackupError.invalidConfiguration("choose exactly one: connectionString or storageAccountName")
        }
        let mode: AzureAuthenticationMode = connectionString == nil ? .azureCli : .connectionString
        if let authenticationMode, authenticationMode != mode {
            throw BackupError.invalidConfiguration("authenticationMode is inferred; remove the legacy authenticationMode field")
        }
        return (connectionString, storageAccountName, mode)
    }
}

private struct AuthenticationConfiguration: Codable {
    var connectionString: String?
    var storageAccountName: String?
}

private struct PersistedRuntimeSettings: Codable {
    var blobEndpoint: String?
    var azureCliPath: String?
    var azureCliSubscription: String?
    var container: String
    var prefix: String
    var libraryID: String
    var spoolDirectory: String
    var journalPath: String
    var logPath: String
    var maxSpoolBytes: Int64
    var blockSize: Int
    var maxRetries: Int
    var dailyHour: Int
    var timeZoneIdentifier: String
    var allowInsecureLocalHTTP: Bool
    var logMaxBytes: Int64
    var logFileCount: Int

    static var storageRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("PhotosBackup", isDirectory: true)
    }

    static var settingsURL: URL {
        storageRoot.appendingPathComponent("state", isDirectory: true).appendingPathComponent("runtime.json")
    }

    static func defaults() -> PersistedRuntimeSettings {
        let root = storageRoot
        let logsBase = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return PersistedRuntimeSettings(
            blobEndpoint: nil, azureCliPath: nil, azureCliSubscription: nil,
            container: "photos-backup", prefix: "photos-backup", libraryID: UUID().uuidString,
            spoolDirectory: root.appendingPathComponent("Spool", isDirectory: true).path,
            journalPath: root.appendingPathComponent("state/journal.json").path,
            logPath: logsBase.appendingPathComponent("Logs/PhotosBackup/backup.log").path,
            maxSpoolBytes: 20 * 1024 * 1024 * 1024, blockSize: 8 * 1024 * 1024, maxRetries: 4,
            dailyHour: 2, timeZoneIdentifier: TimeZone.current.identifier, allowInsecureLocalHTTP: false,
            logMaxBytes: 5 * 1024 * 1024, logFileCount: 5)
    }

    static func migrated(from document: ConfigurationDocument) -> PersistedRuntimeSettings {
        let defaults = defaults()
        return PersistedRuntimeSettings(
            blobEndpoint: document.blobEndpoint ?? defaults.blobEndpoint,
            azureCliPath: document.azureCliPath ?? defaults.azureCliPath,
            azureCliSubscription: document.azureCliSubscription ?? defaults.azureCliSubscription,
            container: document.container ?? defaults.container,
            prefix: document.prefix ?? defaults.prefix,
            libraryID: document.libraryID ?? defaults.libraryID,
            spoolDirectory: document.spoolDirectory ?? defaults.spoolDirectory,
            journalPath: document.journalPath ?? defaults.journalPath,
            logPath: document.logPath ?? defaults.logPath,
            maxSpoolBytes: document.maxSpoolBytes ?? defaults.maxSpoolBytes,
            blockSize: document.blockSize ?? defaults.blockSize,
            maxRetries: document.maxRetries ?? defaults.maxRetries,
            dailyHour: document.dailyHour ?? defaults.dailyHour,
            timeZoneIdentifier: document.timeZoneIdentifier ?? defaults.timeZoneIdentifier,
            allowInsecureLocalHTTP: document.allowInsecureLocalHTTP ?? defaults.allowInsecureLocalHTTP,
            logMaxBytes: document.logMaxBytes ?? defaults.logMaxBytes,
            logFileCount: document.logFileCount ?? defaults.logFileCount)
    }

    static func loadOrCreate(from document: ConfigurationDocument) throws -> PersistedRuntimeSettings {
        let url = settingsURL
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw BackupError.invalidConfiguration("could not lock internal Photos Backup settings") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw BackupError.invalidConfiguration("could not lock internal Photos Backup settings") }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BackupError.invalidConfiguration("could not secure internal Photos Backup settings lock")
        }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw BackupError.invalidConfiguration("internal settings must be a regular file, not a symlink")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard mode & 0o077 == 0 else { throw BackupError.invalidConfiguration("internal settings permissions must be 0600 or stricter") }
            do { return try JSONDecoder().decode(PersistedRuntimeSettings.self, from: Data(contentsOf: url)) }
            catch { throw BackupError.invalidConfiguration("could not read internal Photos Backup settings") }
        }
        guard errno == ENOENT else { throw BackupError.invalidConfiguration("could not inspect internal Photos Backup settings") }
        let settings = migrated(from: document)
        try save(settings, to: url)
        return settings
    }

    static func save(_ settings: PersistedRuntimeSettings, to url: URL) throws {
        try ensurePrivateDirectory(url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
            throw BackupError.invalidConfiguration("internal settings output must be a regular file, not a symlink")
        }
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw BackupError.invalidConfiguration("internal settings directory must not be a symlink")
            }
        } else {
            guard errno == ENOENT else { throw BackupError.invalidConfiguration("could not inspect internal settings directory") }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public struct AppConfiguration {
    public var connectionString: String?
    public var authenticationMode: AzureAuthenticationMode?
    public var storageAccountName: String?
    public var blobEndpoint: String?
    public var azureCliPath: String?
    public var azureCliSubscription: String?
    public var container: String
    public var prefix: String
    public var libraryID: String
    public var spoolDirectory: String
    public var journalPath: String
    public var logPath: String
    public var maxSpoolBytes: Int64
    public var blockSize: Int
    public var maxRetries: Int
    public var dailyHour: Int
    public var timeZoneIdentifier: String
    public var allowInsecureLocalHTTP: Bool
    public var logMaxBytes: Int64
    public var logFileCount: Int

    public init(connectionString: String? = nil, container: String, prefix: String = "", libraryID: String = UUID().uuidString,
                spoolDirectory: String, journalPath: String, logPath: String, maxSpoolBytes: Int64 = 20 * 1024 * 1024 * 1024,
                blockSize: Int = 8 * 1024 * 1024, maxRetries: Int = 4, dailyHour: Int = 2,
                timeZoneIdentifier: String = TimeZone.current.identifier, allowInsecureLocalHTTP: Bool = false,
                logMaxBytes: Int64 = 5 * 1024 * 1024, logFileCount: Int = 5,
                authenticationMode: AzureAuthenticationMode? = nil, storageAccountName: String? = nil,
                blobEndpoint: String? = nil, azureCliPath: String? = nil, azureCliSubscription: String? = nil) {
        self.connectionString = connectionString; self.container = container; self.prefix = prefix
        self.authenticationMode = authenticationMode; self.storageAccountName = storageAccountName
        self.blobEndpoint = blobEndpoint; self.azureCliPath = azureCliPath; self.azureCliSubscription = azureCliSubscription
        self.libraryID = libraryID; self.spoolDirectory = spoolDirectory; self.journalPath = journalPath
        self.logPath = logPath; self.maxSpoolBytes = maxSpoolBytes; self.blockSize = blockSize
        self.maxRetries = maxRetries; self.dailyHour = dailyHour; self.timeZoneIdentifier = timeZoneIdentifier
        self.allowInsecureLocalHTTP = allowInsecureLocalHTTP; self.logMaxBytes = logMaxBytes; self.logFileCount = logFileCount
    }

    public func validate() throws {
        guard !container.isEmpty, container.range(of: "^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?$", options: .regularExpression) != nil else {
            throw BackupError.invalidConfiguration("container must be a valid Azure container name")
        }
        guard maxSpoolBytes > 0, (64 * 1024...100 * 1024 * 1024).contains(blockSize), maxRetries >= 0,
              (0...23).contains(dailyHour), logMaxBytes > 0, logFileCount > 0 else {
            throw BackupError.invalidConfiguration("numeric limits are outside their supported range")
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw BackupError.invalidConfiguration("unknown time zone") }
        guard !libraryID.isEmpty else { throw BackupError.invalidConfiguration("libraryID is required") }
        for path in [spoolDirectory, journalPath, logPath] where !(path.hasPrefix("/") || path.hasPrefix("~/")) {
            throw BackupError.invalidConfiguration("spool, journal, and log paths must be absolute or start with ~/ for LaunchAgent use")
        }
        if let azureCliPath, (!azureCliPath.hasPrefix("/") || azureCliPath.isEmpty) {
            throw BackupError.invalidConfiguration("azureCliPath must be an absolute path")
        }
        if let azureCliSubscription, azureCliSubscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BackupError.invalidConfiguration("azureCliSubscription cannot be empty")
        }
        let hasConnectionString = connectionString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasStorageAccount = storageAccountName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard hasConnectionString != hasStorageAccount else {
            throw BackupError.invalidConfiguration("choose exactly one: connectionString or storageAccountName")
        }
        let mode = authenticationMode ?? (hasConnectionString ? .connectionString : .azureCli)
        _ = try AzureCredentials(connectionString: connectionString, storageAccountName: storageAccountName,
                                 blobEndpoint: blobEndpoint, authenticationMode: mode,
                                 allowInsecureLocalHTTP: allowInsecureLocalHTTP)
    }

    public static func load(from url: URL) throws -> AppConfiguration {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw BackupError.invalidConfiguration("config must be a regular file, not a symlink")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else { throw BackupError.invalidConfiguration("config file permissions must be 0600 or stricter: \(url.path)") }
        do {
            let data = try Data(contentsOf: url)
            let document = try JSONDecoder().decode(ConfigurationDocument.self, from: data)
            let authentication = try document.authentication()
            let integrationConfig = ["PHOTOS_BACKUP_RUN_AZURE_CLI", "PHOTOS_BACKUP_RUN_REAL_AZURE", "PHOTOS_BACKUP_RUN_AZURITE"]
                .contains { ProcessInfo.processInfo.environment[$0] == "1" }
            let runtime = integrationConfig ? PersistedRuntimeSettings.migrated(from: document)
                : try PersistedRuntimeSettings.loadOrCreate(from: document)
            let result = AppConfiguration(
                connectionString: authentication.connectionString, container: runtime.container, prefix: runtime.prefix,
                libraryID: runtime.libraryID, spoolDirectory: runtime.spoolDirectory, journalPath: runtime.journalPath,
                logPath: runtime.logPath, maxSpoolBytes: runtime.maxSpoolBytes, blockSize: runtime.blockSize,
                maxRetries: runtime.maxRetries, dailyHour: runtime.dailyHour,
                timeZoneIdentifier: runtime.timeZoneIdentifier, allowInsecureLocalHTTP: runtime.allowInsecureLocalHTTP,
                logMaxBytes: runtime.logMaxBytes, logFileCount: runtime.logFileCount,
                authenticationMode: authentication.mode, storageAccountName: authentication.storageAccountName,
                blobEndpoint: runtime.blobEndpoint, azureCliPath: runtime.azureCliPath,
                azureCliSubscription: runtime.azureCliSubscription)
            try result.validate()
            if !integrationConfig, try needsSimplification(data, authentication: authentication) {
                try result.save(to: url)
            }
            return result
        } catch let error as BackupError { throw error }
        catch { throw BackupError.invalidConfiguration("could not read configuration JSON") }
    }

    public func save(to url: URL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw BackupError.invalidConfiguration("config output must be a regular file, not a symlink")
            }
        }
        let mode = authenticationMode ?? (storageAccountName == nil ? .connectionString : .azureCli)
        let settings = AuthenticationConfiguration(
            connectionString: mode == .connectionString ? connectionString : nil,
            storageAccountName: mode == .azureCli ? storageAccountName : nil)
        let data = try JSONEncoder.pretty.encode(settings)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func needsSimplification(_ data: Data,
                                            authentication: (connectionString: String?, storageAccountName: String?, mode: AzureAuthenticationMode)) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.invalidConfiguration("configuration must be a JSON object")
        }
        let expected = authentication.mode == .connectionString ? "connectionString" : "storageAccountName"
        return Set(object.keys) != Set([expected])
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}

public struct AzureCredentials {
    let accountName: String
    let accountKey: Data?
    let sasRawQuery: String?
    let endpoint: URL
    let authenticationMode: AzureAuthenticationMode

    public init(connectionString: String? = nil, storageAccountName: String? = nil, blobEndpoint: String? = nil,
                authenticationMode: AzureAuthenticationMode = .connectionString,
                allowInsecureLocalHTTP: Bool = false) throws {
        var values: [String: String] = [:]
        for part in (connectionString ?? "").split(separator: ";", omittingEmptySubsequences: true) {
            guard let i = part.firstIndex(of: "=") else { continue }
            values[String(part[..<i])] = String(part[part.index(after: i)...])
        }
        let key = values["AccountKey"].flatMap { Data(base64Encoded: $0) }
        let sas = values["SharedAccessSignature"].map { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("?")
                ? String(raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst())
                : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let endpointText: String
        let name: String
        switch authenticationMode {
        case .connectionString:
            guard let parsedName = values["AccountName"] ?? values["BlobEndpoint"].flatMap(Self.accountNameFromEndpoint),
                  !parsedName.isEmpty, (key != nil && !key!.isEmpty) || (sas != nil && !sas!.isEmpty) else {
                throw BackupError.invalidConfiguration("connectionString authentication requires AccountName and AccountKey or SharedAccessSignature")
            }
            name = parsedName
            if let explicit = values["BlobEndpoint"] { endpointText = explicit }
            else if let suffix = values["EndpointSuffix"] {
                endpointText = "\(values["DefaultEndpointsProtocol"] ?? "https")://\(name).blob.\(suffix)"
            } else { throw BackupError.invalidConfiguration("connectionString authentication requires BlobEndpoint or EndpointSuffix") }
        case .azureCli:
            guard connectionString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
                throw BackupError.invalidConfiguration("omit connectionString when authenticationMode is azureCli; use storageAccountName and blobEndpoint")
            }
            guard key == nil, sas == nil else {
                throw BackupError.invalidConfiguration("omit AccountKey and SAS when authenticationMode is azureCli")
            }
            guard let configuredName = storageAccountName,
                  configuredName.range(of: "^[a-z0-9]{3,24}$", options: .regularExpression) != nil else {
                throw BackupError.invalidConfiguration("azureCli authentication requires a valid storageAccountName")
            }
            name = configuredName
            endpointText = blobEndpoint ?? "https://\(name).blob.core.windows.net"
        }
        guard let endpoint = URL(string: endpointText), let scheme = endpoint.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else { throw BackupError.invalidConfiguration("invalid Azure Blob endpoint") }
        if scheme == "http" {
            let loopback = ["localhost", "127.0.0.1", "::1"].contains(endpoint.host?.lowercased() ?? "")
            guard allowInsecureLocalHTTP && loopback else { throw BackupError.invalidConfiguration("HTTP is allowed only for explicitly enabled loopback development endpoints") }
        }
        let sasQuery: String?
        if key == nil, let sas,
           let parsed = URLComponents(string: "https://placeholder.invalid/?\(sas)"),
           parsed.queryItems?.contains(where: { $0.name == "sig" }) == true, !sas.isEmpty {
            // Keep the signed query exactly as supplied. Parsing and re-encoding it changes
            // reserved '+' escapes in common base64 SAS signatures.
            sasQuery = sas
        } else if key == nil, sas != nil {
            throw BackupError.invalidConfiguration("SharedAccessSignature is malformed")
        } else { sasQuery = nil }
        self.accountName = name; self.accountKey = key; self.sasRawQuery = sasQuery; self.endpoint = endpoint
        self.authenticationMode = authenticationMode
    }

    private static func accountNameFromEndpoint(_ value: String) -> String? {
        guard let url = URL(string: value), let host = url.host else { return nil }
        let first = host.split(separator: ".").first.map(String.init)
        if let first, first != "127", first != "localhost" { return first }
        let pathFirst = url.path.split(separator: "/").first.map(String.init)
        return pathFirst
    }
}

public final class SafeLogger {
    private let url: URL
    private let maxBytes: Int64
    private let count: Int
    private let lock = NSLock()
    private let secrets: [String]

    public init(url: URL, maxBytes: Int64, count: Int, secrets: [String] = []) {
        self.url = url; self.maxBytes = maxBytes; self.count = count; self.secrets = secrets.filter { !$0.isEmpty }
    }
    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERROR", message) }
    private func write(_ level: String, _ input: String) {
        lock.lock(); defer { lock.unlock() }
        var message = input
        for secret in secrets { message = message.replacingOccurrences(of: secret, with: "[REDACTED]") }
        let line = "\(Date().iso8601Fractional) \(level) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (info.st_mode & 0o077) == 0 else {
                    throw BackupError.invalidConfiguration("log must be a private regular file, not a symlink")
                }
            }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? NSNumber)?.int64Value ?? 0 > maxBytes {
                if count > 1 {
                    for i in stride(from: count - 2, through: 1, by: -1) {
                        let old = URL(fileURLWithPath: "\(url.path).\(i)")
                        let next = URL(fileURLWithPath: "\(url.path).\(i + 1)")
                        try? FileManager.default.removeItem(at: next)
                        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.moveItem(at: old, to: next) }
                    }
                    let rotated = URL(fileURLWithPath: "\(url.path).1")
                    try? FileManager.default.removeItem(at: rotated)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: url, to: rotated) }
                } else { try? FileManager.default.removeItem(at: url) }
            }
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
            } else { try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        } catch { fputs("Unable to write backup log\n", stderr) }
    }
}

extension AppConfiguration {
    public func resolve(_ path: String) -> URL { URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL }
    public var resolvedPrefix: String { prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
}
