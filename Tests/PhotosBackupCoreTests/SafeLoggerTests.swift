import XCTest
@testable import PhotosBackupCore

final class SafeLoggerTests: XCTestCase {
    func testConfiguredCredentialFragmentsAreRedactedFromLogFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-backup-log-\(UUID().uuidString)")
        let logURL = root.appendingPathComponent("logs/run.log")
        let keySentinel = "synthetic-key-should-not-appear"
        let sasSentinel = "synthetic-sas-should-not-appear"
        let logger = SafeLogger(url: logURL, maxBytes: 4096, count: 2, secrets: [keySentinel, sasSentinel])
        logger.error("Azure rejected request: \(keySentinel) \(sasSentinel)")
        let output = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(output.contains(keySentinel))
        XCTAssertFalse(output.contains(sasSentinel))
        XCTAssertTrue(output.contains("[REDACTED]"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: logURL.path)[.posixPermissions] as? NSNumber, 0o600)
    }
}
