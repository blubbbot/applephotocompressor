import XCTest
import AVFoundation
import CoreVideo
import AudioToolbox
import VideoToolbox
@testable import CompressionCore

final class VideoEncoderTests: XCTestCase {
    func testGeneratedHLGRemainsHDRThroughEncodingAndValidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hdr.mov")
        try await makeVideo(source, width: 640, height: 360, fps: 30, seconds: 0.6, hdr: true)
        let before = try await VideoEncoder.inspect(source)
        XCTAssertTrue(before.facts.isHDR)
        let output = try await VideoEncoder.encode(source: source, destination: directory.appendingPathComponent("hdr-output.mov"), settings: CompressionSettings(), cancellation: CancellationFlag(), progress: { _ in })
        XCTAssertTrue(output.facts.isHDR)
        XCTAssertEqual(output.transferFunction, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(output.colorPrimaries, AVVideoColorPrimaries_ITU_R_2020)
    }

    func testRealEncodeDownscalesPortraitCapsFramesAndRetainsAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCompressor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if ProcessInfo.processInfo.environment["PHOTO_COMPRESSOR_KEEP_FIXTURES"] == nil { try? FileManager.default.removeItem(at: directory) } }
        let source = directory.appendingPathComponent("portrait-with-audio.mov")
        try await makeVideo(source, width: 1440, height: 810, fps: 60, seconds: 1.2, portrait: true, withAudio: true, compressedAudio: true)
        let before = try await VideoEncoder.inspect(source)
        XCTAssertEqual(before.facts.width, 810); XCTAssertEqual(before.facts.height, 1440)
        XCTAssertEqual(before.audioTracks, 1)
        var settings = CompressionSettings(); settings.resolution = .hd; settings.frameRate = .thirty
        let destination = directory.appendingPathComponent("compressed.mov")
        let output = try await VideoEncoder.encode(source: source, destination: destination, settings: settings, cancellation: CancellationFlag(), progress: { _ in })
        XCTAssertEqual(output.facts.width, 720); XCTAssertEqual(output.facts.height, 1280)
        XCTAssertEqual(output.facts.frameRate, 30, accuracy: 1)
        XCTAssertEqual(output.facts.duration, before.facts.duration, accuracy: 0.15)
        XCTAssertEqual(output.audioTracks, 1)
        XCTAssertGreaterThan(output.facts.bytes ?? 0, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        if ProcessInfo.processInfo.environment["PHOTO_COMPRESSOR_KEEP_FIXTURES"] != nil { print("Fixture directory: \(directory.path)") }
    }

    func testCancellationRetainsSourceAndAnExistingOutputIsNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(source, width: 320, height: 180, fps: 24, seconds: 0.5)
        let destination = directory.appendingPathComponent("existing.mov")
        let sentinel = Data("existing output".utf8); try sentinel.write(to: destination)
        do {
            _ = try await VideoEncoder.encode(source: source, destination: destination, settings: CompressionSettings(), cancellation: CancellationFlag(), progress: { _ in })
            XCTFail("An existing output must not be overwritten")
        } catch { XCTAssertEqual(try Data(contentsOf: destination), sentinel) }
        let flag = CancellationFlag(); flag.cancel()
        let cancelled = directory.appendingPathComponent("cancelled.mov")
        do {
            _ = try await VideoEncoder.encode(source: source, destination: cancelled, settings: CompressionSettings(), cancellation: flag, progress: { _ in })
            XCTFail("A cancelled operation must not start encoding")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRealEncodePreservesLowFrameRateAndSmallDimensionsWithoutAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(source, width: 320, height: 180, fps: 15, seconds: 1)
        let output = try await VideoEncoder.encode(source: source, destination: directory.appendingPathComponent("output.mov"), settings: CompressionSettings(), cancellation: CancellationFlag(), progress: { _ in })
        XCTAssertEqual(output.facts.width, 320); XCTAssertEqual(output.facts.height, 180)
        XCTAssertEqual(output.facts.frameRate, 15, accuracy: 0.1)
        XCTAssertEqual(output.audioTracks, 0)
    }

    private func makeVideo(_ url: URL, width: Int, height: Int, fps: Int, seconds: Double, portrait: Bool = false, withAudio: Bool = false, compressedAudio: Bool = false, hdr: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var videoSettings: [String: Any] = [AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000], AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]]
        if hdr {
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 2_000_000, AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
            videoSettings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        if portrait { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        var pixelAttributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height]
        if !hdr { pixelAttributes[kCVPixelBufferCGImageCompatibilityKey as String] = true; pixelAttributes[kCVPixelBufferCGBitmapContextCompatibilityKey as String] = true }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pixelAttributes)
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        var audioFormat: CMAudioFormatDescription?
        if withAudio {
            var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat) == noErr else { throw MediaError.invalid("Cannot create test audio format.") }
            let audioSettings: [String: Any]? = compressedAudio ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 64_000] : nil
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
            writer.add(audio); audioInput = audio
        }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(Double(fps) * seconds) {
            let deadline = Date().addingTimeInterval(20)
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                guard Date() < deadline else { throw MediaError.invalid("Timed out generating the fixture.") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try autoreleasepool {
                var optional: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let pixel = optional else { throw MediaError.invalid("Cannot allocate test pixels.") }
                CVPixelBufferLockBaseAddress(pixel, [])
                defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                if hdr {
                    for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
                        let pointer = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!.assumingMemoryBound(to: UInt16.self)
                        let count = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) / 2 * CVPixelBufferGetHeightOfPlane(pixel, plane)
                        for index in 0..<count { pointer[index] = UInt16(plane == 0 ? 300 + frame * 5 : 512) << 6 }
                    }
                    CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
                    CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
                    CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
                } else {
                    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                    context.setFillColor(CGColor(red: 0.15, green: 0.25, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    for stripe in 0..<20 {
                        context.setFillColor(CGColor(red: CGFloat(stripe % 5) / 5, green: CGFloat((stripe + frame) % 7) / 7, blue: 0.6, alpha: 1))
                        context.fill(CGRect(x: (stripe * width / 20 + frame * 5) % width, y: stripe * height / 20, width: width / 12, height: height / 7))
                    }
                }
                guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error ?? MediaError.invalid("Cannot append test pixels.") }
            }
            if let audio = audioInput, let format = audioFormat {
                let deadline = Date().addingTimeInterval(20)
                while !audio.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    guard Date() < deadline else { throw MediaError.invalid("Timed out generating audio.") }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let count = 48_000 / fps
                let values = (0..<count).map { Int16(sin(Double(frame * count + $0) * 2 * .pi * 440 / 48_000) * 5_000) }
                var block: CMBlockBuffer?
                guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw MediaError.invalid("Cannot allocate audio samples.") }
                let copied = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count) }
                guard copied == noErr else { throw MediaError.invalid("Cannot copy audio samples.") }
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 48_000), decodeTimeStamp: .invalid)
                var bytesPerSample = 2
                var sample: CMSampleBuffer?
                guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &bytesPerSample, sampleBufferOut: &sample) == noErr, let sample, audio.append(sample) else { throw writer.error ?? MediaError.invalid("Cannot append audio samples.") }
            }
        }
        audioInput?.markAsFinished()
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaError.invalid("Cannot finish the fixture.") }
    }

}
