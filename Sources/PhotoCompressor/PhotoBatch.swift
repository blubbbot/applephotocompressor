import Foundation
import Photos
import CompressionCore

extension AppModel {
    func encodePhoto(video: LibraryVideo, original: PHAsset?, source: URL, output: URL, record: inout OperationRecord,
                     settings: PhotoCompressionSettings, cancellation: CancellationFlag) async throws {
        guard let journal else { throw MediaError.invalid("The operation journal is unavailable.") }
        if video.kind == .livePhoto {
            guard let original else { throw MediaError.invalid("The Live Photo is no longer available in Photos.") }
            let motion = source.deletingLastPathComponent().appendingPathComponent("Original Live Photo motion.mov")
            record.pairedVideoPath = motion.path
            try await journal.save(record)
            statuses[video.id] = RowStatus(text: "Archiving Live Photo motion and sound…")
            try await PhotosService.archiveMotion(original, to: motion)
            record.pairedVideoBytes = Int64(try motion.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            _ = try await PhotosService.livePhoto(photo: source, motion: motion)
        }
        try cancellation.check()
        let facts = try await Task.detached { try PhotoEncoder.inspect(source) }.value
        record.photoFacts = facts
        record.originalBytes = facts.bytes + (record.pairedVideoBytes ?? 0)
        record.sourceFacts = VideoFacts(width: facts.width, height: facts.height, duration: 0, frameRate: 0, bytes: record.originalBytes)
        if let index = videos.firstIndex(where: { $0.id == video.id }), let sourceFacts = record.sourceFacts {
            videos[index].facts = sourceFacts; videos[index].factsAreMeasured = true
            videos[index].photoFormat = facts.format
        }
        record.stage = .archived; try await journal.save(record)
        statuses[video.id] = RowStatus(text: "Encoding and validating HEIC photo…")
        let encoded = try await Task.detached { try PhotoEncoder.encode(source: source, destination: output, settings: settings, cancellation: cancellation) }.value
        try cancellation.check()
        if record.outputIsLivePhoto, let path = record.pairedVideoPath {
            statuses[video.id] = RowStatus(text: "Verifying Live Photo pairing…")
            _ = try await PhotosService.livePhoto(photo: output, motion: URL(fileURLWithPath: path))
        }
        record.outputPhotoFacts = encoded
        record.outputBytes = encoded.bytes + (record.outputIsLivePhoto ? (record.pairedVideoBytes ?? 0) : 0)
    }
}
