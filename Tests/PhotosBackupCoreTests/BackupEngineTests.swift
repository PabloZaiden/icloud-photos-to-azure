import XCTest
import CryptoKit
@testable import PhotosBackupCore

final class BackupEngineTests: XCTestCase {
    func testInterruptedResourceResumesOnlyMissingBlocksAndKeepsCompletedResource() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let bytesA = Data(repeating: 0x41, count: 16 * 1024)
        let bytesB = Data((0..<256 * 1024).map { UInt8($0 % 251) })
        let a = context.item(asset: "asset-a")
        let b = context.item(asset: "asset-b")
        context.library.set(a, data: bytesA); context.library.set(b, data: bytesB)
        context.store.failPutCall = 3 // after asset A and the first block of B

        let first = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(first.uploaded, 1)
        XCTAssertEqual(first.failed, 1)
        XCTAssertEqual(first.bytesTransferred, Int64(bytesA.count + 64 * 1024))
        XCTAssertNotNil(context.store.blobs[a.blobName])
        XCTAssertNil(context.store.blobs[b.blobName])

        let second = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(second.uploaded, 1)
        XCTAssertEqual(second.resumed, 1)
        XCTAssertEqual(second.failed, 0)
        XCTAssertEqual(second.bytesTransferred, Int64(bytesB.count - 64 * 1024))
        XCTAssertEqual(second.bytesReused, 64 * 1024)
        XCTAssertEqual(context.library.exportCount[a.id], 1)
        XCTAssertEqual(context.library.exportCount[b.id], 1)
        let record = try XCTUnwrap(context.store.blobs[b.objectName(hash: sha256(bytesB))])
        XCTAssertEqual(record.data, bytesB)
        XCTAssertEqual(record.metadata["sha256"], sha256(bytesB))

