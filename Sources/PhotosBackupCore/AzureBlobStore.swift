import Foundation
import CryptoKit

public final class AzureBlobStore: BlobStore {
    private let credentials: AzureCredentials
    private let container: String
    private let prefix: String
    private let session: URLSession
    private let azureCliTokenProvider: AzureCliTokenProvider?
    private let apiVersion = "2023-11-03"

    public init(configuration: AppConfiguration, session: URLSession = .shared) throws {
        try configuration.validate()
        self.credentials = try AzureCredentials(connectionString: configuration.connectionString,
                                                storageAccountName: configuration.storageAccountName,
                                                blobEndpoint: configuration.blobEndpoint,
                                                authenticationMode: configuration.authenticationMode ?? .connectionString,
                                                allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP)
        self.container = configuration.container
        self.prefix = configuration.resolvedPrefix
        self.session = session
        self.azureCliTokenProvider = configuration.authenticationMode == .azureCli
            ? AzureCliTokenProvider(executablePath: configuration.azureCliPath, subscription: configuration.azureCliSubscription)
            : nil
    }

    public func blob(_ name: String) async throws -> BlobRecord? {
        let (response, data) = try await send(method: "HEAD", name: name)
        if response.statusCode == 404 { return nil }
        try ensureSuccess(response, data)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw BackupError.storage("Azure HEAD response omitted ETag") }
        let size = Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "0") ?? 0
        return BlobRecord(etag: etag, size: size, metadata: metadata(from: response))
    }

    public func uncommittedBlockIDs(_ name: String) async throws -> Set<String> {
        let (response, data) = try await send(method: "GET", name: name, query: [("comp", "blocklist"), ("blocklisttype", "uncommitted")])
        if response.statusCode == 404 { return [] }
        try ensureSuccess(response, data)
        let xml = String(decoding: data, as: UTF8.self)
        let pattern = #"<Name>([^<]+)</Name>"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = xml as NSString
        return Set(regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap {
            guard $0.numberOfRanges > 1 else { return nil }
            return ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    public func putBlock(_ name: String, id: String, bytes: Data) async throws {
        let (response, data) = try await send(method: "PUT", name: name, query: [("comp", "block"), ("blockid", id)],
                                              body: bytes, extra: ["Content-Type": "application/octet-stream"])
        try ensureSuccess(response, data)
    }

    public func commit(_ name: String, blockIDs: [String], metadata: [String: String], ifMatch: String?, ifNoneMatch: Bool) async throws -> BlobRecord {
        let entries = blockIDs.map { "<Uncommitted>\($0)</Uncommitted>" }.joined()
        let body = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>\(entries)</BlockList>".utf8)
        var headers = try azureMetadataHeaders(metadata)
        headers["Content-Type"] = "application/xml"
        if let ifMatch { headers["If-Match"] = ifMatch }
        if ifNoneMatch { headers["If-None-Match"] = "*" }
        let (response, data) = try await send(method: "PUT", name: name, query: [("comp", "blocklist")], body: body, extra: headers)
        try ensureSuccess(response, data)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw BackupError.storage("Azure commit response omitted ETag") }
        return BlobRecord(etag: etag, size: 0, metadata: metadata)
    }

    public func setMetadata(_ name: String, metadata: [String: String], ifMatch: String) async throws {
        var headers = try azureMetadataHeaders(metadata); headers["If-Match"] = ifMatch
        let (response, data) = try await send(method: "PUT", name: name, query: [("comp", "metadata")], extra: headers)
        try ensureSuccess(response, data)
    }

    public func publish(_ name: String, metadata: [String: String], ifMatch: String?, ifNoneMatch: Bool) async throws -> BlobRecord {
        var headers = try azureMetadataHeaders(metadata); headers["x-ms-blob-type"] = "BlockBlob"
        if let ifMatch { headers["If-Match"] = ifMatch }
        if ifNoneMatch { headers["If-None-Match"] = "*" }
        let (response, data) = try await send(method: "PUT", name: name, body: Data(), extra: headers)
        try ensureSuccess(response, data)
        guard let etag = response.value(forHTTPHeaderField: "ETag") else { throw BackupError.storage("Azure publish response omitted ETag") }
        return BlobRecord(etag: etag, size: 0, metadata: metadata)
    }

    public func probe(prefix: String) async throws {
        let probePrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = [probePrefix, "probe-\(UUID().uuidString.lowercased())"].filter { !$0.isEmpty }.joined(separator: "/")
        let record = try await publish(name, metadata: ["photos_backup_probe": "1"], ifMatch: nil, ifNoneMatch: true)
        guard let observed = try await blob(name), observed.etag == record.etag,
              observed.metadata["photos_backup_probe"] == "1" else {
            throw BackupError.storage("Azure probe write could not be read back")
        }
        let (response, data) = try await send(method: "DELETE", name: name, extra: ["If-Match": record.etag])
        try ensureSuccess(response, data)
    }

    public func createContainerIfNotExists() async throws {
        let (response, data) = try await send(method: "PUT", name: "", query: [("restype", "container")], includePrefix: false)
        if response.statusCode == 409 { return }
        try ensureSuccess(response, data)
    }

    public func download(_ name: String, maximumBytes: Int64) async throws -> Data {
        if let record = try await blob(name), record.size > maximumBytes {
            throw BackupError.diskBudget(required: record.size, available: maximumBytes)
        }
        let (response, data) = try await send(method: "GET", name: name)
        try ensureSuccess(response, data)
        guard Int64(data.count) <= maximumBytes else { throw BackupError.diskBudget(required: Int64(data.count), available: maximumBytes) }
        return data
    }

    public func delete(_ name: String, ifMatch: String? = nil) async throws {
        var headers: [String: String] = [:]
        if let ifMatch { headers["If-Match"] = ifMatch }
        let (response, data) = try await send(method: "DELETE", name: name, extra: headers)
        try ensureSuccess(response, data)
    }

    private func metadata(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let k = key as? String, k.lowercased().hasPrefix("x-ms-meta-"), let v = value as? String else { continue }
            result[String(k.dropFirst("x-ms-meta-".count)).lowercased()] = v
        }
        return result
    }

    private func azureMetadataHeaders(_ metadata: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            let valid = key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
            guard valid else { throw BackupError.invalidArgument("invalid Azure metadata key") }
            result["x-ms-meta-\(key)"] = value
        }
        return result
    }

    private func send(method: String, name: String, query: [(String, String)] = [], body: Data? = nil,
                      extra: [String: String] = [:], includePrefix: Bool = true) async throws -> (HTTPURLResponse, Data) {
        let fullName = (includePrefix ? [prefix, name] : [name]).filter { !$0.isEmpty }.joined(separator: "/")
        let escaped = ([container] + fullName.split(separator: "/").map(String.init)).map(escapePathSegment).joined(separator: "/")
        var components = URLComponents(url: credentials.endpoint, resolvingAgainstBaseURL: false)!
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, escaped].filter { !$0.isEmpty }.joined(separator: "/")
        let operationQuery: String?
        if !query.isEmpty {
            operationQuery = query.map { "\(escapeQueryComponent($0.0))=\(escapeQueryComponent($0.1))" }.joined(separator: "&")
        } else { operationQuery = nil }
        let queryParts = [components.percentEncodedQuery, credentials.sasRawQuery, operationQuery].compactMap { $0 }.filter { !$0.isEmpty }
        components.percentEncodedQuery = queryParts.isEmpty ? nil : queryParts.joined(separator: "&")
        guard let url = components.url else { throw BackupError.storage("could not form Azure request URL") }
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        let date = DateFormatter.azure.string(from: Date())
        request.setValue(date, forHTTPHeaderField: "x-ms-date")
        request.setValue(apiVersion, forHTTPHeaderField: "x-ms-version")
        for (key, value) in extra { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        if credentials.accountKey != nil {
            request.setValue("SharedKey \(credentials.accountName):\(try signature(request: request, body: body, url: url))", forHTTPHeaderField: "Authorization")
        } else if credentials.authenticationMode == .azureCli {
            guard let azureCliTokenProvider else { throw BackupError.storage("Azure CLI authentication is not available") }
            request.setValue("Bearer \(try azureCliTokenProvider.accessToken())", forHTTPHeaderField: "Authorization")
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw StorageTransportError(error) }
        guard let http = response as? HTTPURLResponse else { throw BackupError.storage("non-HTTP response from Azure") }
        return (http, data)
    }

    private func signature(request: URLRequest, body: Data?, url: URL) throws -> String {
        let method = request.httpMethod ?? "GET"
        func header(_ name: String) -> String { request.value(forHTTPHeaderField: name) ?? "" }
        let contentLength = (body?.count ?? 0) == 0 ? "" : String(body!.count)
        let standard = [method, header("Content-Encoding"), header("Content-Language"), contentLength,
                        header("Content-MD5"), header("Content-Type"), "", header("If-Modified-Since"),
                        header("If-Match"), header("If-None-Match"), header("If-Unmodified-Since"), header("Range")]
        let msHeaders = request.allHTTPHeaderFields?.filter { $0.key.lowercased().hasPrefix("x-ms-") }
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)\n" }.joined() ?? ""
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let resourcePath = encodedPath.hasPrefix("/") ? encodedPath : "/" + encodedPath
        // Shared Key always prefixes the account name, even with path-style emulator URLs
        // whose HTTP path already starts with the account name.
        var canonicalResource = "/\(credentials.accountName)\(resourcePath)"
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = components.queryItems, !items.isEmpty {
            let groups = Dictionary(grouping: items, by: { $0.name.lowercased() })
            for key in groups.keys.sorted() {
                let values = groups[key, default: []].map { $0.value ?? "" }.sorted().joined(separator: ",")
                canonicalResource += "\n\(key):\(values)"
            }
        }
        let stringToSign = standard.joined(separator: "\n") + "\n" + msHeaders + canonicalResource
        guard let key = credentials.accountKey else { throw BackupError.invalidConfiguration("Shared Key is unavailable") }
        let signed = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: key))
        return Data(signed).base64EncodedString()
    }

    private func ensureSuccess(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200...299).contains(response.statusCode) else {
            let rawCode = response.value(forHTTPHeaderField: "x-ms-error-code") ?? ""
            let code = rawCode.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil ? rawCode : "HTTP\(response.statusCode)"
            if response.statusCode == 412 || response.statusCode == 409 { throw BlobConditionFailed(code) }
            if response.statusCode == 408 || response.statusCode == 429 || response.statusCode >= 500 { throw StorageTransientError(code) }
            _ = data
            throw BackupError.storage("Azure rejected request (HTTP\(response.statusCode) \(code))")
        }
    }

    private func escapePathSegment(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? part
    }

    private func escapeQueryComponent(_ part: String) -> String {
        // URLQueryItem leaves some reserved characters, including '+', literal. Azure
        // decodes '+' as a space in block IDs, so encode every non-RFC3986-unreserved byte.
        part.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? part
    }
}

