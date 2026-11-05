import XCTest
@testable import PhotoCompressor

final class LibrarySizeCacheTests: XCTestCase {
    actor Calls {
        var count = 0
        func next() -> Int { count += 1; return count }
    }
    func testConcurrentModesShareOneSizePassAndExplicitRefreshReadsAgain() async throws {
        let calls = Calls()
        let cache = LibrarySizeCache {
            let count = await calls.next()
            try await Task.sleep(nanoseconds: 20_000_000)
            return ["asset": Int64(count)]
        }
        async let videos = cache.sizes()
        async let photos = cache.sizes()
        let results = try await (videos, photos)
        XCTAssertEqual(results.0, ["asset": 1]); XCTAssertEqual(results.1, ["asset": 1])
        let reused = try await cache.sizes()
        XCTAssertEqual(reused, ["asset": 1])
        let refreshed = try await cache.sizes(refresh: true)
        XCTAssertEqual(refreshed, ["asset": 2])
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }
    func testFailedSizePassCanBeRetried() async throws {
        let calls = Calls()
        let cache = LibrarySizeCache {
            let count = await calls.next()
            if count == 1 { throw NSError(domain: "fixture", code: 1) }
            return ["asset": 123]
        }
        do { _ = try await cache.sizes(); XCTFail("Expected fixture error") } catch {}
        let result = try await cache.sizes()
        XCTAssertEqual(result, ["asset": 123])
    }
}
