import Foundation
#if canImport(Photos)
import Photos
import UniformTypeIdentifiers
@preconcurrency import AVFoundation

public final class PhotoKitLibrary: PhotoLibrary {
    private let libraryID: String
    private let policy: PhotoInventoryPolicy
    private let manager = PHAssetResourceManager.default()
    public init(libraryID: String, policy: PhotoInventoryPolicy = .completeAccessibleLibrary) {
        self.libraryID = libraryID; self.policy = policy
    }

    private var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    public func authorization() -> String { Self.describe(status) }
    public func requestAuthorization() async -> String {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in continuation.resume(returning: Self.describe(status)) }
        }
    }

    public func checkAvailability() throws {
        guard status == .authorized else {
            throw BackupError.permission("full read access is required (current status: \(authorization())); run photo-backup authorize")
        }
        if let reason = PHPhotoLibrary.shared().unavailabilityReason {
            throw BackupError.permission("the system Photos library is unavailable (\((reason as NSError).code))")
        }
        _ = PHAsset.fetchAssets(with: PHFetchOptions()).count
    }
    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not-determined"
        @unknown default: return "unknown"
        }
    }

    public func enumerate(filter: DateFilter, consume: (BackupItem) async throws -> Void) async throws {
        guard status == .authorized else {
            throw BackupError.permission("full read access is required (current status: \(authorization())); run photo-backup authorize")
        }
        let options = PHFetchOptions()
        options.includeHiddenAssets = policy.includeHiddenAssets
        options.includeAllBurstAssets = policy.includeAllBurstAssets
        let assets = PHAsset.fetchAssets(with: options)
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            guard asset.creationDate == nil || filter.includes(asset.creationDate) else { continue }
            for item in items(for: asset) { try await consume(item) }
        }
    }

    public func enumerateOriginals(filter: DateFilter, consume: (BackupItem) async throws -> Void) async throws {
        try await enumerate(filter: filter) { item in
            guard item.representation == .original else { return }
            try await consume(item)
        }
    }

    private func items(for asset: PHAsset) -> [BackupItem] {
        var output: [BackupItem] = []
        let resources = PHAssetResource.assetResources(for: asset)
        let originals = resources.filter { Self.isOriginal($0.type) }
        let grouped = Dictionary(grouping: originals, by: { Self.kind(for: $0.type) + "|" + $0.uniformTypeIdentifier })
        for groupKey in grouped.keys.sorted() {
            guard let group = grouped[groupKey] else { continue }
            let sorted = group.sorted { Self.filename($0).localizedStandardCompare(Self.filename($1)) == .orderedAscending }
            let ambiguous = sorted.count > 1
            for (index, resource) in sorted.enumerated() {
                let kind = Self.kind(for: resource.type)
                let resourceType = resource.uniformTypeIdentifier
                let resourceID = ambiguous ? "\(kind)-\(resourceType)-ambiguous-\(index)" : "\(kind)-\(resourceType)"
                output.append(Self.item(libraryID: self.libraryID, asset: asset, resourceID: resourceID,
                                        resourceKind: kind, representation: .original, filename: Self.filename(resource),
                                        uti: resource.uniformTypeIdentifier, sourceSize: Self.dataSize(resource),
                                        identityAmbiguous: ambiguous))
            }
        }

        let fullSize = resources.filter { [.fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo].contains($0.type) }
        var emitted = Set<String>()
        for resource in fullSize {
            guard let kind = Self.currentKind(resource.type, asset: asset) else { continue }
            guard emitted.insert(kind).inserted else { continue }
            output.append(Self.item(libraryID: self.libraryID, asset: asset, resourceID: "current-\(kind)",
                                    resourceKind: kind, representation: .current, filename: Self.filename(resource),
                                    uti: resource.uniformTypeIdentifier, sourceSize: Self.dataSize(resource),
                                    identityAmbiguous: fullSize.filter { Self.currentKind($0.type, asset: asset) == kind }.count > 1))
        }

        // Ensure every image/video family has a current pointer. When a rendered full-size
        // resource is absent, exportCurrentFallback asks Photos for its current rendered
        // output through a read-only editing-input request.
        for kind in Set(originals.map { Self.kind(for: $0.type) }).sorted() where ["image", "video", "paired-video"].contains(kind) {
            guard !emitted.contains(kind) else { continue }
            let source = originals.filter { Self.kind(for: $0.type) == kind }
            let chosen = source.count == 1 ? source.first : nil
            output.append(Self.item(libraryID: self.libraryID, asset: asset, resourceID: "current-\(kind)",
                                    resourceKind: kind, representation: .current,
                                    filename: chosen.map(Self.filename) ?? "current", uti: chosen?.uniformTypeIdentifier ?? "public.data",
                                    identityAmbiguous: source.count > 1))
        }
        return output
    }

    public func export(_ item: BackupItem, to destination: URL, maximumBytes: Int64) async throws -> ExportDescriptor {
        guard status == .authorized else { throw BackupError.permission("Photos read authorization was revoked") }
        if let reason = item.exportUnavailableReason { throw BackupError.integrity(reason) }
        guard !item.identityAmbiguous else {
            throw BackupError.integrity("PhotoKit exposes multiple indistinguishable resources for this identity; refusing an unstable ordinal")
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil).firstObject else {
            throw BackupError.conflict("Photos asset disappeared before export")
        }
        guard asset.modificationDate == item.sourceModified else { throw BackupError.conflict("Photos source changed after inventory") }
        let resource = try resolve(item, asset: asset)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor: ExportDescriptor
        if let resource {
            try await stream(resource, to: destination, maximumBytes: maximumBytes)
            descriptor = Self.descriptor(resource)
        } else {
            descriptor = try await exportCurrentFallback(item, asset: asset, to: destination, maximumBytes: maximumBytes)
        }
        try await verify(item)
        return descriptor
    }

    public func exportOriginal(_ item: BackupItem, to destination: URL,
                               maximumBytes: Int64) async throws -> ExportDescriptor {
        guard status == .authorized else { throw BackupError.permission("Photos read authorization was revoked") }
        guard item.representation == .original else { throw BackupError.integrity("only original resources can be mirrored") }
        guard !item.identityAmbiguous else { throw BackupError.integrity("PhotoKit exposes multiple indistinguishable original resources") }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil).firstObject else {
            throw BackupError.conflict("Photos asset disappeared before export")
        }
        guard let resource = try resolve(item, asset: asset) else { throw BackupError.integrity("original resource is unavailable") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            // Network access is enabled only after preflight shows that Azure needs
            // this resource, allowing PhotoKit to fetch originals stored only in iCloud.
            try await stream(resource, to: destination, maximumBytes: maximumBytes, allowNetwork: true)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        do { try await verifyOriginal(item) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return Self.descriptor(resource)
    }

    public func verifyOriginal(_ item: BackupItem) async throws {
        guard item.representation == .original,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil).firstObject else {
            throw BackupError.conflict("Photos original disappeared during export")
        }
        _ = try resolve(item, asset: asset)
    }

    public func verify(_ item: BackupItem) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetID], options: nil).firstObject else {
            throw BackupError.conflict("Photos asset disappeared during export")
        }
        guard asset.modificationDate == item.sourceModified else { throw BackupError.conflict("Photos asset changed during export") }
        _ = try resolve(item, asset: asset)
    }

    private func resolve(_ item: BackupItem, asset: PHAsset) throws -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if item.representation == .current {
            let accepted = PhotoCurrentResourcePolicy.matchingTypes(kind: item.resourceKind, assetIsImage: asset.mediaType == .image)
            let matching = resources.filter { resource in
                guard let typeName = Self.currentTypeName(resource.type) else { return false }
                return accepted.contains(typeName)
            }
            let exact = matching.filter {
                $0.uniformTypeIdentifier == item.uniformType && Self.filename($0) == item.filename
            }
            if exact.count == 1 { return exact[0] }
            if exact.count > 1 { throw BackupError.integrity("current resource is ambiguous") }
            if matching.count > 1 { throw BackupError.integrity("current resource is ambiguous") }
            if resources.contains(where: { $0.type == .adjustmentData }) { return nil }
            let fallback = resources.filter { Self.isOriginal($0.type) && Self.kind(for: $0.type) == item.resourceKind &&
                $0.uniformTypeIdentifier == item.uniformType && Self.filename($0) == item.filename }
            guard fallback.count == 1 else { throw BackupError.integrity("current representation has no unambiguous original fallback") }
            return fallback[0]
        }
        let matches = resources.filter { Self.isOriginal($0.type) && Self.kind(for: $0.type) == item.resourceKind &&
            $0.uniformTypeIdentifier == item.uniformType && Self.filename($0) == item.filename }
        guard matches.count == 1 else { throw BackupError.integrity("original resource changed or became ambiguous since inventory") }
        return matches[0]
    }

    private func stream(_ resource: PHAssetResource, to destination: URL, maximumBytes: Int64,
                        allowNetwork: Bool = true) async throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BackupError.storage("could not create temporary export")
        }
        let handle = try FileHandle(forWritingTo: destination)
        let stateLock = NSLock()
        var written: Int64 = 0
        var exceeded = false
        var requestID: PHAssetResourceDataRequestID = 0
        var cancelRequested = false
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowNetwork
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let issuedID = manager.requestData(for: resource, options: options, dataReceivedHandler: { chunk in
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    guard !exceeded else { return }
                    if written + Int64(chunk.count) > maximumBytes {
                        exceeded = true
                        if requestID == 0 { cancelRequested = true } else { self.manager.cancelDataRequest(requestID) }
                        return
                    }
                    do { try handle.write(contentsOf: chunk); written += Int64(chunk.count) }
                    catch {
                        exceeded = true
                        if requestID == 0 { cancelRequested = true } else { self.manager.cancelDataRequest(requestID) }
                    }
                }, completionHandler: { error in
                    stateLock.lock(); let budgetExceeded = exceeded; let byteCount = written; stateLock.unlock()
                    do { try handle.close() } catch { }
                    if budgetExceeded { continuation.resume(throwing: BackupError.diskBudget(required: byteCount + 1, available: maximumBytes)) }
                    else if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
                stateLock.lock(); requestID = issuedID; let cancelNow = cancelRequested; stateLock.unlock()
                if cancelNow { manager.cancelDataRequest(issuedID) }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func exportCurrentFallback(_ item: BackupItem, asset: PHAsset, to destination: URL,
                                       maximumBytes: Int64) async throws -> ExportDescriptor {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BackupError.integrity("temporary export path already exists")
        }
        if item.resourceKind == "paired-video" {
            if let livePhoto = try await requestCurrentLivePhoto(asset),
               let resource = try currentLivePhotoVideoResource(livePhoto, item: item) {
                try await stream(resource, to: destination, maximumBytes: maximumBytes)
                return Self.descriptor(resource)
            }
        }
        let input = try await requestRenderedEditingInput(asset)
        if item.resourceKind == "image" {
            guard let imageURL = input.fullSizeImageURL else {
                throw BackupError.integrity("Photos did not provide a rendered full-size current image")
            }
            try copyFile(imageURL, to: destination, maximumBytes: maximumBytes)
            let uti = UTType(filenameExtension: imageURL.pathExtension)?.identifier ?? item.uniformType
            let name = imageURL.lastPathComponent.isEmpty ? item.filename : imageURL.lastPathComponent
            return ExportDescriptor(filename: name, uniformType: uti,
                                    contentType: UTType(uti)?.preferredMIMEType ?? "application/octet-stream")
        }
        guard let audiovisualAsset = input.audiovisualAsset else {
            throw BackupError.integrity("Photos did not provide a rendered current video")
        }
        return try await exportAVAsset(audiovisualAsset, item: item, to: destination, maximumBytes: maximumBytes)
    }

    private func requestRenderedEditingInput(_ asset: PHAsset) async throws -> PHContentEditingInput {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // Apple documents false as requesting the latest rendered output of prior edits.
        options.canHandleAdjustmentData = { _ in false }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHContentEditingInput, Error>) in
            _ = asset.requestContentEditingInput(with: options) { input, info in
                if let input { continuation.resume(returning: input); return }
                if info[PHContentEditingInputResultIsInCloudKey] as? Bool == true {
                    continuation.resume(throwing: BackupError.storage("Photos could not download the current rendered resource from iCloud"))
                } else {
                    continuation.resume(throwing: BackupError.integrity("Photos did not return current rendered content"))
                }
            }
        }
    }

    private func requestCurrentLivePhoto(_ asset: PHAsset) async throws -> PHLivePhoto? {
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHLivePhoto?, Error>) in
            PHImageManager.default().requestLivePhoto(for: asset, targetSize: PHImageManagerMaximumSize,
                                                       contentMode: .aspectFit, options: options) { livePhoto, info in
                if info?[PHImageCancelledKey] as? Bool == true {
                    continuation.resume(throwing: BackupError.storage("Photos cancelled current Live Photo retrieval"))
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if info?[PHImageResultIsDegradedKey] as? Bool == true {
                    return
                } else {
                    continuation.resume(returning: livePhoto)
                }
            }
        }
    }

    private func currentLivePhotoVideoResource(_ livePhoto: PHLivePhoto, item: BackupItem) throws -> PHAssetResource? {
        let candidates = PHAssetResource.assetResources(for: livePhoto).filter { resource in
            guard let typeName = Self.currentTypeName(resource.type) else { return false }
            let isMotion = typeName == "fullSizePairedVideo" || typeName == "fullSizeVideo" ||
                typeName == "pairedVideo" || typeName == "video"
            return isMotion && resource.uniformTypeIdentifier == item.uniformType
        }
        guard candidates.count <= 1 else { throw BackupError.integrity("current Live Photo motion resource is ambiguous") }
        return candidates.first
    }

    private func copyFile(_ source: URL, to destination: URL, maximumBytes: Int64) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BackupError.storage("could not create temporary export")
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var written: Int64 = 0
        do {
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                guard written + Int64(chunk.count) <= maximumBytes else {
                    throw BackupError.diskBudget(required: written + Int64(chunk.count), available: maximumBytes)
                }
                try output.write(contentsOf: chunk); written += Int64(chunk.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func exportAVAsset(_ asset: AVAsset, item: BackupItem, to destination: URL,
                               maximumBytes: Int64) async throws -> ExportDescriptor {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw BackupError.integrity("Photos current video cannot be exported with the system renderer")
        }
        let desired = AVFileType(rawValue: item.uniformType)
        let fileType = session.supportedFileTypes.contains(desired) ? desired :
            session.supportedFileTypes.first(where: { $0 == .mov || $0 == .mp4 })
        guard let fileType else { throw BackupError.integrity("Photos current video has no supported output container") }
        session.outputURL = destination; session.outputFileType = fileType
        let overBudget = LockedFlag()
        let finished = LockedFlag()
        let exportSession = SendableExportSession(session)
        let monitor = Task {
            // Keep polling through .unknown/.waiting as well as .exporting: exportAsynchronously
            // can be scheduled after this task first runs.
            while !finished.value && ExportBudgetPolicy.shouldMonitor(Self.progressPhase(session.status)) {
                if let size = try? self.localFileSize(destination), ExportBudgetPolicy.exceedsLimit(currentBytes: size, limit: maximumBytes) {
                    overBudget.set(); session.cancelExport(); break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let status: AVAssetExportSession.Status = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously {
                    let terminalStatus = exportSession.value.status
                    finished.set()
                    continuation.resume(returning: terminalStatus)
                }
            }
        } onCancel: {
            exportSession.value.cancelExport()
        }
        finished.set()
        monitor.cancel()
        if overBudget.value {
            try? FileManager.default.removeItem(at: destination)
            throw BackupError.diskBudget(required: maximumBytes + 1, available: maximumBytes)
        }
        guard status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw BackupError.integrity("Photos current video render failed")
        }
        let size = try localFileSize(destination)
        guard size <= maximumBytes else {
            try? FileManager.default.removeItem(at: destination)
            throw BackupError.diskBudget(required: size, available: maximumBytes)
        }
        let uti = UTType(fileType.rawValue)?.identifier ?? item.uniformType
        let ext = UTType(uti)?.preferredFilenameExtension ?? (fileType == .mp4 ? "mp4" : "mov")
        let base = (item.filename as NSString).deletingPathExtension
        let name = "\(base.isEmpty ? "current" : base).\(ext)"
        return ExportDescriptor(filename: name, uniformType: uti,
                                contentType: UTType(uti)?.preferredMIMEType ?? "application/octet-stream")
    }

    private static func descriptor(_ resource: PHAssetResource) -> ExportDescriptor {
        let uti = resource.uniformTypeIdentifier
        return ExportDescriptor(filename: filename(resource), uniformType: uti,
                                contentType: UTType(uti)?.preferredMIMEType ?? "application/octet-stream")
    }

    private func localFileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs[.size] as? NSNumber)?.int64Value else { throw BackupError.integrity("rendered export size is unavailable") }
        return size
    }

    private static func progressPhase(_ status: AVAssetExportSession.Status) -> ExportProgressPhase {
        switch status {
        case .unknown: return .unknown
        case .waiting: return .waiting
        case .exporting: return .exporting
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        @unknown default: return .unknown
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock(); private var flag = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// AVAssetExportSession supports status polling and cancellation while its async
    /// export is active. Keep its only @Sendable callback capture behind this box.
    private final class SendableExportSession: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    private static func isOriginal(_ type: PHAssetResourceType) -> Bool {
        [.photo, .video, .audio, .alternatePhoto, .pairedVideo].contains(type)
    }
    private static func kind(for type: PHAssetResourceType) -> String {
        switch type {
        case .photo: return "image"
        case .alternatePhoto: return "alternate-image"
        case .video: return "video"
        case .pairedVideo: return "paired-video"
        case .audio: return "audio"
        default: return "other"
        }
    }
    private static func currentKind(_ type: PHAssetResourceType, asset: PHAsset) -> String? {
        guard let typeName = currentTypeName(type) else { return nil }
        return PhotoCurrentResourcePolicy.kind(resourceType: typeName, assetIsImage: asset.mediaType == .image)
    }
    private static func currentTypeName(_ type: PHAssetResourceType) -> String? {
        switch type {
        case .fullSizePhoto: return "fullSizePhoto"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        case .fullSizeVideo: return "fullSizeVideo"
        case .pairedVideo: return "pairedVideo"
        case .video: return "video"
        default: return nil
        }
    }
    private static func dataSize(_ resource: PHAssetResource) -> Int64? {
        guard #available(macOS 27, *), resource.responds(to: Selector(("dataSize"))),
              let value = resource.perform(Selector(("dataSize")))?.takeUnretainedValue() as? NSNumber else { return nil }
        let size = value.int64Value
        return size >= 0 ? size : nil
    }
    private static func filename(_ resource: PHAssetResource) -> String {
        // macOS 27 adds a nullable filename property. Query it dynamically so this
        // target still builds with the macOS 26 SDK used by the stable release runner.
        let filenameSelector = Selector(("filename"))
        if #available(macOS 27, *), resource.responds(to: filenameSelector),
           let filename = resource.perform(filenameSelector)?.takeUnretainedValue() as? String {
            return filename
        }
        return resource.perform(Selector(("originalFilename")))?.takeUnretainedValue() as? String ?? ""
    }
    private static func item(libraryID: String, asset: PHAsset, resourceID: String, resourceKind: String,
                             representation: Representation, filename: String, uti: String, sourceSize: Int64? = nil,
                             identityAmbiguous: Bool = false,
                             exportUnavailableReason: String? = nil) -> BackupItem {
        let contentType = UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
        return BackupItem(libraryID: libraryID, assetID: asset.localIdentifier, resourceID: resourceID,
                          representation: representation, filename: filename, uniformType: uti,
                          sourceModified: asset.modificationDate, creationDate: asset.creationDate, contentType: contentType,
                          sourceSize: sourceSize, identityAmbiguous: identityAmbiguous, resourceKind: resourceKind,
                          exportUnavailableReason: exportUnavailableReason)
    }
}

#else
public final class PhotoKitLibrary: PhotoLibrary {
    public init(libraryID: String, policy: PhotoInventoryPolicy = .completeAccessibleLibrary) {}
    public func authorization() -> String { "unsupported" }
    public func requestAuthorization() async -> String { "unsupported" }
    public func checkAvailability() throws { throw BackupError.permission("PhotoKit is available only on macOS") }
    public func enumerate(filter: DateFilter, consume: (BackupItem) async throws -> Void) async throws { throw BackupError.permission("PhotoKit is available only on macOS") }
    public func enumerateOriginals(filter: DateFilter, consume: (BackupItem) async throws -> Void) async throws { throw BackupError.permission("PhotoKit is available only on macOS") }
    public func export(_ item: BackupItem, to destination: URL, maximumBytes: Int64) async throws -> ExportDescriptor { throw BackupError.permission("PhotoKit is available only on macOS") }
    public func exportOriginal(_ item: BackupItem, to destination: URL, maximumBytes: Int64) async throws -> ExportDescriptor { throw BackupError.permission("PhotoKit is available only on macOS") }
    public func verifyOriginal(_ item: BackupItem) async throws { throw BackupError.permission("PhotoKit is available only on macOS") }
    public func verify(_ item: BackupItem) async throws { throw BackupError.permission("PhotoKit is available only on macOS") }
}
#endif