        let third = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(third.skipped, 2)
        XCTAssertEqual(third.uploaded, 0)
        XCTAssertEqual(third.bytesTransferred, 0)
        XCTAssertEqual(context.library.exportCount[b.id], 1)
    }

    func testLostCommitResponseIsResolvedByHeadWithoutReupload() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "lost-commit")
        let data = Data(repeating: 7, count: 100_000)
        context.library.set(item, data: data)
        context.store.loseNextCommitResponse = true

        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(context.store.blobs[item.objectName(hash: sha256(data))]?.data, data)
        XCTAssertEqual(context.library.exportCount[item.id], 1)
        XCTAssertTrue(context.store.blocks[item.objectName(hash: sha256(data))]?.isEmpty ?? true)
    }

    func testChangingBlockSizeKeepsPersistedSegmentationForPendingSpool() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "resegment")
        let data = Data((0..<256 * 1024).map { UInt8(($0 * 7) % 253) })
        context.library.set(item, data: data)
        context.store.failPutCall = 2 // retain one block, stop before next block
        let first = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(first.failed, 1)
        let name = item.objectName(hash: sha256(data))
        let previousIDs = Set(context.store.blocks[name, default: [:]].keys)
        XCTAssertEqual(previousIDs.count, 1)

        let second = try await context.engine(blockSize: 96 * 1024).sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(second.failed, 0)
        XCTAssertEqual(second.resumed, 1)
        XCTAssertEqual(second.bytesReused, 64 * 1024)
        XCTAssertEqual(second.bytesTransferred, Int64(data.count - 64 * 1024))
        XCTAssertEqual(context.store.blobs[item.objectName(hash: sha256(data))]?.data, data)
        XCTAssertFalse(previousIDs.isDisjoint(with: context.store.lastCommittedBlockIDs))
        XCTAssertEqual(context.library.exportCount[item.id], 1)
    }

    func testNewExportUsesChangedBlockSizeWhilePendingExportKeepsOldSize() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "new-segmentation")
        let data = Data(repeating: 0x66, count: 256 * 1024)
        context.library.set(item, data: data)
        context.store.failPutCall = 2
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        _ = try await context.engine(blockSize: 96 * 1024).sync(filter: context.unfiltered, dryRun: false)
        let next = context.item(asset: "future-segmentation")
        let nextData = Data(repeating: 0x77, count: 256 * 1024)
        context.library.set(next, data: nextData)
        _ = try await context.engine(blockSize: 96 * 1024).sync(filter: context.unfiltered, dryRun: false)
        let firstID = try XCTUnwrap(context.store.lastCommittedBlockIDs.first)
        let raw = try XCTUnwrap(Data(base64Encoded: firstID))
        let encodedBlockSize = raw[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(encodedBlockSize, UInt32(96 * 1024))
    }

    func testDryRunDoesNotUpdateFilenameMetadataOrErasePendingJournal() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let completed = context.item(asset: "complete", filename: "old-name.jpg")
        let bytes = Data("already backed up".utf8)
        context.library.set(completed, data: bytes)
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        let originalManifest = try XCTUnwrap(context.store.blobs[completed.blobName])

        let pending = context.item(asset: "pending")
        context.library.set(pending, data: Data(repeating: 8, count: 200_000))
        context.store.failPutCall = context.store.putCallCount + 1
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        let journalBefore = try Data(contentsOf: context.config.resolve(context.config.journalPath))

        var renamed = completed
        renamed = BackupItem(libraryID: completed.libraryID, assetID: completed.assetID, resourceID: completed.resourceID,
                             representation: completed.representation, filename: "new-name.jpg", uniformType: completed.uniformType,
                             sourceModified: completed.sourceModified, creationDate: completed.creationDate,
                             contentType: completed.contentType, resourceKind: completed.resourceKind)
        context.library.replaceItem(renamed, data: bytes)
        let dry = try await context.engine().sync(filter: context.unfiltered, dryRun: true)
        XCTAssertGreaterThanOrEqual(dry.wouldUpload, 1)
        XCTAssertEqual(dry.pending, 0)
        XCTAssertEqual(context.store.blobs[completed.blobName]?.metadata, originalManifest.metadata)
        XCTAssertEqual(try Data(contentsOf: context.config.resolve(context.config.journalPath)), journalBefore)
        XCTAssertNotNil(context.store.blobs[completed.blobName])
    }

    func testRevertingCurrentRepresentationReusesOriginalContentObject() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let original = context.item(asset: "live", resource: "image-abc", representation: .original)
        let current = context.item(asset: "live", resource: "current-image", representation: .current)
        let oldBytes = Data("original bytes".utf8)
        let editBytes = Data("edited bytes".utf8)
        context.library.set(original, data: oldBytes); context.library.set(current, data: editBytes)
        let first = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(first.uploaded, 2)
        XCTAssertEqual(first.bytesTransferred, Int64(oldBytes.count + editBytes.count))
        let priorEditManifest = try XCTUnwrap(context.store.blobs[current.blobName])

        let reverted = BackupItem(libraryID: current.libraryID, assetID: current.assetID, resourceID: current.resourceID,
                                  representation: .current, filename: current.filename, uniformType: current.uniformType,
                                  sourceModified: current.sourceModified!.addingTimeInterval(10), creationDate: current.creationDate,
                                  contentType: current.contentType, resourceKind: current.resourceKind)
        context.library.replaceItem(reverted, data: oldBytes)
        let second = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(second.bytesTransferred, 0)
        XCTAssertGreaterThanOrEqual(second.bytesReused, Int64(oldBytes.count))
        let currentManifest = try XCTUnwrap(context.store.blobs[current.blobName])
        XCTAssertEqual(currentManifest.metadata["sha256"], sha256(oldBytes))
        XCTAssertEqual(currentManifest.metadata["object_name"], original.objectName(hash: sha256(oldBytes)))
        XCTAssertNotEqual(currentManifest.metadata["sha256"], priorEditManifest.metadata["sha256"])
        XCTAssertEqual(context.store.blobs.count(where: { $0.key.hasPrefix("objects/") }), 2)
    }

    func testNullSourceDateIsRehashedEveryRun() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "no-date", date: nil)
        context.library.set(item, data: Data("no date".utf8))
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        let second = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(context.library.exportCount[item.id], 2)
        XCTAssertEqual(second.bytesTransferred, 0)
        XCTAssertEqual(second.bytesReused, 7)
    }

    func testMissingObjectForNewerManifestIsNotReportedAsBackedUp() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let older = context.item(asset: "missing-newer")
        let bytes = Data("data".utf8)
        context.library.set(older, data: bytes)
        let newer = older.sourceModified!.addingTimeInterval(100)
        context.store.seedManifest(older, hash: sha256(bytes), objectName: older.objectName(hash: sha256(bytes)), sourceDate: newer)
        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.skipped, 0)
    }

    func testChangedSourceDoesNotMixStagedBlocksFromOldHash() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "changed")
        let oldData = Data(repeating: 3, count: 256 * 1024)
        let newData = Data(repeating: 4, count: 256 * 1024)
        context.library.set(item, data: oldData)
        context.store.failPutCall = 2
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        let updated = BackupItem(libraryID: item.libraryID, assetID: item.assetID, resourceID: item.resourceID,
                                 representation: item.representation, filename: item.filename, uniformType: item.uniformType,
                                 sourceModified: item.sourceModified!.addingTimeInterval(1), creationDate: item.creationDate,
                                 contentType: item.contentType, resourceKind: item.resourceKind)
        context.library.replaceItem(updated, data: newData)
        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(context.store.blobs[updated.objectName(hash: sha256(newData))]?.data, newData)
        XCTAssertEqual(context.store.blobs[item.blobName]?.metadata["sha256"], sha256(newData))
    }

    func testLostJournalDiscardsOrphanSpoolButReusesAzureBlocks() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "lost-journal")
        let data = Data(repeating: 0x5a, count: 192 * 1024)
        context.library.set(item, data: data); context.store.failPutCall = 2
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        let path = context.config.resolve(context.config.journalPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        try FileManager.default.removeItem(at: path)

        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.bytesReused, 64 * 1024)
        XCTAssertEqual(summary.bytesTransferred, Int64(data.count - 64 * 1024))
        XCTAssertEqual(context.library.exportCount[item.id], 2)
        XCTAssertEqual(context.store.blobs[item.objectName(hash: sha256(data))]?.data, data)
        let managedSpool = context.root.appendingPathComponent("spool/.photos-backup-spool-v1")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: managedSpool, includingPropertiesForKeys: nil).isEmpty)
    }

    func testCorruptSpoolIsReexportedAndNeverCommittedAsMixedContent() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "corrupt-spool")
        let data = Data((0..<192 * 1024).map { UInt8($0 % 239) })
        context.library.set(item, data: data); context.store.failPutCall = 2
        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        let journal = try JSONSerialization.jsonObject(with: Data(contentsOf: context.config.resolve(context.config.journalPath))) as! [String: Any]
        let entry = (journal["entries"] as! [String: Any])[item.id] as! [String: Any]
        let spoolPath = entry["spoolPath"] as! String
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: spoolPath))

        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(context.store.blobs[item.objectName(hash: sha256(data))]?.data, data)
        XCTAssertEqual(context.library.exportCount[item.id], 2)
    }

    func testCorruptJournalRecoveryIsConservativeAndDryRunDoesNotModifyIt() async throws {
        let context = try TestContext(blockSize: 64 * 1024)
        let item = context.item(asset: "bad-journal")
        context.library.set(item, data: Data("synthetic".utf8))
        let journalURL = context.config.resolve(context.config.journalPath)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        let orphan = context.config.resolve(context.config.spoolDirectory).appendingPathComponent("orphan.spool")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: orphan)

        _ = try await context.engine().sync(filter: context.unfiltered, dryRun: true)
        XCTAssertEqual(try Data(contentsOf: journalURL), Data("not json".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path), "foreign spool-like files outside the managed namespace must be preserved")
        let quarantined = try FileManager.default.contentsOfDirectory(at: journalURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertTrue(quarantined.contains { $0.lastPathComponent.hasPrefix("journal.json.corrupt-") })
        XCTAssertEqual(context.store.blobs[item.objectName(hash: sha256(Data("synthetic".utf8)))]?.data, Data("synthetic".utf8))
    }

    func testSpoolBudgetStopsExportBeforeItExceedsConfiguredLimit() async throws {
        let context = try TestContext(blockSize: 64 * 1024, maxSpoolBytes: 32 * 1024)
        let item = context.item(asset: "over-budget")
        context.library.set(item, data: Data(repeating: 1, count: 64 * 1024))
        let summary = try await context.engine().sync(filter: context.unfiltered, dryRun: false)
        XCTAssertEqual(summary.failed, 1)
        let spool = context.config.resolve(context.config.spoolDirectory).appendingPathComponent(".photos-backup-spool-v1")
        let files = try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertTrue(files.isEmpty)
        XCTAssertNil(context.store.blobs[item.blobName])
    }

    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension BackupEngineTests {
    func testReviewRoundedDateRepair() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let i = c.item(asset: "review-rounded-date", date: Date(timeIntervalSince1970: 1_700_000_000.123555))
        let data = Data([88])
        c.library.set(i, data: data)
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        c.store.drop(i.objectName(hash: sha256(data)))
        let run = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(run.failed, 0, "a missing object for the same fractional source version must be repaired")
        XCTAssertNotNil(c.store.blobs[i.objectName(hash: sha256(data))])
    }

    func testReviewLegacyRoundedDateRepairAndRename() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let i = c.item(asset: "review-legacy-rounded", date: Date(timeIntervalSince1970: 1_700_000_000.123555))
        let data = Data([19, 20, 21])
        c.library.set(i, data: data)
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        let manifest = try XCTUnwrap(c.store.blobs[i.blobName])
        var legacy = manifest.metadata
        legacy["source_modified"] = i.sourceModified!.iso8601Fractional
        c.store.blobs[i.blobName] = .init(data: manifest.data, metadata: legacy, etag: UUID().uuidString)
        c.store.drop(i.objectName(hash: sha256(data)))
        let renamed = BackupItem(libraryID: i.libraryID, assetID: i.assetID, resourceID: i.resourceID,
                                 representation: i.representation, filename: "renamed.jpg", uniformType: i.uniformType,
                                 sourceModified: i.sourceModified, creationDate: i.creationDate,
                                 contentType: i.contentType, resourceKind: i.resourceKind)
        c.library.replaceItem(renamed, data: data)
        let run = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(run.failed, 0, "legacy millisecond rounding must not classify the same version as newer")
        XCTAssertEqual(c.store.blobs[renamed.blobName]?.metadata["filename_b64"], Data("renamed.jpg".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
        XCTAssertEqual(c.store.blobs[i.objectName(hash: sha256(data))]?.data, data)
        XCTAssertEqual(c.store.blobs[renamed.blobName]?.metadata["source_modified"], i.sourceModified?.versionToken)
    }

    func testReviewNullPendingBytesAreReexportedBeforeResume() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let item = c.item(asset: "review-null-pending", date: nil)
        let old = Data(repeating: 5, count: 120_000)
        let current = Data(repeating: 7, count: 120_000)
        c.library.set(item, data: old)
        c.store.failPutCall = 2
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        c.library.replaceItem(item, data: current)
        let run = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(run.failed, 0)
        XCTAssertEqual(c.store.blobs[item.blobName]?.metadata["sha256"], sha256(current))
        XCTAssertEqual(c.store.blobs[item.objectName(hash: sha256(current))]?.data, current)
    }

    func testReviewKnownRemoteVersionSurvivesNullInputAndProtectsNextChange() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let dated = c.item(asset: "review-known-date")
        let undated = c.item(asset: "review-known-date", date: nil)
        let original = Data([44])
        c.library.set(dated, data: original)
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        c.library.set(undated, data: original)
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(c.store.blobs[dated.blobName]?.metadata["source_modified"], dated.sourceModified?.versionToken)
        c.library.set(undated, data: Data([55]))
        let changed = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(changed.failed, 1, "a null source date cannot replace a known remote version with different bytes")
        XCTAssertEqual(c.store.blobs[dated.blobName]?.metadata["sha256"], sha256(original))
    }

    func testReviewDeletedPendingSpoolCompletesAsHistoricalArchiveAndReleasesBudget() async throws {
        let c = try TestContext(blockSize: 64 * 1024, maxSpoolBytes: 128 * 1024)
        let old = c.item(asset: "review-removed")
        let oldData = Data(repeating: 7, count: 128 * 1024)
        c.library.set(old, data: oldData)
        c.store.failPutCall = 2
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        c.library.drop(old)
        let fresh = c.item(asset: "review-new")
        c.library.set(fresh, data: Data([1]))
        for _ in 0..<3 { _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false) }
        XCTAssertNotNil(c.store.blobs[fresh.blobName])
        let oldHash = sha256(oldData)
        XCTAssertEqual(c.store.blobs[old.objectName(hash: oldHash)]?.data, oldData,
                       "the complete pending snapshot must remain recoverable after the asset disappears")
        let archive = c.store.blobs.first { $0.key.hasPrefix("archives/") && $0.value.metadata["sha256"] == oldHash }
        XCTAssertEqual(archive?.value.metadata["source_state"], "absent-from-complete-inventory")
    }

    func testFilteredOrFailedInventoryDoesNotReconcileAbsentSpool() async throws {
        let c = try TestContext(blockSize: 64 * 1024, maxSpoolBytes: 256 * 1024)
        let pending = c.item(asset: "outside-range", date: Date(timeIntervalSince1970: 1_500_000_000))
        c.library.set(pending, data: Data(repeating: 9, count: 128 * 1024))
        c.store.failPutCall = 2
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        c.library.drop(pending)
        let recent = try DateFilter(from: "2024-01-01", to: nil, timeZone: TimeZone(secondsFromGMT: 0)!)
        _ = try await c.engine().sync(filter: recent, dryRun: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.config.resolve(c.config.journalPath).path))
        XCTAssertFalse(c.store.blobs.keys.contains { $0.hasPrefix("archives/") })
        c.library.failEnumeration = true
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertFalse(c.store.blobs.keys.contains { $0.hasPrefix("archives/") }, "a failed inventory cannot prove absence")
    }

    func testRenderedFormatDescriptorIsStoredSeparatelyAndSurvivesSkipAndRename() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let source = BackupItem(libraryID: c.config.libraryID, assetID: "rendered-format", resourceID: "current-image",
                                representation: .current, filename: "camera-original.heic", uniformType: "public.heic",
                                sourceModified: Date(timeIntervalSince1970: 1_700_000_000), creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                                contentType: "image/heic", resourceKind: "image")
        let rendered = ExportDescriptor(filename: "rendered-current.jpg", uniformType: "public.jpeg", contentType: "image/jpeg")
        let bytes = Data("synthetic JPEG render".utf8)
        c.library.set(source, data: bytes, descriptor: rendered)
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        var manifest = try XCTUnwrap(c.store.blobs[source.blobName])
        func encoded(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        XCTAssertEqual(manifest.metadata["filename_b64"], encoded(source.filename))
        XCTAssertEqual(manifest.metadata["uniform_type_b64"], encoded(source.uniformType))
        XCTAssertEqual(manifest.metadata["export_filename_b64"], encoded(rendered.filename))
        XCTAssertEqual(manifest.metadata["export_uniform_type_b64"], encoded(rendered.uniformType))
        XCTAssertEqual(manifest.metadata["content_type"], "image/jpeg")
        let second = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(second.skipped, 1)
        XCTAssertEqual(c.library.exportCount[source.id], 1)

        let renamed = BackupItem(libraryID: source.libraryID, assetID: source.assetID, resourceID: source.resourceID,
                                representation: source.representation, filename: "renamed-original.heic", uniformType: source.uniformType,
                                sourceModified: source.sourceModified, creationDate: source.creationDate,
                                contentType: source.contentType, resourceKind: source.resourceKind)
        c.library.replaceItem(renamed, data: bytes, descriptor: rendered)
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        manifest = try XCTUnwrap(c.store.blobs[renamed.blobName])
        XCTAssertEqual(manifest.metadata["filename_b64"], encoded(renamed.filename))
        XCTAssertEqual(manifest.metadata["export_filename_b64"], encoded(rendered.filename))
        XCTAssertEqual(manifest.metadata["uniform_type_b64"], encoded(renamed.uniformType))
        XCTAssertEqual(manifest.metadata["content_type"], "image/jpeg")
    }

    func testConfiguredParentPermissionsAndForeignSpoolFilesArePreserved() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let parent = c.root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        var config = c.config
        config.spoolDirectory = parent.appendingPathComponent("Spool").path
        config.journalPath = parent.appendingPathComponent("journal.json").path
        config.logPath = parent.appendingPathComponent("run.log").path
        let logger = SafeLogger(url: config.resolve(config.logPath), maxBytes: config.logMaxBytes, count: config.logFileCount)
        let item = c.item(asset: "filesystem")
        c.library.set(item, data: Data("ok".utf8))
        let lock = try RunLock(url: parent.appendingPathComponent("sync.lock"))
        let foreign = parent.appendingPathComponent("someone-elses.spool")
        try Data("keep".utf8).write(to: foreign)
        let engine = try BackupEngine(configuration: config, library: c.library, store: c.store, logger: logger)
        _ = await engine.sync(filter: c.unfiltered, dryRun: false)
        withExtendedLifetime(lock) {}
        let mode = try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755, "configured parent directories must not be chmodded")
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep".utf8))
    }

    func testTamperedJournalSpoolPathCannotReadOrDeleteOutsideFile() async throws {
        let c = try TestContext(blockSize: 64 * 1024)
        let item = c.item(asset: "tampered-path")
        let data = Data(repeating: 0x31, count: 128 * 1024)
        c.library.set(item, data: data); c.store.failPutCall = 2
        _ = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        let outside = c.root.appendingPathComponent("foreign.spool")
        try Data("protected marker".utf8).write(to: outside)
        let journalURL = c.config.resolve(c.config.journalPath)
        var journal = try JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as! [String: Any]
        var entries = journal["entries"] as! [String: [String: Any]]
        entries[item.id]!["spoolPath"] = outside.path
        journal["entries"] = entries
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        let run = try await c.engine().sync(filter: c.unfiltered, dryRun: false)
        XCTAssertEqual(run.failed, 0)
        XCTAssertEqual(try Data(contentsOf: outside), Data("protected marker".utf8))
        XCTAssertEqual(c.store.blobs[item.objectName(hash: sha256(data))]?.data, data)
    }
}

