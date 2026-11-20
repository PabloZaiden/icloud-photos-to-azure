import Foundation
import Darwin

public final class OriginalsMirror {
    private struct Transfer {
        let sent: Int64
        let reused: Int64
        let resumed: Bool
    }

    private enum Outcome {
        case skipped(reason: String, size: Int64?)
        case uploaded(Transfer, size: Int64)
    }

    private final class SummaryAccumulator {
        var value = RunSummary()
    }

    private let library: PhotoKitLibrary
    private let configuration: AppConfiguration
    private let store: AzureBlobStore
    private let logger: SafeLogger
    private let spoolRoot: URL

    public init(library: PhotoKitLibrary, configuration: AppConfiguration,
                store: AzureBlobStore, logger: SafeLogger) throws {
        try configuration.validate()
        let root = configuration.resolve(configuration.spoolDirectory)
            .appendingPathComponent(".photokit-originals-v2", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              chmod(root.path, mode_t(0o700)) == 0,
              FileManager.default.isWritableFile(atPath: root.path) else {
            throw BackupError.permission("the private Photos export directory is not writable")
        }
        self.library = library
        self.configuration = configuration
        self.store = store
        self.logger = logger
        self.spoolRoot = root.resolvingSymlinksInPath().standardizedFileURL
    }

    public func sync(filter: DateFilter, dryRun: Bool) async -> RunSummary {
        let progress = SummaryAccumulator()
        progress.value.dryRun = dryRun
        let runStarted = Date()
        logger.info("SYNC_START dry_run=\(dryRun) from=\(filter.from?.iso8601Fractional ?? "none") until_exclusive=\(filter.untilExclusive?.iso8601Fractional ?? "none")")

        let catalog: SyncCatalog
        do {
            catalog = try SyncCatalog(directory: spoolRoot)
        } catch {
            progress.value.failed += 1
            logger.error("SYNC_CATALOG_CREATE_FAILED error=\(String(describing: error))")
            logSyncEnd(progress.value, candidates: 0, unclassified: 0, started: runStarted)
            return progress.value
        }
        defer { catalog.remove() }

        let azureInventory: (blobs: Int, pages: Int)
        do {
            azureInventory = try await catalogAzureInventory(into: catalog)
        } catch {
            progress.value.failed += 1
            logger.error("SYNC_AZURE_INVENTORY_FAILED error=\(String(describing: error))")
            logSyncEnd(progress.value, candidates: 0, unclassified: 0, started: runStarted)
            return progress.value
        }

        var candidateCount = 0
        var knownCandidateBytes: Int64 = 0
        var unknownCandidateSizes = 0
        var alreadyBackedUp = 0
        var preflightFailures = 0
        logger.info("PHOTO_INVENTORY_START date_filter=\(filter.from != nil || filter.untilExclusive != nil)")
        do {
            try catalog.beginBatch()
            try await library.enumerateOriginals(filter: filter) { item in
                guard filter.includes(item.creationDate) else {
                    if item.creationDate == nil { try catalog.addUndatedAsset(item.assetID) }
                    return
                }
                progress.value.examined += 1
                let disposition: PlannedPhotoResource.Disposition
                do {
                    guard !item.identityAmbiguous else {
                        throw BackupError.integrity("Photos exposes multiple indistinguishable resources for this original")
                    }
                    let name = try blobName(for: item)
                    let existing = try catalog.blob(named: name)
                    if let existing, sameIdentity(existing.metadata, item: item) {
                        if remoteIsNewer(existing.metadata, than: item.sourceModified) {
                            disposition = .skipped(reason: "azure_version_newer", size: existing.size)
                        } else if let expectedSize = item.sourceSize,
                                  existing.size == expectedSize,
                                  existing.metadata["source_size"] == String(expectedSize) {
                            disposition = .skipped(reason: "already_backed_up", size: expectedSize)
                        } else if item.sourceSize == nil,
                                  Int64(existing.metadata["source_size"] ?? "") == existing.size {
                            disposition = .skipped(reason: "already_backed_up", size: existing.size)
                        } else {
                            disposition = .candidate(existing: existing)
                        }
                    } else {
                        disposition = .candidate(existing: existing)
                    }
                } catch {
                    disposition = .failed(message: String(describing: error))
                }
                switch disposition {
                case .candidate:
                    candidateCount += 1
                    if let size = item.sourceSize { knownCandidateBytes += size }
                    else { unknownCandidateSizes += 1 }
                case .skipped:
                    alreadyBackedUp += 1
                case .failed:
                    preflightFailures += 1
                }
                try catalog.append(PlannedPhotoResource(item: item, disposition: disposition))
                if progress.value.examined % 10_000 == 0 {
                    logger.info("PHOTO_INVENTORY_PROGRESS files=\(progress.value.examined) candidates=\(candidateCount)")
                }
            }
            try catalog.commitBatch()
        } catch {
            catalog.rollbackBatch()
            let unclassified = (try? catalog.unclassifiableAssetCount()) ?? 0
            progress.value.unclassifiableAssets = unclassified
            progress.value.failed += 1
            logger.error("SYNC_INVENTORY_FAILED error=\(String(describing: error))")
            logSyncEnd(progress.value, candidates: candidateCount, unclassified: unclassified, started: runStarted)
            return progress.value
        }

        let unclassified: Int
        do {
            unclassified = try catalog.unclassifiableAssetCount()
        } catch {
            progress.value.failed += 1
            logger.error("SYNC_CATALOG_READ_FAILED error=\(String(describing: error))")
            logSyncEnd(progress.value, candidates: candidateCount, unclassified: 0, started: runStarted)
            return progress.value
        }
        progress.value.unclassifiableAssets = unclassified
        if unclassified > 0 {
            progress.value.failed += unclassified
            logger.error("SYNC_UNCLASSIFIABLE_ASSETS count=\(unclassified) reason=missing_capture_date")
        }

        logger.info("SYNC_PLAN files_examined=\(progress.value.examined) azure_blobs=\(azureInventory.blobs) azure_list_pages=\(azureInventory.pages) candidates_to_upload=\(candidateCount) candidate_bytes_known=\(formattedSize(knownCandidateBytes)) candidate_sizes_unknown=\(unknownCandidateSizes) already_backed_up=\(alreadyBackedUp) preflight_failures=\(preflightFailures) unclassifiable_assets=\(unclassified) dry_run=\(dryRun)")

        var index = 0
        do {
            while let entry = try catalog.nextPlan() {
                index += 1
                let item = entry.item
                let fileStarted = Date()
                let filename = String(reflecting: item.filename)
                let position = "file=\(index)/\(progress.value.examined)"
                logger.info("FILE_START \(position) filename=\(filename) kind=\(item.resourceKind) expected_size=\(formattedSize(item.sourceSize))")

                switch entry.disposition {
                case .skipped(let reason, let size):
                    progress.value.skipped += 1
                    logger.info("FILE_END \(position) filename=\(filename) status=skipped reason=\(reason) size=\(formattedSize(size ?? item.sourceSize)) duration=\(elapsed(since: fileStarted))")
                case .failed(let message):
                    progress.value.failed += 1
                    progress.value.pending += 1
                    logger.error("FILE_END \(position) filename=\(filename) status=failed stage=preflight error=\(message) duration=\(elapsed(since: fileStarted))")
                case .candidate(let existing):
                    if dryRun {
                        progress.value.wouldUpload += 1
                        logger.info("FILE_END \(position) filename=\(filename) status=would_upload expected_size=\(formattedSize(item.sourceSize)) duration=\(elapsed(since: fileStarted))")
                        continue
                    }
                    do {
                        switch try await uploadCandidate(item, existing: existing) {
                        case .skipped(let reason, let size):
                            progress.value.skipped += 1
                            logger.info("FILE_END \(position) filename=\(filename) status=skipped reason=\(reason) size=\(formattedSize(size)) duration=\(elapsed(since: fileStarted))")
                        case .uploaded(let transfer, let size):
                            progress.value.uploaded += 1
                            progress.value.bytesTransferred += transfer.sent
                            progress.value.bytesReused += transfer.reused
                            if transfer.resumed { progress.value.resumed += 1 }
                            logger.info("FILE_END \(position) filename=\(filename) status=uploaded size=\(formattedSize(size)) transferred=\(transfer.sent) bytes_reused=\(transfer.reused) resumed=\(transfer.resumed) duration=\(elapsed(since: fileStarted))")
                        }
                    } catch {
                        progress.value.failed += 1
                        progress.value.pending += 1
                        logger.error("FILE_END \(position) filename=\(filename) status=failed expected_size=\(formattedSize(item.sourceSize)) error=\(String(describing: error)) duration=\(elapsed(since: fileStarted))")
                    }
                }
            }
        } catch {
            progress.value.failed += 1
            logger.error("SYNC_PLAN_READ_FAILED error=\(String(describing: error))")
        }
        logSyncEnd(progress.value, candidates: candidateCount, unclassified: unclassified, started: runStarted)
        return progress.value
    }

    private func catalogAzureInventory(into catalog: SyncCatalog) async throws -> (blobs: Int, pages: Int) {
        logger.info("AZURE_INVENTORY_START prefix=Originals/ page_size=5000")
        try catalog.beginBatch()
        var marker: String?
        var blobs = 0
        var pages = 0
        do {
            repeat {
                let page = try await store.listBlobs(prefix: "Originals/", marker: marker)
                pages += 1
                for blob in page.blobs {
                    try catalog.insertBlob(blob)
                    blobs += 1
                }
                logger.info("AZURE_INVENTORY_PAGE page=\(pages) blobs=\(page.blobs.count) total=\(blobs) complete=\(page.continuationToken == nil)")
                marker = page.continuationToken
            } while marker != nil
            try catalog.commitBatch()
        } catch {
            catalog.rollbackBatch()
            throw error
        }
        return (blobs, pages)
    }

    private func uploadCandidate(_ item: BackupItem, existing: BlobRecord?) async throws -> Outcome {
        let name = try blobName(for: item)
        let stagingURL = spoolRoot.appendingPathComponent("\(UUID().uuidString.lowercased()).resource")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        _ = try await library.exportOriginal(item, to: stagingURL,
                                             maximumBytes: configuration.maxSpoolBytes)
        let size = try fileSize(stagingURL)
        if let expectedSize = item.sourceSize, size != expectedSize {
            throw BackupError.conflict("Photos reported a different original size during export")
        }
        logger.info("FILE_SOURCE_READY filename=\(String(reflecting: item.filename)) size=\(formattedSize(size))")
        if let existing, sameIdentity(existing.metadata, item: item), existing.size == size,
           existing.metadata["source_size"] == String(size) {
            return .skipped(reason: "already_backed_up", size: size)
        }
        let transfer = try await upload(item, stagingURL: stagingURL, size: size,
                                        blobName: name, replacing: existing)
        return .uploaded(transfer, size: size)
    }

    private func logSyncEnd(_ summary: RunSummary, candidates: Int, unclassified: Int, started: Date) {
        logger.info("SYNC_END files_examined=\(summary.examined) candidates_to_upload=\(candidates) uploaded=\(summary.uploaded) skipped=\(summary.skipped) would_upload=\(summary.wouldUpload) resumed=\(summary.resumed) pending=\(summary.pending) failed=\(summary.failed) unclassifiable_assets=\(unclassified) bytes_transferred=\(summary.bytesTransferred) bytes_reused=\(summary.bytesReused) duration=\(elapsed(since: started))")
    }

    private func formattedSize(_ size: Int64?) -> String {
        guard let size else { return "unknown" }
        return "\(size) bytes (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
    }

    private func elapsed(since date: Date) -> String {
        String(format: "%.2f seconds", Date().timeIntervalSince(date))
    }

    private func upload(_ item: BackupItem, stagingURL: URL, size: Int64,
                        blobName: String, replacing existing: BlobRecord?) async throws -> Transfer {
        let metadata = sourceMetadata(item, size: size)
        let contentType = item.contentType.isEmpty ? "application/octet-stream" : item.contentType
        if size == 0 {
            do {
                _ = try await store.publishFile(blobName, contentType: contentType, metadata: metadata,
                                                ifMatch: existing?.etag, ifNoneMatch: existing == nil)
            } catch {
                if let committed = try? await store.blob(blobName), matches(committed, item: item, size: size) {
                    return Transfer(sent: 0, reused: 0, resumed: false)
                }
                throw error
            }
        } else {
            let blockSize = configuration.blockSize
            let blockCount = size / Int64(blockSize) + (size % Int64(blockSize) == 0 ? 0 : 1)
            guard blockCount <= 50_000 else {
                throw BackupError.invalidConfiguration("Azure block count exceeds 50,000; increase the block size")
            }
            let blockIDs = (0..<Int(blockCount)).map {
                blockID(size: size, modified: modifiedNanoseconds(item.creationDate ?? item.sourceModified), index: $0)
            }
            let present = try await store.uncommittedBlockIDs(blobName)
            let handle = try FileHandle(forReadingFrom: stagingURL)
            defer { try? handle.close() }
            var sent: Int64 = 0
            var reused: Int64 = 0
            for index in blockIDs.indices {
                let offset = UInt64(index) * UInt64(blockSize)
                let expected = Int(min(Int64(blockSize), size - Int64(offset)))
                if present.contains(blockIDs[index]) {
                    reused += Int64(expected)
                    continue
                }
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: expected), data.count == expected else {
                    throw BackupError.integrity("Photos original changed while staging its upload")
                }
                try await store.putBlock(blobName, id: blockIDs[index], bytes: data)
                sent += Int64(data.count)
            }
            try await library.verifyOriginal(item)
            do {
                _ = try await store.commitFile(blobName, blockIDs: blockIDs, contentType: contentType,
                                               metadata: metadata, ifMatch: existing?.etag,
                                               ifNoneMatch: existing == nil)
            } catch {
                if let committed = try? await store.blob(blobName), matches(committed, item: item, size: size) {
                    return Transfer(sent: sent, reused: reused, resumed: reused > 0)
                }
                throw error
            }
            guard let committed = try await store.blob(blobName), matches(committed, item: item, size: size) else {
                throw BackupError.integrity("Azure did not confirm the Photos original upload")
            }
            return Transfer(sent: sent, reused: reused, resumed: reused > 0)
        }
        guard let committed = try await store.blob(blobName), matches(committed, item: item, size: size) else {
            throw BackupError.integrity("Azure did not confirm the Photos original upload")
        }
        return Transfer(sent: 0, reused: 0, resumed: false)
    }

