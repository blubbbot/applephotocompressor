import Foundation

public enum OperationStage: String, Codable {
    case preparing, archived, encoded, imported, readyToDelete, originalDeleted, keptOriginal, failed, reverting, reverted
}

public enum ReviewDecision: String, Codable {
    case accepted, reverted
}

public struct LibraryTextMetadata: Codable, Equatable {
    public let title: String
    public let caption: String
    public let keywords: [String]

    public init(title: String, caption: String, keywords: [String]) {
        self.title = title; self.caption = caption; self.keywords = keywords
    }
}

public struct OperationRecord: Codable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var sourceID: String
    public var sourceName: String
    public var backupPath: String
    public var outputPath: String
    public var replacementID: String?
    public var originalBytes: Int64?
    public var outputBytes: Int64?
    public var stage: OperationStage
    public var error: String?
    public var metadataVerified: Bool
    public var sourceModifiedAt: Date?
    public var sourceFacts: VideoFacts?
    public var sourceTextMetadata: LibraryTextMetadata?
    public var replacementModifiedAt: Date?
    public var restoredOriginalID: String?
    public var restoredOriginalVerified: Bool?
    public var reviewDecision: ReviewDecision?
    public var settings: CompressionSettings

    public init(sourceID: String, sourceName: String, backupPath: String, outputPath: String, settings: CompressionSettings) {
        id = UUID(); startedAt = Date(); self.sourceID = sourceID; self.sourceName = sourceName
        self.backupPath = backupPath; self.outputPath = outputPath; self.settings = settings
        stage = .preparing; metadataVerified = false
    }

    public var isDeletionCandidate: Bool {
        stage == .readyToDelete && reviewDecision == nil && metadataVerified && replacementID?.isEmpty == false &&
        !(backupPath.isEmpty) && (originalBytes ?? 0) > 0 && (outputBytes ?? 0) > 0 &&
        (outputBytes ?? .max) < (originalBytes ?? 0)
    }

    public var isPhotosOperation: Bool { !sourceID.hasPrefix("/") }

    public var hasReviewableCopy: Bool {
        guard (outputBytes ?? 0) > 0, !outputPath.isEmpty else { return false }
        if replacementID != nil { return true }
        guard !isPhotosOperation, stage == .keptOriginal || stage == .reverted, let originalBytes, let outputBytes else { return false }
        return originalBytes > 0 && outputBytes < originalBytes && Double(originalBytes - outputBytes) / Double(originalBytes) >= settings.minimumSavings
    }

    public var needsReview: Bool { hasReviewableCopy && reviewDecision == nil && stage != .reverted }

    // A stable resource name lets an interrupted archive restoration be recovered
    // without importing another full original after a restart.
    public var restorationFilename: String {
        let url = URL(fileURLWithPath: sourceName)
        let stem = String(url.deletingPathExtension().lastPathComponent.prefix(40))
        let ext = URL(fileURLWithPath: backupPath).pathExtension
        return "\(stem) [restored \(id.uuidString)].\(ext.isEmpty ? "mov" : ext)"
    }
}

public actor OperationJournal {
    public let url: URL
    private var records: [OperationRecord]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            records = try JSONDecoder().decode([OperationRecord].self, from: Data(contentsOf: url))
        } else { records = [] }
    }

    public func all() -> [OperationRecord] { records.sorted { $0.startedAt > $1.startedAt } }

    public func save(_ record: OperationRecord) throws {
        var next = records
        if let index = next.firstIndex(where: { $0.id == record.id }) { next[index] = record }
        else { next.append(record) }
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        records = next
    }
}