private struct TestContext {
    let root: URL
    let config: AppConfiguration
    let library = FixtureLibrary()
    let store = MemoryBlobStore()
    let unfiltered = try! DateFilter(from: nil, to: nil, timeZone: TimeZone(secondsFromGMT: 0)!)
    init(blockSize: Int, maxSpoolBytes: Int64 = 64 * 1024 * 1024) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photos-backup-test-\(UUID().uuidString)")
        let key = Data("local-test-key".utf8).base64EncodedString()
        config = AppConfiguration(connectionString: "AccountName=unit;AccountKey=\(key);BlobEndpoint=https://unit.example.invalid",
                                  container: "photos-backup-test", prefix: "test", libraryID: "library-unit",
                                  spoolDirectory: root.appendingPathComponent("spool").path,
                                  journalPath: root.appendingPathComponent("state/journal.json").path,
                                  logPath: root.appendingPathComponent("logs/run.log").path,
                                  maxSpoolBytes: maxSpoolBytes, blockSize: blockSize, maxRetries: 0)
        try config.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func engine(blockSize: Int? = nil) throws -> BackupEngine {
        var selected = config
        if let blockSize { selected.blockSize = blockSize }
        let logger = SafeLogger(url: selected.resolve(selected.logPath), maxBytes: selected.logMaxBytes, count: selected.logFileCount)
        return try BackupEngine(configuration: selected, library: library, store: store, logger: logger)
    }
    func item(asset: String, resource: String = "image-abcd", representation: Representation = .original,
              filename: String = "photo.jpg", date: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> BackupItem {
        BackupItem(libraryID: config.libraryID, assetID: asset, resourceID: resource, representation: representation,
                   filename: filename, uniformType: "public.jpeg", sourceModified: date, creationDate: date,
                   contentType: "image/jpeg", resourceKind: representation == .current ? "image" : "image")
    }
}

private final class FixtureLibrary: PhotoLibrary {
    private(set) var items: [String: BackupItem] = [:]
    private(set) var files: [String: Data] = [:]
    private(set) var exportCount: [String: Int] = [:]
    private(set) var descriptors: [String: ExportDescriptor] = [:]
    var failEnumeration = false
    func set(_ item: BackupItem, data: Data, descriptor: ExportDescriptor? = nil) {
        items[item.id] = item; files[item.id] = data; descriptors[item.id] = descriptor ?? ExportDescriptor(item: item)
    }
    func replaceItem(_ item: BackupItem, data: Data, descriptor: ExportDescriptor? = nil) { set(item, data: data, descriptor: descriptor) }
    func authorization() -> String { "authorized" }
    func requestAuthorization() async -> String { "authorized" }
    func enumerate(filter: DateFilter, consume: (BackupItem) async throws -> Void) async throws {
        if failEnumeration { throw BackupError.storage("injected inventory failure") }
        for item in items.values.sorted(by: { $0.id < $1.id }) where item.creationDate == nil || filter.includes(item.creationDate) {
            try await consume(item)
        }
    }
    func export(_ item: BackupItem, to destination: URL, maximumBytes: Int64) async throws -> ExportDescriptor {
        guard let data = files[item.id] else { throw BackupError.integrity("fixture missing") }
        guard Int64(data.count) <= maximumBytes else { throw BackupError.diskBudget(required: Int64(data.count), available: maximumBytes) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic); exportCount[item.id, default: 0] += 1
        return descriptors[item.id] ?? ExportDescriptor(item: item)
    }
    func verify(_ item: BackupItem) async throws {
        guard items[item.id]?.sourceModified == item.sourceModified else { throw BackupError.conflict("fixture source changed") }
    }
}

private final class MemoryBlobStore: BlobStore {
    struct Stored { var data: Data; var metadata: [String: String]; var etag: String }
    var blobs: [String: Stored] = [:]
    var blocks: [String: [String: Data]] = [:]
    var putCallCount = 0
    var failPutCall: Int?
    var loseNextCommitResponse = false
    var lastCommittedBlockIDs = Set<String>()