private final class AzureCliTokenProvider {
    private struct CachedToken {
        let value: String
        let refreshAfter: Date
    }

    private let executablePath: String?
    private let subscription: String?
    private let lock = NSLock()
    private var cachedToken: CachedToken?

    init(executablePath: String?, subscription: String?) {
        self.executablePath = executablePath
        self.subscription = subscription
    }

    func accessToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let cachedToken, cachedToken.refreshAfter > Date() { return cachedToken.value }
        let executable = try resolveExecutable()
        let process = Process()
        process.executableURL = executable
        var arguments = ["account", "get-access-token", "--resource", "https://storage.azure.com/"]
        if let subscription, !subscription.isEmpty { arguments += ["--subscription", subscription] }
        arguments += ["--output", "json"]
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch {
            throw BackupError.storage("Azure CLI could not start; configure azureCliPath or install Azure CLI and run az login as this macOS user")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackupError.storage("Azure CLI could not get a Blob Storage token (exit code \(process.terminationStatus)); run az login as this macOS user")
        }
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawToken = response["accessToken"] as? String else {
            throw BackupError.storage("Azure CLI returned an invalid token response; run az login again")
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw BackupError.storage("Azure CLI returned an empty Storage token; run az login again") }
        let now = Date()
        let expiration = Self.expirationDate(in: response) ?? now.addingTimeInterval(30 * 60)
        let refreshAfter = min(expiration.addingTimeInterval(-60), now.addingTimeInterval(45 * 60))
        guard refreshAfter > now else { throw BackupError.storage("Azure CLI returned a Storage token that is about to expire; run az login again") }
        cachedToken = CachedToken(value: token, refreshAfter: refreshAfter)
        return token
    }

    private func resolveExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let executablePath {
            guard fileManager.isExecutableFile(atPath: executablePath) else {
                throw BackupError.storage("Azure CLI executable is not available at azureCliPath")
            }
            return URL(fileURLWithPath: executablePath)
        }
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let searchDirectories = pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("az").path
            if fileManager.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        throw BackupError.storage("Azure CLI executable was not found; install Azure CLI or set azureCliPath")
    }

    private static func expirationDate(in response: [String: Any]) -> Date? {
        for key in ["expires_on", "expiresOnTimestamp"] {
            if let value = response[key] as? NSNumber { return Date(timeIntervalSince1970: value.doubleValue) }
            if let value = response[key] as? String, let timestamp = Double(value) {
                return Date(timeIntervalSince1970: timestamp)
            }
        }
        guard let localDate = response["expiresOn"] as? String else { return nil }
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: localDate) { return date }
        }
        return nil
    }
}

private extension DateFormatter {
    static var azure: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"; return f
    }
}

public struct BlobConditionFailed: Error, CustomStringConvertible { public let description: String; public init(_ description: String) { self.description = description } }
public struct StorageTransientError: Error, CustomStringConvertible { public let description: String; public init(_ description: String) { self.description = description } }
public struct StorageTransportError: Error, CustomStringConvertible {
    public let description: String
    public init(_ error: Error) { description = "network request failed (\(type(of: error)))" }
}
