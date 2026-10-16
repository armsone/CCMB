import Foundation
import XCTest
@testable import CodexCreditMenuBar

final class ClaudeLimitResetsTests: XCTestCase {
    private func entry(_ resets: Any? = nil, provider: NASServiceID = .claude) throws -> NASServiceEntry {
        var details: [String: Any] = ["plan_type": "max_5x", "extra_usage": ["is_enabled": false]]
        if let resets { details["limit_resets"] = resets }
        let item: [String: Any] = ["name": "전체", "window": "weekly", "remaining_percent": 75,
                                 "resets_at": NSNull(), "claude_details": details]
        let object: [String: Any] = ["service": provider.rawValue, "provider": provider.provider,
            "account_ref": provider.accountRef as Any? ?? NSNull(), "ok": true, "stale": false,
            "fetched_at": Date().timeIntervalSince1970, "items": [item], "error": NSNull()]
        guard case let .entry(entry) = NASServiceEntry.parse(object, expected: provider) else {
            throw NSError(domain: "fixture", code: 1)
        }
        return entry
    }

    func testConfirmedZeroIsDifferentFromMissing() throws {
        let zero = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: entry(["remaining_count": 0, "usable_now": false, "expires_at": NSNull()])))
        XCTAssertEqual(zero.limitResets?.remainingCount, 0)
        XCTAssertEqual(ClaudeUsageCore.limitResetsTitle(zero.limitResets), "0개")
        let missing = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: entry()))
        XCTAssertNil(missing.limitResets)
        XCTAssertEqual(ClaudeUsageCore.limitResetsTitle(missing.limitResets), "확인 불가")
        XCTAssertEqual(missing.planTitle, "Claude Max 5×")
        XCTAssertEqual(missing.extraUsage?.isEnabled, false)
        XCTAssertEqual(missing.weeklyUsedPercent, 25)
    }

    func testPositiveCountAndEligibilityRemainSeparate() throws {
        for usable in [true, false] {
            let snap = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: entry(["remaining_count": 3, "usable_now": usable, "expires_at": 1_800_000_000])))
            XCTAssertEqual(snap.limitResets?.remainingCount, 3)
            XCTAssertEqual(snap.limitResets?.usableNow, usable)
            XCTAssertEqual(snap.limitResets?.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(ClaudeUsageCore.limitResetsTitle(snap.limitResets), usable ? "3개 · 사용 가능" : "3개 · 대기")
        }
        let unknown = try XCTUnwrap(ClaudeLimitResets.parse(["remaining_count": 2, "usable_now": NSNull()]))
        XCTAssertNil(unknown.usableNow)
        XCTAssertEqual(ClaudeUsageCore.limitResetsTitle(unknown), "2개")
    }

    func testMalformedAndOverflowCannotEraseHealthyQuotaOrCreateZero() throws {
        let invalid: [Any] = [NSNull(), "bad", [:], ["remaining_count": true], ["remaining_count": -1],
            ["remaining_count": 0.5], ["remaining_count": 9_007_199_254_740_992 as UInt64],
            ["remaining_count": 2, "usable_now": 1], ["remaining_count": 2, "usable_now": "true"],
            ["remaining_count": 2, "expires_at": true], ["remaining_count": 2, "expires_at": -1]]
        for raw in invalid {
            let snap = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: entry(raw)))
            XCTAssertNil(snap.limitResets, "\(raw)")
            XCTAssertEqual(snap.weeklyUsedPercent, 25)
            XCTAssertEqual(snap.planTitle, "Claude Max 5×")
            XCTAssertEqual(snap.extraUsage?.isEnabled, false)
        }
        XCTAssertEqual(ClaudeLimitResets.parse(["remaining_count": 9_007_199_254_740_991 as UInt64])?.remainingCount, 9_007_199_254_740_991)
    }

    func testNASCacheAndSharedPayloadRoundTrip() throws {
        let source = try entry(["remaining_count": 4, "usable_now": false, "expires_at": 1_800_000_000])
        var state = NASFourServiceState()
        state.apply(NASSnapshotV2(generatedAt: Date(), collection: nil, entries: [source]))
        let restored = try XCTUnwrap(NASFourServiceState.decodeCache(XCTUnwrap(state.encodedCache())))
        let snap = try XCTUnwrap(restored.claudeSnapshot)
        XCTAssertEqual(snap.limitResets?.remainingCount, 4)
        let shared = ClaudeUsageCore.sharedPayload(from: snap)
        let sharedData = try JSONSerialization.data(withJSONObject: shared)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sharedData) as? [String: Any])
        let roundTrip = try XCTUnwrap(ClaudeUsageCore.snapshot(fromSharedPayload: object))
        XCTAssertEqual(roundTrip.limitResets, snap.limitResets)
        XCTAssertEqual(roundTrip.withAccount(nil).limitResets, snap.limitResets)
        var invalid = object
        invalid["limitResets"] = ["remaining_count": true]
        XCTAssertNil(ClaudeUsageCore.snapshot(fromSharedPayload: invalid)?.limitResets)
    }

    func testMissingFreshDataNeverBackfillsOldGrantCount() throws {
        let old = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: entry(["remaining_count": 2])))
        let fresh = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: entry()))
        XCTAssertNil(ClaudeUsageCore.merge(preferred: fresh, fallback: old).limitResets)
        let foreign = try entry(["remaining_count": 5], provider: .codex)
        XCTAssertNil(foreign.items.first?.claudeLimitResets)
        XCTAssertTrue(ClaudeUsageCore.sharedPayload(from: nil)["limitResets"] is NSNull)
    }
}
