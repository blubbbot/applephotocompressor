import XCTest
@testable import CompressionCore

final class SharedLibraryWorkflowTests: XCTestCase {
    func testSharedOriginalCanBeReplacedAndStaysFindableAfterDeletionAndAcceptance() throws {
        var record = sharedRecord()
        XCTAssertTrue(record.isDeletionCandidate, "Shared membership must not prevent a verified automatic replacement")
        record.stage = .originalDeleted
        let restored = try JSONDecoder().decode(OperationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertFalse(restored.isDeletionCandidate)
        XCTAssertTrue(restored.needsReview, "Automatic deletion must leave the compressed version in the Review queue")
        XCTAssertEqual(restored.reviewPhotosID, "replacement")
        XCTAssertTrue(ReviewSharingFilter.shared.includes(original: restored.sourceSharedLibrary!.state, replacement: .personal, hasPhotosTarget: true))
        XCTAssertTrue(ReviewSharingFilter.needsSharing.includes(original: restored.sourceSharedLibrary!.state, replacement: .personal, hasPhotosTarget: true))
        record.reviewDecision = .accepted
        XCTAssertFalse(record.needsReview)
        XCTAssertTrue(record.hasReviewableCopy)
        XCTAssertTrue(ReviewSharingFilter.needsSharing.includes(original: record.sourceSharedLibrary!.state, replacement: .unknown, hasPhotosTarget: record.reviewPhotosID != nil), "Accepting a copy must not certify that its sharing was restored")
    }

    func testSharingCheckQueueTracksCopyPlacementWithoutLosingSharedOriginalFilter() {
        let record = sharedRecord()
        for state in [SharedLibraryState.personal, .unknown] {
            XCTAssertTrue(ReviewSharingFilter.needsSharing.includes(original: .shared, replacement: state, hasPhotosTarget: record.reviewPhotosID != nil))
        }
        XCTAssertFalse(ReviewSharingFilter.needsSharing.includes(original: .shared, replacement: .shared, hasPhotosTarget: true))
        XCTAssertTrue(ReviewSharingFilter.shared.includes(original: .shared, replacement: .shared, hasPhotosTarget: true), "Re-sharing removes a copy from the action queue, while Shared originals still finds it")
        XCTAssertFalse(ReviewSharingFilter.needsSharing.includes(original: .personal, replacement: .personal, hasPhotosTarget: true))
        XCTAssertFalse(ReviewSharingFilter.needsSharing.includes(original: .unknown, replacement: .personal, hasPhotosTarget: true))
        XCTAssertFalse(ReviewSharingFilter.needsSharing.includes(original: .shared, replacement: .personal, hasPhotosTarget: false))
    }

    func testRevertRevealsRestoredOriginalAndLocalOperationsHaveNoPhotosTarget() {
        var record = sharedRecord()
        record.stage = .reverted
        XCTAssertEqual(record.reviewPhotosID, record.sourceID, "When the original was retained, reveal that item")
        record.restoredOriginalID = "restored-original"
        XCTAssertEqual(record.reviewPhotosID, "restored-original", "An archive-backed revert creates a new original that may need re-sharing")
        record.sourceID = "/Movies/local.mov"
        XCTAssertNil(record.reviewPhotosID)
    }

    func testLibraryFiltersKeepUnknownSeparateFromPersonal() {
        XCTAssertTrue(LibrarySharingFilter.all.includes(.unknown))
        XCTAssertFalse(LibrarySharingFilter.shared.includes(.unknown))
        XCTAssertFalse(LibrarySharingFilter.personal.includes(.unknown))
        XCTAssertTrue(LibrarySharingFilter.unknown.includes(.unknown))
        XCTAssertTrue(LibrarySharingFilter.shared.includes(.shared))
        XCTAssertFalse(LibrarySharingFilter.shared.includes(.personal))
        XCTAssertTrue(LibrarySharingFilter.personal.includes(.personal))
    }

    private func sharedRecord() -> OperationRecord {
        var record = OperationRecord(sourceID: "original", sourceName: "shared.mov", backupPath: "/archive/original.mov", outputPath: "/archive/copy.mov", settings: CompressionSettings())
        record.sourceSharedLibrary = SharedLibraryObservation(state: .shared, detail: "Observed at compression")
        record.originalBytes = 1_000; record.outputBytes = 500
        record.replacementID = "replacement"; record.metadataVerified = true; record.stage = .readyToDelete
        return record
    }
}
