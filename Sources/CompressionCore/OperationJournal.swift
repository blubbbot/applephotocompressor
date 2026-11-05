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
    public var mediaKind: MediaKind?
    public var photoSettings: PhotoCompressionSettings?
    public var photoFacts: PhotoFacts?
    public var outputPhotoFacts: PhotoFacts?
    public var pairedVideoPath: String?
    public var pairedVideoBytes: Int64?
    public var sourceSharedLibrary: SharedLibraryObservation?
    public var settings: CompressionSettings

    public init(sourceID: String, sourceName: String, backupPath: String, outputPath: String, settings: CompressionSettings) {
        id = UUID(); startedAt = Date(); self.sourceID = sourceID; self.sourceName = sourceName
        self.backupPath = backupPath; self.outputPath = outputPath; self.settings = settings
        stage = .preparing; metadataVerified = false
    }

    public var isDeletionCandidate: Bool {
        stage == .readyToDelete && reviewDecision == nil && completePhotoResources && metadataVerified && replacementID?.isEmpty == false && replacementID != sourceID &&
        !(backupPath.isEmpty) && (originalBytes ?? 0) > 0 && (outputBytes ?? 0) > 0 &&
        (outputBytes ?? .max) < (originalBytes ?? 0)
    }

    public var isPhotosOperation: Bool { !sourceID.hasPrefix("/") }
    public var sourceWasShared: Bool { sourceSharedLibrary?.state == .shared }
    public var reviewPhotosID: String? {
        guard isPhotosOperation else { return nil }
        return stage == .reverted ? (restoredOriginalID ?? sourceID) : replacementID
    }
    public var kind: MediaKind { mediaKind ?? .video }
    public var outputIsLivePhoto: Bool { kind == .livePhoto && photoSettings?.convertLiveToStill != true }
    public var originalFileBytes: Int64? { originalBytes.map { $0 - (pairedVideoBytes ?? 0) } }
    public var outputFileBytes: Int64? { outputBytes.map { $0 - (outputIsLivePhoto ? (pairedVideoBytes ?? 0) : 0) } }
    public var completePhotoResources: Bool {
        guard kind.isPhoto else { return true }
        guard photoSettings != nil, let photoFacts, let outputPhotoFacts,
              photoFacts.bytes > 0, outputPhotoFacts.bytes > 0, photoFacts.width > 0, photoFacts.height > 0,
              outputPhotoFacts.width > 0, outputPhotoFacts.height > 0,
              originalFileBytes == photoFacts.bytes, outputFileBytes == outputPhotoFacts.bytes else { return false }
        return kind != .livePhoto || (pairedVideoPath?.isEmpty == false && (pairedVideoBytes ?? 0) > 0)
    }
    public var archiveFiles: [(String, Int64?)] {
        var files = [(backupPath, originalFileBytes), (outputPath, outputFileBytes)]
        if let pairedVideoPath { files.append((pairedVideoPath, pairedVideoBytes)) }
        return files
    }

    public var hasReviewableCopy: Bool {
        guard (outputBytes ?? 0) > 0, !outputPath.isEmpty else { return false }
        if replacementID != nil { return true }
        guard !isPhotosOperation, stage == .keptOriginal || stage == .reverted, let originalBytes, let outputBytes else { return false }
        return originalBytes > 0 && outputBytes < originalBytes && Double(originalBytes - outputBytes) / Double(originalBytes) >= (photoSettings?.minimumSavings ?? settings.minimumSavings)
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
