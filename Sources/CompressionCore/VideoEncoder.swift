@preconcurrency import AVFoundation
import VideoToolbox
import CoreVideo
import AudioToolbox
import CryptoKit

public enum MediaError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw CancellationError() } }
}

public struct MediaInspection: Sendable {
    public let facts: VideoFacts
    public let audioTracks: Int
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let colorMatrix: String?
    public let hasDolbyVision: Bool
    public let audioBitrate: Int
}

public enum VideoEncoder {
    public static func inspect(_ url: URL) async throws -> MediaInspection {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        return try await inspect(asset: AVURLAsset(url: url), bytes: bytes)
    }

    public static func inspect(asset: AVAsset, bytes: Int64? = nil) async throws -> MediaInspection {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.count == 1, let track = videoTracks.first else { throw MediaError.invalid("Only a single ordinary video track is supported. The original is retained.") }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MediaError.invalid("The video has no valid duration.") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let fps = try await track.load(.nominalFrameRate)
        guard fps.isFinite, fps > 0 else {
            throw MediaError.invalid("The original does not report a usable frame rate. It is retained rather than guessing its timing.")
        }
        let formats = try await track.load(.formatDescriptions)
        let ext: NSDictionary = formats.first.flatMap { CMFormatDescriptionGetExtensions($0) }.map { $0 as NSDictionary } ?? [:]
        let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries] as? String
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
        let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix] as? String
        let hdr = transfer == AVVideoTransferFunction_ITU_R_2100_HLG || transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
        let description = ext.description.lowercased()
        let dolby = description.contains("dvcc") || description.contains("dvvc") || description.contains("dolby")
        if dolby && !hdr { throw MediaError.invalid("This Dolby Vision profile has no supported HLG/PQ base layer. The original is retained.") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioBitrate = 0
        for audio in audioTracks { audioBitrate += Int(try await audio.load(.estimatedDataRate)) }
        return MediaInspection(facts: VideoFacts(width: Int(abs(oriented.width).rounded()), height: Int(abs(oriented.height).rounded()), duration: duration, frameRate: Double(fps), bytes: bytes, isHDR: hdr), audioTracks: audioTracks.count, colorPrimaries: primaries, transferFunction: transfer, colorMatrix: matrix, hasDolbyVision: dolby, audioBitrate: audioBitrate)
    }

    public static func encode(source: URL, destination: URL, settings: CompressionSettings, cancellation: CancellationFlag, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaInspection {
        let inspection = try await inspect(source)
        let plan = CompressionPlan(facts: inspection.facts, settings: settings, audioTracks: inspection.audioTracks, audioBitrate: inspection.audioBitrate)
        let asset = AVURLAsset(url: source)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard let track = videos.first else { throw MediaError.invalid("No video track.") }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let metadata = try await asset.load(.metadata)
        let timeRange = try await track.load(.timeRange)
        let audioFormats = try await audios.asyncMap { try await $0.load(.formatDescriptions) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try cancellation.check()
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw MediaError.invalid("The output already exists; it has not been overwritten.") }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let reader = try AVAssetReader(asset: asset)
                    let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
                    writer.metadata = metadata
                    var compression: [String: Any] = [AVVideoAverageBitRateKey: plan.videoBitrate,
                        AVVideoExpectedSourceFrameRateKey: plan.frameRate,
                        AVVideoProfileLevelKey: inspection.facts.isHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel]
                    if inspection.facts.isHDR {
                        compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
                    }
                    var videoSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
                        AVVideoWidthKey: plan.width, AVVideoHeightKey: plan.height,
                        AVVideoCompressionPropertiesKey: compression]
                    #if arch(arm64)
                    let useHardware = true
                    #else
                    let useHardware = false
                    #endif
                    videoSettings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: useHardware]
                    if let p = inspection.colorPrimaries, let t = inspection.transferFunction, let m = inspection.colorMatrix {
                        videoSettings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m]
                    }
                    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw MediaError.invalid("This Mac cannot encode the selected HEVC settings.") }
                    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
                    videoInput.expectsMediaDataInRealTime = false
                    let pixelFormat = inspection.facts.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videos, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
                    let composition = AVMutableVideoComposition()
                    composition.renderSize = CGSize(width: plan.width, height: plan.height)
                    composition.frameDuration = CMTime(seconds: 1 / plan.frameRate, preferredTimescale: 60_000)
                    if settings.frameRate.limit == nil || inspection.facts.frameRate <= plan.frameRate + 0.01 {
                        composition.sourceTrackIDForFrameTiming = track.trackID
                    }
                    composition.colorPrimaries = inspection.colorPrimaries
                    composition.colorTransferFunction = inspection.transferFunction
                    composition.colorYCbCrMatrix = inspection.colorMatrix
                    let bounds = CGRect(origin: .zero, size: size).applying(transform)
                    let scale = CGAffineTransform(scaleX: Double(plan.width) / abs(bounds.width), y: Double(plan.height) / abs(bounds.height))
                    let normalized = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)).concatenating(scale)
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: inspection.facts.duration, preferredTimescale: 60_000))
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    layer.setTransform(normalized, at: .zero)
                    instruction.layerInstructions = [layer]
                    composition.instructions = [instruction]
                    videoOutput.videoComposition = composition
                    videoOutput.alwaysCopiesSampleData = false
                    guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw MediaError.invalid("Cannot configure the video pipeline.") }
                    reader.add(videoOutput); writer.add(videoInput)
                    var outputs: [AVAssetReaderOutput] = [videoOutput]
                    var inputs: [AVAssetWriterInput] = [videoInput]
                    for (index, audio) in audios.enumerated() {
                        // Preserve compressed audio packets, channel layout, and fidelity.
                        let audioOutput = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
                        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormats[index].first)
                        guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { throw MediaError.invalid("Cannot preserve an audio track.") }
                        reader.add(audioOutput); writer.add(audioInput)
                        outputs.append(audioOutput); inputs.append(audioInput)
                    }
                    guard writer.startWriting() else { throw writer.error ?? MediaError.invalid("The encoder could not start.") }
                    writer.startSession(atSourceTime: .zero)
                    guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? MediaError.invalid("The decoder could not start.") }
                    do {
                        var finished = Set<Int>()
                        var lastSample = Date()
                        while finished.count < inputs.count {
                            try cancellation.check()
                            if writer.status == .failed { throw writer.error ?? MediaError.invalid("Encoding failed.") }
                            if reader.status == .failed { throw reader.error ?? MediaError.invalid("Reading failed.") }
                            var advanced = false
                            guard Date().timeIntervalSince(lastSample) < 60 else { throw MediaError.invalid("The media encoder stopped making progress. The original is retained.") }
                            for index in inputs.indices where !finished.contains(index) && inputs[index].isReadyForMoreMediaData {
                                advanced = true
                                try autoreleasepool {
                                    if let sample = outputs[index].copyNextSampleBuffer() {
                                        lastSample = Date()
                                        guard inputs[index].append(sample) else { throw writer.error ?? MediaError.invalid("Could not encode a media sample.") }
                                        if index == 0 { progress(min(0.99, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / inspection.facts.duration))) }
                                    } else {
                                        inputs[index].markAsFinished(); finished.insert(index)
                                    }
                                }
                            }
                            if !advanced { Thread.sleep(forTimeInterval: 0.002) }
                        }
                        guard reader.status != .failed else { throw reader.error ?? MediaError.invalid("Reading failed.") }
                        writer.endSession(atSourceTime: max(timeRange.end, CMTime(seconds: inspection.facts.duration, preferredTimescale: 60_000)))
                        let completion = WriterCompletion(writer)
                        writer.finishWriting {
                            if completion.writer.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: completion.writer.error ?? MediaError.invalid("Could not finish the video.")) }
                        }
                    } catch {
                        reader.cancelReading(); writer.cancelWriting(); throw error
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        try cancellation.check()
        let output = try await inspect(destination)
        guard abs(output.facts.duration - inspection.facts.duration) <= max(0.2, 2 / plan.frameRate),
              output.facts.width == plan.width, output.facts.height == plan.height,
              output.audioTracks == inspection.audioTracks,
              output.facts.isHDR == inspection.facts.isHDR,
              !inspection.facts.isHDR || output.transferFunction == inspection.transferFunction else {
            throw MediaError.invalid("The output did not match the expected duration, dimensions, audio, or HDR properties. The original is retained.")
        }
        try await validateDecode(destination, cancellation: cancellation)
        let originalAudio = try await audioDigests(source, cancellation: cancellation)
        let outputAudio = try await audioDigests(destination, cancellation: cancellation)
        guard originalAudio == outputAudio else { throw MediaError.invalid("The output audio packets did not match the original. The original is retained.") }
        progress(1)
        return output
    }

    private static func validateDecode(_ url: URL, cancellation: CancellationFlag) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        try await Task.detached(priority: .utility) {
            for track in tracks where track.mediaType == .video {
                try cancellation.check()
                let reader = try AVAssetReader(asset: asset)
                let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                guard reader.canAdd(output) else { throw MediaError.invalid("Cannot validate an output track.") }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? MediaError.invalid("Cannot decode the output.") }
                var samples = 0
                do {
                    while reader.status == .reading {
                        try cancellation.check()
                        let hasSample = autoreleasepool { output.copyNextSampleBuffer() != nil }
                        if !hasSample { break }; samples += 1
                    }
                    guard reader.status == .completed, samples > 0 else { throw reader.error ?? MediaError.invalid("An output track did not decode completely.") }
                } catch { reader.cancelReading(); throw error }
            }
        }.value
    }

    private static func audioDigests(_ url: URL, cancellation: CancellationFlag) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        return try await Task.detached(priority: .utility) {
            var result: [String] = []
            for track in tracks {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? MediaError.invalid("Cannot verify audio packets.") }
                var hash = SHA256(); var bytes = 0
                do {
                    while reader.status == .reading {
                        try cancellation.check()
                        let found = try autoreleasepool {
                            guard let sample = output.copyNextSampleBuffer() else { return false }
                            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                                // Readers may emit zero-byte timing/edit markers between packets.
                                if CMSampleBufferGetTotalSampleSize(sample) == 0 { return true }
                                throw MediaError.invalid("Missing audio sample data.")
                            }
                            var data = Data(count: CMBlockBufferGetDataLength(block))
                            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                            guard status == noErr else { throw MediaError.invalid("Cannot read audio sample data.") }
                            hash.update(data: data); bytes += data.count
                            return true
                        }
                        if !found { break }
                    }
                    guard reader.status == .completed, bytes > 0 else { throw reader.error ?? MediaError.invalid("The audio track is incomplete.") }
                    result.append(hash.finalize().map { String(format: "%02x", $0) }.joined())
                } catch { reader.cancelReading(); throw error }
            }
            return result
        }.value
    }
}

// Ownership of the legacy writer moves to its completion handler after finishing.
private final class WriterCompletion: @unchecked Sendable {
    let writer: AVAssetWriter
    init(_ writer: AVAssetWriter) { self.writer = writer }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for item in self { result.append(try await transform(item)) }
        return result
    }
}
