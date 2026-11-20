import XCTest
import CryptoKit
@testable import PhotosBackupCore

final class AzureBlobStoreTests: XCTestCase {
    func testSASPercentEscapesArePreservedAndNoAuthorizationHeaderIsAdded() async throws {
        let sas = "sv=2023-11-03&sp=rwdlac&sr=c&sig=YWJj%2Bdef%2Fghi%3D"
        let config = config(connection: "BlobEndpoint=https://storage.example.test;SharedAccessSignature=\(sas)")
        let session = stubSession(status: 201, headers: ["ETag": "\"etag\""])
        let store = try AzureBlobStore(configuration: config, session: session)
        _ = try await store.publish("probe/item", metadata: ["test": "1"], ifMatch: nil, ifNoneMatch: true)
        let observed = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        XCTAssertTrue(observed.url?.absoluteString.contains("sig=YWJj%2Bdef%2Fghi%3D") == true)
        XCTAssertNil(observed.value(forHTTPHeaderField: "Authorization"))
    }

    func testBinaryBlockIDQueryEscapesPlusSlashAndEquals() async throws {
        let config = config(connection: "AccountName=test;AccountKey=dGVzdA==;BlobEndpoint=https://storage.example.test")
        let store = try AzureBlobStore(configuration: config, session: stubSession(status: 201, headers: [:]))
        let id = Data([251, 255, 0]).base64EncodedString()
        XCTAssertEqual(id, "+/8A")
        try await store.putBlock("binary", id: id, bytes: Data([1, 2, 3]))
        let observed = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        XCTAssertTrue(observed.url?.absoluteString.contains("blockid=%2B%2F8A") == true)
        XCTAssertFalse(observed.url?.absoluteString.contains("blockid=+/8A") == true)
    }