    private func blobName(for item: BackupItem) throws -> String {
        guard !item.filename.isEmpty, item.filename != ".", item.filename != "..",
              !item.filename.contains("/"), !item.filename.contains("\\"),
              !item.filename.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw BackupError.integrity("Photos returned an unsafe original filename")
        }
        // PhotoKit exposes the real resource filename and asset identifier, but not
        // the package-relative path under Photos' private Originals directory.
        // Keep the original filename as the final blob component and namespace it
        // by the reversible Photos asset ID and resource type to prevent collisions.
        return ["Originals", base64URL(item.assetID), item.resourceKind,
                base64URL(item.uniformType), item.filename].joined(separator: "/")
    }

    private func sourceMetadata(_ item: BackupItem, size: Int64) -> [String: String] {
        ["layout": "photokit-originals-v2",
         "source_asset": base64URL(item.assetID),
         "source_resource": base64URL(item.resourceID),
         "source_filename": base64URL(item.filename),
         "source_kind": base64URL(item.resourceKind),
         "source_uti": base64URL(item.uniformType),
         "source_size": String(size),
         "source_modified_ns": String(modifiedNanoseconds(item.sourceModified))]
    }

    private func sameIdentity(_ metadata: [String: String], item: BackupItem) -> Bool {
        metadata["layout"] == "photokit-originals-v2" &&
        metadata["source_asset"] == base64URL(item.assetID) &&
        metadata["source_resource"] == base64URL(item.resourceID) &&
        metadata["source_filename"] == base64URL(item.filename) &&
        metadata["source_kind"] == base64URL(item.resourceKind) &&
        metadata["source_uti"] == base64URL(item.uniformType)
    }

    private func matches(_ record: BlobRecord, item: BackupItem, size: Int64) -> Bool {
        record.size == size && record.metadata["source_size"] == String(size) &&
        sameIdentity(record.metadata, item: item)
    }

    private func remoteIsNewer(_ metadata: [String: String], than sourceDate: Date?) -> Bool {
        guard let remote = Int64(metadata["source_modified_ns"] ?? ""),
              let sourceDate else { return false }
        return remote > modifiedNanoseconds(sourceDate)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
            throw BackupError.integrity("Photos did not create a regular staged original")
        }
        return Int64(info.st_size)
    }

    private func modifiedNanoseconds(_ date: Date?) -> Int64 {
        guard let date else { return 0 }
        let scaled = date.timeIntervalSince1970 * 1_000_000_000
        guard scaled.isFinite, scaled >= Double(Int64.min), scaled <= Double(Int64.max) else { return 0 }
        return Int64(scaled.rounded())
    }

    private func blockID(size: Int64, modified: Int64, index: Int) -> String {
        let raw = String(format: "%020lld:%020lld:%06lld", size, modified, Int64(index))
        return Data(raw.padding(toLength: 64, withPad: "0", startingAt: 0).utf8).base64EncodedString()
    }

    private func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
