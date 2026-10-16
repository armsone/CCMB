import Foundation
import XCTest
@testable import CodexCreditMenuBar

final class NASDynamicAccountTests: XCTestCase {
    private func snapshot(selected: String, service: String = "gemini2", role: String = "secondary", hostID: String = "nas", actual: String? = nil, historyIdentity: String = "abcd1234", failed: Bool = false) throws -> NASSnapshotV2 {
        let now = Date().timeIntervalSince1970
        let entries: [[String: Any]] = NASServiceID.allCases.map { id in
            let gemini = id == .gemini || id == .gemini2
            var entry: [String: Any] = [
                "service": id.rawValue, "provider": id.provider, "account_ref": id.accountRef as Any? ?? NSNull(),
                "ok": !(failed && id == .gemini2), "stale": failed && id == .gemini2,
                "fetched_at": now,
                "items": [["name": gemini ? "Gemini Models" : id == .codex ? "codex" : "전체",
                           "window": gemini ? "session" : "weekly", "window_minutes": gemini ? 300 : 10080,
                           "remaining_percent": 75, "resets_at": now + 3600]],
                "error": NSNull()
            ]
            if gemini {
                entry["actual_account_ref"] = id == .gemini ? "account1" : (actual ?? selected)
                entry["history_identity"] = id == .gemini ? "1" : historyIdentity
            }
            if failed && id == .gemini2 {
                entry["items"] = []
                entry["error"] = ["code": "not_collected", "message": ""]
            }
            return entry
        }
        let root: [String: Any] = ["schema_version": 2, "quota_origin": "nas", "generated_at": now,
            "services": entries, "auto_switch_enabled": true,
            "execution_hosts": [["host_id": hostID, "phase": "idle", "execution_account": NSNull(),
                "selected_account_id": selected, "selected_service": service, "role": role,
                "selection_generation": 3, "observed_at": now, "return_state": service == "gemini" ? "confirmed" : "pending"]]]
        return try XCTUnwrap(NASSnapshotV2Core.parse(JSONSerialization.data(withJSONObject: root)))
    }

    func testFourSecondaryIDsRetainIdleSelectionThroughCache() throws {
        var state = NASFourServiceState()
        for id in ["account2", "g_reserve_b", "g-reserve-c", "reserve4"] {
            state.apply(try snapshot(selected: id))
            XCTAssertEqual(state.selectedGeminiServiceID, .gemini2)
            XCTAssertNotNil(state.selectedGeminiSnapshot)
            XCTAssertEqual(state.slot(.gemini2).lastGood?.actualAccountRef, id)
            let restored = try XCTUnwrap(NASFourServiceState.decodeCache(XCTUnwrap(state.encodedCache())))
            XCTAssertEqual(restored.selectedGeminiServiceID, .gemini2)
            XCTAssertEqual(restored.hostStatus?.hosts.first?.selectedAccountID, id)
            XCTAssertEqual(restored.slot(.gemini2).lastGood?.historyIdentity, "abcd1234")
        }
    }

    func testPrimaryReturnAndOtherHostCannotOverrideNAS() throws {
        var state = NASFourServiceState()
        state.apply(try snapshot(selected: "reserve3"))
        state.apply(try snapshot(selected: "account1", service: "gemini", role: "primary", actual: "reserve3"))
        XCTAssertEqual(state.selectedGeminiServiceID, .gemini)
        XCTAssertNotNil(state.selectedGeminiSnapshot)
        state.apply(try snapshot(selected: "reserve3", hostID: "mac"))
        XCTAssertEqual(state.selectedGeminiServiceID, .gemini)
    }

    func testDifferentSelectedAccountNeverBorrowsOldQuotaOrHistory() throws {
        var state = NASFourServiceState()
        state.apply(try snapshot(selected: "reserve2"))
        state.apply(try snapshot(selected: "reserve3", actual: "reserve2"))
        XCTAssertEqual(state.selectedGeminiServiceID, .gemini2)
        XCTAssertNil(state.selectedGeminiSnapshot)
        XCTAssertFalse(state.canShowHistory(NASHistorySeries(identityGeneration: "abcd1234", points: []), for: .gemini2))
        state.apply(try snapshot(selected: "reserve3", historyIdentity: "newidentity"))
        XCTAssertFalse(state.canShowHistory(NASHistorySeries(identityGeneration: "abcd1234", points: []), for: .gemini2))
        XCTAssertTrue(state.canShowHistory(NASHistorySeries(identityGeneration: "newidentity", points: []), for: .gemini2))
    }

    func testFailedNewAccountClearsOldAccountCacheOnly() throws {
        var state = NASFourServiceState()
        state.apply(try snapshot(selected: "reserve2"))
        state.apply(try snapshot(selected: "reserve3", failed: true))
        XCTAssertNil(state.slot(.gemini2).lastGood)
        XCTAssertNil(state.selectedGeminiSnapshot)
        XCTAssertNotNil(state.codexSnapshot)
        XCTAssertNotNil(state.geminiSnapshot)
    }

    func testMalformedSelectionCannotLeakOrEraseHealthyQuotas() throws {
        var state = NASFourServiceState()
        state.apply(try snapshot(selected: "private@example.com", actual: "reserve3"))
        XCTAssertTrue(state.hostStatus?.hosts.isEmpty == true)
        XCTAssertNotNil(state.gemini2Snapshot)
        let cache = String(decoding: try XCTUnwrap(state.encodedCache()), as: UTF8.self)
        XCTAssertFalse(cache.contains("@"))
    }
}
