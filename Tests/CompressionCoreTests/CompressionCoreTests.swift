import XCTest
@testable import CompressionCore

final class CompressionCoreTests: XCTestCase {
    func testPortraitVideoIsDownscaledWithoutChangingAspectOrExceedingFrameRate() {
        let facts = VideoFacts(width: 2160, height: 3840, duration: 60, frameRate: 24, bytes: 1_000_000_000)
        let plan = CompressionPlan(facts: facts, settings: CompressionSettings())
        XCTAssertEqual(plan.width, 1080); XCTAssertEqual(plan.height, 1920)
        XCTAssertEqual(plan.frameRate, 24)
        XCTAssertGreaterThan(plan.estimatedSavings ?? 0, 0)
    }

    func testSmallVideoIsNeverUpscaled() {
        let facts = VideoFacts(width: 640, height: 360, duration: 10, frameRate: 15)
        let plan = CompressionPlan(facts: facts, settings: CompressionSettings())
        XCTAssertEqual(plan.width, 640); XCTAssertEqual(plan.height, 360); XCTAssertEqual(plan.frameRate, 15)
        XCTAssertNil(plan.estimatedSavings)
    }

    func testEstimatesUseCustomBitrateAndDoNotInventNegativeSavings() {
        var settings = CompressionSettings(); settings.useCustomBitrate = true; settings.bitrateMbps = 8
        let plan = CompressionPlan(facts: VideoFacts(width: 1920, height: 1080, duration: 100, bytes: 1_000_000), settings: settings, audioTracks: 0)
        XCTAssertEqual(plan.estimatedBytes, 102_000_000)
        XCTAssertEqual(plan.estimatedSavings, 0)
        XCTAssertFalse(plan.meetsMinimumSavings(originalBytes: 100, outputBytes: 95, threshold: 0.15))
        XCTAssertTrue(plan.meetsMinimumSavings(originalBytes: 100, outputBytes: 75, threshold: 0.15))
        XCTAssertFalse(plan.meetsMinimumSavings(originalBytes: 0, outputBytes: 0, threshold: 0))
    }

    func testDeletionIsIneligibleUntilEveryRequiredStageIsRecorded() {
        var record = OperationRecord(sourceID: "original", sourceName: "video.mov", backupPath: "/archive/video.mov", outputPath: "/archive/small.mov", settings: CompressionSettings())
        record.originalBytes = 1000; record.outputBytes = 500
        record.replacementID = "replacement"; record.metadataVerified = true
        XCTAssertFalse(record.isDeletionCandidate)
        record.stage = .readyToDelete; XCTAssertTrue(record.isDeletionCandidate)
        record.metadataVerified = false; XCTAssertFalse(record.isDeletionCandidate)
        record.metadataVerified = true; record.replacementID = nil; XCTAssertFalse(record.isDeletionCandidate)
        record.replacementID = "replacement"; record.outputBytes = 1100; XCTAssertFalse(record.isDeletionCandidate)
    }

    func testJournalSurvivesRestartAndCorruptionFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.json")
        let journal = try OperationJournal(url: url)
        var record = OperationRecord(sourceID: "asset", sourceName: "example.mov", backupPath: "/archive/original", outputPath: "/archive/output", settings: CompressionSettings())
        try await journal.save(record)
        record.replacementID = "copy"; record.stage = .imported
        try await journal.save(record)
        let reopened = try OperationJournal(url: url)
        let records = await reopened.all()
        XCTAssertEqual(records.count, 1); XCTAssertEqual(records.first?.replacementID, "copy")
        XCTAssertFalse(records.first!.isDeletionCandidate)
        try Data("broken history".utf8).write(to: url)
        XCTAssertThrowsError(try OperationJournal(url: url))
    }
}
