import XCTest
@testable import CopyCore

final class PasteStackPermissionTests: XCTestCase {
    func testVerifiedPermissionRequiresBundleSigningIDAndCertificate() {
        let entry = PasteStackPermission.signed(bundleID: "org.example.app", signingID: "org.example.app", certificateSHA256: "ABC")
        let caller = PasteStackCaller(bundleID: "org.example.app", canonicalPath: "/Applications/Example.app", signingID: "org.example.app", certificateSHA256: "ABC")
        XCTAssertTrue(entry.permits(caller))
        var changed = caller
        changed.bundleID = "org.example.other"
        XCTAssertFalse(entry.permits(changed))
        changed = caller
        changed.signingID = "org.example.other"
        XCTAssertFalse(entry.permits(changed))
        changed = caller
        changed.certificateSHA256 = "DEF"
        XCTAssertFalse(entry.permits(changed))
        changed = caller
        changed.certificateSHA256 = nil
        XCTAssertFalse(entry.permits(changed))
    }

    func testDeveloperExceptionRequiresExactCanonicalPathAndBundleID() {
        let entry = PasteStackPermission.developer(bundleID: "org.example.app", canonicalPath: "/Applications/Example.app")
        XCTAssertTrue(entry.permits(PasteStackCaller(bundleID: "org.example.app", canonicalPath: "/Applications/Example.app")))
        XCTAssertFalse(entry.permits(PasteStackCaller(bundleID: "org.example.app", canonicalPath: "/tmp/Example.app")))
        XCTAssertFalse(entry.permits(PasteStackCaller(bundleID: "org.example.other", canonicalPath: "/Applications/Example.app")))
    }

    func testEmptyIdentityNeverMatchesAnEntry() {
        let caller = PasteStackCaller(bundleID: "", canonicalPath: "", signingID: "", certificateSHA256: "")
        XCTAssertFalse(PasteStackPermission.signed(bundleID: "", signingID: "", certificateSHA256: "").permits(caller))
        XCTAssertFalse(PasteStackPermission.developer(bundleID: "", canonicalPath: "").permits(caller))
    }

    func testPermissionsRoundTrip() throws {
        let entries: [PasteStackPermission] = [
            .signed(bundleID: "org.example.app", signingID: "org.example.app", certificateSHA256: "ABC"),
            .developer(bundleID: "org.example.app", canonicalPath: "/Applications/Example.app")
        ]
        XCTAssertEqual(try JSONDecoder().decode([PasteStackPermission].self, from: JSONEncoder().encode(entries)), entries)
    }
}
