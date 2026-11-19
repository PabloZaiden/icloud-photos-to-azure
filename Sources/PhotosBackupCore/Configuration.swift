import Foundation
import Darwin

public struct AppConfiguration: Codable {
    public var connectionString: String
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

    public init(connectionString: String, container: String, prefix: String = "", libraryID: String = UUID().uuidString,
                spoolDirectory: String, journalPath: String, logPath: String, maxSpoolBytes: Int64 = 20 * 1024 * 1024 * 1024,
                blockSize: Int = 8 * 1024 * 1024, maxRetries: Int = 4, dailyHour: Int = 2,
                timeZoneIdentifier: String = TimeZone.current.identifier, allowInsecureLocalHTTP: Bool = false,
                logMaxBytes: Int64 = 5 * 1024 * 1024, logFileCount: Int = 5) {
        self.connectionString = connectionString; self.container = container; self.prefix = prefix
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
        _ = try AzureCredentials(connectionString: connectionString, allowInsecureLocalHTTP: allowInsecureLocalHTTP)
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
            let result = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: url))
            try result.validate()
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
        let data = try JSONEncoder.pretty.encode(self)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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

    public init(connectionString: String, allowInsecureLocalHTTP: Bool = false) throws {
        var values: [String: String] = [:]
        for part in connectionString.split(separator: ";", omittingEmptySubsequences: true) {
            guard let i = part.firstIndex(of: "=") else { continue }
            values[String(part[..<i])] = String(part[part.index(after: i)...])
        }
        let key = values["AccountKey"].flatMap { Data(base64Encoded: $0) }
        let sas = values["SharedAccessSignature"].map { raw in
            raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("?")
                ? String(raw.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst())
                : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = values["AccountName"] ?? values["BlobEndpoint"].flatMap(Self.accountNameFromEndpoint), !name.isEmpty,
              (key != nil && !key!.isEmpty) || (sas != nil && !sas!.isEmpty) else {
            throw BackupError.invalidConfiguration("connection string must contain a valid AccountKey or SharedAccessSignature plus BlobEndpoint")
        }
        let endpointText: String
        if let explicit = values["BlobEndpoint"] { endpointText = explicit }
        else if let suffix = values["EndpointSuffix"] {
            endpointText = "\(values["DefaultEndpointsProtocol"] ?? "https")://\(name).blob.\(suffix)"
        } else { throw BackupError.invalidConfiguration("connection string must specify BlobEndpoint or EndpointSuffix") }
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
