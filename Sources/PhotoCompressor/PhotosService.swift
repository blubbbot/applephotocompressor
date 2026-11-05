import AppKit
import Photos
import AVFoundation
import CompressionCore
import UniformTypeIdentifiers

struct LibraryVideo: Identifiable {
    let id: String
    var name: String
    let asset: PHAsset?
    let fileURL: URL?
    var facts: VideoFacts
    let date: Date
    let unsupportedReason: String?
    var isDemo = false
    var factsAreMeasured = false
    var isSlowMotion = false
    var kind: MediaKind = .video
    var photoFormat: String?
    var isPanorama = false

    var sharingIdentity: SharedLibraryAssetIdentity? {
        guard asset != nil else { return nil }
        return SharedLibraryAssetIdentity(localIdentifier: id, filename: name, isVideo: !kind.isPhoto, creationDate: date == .distantPast ? nil : date)
    }

    var hasInspectedFacts: Bool { factsAreMeasured || fileURL != nil || isDemo }
}

typealias ScriptMetadata = LibraryTextMetadata

enum PhotosScript {
    static func reveal(id: String) async throws {
        let script = """
        function run(args) {
            const photos = Application('Photos');
            const item = photos.mediaItems.byId(args[0]);
            if (!item.exists()) return 'missing';
            photos.activate();
            photos.spotlight(item);
            return 'ok';
        }
        """
        let response = try await execute(script, arguments: [id])
        guard String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
            throw MediaError.invalid("This video is no longer available in the open Photos library. It may have been deleted or moved to a different library. Refresh the library, or show its compressed copy from History.")
        }
    }

    static func execute(_ script: String, arguments: [String] = []) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".js")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: scriptURL) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", scriptURL.path] + arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            guard process.terminationStatus == 0 else {
                let detail = String(data: data, encoding: .utf8) ?? "Unknown scripting error"
                throw MediaError.invalid("Photos automation failed. Allow Photo Compressor to control Photos in System Settings → Privacy & Security → Automation. \(detail.prefix(500))")
            }
            return data
        }.value
    }

    static func sizes() async throws -> [String: Int64] {
        let script = """
        function run() {
            const photos = Application('Photos');
            const ids = photos.mediaItems.id();
            const sizes = photos.mediaItems.size();
            const check = photos.mediaItems.id();
            if (ids.length !== sizes.length || JSON.stringify(ids) !== JSON.stringify(check))
                throw new Error('The library changed while reading sizes. Refresh to try again.');
            const result = {};
            for (let i = 0; i < ids.length; i++) {
                const size = Number(sizes[i]);
                if (Number.isFinite(size) && size > 0) result[ids[i]] = Math.round(size);
            }
            return JSON.stringify(result);
        }
        """
        return try JSONDecoder().decode([String: Int64].self, from: await execute(script))
    }

    static func readMetadata(id: String) async throws -> ScriptMetadata {
        let script = """
        function run(args) {
            const item = Application('Photos').mediaItems.byId(args[0]);
            return JSON.stringify({title: String(item.name() || ''), caption: String(item.description() || ''), keywords: item.keywords() || []});
        }
        """
        return try JSONDecoder().decode(ScriptMetadata.self, from: await execute(script, arguments: [id]))
    }

    static func restoreMetadata(_ metadata: ScriptMetadata, id: String) async throws {
        let data = try JSONEncoder().encode(metadata)
        let script = """
        function run(args) {
            const item = Application('Photos').mediaItems.byId(args[0]);
            const expected = JSON.parse(args[1]);
            item.name = expected.title;
            item.description = expected.caption;
            item.keywords = expected.keywords;
            const actual = {title: String(item.name() || ''), caption: String(item.description() || ''), keywords: item.keywords() || []};
            if (actual.title !== expected.title || actual.caption !== expected.caption ||
                JSON.stringify(actual.keywords.slice().sort()) !== JSON.stringify(expected.keywords.slice().sort()))
                throw new Error('Title, caption, or keywords did not transfer correctly. Original retained.');
            return 'ok';
        }
        """
        _ = try await execute(script, arguments: [id, String(decoding: data, as: UTF8.self)])
    }
}

