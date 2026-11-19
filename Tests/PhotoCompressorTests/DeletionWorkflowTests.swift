import XCTest
import CompressionCore
@testable import PhotoCompressor

@MainActor
final class DeletionWorkflowTests: XCTestCase {
    func testVerificationFailureKeepsRefreshedSharingAndReplacementCheckpointOnBothPaths() async throws {
        for reviewed in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let model = fixture.model(); await model.reloadHistory()
            var services = fixture.services()
            var refreshed = false, deleted = false
            services.refreshSharing = { _ in refreshed = true; return .init(state: .shared, detail: "Moved after compression") }
            services.verifyArchives = { record, _ in
                XCTAssertTrue(record.sourceWasShared)
                XCTAssertEqual(record.replacementModifiedAt, fixture.changed)
                throw MediaError.invalid("Archive verification failed")
            }
            services.delete = { _ in deleted = true }
            await model.deleteReady([fixture.record], markReviewed: reviewed, services: services)
            let result = try await fixture.saved(model)
            XCTAssertTrue(refreshed); XCTAssertFalse(deleted)
            XCTAssertTrue(result.sourceWasShared)
            XCTAssertEqual(result.replacementModifiedAt, fixture.changed)
            XCTAssertEqual(result.error, "Archive verification failed")
            XCTAssertEqual(result.stage, .readyToDelete); XCTAssertNil(result.reviewDecision)
        }
    }

    func testReviewAcceptanceRefreshesSharingAndLeavesReminder() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model(); await model.reloadHistory()
        model.cancellation.cancel() // An earlier stopped batch must not block explicit Review.
        var services = fixture.services()
        var deleted: [String] = []
        services.refreshSharing = { _ in .init(state: .shared, detail: "Moved after compression") }
        services.verifyArchives = { record, flag in
            XCTAssertFalse(flag.isCancelled)
            try ArchiveIntegrity.verify(record, cancellation: flag)
        }
        services.delete = { deleted = $0.map(\.id) }
        await model.deleteReady([fixture.record], markReviewed: true, services: services)
        let result = try await fixture.saved(model)
        XCTAssertEqual(deleted, [fixture.record.sourceID])
        XCTAssertEqual(result.stage, .originalDeleted); XCTAssertEqual(result.reviewDecision, .accepted)
        XCTAssertTrue(result.sourceWasShared); XCTAssertTrue(model.needsSharing(result))
    }

    func testFreshNonsharedObservationNeverDowngradesSavedSharedEvidence() async throws {
        for state in [SharedLibraryState.personal, .unknown] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let model = fixture.model(); await model.reloadHistory()
            var record = fixture.record
            record.sourceSharedLibrary = .init(state: .shared, detail: "Saved shared evidence")
            var services = fixture.services()
            services.refreshSharing = { _ in .init(state: state, detail: "Fresh observation") }
            await model.deleteReady([record], services: services)
            let result = try await fixture.saved(model)
            XCTAssertEqual(result.stage, .originalDeleted); XCTAssertNil(result.reviewDecision)
            XCTAssertEqual(result.sourceSharedLibrary, record.sourceSharedLibrary)
        }
    }

    func testCorruptArchivePreventsDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model(); await model.reloadHistory()
        try Data(repeating: 1, count: 10).write(to: URL(fileURLWithPath: fixture.record.backupPath))
        var services = fixture.services()
        var verificationFailed = false, deleted = false
        services.verifyArchives = { record, flag in
            do { try ArchiveIntegrity.verify(record, cancellation: flag) } catch { verificationFailed = true; throw error }
        }
        services.delete = { _ in deleted = true }
        await model.deleteReady([fixture.record], services: services)
        let result = try await fixture.saved(model)
        XCTAssertTrue(verificationFailed); XCTAssertFalse(deleted)
        XCTAssertEqual(result.stage, .readyToDelete); XCTAssertNotNil(result.error)
    }

    func testChangesDuringArchiveVerificationPreventDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model(); await model.reloadHistory()
        var services = fixture.services()
        let fetch = services.fetch
        var changed = false, deleted = false
        services.fetch = { id in
            if changed && id == fixture.record.replacementID {
                return .init(id: id, modifiedAt: fixture.changed.addingTimeInterval(1), duration: 1)
            }
            return fetch(id)
        }
        services.verifyArchives = { _, _ in changed = true }
        services.delete = { _ in deleted = true }
        await model.deleteReady([fixture.record], services: services)
        let result = try await fixture.saved(model)
        // Verification passed, so only the final snapshot check can have dropped it.
        XCTAssertTrue(changed); XCTAssertFalse(deleted)
        XCTAssertEqual(result.stage, .readyToDelete); XCTAssertNil(result.error)
        XCTAssertNotNil(model.notice)
    }

    func testStopDuringRevalidationPreventsAutomaticDeletion() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model(); await model.reloadHistory()
        var services = fixture.services()
        var deleted = false
        services.revalidateReplacement = { _ in model.cancellation.cancel(); return fixture.changed }
        services.verifyArchives = { _, _ in } // Even if hashing finishes before noticing Stop.
        services.delete = { _ in deleted = true }
        await model.deleteReady([fixture.record], services: services)
        XCTAssertFalse(deleted)
        let result = try await fixture.saved(model)
        XCTAssertEqual(result.stage, .readyToDelete); XCTAssertEqual(result.replacementModifiedAt, fixture.changed)
    }

    func testDeclinedDeletionRetainsCheckpointsWithoutAcceptingReview() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let model = fixture.model(); await model.reloadHistory()
        var services = fixture.services()
        services.refreshSharing = { _ in .init(state: .shared, detail: "Fresh shared observation") }
        services.delete = { _ in throw MediaError.invalid("Declined") }
        await model.deleteReady([fixture.record], markReviewed: true, services: services)
        let result = try await fixture.saved(model)
        XCTAssertTrue(result.sourceWasShared); XCTAssertEqual(result.replacementModifiedAt, fixture.changed)
        XCTAssertEqual(result.stage, .readyToDelete); XCTAssertNil(result.reviewDecision)
        XCTAssertTrue(result.error?.contains("Declined") == true)
    }

    func testMissingOrChangedAssetsAndIncompleteManifestPreventDeletion() async throws {
        enum Blocker: CaseIterable { case missingOriginal, missingReplacement, changedOriginal, incompleteManifest }
        for blocker in Blocker.allCases {
            let fixture = try Fixture(); defer { fixture.remove() }
            let model = fixture.model(); await model.reloadHistory()
            var record = fixture.record, services = fixture.services()
            let fetch = services.fetch
            var deleted = false
            services.fetch = { id in
                switch blocker {
                case .missingOriginal where id == record.sourceID: return nil
                case .missingReplacement where id == record.replacementID: return nil
                case .changedOriginal where id == record.sourceID: return .init(id: id, modifiedAt: fixture.changed, duration: 1)
                default: return fetch(id)
                }
            }
            if blocker == .incompleteManifest { record.originalFingerprint = nil }
            services.delete = { _ in deleted = true }
            await model.deleteReady([record], services: services)
            XCTAssertFalse(deleted, "\(blocker)")
            let result = try await fixture.saved(model)
            XCTAssertEqual(result.stage, .readyToDelete, "\(blocker)")
        }
    }

    @MainActor
    private struct Fixture {
        let environment: TestModelEnvironment
        let record: OperationRecord
        let changed = Date(timeIntervalSince1970: 200)

        init() throws {
            environment = try TestModelEnvironment("delete")
            let original = environment.directory.appendingPathComponent("original.mov"), output = environment.directory.appendingPathComponent("copy.mov")
            try Data(repeating: 0, count: 10).write(to: original)
            try Data(repeating: 0, count: 5).write(to: output)
            var record = OperationRecord(sourceID: "original", sourceName: "original.mov", backupPath: original.path, outputPath: output.path, settings: .init())
            record.originalBytes = 10; record.outputBytes = 5
            record.originalFingerprint = try ArchiveIntegrity.fingerprint(original)
            record.outputFingerprint = try ArchiveIntegrity.fingerprint(output)
            record.replacementID = "copy"; record.sourceModifiedAt = Date(timeIntervalSince1970: 100)
            record.replacementModifiedAt = record.sourceModifiedAt
            record.sourceSharedLibrary = .init(state: .personal, detail: "At compression")
            record.metadataVerified = true; record.stage = .readyToDelete
            self.record = record
        }

        func model() -> AppModel { environment.model() }
        func services() -> DeletionServices {
            DeletionServices(fetch: { id in
                guard id == record.sourceID || id == record.replacementID else { return nil }
                return .init(id: id, modifiedAt: id == record.sourceID ? record.sourceModifiedAt : changed, duration: 1)
            }, refreshSharing: { _ in nil }, revalidateReplacement: { _ in changed },
            verifyArchives: { record, flag in try ArchiveIntegrity.verify(record, cancellation: flag) }, delete: { _ in })
        }
        func saved(_ model: AppModel) async throws -> OperationRecord {
            await model.reloadHistory()
            return try XCTUnwrap(model.history.first)
        }
        func remove() { environment.remove() }
    }
}
