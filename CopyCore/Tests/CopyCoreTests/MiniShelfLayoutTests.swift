import XCTest
@testable import CopyCore

final class MiniShelfLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 340, height: 400)

    func testOpensJustAboveTheCaret() {
        let caret = CGRect(x: 600, y: 200, width: 2, height: 18)
        let placement = MiniShelfLayout.placement(size: size, anchor: caret, visibleFrame: screen)
        XCTAssertFalse(placement.opensBelow)
        XCTAssertEqual(placement.frame.minY, caret.maxY + MiniShelfLayout.gap)
        XCTAssertEqual(placement.frame.minX, caret.minX - MiniShelfLayout.leadingOffset)
        XCTAssertEqual(placement.frame.size, size)
    }

    func testOpensBelowWhenThereIsNoRoomAbove() {
        let caret = CGRect(x: 600, y: 780, width: 2, height: 18)
        let placement = MiniShelfLayout.placement(size: size, anchor: caret, visibleFrame: screen)
        XCTAssertTrue(placement.opensBelow)
        XCTAssertEqual(placement.frame.maxY, caret.minY - MiniShelfLayout.gap)
    }

    func testStaysOnScreenNearTheEdges() {
        for caret in [CGRect(x: 1430, y: 100, width: 2, height: 18), CGRect(x: 2, y: 100, width: 2, height: 18)] {
            let frame = MiniShelfLayout.placement(size: size, anchor: caret, visibleFrame: screen).frame
            XCTAssertTrue(screen.insetBy(dx: MiniShelfLayout.edgeInset, dy: MiniShelfLayout.edgeInset).contains(frame))
        }
    }

    func testUsesTheSideWithMoreRoomWhenNeitherFits() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let caret = CGRect(x: 600, y: 300, width: 2, height: 18)
        let placement = MiniShelfLayout.placement(size: size, anchor: caret, visibleFrame: short)
        XCTAssertTrue(placement.opensBelow)
        XCTAssertTrue(short.contains(placement.frame))
    }

    func testPointerAnchorOnAnOffsetDisplay() {
        let display = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        let pointer = CGRect(x: -1000, y: 1200, width: 0, height: 0)
        let placement = MiniShelfLayout.placement(size: size, anchor: pointer, visibleFrame: display)
        XCTAssertFalse(placement.opensBelow)
        XCTAssertEqual(placement.frame.minY, 1200 + MiniShelfLayout.gap)
        XCTAssertTrue(display.contains(placement.frame))
    }

    func testShrinksToFitATinyScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 300)
        let frame = MiniShelfLayout.placement(size: size, anchor: CGRect(x: 150, y: 150, width: 0, height: 0),
                                              visibleFrame: tiny).frame
        XCTAssertTrue(tiny.contains(frame))
    }
}
