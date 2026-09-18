import XCTest
@testable import CopyCore

final class PreviewLayoutTests: XCTestCase {
    func testImagesFitScreenAndKeepPortraitLandscapeAndPanoramaRatios() {
        let screen = CGSize(width: 1280, height: 800)
        for pixels in [CGSize(width: 900, height: 1800), CGSize(width: 3000, height: 1500), CGSize(width: 10000, height: 100), CGSize(width: 16, height: 16)] {
            let result = PreviewLayout.imageSize(pixels: pixels, screen: screen, scale: 2)
            XCTAssertLessThanOrEqual(result.width, ceil(screen.width * 0.78))
            XCTAssertLessThanOrEqual(result.height, ceil(screen.height * 0.72))
            // Rounding to whole points contributes at most one point on either axis.
            XCTAssertEqual(result.width - 24, (result.height - 24) * pixels.width / pixels.height, accuracy: 1 + pixels.width / pixels.height)
        }
    }
    func testShortTextIsCompactAndLongTextIsBounded() {
        let screen = CGSize(width: 1280, height: 800)
        XCTAssertEqual(PreviewLayout.textSize(text: "Hello", screen: screen), CGSize(width: 320, height: 120))
        let long = PreviewLayout.textSize(text: String(repeating: "hello world\n", count: 30000), screen: screen)
        XCTAssertLessThanOrEqual(long.width, 520)
        XCTAssertLessThanOrEqual(long.height, 496)
    }
    func testMissingDimensionsStayFinite() {
        let result = PreviewLayout.imageSize(pixels: .zero, screen: CGSize(width: 1280, height: 800), scale: 0)
        XCTAssertTrue(result.width.isFinite && result.height.isFinite)
        XCTAssertGreaterThan(result.width, 24)
    }
}
