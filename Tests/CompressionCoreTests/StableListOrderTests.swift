import XCTest
@testable import CompressionCore

final class StableListOrderTests: XCTestCase {
    func testMeasurementUpdatesDoNotChangeKeyboardNeighborsUntilCommitted() {
        var order = StableListOrder<String>()
        order.propose(["a", "b", "c"])
        order.propose(["b", "c", "a"])
        XCTAssertEqual(order.ids, ["a", "b", "c"])
        XCTAssertEqual(order.pending, ["b", "c", "a"])
        order.propose(["c", "b", "a"])
        XCTAssertEqual(order.ids, ["a", "b", "c"])
        order.commit()
        XCTAssertEqual(order.ids, ["c", "b", "a"])
        XCTAssertNil(order.pending)
    }
    func testExplicitSortAndChangingDatasetApplyImmediately() {
        var order = StableListOrder<String>()
        order.propose(["a", "b"]); order.propose(["b", "a"])
        order.apply(["b", "a"])
        XCTAssertEqual(order.ids, ["b", "a"]); XCTAssertNil(order.pending)
        order.propose(["photo-1", "photo-2"])
        XCTAssertEqual(order.ids, ["photo-1", "photo-2"])
    }
    func testRemovedItemsDisappearAndNewItemsAppendWithoutMovingExistingRows() {
        var order = StableListOrder<String>()
        order.propose(["a", "b", "c"])
        order.propose(["new", "c", "a"])
        XCTAssertEqual(order.ids, ["a", "c", "new"])
        order.commit(); XCTAssertEqual(order.ids, ["new", "c", "a"])
    }
}
