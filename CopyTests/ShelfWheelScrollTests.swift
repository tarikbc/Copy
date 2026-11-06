import AppKit
import XCTest

final class ShelfWheelScrollTests: XCTestCase {
    func testDownwardWheelMovementBecomesRightwardShelfMovement() {
        XCTAssertEqual(ShelfWheelScroll.horizontalOffset(horizontal: 0, vertical: -3), 3)
    }

    func testUpwardWheelMovementBecomesLeftwardShelfMovement() {
        XCTAssertEqual(ShelfWheelScroll.horizontalOffset(horizontal: 0, vertical: 3), -3)
    }

    func testHorizontalTrackpadMovementStaysWithAppKit() {
        XCTAssertNil(ShelfWheelScroll.horizontalOffset(horizontal: 2, vertical: 0))
    }

    func testCombinedAxisTrackpadMovementStaysWithAppKit() {
        XCTAssertNil(ShelfWheelScroll.horizontalOffset(horizontal: 2, vertical: -3))
    }
}
