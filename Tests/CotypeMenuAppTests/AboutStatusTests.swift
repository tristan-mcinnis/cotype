import CotypeCore
import XCTest
@testable import CotypeMenuApp

final class AboutStatusTests: XCTestCase {
    @MainActor
    func testUnavailableAssessmentIsNotReportedAsNotarizationRejection() {
        let unavailable = NotarizationStatus(
            accepted: false, source: "", identity: "",
            codesignAccepted: false, assessmentAvailable: false
        )
        XCTAssertEqual(AboutPane.notarizedLabel(for: unavailable), "Verification unavailable")
        XCTAssertEqual(AboutPane.notarizedLabel(for: nil), "Checking…")
        let rejected = NotarizationStatus(accepted: false, source: "", identity: "", codesignAccepted: true)
        XCTAssertEqual(AboutPane.notarizedLabel(for: rejected), "No — not notarized")
    }
}
