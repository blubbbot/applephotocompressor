import Foundation
import Photos
import CryptoKit
import CompressionCore

extension PhotosService {
    // Moving a copy to Shared Library can change its modification date. Accept
    // that only after checking the actual original resources and library fields;
    // never infer shared membership from a private property or database field.
    static func revalidateChangedReplacement(_ record: OperationRecord, original: PHAsset?) async throws -> Date? {
        guard let id = record.replacementID, let replacement = fetch(id),
              replacement.mediaType == (record.kind.isPhoto ? .image : .video),
              !PHAssetResource.assetResources(for: replacement).contains(where: { $0.type == .adjustmentData }) else {
            throw MediaError.invalid("The replacement is missing or edited. The original is retained.")
        }
        let modification = replacement.modificationDate
        if let original {
            try verifyImport(id, original: original, albums: regularAlbums(containing: original), expectedLive: record.kind.isPhoto ? record.outputIsLivePhoto : nil)
        }
        let expectedText: LibraryTextMetadata?
        if let saved = record.sourceTextMetadata { expectedText = saved }
        else if let original { expectedText = try await PhotosScript.readMetadata(id: original.localIdentifier) }
        else { expectedText = nil }
        if let expectedText {
            guard try await PhotosScript.readMetadata(id: id) == expectedText else { throw MediaError.invalid("The replacement's title, caption, or keywords changed. Review those changes in Photos; no item was deleted.") }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCompressor-verify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = PHAssetResource.assetResources(for: replacement)
        var expected: [(PHAssetResourceType, URL)] = [(record.kind.isPhoto ? .photo : .video, URL(fileURLWithPath: record.outputPath))]
        if record.outputIsLivePhoto, let motion = record.pairedVideoPath { expected.append((.pairedVideo, URL(fileURLWithPath: motion))) }
        for (type, archived) in expected {
            let matches = resources.filter { $0.type == type }
            guard matches.count == 1 else { throw MediaError.invalid("The replacement's media resources changed. No item was deleted.") }
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
                PHAssetResourceManager.default().writeData(for: matches[0], toFile: temporary, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let equal = try await Task.detached { try digest(temporary) == digest(archived) }.value
            guard equal else { throw MediaError.invalid("The replacement's content no longer matches its verified archive. No item was deleted.") }
        }
        guard fetch(id)?.modificationDate == modification else { throw MediaError.invalid("The replacement changed while it was checked. Retry after finishing changes in Photos.") }
        return modification
    }

    private static func digest(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }
}
