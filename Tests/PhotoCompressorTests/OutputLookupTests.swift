import XCTest
import CompressionCore
@testable import PhotoCompressor

@MainActor
final class OutputLookupTests: XCTestCase {
    func testLookupPreservesHistoryOrderAndTracksFileRemovalAndHistoryChanges() async throws {
        let environment = try TestModelEnvironment("lookup"); defer { environment.remove() }
        let directory = environment.directory, model = environment.model()
        await model.reloadHistory()
        let first = directory.appendingPathComponent("first.mov"), second = directory.appendingPathComponent("second.mov")
        try Data([1]).write(to: first); try Data([2]).write(to: second)
        var record = OperationRecord(sourceID: "original", sourceName: "original.mov", backupPath: "", outputPath: first.path, settings: .init())
        record.outputBytes = 1; record.stage = .keptOriginal
        var next = record; next.id = UUID(); next.outputPath = second.path
        var missing = record; missing.id = UUID(); missing.outputPath = directory.appendingPathComponent("missing.mov").path
        var failed = record; failed.id = UUID(); failed.stage = .failed
        var reverted = record; reverted.id = UUID(); reverted.stage = .reverted
        model.history = [missing, failed, reverted, record, next]
        XCTAssertEqual(model.outputRecord(for: "original")?.id, record.id)
        XCTAssertNil(model.outputRecord(for: "unrelated"))
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(model.outputRecord(for: "original")?.id, next.id)
        next.stage = .reverted; model.history = [next]
        XCTAssertNil(model.outputRecord(for: "original"))
    }

    func testAlreadyCancelledRecoveryLookupDoesNotEnumeratePhotos() async {
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhotosService.asset(named: "cancelled.mov")
        }
        do { _ = try await worker.value; XCTFail("Cancelled recovery must not return a match") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
