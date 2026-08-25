import XCTest
@testable import CodexCreditMenuBar

@MainActor
final class UpdateDownloadPreferenceTests: XCTestCase {
    func testToggleWritesPreferenceAndUpdatesStatus() {
        var stored = true
        let preference = UpdateDownloadPreference(
            read: { stored },
            write: { stored = $0 }
        )

        XCTAssertTrue(preference.isEnabled)
        XCTAssertEqual(preference.statusText, "자동 다운로드 켬")

        preference.setEnabled(false)

        XCTAssertFalse(stored)
        XCTAssertFalse(preference.isEnabled)
        XCTAssertEqual(preference.statusText, "자동 다운로드 끔")
    }

    func testUsesEffectiveValueWhenUpdaterRejectsChange() {
        var requested: Bool?
        let preference = UpdateDownloadPreference(
            read: { false },
            write: { requested = $0 }
        )

        preference.setEnabled(true)

        XCTAssertEqual(requested, true)
        XCTAssertFalse(preference.isEnabled)
        XCTAssertEqual(preference.statusText, "자동 다운로드 끔")
    }
}
