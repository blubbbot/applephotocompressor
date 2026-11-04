import Foundation

public enum Resolution: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original", uhd = "4K", fullHD = "1080p", hd = "720p"
    public var id: String { rawValue }
    public var longEdge: Int? {
        switch self { case .original: return nil; case .uhd: return 3840; case .fullHD: return 1920; case .hd: return 1280 }
    }
}

public enum FrameRate: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original", sixty = "60 fps", thirty = "30 fps", twentyFour = "24 fps"
    public var id: String { rawValue }
    public var limit: Double? {
        switch self { case .original: return nil; case .sixty: return 60; case .thirty: return 30; case .twentyFour: return 24 }
    }
}

public enum Quality: String, Codable, CaseIterable, Identifiable, Sendable {
    case smaller = "Smaller", balanced = "Balanced", higher = "Higher"
    public var id: String { rawValue }
    var bitsPerPixel: Double {
        switch self { case .smaller: return 0.045; case .balanced: return 0.075; case .higher: return 0.12 }
    }
}

public struct CompressionSettings: Codable, Equatable, Sendable {
    public var resolution: Resolution = .fullHD
    public var frameRate: FrameRate = .original
    public var quality: Quality = .balanced
    public var useCustomBitrate = false
    public var bitrateMbps: Double = 5
    public var minimumSavings: Double = 0.15
    public init() {}
}

public struct VideoFacts: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var duration: Double
    public var frameRate: Double
    public var bytes: Int64?
    public var isHDR: Bool
    public init(width: Int, height: Int, duration: Double, frameRate: Double = 30, bytes: Int64? = nil, isHDR: Bool = false) {
        self.width = width; self.height = height; self.duration = duration
        self.frameRate = frameRate; self.bytes = bytes; self.isHDR = isHDR
    }
}

public struct CompressionPlan: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let videoBitrate: Int
    public let estimatedBytes: Int64
    public let estimatedSavings: Int64?

    public init(facts: VideoFacts, settings: CompressionSettings, audioTracks: Int = 1, audioBitrate: Int? = nil) {
        let longest = max(2, facts.width, facts.height)
        let scale = min(1, Double(settings.resolution.longEdge ?? longest) / Double(longest))
        width = max(2, Int(Double(facts.width) * scale) / 2 * 2)
        height = max(2, Int(Double(facts.height) * scale) / 2 * 2)
        let sourceFPS = facts.frameRate.isFinite && facts.frameRate > 0 ? facts.frameRate : 30
        frameRate = min(sourceFPS, settings.frameRate.limit ?? sourceFPS)
        let automatic = Double(width * height) * frameRate * settings.quality.bitsPerPixel * (facts.isHDR ? 1.25 : 1)
        let requested = settings.useCustomBitrate ? max(0.25, min(100, settings.bitrateMbps)) * 1_000_000 : automatic
        videoBitrate = Int(max(250_000, min(100_000_000, requested)))
        let duration = facts.duration.isFinite ? max(0, facts.duration) : 0
        let estimated = Int64(duration * Double(videoBitrate + (audioBitrate ?? max(0, audioTracks) * 128_000)) / 8 * 1.02)
        estimatedBytes = estimated
        estimatedSavings = facts.bytes.map { max(0, $0 - estimated) }
    }

    public func meetsMinimumSavings(originalBytes: Int64, outputBytes: Int64, threshold: Double) -> Bool {
        originalBytes > 0 && outputBytes > 0 && Double(originalBytes - outputBytes) / Double(originalBytes) >= threshold
    }
}

public enum DisplayFormat {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
    public static func duration(_ value: Double) -> String {
        let seconds = Int(max(0, value.isFinite ? value : 0))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