enum PhotosService {
    static func authorize() async throws {
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String,
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaError.invalid("This build is missing its Photos permission description (NSPhotoLibraryUsageDescription). Open the rebuilt Photo Compressor.app bundle rather than the bare executable.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw MediaError.invalid("Full Photos access is needed to browse and replace videos. Enable it in System Settings → Privacy & Security → Photos.") }
    }

    static func videos(photos: Bool = false, previous: [LibraryVideo] = [], history: [OperationRecord] = []) async throws -> [LibraryVideo] {
        let worker = Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            let assets = PHAsset.fetchAssets(with: photos ? .image : .video, options: options)
            var slowMotionIDs = Set<String>()
            if !photos {
                let slowMotionAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSlomoVideos, options: nil)
                slowMotionAlbums.enumerateObjects { album, _, stop in
                    if Task.isCancelled { stop.pointee = true; return }
                    PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, stop in
                        if Task.isCancelled { stop.pointee = true; return }
                        slowMotionIDs.insert(asset.localIdentifier)
                    }
                }
            }
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let historyByID = Dictionary(history.map { ($0.sourceID, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [LibraryVideo] = []
            result.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                autoreleasepool {
                    let resources = PHAssetResource.assetResources(for: asset)
                    let original = resources.first(where: { $0.type == (photos ? .photo : .video) })
                    let slowMotion = asset.mediaSubtypes.contains(.videoHighFrameRate) || slowMotionIDs.contains(asset.localIdentifier)
                    let reason = slowMotion ? "Slo-mo protected: the captured frames and slow-motion timing are kept by excluding this video from compression." : protectionReason(for: asset, resources: resources)
                    var item = LibraryVideo(id: asset.localIdentifier, name: original?.originalFilename ?? (photos ? "Photo" : "Video"), asset: asset, fileURL: nil,
                        facts: VideoFacts(width: asset.pixelWidth, height: asset.pixelHeight, duration: asset.duration),
                        date: asset.creationDate ?? .distantPast, unsupportedReason: reason, isSlowMotion: slowMotion,
                        kind: photos ? (asset.mediaSubtypes.contains(.photoLive) ? .livePhoto : .photo) : .video,
                        photoFormat: photos ? original?.uniformTypeIdentifier : nil, isPanorama: asset.mediaSubtypes.contains(.photoPanorama))
                    if let old = previousByID[item.id], old.asset?.modificationDate == asset.modificationDate, old.hasInspectedFacts {
                        item.facts = old.facts; item.factsAreMeasured = true
                    } else if let record = historyByID[item.id], record.sourceModifiedAt == asset.modificationDate, let facts = record.sourceFacts {
                        item.facts = facts; item.factsAreMeasured = true
                    }
                    result.append(item)
                }
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    static func protectionReason(for asset: PHAsset, resources: [PHAssetResource]? = nil) -> String? {
        if asset.mediaType == .image { return photoProtectionReason(asset, resources: resources) }
        if asset.mediaSubtypes.contains(.videoHighFrameRate) { return "Slo-mo protected: the captured frames and slow-motion timing are retained." }
        if asset.mediaSubtypes.contains(.videoCinematic) { return "Cinematic video: depth and focus adjustments need a dedicated export path." }
        if asset.mediaSubtypes.contains(.spatialMedia) { return "Spatial video: stereo/depth information needs a dedicated export path." }
        if (resources ?? PHAssetResource.assetResources(for: asset)).contains(where: { $0.type == .adjustmentData }) { return "Edited video: Photos adjustment history needs a separate export path." }
        if asset.sourceType.contains(.typeCloudShared) { return "Shared-album items cannot be safely replaced with their sharing history." }
        return nil
    }

    static func inspectOriginal(_ asset: PHAsset, allowNetwork: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> VideoFacts? {
        if let reason = protectionReason(for: asset) { throw MediaError.invalid(reason) }
        let request = OriginalVideoRequest()
        let original: AVAsset? = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard request.attach(continuation) else { return }
                let options = PHVideoRequestOptions()
                options.version = .original
                options.isNetworkAccessAllowed = allowNetwork
                options.progressHandler = { fraction, _, _, _ in progress(fraction) }
                let id = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { original, _, info in
                    let error = info?[PHImageErrorKey] as? NSError
                    let needsNetwork = (info?[PHImageResultIsInCloudKey] as? Bool) == true ||
                        (error?.domain == PHPhotosErrorDomain && error?.code == PHPhotosError.Code.networkAccessRequired.rawValue)
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        request.finish(.failure(CancellationError()))
                    } else if let original {
                        request.finish(.success(original))
                    } else if !allowNetwork, needsNetwork {
                        request.finish(.success(nil))
                    } else if let error {
                        request.finish(.failure(error))
                    } else if !allowNetwork {
                        request.finish(.success(nil))
                    } else {
                        request.finish(.failure(MediaError.invalid("Photos could not provide the original video for inspection.")))
                    }
                }
                request.setID(id)
            }
        }, onCancel: { request.cancel() })
        try Task.checkCancellation()
        guard let original else { return nil }
        var bytes: Int64?
        if let url = (original as? AVURLAsset)?.url, url.isFileURL {
            bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }
        let inspection = try await VideoEncoder.inspect(asset: original, bytes: bytes)
        try Task.checkCancellation()
        return inspection.facts
    }