    func testListBlobsPaginatesAndReturnsMetadataAndRelativeNames() async throws {
        let config = config(connection: "AccountName=test;AccountKey=dGVzdA==;BlobEndpoint=https://storage.example.test",
                            prefix: "archive")
        let store = try AzureBlobStore(configuration: config, session: stubSession(status: 200, headers: [:]))
        CapturingURLProtocol.body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults>
          <Blobs>
            <Blob>
              <Name>archive/Originals/asset-one/image/public.jpeg/one.jpg</Name>
              <Properties><Content-Length>123</Content-Length><Etag>&quot;etag-one&quot;</Etag></Properties>
              <Metadata><layout>photokit-originals-v2</layout><source_asset>asset&amp;one</source_asset></Metadata>
            </Blob>
          </Blobs>
          <NextMarker>opaque+marker/=</NextMarker>
        </EnumerationResults>
        """.utf8)

        let first = try await store.listBlobs(prefix: "Originals/")
        XCTAssertEqual(first.blobs.count, 1)
        XCTAssertEqual(first.blobs[0].name, "Originals/asset-one/image/public.jpeg/one.jpg")
        XCTAssertEqual(first.blobs[0].record.etag, #""etag-one""#)
        XCTAssertEqual(first.blobs[0].record.size, 123)
        XCTAssertEqual(first.blobs[0].record.metadata["layout"], "photokit-originals-v2")
        XCTAssertEqual(first.blobs[0].record.metadata["source_asset"], "asset&one")
        XCTAssertEqual(first.continuationToken, "opaque+marker/=")

        let firstRequest = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let firstQuery = URLComponents(url: try XCTUnwrap(firstRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(firstQuery.first(where: { $0.name == "prefix" })?.value, "archive/Originals/")
        XCTAssertEqual(firstQuery.first(where: { $0.name == "include" })?.value, "metadata")
        XCTAssertEqual(firstQuery.first(where: { $0.name == "maxresults" })?.value, "5000")

        CapturingURLProtocol.body = Data("""
        <EnumerationResults>
          <Blobs>
            <Blob>
              <Name>archive/Originals/asset-two/video/public.mpeg-4/two.mp4</Name>
              <Properties><Content-Length>456</Content-Length><Etag>&quot;etag-two&quot;</Etag></Properties>
              <Metadata><SOURCE_SIZE>456</SOURCE_SIZE></Metadata>
            </Blob>
          </Blobs>
          <NextMarker></NextMarker>
        </EnumerationResults>
        """.utf8)
        let second = try await store.listBlobs(prefix: "Originals/", marker: first.continuationToken)
        XCTAssertEqual(second.blobs.map(\.name), ["Originals/asset-two/video/public.mpeg-4/two.mp4"])
        XCTAssertEqual(second.blobs[0].record.metadata["source_size"], "456")
        XCTAssertNil(second.continuationToken)
        let secondRequest = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        let secondQuery = URLComponents(url: try XCTUnwrap(secondRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(secondQuery.first(where: { $0.name == "marker" })?.value, "opaque+marker/=")
        XCTAssertEqual(secondRequest.httpMethod, "GET")
    }

    func testAzureCliUsesBearerTokenFromCurrentSessionAndCachesItInMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("azure-cli-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = root.appendingPathComponent("calls.txt")
        let az = root.appendingPathComponent("az")
        let expectedArguments = "account get-access-token --resource https://storage.azure.com/ --subscription synthetic-subscription --output json"
        let script = """
        #!/bin/sh
        case "$*" in
          '\(expectedArguments)') ;;
          *) exit 91 ;;
        esac
        printf 'called\\n' >> '\(calls.path)'
        printf '%s\\n' '{"accessToken":"synthetic-storage-token","expires_on":4102444800,"tokenType":"Bearer"}'
        """
        try script.write(to: az, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: az.path)
        let config = AppConfiguration(container: "photos-backup-test", prefix: "cli-test", libraryID: "test-library",
                                      spoolDirectory: root.appendingPathComponent("spool").path,
                                      journalPath: root.appendingPathComponent("journal.json").path,
                                      logPath: root.appendingPathComponent("run.log").path,
                                      authenticationMode: .azureCli, storageAccountName: "photostoragetest",
                                      azureCliPath: az.path, azureCliSubscription: "synthetic-subscription")
        let store = try AzureBlobStore(configuration: config, session: stubSession(status: 201, headers: ["ETag": "\"etag\""]))

        _ = try await store.publish("first", metadata: [:], ifMatch: nil, ifNoneMatch: true)
        _ = try await store.publish("second", metadata: [:], ifMatch: nil, ifNoneMatch: true)

        let observed = try XCTUnwrap(CapturingURLProtocol.lastRequest)
        XCTAssertEqual(observed.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-storage-token")
        XCTAssertEqual(observed.url?.host, "photostoragetest.blob.core.windows.net")
        XCTAssertFalse(observed.url?.absoluteString.contains("synthetic-storage-token") == true)
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(whereSeparator: { $0.isNewline }).count, 1)
        XCTAssertNil(config.connectionString)
    }

    func testAzureCliFailureDoesNotExposeCLIStderr() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("azure-cli-failure-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let az = root.appendingPathComponent("az")
        let script = """
        #!/bin/sh
        printf '%s\\n' 'PRIVATE-CLI-DETAIL' >&2
        exit 42
        """
        try script.write(to: az, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: az.path)
        let config = AppConfiguration(container: "photos-backup-test", libraryID: "test-library",
                                      spoolDirectory: root.appendingPathComponent("spool").path,
                                      journalPath: root.appendingPathComponent("journal.json").path,
                                      logPath: root.appendingPathComponent("run.log").path,
                                      authenticationMode: .azureCli, storageAccountName: "photostoragetest",
                                      azureCliPath: az.path)
        let store = try AzureBlobStore(configuration: config, session: stubSession(status: 201, headers: ["ETag": "\"etag\""]))
        do {
            _ = try await store.publish("failure", metadata: [:], ifMatch: nil, ifNoneMatch: true)
            XCTFail("Expected an Azure CLI authentication failure")
        } catch let error as BackupError {
            XCTAssertTrue(error.description.contains("exit code 42"))
            XCTAssertFalse(error.description.contains("PRIVATE-CLI-DETAIL"))
        }
    }

    func testSASAllowsLoopbackHTTPOnlyWhenExplicitlyEnabled() throws {
        XCTAssertNoThrow(try AzureCredentials(connectionString: "BlobEndpoint=http://127.0.0.1:11000/devstoreaccount1;SharedAccessSignature=sv=x&sig=abc",
                                              allowInsecureLocalHTTP: true))
        XCTAssertThrowsError(try AzureCredentials(connectionString: "BlobEndpoint=http://example.com;SharedAccessSignature=sv=x&sig=abc",
                                                  allowInsecureLocalHTTP: true))
        XCTAssertThrowsError(try AzureCredentials(connectionString: "BlobEndpoint=http://127.0.0.1:11000/devstoreaccount1;SharedAccessSignature=sv=x&sig=abc"))
    }

    func test409And412ResponsesBecomeConditionalConflict() async throws {
        for status in [409, 412] {
            let config = config(connection: "AccountName=test;AccountKey=dGVzdA==;BlobEndpoint=https://storage.example.test")
            let store = try AzureBlobStore(configuration: config, session: stubSession(status: status, headers: [:]))
            do {
                _ = try await store.publish("existing", metadata: [:], ifMatch: nil, ifNoneMatch: true)
                XCTFail("Expected HTTP \(status) to be treated as a conditional conflict")
            } catch is BlobConditionFailed { }
        }
    }

    func testAzuriteBlockUploadIsAvailableAsOptInIntegration() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOS_BACKUP_RUN_AZURITE"] == "1" else {
            throw XCTSkip("Set PHOTOS_BACKUP_RUN_AZURITE=1 to run against the local Azurite instance at :11000")
        }
        // This is the well-known public Azurite fixture key, not a production credential.
        // See Microsoft's Azurite connection-string documentation.
        let key = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
        let endpoint = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_AZURITE_ENDPOINT"] ?? "http://127.0.0.1:11000/devstoreaccount1"
        let connection = "DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;AccountKey=\(key);BlobEndpoint=\(endpoint)"
        var config = config(connection: connection, container: "photos-backup-azurite-integration", prefix: "integration-\(UUID().uuidString.lowercased())")
        config.allowInsecureLocalHTTP = true
        let store = try AzureBlobStore(configuration: config)
        try await store.createContainerIfNotExists()
        try await exerciseRealBlocks(store: store, config: config)
    }

    func testPrivateAzureSASBlockUploadIsAvailableAsOptInIntegration() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOS_BACKUP_RUN_REAL_AZURE"] == "1",
              let path = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_INTEGRATION_CONFIG"] else {
            throw XCTSkip("Set PHOTOS_BACKUP_RUN_REAL_AZURE=1 and PHOTOS_BACKUP_INTEGRATION_CONFIG to a private 0600 config for a synthetic-only Azure check")
        }
        let config = try AppConfiguration.load(from: URL(fileURLWithPath: path))
        let store = try AzureBlobStore(configuration: config)
        try await exerciseRealBlocks(store: store, config: config)
    }

    func testAzureCliBlockUploadIsAvailableAsOptInIntegration() async throws {
        guard ProcessInfo.processInfo.environment["PHOTOS_BACKUP_RUN_AZURE_CLI"] == "1",
              let path = ProcessInfo.processInfo.environment["PHOTOS_BACKUP_AZURECLI_INTEGRATION_CONFIG"] else {
            throw XCTSkip("Set PHOTOS_BACKUP_RUN_AZURE_CLI=1 and PHOTOS_BACKUP_AZURECLI_INTEGRATION_CONFIG to a private Azure CLI config for a synthetic-only Azure check")
        }
        let config = try AppConfiguration.load(from: URL(fileURLWithPath: path))
        XCTAssertEqual(config.authenticationMode, .azureCli)
        let store = try AzureBlobStore(configuration: config)
        try await exerciseRealBlocks(store: store, config: config)
    }

    private func exerciseRealBlocks(store firstClient: AzureBlobStore, config: AppConfiguration) async throws {
        let secondClient = try AzureBlobStore(configuration: config)
        let blobName = "swift-integration-\(UUID().uuidString.lowercased())"
        let payload = Data((0..<160_000).map { UInt8(($0 * 31) % 251) })
        let hash = sha256(payload)
        let chunks = stride(from: 0, to: payload.count, by: 64 * 1024).map { offset in
            payload.subdata(in: offset..<min(offset + 64 * 1024, payload.count))
        }
        // Exercise real base64 reserved characters. In particular '+' must remain %2B
        // in the URL query or Azure decodes the block ID as a space.
        let ids = chunks.indices.map { Data([0xfb, 0xff, UInt8($0)]).base64EncodedString() }
        var stage = "initial block list"
        var conditionalBlob: String?
        do {
            stage = "confirm target blob is absent"
            let beforeUpload = try await firstClient.blob(blobName)
            XCTAssertNil(beforeUpload)
            stage = "initial block list"
            let initiallyStaged = try await firstClient.uncommittedBlockIDs(blobName)
            XCTAssertTrue(initiallyStaged.isEmpty)
            stage = "stage first block"
            try await firstClient.putBlock(blobName, id: ids[0], bytes: chunks[0])
            stage = "reconcile block list from a new client"
            let pending = try await secondClient.uncommittedBlockIDs(blobName)
            XCTAssertTrue(pending.contains(ids[0]), "a fresh client should recover the pending block list")
            stage = "upload remaining blocks"
            for index in chunks.indices.dropFirst() { try await secondClient.putBlock(blobName, id: ids[index], bytes: chunks[index]) }
            stage = "commit block list"
            let record = try await secondClient.commit(blobName, blockIDs: ids,
                                                        metadata: ["sha256": hash, "size": String(payload.count), "schema": "1"],
                                                        ifMatch: nil, ifNoneMatch: true)
            let observedResult = try await firstClient.blob(blobName)
            let observed = try XCTUnwrap(observedResult)
            XCTAssertEqual(observed.size, Int64(payload.count))
            XCTAssertEqual(observed.metadata["sha256"], hash)
            stage = "download committed bytes"
            let downloaded = try await secondClient.download(blobName, maximumBytes: 1_000_000)
            XCTAssertEqual(downloaded, payload)

            conditionalBlob = blobName + "-conditional"
            let conditionalETag = try await secondClient.publish(conditionalBlob!, metadata: ["synthetic": "1"], ifMatch: nil, ifNoneMatch: true).etag
            do {
                stage = "conditional create collision"
                _ = try await secondClient.publish(conditionalBlob!, metadata: ["synthetic": "2"], ifMatch: nil, ifNoneMatch: true)
                XCTFail("If-None-Match must preserve an existing blob")
            } catch is BlobConditionFailed { }
            do {
                stage = "stale ETag update"
                try await secondClient.setMetadata(conditionalBlob!, metadata: ["changed": "1"], ifMatch: "\"stale\"")
                XCTFail("If-Match must reject an obsolete ETag")
            } catch is BlobConditionFailed { }
            try await secondClient.delete(conditionalBlob!, ifMatch: conditionalETag)
            conditionalBlob = nil
            try await firstClient.delete(blobName, ifMatch: observed.etag)
            _ = record
        } catch {
            if let record = try? await firstClient.blob(blobName) { try? await firstClient.delete(blobName, ifMatch: record.etag) }
            if let conditionalBlob, let record = try? await firstClient.blob(conditionalBlob) { try? await firstClient.delete(conditionalBlob, ifMatch: record.etag) }
            let reason = (error as? BackupError)?.description ?? String(describing: type(of: error))
            throw BackupError.storage("integration failed during \(stage): \(reason)")
        }
    }

    private func config(connection: String, container: String = "photos-backup-test", prefix: String = "test") -> AppConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("azure-test-\(UUID().uuidString)")
        return AppConfiguration(connectionString: connection, container: container, prefix: prefix, libraryID: "test-library",
                                spoolDirectory: root.appendingPathComponent("spool").path,
                                journalPath: root.appendingPathComponent("journal.json").path,
                                logPath: root.appendingPathComponent("logs/run.log").path,
                                allowInsecureLocalHTTP: connection.contains("http://127.0.0.1") || connection.contains("http://localhost"))
    }

    private func stubSession(status: Int, headers: [String: String]) -> URLSession {
        CapturingURLProtocol.status = status; CapturingURLProtocol.headers = headers
        CapturingURLProtocol.lastRequest = nil; CapturingURLProtocol.body = Data()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CapturingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class CapturingURLProtocol: URLProtocol {
    static var status = 200
    static var headers: [String: String] = [:]
    static var lastRequest: URLRequest?
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
