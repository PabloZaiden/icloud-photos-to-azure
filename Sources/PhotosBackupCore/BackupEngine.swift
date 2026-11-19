import Foundation
import CryptoKit
import Darwin

private struct Journal: Codable { var version = 1; var entries: [String: JournalEntry] = [:] }
private struct JournalEntry: Codable {
    let item: BackupItem
    var objectName: String?
    var sha256: String?
    var size: Int64?
    var blockSize: Int
    let spoolPath: String
    var confirmedBlockIndexes: Set<Int>
    var exportDescriptor: ExportDescriptor?
}
private enum ItemOutcome { case skipped, candidate, uploaded(Int64, Int64), resumed(Int64, Int64) }
private struct TransferFailure: Error {
    let underlying: Error
    let bytesTransferred: Int64
    let bytesReused: Int64
    let resumed: Bool
}

public final class BackupEngine {
    private let configuration: AppConfiguration
    private let library: PhotoLibrary
    private let store: BlobStore
    private let logger: SafeLogger
    private let spoolRoot: URL
    private let journalURL: URL
    private var journal = Journal()
    private var journalRecoveryNeeded = false

    public init(configuration: AppConfiguration, library: PhotoLibrary, store: BlobStore, logger: SafeLogger) throws {
        try configuration.validate()
        self.configuration = configuration; self.library = library; self.store = store; self.logger = logger
        let requestedSpoolRoot = configuration.resolve(configuration.spoolDirectory)
            .appendingPathComponent(".photos-backup-spool-v1", isDirectory: true).standardizedFileURL
        self.journalURL = configuration.resolve(configuration.journalPath)
        try FileManager.default.createDirectory(at: configuration.resolve(configuration.spoolDirectory), withIntermediateDirectories: true)
        var requestedStat = stat()
        if lstat(requestedSpoolRoot.path, &requestedStat) == 0 {
            guard (requestedStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), (requestedStat.st_mode & 0o077) == 0 else {
                throw BackupError.invalidConfiguration("managed spool directory must be a private, non-symlink directory")
            }
        } else {
            guard errno == ENOENT else { throw BackupError.invalidConfiguration("could not inspect private spool directory") }
            try FileManager.default.createDirectory(at: requestedSpoolRoot, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        self.spoolRoot = requestedSpoolRoot.resolvingSymlinksInPath()
        try validatePrivateSpoolRoot()
        try loadJournal()
    }

    public func sync(filter: DateFilter, dryRun: Bool) async -> RunSummary {
        var summary = RunSummary(); summary.dryRun = dryRun
        if !dryRun { recoverJournalIfNeeded() }
        var undatedAssets = Set<String>()
        var seenItemIDs = Set<String>()
        var inventoryCompleted = false
        do {
            try await library.enumerate(filter: filter) { item in
                seenItemIDs.insert(item.id)
                if !filter.includes(item.creationDate) {
                    if item.creationDate == nil { undatedAssets.insert(item.assetID) }
                    return
                }
                summary.examined += 1
                if item.identityAmbiguous || item.exportUnavailableReason != nil {
                    summary.failed += 1
                    logger.error("Incomplete coverage for \(shortID(item.id)): \(item.exportUnavailableReason ?? "resource identity is ambiguous")")
                    return
                }
                do {
                    let outcome = try await process(item, dryRun: dryRun)
                    switch outcome {
                    case .skipped: summary.skipped += 1
                    case .candidate:
                        if dryRun { summary.wouldUpload += 1 } else { summary.pending += 1 }
                    case .uploaded(let sent, let reused): summary.uploaded += 1; summary.bytesTransferred += sent; summary.bytesReused += reused
                    case .resumed(let sent, let reused): summary.uploaded += 1; summary.resumed += 1
                        summary.bytesTransferred += sent; summary.bytesReused += reused
                    }
                } catch {
                    summary.failed += 1; summary.pending += 1
                    if let progress = error as? TransferFailure {
                        summary.bytesTransferred += progress.bytesTransferred
                        summary.bytesReused += progress.bytesReused
                        if progress.resumed { summary.resumed += 1 }
                    }
                    logger.error("Resource \(shortID(item.id)) failed and remains pending: \(safeError(error))")
                }
            }
            inventoryCompleted = true
        } catch { logger.error("Photo inventory failed: \(safeError(error))"); summary.failed += 1 }
        if inventoryCompleted && filter.includesUnfiltered && !dryRun {
            await reconcileAbsentJournalEntries(presentItemIDs: seenItemIDs, summary: &summary)
            cleanOrphanSpools()
        }
        summary.unclassifiableAssets = undatedAssets.count
        if !undatedAssets.isEmpty {
            logger.error("\(undatedAssets.count) assets have no capture date and could not be classified by the requested date filter")
            summary.failed += undatedAssets.count
        }
        return summary
    }

    private func process(_ item: BackupItem, dryRun: Bool) async throws -> ItemOutcome {
        let manifestName = item.blobName
        let manifest = try await retry { try await self.store.blob(manifestName) }
        if let manifest, isTrusted(manifest.metadata, for: item), isRemoteNewer(manifest.metadata, than: item.sourceModified) {
            guard let hash = manifest.metadata["sha256"], let size = Int64(manifest.metadata["size"] ?? "-1"),
                  let objectName = manifest.metadata["object_name"],
                  objectName == item.objectName(hash: hash),
                  try await objectIsVerified(objectName, hash: hash, size: size) else {
                throw BackupError.integrity("destination manifest has a newer source version but its content object is missing or invalid")
            }
            logger.info("Destination source version is newer; left intact for \(shortID(item.id))")
            if !dryRun { clearJournal(for: item.id) }
            return .skipped
        }
        let localVersion = item.sourceModified?.versionToken ?? "null"
        if let manifest, item.sourceModified != nil, isTrusted(manifest.metadata, for: item),
           sameVersion(manifest.metadata["source_modified"], localVersion),
           let hash = manifest.metadata["sha256"], let objectName = manifest.metadata["object_name"], objectName == item.objectName(hash: hash) {
            let object = try await retry { try await self.store.blob(objectName) }
            if object.map({ validObject($0, hash: hash, size: manifest.metadata["size"] ?? "") }) == true {
                if metadataMatches(manifest.metadata, item: item) { if !dryRun { cleanupJournal(item.id) }; return .skipped }
                if dryRun { return .candidate }
                try await updateManifest(item, hash: hash, size: Int64(manifest.metadata["size"] ?? "0") ?? 0,
                                         objectName: objectName, existing: manifest)
                cleanupJournal(item.id)
                logger.info("Updated manifest metadata without retransmitting bytes for \(shortID(item.id))")
                return .skipped
            }
        }
        if dryRun { return .candidate }

        let pendingEntry = journal.entries[item.id]
        var resumed = false
        var spool: URL
        var hash: String
        var size: Int64
        var exportDescriptor: ExportDescriptor
        let reusableSpool: URL? = {
            guard let entry = pendingEntry, item.sourceModified != nil,
                  entry.item.id == item.id, entry.item.sourceModified == item.sourceModified,
                  (item.representation != .current || entry.exportDescriptor != nil),
                  entry.sha256 != nil, entry.size != nil,
                  let url = validatedSpoolURL(entry.spoolPath),
                  (try? hashFile(url)) == entry.sha256 else { return nil }
            return url
        }()
        if let entry = pendingEntry, let reusableSpool,
           let entryHash = entry.sha256, let entrySize = entry.size,
           let attrs = try? FileManager.default.attributesOfItem(atPath: reusableSpool.path),
           (attrs[.size] as? NSNumber)?.int64Value == entrySize {
            try await library.verify(item)
            spool = reusableSpool; hash = entryHash; size = entrySize; resumed = true
            exportDescriptor = entry.exportDescriptor ?? ExportDescriptor(item: item)
        } else {
            if pendingEntry != nil { clearJournal(for: item.id) }
            let used = spoolBytes()
            let available = max(0, configuration.maxSpoolBytes - used)
            guard available > 0 else { throw BackupError.diskBudget(required: 1, available: 0) }
            spool = spoolRoot.appendingPathComponent("\(stableHash(item.id).prefix(24))-\(UUID().uuidString).spool")
            journal.entries[item.id] = JournalEntry(item: item, objectName: nil, sha256: nil, size: nil,
                                                    blockSize: configuration.blockSize, spoolPath: spool.path,
                                                    confirmedBlockIndexes: [], exportDescriptor: nil)
            try saveJournal()
            do { exportDescriptor = try await library.export(item, to: spool, maximumBytes: available) }
            catch { try? FileManager.default.removeItem(at: spool); throw error }
            guard let validated = validatedSpoolURL(spool.path) else {
                throw BackupError.integrity("Photos export did not create a managed regular spool file")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: validated.path)
            size = try fileSize(spool)
            hash = try hashFile(spool)
            let objectName = item.objectName(hash: hash)
            // A fresh export is required when PhotoKit has no modification token. Keep
            // the prior Azure segmentation only when the re-export proves identical bytes.
            let priorSegmentation = pendingEntry.flatMap { prior -> Int? in
                guard prior.sha256 == hash, prior.size == size, validBlockSize(prior.blockSize) else { return nil }
                return prior.blockSize
            }
            journal.entries[item.id] = JournalEntry(item: item, objectName: objectName, sha256: hash, size: size,
                                                    blockSize: priorSegmentation ?? effectiveBlockSize(size), spoolPath: spool.path,
                                                    confirmedBlockIndexes: [], exportDescriptor: exportDescriptor)
            try saveJournal()
        }
        let objectName = item.objectName(hash: hash)
        let contentMetadata = contentObjectMetadata(hash: hash, size: size, descriptor: exportDescriptor)
        var transferred: Int64 = 0
        var reused: Int64 = 0
        if let existingObject = try await retry({ try await self.store.blob(objectName) }) {
            guard validObject(existingObject, hash: hash, size: String(size)) else {
                throw BackupError.integrity("content-addressed Azure object exists with unverifiable metadata; refusing overwrite")
            }
            reused = size
        } else if size == 0 {
            do { _ = try await retry { try await self.store.publish(objectName, metadata: contentMetadata, ifMatch: nil, ifNoneMatch: true) } }
            catch {
                let verified = try await objectIsVerified(objectName, hash: hash, size: size)
                if !verified { throw error }
            }
            guard try await objectIsVerified(objectName, hash: hash, size: size) else { throw BackupError.integrity("empty Azure object did not verify after publish") }
            transferred = 0
        } else {
            do {
                (transferred, reused) = try await uploadBlocks(item: item, spool: spool, hash: hash, size: size,
                                                                objectName: objectName, metadata: contentMetadata)
            } catch let progress as TransferFailure {
                throw TransferFailure(underlying: progress.underlying, bytesTransferred: progress.bytesTransferred,
                                      bytesReused: progress.bytesReused, resumed: resumed)
            }
        }
        try await library.verify(item)
        try await publishManifest(item, hash: hash, size: size, objectName: objectName, descriptor: exportDescriptor)
        cleanupJournal(item.id)
        return resumed ? .resumed(transferred, reused) : .uploaded(transferred, reused)
    }

    private func reconcileAbsentJournalEntries(presentItemIDs: Set<String>, summary: inout RunSummary) async {
        let absent = journal.entries.values.filter { !presentItemIDs.contains($0.item.id) }
        for entry in absent {
            do {
                guard let hash = entry.sha256, let size = entry.size, size >= 0,
                      validBlockSize(entry.blockSize) else {
                    clearJournal(for: entry.item.id)
                    continue
                }
                let spool = validatedSpoolURL(entry.spoolPath)
                if let spool {
                    guard (try? fileSize(spool)) == size, (try? hashFile(spool)) == hash else {
                        clearJournal(for: entry.item.id)
                        logger.error("Discarded a corrupt retained spool for an absent Photos resource: \(shortID(entry.item.id))")
                        continue
                    }
                }
                let item = entry.item
                let objectName = item.objectName(hash: hash)
                var sent: Int64 = 0
                var reused: Int64 = 0
                if let object = try await retry({ try await self.store.blob(objectName) }),
                   validObject(object, hash: hash, size: String(size)) {
                    reused = size
                } else if let spool {
                    if size == 0 {
                        let metadata = contentObjectMetadata(hash: hash, size: size,
                                                             descriptor: entry.exportDescriptor ?? ExportDescriptor(item: item))
                        do { _ = try await retry { try await self.store.publish(objectName, metadata: metadata, ifMatch: nil, ifNoneMatch: true) } }
                        catch {
                            guard try await objectIsVerified(objectName, hash: hash, size: 0) else { throw error }
                        }
                    } else {
                        let contentMetadata = contentObjectMetadata(hash: hash, size: size,
                                                                     descriptor: entry.exportDescriptor ?? ExportDescriptor(item: item))
                        (sent, reused) = try await uploadBlocks(item: item, spool: spool, hash: hash, size: size,
                                                                objectName: objectName, metadata: contentMetadata)
                    }
                    guard try await objectIsVerified(objectName, hash: hash, size: size) else {
                        throw BackupError.integrity("archived Azure object did not verify")
                    }
                } else {
                    clearJournal(for: item.id)
                    continue
                }
                try await publishHistoricalArchive(item, hash: hash, size: size, objectName: objectName,
                                                   descriptor: entry.exportDescriptor ?? ExportDescriptor(item: item))
                cleanupJournal(item.id)
                summary.uploaded += 1; summary.resumed += 1
                summary.bytesTransferred += sent; summary.bytesReused += reused
                logger.info("Completed a retained snapshot for a resource absent from the complete Photos inventory: \(shortID(item.id))")
            } catch {
                summary.failed += 1; summary.pending += 1
                logger.error("Retained snapshot for an absent Photos resource remains pending: \(safeError(error))")
            }
        }
    }

    private func publishHistoricalArchive(_ item: BackupItem, hash: String, size: Int64, objectName: String,
                                          descriptor: ExportDescriptor) async throws {
        let existingCurrent = try await retry { try await self.store.blob(item.blobName) }
        let priorVersion = item.sourceModified == nil ? existingCurrent?.metadata["source_modified"] : nil
        var metadata = manifestMetadata(item: item, hash: hash, size: size, objectName: objectName,
                                        preservingSourceModified: priorVersion, descriptor: descriptor)
        metadata["source_state"] = "absent-from-complete-inventory"
        let archiveName = "archives/\(b64url(item.id))/\(hash)"
        if let existing = try await retry({ try await self.store.blob(archiveName) }) {
            guard existing.metadata["sha256"] == hash, existing.metadata["object_name"] == objectName,
                  existing.metadata["size"] == String(size), existing.metadata["source_state"] == "absent-from-complete-inventory" else {
                throw BackupError.integrity("historical archive pointer conflicts with retained snapshot")
            }
            return
        }
        do { _ = try await retry { try await self.store.publish(archiveName, metadata: metadata, ifMatch: nil, ifNoneMatch: true) } }
        catch is BlobConditionFailed {
            guard let existing = try await retry({ try await self.store.blob(archiveName) }),
                  existing.metadata["sha256"] == hash, existing.metadata["object_name"] == objectName,
                  existing.metadata["size"] == String(size) else { throw BackupError.conflict("historical archive changed concurrently") }
        }
    }

    private func uploadBlocks(item: BackupItem, spool: URL, hash: String, size: Int64, objectName: String,
                              metadata: [String: String]) async throws -> (Int64, Int64) {
        guard let blockSize = journal.entries[item.id]?.blockSize else { throw BackupError.integrity("journal lost block segmentation") }
        var sent: Int64 = 0
        var reused: Int64 = 0
        do {
            let count = Int((size + Int64(blockSize) - 1) / Int64(blockSize))
            guard count <= 50_000 else { throw BackupError.invalidConfiguration("Azure block count exceeds 50,000; increase block size") }
            var present = try await retry { try await self.store.uncommittedBlockIDs(objectName) }
            var blockIDs: [String] = []; blockIDs.reserveCapacity(count)
            let handle = try FileHandle(forReadingFrom: spool); defer { try? handle.close() }
            for index in 0..<count {
                let expectedSize = Int(min(Int64(blockSize), size - Int64(index) * Int64(blockSize)))
                try handle.seek(toOffset: UInt64(index * blockSize))
                guard let data = try handle.read(upToCount: expectedSize), data.count == expectedSize else {
                    throw BackupError.integrity("retained export ended before its expected size")
                }
                let id = blockID(bytes: data, blockSize: blockSize, index: index)
                blockIDs.append(id)
                if present.contains(id) { reused += Int64(expectedSize); continue }
                try await retry { try await self.store.putBlock(objectName, id: id, bytes: data) }
                sent += Int64(data.count); present.insert(blockIDs[index])
                if var entry = journal.entries[item.id] { entry.confirmedBlockIndexes.insert(index); journal.entries[item.id] = entry; try saveJournal() }
            }
            do {
                _ = try await retry { try await self.store.commit(objectName, blockIDs: blockIDs, metadata: metadata, ifMatch: nil, ifNoneMatch: true) }
            } catch {
                // Resolve a lost commit response before any future retry/retransmission.
                let verified = try await objectIsVerified(objectName, hash: hash, size: size)
                if !verified { throw error }
            }
            guard try await objectIsVerified(objectName, hash: hash, size: size) else {
                throw BackupError.integrity("Azure committed blob size or hash metadata did not match the export")
            }
            return (sent, reused)
        } catch let progress as TransferFailure {
            throw progress
        } catch {
            throw TransferFailure(underlying: error, bytesTransferred: sent, bytesReused: reused, resumed: false)
        }
    }

    private func publishManifest(_ item: BackupItem, hash: String, size: Int64, objectName: String,
                                 descriptor: ExportDescriptor? = nil, verifySource: Bool = true) async throws {
        for attempt in 0..<4 {
            let current = try await retry { try await self.store.blob(item.blobName) }
            if let current, isTrusted(current.metadata, for: item), isRemoteNewer(current.metadata, than: item.sourceModified) {
                guard let remoteHash = current.metadata["sha256"], let remoteName = current.metadata["object_name"],
                      remoteName == item.objectName(hash: remoteHash), let remoteSize = Int64(current.metadata["size"] ?? "-1"),
                      try await objectIsVerified(remoteName, hash: remoteHash, size: remoteSize) else {
                    throw BackupError.integrity("concurrent newer manifest points to missing or invalid content")
                }
                return
            }
            if let current, item.sourceModified == nil, current.metadata["source_modified"] != nil,
               current.metadata["source_modified"] != "null", current.metadata["sha256"] != hash {
                throw BackupError.conflict("local source has no modification date and differs from a dated destination; refusing to replace it")
            }
            let preservedVersion = item.sourceModified == nil ? current?.metadata["source_modified"] : nil
            let actualDescriptor = descriptor ?? current.flatMap { exportDescriptor(from: $0.metadata, fallback: item) } ?? ExportDescriptor(item: item)
            let desired = manifestMetadata(item: item, hash: hash, size: size, objectName: objectName,
                                           preservingSourceModified: preservedVersion, descriptor: actualDescriptor)
            do {
                if let current {
                    if current.metadata["sha256"] == hash && current.metadata["object_name"] == objectName {
                        if verifySource { try await library.verify(item) }
                        try await retry { try await self.store.setMetadata(item.blobName, metadata: desired, ifMatch: current.etag) }
                    } else {
                        if verifySource { try await library.verify(item) }
                        _ = try await retry { try await self.store.publish(item.blobName, metadata: desired, ifMatch: current.etag, ifNoneMatch: false) }
                    }
                } else {
                    if verifySource { try await library.verify(item) }
                    _ = try await retry { try await self.store.publish(item.blobName, metadata: desired, ifMatch: nil, ifNoneMatch: true) }
                }
                let confirmed = try await retry { try await self.store.blob(item.blobName) }
                guard let confirmed, confirmed.metadata["sha256"] == hash, confirmed.metadata["object_name"] == objectName,
                      confirmed.metadata["size"] == String(size), confirmed.metadata["identity_hash"] == stableHash(item.id) else {
                    throw BackupError.integrity("Azure manifest did not confirm the completed object")
                }
                return
            } catch is BlobConditionFailed {
                if let latest = try await retry({ try await self.store.blob(item.blobName) }), manifestMatches(latest.metadata, desired: desired) { return }
                if attempt == 3 { throw BackupError.conflict("Azure manifest changed concurrently; retry next run") }
            } catch let error as StorageTransportError {
                if let latest = try await retry({ try await self.store.blob(item.blobName) }), manifestMatches(latest.metadata, desired: desired) { return }
                if attempt == 3 { throw error }
            }
        }
    }

    private func updateManifest(_ item: BackupItem, hash: String, size: Int64, objectName: String,
                                existing: BlobRecord) async throws {
        let preservedVersion = item.sourceModified == nil ? existing.metadata["source_modified"] : nil
        let actualDescriptor = exportDescriptor(from: existing.metadata, fallback: item) ?? ExportDescriptor(item: item)
        let metadata = manifestMetadata(item: item, hash: hash, size: size, objectName: objectName,
                                        preservingSourceModified: preservedVersion, descriptor: actualDescriptor)
        do { try await retry { try await self.store.setMetadata(item.blobName, metadata: metadata, ifMatch: existing.etag) } }
        catch is BlobConditionFailed {
            try await publishManifest(item, hash: hash, size: size, objectName: objectName, descriptor: actualDescriptor)
        }
    }

    private func manifestMetadata(item: BackupItem, hash: String, size: Int64, objectName: String,
                                  preservingSourceModified priorVersion: String? = nil,
                                  descriptor: ExportDescriptor? = nil) -> [String: String] {
        let actual = descriptor ?? ExportDescriptor(item: item)
        return ["schema": "1", "identity_hash": stableHash(item.id), "asset_id_b64": b64url(item.assetID),
         "resource_id_b64": b64url(item.resourceID), "representation": item.representation.rawValue,
         "resource_kind": item.resourceKind, "source_modified": item.sourceModified?.versionToken ?? priorVersion ?? "null",
         "creation_date": item.creationDate?.iso8601Fractional ?? "null", "sha256": hash, "size": String(size),
         "object_name": objectName, "filename_b64": b64url(item.filename), "uniform_type_b64": b64url(item.uniformType),
         "source_content_type": item.contentType,
         "export_filename_b64": b64url(actual.filename), "export_uniform_type_b64": b64url(actual.uniformType),
         "content_type": actual.contentType]
    }

    private func metadataMatches(_ metadata: [String: String], item: BackupItem) -> Bool {
        metadata["filename_b64"] == b64url(item.filename) && metadata["uniform_type_b64"] == b64url(item.uniformType) &&
        (metadata["source_content_type"] ?? metadata["content_type"]) == item.contentType &&
        metadata["representation"] == item.representation.rawValue
    }
    private func manifestMatches(_ metadata: [String: String], desired: [String: String]) -> Bool {
        metadata["identity_hash"] == desired["identity_hash"] && metadata["sha256"] == desired["sha256"] &&
        metadata["object_name"] == desired["object_name"] && metadata["size"] == desired["size"] &&
        metadata["export_filename_b64"] == desired["export_filename_b64"] &&
        metadata["export_uniform_type_b64"] == desired["export_uniform_type_b64"] &&
        metadata["content_type"] == desired["content_type"] &&
        sameVersion(metadata["source_modified"], desired["source_modified"])
    }

    private func contentObjectMetadata(hash: String, size: Int64, descriptor: ExportDescriptor) -> [String: String] {
        ["schema": "1", "sha256": hash, "size": String(size), "content_type": descriptor.contentType,
         "export_filename_b64": b64url(descriptor.filename), "export_uniform_type_b64": b64url(descriptor.uniformType)]
    }

    private func exportDescriptor(from metadata: [String: String], fallback item: BackupItem) -> ExportDescriptor? {
        let filename = metadata["export_filename_b64"].flatMap(decodeB64URL) ?? metadata["filename_b64"].flatMap(decodeB64URL)
        let uti = metadata["export_uniform_type_b64"].flatMap(decodeB64URL) ?? metadata["uniform_type_b64"].flatMap(decodeB64URL)
        guard let filename, let uti else { return nil }
        return ExportDescriptor(filename: filename, uniformType: uti, contentType: metadata["content_type"] ?? item.contentType)
    }

    private func decodeB64URL(_ value: String) -> String? {
        var raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - raw.count % 4) % 4
        raw += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func isTrusted(_ metadata: [String: String], for item: BackupItem) -> Bool {
        metadata["schema"] == "1" && metadata["identity_hash"] == stableHash(item.id) &&
        metadata["representation"] == item.representation.rawValue && metadata["sha256"]?.count == 64 && metadata["object_name"] != nil
    }
    private func isRemoteNewer(_ metadata: [String: String], than local: Date?) -> Bool {
        guard let local, let remoteText = metadata["source_modified"], remoteText != "null" else { return false }
        let localText = local.versionToken
        if remoteText.hasPrefix("ns:") && localText.hasPrefix("ns:") {
            guard let remote = Self.versionNanoseconds(remoteText), let localNanos = Self.versionNanoseconds(localText) else { return false }
            return remote > localNanos
        }
        guard let remote = Self.versionMilliseconds(remoteText), let localMillis = Self.versionMilliseconds(localText) else { return false }
        return remote > localMillis
    }
    private static func parseDate(_ string: String) -> Date? {
        if string.hasPrefix("ns:"), let nanos = Int64(string.dropFirst(3)) {
            return Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
        }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    private static func versionNanoseconds(_ string: String) -> Int64? {
        if string.hasPrefix("ns:") { return Int64(string.dropFirst(3)) }
        guard let date = parseDate(string) else { return nil }
        let scaled = date.timeIntervalSince1970 * 1_000_000_000
        guard scaled.isFinite, scaled >= Double(Int64.min), scaled <= Double(Int64.max) else { return nil }
        return Int64(scaled.rounded())
    }
    private static func versionMilliseconds(_ string: String) -> Int64? {
        if let nanos = versionNanoseconds(string) { return Int64((Double(nanos) / 1_000_000).rounded()) }
        return nil
    }
    private func sameVersion(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        if lhs == "null" || rhs == "null" { return lhs == rhs }
        if lhs.hasPrefix("ns:") && rhs.hasPrefix("ns:") {
            guard let left = Self.versionNanoseconds(lhs), let right = Self.versionNanoseconds(rhs) else { return lhs == rhs }
            return left == right
        }
        guard let left = Self.versionMilliseconds(lhs), let right = Self.versionMilliseconds(rhs) else { return lhs == rhs }
        return left == right
    }
    private func validObject(_ object: BlobRecord, hash: String, size: String) -> Bool {
        object.metadata["sha256"] == hash && object.metadata["size"] == size && object.size == (Int64(size) ?? -1)
    }
    private func objectIsVerified(_ name: String, hash: String, size: Int64) async throws -> Bool {
        guard let object = try await retry({ try await self.store.blob(name) }) else { return false }
        return validObject(object, hash: hash, size: String(size))
    }

    private func retry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() }
            catch is StorageTransientError where attempt < configuration.maxRetries {
                try await Task.sleep(for: .milliseconds(min(8000, 250 * (1 << attempt)))); attempt += 1
            } catch is StorageTransportError where attempt < configuration.maxRetries {
                try await Task.sleep(for: .milliseconds(min(8000, 250 * (1 << attempt)))); attempt += 1
            }
        }
    }

