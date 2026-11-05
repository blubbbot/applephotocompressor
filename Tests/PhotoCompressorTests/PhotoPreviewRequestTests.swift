import XCTest
@testable import PhotoCompressor

final class PhotoPreviewRequestTests: XCTestCase {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testFinalCallbackIsDeliveredOnceAndLateResultsAreIgnored() async throws {
        let request = PhotoPreviewRequest<Int>()
        let result: Int = try await withCheckedThrowingContinuation { continuation in
            XCTAssertTrue(request.attach(continuation))
            request.finish(.success(1)); request.finish(.success(2))
            request.cancel()
        }
        XCTAssertEqual(result, 1)
        let cancellations = Counter()
        request.setCancellation { cancellations.increment() }
        XCTAssertEqual(cancellations.value, 0, "Finishing before PhotoKit returns a request ID must not retain or cancel that completed request")
    }

    func testCancellationBeforeAttachAndBeforeRequestIDArrival() async {
        let request = PhotoPreviewRequest<Int>()
        request.cancel()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(request.attach(continuation))
            } as Int
            XCTFail("Cancelled request must not start")
        } catch { XCTAssertTrue(error is CancellationError) }
        let cancellations = Counter()
        request.setCancellation { cancellations.increment() }
        XCTAssertEqual(cancellations.value, 1)
        request.finish(.success(3))
    }

    func testCancellationStopsUnderlyingRequestWithoutWaitingForPhotoKitCallback() async {
        let request = PhotoPreviewRequest<Int>(), cancellations = Counter()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(request.attach(continuation))
                request.setCancellation { cancellations.increment() }
                request.cancel(); request.cancel()
                request.finish(.success(4))
            } as Int
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancellations.value, 1)
    }

    func testConcurrentCompletionAndCancellationResumeExactlyOnce() async {
        for _ in 0..<100 {
            let request = PhotoPreviewRequest<Int>()
            let group = DispatchGroup()
            do {
                let result: Int = try await withCheckedThrowingContinuation { continuation in
                    XCTAssertTrue(request.attach(continuation))
                    group.enter(); DispatchQueue.global().async { request.finish(.success(5)); group.leave() }
                    group.enter(); DispatchQueue.global().async { request.cancel(); group.leave() }
                }
                XCTAssertEqual(result, 5)
            } catch { XCTAssertTrue(error is CancellationError) }
            group.wait()
        }
    }
}
