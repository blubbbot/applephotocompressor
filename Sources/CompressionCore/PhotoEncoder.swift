import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaKind: String, Codable, Sendable { case video, photo, livePhoto
    public var isPhoto: Bool { self != .video }
}

public enum PhotoResolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original", large = "4096 px", medium = "2560 px", small = "1920 px"
    public var id: Self { self }
    public var longEdge: Int? { switch self { case .original: return nil; case .large: return 4096; case .medium: return 2560; case .small: return 1920 } }
}

public struct PhotoCompressionSettings: Codable, Equatable, Sendable {
    public var quality = 0.8
    public var resolution: PhotoResolution = .original
    public var minimumSavings = 0.15
    public var convertLiveToStill = false
    public init() {}
}

public struct PhotoFacts: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var bytes: Int64
    public var format: String
    public init(width: Int, height: Int, bytes: Int64, format: String) {
        self.width = width; self.height = height; self.bytes = bytes; self.format = format
    }
}

public enum PhotoEncoder {
    public static func dimensions(width: Int, height: Int, resolution: PhotoResolution) -> (Int, Int) {
        let scale = min(1, Double(resolution.longEdge ?? max(width, height)) / Double(max(1, width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    public static func inspect(_ url: URL) throws -> PhotoFacts {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, [UTType.jpeg.identifier, UTType.heic.identifier].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw MediaError.invalid("Only ordinary, single-image JPEG and HEIC photos are supported. RAW, animated, spatial, and other formats are retained.")
        }
        guard (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8,
              (properties[kCGImagePropertyHasAlpha] as? Bool) != true else {
            throw MediaError.invalid("High-bit-depth or transparent photos need a dedicated encoder. The original is retained.")
        }
        let auxiliaryTypes = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                              kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
                              kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
                              kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte]
        guard !auxiliaryTypes.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }) else {
            throw MediaError.invalid("This photo contains HDR, depth, or portrait auxiliary data. It is protected rather than dropping those resources.")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let bytes = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        return PhotoFacts(width: rotated ? height : width, height: rotated ? width : height, bytes: bytes, format: type)
    }

    public static func encode(source url: URL, destination: URL, settings: PhotoCompressionSettings, cancellation: CancellationFlag) throws -> PhotoFacts {
        try cancellation.check()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MediaError.invalid("A photo output already exists. It was not overwritten.") }
        let facts = try inspect(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw MediaError.invalid("The native HEIC photo encoder is unavailable.")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = max(0.4, min(1, settings.quality))
        let (width, height) = dimensions(width: facts.width, height: facts.height, resolution: settings.resolution)
        if width == facts.width && height == facts.height {
            CGImageDestinationAddImageFromSource(output, source, 0, properties as CFDictionary)
        } else {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw MediaError.invalid("The photo could not be resized.") }
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = image.width; properties[kCGImagePropertyPixelHeight] = image.height
            var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifPixelXDimension] = image.width; exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
            CGImageDestinationAddImage(output, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(output) else { throw MediaError.invalid("HEIC photo encoding failed. The original is retained.") }
        try cancellation.check()
        let result = try inspect(destination)
        guard abs(result.width - width) <= 1, abs(result.height - height) <= 1,
              let decoded = CGImageSourceCreateWithURL(destination as CFURL, nil),
              CGImageSourceCreateImageAtIndex(decoded, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw MediaError.invalid("The encoded photo could not be decoded or its dimensions changed unexpectedly.")
        }
        completed = true
        return result
    }
}
