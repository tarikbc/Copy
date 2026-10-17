import XCTest
@testable import CopyCore

final class ShelfSelectionTests: XCTestCase {
    let order = ["a", "b", "c", "d", "e"]

    func testClickSelectsSingle() {
        var sel = ShelfSelection()
        sel.click("b")
        XCTAssertEqual(sel.selected, ["b"])
        XCTAssertEqual(sel.primary, "b")
        sel.click("d")
        XCTAssertEqual(sel.selected, ["d"])
    }

    func testCommandClickToggles() {
        var sel = ShelfSelection()
        sel.click("a")
        sel.commandClick("c", in: order)
        XCTAssertEqual(sel.selected, ["a", "c"])
        XCTAssertEqual(sel.primary, "c")
        sel.commandClick("c", in: order)
        XCTAssertEqual(sel.selected, ["a"])
        XCTAssertEqual(sel.primary, "a")
    }

    func testShiftClickSelectsRange() {
        var sel = ShelfSelection()
        sel.click("b")
        sel.shiftClick("d", in: order)
        XCTAssertEqual(sel.selected, ["b", "c", "d"])
        XCTAssertEqual(sel.primary, "b")
        sel.shiftClick("a", in: order)
        XCTAssertEqual(sel.selected, ["a", "b"])
    }

    func testSelectReplacesSelectionAndPrefersGivenPrimary() {
        var sel = ShelfSelection()
        sel.click("a")
        sel.select(["c", "d", "e"], preferredPrimary: "d", in: order)
        XCTAssertEqual(sel.selected, ["c", "d", "e"])
        XCTAssertEqual(sel.primary, "d")
    }

    func testSelectKeepsPrimaryWhenStillSelected() {
        var sel = ShelfSelection()
        sel.click("c")
        sel.select(["b", "c"], in: order)
        XCTAssertEqual(sel.selected, ["b", "c"])
        XCTAssertEqual(sel.primary, "c")
    }

    func testSelectFallsBackToFirstSelectedInOrder() {
        var sel = ShelfSelection()
        sel.click("a")
        sel.select(["e", "c"], preferredPrimary: "b", in: order)
        XCTAssertEqual(sel.selected, ["c", "e"])
        XCTAssertEqual(sel.primary, "c")
    }

    func testSelectEmptySetChangesNothing() {
        var sel = ShelfSelection()
        sel.click("b")
        sel.select([], in: order)
        XCTAssertEqual(sel.selected, ["b"])
        XCTAssertEqual(sel.primary, "b")
    }

    func testMoveCollapsesAndClamps() {
        var sel = ShelfSelection()
        sel.click("b")
        sel.commandClick("d", in: order)
        sel.move(1, in: order)
        XCTAssertEqual(sel.selected, ["e"])
        XCTAssertEqual(sel.primary, "e")
        sel.move(1, in: order)
        XCTAssertEqual(sel.primary, "e") // clamped at end
        sel.move(-10, in: order)
        XCTAssertEqual(sel.primary, "a")
    }

    func testMoveWithEmptySelectionPicksFirst() {
        var sel = ShelfSelection()
        sel.move(1, in: order)
        XCTAssertEqual(sel.primary, "a")
        XCTAssertEqual(sel.selected, ["a"])
    }

    func testOrderedSelection() {
        var sel = ShelfSelection()
        sel.click("d")
        sel.commandClick("a", in: order)
        sel.commandClick("c", in: order)
        XCTAssertEqual(sel.orderedSelection(in: order), ["a", "c", "d"])
    }

    func testPruneDropsVanishedAndReanchorsPrimary() {
        var sel = ShelfSelection()
        sel.click("b")
        sel.commandClick("c", in: order)
        sel.prune(existing: ["a", "c", "d", "e"], order: ["a", "c", "d", "e"])
        XCTAssertEqual(sel.selected, ["c"])
        XCTAssertEqual(sel.primary, "c")
        sel.prune(existing: [], order: [])
        XCTAssertNil(sel.primary)
        XCTAssertTrue(sel.selected.isEmpty)
    }

    func testCommandClickDeterminismWithMultipleDeselections() {
        let order = ["a", "b", "c"]
        var sel = ShelfSelection()
        sel.click("b")
        sel.commandClick("c", in: order)
        XCTAssertEqual(sel.selected, ["b", "c"])
        XCTAssertEqual(sel.primary, "c")
        sel.commandClick("a", in: order)
        XCTAssertEqual(sel.selected, ["a", "b", "c"])
        XCTAssertEqual(sel.primary, "a")
        sel.commandClick("a", in: order)
        XCTAssertEqual(sel.selected, ["b", "c"])
        XCTAssertEqual(sel.primary, "b")
    }
}
