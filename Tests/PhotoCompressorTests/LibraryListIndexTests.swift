import XCTest
import CompressionCore
@testable import PhotoCompressor

final class LibraryListIndexTests: XCTestCase {
    func testMeasurementsKeepNavigationOrderUntilCommitAndFilteringKeepsHiddenRanks() throws {
        var items = [item("a", bytes: 300, panorama: true), item("b", bytes: 200), item("c", bytes: 100, panorama: true)]
        let first = try LibraryListIndex.build(items, query: .init(), order: .init(), resort: true, applyImmediately: false)
        XCTAssertEqual(first.items.map(\.id), ["a", "b", "c"])
        items[0].facts.bytes = 50
        let measured = try LibraryListIndex.build(items, query: .init(), order: first.order, resort: true, applyImmediately: false)
        XCTAssertEqual(measured.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(measured.order.pending, ["b", "c", "a"])
        var query = LibraryListIndex.Query(); query.photoFilter = .panoramas
        let filtered = try LibraryListIndex.build(items, query: query, order: measured.order, resort: false, applyImmediately: false)
        XCTAssertEqual(filtered.items.map(\.id), ["a", "c"])
        var committed = filtered.order; committed.commit()
        let reordered = try LibraryListIndex.build(items, query: query, order: committed, resort: false, applyImmediately: false)
        XCTAssertEqual(reordered.items.map(\.id), ["c", "a"])
    }

    func testSharingAndSubtypeFiltersCombineAndStaleResultsBecomeUnknown() throws {
        let items = [item("live", bytes: 300, live: true), item("pano", bytes: 200, panorama: true), item("still", bytes: 100)]
        var query = LibraryListIndex.Query(); query.sharingEnabled = true
        query.sharing = ["live": .init(state: .shared, detail: "fixture"), "pano": .init(state: .shared, detail: "fixture"), "still": .init(state: .personal, detail: "fixture")]
        query.sharingFilter = .shared; query.photoFilter = .livePhotos
        XCTAssertEqual(try LibraryListIndex.build(items, query: query, order: .init(), resort: true, applyImmediately: true).items.map(\.id), ["live"])
        query.photoFilter = .panoramas
        XCTAssertEqual(try LibraryListIndex.build(items, query: query, order: .init(), resort: true, applyImmediately: true).items.map(\.id), ["pano"])
        query.now = Date().addingTimeInterval(121)
        XCTAssertTrue(try LibraryListIndex.build(items, query: query, order: .init(), resort: true, applyImmediately: true).items.isEmpty)
        query.sharingFilter = .unknown
        XCTAssertEqual(try LibraryListIndex.build(items, query: query, order: .init(), resort: true, applyImmediately: true).items.map(\.id), ["pano"])
    }

    @MainActor
    func testLargeCatalogBuildRunsOffMainActorAndCombinesProcessedAndSubtypeFilters() async throws {
        let items = (0..<30_000).map { item("item-\($0)", bytes: Int64($0 + 1), panorama: $0 % 7 == 0) }
        var query = LibraryListIndex.Query(); query.photoFilter = .panoramas
        query.processedIDs = Set(stride(from: 0, to: 30_000, by: 3).map { "item-\($0)" })
        query.outputIDs = Set(stride(from: 0, to: 30_000, by: 5).map { "item-\($0)" })
        let configuration = query
        let worker = Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return try LibraryListIndex.build(items, query: configuration, order: .init(), resort: true, applyImmediately: true)
        }
        // The UI actor can run other work while the whole-library job proceeds.
        await Task.yield()
        let result = try await worker.value
        let expected = (0..<30_000).filter { $0 % 7 == 0 && $0 % 3 != 0 && $0 % 5 != 0 }.reversed().map { "item-\($0)" }
        XCTAssertEqual(result.items.map(\.id), expected)
    }

    func testCancelledCatalogWorkDoesNotReturnAnObsoleteSnapshot() async {
        let worker = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try LibraryListIndex.build([], query: .init(), order: .init(), resort: true, applyImmediately: false)
        }
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Cancelled work must not publish a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func item(_ id: String, bytes: Int64, live: Bool = false, panorama: Bool = false) -> LibraryVideo {
        LibraryVideo(id: id, name: id + ".heic", asset: nil, fileURL: nil,
                     facts: VideoFacts(width: 4000, height: 3000, duration: 0, bytes: bytes), date: .distantPast,
                     unsupportedReason: nil, kind: live ? .livePhoto : .photo, isPanorama: panorama)
    }
}
