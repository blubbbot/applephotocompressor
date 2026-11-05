import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CompressionCore

final class PhotoEncoderTests: XCTestCase {
    func testJPEGToHEICRetainsDimensionsOrientationAndCaptureMetadata() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg"), output = directory.appendingPathComponent("output.heic")
        try fixture(source, width: 640, height: 480, orientation: 6)
        let original = try Data(contentsOf: source)
        let result = try PhotoEncoder.encode(source: source, destination: output, settings: PhotoCompressionSettings(), cancellation: CancellationFlag())
        XCTAssertEqual(result.width, 480); XCTAssertEqual(result.height, 640)
        XCTAssertEqual(result.format, UTType.heic.identifier)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2020:06:15 12:34:56")
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitude] as? Double, 48.5)
    }

    func testResizeHandlesOrientationWithoutUpscaling() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg")
        try fixture(source, width: 2304, height: 1536, orientation: 6)
        var settings = PhotoCompressionSettings(); settings.resolution = .small
        let output = try PhotoEncoder.encode(source: source, destination: directory.appendingPathComponent("small.heic"), settings: settings, cancellation: CancellationFlag())
        XCTAssertEqual(output.width, 1280); XCTAssertEqual(output.height, 1920)
        let small = PhotoEncoder.dimensions(width: 320, height: 240, resolution: .large)
        XCTAssertEqual(small.0, 320); XCTAssertEqual(small.1, 240)
    }

    func testCancellationAndExistingOutputNeverOverwriteOriginalFiles() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg"), output = directory.appendingPathComponent("output.heic")
        try fixture(source, width: 64, height: 64)
        let sentinel = Data("existing output".utf8); try sentinel.write(to: output)
        XCTAssertThrowsError(try PhotoEncoder.encode(source: source, destination: output, settings: PhotoCompressionSettings(), cancellation: CancellationFlag()))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        let cancelled = CancellationFlag(); cancelled.cancel()
        let other = directory.appendingPathComponent("cancelled.heic")
        XCTAssertThrowsError(try PhotoEncoder.encode(source: source, destination: other, settings: PhotoCompressionSettings(), cancellation: cancelled))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testExistingHEICCanBeReencodedAndPNGIsProtected() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg"), first = directory.appendingPathComponent("first.heic")
        try fixture(source, width: 640, height: 480)
        _ = try PhotoEncoder.encode(source: source, destination: first, settings: PhotoCompressionSettings(), cancellation: CancellationFlag())
        var settings = PhotoCompressionSettings(); settings.quality = 0.5
        let second = try PhotoEncoder.encode(source: first, destination: directory.appendingPathComponent("second.heic"), settings: settings, cancellation: CancellationFlag())
        XCTAssertEqual(second.width, 640); XCTAssertEqual(second.height, 480)
        let png = directory.appendingPathComponent("protected.png")
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(writer, reader, 0, nil); XCTAssertTrue(CGImageDestinationFinalize(writer))
        XCTAssertThrowsError(try PhotoEncoder.inspect(png))
    }

    func testLivePhotoManifestCountsMotionAndRequiresEveryOriginalResource() {
        var record = OperationRecord(sourceID: "live", sourceName: "live.jpg", backupPath: "/backup/live.jpg", outputPath: "/backup/small.heic", settings: CompressionSettings())
        record.mediaKind = .livePhoto; record.photoSettings = PhotoCompressionSettings()
        record.photoFacts = PhotoFacts(width: 100, height: 100, bytes: 900, format: UTType.jpeg.identifier)
        record.outputPhotoFacts = PhotoFacts(width: 100, height: 100, bytes: 200, format: UTType.heic.identifier)
        record.pairedVideoPath = "/backup/motion.mov"; record.pairedVideoBytes = 400
        record.originalBytes = 1300; record.outputBytes = 600; record.replacementID = "copy"; record.metadataVerified = true; record.stage = .readyToDelete
        XCTAssertTrue(record.isDeletionCandidate)
        XCTAssertEqual(record.originalFileBytes, 900); XCTAssertEqual(record.outputFileBytes, 200)
        XCTAssertEqual(record.archiveFiles.count, 3)
        record.photoSettings?.convertLiveToStill = true; record.outputBytes = 200
        XCTAssertTrue(record.isDeletionCandidate)
        XCTAssertFalse(record.outputIsLivePhoto)
        XCTAssertEqual(record.archiveFiles.count, 3, "Conversion must still archive original motion for recovery")
        record.pairedVideoPath = nil
        XCTAssertFalse(record.isDeletionCandidate)
    }

    func testNewPhotoFieldsPersistAndOldRecordsDefaultToVideo() throws {
        var record = OperationRecord(sourceID: "photo", sourceName: "image.jpg", backupPath: "/original", outputPath: "/copy", settings: CompressionSettings())
        XCTAssertEqual(record.kind, .video)
        record.mediaKind = .livePhoto; record.photoSettings = PhotoCompressionSettings(); record.pairedVideoPath = "/motion"
        let decoded = try JSONDecoder().decode(OperationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.kind, .livePhoto); XCTAssertEqual(decoded.pairedVideoPath, "/motion")
        XCTAssertFalse(try XCTUnwrap(decoded.photoSettings).convertLiveToStill)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoCompressor-image-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fixture(_ url: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<40 {
            context.setFillColor(CGColor(red: CGFloat(index % 7) / 7, green: 0.3, blue: CGFloat(index % 9) / 9, alpha: 1))
            context.fill(CGRect(x: index * width / 40, y: index * height / 40, width: width / 4, height: height / 4))
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:06:15 12:34:56"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.5, kCGImagePropertyGPSLatitudeRef: "N"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
