import XCTest
@testable import CopyCore

final class PasteStackExternalAccessTests: XCTestCase {
    func testDisabledDoesNotReadProtectedStorage() {
        var reads = 0
        let access = PasteStackExternalAccess(enabled: false, read: { reads += 1; return nil }, write: { _ in true })
        XCTAssertFalse(access.permitsRequests())
        XCTAssertEqual(reads, 0)
    }

    func testModifiedPreferenceCannotEnableWithoutProtectedConsent() {
        let access = PasteStackExternalAccess(enabled: true, read: { nil }, write: { _ in true })
        XCTAssertFalse(access.permitsRequests())
    }

    func testEnablePersistsConsentAndPermissions() {
        var protected: PasteStackExternalAccess.State?
        let access = PasteStackExternalAccess(enabled: false, read: { protected }, write: { protected = $0; return true })
        XCTAssertTrue(access.enable())
        XCTAssertTrue(access.permitsRequests())
        XCTAssertEqual(protected?.enabled, true)
    }

    func testFailedConsentWriteStaysDisabled() {
        let access = PasteStackExternalAccess(enabled: false, read: { nil }, write: { _ in false })
        XCTAssertFalse(access.enable())
        XCTAssertFalse(access.permitsRequests())
    }

    func testPermissionChangesAreProtectedAndRevocable() {
        var protected: PasteStackExternalAccess.State?
        let access = PasteStackExternalAccess(enabled: false, read: { protected }, write: { protected = $0; return true })
        let permission = PasteStackPermission.developer(bundleID: "org.example.app", canonicalPath: "/Applications/Test.app")
        XCTAssertFalse(access.setPermissions([permission]))
        XCTAssertTrue(access.enable())
        XCTAssertTrue(access.setPermissions([permission]))
        XCTAssertEqual(access.permissions(), [permission])
        XCTAssertTrue(access.setPermissions([]))
        XCTAssertTrue(access.permissions().isEmpty)
        XCTAssertTrue(access.disable())
        XCTAssertFalse(access.permitsRequests())
        XCTAssertFalse(protected!.enabled)
    }

    func testFailedDisableDoesNotReportSuccess() {
        var canWrite = true
        var protected: PasteStackExternalAccess.State?
        let access = PasteStackExternalAccess(enabled: false, read: { protected }, write: { state in
            guard canWrite else { return false }
            protected = state
            return true
        })
        XCTAssertTrue(access.enable())
        canWrite = false
        XCTAssertFalse(access.disable())
        XCTAssertTrue(access.permitsRequests())
    }
}
