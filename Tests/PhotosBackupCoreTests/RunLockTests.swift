import XCTest
@testable import PhotosBackupCore

final class RunLockTests: XCTestCase {
    func testExclusiveLockAndRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-backup-lock-\(UUID().uuidString)")
        let file = root.appendingPathComponent("sync.lock")
        try assertHeld(file)
        XCTAssertNoThrow(try RunLock(url: file))
    }

    func testLockDoesNotChangeExistingParentPermissionsOrFollowSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-backup-lock-perms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let lockURL = root.appendingPathComponent("sync.lock")
        let lock = try RunLock(url: lockURL)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: lockURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        withExtendedLifetime(lock) {}

        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let link = root.appendingPathComponent("linked.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RunLock(url: link))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    private func assertHeld(_ file: URL) throws {
        let held = try RunLock(url: file)
        XCTAssertThrowsError(try RunLock(url: file))
        withExtendedLifetime(held) { }
    }
}
