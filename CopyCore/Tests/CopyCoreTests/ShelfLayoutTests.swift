import XCTest
@testable import CopyCore

final class ShelfLayoutTests: XCTestCase {
    func testAttachedGeometryStaysUnchanged() {
        let screen = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        for height: CGFloat in [244, 352] {
            XCTAssertEqual(ShelfLayout.frame(visibleFrame: screen, height: height, floating: false),
                           CGRect(x: -1920, y: 900, width: 1920, height: height))
        }
    }
    func testFloatingFrameKeepsItsGapsOnOffsetDisplays() {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 900, width: 1920, height: 1080)] {
            let frame = ShelfLayout.frame(visibleFrame: screen, height: 352, floating: true)
            XCTAssertEqual(frame.minX - screen.minX, 12)
            XCTAssertEqual(screen.maxX - frame.maxX, 12)
            XCTAssertEqual(frame.minY - screen.minY, 12)
            XCTAssertTrue(screen.contains(frame))
        }
    }
}