    static func thumbnail(_ asset: PHAsset, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func preview(_ asset: PHAsset) async throws -> AVPlayerItem {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true; options.deliveryMode = .automatic; options.version = .current
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: info?[PHImageErrorKey] as? Error ?? MediaError.invalid("Photos could not load this preview from iCloud.")) }
            }
        }
    }

    static func archive(_ asset: PHAsset, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let resources = PHAssetResource.assetResources(for: asset)
        if let reason = protectionReason(for: asset, resources: resources) { throw MediaError.invalid(reason) }
        guard let resource = resources.first(where: { $0.type == (asset.mediaType == .image ? .photo : .video) }) else {
            throw MediaError.invalid("This video was edited or has no supported original resource. It has been kept.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true; options.progressHandler = progress
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    static func regularAlbums(containing asset: PHAsset) -> [PHAssetCollection] {
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [PHAssetCollection] = []
        collections.enumerateObjects { collection, _, _ in
            if collection.assetCollectionSubtype == .albumRegular { albums.append(collection) }
        }
        return albums
    }

    static func importVideo(_ url: URL, original: PHAsset, albums: [PHAssetCollection], resourceFilename: String? = nil, pairedVideo: URL? = nil) async throws -> String {
        guard albums.allSatisfy({ $0.canPerform(.addContent) }) else { throw MediaError.invalid("One of the original's albums is not writable. The original is retained.") }
        var identifier: String?
        try await change {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = resourceFilename ?? url.lastPathComponent
            request.addResource(with: original.mediaType == .image ? .photo : .video, fileURL: url, options: options)
            if let pairedVideo { request.addResource(with: .pairedVideo, fileURL: pairedVideo, options: nil) }
            request.creationDate = original.creationDate; request.location = original.location
            request.isFavorite = original.isFavorite; request.isHidden = original.isHidden
            if let placeholder = request.placeholderForCreatedAsset {
                identifier = placeholder.localIdentifier
                for album in albums { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
            }
        }
        guard let identifier else { throw MediaError.invalid("Photos did not return an identifier for the new video.") }
        return identifier
    }

    static func verifyImport(_ identifier: String, original: PHAsset, albums: [PHAssetCollection], expectedLive: Bool? = nil) throws {
        guard let imported = fetch(identifier), imported.mediaType == original.mediaType,
              original.mediaType == .image || abs(imported.duration - original.duration) < 0.25,
              imported.isFavorite == original.isFavorite, imported.isHidden == original.isHidden,
              abs((imported.creationDate ?? .distantPast).timeIntervalSince(original.creationDate ?? .distantPast)) < 1,
              Set(regularAlbums(containing: imported).map(\.localIdentifier)).isSuperset(of: Set(albums.map(\.localIdentifier))) else {
            throw MediaError.invalid("Photos import or library metadata verification failed. The original is retained. Check the imported copy before retrying.")
        }
        if let expectedLive, imported.mediaSubtypes.contains(.photoLive) != expectedLive {
            throw MediaError.invalid("The imported photo's Live Photo status was not preserved as requested. The original is retained.")
        }
        if let expected = original.location {
            guard let location = imported.location, location.distance(from: expected) < 2 else { throw MediaError.invalid("The capture location did not transfer. The original is retained.") }
        }
    }

    static func fetch(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

    static func restoredVideo(named filename: String, photos: Bool = false) async throws -> PHAsset? {
        try await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions(); options.includeHiddenAssets = true
            var matches: [PHAsset] = []
            PHAsset.fetchAssets(with: photos ? .image : .video, options: options).enumerateObjects { asset, _, _ in
                if PHAssetResource.assetResources(for: asset).contains(where: { $0.type == (photos ? .photo : .video) && $0.originalFilename == filename }) {
                    matches.append(asset)
                }
            }
            guard matches.count <= 1 else { throw MediaError.invalid("Multiple restored originals were found. Check them in Photos before continuing; no video was deleted.") }
            return matches.first
        }.value
    }

    static func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await change { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
    }

    private static func change(_ body: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(body) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? MediaError.invalid("Photos declined the library change.")) }
            }
        }
    }
}

// Resume at most once, even if cancellation races PhotoKit's callback or occurs
// before PhotoKit returns the request ID.
private final class OriginalVideoRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AVAsset?, Error>?
    private var requestID: PHImageRequestID?
    private var completed = false
    private var cancelled = false

    func attach(_ continuation: CheckedContinuation<AVAsset?, Error>) -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); continuation.resume(throwing: CancellationError()); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setID(_ id: PHImageRequestID) {
        lock.lock(); requestID = id; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(id) }
    }

    func finish(_ result: Result<AVAsset?, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock(); cancelled = true; let id = requestID; lock.unlock()
        finish(.failure(CancellationError()))
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}
