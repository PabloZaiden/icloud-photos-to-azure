import XCTest
@testable import PhotosBackupCore

final class SyncCatalogTests: XCTestCase {
    func testDiskCatalogRoundTripsRemoteBlobsAndStreamingPlan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-backup-catalog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = try SyncCatalog(directory: directory)
        let item = BackupItem(libraryID: "library", assetID: "asset", resourceID: "image-public.jpeg",
                              representation: .original, filename: "photo.jpg", uniformType: "public.jpeg",
                              sourceModified: Date(timeIntervalSince1970: 1_700_000_000),
                              creationDate: Date(timeIntervalSince1970: 1_600_000_000),
                              contentType: "image/jpeg", sourceSize: 123, resourceKind: "image")
        let remote = BlobRecord(etag: #""etag""#, size: 456,
                                metadata: ["layout": "photokit-originals-v2", "source_size": "456"])
        defer { catalog.remove() }

        try catalog.beginBatch()
        try catalog.insertBlob(ListedBlob(name: "Originals/asset/image/photo.jpg", record: remote))
        try catalog.append(PlannedPhotoResource(item: item, disposition: .candidate(existing: remote)))
        try catalog.addUndatedAsset("undated-asset")
        try catalog.addUndatedAsset("undated-asset")
        try catalog.commitBatch()

        XCTAssertEqual(try catalog.blob(named: "Originals/asset/image/photo.jpg"), remote)
        XCTAssertNil(try catalog.blob(named: "Originals/missing.jpg"))
        XCTAssertEqual(try catalog.unclassifiableAssetCount(), 1)
        let next = try XCTUnwrap(catalog.nextPlan())
        XCTAssertEqual(next.item, item)
        if case .candidate(let existing) = next.disposition {
            XCTAssertEqual(existing, remote)
        } else {
            XCTFail("Expected the candidate and its existing Azure record to round-trip")
        }
        XCTAssertNil(try catalog.nextPlan())

        catalog.remove()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
}