    private func blockID(bytes: Data, blockSize: Int, index: Int) -> String {
        var raw = Data([1])
        var size = UInt32(blockSize).bigEndian
        var ordinal = UInt32(index).bigEndian
        withUnsafeBytes(of: &size) { raw.append(contentsOf: $0) }
        withUnsafeBytes(of: &ordinal) { raw.append(contentsOf: $0) }
        raw.append(contentsOf: SHA256.hash(data: bytes))
        return raw.base64EncodedString()
    }
    private func effectiveBlockSize(_ size: Int64) -> Int {
        let minimum = Int((size + 49_999) / 50_000)
        return max(configuration.blockSize, minimum)
    }
    private func validBlockSize(_ value: Int) -> Bool { (64 * 1024...100 * 1024 * 1024).contains(value) }
    private func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }; hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs[.size] as? NSNumber)?.int64Value else { throw BackupError.integrity("could not read exported file size") }
        return size
    }
    private func spoolBytes() -> Int64 {
        var total: Int64 = 0
        guard let files = try? FileManager.default.contentsOfDirectory(at: spoolRoot, includingPropertiesForKeys: nil) else { return 0 }
        for file in files where validatedSpoolURL(file.path) != nil { total += (try? fileSize(file)) ?? 0 }
        return total
    }
    private func stableHash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func b64url(_ value: String) -> String {
        Data(value.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func shortID(_ value: String) -> String { String(stableHash(value).prefix(12)) }
    private func safeError(_ error: Error) -> String {
        if let progress = error as? TransferFailure { return safeError(progress.underlying) }
        if let error = error as? BackupError { return error.description }
        if let error = error as? StorageTransientError { return error.description }
        if let error = error as? StorageTransportError { return error.description }
        if let error = error as? BlobConditionFailed { return error.description }
        return String(describing: type(of: error))
    }

    private func loadJournal() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try requireRegularFileWithoutSymlink(journalURL, description: "journal")
        let attrs = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard mode & 0o077 == 0 else { throw BackupError.invalidConfiguration("journal permissions must be 0600 or stricter") }
        do {
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard journal.version == 1 else { throw BackupError.integrity("unsupported journal schema") }
        } catch {
            journal = Journal()
            journalRecoveryNeeded = true
            logger.error("Journal was unreadable; recovery will preserve it for diagnosis and discard untracked spool files on the next real sync")
        }
    }
    private func saveJournal() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try requireRegularFileWithoutSymlink(journalURL, description: "journal")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    private func clearJournal(for id: String) {
        guard let entry = journal.entries.removeValue(forKey: id) else { return }
        if let spool = validatedSpoolURL(entry.spoolPath) { try? FileManager.default.removeItem(at: spool) }
        try? saveJournal()
    }
    private func cleanupJournal(_ id: String) { clearJournal(for: id) }
    private func cleanOrphanSpools() {
        var changed = false
        for id in Array(journal.entries.keys) {
            guard let entry = journal.entries[id] else { continue }
            if entry.sha256 == nil || entry.size == nil || validatedSpoolURL(entry.spoolPath) == nil {
                if let spool = validatedSpoolURL(entry.spoolPath) { try? FileManager.default.removeItem(at: spool) }
                journal.entries.removeValue(forKey: id); changed = true
            }
        }
        let referenced = Set(journal.entries.values.compactMap { validatedSpoolURL($0.spoolPath)?.path })
        if let files = try? FileManager.default.contentsOfDirectory(at: spoolRoot, includingPropertiesForKeys: nil) {
            for file in files where isManagedSpoolFilename(file.lastPathComponent) &&
                validatedSpoolURL(file.path) != nil && !referenced.contains(file.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        if changed { try? saveJournal() }
    }
    private func validatePrivateSpoolRoot() throws {
        var info = stat()
        guard lstat(spoolRoot.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & 0o077) == 0 else {
            throw BackupError.invalidConfiguration("managed spool directory must be a private, non-symlink directory")
        }
    }
    private func validatedSpoolURL(_ rawPath: String) -> URL? {
        let candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard candidate.path.hasPrefix(spoolRoot.path + "/"),
              candidate.deletingLastPathComponent().path == spoolRoot.path,
              isManagedSpoolFilename(candidate.lastPathComponent) else { return nil }
        var info = stat()
        guard lstat(candidate.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
        return candidate
    }
    private func isManagedSpoolFilename(_ name: String) -> Bool {
        name.range(of: "^[0-9a-f]{24}-[0-9A-Fa-f-]{36}\\.spool$", options: .regularExpression) != nil
    }
    private func requireRegularFileWithoutSymlink(_ url: URL, description: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw BackupError.invalidConfiguration("\(description) must be a regular file, not a symlink")
        }
    }
    private func recoverJournalIfNeeded() {
        if journalRecoveryNeeded, FileManager.default.fileExists(atPath: journalURL.path) {
            let quarantine = URL(fileURLWithPath: "\(journalURL.path).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: journalURL, to: quarantine)
            journalRecoveryNeeded = false
        }
    }
}
