import ServiceManagement
import XCTest
@testable import CotypeMenuApp

@MainActor
final class LaunchAtLoginModelTests: XCTestCase {
    private struct RegistrationFailure: LocalizedError {
        var errorDescription: String? { "Registration was refused." }
    }

    func testFailedRegistrationSurvivesRefreshOfOSStatus() {
        let model = LaunchAtLoginModel(
            readStatus: { .notRegistered },
            updateRegistration: { _ in throw RegistrationFailure() }
        )
        model.setEnabled(true)
        model.refresh()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.registrationStatusText, "")
        XCTAssertEqual(model.operationError, "Could not update Launch at Login: Registration was refused.")
        XCTAssertEqual(model.statusText, model.operationError)
    }

    func testSuccessfulRetryClearsErrorAndUsesCurrentOSStatus() {
        var status: SMAppService.Status = .notRegistered
        var shouldFail = true
        let model = LaunchAtLoginModel(readStatus: { status }, updateRegistration: { enabled in
            if shouldFail { throw RegistrationFailure() }
            status = enabled ? .enabled : .notRegistered
        })
        model.setEnabled(true)
        XCTAssertNotNil(model.operationError)
        shouldFail = false
        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.operationError)
        XCTAssertEqual(model.statusText, "Cotype will open when you log in.")
        model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.statusText, "")
    }

    func testApprovalAndRegistrationFailureRemainSeparate() {
        let model = LaunchAtLoginModel(
            readStatus: { .requiresApproval },
            updateRegistration: { _ in throw RegistrationFailure() }
        )
        model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.registrationStatusText.contains("Approval needed"))
        XCTAssertNotNil(model.operationError)
        XCTAssertTrue(model.statusText.contains("Could not update"))
    }
}
