import XCTest
@testable import CopyCore

final class PasteStackBatchRequestTests: XCTestCase {
    func testValidRequestPreservesDuplicateEntriesAndWhitespace() throws {
        let data = Data(#"{"version":1,"items":[" one ","same","same"],"expiresAt":1240}"#.utf8)
        let request = try XCTUnwrap(PasteStackBatchRequest.decode(data, now: 1000))
        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(request.items, [" one ", "same", "same"])
        XCTAssertFalse(request.isExpired(at: 1239))
        XCTAssertTrue(request.isExpired(at: 1240))
        XCTAssertTrue(request.isExpired(at: 1241))
    }

    func testDeadlineUsesMonotonicTimeAfterReceipt() throws {
        let data = Data(#"{"version":1,"items":["a"],"expiresAt":1240}"#.utf8)
        let request = try XCTUnwrap(PasteStackBatchRequest.decode(data, now: 1000))
        let deadline = request.monotonicDeadline(wallTime: 1000, uptime: 500)
        XCTAssertEqual(deadline, 740)
        XCTAssertLessThan(739, deadline)
        XCTAssertGreaterThanOrEqual(740, deadline)
    }

    func testMissingOrDistantExpiryIsRejected() throws {
        let missing = Data(#"{"version":1,"items":["a"]}"#.utf8)
        XCTAssertNil(PasteStackBatchRequest.decode(missing, now: 1000))
        let tooFar = Data(#"{"version":1,"items":["a"],"expiresAt":1301}"#.utf8)
        XCTAssertNil(PasteStackBatchRequest.decode(tooFar, now: 1000))
        let boundary = Data(#"{"version":1,"items":["a"],"expiresAt":1300}"#.utf8)
        XCTAssertNotNil(PasteStackBatchRequest.decode(boundary, now: 1000))
        let nonfinite = Data(#"{"version":1,"items":["a"],"expiresAt":1e999}"#.utf8)
        XCTAssertNil(PasteStackBatchRequest.decode(nonfinite, now: 1000))
        let expired = Data(#"{"version":1,"items":["a"],"expiresAt":999}"#.utf8)
        XCTAssertTrue(try XCTUnwrap(PasteStackBatchRequest.decode(expired, now: 1000)).isExpired(at: 1000))
    }

    func testInvalidVersionShapeAndSizeAreRejected() throws {
        for text in [#"{"version":2,"items":["a"],"expiresAt":1240}"#,
                     #"{"version":1,"items":[],"expiresAt":1240}"#,
                     #"{"version":1,"items":[""],"expiresAt":1240}"#,
                     #"{"version":1,"items":[3],"expiresAt":1240}"#] {
            XCTAssertNil(PasteStackBatchRequest.decode(Data(text.utf8), now: 1000))
        }
        let tooMany = try JSONSerialization.data(withJSONObject: ["version": 1, "items": Array(repeating: "a", count: 101), "expiresAt": 1240])
        XCTAssertNil(PasteStackBatchRequest.decode(tooMany, now: 1000))
        let tooMuch = try JSONSerialization.data(withJSONObject: ["version": 1, "items": [String(repeating: "a", count: 1_048_577)], "expiresAt": 1240])
        XCTAssertNil(PasteStackBatchRequest.decode(tooMuch, now: 1000))
        XCTAssertNil(PasteStackBatchRequest.decode(Data(repeating: 0, count: 6_295_553), now: 1000))
    }
}
