import XCTest
@testable import CompressionCore

final class ReviewJournalTests: XCTestCase {
    private func readyRecord() -> OperationRecord {
        var record = OperationRecord(sourceID: "original", sourceName: "portrait.mov", backupPath: "/archive/original.mov", outputPath: "/archive/copy.mov", settings: CompressionSettings())
        record.originalBytes = 1_000; record.outputBytes = 500
        record.replacementID = "replacement"; record.metadataVerified = true; record.stage = .readyToDelete
        return record
    }

    func testAutomaticReplacementStillNeedsReviewButCannotDeleteOriginalAgain() {
        var record = readyRecord()
        XCTAssertTrue(record.needsReview)
        XCTAssertTrue(record.isDeletionCandidate)
        record.stage = .originalDeleted
        XCTAssertTrue(record.needsReview)
        XCTAssertFalse(record.isDeletionCandidate)
        record.reviewDecision = .accepted
        XCTAssertFalse(record.needsReview)
        XCTAssertTrue(record.hasReviewableCopy)
    }

    func testRevertAndUnverifiedImportNeverGrantOriginalDeletion() {
        var record = readyRecord()
        record.stage = .imported; record.metadataVerified = false
        XCTAssertTrue(record.needsReview)
        XCTAssertFalse(record.isDeletionCandidate)
        record.stage = .reverting; record.metadataVerified = true
        XCTAssertTrue(record.needsReview)
        XCTAssertFalse(record.isDeletionCandidate)
        record.stage = .reverted; record.reviewDecision = .reverted
        XCTAssertFalse(record.needsReview)
        XCTAssertFalse(record.isDeletionCandidate)
        XCTAssertTrue(record.hasReviewableCopy)
    }

    func testLocalCopiesSkippedForSavingsAreNotQueuedAndReviewedCopiesRemainVisible() {
        var record = readyRecord()
        record.sourceID = "/Movies/example.mov"; record.replacementID = nil; record.stage = .keptOriginal
        XCTAssertTrue(record.needsReview)
        XCTAssertFalse(record.isDeletionCandidate)
        record.outputBytes = 999
        XCTAssertFalse(record.hasReviewableCopy)
        record.outputBytes = 500; record.stage = .reverted; record.reviewDecision = .reverted
        XCTAssertTrue(record.hasReviewableCopy)
        XCTAssertFalse(record.needsReview)
    }

    func testPreReviewJournalMigratesWithoutLosingDeletionSafeguards() throws {
        let data = try JSONEncoder().encode(readyRecord())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["reviewDecision", "sourceTextMetadata", "replacementModifiedAt", "restoredOriginalID", "restoredOriginalVerified"] { object.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(OperationRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.needsReview)
        XCTAssertTrue(legacy.isDeletionCandidate)
        XCTAssertNil(legacy.restoredOriginalID)
        XCTAssertNil(legacy.sourceTextMetadata)
    }

    func testRestorationCheckpointAndDecisionSurviveRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        var record = readyRecord()
        record.stage = .reverting; record.restoredOriginalID = "restored-original"; record.restoredOriginalVerified = true
        record.sourceTextMetadata = LibraryTextMetadata(title: "Trip", caption: "Original caption", keywords: ["Family"])
        record.replacementModifiedAt = Date(timeIntervalSinceReferenceDate: 123456)
        let filename = record.restorationFilename
        let journal = try OperationJournal(url: url)
        try await journal.save(record)
        let reopened = try OperationJournal(url: url)
        let checkpoints = await reopened.all()
        var checkpoint = try XCTUnwrap(checkpoints.first)
        XCTAssertEqual(checkpoint.restoredOriginalID, "restored-original")
        XCTAssertEqual(checkpoint.restoredOriginalVerified, true)
        XCTAssertEqual(checkpoint.restorationFilename, filename)
        XCTAssertTrue(filename.contains(record.id.uuidString))
        XCTAssertEqual(checkpoint.sourceTextMetadata, record.sourceTextMetadata)
        XCTAssertEqual(checkpoint.replacementModifiedAt, record.replacementModifiedAt)
        XCTAssertFalse(checkpoint.isDeletionCandidate)
        checkpoint.stage = .reverted; checkpoint.reviewDecision = .reverted
        try await reopened.save(checkpoint)
        let finalJournal = try OperationJournal(url: url)
        let completed = await finalJournal.all()
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.reviewDecision, .reverted)
        XCTAssertFalse(try XCTUnwrap(completed.first).needsReview)
    }
}
