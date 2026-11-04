import AppKit
import Photos
import AVFoundation
import CompressionCore

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

    var hasInspectedFacts: Bool { factsAreMeasured || fileURL != nil || isDemo }
}

struct ScriptMetadata: Codable, Equatable {
    let title: String
    let caption: String
    let keywords: [String]
}

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

    static func videos() async -> [LibraryVideo] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.includeHiddenAssets = false
            let assets = PHAsset.fetchAssets(with: .video, options: options)
            var result: [LibraryVideo] = []
            assets.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let original = resources.first(where: { $0.type == .video })
                var reason: String?
                if asset.mediaSubtypes.contains(.videoHighFrameRate) { reason = "Slow-motion video: special timing is retained by keeping the original." }
                if asset.mediaSubtypes.contains(.videoCinematic) { reason = "Cinematic video: depth and focus adjustments need a dedicated export path." }
                if asset.mediaSubtypes.contains(.spatialMedia) { reason = "Spatial video: stereo/depth information needs a dedicated export path." }
                if resources.contains(where: { $0.type == .adjustmentData }) { reason = "Edited video: Photos adjustment history needs a separate export path." }
                if asset.sourceType.contains(.typeCloudShared) { reason = "Shared-album items cannot be safely replaced with their sharing history." }
                result.append(LibraryVideo(id: asset.localIdentifier, name: original?.originalFilename ?? "Video", asset: asset, fileURL: nil,
                    facts: VideoFacts(width: asset.pixelWidth, height: asset.pixelHeight, duration: asset.duration),
                    date: asset.creationDate ?? .distantPast, unsupportedReason: reason))
            }
            return result
        }.value
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
        guard !resources.contains(where: { $0.type == .adjustmentData }),
              let resource = resources.first(where: { $0.type == .video }) else {
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

    static func importVideo(_ url: URL, original: PHAsset, albums: [PHAssetCollection]) async throws -> String {
        guard albums.allSatisfy({ $0.canPerform(.addContent) }) else { throw MediaError.invalid("One of the original's albums is not writable. The original is retained.") }
        var identifier: String?
        try await change {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
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

    static func verifyImport(_ identifier: String, original: PHAsset, albums: [PHAssetCollection]) throws {
        guard let imported = fetch(identifier), abs(imported.duration - original.duration) < 0.25,
              imported.isFavorite == original.isFavorite, imported.isHidden == original.isHidden,
              abs((imported.creationDate ?? .distantPast).timeIntervalSince(original.creationDate ?? .distantPast)) < 1,
              Set(regularAlbums(containing: imported).map(\.localIdentifier)).isSuperset(of: Set(albums.map(\.localIdentifier))) else {
            throw MediaError.invalid("Photos import or library metadata verification failed. The original is retained. Check the imported copy before retrying.")
        }
        if let expected = original.location {
            guard let location = imported.location, location.distance(from: expected) < 2 else { throw MediaError.invalid("The capture location did not transfer. The original is retained.") }
        }
    }

    static func fetch(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

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