    func drop(_ name: String) { blobs.removeValue(forKey: name) }

    func blob(_ name: String) async throws -> BlobRecord? {
        guard let blob = blobs[name] else { return nil }
        return BlobRecord(etag: blob.etag, size: Int64(blob.data.count), metadata: blob.metadata)
    }
    func uncommittedBlockIDs(_ name: String) async throws -> Set<String> { Set(blocks[name, default: [:]].keys) }
    func putBlock(_ name: String, id: String, bytes: Data) async throws {
        putCallCount += 1
        if failPutCall == putCallCount { failPutCall = nil; throw StorageTransportError(NSError(domain: "Injected", code: 1)) }
        blocks[name, default: [:]][id] = bytes
    }
    func commit(_ name: String, blockIDs: [String], metadata: [String: String], ifMatch: String?, ifNoneMatch: Bool) async throws -> BlobRecord {
        try checkConditions(name, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        var data = Data()
        for id in blockIDs {
            guard let block = blocks[name]?[id] else { throw BackupError.integrity("missing staged block") }
            data.append(block)
        }
        let etag = UUID().uuidString
        blobs[name] = Stored(data: data, metadata: metadata, etag: etag)
        lastCommittedBlockIDs = Set(blockIDs)
        blocks[name] = [:]
        if loseNextCommitResponse { loseNextCommitResponse = false; throw StorageTransportError(NSError(domain: "Injected", code: 2)) }
        return BlobRecord(etag: etag, size: Int64(data.count), metadata: metadata)
    }
    func setMetadata(_ name: String, metadata: [String: String], ifMatch: String) async throws {
        guard var blob = blobs[name], blob.etag == ifMatch else { throw BlobConditionFailed("HTTP412") }
        blob.metadata = metadata; blob.etag = UUID().uuidString; blobs[name] = blob
    }
    func publish(_ name: String, metadata: [String: String], ifMatch: String?, ifNoneMatch: Bool) async throws -> BlobRecord {
        try checkConditions(name, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch)
        let blob = Stored(data: Data(), metadata: metadata, etag: UUID().uuidString); blobs[name] = blob
        return BlobRecord(etag: blob.etag, size: 0, metadata: metadata)
    }
    func probe(prefix: String) async throws { }
    func seedManifest(_ item: BackupItem, hash: String, objectName: String, sourceDate: Date) {
        blobs[item.blobName] = Stored(data: Data(), metadata: ["schema": "1", "identity_hash": SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined(),
            "representation": item.representation.rawValue, "source_modified": sourceDate.iso8601Fractional, "sha256": hash,
            "size": "4", "object_name": objectName], etag: UUID().uuidString)
    }
    private func checkConditions(_ name: String, ifMatch: String?, ifNoneMatch: Bool) throws {
        if ifNoneMatch && blobs[name] != nil { throw BlobConditionFailed("HTTP409") }
        if let ifMatch, blobs[name]?.etag != ifMatch { throw BlobConditionFailed("HTTP412") }
    }
}

private extension FixtureLibrary {
    func drop(_ item: BackupItem) {
        items.removeValue(forKey: item.id); files.removeValue(forKey: item.id); descriptors.removeValue(forKey: item.id)
    }
}
