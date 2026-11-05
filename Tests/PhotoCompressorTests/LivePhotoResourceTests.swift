import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreVideo
import Photos
import VideoToolbox
import CompressionCore
@testable import PhotoCompressor

final class LivePhotoResourceTests: XCTestCase {
    func testReencodedStillKeepsAValidLivePhotoPairAndOriginalMotionBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCompressor-live-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifier = UUID().uuidString
        let photo = directory.appendingPathComponent("original.jpg"), motion = directory.appendingPathComponent("motion.mov")
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        // The fixture represents the identifier carried in exported Apple
        // MakerNote metadata. Production code copies metadata without parsing it.
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let writer = try AVAssetWriter(outputURL: motion, fileType: .mov)
        let contentID = AVMutableMetadataItem(); contentID.identifier = .quickTimeMetadataContentIdentifier; contentID.value = identifier as NSString
        writer.metadata = [contentID]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        var format: CMMetadataFormatDescription?
        let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                                           kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]
        XCTAssertEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &format), noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata); writer.add(metadata)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let imageTime = AVMutableMetadataItem(); imageTime.keySpace = .quickTimeMetadata
        imageTime.key = "com.apple.quicktime.still-image-time" as NSString
        imageTime.value = 0 as NSNumber; imageTime.dataType = kCMMetadataBaseDataType_SInt8 as String
        XCTAssertTrue(timed.append(AVTimedMetadataGroup(items: [imageTime], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)))))
        metadata.markAsFinished()
        for frame in 0..<30 {
            let deadline = Date().addingTimeInterval(10)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status != .failed else { throw writer.error ?? MediaError.invalid("Fixture writer timed out") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(pixels.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, []); memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame * 3), CVPixelBufferGetBytesPerRow(pixel) * 180); CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(pixels.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1)); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        _ = try await PhotosService.livePhoto(photo: photo, motion: motion)
        let motionData = try Data(contentsOf: motion)
        let output = directory.appendingPathComponent("compressed.heic")
        _ = try PhotoEncoder.encode(source: photo, destination: output, settings: PhotoCompressionSettings(), cancellation: CancellationFlag())
        _ = try await PhotosService.livePhoto(photo: output, motion: motion)
        XCTAssertEqual(try Data(contentsOf: motion), motionData)
    }
}
