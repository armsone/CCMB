import XCTest
@testable import CodexCreditMenuBar

@MainActor
final class LowerControlsLayoutTests: XCTestCase {
    func testVersionOpacityRowUsesOneAlignedVisualGrid() {
        let view = VersionOpacityRowView(
            alwaysTitle: "항상 보기",
            updateTitle: "업데이트 확인…",
            versionTitle: "현재 버전 2.0.9"
        )

        XCTAssertEqual(view.frame.height, 48, accuracy: 0.001)
        XCTAssertEqual(view.alwaysViewButton.frame.minY, view.updateButton.frame.minY, accuracy: 0.001)
        XCTAssertEqual(view.updateButton.frame.height, 42, accuracy: 0.001)
        XCTAssertEqual(view.updateButton.title, "업데이트 확인 · 2.0.9")
    }

    func testHistoryCaptionsFitOnOneLineWithoutRepeatingProviderName() throws {
        let view = UsageHistoryChartView()
        let strip = UsageHistoryStrip(
            caption: "갱신당 주간 0% · Spark 0%",
            series: [],
            slotCount: 3,
            unitSuffix: "%",
            accessibilityValue: "최근 갱신 소비 기록"
        )

        XCTAssertTrue(view.apply(codex: strip, claude: nil, gemini: nil, grok: nil))
        let caption = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first { !$0.isHidden })
        XCTAssertEqual(caption.stringValue, strip.caption)
        XCTAssertFalse(caption.stringValue.contains("Codex"))
        XCTAssertEqual(caption.maximumNumberOfLines, 1)
        XCTAssertEqual(caption.lineBreakMode, .byClipping)
        XCTAssertEqual(caption.cell?.truncatesLastVisibleLine, false)
        XCTAssertEqual(caption.frame.height, 13, accuracy: 0.001)
        XCTAssertLessThanOrEqual(caption.intrinsicContentSize.width, caption.frame.width)
    }

    func testHistoryHoverTimeUsesTwentyFourHourMinutesOnly() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/CodexCreditMenuBar/ClaudeUsagePanel.swift")
            .standardized
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("formatter.dateFormat = \"HH:mm\""))
        XCTAssertFalse(source.contains("formatter.dateFormat = \"a h:mm:ss\""))
    }

    func testAllDisplayedDatesIncludeWeekdayAndUseTwentyFourHourTime() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/CodexCreditMenuBar/main.swift")
            .standardized
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("formatter.dateFormat = \"M/d(EEEEE) HH:mm\""))
        XCTAssertTrue(source.contains("formatter.dateFormat = \"HH:mm:ss\""))
    }
}

final class UsageCoreTests: XCTestCase {
    func testSmartRefreshPolicySlowsFromOneToThreeToFiveToTenMinutes() {
        var policy = SmartRefreshPolicy()
        XCTAssertEqual(policy.interval, 60)
        XCTAssertFalse(policy.update(values: [10, 20]))

        for _ in 0..<2 { XCTAssertFalse(policy.update(values: [10, 20])) }
        XCTAssertTrue(policy.update(values: [10, 20]))
        XCTAssertEqual(policy.interval, 180)

        for _ in 0..<5 { XCTAssertFalse(policy.update(values: [10, 20])) }
        XCTAssertTrue(policy.update(values: [10, 20]))
        XCTAssertEqual(policy.interval, 300)

        for _ in 0..<11 { XCTAssertFalse(policy.update(values: [10, 20])) }
        XCTAssertTrue(policy.update(values: [10, 20]))
        XCTAssertEqual(policy.interval, 600)
    }

    func testSmartRefreshPolicyReturnsToOneMinuteWhenAnyValueChanges() {
        var policy = SmartRefreshPolicy()
        XCTAssertFalse(policy.update(values: [10, 20]))
        for _ in 0..<3 { _ = policy.update(values: [10, 20]) }
        XCTAssertEqual(policy.interval, 180)

        XCTAssertTrue(policy.update(values: [10, 20.02]))
        XCTAssertEqual(policy.interval, 60)
        XCTAssertEqual(policy.unchangedCount, 0)
    }

    @MainActor
    func testPinnedPanelContentScaleIsCompactAndClamped() {
        XCTAssertEqual(PinnedUsageWindowController.normalizedContentScale(0.2), 0.4)
        XCTAssertEqual(PinnedUsageWindowController.normalizedContentScale(0.4), 0.4)
        XCTAssertEqual(PinnedUsageWindowController.normalizedContentScale(0.8), 0.8)
        XCTAssertEqual(PinnedUsageWindowController.normalizedContentScale(1.4), 1.0)
    }

    func testClaudePlanReadsOnlyAccountMetadataAndUsesRateLimitTier() {
        let data = Data(#"{"oauthAccount":{"organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_5x"}}"#.utf8)
        XCTAssertEqual(ClaudePlanCore.title(fromAccountMetadata: data), "Claude Max 5×")
        XCTAssertNil(ClaudePlanCore.title(fromAccountMetadata: Data(#"{"other":true}"#.utf8)))
    }

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(UsageCore.remainingPercent(from: -5), 100)
        XCTAssertEqual(UsageCore.remainingPercent(from: 25), 75)
        XCTAssertEqual(UsageCore.remainingPercent(from: 120), 0)
    }

    func testSparkWeeklyWindowReadsSecondaryAppServerBucket() throws {
        let buckets: [String: Any] = [
            "codex": [
                "limitId": "codex",
                "primary": ["usedPercent": 47, "windowDurationMins": 10_080]
            ],
            "codex_bengalfox": [
                "limitId": "codex_bengalfox",
                "limitName": "GPT-5.3-Codex-Spark",
                "primary": ["usedPercent": 47, "windowDurationMins": 300],
                "secondary": ["usedPercent": 21, "windowDurationMins": 10_080, "resetsAt": 1_787_904_744]
            ]
        ]

        let weekly = try XCTUnwrap(UsageCore.sparkWeeklyWindow(from: buckets))

        XCTAssertEqual(weekly.usedPercent, 21)
        XCTAssertEqual(weekly.windowDurationMinutes, 10_080)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_787_904_744))
    }

    func testSparkWeeklyWindowDoesNotMistakePrimaryCodexBucketForSpark() {
        let buckets: [String: Any] = [
            "codex": [
                "limitId": "codex",
                "primary": ["usedPercent": 47, "windowDurationMins": 10_080]
            ]
        ]

        XCTAssertNil(UsageCore.sparkWeeklyWindow(from: buckets))
    }

    func testPositiveSubunitCreditRemainsVisible() {
        XCTAssertEqual(UsageCore.creditTitle(from: 0.49), "0.49")
        XCTAssertEqual(UsageCore.creditTitle(from: 0.1), "0.1")
        XCTAssertNil(UsageCore.creditTitle(from: 0))
        XCTAssertNil(UsageCore.creditTitle(from: nil))
        XCTAssertEqual(UsageCore.creditTitle(from: 10.6), "11")
    }

    func testCreditDetailUsesAtMostTwoFractionDigits() {
        XCTAssertEqual(UsageCore.creditDetailTitle(from: 0.1234), "0.12")
        XCTAssertEqual(UsageCore.creditDetailTitle(from: 10.6), "10.6")
        XCTAssertEqual(UsageCore.creditDetailTitle(from: 10), "10")
    }

    func testMenuBarSwitchesFromWeeklyPercentToCreditsAtZero() {
        XCTAssertEqual(UsageCore.menuBarCodexTitle(usedPercent: 98, creditBalance: 2_687.78), "2%")
        XCTAssertEqual(UsageCore.menuBarCodexTitle(usedPercent: 100, creditBalance: 2_687.78), "2688")
        XCTAssertEqual(UsageCore.menuBarCodexTitle(usedPercent: 100, creditBalance: nil), "0%")
        XCTAssertEqual(UsageCore.menuBarCodexTitle(usedPercent: nil, creditBalance: 0.49), "0.49")
    }

    func testCodexQuotaDisplaysCreditsOnlyAfterWeeklyQuotaIsExhausted() {
        XCTAssertFalse(UsageCore.codexQuotaDisplaysCredits(usedPercent: 99, creditBalance: 10))
        XCTAssertTrue(UsageCore.codexQuotaDisplaysCredits(usedPercent: 100, creditBalance: 10))
        XCTAssertTrue(UsageCore.codexQuotaDisplaysCredits(usedPercent: 120, creditBalance: 0.5))
        XCTAssertFalse(UsageCore.codexQuotaDisplaysCredits(usedPercent: 100, creditBalance: 0))
        XCTAssertFalse(UsageCore.codexQuotaDisplaysCredits(usedPercent: nil, creditBalance: 10))
    }

    func testUsageHelperOnlyReplacesCCMBOwnedFile() {
        XCTAssertTrue(UsageCore.canReplaceUsageHelper(existingContents: nil))
        XCTAssertTrue(UsageCore.canReplaceUsageHelper(existingContents: "#!/bin/sh\n# CCMB_USAGE_HELPER_VERSION=1\n"))
        XCTAssertFalse(UsageCore.canReplaceUsageHelper(existingContents: "#!/bin/sh\necho custom\n"))
    }

    func testCacheAgeNeverBecomesNegative() {
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(UsageCore.cacheAgeSeconds(fetchedAt: Date(timeIntervalSince1970: 90), now: now), 10)
        XCTAssertEqual(UsageCore.cacheAgeSeconds(fetchedAt: Date(timeIntervalSince1970: 110), now: now), 0)
        XCTAssertEqual(UsageCore.cacheAgeSeconds(fetchedAt: nil, now: now), Int.max)
    }

    func testCacheFreshnessRequiresAllEvidence() {
        XCTAssertTrue(UsageCore.cacheIsFresh(statusOK: true, processMatches: true, ageSeconds: 45, freshForSeconds: 45))
        XCTAssertFalse(UsageCore.cacheIsFresh(statusOK: false, processMatches: true, ageSeconds: 1, freshForSeconds: 45))
        XCTAssertFalse(UsageCore.cacheIsFresh(statusOK: true, processMatches: false, ageSeconds: 1, freshForSeconds: 45))
        XCTAssertFalse(UsageCore.cacheIsFresh(statusOK: true, processMatches: true, ageSeconds: 46, freshForSeconds: 45))
    }

    func testRefreshIntervalOnlyAcceptsSupportedValues() {
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(nil), -1)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(-1), -1)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(60), 60)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(180), 180)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(600), 600)
        // An unknown stored value falls back to the default, not to whatever
        // the first option happens to be.
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(42), -1)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(30), -1)

        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(nil), -1)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(-1), -1)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(300), 300)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(600), 600)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(42), -1)

        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(nil), -1)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(-1), -1)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(180), 180)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(42), -1)
    }

    func testRefreshIntervalOptionsCoverTheAdvertisedCadences() {
        XCTAssertEqual(UsageCore.refreshIntervalOptions, [-1, 0, 60, 180, 300, 600])
        XCTAssertEqual(UsageCore.claudeRefreshIntervalOptions, [-1, 0, 60, 180, 300, 600])
        XCTAssertEqual(UsageCore.geminiRefreshIntervalOptions, [-1, 0, 60, 180, 300, 600])
        XCTAssertTrue(UsageCore.refreshIntervalOptions.contains(UsageCore.defaultRefreshIntervalSeconds))
        XCTAssertTrue(UsageCore.claudeRefreshIntervalOptions.contains(UsageCore.defaultClaudeRefreshIntervalSeconds))
        XCTAssertTrue(UsageCore.geminiRefreshIntervalOptions.contains(UsageCore.defaultGeminiRefreshIntervalSeconds))
    }

    func testPanelOpacityIsClampedToNinetyFiveThroughOneHundredPercent() {
        XCTAssertEqual(UsageCore.normalizedPanelOpacity(0.7), 0.95)
        XCTAssertEqual(UsageCore.normalizedPanelOpacity(0.95), 0.95)
        XCTAssertEqual(UsageCore.normalizedPanelOpacity(0.975), 0.975)
        XCTAssertEqual(UsageCore.normalizedPanelOpacity(1.0), 1.0)
        XCTAssertEqual(UsageCore.normalizedPanelOpacity(1.2), 1.0)
    }

    func testCacheFallbackReasonTreatsCorruptCacheLikeMissing() {
        XCTAssertEqual(UsageCore.cacheFallbackReason(cacheExists: true, cacheIsCorrupt: true), "corrupt")
        XCTAssertEqual(UsageCore.cacheFallbackReason(cacheExists: false, cacheIsCorrupt: true), "corrupt")
        XCTAssertEqual(UsageCore.cacheFallbackReason(cacheExists: false, cacheIsCorrupt: false), "missing")
        XCTAssertEqual(UsageCore.cacheFallbackReason(cacheExists: true, cacheIsCorrupt: false), "stale-or-ccmb-not-running")
    }

    func testCacheOnlyFailureMessageDistinguishesCorruptFromMissing() {
        XCTAssertTrue(UsageCore.cacheOnlyFailureMessage(cacheIsCorrupt: true, path: "/tmp/x").contains("손상"))
        XCTAssertTrue(UsageCore.cacheOnlyFailureMessage(cacheIsCorrupt: false, path: "/tmp/x").contains("없습니다"))
    }

    private func makeRateLimitSnapshot(
        accountID: String? = nil,
        planType: String? = nil,
        usedPercent: Double? = nil,
        windowDurationMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetCredits: Int? = nil,
        creditBalance: Double? = nil,
        sparkUsedPercent: Double? = nil,
        sparkWindowDurationMinutes: Int? = nil,
        sparkResetsAt: Date? = nil,
        detailedCreditsReturned: Bool = false,
        updatedAt: Date
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            accountID: accountID,
            planType: planType,
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt,
            resetCredits: resetCredits,
            creditBalance: creditBalance,
            sparkUsedPercent: sparkUsedPercent,
            sparkWindowDurationMinutes: sparkWindowDurationMinutes,
            sparkResetsAt: sparkResetsAt,
            detailedCreditsReturned: detailedCreditsReturned,
            updatedAt: updatedAt
        )
    }

    func testCodexPlanTitlesUseOfficialProtocolValues() {
        XCTAssertEqual(CodexPlanCore.title(for: "plus"), "ChatGPT Plus")
        XCTAssertEqual(CodexPlanCore.title(for: "pro"), "ChatGPT Pro")
        XCTAssertEqual(CodexPlanCore.title(for: "business"), "ChatGPT Business")
        XCTAssertEqual(CodexPlanCore.title(for: "enterprise_cbp_usage_based"), "ChatGPT Enterprise · 사용량 기반")
        XCTAssertNil(CodexPlanCore.title(for: "unknown"))
        XCTAssertNil(CodexPlanCore.title(for: "future-plan"))
    }

    func testCodexPayloadForMissingSnapshotIsExplicitlyUnavailable() {
        let payload = UsageCore.codexPayload(from: nil, freshForSeconds: 45)

        XCTAssertEqual(payload["status"] as? String, "unavailable")
        XCTAssertTrue(payload["weeklyRemainingPercent"] is NSNull)
        XCTAssertTrue(payload["sparkRemainingPercent"] is NSNull)
        XCTAssertTrue(payload["sparkUsedPercent"] is NSNull)
        XCTAssertTrue(payload["sparkResetsAt"] is NSNull)
        XCTAssertTrue(payload["sparkWindowDurationMins"] is NSNull)
        XCTAssertTrue(payload["account"] is NSNull)
        XCTAssertEqual(payload["fresh"] as? Bool, false)
        XCTAssertEqual(payload["freshForSeconds"] as? Int, 45)
    }

    func testCodexPayloadKeepsRetiredSparkFieldsNull() {
        let now = Date(timeIntervalSince1970: 1_000)
        let sparkResetsAt = Date(timeIntervalSince1970: 1_250)
        let snapshot = makeRateLimitSnapshot(
            accountID: "user@example.com",
            usedPercent: 30,
            resetCredits: 5,
            creditBalance: 12.5,
            sparkUsedPercent: 20,
            sparkWindowDurationMinutes: 1_440,
            sparkResetsAt: sparkResetsAt,
            updatedAt: Date(timeIntervalSince1970: 970)
        )

        let payload = UsageCore.codexPayload(from: snapshot, freshForSeconds: 45, now: now)

        XCTAssertTrue(payload["sparkRemainingPercent"] is NSNull)
        XCTAssertTrue(payload["sparkUsedPercent"] is NSNull)
        XCTAssertTrue(payload["sparkWindowDurationMins"] is NSNull)
        XCTAssertTrue(payload["sparkResetsAt"] is NSNull)
    }

    func testCodexPayloadIncludesWeeklyCreditAccountAndFreshness() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeRateLimitSnapshot(
            accountID: "user@example.com",
            usedPercent: 30,
            resetCredits: 5,
            creditBalance: 12.5,
            updatedAt: Date(timeIntervalSince1970: 970)
        )

        let payload = UsageCore.codexPayload(from: snapshot, freshForSeconds: 45, now: now)

        XCTAssertEqual(payload["status"] as? String, "ok")
        XCTAssertEqual(payload["weeklyRemainingPercent"] as? Double, 70)
        XCTAssertEqual(payload["weeklyUsedPercent"] as? Double, 30)
        XCTAssertEqual(payload["account"] as? String, "user@example.com")
        XCTAssertEqual(payload["creditBalance"] as? Double, 12.5)
        XCTAssertEqual(payload["resetCredits"] as? Int, 5)
        XCTAssertEqual(payload["ageSeconds"] as? Int, 30)
        XCTAssertEqual(payload["fresh"] as? Bool, true)
    }

    func testCodexPayloadBecomesStaleBeyondFreshForSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = makeRateLimitSnapshot(usedPercent: 10, updatedAt: Date(timeIntervalSince1970: 900))

        let payload = UsageCore.codexPayload(from: snapshot, freshForSeconds: 45, now: now)

        XCTAssertEqual(payload["ageSeconds"] as? Int, 100)
        XCTAssertEqual(payload["fresh"] as? Bool, false)
    }

    func testRefreshedCodexPayloadRecalculatesFreshness() {
        let stored = UsageCore.codexPayload(
            from: makeRateLimitSnapshot(usedPercent: 10, updatedAt: Date(timeIntervalSince1970: 1_000)),
            freshForSeconds: 45,
            now: Date(timeIntervalSince1970: 1_000)
        )

        let refreshed = UsageCore.refreshedCodexPayload(stored, now: Date(timeIntervalSince1970: 1_100))

        XCTAssertEqual(refreshed["ageSeconds"] as? Int, 100)
        XCTAssertEqual(refreshed["fresh"] as? Bool, false)
    }

    func testRefreshedCodexPayloadClearsRetiredSparkFieldsFromOlderCache() {
        var stored = UsageCore.codexPayload(
            from: makeRateLimitSnapshot(
                usedPercent: 10,
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            freshForSeconds: 45,
            now: Date(timeIntervalSince1970: 1_000)
        )
        stored["sparkRemainingPercent"] = 80.0
        stored["sparkUsedPercent"] = 20.0
        stored["sparkWindowDurationMins"] = 1_440
        stored["sparkResetsAt"] = "1970-01-01T00:20:00.000Z"

        let refreshed = UsageCore.refreshedCodexPayload(stored, now: Date(timeIntervalSince1970: 1_100))

        XCTAssertTrue(refreshed["sparkRemainingPercent"] is NSNull)
        XCTAssertTrue(refreshed["sparkUsedPercent"] is NSNull)
        XCTAssertTrue(refreshed["sparkWindowDurationMins"] is NSNull)
        XCTAssertTrue(refreshed["sparkResetsAt"] is NSNull)
    }
}

final class UsageConsumptionHistoryStoreTests: XCTestCase {
    func testDecodingPreGeminiBlobPreservesCodexAndClaudeAndDefaultsGeminiEmpty() throws {
        var codex = UsageConsumptionTracker()
        codex.record(reading: 100, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "codex.credit")
        codex.record(reading: 90, at: Date(timeIntervalSince1970: 60), isDecreasing: true, metricKey: "codex.credit")
        var claude = UsageConsumptionTracker()
        claude.record(reading: 10, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "claude.session")
        claude.record(reading: 15, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "claude.session")

        struct LegacyStore: Codable {
            let codex: UsageConsumptionTracker
            let claude: UsageConsumptionTracker
        }
        let legacyData = try JSONEncoder().encode(LegacyStore(codex: codex, claude: claude))

        let restored = try JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: legacyData)

        XCTAssertEqual(restored.codex, codex)
        XCTAssertEqual(restored.claude, claude)
        XCTAssertTrue(restored.gemini.amounts.isEmpty)
        XCTAssertTrue(restored.grok.amounts.isEmpty)
    }

    func testRoundTripsWithGeminiHistoryIncluded() throws {
        var gemini = UsageConsumptionTracker()
        gemini.record(reading: 99, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "gemini.5h")
        gemini.record(reading: 95, at: Date(timeIntervalSince1970: 60), isDecreasing: true, metricKey: "gemini.5h")
        let store = UsageConsumptionHistoryStore(gemini: gemini)

        let data = try JSONEncoder().encode(store)
        let restored = try JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: data)

        XCTAssertEqual(restored, store)
        XCTAssertEqual(restored.gemini.amounts, [4])
    }

    func testDecodingPreGrokBlobDefaultsGrokEmpty() throws {
        var codex = UsageConsumptionTracker()
        codex.record(reading: 100, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "codex.credit")
        var gemini = UsageConsumptionTracker()
        gemini.record(reading: 99, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "gemini.5h")

        struct PreGrokStore: Codable {
            let codex: UsageConsumptionTracker
            let claude: UsageConsumptionTracker
            let gemini: UsageConsumptionTracker
        }
        let legacyData = try JSONEncoder().encode(
            PreGrokStore(codex: codex, claude: UsageConsumptionTracker(), gemini: gemini)
        )

        let restored = try JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: legacyData)

        XCTAssertEqual(restored.codex, codex)
        XCTAssertEqual(restored.gemini, gemini)
        XCTAssertTrue(restored.grok.amounts.isEmpty)
    }

    func testRoundTripsWithGrokHistoryIncluded() throws {
        var grok = UsageConsumptionTracker()
        grok.record(reading: 10, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "grok.weekly")
        grok.record(reading: 18, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "grok.weekly")
        let store = UsageConsumptionHistoryStore(grok: grok)

        let data = try JSONEncoder().encode(store)
        let restored = try JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: data)

        XCTAssertEqual(restored, store)
        XCTAssertEqual(restored.grok.amounts, [8])
    }

    func testDecodingPreSparkFableBlobDefaultsThoseBucketsEmpty() throws {
        var codex = UsageConsumptionTracker()
        codex.record(reading: 10, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "codex.weekly")
        codex.record(reading: 12, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "codex.weekly")

        struct PreSparkFableStore: Codable {
            let codex: UsageConsumptionTracker
            let claude: UsageConsumptionTracker
            let gemini: UsageConsumptionTracker
            let grok: UsageConsumptionTracker
        }
        let legacyData = try JSONEncoder().encode(PreSparkFableStore(
            codex: codex,
            claude: UsageConsumptionTracker(),
            gemini: UsageConsumptionTracker(),
            grok: UsageConsumptionTracker()
        ))

        let restored = try JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: legacyData)

        XCTAssertEqual(restored.codex, codex)
        XCTAssertTrue(restored.codexSpark.amounts.isEmpty)
        XCTAssertTrue(restored.claudeFable.amounts.isEmpty)
    }

    func testRoundTripsWithSparkAndFableHistoryIncluded() throws {
        var spark = UsageConsumptionTracker()
        spark.record(reading: 5, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "codex.spark.weekly")
        spark.record(reading: 7, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "codex.spark.weekly")
        var fable = UsageConsumptionTracker()
        fable.record(reading: 20, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "claude.fable.weekly")
        fable.record(reading: 21.5, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "claude.fable.weekly")
        let store = UsageConsumptionHistoryStore(codexSpark: spark, claudeFable: fable)

        let data = try JSONEncoder().encode(store)
        let restored = try JSONDecoder().decode(UsageConsumptionHistoryStore.self, from: data)

        XCTAssertEqual(restored, store)
        XCTAssertEqual(restored.codexSpark.amounts, [2])
        XCTAssertEqual(restored.claudeFable.amounts, [1.5])
    }
}

final class UsageConsumptionStackingTests: XCTestCase {
    private func sample(_ seconds: TimeInterval, _ amount: Double) -> UsageConsumptionSample {
        UsageConsumptionSample(at: Date(timeIntervalSince1970: seconds), amount: amount)
    }

    func testStackedSamplesAlignBucketsByRefreshTimestamp() {
        let ordinary = [sample(60, 1), sample(120, 2), sample(180, 3)]
        let spark = [sample(60, 0.5), sample(120, 0.25), sample(180, 0.75)]

        let stacked = UsageConsumptionCore.stackedSamples([ordinary, spark])

        XCTAssertEqual(stacked.map(\.at), [60, 120, 180].map { Date(timeIntervalSince1970: $0) })
        XCTAssertEqual(stacked.map(\.amounts), [[1, 0.5], [2, 0.25], [3, 0.75]])
        XCTAssertEqual(stacked.map(\.total), [1.5, 2.25, 3.75])
    }

    func testMissingBucketReadingStaysMissingAndIsNotCountedAsZero() {
        // Spark was absent from the second refresh and Fable-style buckets can
        // appear later than the ordinary meter: neither gap may become a 0.
        let ordinary = [sample(60, 1), sample(120, 2), sample(180, 3)]
        let spark = [sample(60, 0.5), sample(180, 0.75)]

        let stacked = UsageConsumptionCore.stackedSamples([ordinary, spark])

        XCTAssertEqual(stacked.count, 3)
        XCTAssertEqual(stacked[1].amounts, [2, nil])
        XCTAssertEqual(stacked[1].total, 2)
        XCTAssertNotEqual(stacked[1].amounts, [2, 0])
    }

    func testARefreshOnlyTheWorkerBucketReportedStillGetsASlot() {
        // The ordinary meter was momentarily nil while Spark reported: the
        // refresh is drawn from Spark alone, with the ordinary bucket missing.
        let ordinary = [sample(60, 1)]
        let spark = [sample(60, 0.5), sample(120, 0.25)]

        let stacked = UsageConsumptionCore.stackedSamples([ordinary, spark])

        XCTAssertEqual(stacked.map(\.at), [Date(timeIntervalSince1970: 60), Date(timeIntervalSince1970: 120)])
        XCTAssertEqual(stacked[1].amounts, [nil, 0.25])
        XCTAssertEqual(stacked[1].total, 0.25)
    }

    func testStackedSamplesKeepOnlyTheNewestRefreshes() {
        let ordinary = (0..<50).map { sample(TimeInterval($0) * 60, 1) }
        let spark = (0..<50).map { sample(TimeInterval($0) * 60, 0.5) }

        let stacked = UsageConsumptionCore.stackedSamples([ordinary, spark], capacity: 40)

        XCTAssertEqual(stacked.count, 40)
        XCTAssertEqual(stacked.first?.at, Date(timeIntervalSince1970: 10 * 60))
        XCTAssertEqual(stacked.last?.at, Date(timeIntervalSince1970: 49 * 60))
    }

    func testStackingASingleBucketMatchesItsOwnSamples() {
        let gemini = [sample(60, 4), sample(120, 0)]

        let stacked = UsageConsumptionCore.stackedSamples([gemini])

        XCTAssertEqual(stacked.map(\.amounts), [[4], [0]])
        XCTAssertEqual(stacked.map(\.total), [4, 0])
        XCTAssertTrue(UsageConsumptionCore.stackedSamples([]).isEmpty)
        XCTAssertTrue(UsageConsumptionCore.stackedSamples([[]]).isEmpty)
    }

    func testBreakdownTitleNamesEachReportedBucketWithoutInventingAQuotaTotal() {
        XCTAssertEqual(
            UsageConsumptionCore.breakdownTitle(amounts: [1.2, 0.3], labels: ["주간", "Spark"], unit: "%"),
            "주간 1.2% · Spark 0.3%"
        )
        XCTAssertEqual(
            UsageConsumptionCore.breakdownTitle(amounts: [0.4, 0.2], labels: ["주간", "Fable"], unit: "%"),
            "주간 0.4% · Fable 0.2%"
        )
    }

    func testBreakdownTitleOmitsMissingBucketsInsteadOfWritingZero() {
        // Only the ordinary meter reported: no total, no "Spark 0%".
        XCTAssertEqual(
            UsageConsumptionCore.breakdownTitle(amounts: [1.2, nil], labels: ["주간", "Spark"], unit: "%"),
            "주간 1.2%"
        )
        // Only the worker bucket reported.
        XCTAssertEqual(
            UsageConsumptionCore.breakdownTitle(amounts: [nil, 0.3], labels: ["주간", "Spark"], unit: "%"),
            "Spark 0.3%"
        )
        // A bucket that measured genuine zero work is still listed.
        XCTAssertEqual(
            UsageConsumptionCore.breakdownTitle(amounts: [1, 0], labels: ["주간", "Fable"], unit: "%"),
            "주간 1% · Fable 0%"
        )
    }

    func testBreakdownTitleKeepsThePlainReadoutForSingleBucketStrips() {
        // Gemini/Grok strips have one unlabeled bucket and read exactly as before.
        XCTAssertEqual(UsageConsumptionCore.breakdownTitle(amounts: [4], labels: [""], unit: "%"), "4%")
        // Codex on credits is a single bucket too; its label is not repeated.
        XCTAssertEqual(UsageConsumptionCore.breakdownTitle(amounts: [1.5], labels: ["크레딧"], unit: " 크레딧"), "1.5 크레딧")
        XCTAssertEqual(UsageConsumptionCore.breakdownTitle(amounts: [], labels: [], unit: "%"), "0%")
    }

    func testSparkAndFableBucketsRecordOnlyWhenTheSnapshotCarriesThem() {
        // Mirrors the app's recording: the worker bucket is fed the optional
        // figure straight from the snapshot, so a refresh without it leaves
        // no sample behind rather than a zero bar.
        var spark = UsageConsumptionTracker()
        spark.record(reading: 10, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "codex.spark.weekly")
        spark.record(reading: nil, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "codex.spark.weekly")
        spark.record(reading: 13, at: Date(timeIntervalSince1970: 120), isDecreasing: false, metricKey: "codex.spark.weekly")
        XCTAssertEqual(spark.samples.map(\.at), [Date(timeIntervalSince1970: 120)])
        XCTAssertEqual(spark.amounts, [3])

        let limits = [
            ClaudeModelWeeklyLimit(modelName: "Opus", usedPercent: 40, resetsAt: nil),
            ClaudeModelWeeklyLimit(modelName: "fable", usedPercent: 21.5, resetsAt: nil)
        ]
        var fable = UsageConsumptionTracker()
        fable.record(
            reading: ClaudeUsageCore.fableWeeklyLimit(in: limits)?.usedPercent,
            at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "claude.fable.weekly"
        )
        fable.record(
            reading: ClaudeUsageCore.fableWeeklyLimit(in: [limits[0]])?.usedPercent,
            at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "claude.fable.weekly"
        )
        fable.record(
            reading: ClaudeUsageCore.fableWeeklyLimit(in: limits)?.usedPercent.map { $0 + 2 },
            at: Date(timeIntervalSince1970: 120), isDecreasing: false, metricKey: "claude.fable.weekly"
        )
        XCTAssertEqual(fable.samples.map(\.at), [Date(timeIntervalSince1970: 120)])
        XCTAssertEqual(fable.amounts, [2])
    }
}

final class GeminiUsageCoreTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    func testActiveGeminiAccountReadsOnlyAValidEmail() {
        XCTAssertEqual(
            GeminiAccountCore.activeEmail(from: data(#"{"active":"person@example.com","old":[]}"#)),
            "person@example.com"
        )
        XCTAssertNil(GeminiAccountCore.activeEmail(from: data(#"{"active":"","old":[]}"#)))
        XCTAssertNil(GeminiAccountCore.activeEmail(from: data(#"{"active":"not-an-email","old":[]}"#)))
        XCTAssertNil(GeminiAccountCore.activeEmail(from: data("not-json")))
    }

    func testParseUsageReadsWeeklyAndFiveHourBucketsFromGeminiGroup() throws {
        let json = """
        {
            "command": {
                "name": "usage",
                "data": {
                    "groups": [
                        {
                            "name": "Gemini Models",
                            "buckets": [
                                {"id": "gemini-weekly", "name": "Weekly", "window": "weekly", "remaining_fraction": 0.9996002912521362, "reset_time": "2026-08-24T00:00:00.000000+00:00"},
                                {"id": "gemini-5h", "name": "5 hour", "window": "5h", "remaining_fraction": 0.9976015090942383, "reset_time": "2026-08-19T05:00:00.000000+00:00"}
                            ]
                        }
                    ]
                }
            }
        }
        """
        let buckets = try XCTUnwrap(GeminiUsageCore.parseUsage(data(json)))
        XCTAssertEqual(buckets.count, 2)

        let snapshot = GeminiUsageCore.snapshot(buckets: buckets, creditBalance: nil, publishedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(snapshot.weeklyRemainingFraction, 0.9996002912521362)
        XCTAssertEqual(snapshot.fiveHourRemainingFraction, 0.9976015090942383)
        XCTAssertNotNil(snapshot.weeklyResetsAt)
        XCTAssertNotNil(snapshot.fiveHourResetsAt)
    }

    func testPlanInferenceUsesStructuredAntigravityEntitlements() {
        let ultra = """
        {"command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-5h","remaining_fraction":1}]},
          {"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","remaining_fraction":1}]}
        ]}}}
        """
        XCTAssertEqual(GeminiUsageCore.parsePlanTitle(data(ultra)), "Google AI Pro")

        let paid = """
        {"command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","buckets":[{"id":"gemini-5h","remaining_fraction":1}]}
        ]}}}
        """
        XCTAssertEqual(GeminiUsageCore.parsePlanTitle(data(paid)), "Google AI Pro")
    }

    func testParseUsageRejectsWrongCommandName() {
        let json = """
        {"command": {"name": "credits", "data": {"groups": []}}}
        """
        XCTAssertNil(GeminiUsageCore.parseUsage(data(json)))
    }

    func testParseUsageReturnsNilWhenGeminiGroupMissing() {
        let json = """
        {"command": {"name": "usage", "data": {"groups": [{"name": "Other Models", "buckets": []}]}}}
        """
        XCTAssertNil(GeminiUsageCore.parseUsage(data(json)))
    }

    func testParseUsageReturnsNilForMalformedJSON() {
        XCTAssertNil(GeminiUsageCore.parseUsage(data("not-json")))
    }

    func testParseUsageAcceptsResetTimeWithoutFractionalSeconds() throws {
        let json = """
        {
            "command": {
                "name": "usage",
                "data": {
                    "groups": [
                        {
                            "name": "Gemini Models",
                            "buckets": [
                                {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.5, "reset_time": "2026-08-19T05:00:00Z"}
                            ]
                        }
                    ]
                }
            }
        }
        """
        let buckets = try XCTUnwrap(GeminiUsageCore.parseUsage(data(json)))
        XCTAssertNotNil(buckets.first?.resetsAt)
    }

    func testParseCreditsReadsRemainingCreditsAndIgnoresUpgradeURI() throws {
        let json = """
        {"command": {"name": "credits", "data": {"remaining_credits": 42, "upgrade_uri": "https://example.com/account/secret"}}}
        """
        XCTAssertEqual(GeminiUsageCore.parseCredits(data(json)), 42)
    }

    func testParseCreditsRejectsWrongCommandName() {
        let json = """
        {"command": {"name": "usage", "data": {"remaining_credits": 42}}}
        """
        XCTAssertNil(GeminiUsageCore.parseCredits(data(json)))
    }

    func testSharedPayloadIncludesWeeklyAndFiveHourRemainingPercentAndCredits() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = GeminiUsageSnapshot(
            weeklyRemainingFraction: 0.9996002912521362,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000),
            fiveHourRemainingFraction: 0.9976015090942383,
            fiveHourResetsAt: Date(timeIntervalSince1970: 1_500),
            creditBalance: 42,
            publishedAt: Date(timeIntervalSince1970: 900)
        )

        let payload = GeminiUsageCore.sharedPayload(from: snapshot, now: now)

        XCTAssertEqual(payload["status"] as? String, "ok")
        XCTAssertEqual((payload["weeklyRemainingPercent"] as? Double).map { round($0 * 100) / 100 }, 99.96)
        XCTAssertEqual((payload["fiveHourRemainingPercent"] as? Double).map { round($0 * 100) / 100 }, 99.76)
        XCTAssertEqual(payload["creditBalance"] as? Int, 42)
        XCTAssertEqual(payload["ageSeconds"] as? Int, 100)
        XCTAssertEqual(payload["fresh"] as? Bool, true)
        // The account-specific upgrade URI must never be persisted.
        XCTAssertNil(payload["upgradeURI"])
        XCTAssertNil(payload["upgrade_uri"])
    }

    func testSharedPayloadForMissingSnapshotIsExplicitlyUnavailable() {
        let payload = GeminiUsageCore.sharedPayload(from: nil)

        XCTAssertEqual(payload["status"] as? String, "unavailable")
        XCTAssertTrue(payload["weeklyRemainingPercent"] is NSNull)
        XCTAssertEqual(payload["fresh"] as? Bool, false)
    }

    func testSharedPayloadRoundTripsIntoRestartSnapshot() throws {
        let original = GeminiUsageSnapshot(
            weeklyRemainingFraction: 0.9,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000),
            fiveHourRemainingFraction: 0.5,
            fiveHourResetsAt: Date(timeIntervalSince1970: 1_500),
            creditBalance: 7,
            publishedAt: Date(timeIntervalSince1970: 1_000)
        )
        let payload = GeminiUsageCore.sharedPayload(from: original, now: Date(timeIntervalSince1970: 1_010))

        let restored = try XCTUnwrap(GeminiUsageCore.snapshot(fromSharedPayload: payload))

        XCTAssertEqual(restored.weeklyRemainingFraction ?? 0, original.weeklyRemainingFraction ?? 0, accuracy: 0.0001)
        XCTAssertEqual(restored.fiveHourRemainingFraction ?? 0, original.fiveHourRemainingFraction ?? 0, accuracy: 0.0001)
        XCTAssertEqual(restored.creditBalance, original.creditBalance)
        XCTAssertEqual(restored.publishedAt, original.publishedAt)
    }

    func testRestartSnapshotRejectsEmptySharedPayload() {
        XCTAssertNil(GeminiUsageCore.snapshot(fromSharedPayload: [:]))
    }

    func testRefreshedSharedPayloadRecalculatesFreshness() {
        let snapshot = GeminiUsageSnapshot(fiveHourRemainingFraction: 0.8, publishedAt: Date(timeIntervalSince1970: 1_000))
        let stored = GeminiUsageCore.sharedPayload(from: snapshot, now: Date(timeIntervalSince1970: 1_100))

        let refreshed = GeminiUsageCore.refreshedSharedPayload(stored, now: Date(timeIntervalSince1970: 1_500))

        XCTAssertEqual(refreshed["ageSeconds"] as? Int, 500)
        XCTAssertEqual(refreshed["fresh"] as? Bool, false)
    }

    func testShouldThrottleFetchRequiresTheHigherGeminiFloor() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(GeminiUsageCore.shouldThrottleFetch(
            minimumInterval: GeminiUsageCore.minimumRequestIntervalSeconds,
            lastFetchDate: Date(timeIntervalSince1970: 950),
            now: now
        ))
        XCTAssertFalse(GeminiUsageCore.shouldThrottleFetch(
            minimumInterval: GeminiUsageCore.minimumRequestIntervalSeconds,
            lastFetchDate: Date(timeIntervalSince1970: 850),
            now: now
        ))
        XCTAssertFalse(GeminiUsageCore.shouldThrottleFetch(minimumInterval: 120, lastFetchDate: nil, now: now))
    }
}

/// Fixtures mirror the sanitized backend output (`safeCcmbService` /
/// `usage.py --snapshot-json`): fixed service order, fixed provider and
/// account_ref, `window_minutes`, structured `{code,message}` errors.
enum NASSnapshotFixtures {
    static let codexItems = """
    [
        {"name": "codex", "window": "session", "window_minutes": 300, "remaining_percent": 90, "resets_at": 1792055000},
        {"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1792400000,
         "credits": {"balance": 12.5, "unlimited": false}}
    ]
    """
    static let claudeItems = """
    [
        {"name": "전체", "window": "session", "window_minutes": 300, "remaining_percent": 60, "resets_at": 1792055000},
        {"name": "전체", "window": "weekly", "window_minutes": 10080, "remaining_percent": 80, "resets_at": 1792400000},
        {"name": "fable", "window": "weekly", "window_minutes": 10080, "remaining_percent": 45, "resets_at": 1792400500}
    ]
    """
    static let geminiItems = """
    [
        {"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_percent": 80, "resets_at": 1792055000},
        {"name": "Gemini Models", "window": "weekly", "window_minutes": 10080, "remaining_percent": 90, "resets_at": 1792400000},
        {"name": "Claude and GPT models", "window": "session", "window_minutes": 300, "remaining_percent": 5, "resets_at": 1792055000},
        {"name": "Claude and GPT models", "window": "weekly", "window_minutes": 10080, "remaining_percent": 6, "resets_at": 1792400000}
    ]
    """
    static let gemini2Items = """
    [
        {"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_percent": 60, "resets_at": 1792055100},
        {"name": "Gemini Models", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1792400100}
    ]
    """

    static func service(
        _ id: String,
        provider: String,
        accountRef: String?,
        ok: Bool = true,
        stale: Bool = false,
        fetchedAt: String = "1792051100",
        items: String = "[]",
        error: String = "null"
    ) -> String {
        let ref = accountRef.map { "\"\($0)\"" } ?? "null"
        return """
        {"service": "\(id)", "provider": "\(provider)", "account_ref": \(ref), "ok": \(ok), "fetched_at": \(fetchedAt), "stale": \(stale), "items": \(items), "error": \(error)}
        """
    }

    static func codex(ok: Bool = true, items: String = codexItems, error: String = "null") -> String {
        service("codex", provider: "codex", accountRef: nil, ok: ok, items: items, error: error)
    }
    static func claude(ok: Bool = true, items: String = claudeItems, error: String = "null") -> String {
        service("claude", provider: "claude", accountRef: nil, ok: ok, items: items, error: error)
    }
    static func gemini(ok: Bool = true, items: String = geminiItems, error: String = "null") -> String {
        service("gemini", provider: "gemini", accountRef: "account1", ok: ok, items: items, error: error)
    }
    static func gemini2(ok: Bool = true, items: String = gemini2Items, error: String = "null") -> String {
        service("gemini2", provider: "gemini", accountRef: "account2", ok: ok, items: items, error: error)
    }

    static let notCollected = #"{"code": "not_collected", "message": "아직 수집된 값이 없습니다."}"#

    /// `executionHosts`/`autoSwitch` are raw JSON fragments; `nil` omits
    /// the key entirely (legacy NAS).
    static func envelope(
        services: [String],
        schemaVersion: String = "2",
        quotaOrigin: String = "\"nas\"",
        executionHosts: String? = "[]",
        autoSwitch: String? = "false"
    ) -> String {
        var optional = ""
        if let executionHosts { optional += ",\n    \"execution_hosts\": \(executionHosts)" }
        if let autoSwitch { optional += ",\n    \"auto_switch_enabled\": \(autoSwitch)" }
        return """
        {
            "schema_version": \(schemaVersion),
            "generated_at": 1792051200,
            "quota_origin": \(quotaOrigin),
            "collection": {"state": "idle", "job_id": null, "retry_at": null},
            "services": [\(services.joined(separator: ","))]\(optional)
        }
        """
    }

    static func host(
        id: String = "tm-mini",
        run: String = "\"run-42\"",
        account: String = "\"account1\"",
        phase: String = "\"running\"",
        changedAt: String = "1792051000",
        heartbeatAt: String = "1792051150",
        returnState: String = "null",
        extra: String = ""
    ) -> String {
        """
        {"host_id": "\(id)", "run_id": \(run), "execution_account": \(account), "phase": \(phase), \
        "state_changed_at": \(changedAt), "last_heartbeat_at": \(heartbeatAt), "return_state": \(returnState)\(extra)}
        """
    }

    /// Two different hosts on the two fixed accounts; the second has null
    /// times and a confirmed return.
    static let twoHosts = "[" + host() + "," + host(
        id: "api-worker",
        run: "null",
        account: "\"account2\"",
        phase: "\"returning\"",
        changedAt: "null",
        heartbeatAt: "null",
        returnState: "\"confirmed\""
    ) + "]"

    static let withHosts = envelope(services: [codex(), claude(), gemini(), gemini2()], executionHosts: twoHosts, autoSwitch: "true")

    static let valid = envelope(services: [codex(), claude(), gemini(), gemini2()])

    static func data(_ json: String) -> Data { Data(json.utf8) }

    static func parse(_ json: String) -> NASSnapshotV2? {
        NASSnapshotV2Core.parse(data(json))
    }
}

final class NASSnapshotV2CoreTests: XCTestCase {
    private typealias F = NASSnapshotFixtures

    func testParsesFourFixedServicesInOrder() throws {
        let snapshot = try XCTUnwrap(F.parse(F.valid))
        XCTAssertEqual(snapshot.entries.map(\.service), ["codex", "claude", "gemini", "gemini2"])
        XCTAssertEqual(snapshot.gemini.accountRef, "account1")
        XCTAssertEqual(snapshot.gemini2.accountRef, "account2")
        XCTAssertEqual(snapshot.gemini2.provider, "gemini")
        XCTAssertNil(snapshot.codex.accountRef)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 1792051200))
    }

    func testCodexWeeklyMapsToPrimaryWeeklyFieldsAndCredits() throws {
        let snapshot = try XCTUnwrap(F.parse(F.valid))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertEqual(codex.usedPercent ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(codex.windowDurationMinutes, 10080)
        XCTAssertEqual(codex.resetsAt, Date(timeIntervalSince1970: 1792400000))
        XCTAssertEqual(codex.creditBalance, 12.5)
        XCTAssertTrue(codex.detailedCreditsReturned)
        XCTAssertFalse(codex.creditsUnlimited)
        XCTAssertEqual(codex.updatedAt, Date(timeIntervalSince1970: 1792051100))
        // The session window is never folded into the Spark slots, and NAS
        // never borrows a local account ID.
        XCTAssertNil(codex.sparkUsedPercent)
        XCTAssertNil(codex.sparkResetsAt)
        XCTAssertNil(codex.accountID)
    }

    func testCodexUnlimitedCreditsAreCarried() throws {
        let items = """
        [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 0, "resets_at": null,
          "credits": {"balance": null, "unlimited": true}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertTrue(codex.creditsUnlimited)
        XCTAssertNil(codex.creditBalance)
        XCTAssertNil(codex.resetsAt)
    }

    func testCodexWithoutNamedWeeklyItemIsUnavailableNotFirstWindow() throws {
        let items = """
        [{"name": "codex", "window": "session", "window_minutes": 300, "remaining_percent": 50, "resets_at": null},
         {"name": "reserve", "window": "weekly", "window_minutes": 10080, "remaining_percent": 10, "resets_at": null}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        XCTAssertNil(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
    }

    func testCodexDetailsMapToPlanTypeAndResetCredits() throws {
        let items = """
        [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1792400000,
          "credits": {"balance": 12.5, "unlimited": false},
          "codex_details": {"plan_type": "plus", "reset_credits_available": 3}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertEqual(codex.planType, "plus")
        XCTAssertEqual(codex.resetCredits, 3)
    }

    /// Zero remaining reset vouchers is a real, distinct quantity from "not
    /// reported": it must round-trip as 0, not nil.
    func testCodexDetailsZeroResetCreditsStaysZeroNotNil() throws {
        let items = """
        [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1792400000,
          "credits": {"balance": 12.5, "unlimited": false},
          "codex_details": {"plan_type": "pro", "reset_credits_available": 0}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertEqual(codex.resetCredits, 0)
    }

    /// An unrecognized future `plan_type` is hidden rather than guessed, and
    /// a non-integer `reset_credits_available` is dropped — but neither
    /// malformed field may erase the already-healthy weekly quota/credits.
    func testCodexDetailsUnknownPlanAndNonIntegerResetCreditsAreHiddenWithoutErasingQuota() throws {
        let items = """
        [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1792400000,
          "credits": {"balance": 12.5, "unlimited": false},
          "codex_details": {"plan_type": "some_future_plan", "reset_credits_available": 2.5}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertNil(codex.planType)
        XCTAssertNil(codex.resetCredits)
        XCTAssertEqual(codex.usedPercent ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(codex.creditBalance, 12.5)
    }

    /// A boolean or string `reset_credits_available` is neither a valid
    /// count nor silently coerced — it is dropped, and the surrounding
    /// weekly quota/credits remain untouched.
    func testCodexDetailsBoolOrStringResetCreditsDroppedWithoutErasingQuota() throws {
        for malformed in ["true", "\"3\""] {
            let items = """
            [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1792400000,
              "credits": {"balance": 12.5, "unlimited": false},
              "codex_details": {"plan_type": "plus", "reset_credits_available": \(malformed)}}]
            """
            let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
            let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
            XCTAssertEqual(codex.planType, "plus")
            XCTAssertNil(codex.resetCredits)
            XCTAssertEqual(codex.usedPercent ?? -1, 30, accuracy: 0.0001)
            XCTAssertEqual(codex.creditBalance, 12.5)
        }
    }

    /// Missing `codex_details` (old NAS payload, pre-regression-fix) keeps
    /// mapping succeeding with both fields nil, never dropping the item.
    func testCodexWithoutDetailsFieldKeepsPlanAndResetCreditsNil() throws {
        let snapshot = try XCTUnwrap(F.parse(F.valid))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertNil(codex.planType)
        XCTAssertNil(codex.resetCredits)
    }

    func testClaudeOverallAndFableMapSeparately() throws {
        let snapshot = try XCTUnwrap(F.parse(F.valid))
        let claude = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: snapshot.claude))
        XCTAssertEqual(claude.fiveHourUsedPercent ?? -1, 40, accuracy: 0.0001)
        XCTAssertEqual(claude.weeklyUsedPercent ?? -1, 20, accuracy: 0.0001)
        let fable = try XCTUnwrap(ClaudeUsageCore.fableWeeklyLimit(in: claude.modelWeeklyLimits))
        XCTAssertEqual(fable.usedPercent ?? -1, 55, accuracy: 0.0001)
        XCTAssertEqual(fable.resetsAt, Date(timeIntervalSince1970: 1792400500))
        XCTAssertEqual(claude.quotaSource, "nas")
    }

    func testClaudeDetailsMapKnownPlanAndExtraUsage() throws {
        let items = """
        [{"name": "전체", "window": "session", "window_minutes": 300, "remaining_percent": 60, "resets_at": null},
         {"name": "전체", "window": "weekly", "window_minutes": 10080, "remaining_percent": 80, "resets_at": null,
          "claude_details": {"plan_type": "max_20x",
            "extra_usage": {"is_enabled": true, "monthly_limit_minor": 5000, "used_minor": 1250,
                             "utilization": 25, "currency": "USD", "decimal_places": 2}}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(items: items), F.gemini(), F.gemini2()])))
        let claude = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: snapshot.claude))
        XCTAssertEqual(claude.planTitle, "Claude Max 20×")
        let extraUsage = try XCTUnwrap(claude.extraUsage)
        XCTAssertEqual(extraUsage.isEnabled, true)
        XCTAssertEqual(extraUsage.limitCents, 5000)
        XCTAssertEqual(extraUsage.usedCents, 1250)
        XCTAssertEqual(extraUsage.currency, "USD")
    }

    /// `is_enabled: false` is a distinct, known "disabled" state: it must
    /// round-trip as `false`, not `nil`, and never carries fake monetary
    /// values.
    func testClaudeExtraUsageDisabledStaysFalseWithNilMonetary() throws {
        let items = """
        [{"name": "전체", "window": "weekly", "window_minutes": 10080, "remaining_percent": 80, "resets_at": null,
          "claude_details": {"plan_type": "pro",
            "extra_usage": {"is_enabled": false, "monthly_limit_minor": null, "used_minor": null,
                             "utilization": null, "currency": null, "decimal_places": null}}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(items: items), F.gemini(), F.gemini2()])))
        let claude = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: snapshot.claude))
        let extraUsage = try XCTUnwrap(claude.extraUsage)
        XCTAssertEqual(extraUsage.isEnabled, false)
        XCTAssertNil(extraUsage.limitCents)
        XCTAssertNil(extraUsage.usedCents)
    }

    /// Unknown units must never be divided by 100 and labeled as dollars.
    func testClaudeExtraUsageForeignCurrencyOrExponentNeverPretendsUSD() throws {
        for details in [
            #"{"is_enabled": true, "monthly_limit_minor": 5000, "used_minor": 1250, "currency": "EUR", "decimal_places": 2}"#,
            #"{"is_enabled": true, "monthly_limit_minor": 5000, "used_minor": 1250, "currency": "USD", "decimal_places": null}"#,
            #"{"is_enabled": true, "monthly_limit_minor": 5000, "used_minor": 1250}"#,
        ] {
            let items = """
            [{"name": "전체", "window": "weekly", "window_minutes": 10080, "remaining_percent": 80, "resets_at": null,
              "claude_details": {"plan_type": "pro", "extra_usage": \(details)}}]
            """
            let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(items: items), F.gemini(), F.gemini2()])), details)
            let claude = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: snapshot.claude), details)
            let extraUsage = try XCTUnwrap(claude.extraUsage, details)
            XCTAssertNil(extraUsage.limitCents, details)
            XCTAssertNil(extraUsage.usedCents, details)
            XCTAssertEqual(extraUsage.isEnabled, true, details)
        }
    }

    func testClaudeExtraUsageKnownExponentsConvertToCents() throws {
        for (places, expected) in [(0, 125000.0), (3, 125.0), (6, 0.125)] {
            let extra = NASClaudeExtraUsage(isEnabled: true, monthlyLimitMinor: nil, usedMinor: 1250,
                utilization: nil, currency: "USD", decimalPlaces: places)
            let result = try XCTUnwrap(NASItemMappingCore.claudeExtraUsage(from: extra))
            XCTAssertEqual(try XCTUnwrap(result.usedCents), expected, accuracy: 0.000001)
        }
    }

    /// An unrecognized future `plan_type` is hidden rather than guessed, and
    /// a malformed `extra_usage` sub-field is simply dropped — neither may
    /// erase the already-healthy weekly quota carried by the rest of the
    /// item (mirrors the existing `codex_details` contract).
    func testClaudeDetailsUnknownPlanAndMalformedExtraUsageAreHiddenWithoutErasingQuota() throws {
        let items = """
        [{"name": "전체", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": null,
          "claude_details": {"plan_type": "some_future_plan",
            "extra_usage": {"is_enabled": "yes", "monthly_limit_minor": -5, "used_minor": "1250",
                             "utilization": 150, "currency": "US Dollar", "decimal_places": 9}}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(items: items), F.gemini(), F.gemini2()])))
        let claude = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: snapshot.claude))
        XCTAssertNil(claude.planTitle)
        XCTAssertNil(claude.extraUsage)
        XCTAssertEqual(claude.weeklyUsedPercent ?? -1, 30, accuracy: 0.0001)
    }

    /// Missing `claude_details` (old NAS payload) keeps mapping succeeding
    /// with both fields nil, never dropping the item.
    func testClaudeWithoutDetailsFieldKeepsPlanTitleAndExtraUsageNil() throws {
        let snapshot = try XCTUnwrap(F.parse(F.valid))
        let claude = try XCTUnwrap(NASItemMappingCore.claudeSnapshot(from: snapshot.claude))
        XCTAssertNil(claude.planTitle)
        XCTAssertNil(claude.extraUsage)
    }

    /// A `claude_details`/`extra_usage` object on a *non*-Claude service
    /// (e.g. Codex) is never read — `allowsClaudeDetails` is Claude-only.
    func testClaudeDetailsAreIgnoredOnNonClaudeServices() throws {
        let items = """
        [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": null,
          "claude_details": {"plan_type": "max_20x", "extra_usage": {"is_enabled": true}}}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        let codex = try XCTUnwrap(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertEqual(codex.usedPercent ?? -1, 30, accuracy: 0.0001)
    }

    /// `ClaudeUsageSnapshot.sharedPayload`/`snapshot(fromSharedPayload:)`
    /// round-trip `planTitle` and `extraUsage.isEnabled` without altering
    /// any other field.
    func testClaudePlanTitleAndExtraUsageIsEnabledSurviveSharedPayloadRoundTrip() throws {
        let snapshot = ClaudeUsageSnapshot(
            quotaSource: "nas",
            weeklyUsedPercent: 20,
            publishedAt: Date(timeIntervalSince1970: 1_792_400_000),
            extraUsage: ClaudeExtraUsage(limitCents: 5000, usedCents: 1250, currency: "USD", isEnabled: true),
            planTitle: "Claude Max 20×"
        )
        let payload = ClaudeUsageCore.sharedPayload(from: snapshot)
        let restored = try XCTUnwrap(ClaudeUsageCore.snapshot(fromSharedPayload: payload))
        XCTAssertEqual(restored.planTitle, "Claude Max 20×")
        XCTAssertEqual(restored.extraUsage?.isEnabled, true)
        XCTAssertEqual(restored.extraUsage?.limitCents, 5000)
    }

    func testGeminiReadsOnlyGeminiModelsAndAccountsStayFixed() throws {
        let snapshot = try XCTUnwrap(F.parse(F.valid))
        let account1 = try XCTUnwrap(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini))
        let account2 = try XCTUnwrap(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini2))
        // The "Claude and GPT models" pool (5%/6%) is never read.
        XCTAssertEqual(account1.fiveHourRemainingFraction ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(account1.weeklyRemainingFraction ?? -1, 0.9, accuracy: 0.0001)
        XCTAssertEqual(account2.fiveHourRemainingFraction ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(account2.weeklyRemainingFraction ?? -1, 0.7, accuracy: 0.0001)
        XCTAssertNil(account1.accountEmail)
        XCTAssertNil(account2.accountEmail)
    }

    func testDuplicateGeminiWindowIsUnknownRatherThanFirstMatch() throws {
        let items = """
        [{"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_percent": 80, "resets_at": null},
         {"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_percent": 20, "resets_at": null},
         {"name": "Gemini Models", "window": "weekly", "window_minutes": 10080, "remaining_percent": 90, "resets_at": null}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini(items: items), F.gemini2()])))
        let account1 = try XCTUnwrap(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini))
        XCTAssertNil(account1.fiveHourRemainingFraction)
        XCTAssertEqual(account1.weeklyRemainingFraction ?? -1, 0.9, accuracy: 0.0001)
    }

    func testRemainingFractionIsPreferredAndStrict() throws {
        let fractionItems = """
        [{"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_fraction": 0.25, "resets_at": null}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini(items: fractionItems), F.gemini2()])))
        let account1 = try XCTUnwrap(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini))
        XCTAssertEqual(account1.fiveHourRemainingFraction ?? -1, 0.25, accuracy: 0.0001)

        for bad in ["1.5", "-0.1", "true", "\"0.5\""] {
            let items = """
            [{"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_fraction": \(bad), "resets_at": null}]
            """
            let parsed = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini(items: items), F.gemini2()])))
            XCTAssertEqual(parsed.gemini.error?.code, "schema_changed", bad)
            XCTAssertNil(NASItemMappingCore.geminiSnapshot(from: parsed.gemini), bad)
        }
    }

    func testOneServiceContentErrorNeverHidesTheOthers() throws {
        let badItems = """
        [{"name": "Gemini Models", "window": "session", "window_minutes": 300, "remaining_percent": 120, "resets_at": null}]
        """
        let snapshot = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini(), F.gemini2(items: badItems)])))
        XCTAssertFalse(snapshot.gemini2.ok)
        XCTAssertEqual(snapshot.gemini2.error?.code, "schema_changed")
        XCTAssertNotNil(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini))
        XCTAssertNotNil(NASItemMappingCore.codexSnapshot(from: snapshot.codex))
        XCTAssertNotNil(NASItemMappingCore.claudeSnapshot(from: snapshot.claude))
    }

    func testStructuredErrorIsParsedAsFields() throws {
        let unavailable = F.envelope(services: [
            F.codex(ok: false, items: "[]", error: F.notCollected),
            F.claude(),
            F.gemini(),
            F.gemini2(ok: false, items: "[]", error: #"{"code": "login_required", "message": null}"#),
        ])
        let snapshot = try XCTUnwrap(F.parse(unavailable))
        XCTAssertEqual(snapshot.codex.error, NASServiceError(code: "not_collected", message: "아직 수집된 값이 없습니다."))
        XCTAssertEqual(snapshot.gemini2.error?.code, "login_required")
        XCTAssertNil(snapshot.gemini2.error?.message)
        XCTAssertEqual(snapshot.gemini2.error?.label, "NAS 쪽 다시 로그인 필요")
        XCTAssertEqual(NASServiceError(code: "brand_new", message: nil).label, "NAS 오류(brand_new)")

        // A plain-string error is not the contract: that service becomes a
        // schema error rather than showing the string.
        let stringError = F.envelope(services: [F.codex(ok: false, items: "[]", error: "\"boom\""), F.claude(), F.gemini(), F.gemini2()])
        XCTAssertEqual(try XCTUnwrap(F.parse(stringError)).codex.error?.code, "schema_changed")
    }

    func testOkWithoutItemsOrWithErrorIsSchemaInvalid() throws {
        let emptyOk = F.envelope(services: [F.codex(items: "[]"), F.claude(), F.gemini(), F.gemini2()])
        XCTAssertEqual(try XCTUnwrap(F.parse(emptyOk)).codex.error?.code, "schema_changed")
        let okWithError = F.envelope(services: [F.codex(error: F.notCollected), F.claude(), F.gemini(), F.gemini2()])
        XCTAssertEqual(try XCTUnwrap(F.parse(okWithError)).codex.error?.code, "schema_changed")
    }

    func testTimestampsMustBePositiveFiniteNonBool() throws {
        for bad in ["true", "-5", "0", "\"1792051100\""] {
            let service = F.service("codex", provider: "codex", accountRef: nil, fetchedAt: bad, items: F.codexItems)
            let parsed = try XCTUnwrap(F.parse(F.envelope(services: [service, F.claude(), F.gemini(), F.gemini2()])))
            XCTAssertEqual(parsed.codex.error?.code, "schema_changed", bad)
        }
        let boolReset = """
        [{"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": true}]
        """
        let parsed = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: boolReset), F.claude(), F.gemini(), F.gemini2()])))
        XCTAssertEqual(parsed.codex.error?.code, "schema_changed")
    }

    func testWindowMinutesMustMatchWindow() throws {
        let items = """
        [{"name": "codex", "window": "weekly", "window_minutes": 300, "remaining_percent": 70, "resets_at": null}]
        """
        let parsed = try XCTUnwrap(F.parse(F.envelope(services: [F.codex(items: items), F.claude(), F.gemini(), F.gemini2()])))
        XCTAssertEqual(parsed.codex.error?.code, "schema_changed")
    }

    func testRejectsUnknownOrNonIntegerSchemaVersion() {
        for version in ["3", "1", "2.5", "true", "\"2\"", "null"] {
            XCTAssertNil(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini(), F.gemini2()], schemaVersion: version)), version)
        }
    }

    func testRejectsNonNASOriginAndLegacyShapes() {
        XCTAssertNil(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini(), F.gemini2()], quotaOrigin: "\"local\"")))
        XCTAssertNil(F.parse(#"{"report":{"services":[]}}"#))
        XCTAssertNil(F.parse("not-json"))
    }

    func testRejectsMissingDuplicateExtraOrReorderedServices() {
        XCTAssertNil(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini()])))
        XCTAssertNil(F.parse(F.envelope(services: [F.codex(), F.codex(), F.gemini(), F.gemini2()])))
        XCTAssertNil(F.parse(F.envelope(services: [
            F.codex(), F.claude(), F.gemini(), F.gemini2(),
            F.service("grok", provider: "grok", accountRef: nil),
        ])))
        XCTAssertNil(F.parse(F.envelope(services: [F.codex(), F.claude(), F.gemini2(), F.gemini()])))
    }

    func testRejectsWrongIdentityPairing() {
        let swappedAccount = F.service("gemini", provider: "gemini", accountRef: "account2", items: F.geminiItems)
        XCTAssertNil(F.parse(F.envelope(services: [F.codex(), F.claude(), swappedAccount, F.gemini2()])))
        let wrongProvider = F.service("codex", provider: "claude", accountRef: nil, items: F.codexItems)
        XCTAssertNil(F.parse(F.envelope(services: [wrongProvider, F.claude(), F.gemini(), F.gemini2()])))
        let codexWithAccount = F.service("codex", provider: "codex", accountRef: "account1", items: F.codexItems)
        XCTAssertNil(F.parse(F.envelope(services: [codexWithAccount, F.claude(), F.gemini(), F.gemini2()])))
    }
}

final class NASFourServiceStateTests: XCTestCase {
    private typealias F = NASSnapshotFixtures

    func testFreshSnapshotFillsAllFourSlotsIndependently() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        XCTAssertNotNil(state.codexSnapshot)
        XCTAssertNotNil(state.claudeSnapshot)
        XCTAssertEqual(state.geminiSnapshot?.fiveHourRemainingFraction ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(state.gemini2Snapshot?.fiveHourRemainingFraction ?? -1, 0.6, accuracy: 0.0001)
        for id in NASServiceID.allCases {
            XCTAssertNil(state.slot(id).issue)
            XCTAssertFalse(state.slot(id).isStale)
        }
    }

    func testServiceFailureKeepsThatSlotsLastGoodValueAndUpdatesOthers() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        let laterItems = F.geminiItems.replacingOccurrences(of: "\"remaining_percent\": 80", with: "\"remaining_percent\": 55")
        let later = F.envelope(services: [
            F.codex(),
            F.claude(),
            F.gemini(items: laterItems),
            F.gemini2(ok: false, items: "[]", error: F.notCollected),
        ])
        state.apply(try XCTUnwrap(F.parse(later)))
        XCTAssertEqual(state.geminiSnapshot?.fiveHourRemainingFraction ?? -1, 0.55, accuracy: 0.0001)
        // account2 keeps its own last value, marked stale with its own issue.
        XCTAssertEqual(state.gemini2Snapshot?.fiveHourRemainingFraction ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertTrue(state.slot(.gemini2).isStale)
        XCTAssertEqual(state.slot(.gemini2).issue, "NAS 미수집")
        XCTAssertNil(state.slot(.gemini).issue)
    }

    func testAccountTwoNeverBorrowsAccountOneValues() throws {
        var state = NASFourServiceState()
        let snapshot = F.envelope(services: [F.codex(), F.claude(), F.gemini(), F.gemini2(ok: false, items: "[]", error: F.notCollected)])
        state.apply(try XCTUnwrap(F.parse(snapshot)))
        XCTAssertNotNil(state.geminiSnapshot)
        XCTAssertNil(state.gemini2Snapshot)
        XCTAssertEqual(state.slot(.gemini2).issue, "NAS 미수집")
    }

    func testTransportFailureKeepsEveryValueAndMarksStale() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        let before = state.codexSnapshot?.usedPercent
        state.applyFailure(label: NASFetchError.timeout.label)
        XCTAssertEqual(state.codexSnapshot?.usedPercent, before)
        XCTAssertNotNil(state.gemini2Snapshot)
        for id in NASServiceID.allCases {
            XCTAssertTrue(state.slot(id).isStale)
            XCTAssertEqual(state.slot(id).issue, "NAS 응답 시간 초과")
        }
    }

    func testCacheRoundTripRestoresValuesAsStale() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        let data = try XCTUnwrap(state.encodedCache())
        let restored = try XCTUnwrap(NASFourServiceState.decodeCache(data))
        XCTAssertEqual(restored.codexSnapshot?.usedPercent ?? -1, 30, accuracy: 0.0001)
        XCTAssertEqual(restored.codexSnapshot?.creditBalance, 12.5)
        XCTAssertEqual(restored.claudeSnapshot?.weeklyUsedPercent ?? -1, 20, accuracy: 0.0001)
        XCTAssertEqual(restored.geminiSnapshot?.fiveHourRemainingFraction ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(restored.gemini2Snapshot?.fiveHourRemainingFraction ?? -1, 0.6, accuracy: 0.0001)
        for id in NASServiceID.allCases {
            XCTAssertTrue(restored.slot(id).isStale)
        }
    }

    func testCacheRejectsUnknownVersionOrSource() {
        XCTAssertNil(NASFourServiceState.decodeCache(Data(#"{"version": 2, "source": "nas", "services": {}}"#.utf8)))
        XCTAssertNil(NASFourServiceState.decodeCache(Data(#"{"version": 1, "source": "local", "services": {}}"#.utf8)))
        XCTAssertNil(NASFourServiceState.decodeCache(Data("garbage".utf8)))
    }

    /// The single visible Gemini card always picks account1 unless the
    /// `"nas"` execution host itself is reported as actually running on
    /// account2 with switching enabled — it is never guessed from quota
    /// values, from a non-`"nas"` host (e.g. a Mac), or from a `return_state`
    /// (which marks the primary's own confirmed return, not a secondary
    /// selection).
    func testSelectedGeminiServiceIDNeverGuessedFromQuota() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        XCTAssertEqual(state.selectedGeminiServiceID, .gemini)
        XCTAssertEqual(state.selectedGeminiSnapshot?.fiveHourRemainingFraction, state.geminiSnapshot?.fiveHourRemainingFraction)

        // Switching disabled: always account1, even with hosts present.
        let disabledButHosted = F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: F.twoHosts,
            autoSwitch: "false"
        )
        var disabledState = NASFourServiceState()
        disabledState.apply(try XCTUnwrap(F.parse(disabledButHosted)))
        XCTAssertEqual(disabledState.selectedGeminiServiceID, .gemini)

        // Switching enabled and a non-"nas" host (e.g. a Mac) is running on
        // account2: that host carries no selection weight, so the card
        // stays on the primary.
        let macRunningAccount2 = F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: "[" + F.host(id: "tm-mini", account: "\"account2\"", phase: "\"running\"") + "]",
            autoSwitch: "true"
        )
        var macRunningState = NASFourServiceState()
        macRunningState.apply(try XCTUnwrap(F.parse(macRunningAccount2)))
        XCTAssertEqual(macRunningState.selectedGeminiServiceID, .gemini)

        // Switching enabled and the "nas" host itself is actually running
        // on account2.
        let nasRunningAccount2 = F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: "[" + F.host(id: "nas", account: "\"account2\"", phase: "\"running\"") + "]",
            autoSwitch: "true"
        )
        var runningState = NASFourServiceState()
        runningState.apply(try XCTUnwrap(F.parse(nasRunningAccount2)))
        XCTAssertEqual(runningState.selectedGeminiServiceID, .gemini2)
        XCTAssertEqual(runningState.selectedGeminiSnapshot?.fiveHourRemainingFraction, runningState.gemini2Snapshot?.fiveHourRemainingFraction)

        // Switching enabled, the "nas" host is not running (merely
        // returning) but reports a confirmed return: that field marks the
        // primary's own confirmed return, never a remembered secondary
        // selection, so the card falls back to the primary.
        let nasReturningAccount2 = F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: "[" + F.host(
                id: "nas",
                account: "\"account2\"",
                phase: "\"returning\"",
                returnState: "\"confirmed\""
            ) + "]",
            autoSwitch: "true"
        )
        var confirmedState = NASFourServiceState()
        confirmedState.apply(try XCTUnwrap(F.parse(nasReturningAccount2)))
        XCTAssertEqual(confirmedState.selectedGeminiServiceID, .gemini)

        // Switching enabled, no hosts at all: falls back to the primary.
        let idleEnabled = F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: "[]",
            autoSwitch: "true"
        )
        var idleState = NASFourServiceState()
        idleState.apply(try XCTUnwrap(F.parse(idleEnabled)))
        XCTAssertEqual(idleState.selectedGeminiServiceID, .gemini)
    }
}

final class NASHostStatusTests: XCTestCase {
    private typealias F = NASSnapshotFixtures
    private let now = Date(timeIntervalSince1970: 1792051200)

    func testParsesTwoHostObjectsOnFixedAccountsWithNullTimes() throws {
        let snapshot = try XCTUnwrap(F.parse(F.withHosts))
        let status = snapshot.hostStatus
        XCTAssertEqual(status.autoSwitchEnabled, true)
        XCTAssertEqual(status.hosts.count, 2)
        let first = try XCTUnwrap(status.hosts(for: .gemini).first)
        XCTAssertEqual(first.hostID, "tm-mini")
        XCTAssertEqual(first.runID, "run-42")
        XCTAssertEqual(first.phase, "running")
        XCTAssertEqual(first.stateChangedAt, Date(timeIntervalSince1970: 1792051000))
        XCTAssertEqual(first.lastHeartbeatAt, Date(timeIntervalSince1970: 1792051150))
        XCTAssertNil(first.returnState)
        let second = try XCTUnwrap(status.hosts(for: .gemini2).first)
        XCTAssertEqual(second.hostID, "api-worker")
        XCTAssertNil(second.runID)
        XCTAssertNil(second.stateChangedAt)
        XCTAssertNil(second.lastHeartbeatAt)
        XCTAssertEqual(second.returnState, "confirmed")
        // Quota cards are unaffected by host metadata.
        XCTAssertNotNil(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini))
        XCTAssertNotNil(NASItemMappingCore.geminiSnapshot(from: snapshot.gemini2))
    }

    func testMalformedHostsAreDroppedWithoutRejectingQuotaCards() throws {
        let malformed = [
            "\"tm-mini\"",                                              // string, not object
            F.host(account: "\"account3\""),                             // unknown account
            F.host(account: "null"),                                     // missing account
            F.host(id: "user@example.com"),                              // email-like id
            F.host(id: "/volume1/worker"),                               // path-like id
            F.host(run: "\"run 1\""),                                    // unsafe run id
            F.host(phase: "\"Running Now\""),                            // unsafe phase
            F.host(phase: "{\"x\": 1}"),                                  // object, never stringified
            F.host(changedAt: "true"),                                   // bool timestamp
            F.host(heartbeatAt: "0"),                                    // non-positive
            F.host(heartbeatAt: "-5"),
            F.host(heartbeatAt: "\"1792051150\""),                       // string timestamp
            F.host(returnState: "42"),
        ]
        let hosts = "[" + (malformed + [F.host(id: "ok-host", extra: #", "binding": {"email": "a@b.c"}, "worker_path": "/x""#)])
            .joined(separator: ",") + "]"
        let snapshot = try XCTUnwrap(F.parse(F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: hosts,
            autoSwitch: "true"
        )))
        XCTAssertEqual(snapshot.hostStatus.hosts.map(\.hostID), ["ok-host"])
        XCTAssertEqual(snapshot.entries.filter(\.ok).count, 4)
    }

    func testNonArrayHostsAndNonBoolAutoSwitchDoNotRejectEnvelope() throws {
        let snapshot = try XCTUnwrap(F.parse(F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: #"{"host_id": "tm-mini"}"#,
            autoSwitch: "1"
        )))
        XCTAssertEqual(snapshot.hostStatus.hosts, [])
        XCTAssertNil(snapshot.hostStatus.autoSwitchEnabled)
        XCTAssertEqual(snapshot.entries.filter(\.ok).count, 4)
    }

    func testAutoSwitchReflectsActualServerValue() throws {
        let services = [F.codex(), F.claude(), F.gemini(), F.gemini2()]
        XCTAssertEqual(try XCTUnwrap(F.parse(F.envelope(services: services, autoSwitch: "true"))).hostStatus.autoSwitchEnabled, true)
        XCTAssertEqual(try XCTUnwrap(F.parse(F.envelope(services: services, autoSwitch: "false"))).hostStatus.autoSwitchEnabled, false)
        XCTAssertNil(try XCTUnwrap(F.parse(F.envelope(services: services, autoSwitch: nil))).hostStatus.autoSwitchEnabled)
        XCTAssertNil(try XCTUnwrap(F.parse(F.envelope(services: services, autoSwitch: "null"))).hostStatus.autoSwitchEnabled)
    }

    func testLegacyEnvelopeWithoutHostKeysOrWithEmptyArrayIsCompatible() throws {
        let services = [F.codex(), F.claude(), F.gemini(), F.gemini2()]
        let legacy = try XCTUnwrap(F.parse(F.envelope(services: services, executionHosts: nil, autoSwitch: nil)))
        XCTAssertEqual(legacy.hostStatus, NASHostStatus(hosts: [], autoSwitchEnabled: nil))
        let empty = try XCTUnwrap(F.parse(F.valid))
        XCTAssertEqual(empty.hostStatus, NASHostStatus(hosts: [], autoSwitchEnabled: false))
        XCTAssertEqual(empty.entries.filter(\.ok).count, 4)
    }

    func testStateCarriesHostStatusIndependentlyAndThroughFailure() throws {
        var state = NASFourServiceState()
        XCTAssertNil(state.hostStatus)
        state.apply(try XCTUnwrap(F.parse(F.withHosts)))
        XCTAssertEqual(state.hostStatus?.hosts.count, 2)
        XCTAssertFalse(state.hostStatusIsStale)
        state.applyFailure(label: NASFetchError.timeout.label)
        XCTAssertEqual(state.hostStatus?.hosts.count, 2)
        XCTAssertTrue(state.hostStatusIsStale)
        // Per-service freshness stays its own.
        XCTAssertEqual(state.slot(.gemini).issue, "NAS 응답 시간 초과")
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        XCTAssertEqual(state.hostStatus, NASHostStatus(hosts: [], autoSwitchEnabled: false))
        XCTAssertFalse(state.hostStatusIsStale)
    }

    func testCacheRoundTripRestoresHostStatusAsStale() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.withHosts)))
        let restored = try XCTUnwrap(NASFourServiceState.decodeCache(try XCTUnwrap(state.encodedCache())))
        XCTAssertEqual(restored.hostStatus, state.hostStatus)
        XCTAssertTrue(restored.hostStatusIsStale)
        XCTAssertNotNil(restored.gemini2Snapshot)
    }

    func testOldCacheWithoutHostStatusStillRestores() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.valid)))
        let data = try XCTUnwrap(state.encodedCache())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root.removeValue(forKey: "host_status")
        let restored = try XCTUnwrap(NASFourServiceState.decodeCache(JSONSerialization.data(withJSONObject: root)))
        XCTAssertNil(restored.hostStatus)
        XCTAssertNotNil(restored.geminiSnapshot)
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .gemini, state: restored, source: .nas), [])
    }

    /// Only a running host on the *other* fixed account is decision-relevant
    /// enough to surface on a card; everything else (phase, heartbeat,
    /// return confirmation, auto-switch, staleness) is diagnostics-only and
    /// must not appear in this compact, single-line footer.
    func testFooterLinesForBothFixedGeminiCards() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.withHosts)))
        // `twoHosts` runs the account1 host; the account1 card never
        // reports on itself, but the idle account2 card names it.
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas), [])
        XCTAssertEqual(
            NASHostStatusPresentation.footerLines(for: .gemini2, state: state, source: .nas),
            []
        )
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .codex, state: state, source: .nas), [])
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .claude, state: state, source: .nas), [])
    }

    func testFooterDoesNotShowOtherAccountEvenWhileRunning() throws {
        let services = [F.codex(), F.claude(), F.gemini(), F.gemini2()]
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.envelope(services: services, executionHosts: nil, autoSwitch: nil))))
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas), [])
        state.apply(try XCTUnwrap(F.parse(F.envelope(services: services, executionHosts: "[" + F.host(account: "\"account2\"") + "]"))))
        XCTAssertEqual(
            NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas),
            []
        )
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .gemini2, state: state, source: .nas), [])
    }

    func testLocalMacSourceShowsNoNASHostState() throws {
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.withHosts)))
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .localMac), [])
        XCTAssertEqual(NASHostStatusPresentation.footerLines(for: .gemini2, state: state, source: .localMac), [])
    }

    /// A shared idle host (no `execution_account`) never names a running
    /// account, so it must never produce a footer line on either card.
    func testIdleCommonHostDoesNotDuplicateStaleHeartbeatOrNonMeaningfulReturn() throws {
        let idleCommonHosts = "[" + F.host(
            id: "shared-idle-1", run: "null", account: "null", phase: "\"idle\"",
            changedAt: "1792050000", heartbeatAt: "1792050240", returnState: "\"not_required\""
        ) + "," + F.host(
            id: "shared-idle-2", run: "null", account: "null", phase: "\"idle\"",
            changedAt: "1792050000", heartbeatAt: "1792050240", returnState: "\"not_required\""
        ) + "]"
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: idleCommonHosts,
            autoSwitch: "true"
        ))))
        for id: NASServiceID in [.gemini, .gemini2] {
            XCTAssertEqual(NASHostStatusPresentation.footerLines(for: id, state: state, source: .nas), [])
        }
    }

    /// The compact footer never repeats a host identifier, so it can never
    /// leak a sanitized-away field either.
    func testFooterRendersOnlySanitizedFields() throws {
        let hosts = "[" + F.host(
            id: "a-very-long-host-identifier-name",
            account: "\"account2\"",
            extra: #", "binding": {"email": "secret@example.com"}, "worker_path": "/volume1/secret""#
        ) + "]"
        var state = NASFourServiceState()
        state.apply(try XCTUnwrap(F.parse(F.envelope(
            services: [F.codex(), F.claude(), F.gemini(), F.gemini2()],
            executionHosts: hosts,
            autoSwitch: "true"
        ))))
        let lines = NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas)
        XCTAssertEqual(lines, [])
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains("@"))
        XCTAssertFalse(joined.contains("/"))
        XCTAssertFalse(joined.contains("{"))
        let cache = String(decoding: try XCTUnwrap(state.encodedCache()), as: UTF8.self)
        XCTAssertFalse(cache.contains("secret"))
    }
}

final class NASHistoryV2CoreTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    private static func point(at: String = "1792051200000", consumed: String = "12.5", unit: String = "percent", segment: String = "a1b2c3d4e5f60718") -> String {
        "{\"at\": \(at), \"consumed\": \(consumed), \"unit\": \"\(unit)\", \"segmentId\": \"\(segment)\"}"
    }

    private static func series(identityGeneration: String = "null", points: [String] = []) -> String {
        "{\"identityGeneration\": \(identityGeneration), \"points\": [\(points.joined(separator: ","))]}"
    }

    private static func envelope(
        overrides: [String: String] = [:],
        schemaVersion: String = "2",
        generatedAt: String = "1792051200000",
        extraRoot: String = "",
        ok: String? = "true"
    ) -> String {
        var objects: [String: String] = [
            "codex": series(points: [point()]),
            "codexCredits": series(points: [point(consumed: "3", unit: "credits")]),
            "claude": series(points: [point()]),
            "claudeFable": series(),
            "gemini": series(identityGeneration: "\"gen-1\"", points: [point()]),
            "gemini2": series(identityGeneration: "\"gen-7\"", points: [point(consumed: "4")]),
        ]
        for (key, value) in overrides { objects[key] = value }
        let body = objects.keys.sorted().map { "\"\($0)\": \(objects[$0]!)" }.joined(separator: ",")
        let okField = ok.map { "\"ok\": \($0), " } ?? ""
        return """
        {\(okField)"schemaVersion": \(schemaVersion), "generatedAt": \(generatedAt), "source": "nas", "series": {\(body)}\(extraRoot)}
        """
    }

    func testParsesHelperOutputWithSixFixedSeriesAndUnits() throws {
        let history = try XCTUnwrap(NASHistoryV2Core.parse(data(Self.envelope())))
        XCTAssertEqual(Set(history.series.keys), Set(NASHistoryV2.seriesKeys))
        XCTAssertEqual(history.series["codexCredits"]?.points.first?.unit, .credits)
        XCTAssertEqual(history.series["codex"]?.points.first?.unit, .percent)
        XCTAssertEqual(history.series["gemini"]?.identityGeneration, "gen-1")
        XCTAssertEqual(history.series["gemini2"]?.identityGeneration, "gen-7")
        XCTAssertEqual(history.series["gemini2"]?.points.first?.consumed, 4)
        XCTAssertEqual(history.series["claudeFable"]?.points, [])
        XCTAssertEqual(history.generatedAt, Date(timeIntervalSince1970: 1792051200))
        // The persisted file shape (no helper `ok`) parses too.
        XCTAssertNotNil(NASHistoryV2Core.parse(data(Self.envelope(ok: nil))))
    }

    func testRejectsUnknownOrNonIntegerSchemaVersion() {
        for version in ["1", "3", "2.5", "true", "\"2\""] {
            XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(schemaVersion: version))), version)
        }
    }

    func testRejectsBadGeneratedAtAndExtraRootKeys() {
        for generatedAt in ["0", "-1", "true", "\"1792051200000\"", "null"] {
            XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(generatedAt: generatedAt))), generatedAt)
        }
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(extraRoot: ", \"extra\": 1"))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(ok: "false"))))
    }

    func testRejectsMissingOrExtraSeriesAndSeriesKeys() {
        var missing = Self.envelope()
        missing = missing.replacingOccurrences(of: "\"claudeFable\": \(Self.series()),", with: "")
        XCTAssertNil(NASHistoryV2Core.parse(data(missing)))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["grok": Self.series()]))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": "{\"points\": []}"]))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": "{\"identityGeneration\": null, \"points\": [], \"x\": 1}"]))))
    }

    func testIdentityGenerationMustBeStringOrNull() {
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["gemini": Self.series(identityGeneration: "3")]))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["gemini": Self.series(identityGeneration: "true")]))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["gemini": Self.series(identityGeneration: "\"\"")]))))
    }

    func testRejectsMoreThanFortyPoints() {
        let points = (0..<41).map { Self.point(at: String(1792051200000 + $0)) }
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": Self.series(points: points)]))))
        let forty = Array(points.prefix(40))
        XCTAssertNotNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": Self.series(points: forty)]))))
    }

    func testRejectsInvalidPointFields() {
        let badPoints = [
            Self.point(at: "0"),
            Self.point(at: "-5"),
            Self.point(at: "true"),
            Self.point(consumed: "-1"),
            Self.point(consumed: "true"),
            Self.point(consumed: "\"1\""),
            Self.point(segment: ""),
            Self.point(segment: "has space"),
            Self.point(segment: String(repeating: "a", count: 65)),
            "{\"at\": 1792051200000, \"consumed\": 1, \"unit\": \"percent\"}",
            "{\"at\": 1792051200000, \"consumed\": 1, \"unit\": \"percent\", \"segmentId\": \"a1\", \"extra\": 1}",
        ]
        for bad in badPoints {
            XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": Self.series(points: [bad])]))), bad)
        }
    }

    func testEachSeriesHasExactlyItsOwnUnit() {
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": Self.series(points: [Self.point(unit: "credits")])]))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codexCredits": Self.series(points: [Self.point(unit: "percent")])]))))
        XCTAssertNil(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["gemini2": Self.series(points: [Self.point(unit: "tokens")])]))))
    }

    func testHelperErrorIsAnErrorNeverAnEmptyHistory() {
        let body = #"{"ok": false, "error": {"code": "not_collected", "message": "아직 수집된 기록이 없습니다."}}"#
        XCTAssertEqual(
            NASHistoryV2Core.interpret(stdout: data(body), exitStatus: 1),
            .helperError(NASServiceError(code: "not_collected", message: "아직 수집된 기록이 없습니다."))
        )
        let storage = #"{"ok": false, "error": {"code": "storage_unavailable", "message": "저장소를 확인할 수 없습니다."}}"#
        if case .helperError(let error) = NASHistoryV2Core.interpret(stdout: data(storage), exitStatus: 1) {
            XCTAssertEqual(error.code, "storage_unavailable")
        } else {
            XCTFail("storage_unavailable must surface as a helper error")
        }
        XCTAssertEqual(NASHistoryV2Core.interpret(stdout: data(#"{"ok": false, "error": "boom"}"#), exitStatus: 1), .invalid)
        XCTAssertEqual(NASHistoryV2Core.interpret(stdout: data("garbage"), exitStatus: 0), .invalid)
        // A success-shaped body from a failing exit is contradictory.
        XCTAssertEqual(NASHistoryV2Core.interpret(stdout: data(Self.envelope()), exitStatus: 1), .invalid)
        if case .history = NASHistoryV2Core.interpret(stdout: data(Self.envelope()), exitStatus: 0) {} else {
            XCTFail("valid helper output must parse")
        }
    }

    func testCacheKeepsLastGoodHistoryOnHelperErrorOrInvalid() throws {
        let previous = try XCTUnwrap(NASHistoryV2Core.parse(data(Self.envelope())))
        let helper = NASHistoryV2Cache.apply(.helperError(NASServiceError(code: "schema_changed", message: nil)), previous: previous)
        XCTAssertEqual(helper.history, previous)
        XCTAssertEqual(helper.failureLabel, "이력 NAS 형식 변경으로 확인 불가")
        let invalid = NASHistoryV2Cache.apply(.invalid, previous: previous)
        XCTAssertEqual(invalid.history, previous)
        XCTAssertNotNil(invalid.failureLabel)
        let none = NASHistoryV2Cache.apply(.invalid, previous: nil)
        XCTAssertNil(none.history)
    }

    func testCacheAdoptsNewGoodHistory() throws {
        let previous = try XCTUnwrap(NASHistoryV2Core.parse(data(Self.envelope())))
        let updated = try XCTUnwrap(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["codex": Self.series(points: [Self.point(consumed: "30")])]))))
        let result = NASHistoryV2Cache.apply(.history(updated), previous: previous)
        XCTAssertEqual(result.history?.series["codex"]?.points.first?.consumed, 30)
        XCTAssertNil(result.failureLabel)
    }

    func testEncodeRoundTripsThroughStrictParser() throws {
        let history = try XCTUnwrap(NASHistoryV2Core.parse(data(Self.envelope())))
        let encoded = try XCTUnwrap(NASHistoryV2Core.encode(history))
        XCTAssertEqual(NASHistoryV2Core.parse(encoded), history)
    }

    func testChartSamplesKeepSegmentsSeparateAndNeverSum() throws {
        let points = [
            Self.point(at: "1792051200000", consumed: "5", segment: "segmenta"),
            Self.point(at: "1792051300000", consumed: "2", segment: "segmentb"),
            Self.point(at: "1792051400000", consumed: "1", segment: "segmentb"),
        ]
        let history = try XCTUnwrap(NASHistoryV2Core.parse(data(Self.envelope(overrides: ["gemini2": Self.series(points: points)]))))
        let series = history.series["gemini2"]
        let samples = NASHistoryChartCore.samples(series, unit: .percent)
        XCTAssertEqual(samples.map(\.amount), [5, 2, 1])
        XCTAssertEqual(samples.map(\.at), samples.map(\.at).sorted())
        XCTAssertEqual(NASHistoryChartCore.segmentCount(series), 2)
        // Wrong unit for the strip: nothing drawn instead of a mis-scaled bar.
        XCTAssertTrue(NASHistoryChartCore.samples(series, unit: .credits).isEmpty)
        // account1 and account2 stay separate series.
        XCTAssertEqual(NASHistoryChartCore.samples(history.series["gemini"], unit: .percent).map(\.amount), [12.5])
    }
}

final class DataSourceGateTests: XCTestCase {
    func testOnlyExplicitLocalModeAllowsLocalCollectors() {
        XCTAssertTrue(DataSourceGate.allowsLocalCollection(.localMac))
        XCTAssertFalse(DataSourceGate.allowsLocalCollection(.nas))
    }

    func testResultsFromAnotherSourceOrGenerationAreDropped() {
        XCTAssertTrue(DataSourceGate.accepts(resultFrom: .nas, generation: 3, current: .nas, currentGeneration: 3))
        // A local read finishing after the switch to NAS.
        XCTAssertFalse(DataSourceGate.accepts(resultFrom: .localMac, generation: 3, current: .nas, currentGeneration: 4))
        // A NAS read finishing after NAS → local → NAS (same source, new generation).
        XCTAssertFalse(DataSourceGate.accepts(resultFrom: .nas, generation: 3, current: .nas, currentGeneration: 5))
        XCTAssertFalse(DataSourceGate.accepts(resultFrom: .nas, generation: 3, current: .localMac, currentGeneration: 3))
    }
}

final class NASTransportTests: XCTestCase {
    private func shell(
        _ script: String,
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = NASSSHTransport.maximumOutputBytes,
        killGrace: TimeInterval = 0.5,
        drainGrace: TimeInterval = 0.5
    ) async throws -> NASProcessOutput {
        try await NASSSHTransport.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            killGrace: killGrace,
            drainGrace: drainGrace
        )
    }

    func testFixedSSHArgumentsAndCommands() {
        XCTAssertEqual(NASConfig.sshExecutablePath, "/usr/bin/ssh")
        XCTAssertEqual(NASConfig.remoteCommand, "python3 /workspace/web-app/usage.py --snapshot-json")
        XCTAssertEqual(NASConfig.remoteHistoryCommand, "python3 /workspace/web-app/usage.py --history-json")
        XCTAssertEqual(NASConfig.sshArguments(remoteCommand: NASConfig.remoteHistoryCommand), [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=10",
            "hanstree-dev",
            "python3 /workspace/web-app/usage.py --history-json",
        ])
        XCTAssertLessThanOrEqual(NASSSHTransport.processTimeoutSeconds, 30)
        XCTAssertGreaterThanOrEqual(NASSSHTransport.processTimeoutSeconds, 20)
    }

    func testShortStdoutIsReadCompletely() async throws {
        let output = try await shell("printf '{\"ok\":true}'")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "{\"ok\":true}")
        XCTAssertEqual(output.exitStatus, 0)
    }

    func testFinalChunkWrittenJustBeforeExitIsNotLost() async throws {
        let output = try await shell("printf 'abc'; sleep 0.2; printf 'def'; exit 0")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "abcdef")
    }

    func testLargeStderrIsDrainedWithoutDeadlock() async throws {
        let output = try await shell("head -c 300000 /dev/zero >&2; printf ok")
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "ok")
        XCTAssertEqual(output.stderrByteCount, 300000)
    }

    func testOversizedStdoutIsRejectedNotTruncated() async {
        do {
            _ = try await shell("head -c 5000 /dev/zero", maximumOutputBytes: 1000)
            XCTFail("oversized output must not be returned")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .outputTooLarge)
        }
    }

    func testNonZeroExitAndGoneChildAreReportedAfterReaping() async throws {
        let output = try await shell("printf 'partial'; exit 3")
        XCTAssertEqual(output.exitStatus, 3)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "partial")
    }

    func testTimeoutTerminatesTheChild() async {
        let started = Date()
        do {
            _ = try await shell("exec sleep 10", timeout: 0.3)
            XCTFail("must time out")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testTimeoutEscalatesToKillWhenTermIsIgnored() async {
        let started = Date()
        do {
            _ = try await shell("trap '' TERM; exec sleep 10", timeout: 0.3, killGrace: 0.3)
            XCTFail("must time out")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testTaskCancellationStopsTheChild() async {
        let started = Date()
        let task = Task { try await self.shell("exec sleep 10", timeout: 20) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("must be cancelled")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testMissingExecutableIsSSHUnavailable() async {
        do {
            _ = try await NASSSHTransport.runProcess(executableURL: URL(fileURLWithPath: "/nonexistent/ssh"), arguments: [])
            XCTFail("must fail to launch")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .sshUnavailable)
        }
    }

    func testHistoryClientSurfacesHelperErrorAndSSHFailure() async throws {
        let body = Data(#"{"ok": false, "error": {"code": "not_collected", "message": "아직 수집된 기록이 없습니다."}}"#.utf8)
        let helperClient = NASSnapshotClient { command in
            XCTAssertEqual(command, NASConfig.remoteHistoryCommand)
            return NASProcessOutput(exitStatus: 1, terminatedBySignal: false, stdout: body, stderrByteCount: 0)
        }
        let result = try await helperClient.fetchHistory()
        XCTAssertEqual(result, .helperError(NASServiceError(code: "not_collected", message: "아직 수집된 기록이 없습니다.")))

        let sshFailure = NASSnapshotClient { _ in
            NASProcessOutput(exitStatus: 255, terminatedBySignal: false, stdout: Data(), stderrByteCount: 40)
        }
        do {
            _ = try await sshFailure.fetchHistory()
            XCTFail("ssh failure must throw")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .connectionFailed)
        }
        do {
            _ = try await sshFailure.fetchSnapshot()
            XCTFail("ssh failure must throw")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .connectionFailed)
        }

        let empty = NASSnapshotClient { _ in
            NASProcessOutput(exitStatus: 0, terminatedBySignal: false, stdout: Data(), stderrByteCount: 0)
        }
        do {
            _ = try await empty.fetchSnapshot()
            XCTFail("empty snapshot must throw")
        } catch {
            XCTAssertEqual(error as? NASFetchError, .emptyResponse)
        }
    }
}

@MainActor
final class ThreeServiceCardLayoutTests: XCTestCase {
    private func column(_ title: String, percent: Double? = nil) -> UsagePanelColumn {
        UsagePanelColumn(
            title: title,
            accentColor: .systemBlue,
            quota: percent.map {
                UsagePanelQuota(caption: "세션", percentText: "\(Int($0))%", fraction: $0 / 100, color: .systemBlue, accessibilityValue: "\(Int($0))%")
            },
            secondaryQuota: nil,
            rowGroups: [],
            accountLines: ["놀이터(NAS) 기준"],
            refreshLine: nil,
            statusLines: [],
            statusColor: .secondaryLabelColor
        )
    }

    private func model() -> UsagePanelModel {
        UsagePanelModel(
            codex: column("Codex", percent: 70),
            claude: column("Claude", percent: 60),
            gemini: column("Gemini · 주", percent: 80),
            grok: column("Grok")
        )
    }

    func testModelExposesExactlyThreeCardsInFixedOrder() {
        let m = model()
        XCTAssertEqual([m.codex, m.claude, m.gemini].map(\.title), ["Codex", "Claude", "Gemini · 주"])
    }

    func testCardGridHasThreeColumnsSpanningFullWidth() {
        XCTAssertEqual(UsagePanelLayout.columnCount, 3)
        XCTAssertEqual(UsagePanelLayout.columnX.count, 3)
        let lastCardEdge = UsagePanelLayout.columnX[2] + UsagePanelLayout.columnWidth + UsagePanelLayout.sidePadding
        XCTAssertEqual(lastCardEdge, UsagePanelLayout.viewWidth, accuracy: 0.001)
        for index in 0..<2 {
            XCTAssertGreaterThan(UsagePanelLayout.dividerX(after: index), UsagePanelLayout.columnX[index] + UsagePanelLayout.columnWidth)
            XCTAssertLessThan(UsagePanelLayout.dividerX(after: index), UsagePanelLayout.columnX[index + 1])
        }
    }

    func testSplitPanelRendersExactlyThreeCardsAtFullWidth() {
        let view = SplitUsagePanelView()
        view.apply(model())
        XCTAssertEqual(view.frame.width, UsagePanelLayout.viewWidth, accuracy: 0.001)
        let value = view.accessibilityValue() as? String ?? ""
        XCTAssertTrue(value.contains("80%"))
        XCTAssertFalse(value.contains("Gemini 부계정"))
        let cardFrames = view.subviews
            .filter { $0.frame.width == UsagePanelLayout.columnWidth }
            .map(\.frame.minX)
            .sorted()
        XCTAssertEqual(cardFrames, UsagePanelLayout.columnX)
    }

    func testAppNeverWiresASecondGeminiCardOrHistoryStrip() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/CodexCreditMenuBar/main.swift")
            .standardized
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("gemini2History"))
        XCTAssertFalse(source.contains("gemini2: strips.gemini2"))
        XCTAssertFalse(source.contains("account2Snapshot"))
    }
}

final class GeminiUsageFetchOutcomeTests: XCTestCase {
    func testSkippedOutcomesCarryNoDiagnosticOrLabel() {
        for outcome: GeminiUsageFetchOutcome in [.skippedInFlight, .skippedThrottled] {
            XCTAssertNil(outcome.diagnosticDescription)
            XCTAssertNil(outcome.staleReasonLabel)
        }
    }

    func testFailureOutcomesAlwaysCarryADiagnosticAndLabel() {
        let failures: [GeminiUsageFetchOutcome] = [.commandNotFound, .timedOut, .nonZeroExit(1), .decodeFailure]
        for outcome in failures {
            XCTAssertNotNil(outcome.diagnosticDescription)
            XCTAssertNotNil(outcome.staleReasonLabel)
        }
    }
}

final class GrokUsageCoreTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    func testWeeklyPercentIsUsedWhenPresent() {
        let percent = GrokUsageCore.weeklyUsedPercent(creditUsagePercent: 42.5)
        XCTAssertEqual(percent, 42.5)
    }

    func testWeeklyPercentClamps() {
        XCTAssertEqual(GrokUsageCore.weeklyUsedPercent(creditUsagePercent: 150), 100)
        XCTAssertEqual(GrokUsageCore.weeklyUsedPercent(creditUsagePercent: -10), 0)
    }

    func testOmittedWeeklyPercentIsUnavailable() {
        XCTAssertNil(GrokUsageCore.weeklyUsedPercent(creditUsagePercent: nil))
    }

    func testParsesCompletedTurnTokenUsageOnly() {
        let jsonLines = """
        {"timestamp":1000,"params":{"update":{"sessionUpdate":"agent_message_chunk","usage":{"totalTokens":999}}}}
        {"timestamp":1100,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"totalTokens":12000}}}}
        {"timestamp":1200,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"totalTokens":8000}}}}
        """

        XCTAssertEqual(
            GrokUsageCore.parseTokenUsageRecords(data(jsonLines)),
            [
                GrokTokenUsageRecord(completedAt: Date(timeIntervalSince1970: 1_100), totalTokens: 12_000),
                GrokTokenUsageRecord(completedAt: Date(timeIntervalSince1970: 1_200), totalTokens: 8_000)
            ]
        )
    }

    func testRollingTokenUsageDropsOldRecordsAndPredictsRecovery() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let records = [
            GrokTokenUsageRecord(completedAt: now.addingTimeInterval(-90_000), totalTokens: 400_000),
            GrokTokenUsageRecord(completedAt: now.addingTimeInterval(-80_000), totalTokens: 300_000),
            GrokTokenUsageRecord(completedAt: now.addingTimeInterval(-1_000), totalTokens: 205_000)
        ]

        let estimate = try XCTUnwrap(GrokUsageCore.rollingTokenUsage(records: records, now: now))

        XCTAssertEqual(estimate.usedTokens, 505_000)
        XCTAssertEqual(estimate.limitTokens, 500_000)
        XCTAssertEqual(estimate.remainingPercent, 0)
        XCTAssertEqual(estimate.recoveryAt, now.addingTimeInterval(6_400))
    }

    func testRollingTokenUsageShowsRemainingEstimateWhenBelowLimit() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let estimate = try XCTUnwrap(GrokUsageCore.rollingTokenUsage(
            records: [GrokTokenUsageRecord(completedAt: now.addingTimeInterval(-1_000), totalTokens: 20_000)],
            now: now
        ))

        XCTAssertEqual(estimate.usedTokens, 20_000)
        XCTAssertEqual(estimate.remainingPercent, 96)
        XCTAssertNil(estimate.recoveryAt)
    }

    /// The default `/v1/billing` shape: `monthlyLimit.val == 0`,
    /// `used.val == 280`. A zero (or absent) limit must never render a
    /// monthly percentage.
    func testZeroOrAbsentMonthlyLimitIsRejected() {
        XCTAssertNil(GrokUsageCore.monthlyUsedPercent(limit: 0, used: 280))
        XCTAssertNil(GrokUsageCore.monthlyUsedPercent(limit: nil, used: 280))
        XCTAssertNil(GrokUsageCore.monthlyUsedPercent(limit: 100, used: nil))
        XCTAssertNil(GrokUsageCore.monthlyUsedPercent(limit: .infinity, used: 10))
    }

    func testMonthlyPercentOnlyWithFinitePositiveLimitAndUsed() {
        XCTAssertEqual(GrokUsageCore.monthlyUsedPercent(limit: 200, used: 50), 25)
        XCTAssertEqual(GrokUsageCore.monthlyUsedPercent(limit: 100, used: 250), 100)
        XCTAssertEqual(GrokUsageCore.monthlyUsedPercent(limit: 100, used: -10), 0)
    }

    func testParseReadsWeeklyPercentAndAccountEmailWithoutLeakingToken() throws {
        let json = """
        {
            "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-08-15T00:00:00Z", "end": "2026-08-22T00:00:00Z"},
            "billingPeriodStart": "2026-08-15T00:00:00Z",
            "billingPeriodEnd": "2026-08-22T00:00:00Z",
            "creditUsagePercent": 12.5,
            "monthlyLimit": {"val": 0},
            "used": {"val": 280}
        }
        """
        let snapshot = try XCTUnwrap(GrokUsageCore.parse(data(json), accountEmail: "person@example.com", now: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(snapshot.weeklyUsedPercent, 12.5)
        XCTAssertNil(snapshot.monthlyUsedPercent)
        XCTAssertEqual(snapshot.accountEmail, "person@example.com")
        XCTAssertNotNil(snapshot.weeklyResetsAt)
    }

    func testParseKeepsOmittedLivePercentUnavailable() throws {
        let json = """
        {
            "config": {
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-08-15T00:00:00+00:00", "end": "2026-08-22T00:00:00+00:00"},
                "billingPeriodStart": "2026-08-15T00:00:00+00:00",
                "billingPeriodEnd": "2026-08-22T00:00:00+00:00",
                "prepaidBalance": {"val": 0}
            }
        }
        """
        let snapshot = try XCTUnwrap(GrokUsageCore.parse(data(json), accountEmail: nil))
        XCTAssertNil(snapshot.weeklyUsedPercent)
        XCTAssertEqual(snapshot.extraCreditBalance, 0)
    }

    func testParseReturnsNilForMalformedJSON() {
        XCTAssertNil(GrokUsageCore.parse(data("not-json"), accountEmail: nil))
    }

    func testParseReturnsNilWhenNoUsageIsAvailableAtAll() {
        let json = """
        {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_MONTHLY", "start": "a", "end": "b"}, "monthlyLimit": {"val": 0}}
        """
        XCTAssertNil(GrokUsageCore.parse(data(json), accountEmail: nil))
    }

    func testSharedPayloadRoundTripsIntoRestartSnapshot() throws {
        let original = GrokUsageSnapshot(
            weeklyUsedPercent: 12.5,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000),
            monthlyUsedPercent: nil,
            monthlyResetsAt: nil,
            monthlyUsedCredits: 2.8,
            extraCreditBalance: 5,
            subscriptionTier: "SuperGrok",
            rollingTokenUsage: GrokRollingTokenUsage(
                usedTokens: 20_000,
                limitTokens: 500_000,
                recoveryAt: nil
            ),
            publishedAt: Date(timeIntervalSince1970: 1_000),
            accountEmail: "person@example.com"
        )
        let payload = GrokUsageCore.sharedPayload(from: original, now: Date(timeIntervalSince1970: 1_010))
        XCTAssertEqual(payload["status"] as? String, "ok")

        let restored = try XCTUnwrap(GrokUsageCore.snapshot(fromSharedPayload: payload))
        XCTAssertEqual(restored.weeklyUsedPercent, original.weeklyUsedPercent)
        XCTAssertEqual(restored.monthlyUsedCredits, 2.8)
        XCTAssertEqual(restored.extraCreditBalance, 5)
        XCTAssertEqual(restored.subscriptionTier, "SuperGrok")
        XCTAssertEqual(restored.rollingTokenUsage, original.rollingTokenUsage)
        XCTAssertEqual(restored.accountEmail, original.accountEmail)
        XCTAssertEqual(restored.publishedAt, original.publishedAt)
    }

    func testParseCombinedCollectsPlanMonthlyWeeklyAndCredits() throws {
        let credits = """
        {
            "config": {
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-08-15T00:00:00+00:00", "end": "2026-08-22T00:00:00+00:00"},
                "billingPeriodStart": "2026-08-15T00:00:00+00:00",
                "billingPeriodEnd": "2026-08-22T00:00:00+00:00",
                "prepaidBalance": {"val": 525}
            }
        }
        """
        let billing = """
        {
            "config": {
                "monthlyLimit": {"val": 0},
                "used": {"val": 280},
                "billingPeriodEnd": "2026-09-01T00:00:00+00:00"
            }
        }
        """
        let settings = """
        {"subscription_tier_display": "Free"}
        """

        let snapshot = try XCTUnwrap(GrokUsageCore.parseCombined(
            creditsData: data(credits),
            billingData: data(billing),
            settingsData: data(settings),
            accountEmail: "person@example.com",
            now: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(snapshot.subscriptionTier, "Free")
        XCTAssertEqual(snapshot.monthlyUsedCredits, 2.8)
        XCTAssertNil(snapshot.weeklyUsedPercent)
        XCTAssertNotNil(snapshot.weeklyResetsAt)
        XCTAssertEqual(snapshot.extraCreditBalance, 5.25)
    }

    func testSharedPayloadForMissingSnapshotIsExplicitlyUnavailable() {
        let payload = GrokUsageCore.sharedPayload(from: nil)
        XCTAssertEqual(payload["status"] as? String, "unavailable")
        XCTAssertTrue(payload["weeklyRemainingPercent"] is NSNull)
        XCTAssertEqual(payload["weeklyUsageConfirmed"] as? Bool, false)
        XCTAssertEqual(payload["fresh"] as? Bool, false)
    }

    func testLegacyInferredZeroDoesNotRestoreAsOneHundredPercentRemaining() throws {
        let payload: [String: Any] = [
            "weeklyUsedPercent": 0.0,
            "monthlyUsedCredits": 6.62,
            "subscriptionTier": "Free",
            "fetchedAt": "2026-08-21T13:27:56.286Z"
        ]

        let restored = try XCTUnwrap(GrokUsageCore.snapshot(fromSharedPayload: payload))

        XCTAssertNil(restored.weeklyUsedPercent)
        XCTAssertTrue(GrokUsageCore.sharedPayload(from: restored)["weeklyRemainingPercent"] is NSNull)
    }

    func testRestartSnapshotRejectsEmptySharedPayload() {
        XCTAssertNil(GrokUsageCore.snapshot(fromSharedPayload: [:]))
    }

    func testRefreshedSharedPayloadRecalculatesFreshness() {
        let snapshot = GrokUsageSnapshot(weeklyUsedPercent: 10, publishedAt: Date(timeIntervalSince1970: 1_000))
        let stored = GrokUsageCore.sharedPayload(from: snapshot, now: Date(timeIntervalSince1970: 1_100))

        let refreshed = GrokUsageCore.refreshedSharedPayload(stored, now: Date(timeIntervalSince1970: 1_500))

        XCTAssertEqual(refreshed["ageSeconds"] as? Int, 500)
        XCTAssertEqual(refreshed["fresh"] as? Bool, false)
    }

    func testShouldThrottleFetchRequiresTheHigherGrokFloor() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(GrokUsageCore.shouldThrottleFetch(
            minimumInterval: GrokUsageCore.minimumRequestIntervalSeconds,
            lastFetchDate: Date(timeIntervalSince1970: 950),
            now: now
        ))
        XCTAssertFalse(GrokUsageCore.shouldThrottleFetch(
            minimumInterval: GrokUsageCore.minimumRequestIntervalSeconds,
            lastFetchDate: Date(timeIntervalSince1970: 850),
            now: now
        ))
        XCTAssertFalse(GrokUsageCore.shouldThrottleFetch(minimumInterval: 120, lastFetchDate: nil, now: now))
    }
}

final class GrokAuthCoreTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    func testSelectsTokenBearingAuthXAIEntryWithoutOtherIssuers() throws {
        let json = """
        {
            "https://auth.x.ai::abc123": {
                "key": "secret-token",
                "user_id": "user-1",
                "email": "person@example.com",
                "team_id": "team-1",
                "refresh_token": "refresh-secret",
                "expires_at": 2000000000
            },
            "https://auth.example.com::other": {
                "key": "unrelated-token"
            }
        }
        """
        let credential = try XCTUnwrap(GrokAuthCore.selectCredential(from: data(json)))
        XCTAssertEqual(credential.accessToken, "secret-token")
        XCTAssertEqual(credential.email, "person@example.com")
        XCTAssertEqual(credential.userID, "user-1")
        XCTAssertEqual(credential.teamID, "team-1")
        XCTAssertTrue(credential.hasRefreshToken)
        XCTAssertNotNil(credential.expiresAt)
    }

    func testSelectsFreshestEntryWhenMultiplePresent() throws {
        let json = """
        {
            "https://auth.x.ai::old": {"key": "old-token", "expires_at": 1000000000},
            "https://auth.x.ai::new": {"key": "new-token", "expires_at": 3000000000}
        }
        """
        let credential = try XCTUnwrap(GrokAuthCore.selectCredential(from: data(json)))
        XCTAssertEqual(credential.accessToken, "new-token")
    }

    func testIgnoresEntriesWithoutATokenAndMalformedJSON() {
        let json = #"{"https://auth.x.ai::empty": {"user_id": "user-1"}}"#
        XCTAssertNil(GrokAuthCore.selectCredential(from: data(json)))
        XCTAssertNil(GrokAuthCore.selectCredential(from: data("not-json")))
    }

    func testExpiryIsComparedAgainstNow() {
        let expired = GrokAuthCredential(accessToken: "t", email: nil, userID: nil, teamID: nil, expiresAt: Date(timeIntervalSince1970: 1_000), hasRefreshToken: false)
        let notExpired = GrokAuthCredential(accessToken: "t", email: nil, userID: nil, teamID: nil, expiresAt: Date(timeIntervalSince1970: 3_000), hasRefreshToken: false)
        let noExpiry = GrokAuthCredential(accessToken: "t", email: nil, userID: nil, teamID: nil, expiresAt: nil, hasRefreshToken: false)
        let now = Date(timeIntervalSince1970: 2_000)

        XCTAssertTrue(GrokAuthCore.isExpired(expired, now: now))
        XCTAssertFalse(GrokAuthCore.isExpired(notExpired, now: now))
        XCTAssertFalse(GrokAuthCore.isExpired(noExpiry, now: now))
    }

    func testParsesWholeSecondISOExpiry() throws {
        let json = #"""
        {
          "https://auth.x.ai::active": {
            "key": "token",
            "expires_at": "2030-01-02T03:04:05Z"
          }
        }
        """#

        let credential = try XCTUnwrap(GrokAuthCore.selectCredential(from: data(json)))
        XCTAssertNotNil(credential.expiresAt)
    }
}

final class GrokUsageFetchOutcomeTests: XCTestCase {
    func testSkippedOutcomesCarryNoDiagnosticOrLabel() {
        for outcome: GrokUsageFetchOutcome in [.skippedInFlight, .skippedThrottled] {
            XCTAssertNil(outcome.diagnosticDescription)
            XCTAssertNil(outcome.staleReasonLabel)
        }
    }

    func testFailureOutcomesAlwaysCarryADiagnosticAndLabel() {
        let failures: [GrokUsageFetchOutcome] = [.notSignedIn, .expiredCredential, .httpFailure(status: 500), .transportFailure, .decodeFailure]
        for outcome in failures {
            XCTAssertNotNil(outcome.diagnosticDescription)
            XCTAssertNotNil(outcome.staleReasonLabel)
        }
    }

    func testExpiredCredentialDirectsUserToInAppLogin() {
        XCTAssertEqual(GrokUsageFetchOutcome.expiredCredential.staleReasonLabel, "인증 만료 · 브라우저에서 Grok 로그인이 필요합니다")
    }
}

final class ClaudeUsageCoreTests: XCTestCase {
    func testRemainingPercentIsClampedAndNilSafe() {
        XCTAssertEqual(ClaudeUsageCore.remainingPercent(from: 28), 72)
        XCTAssertEqual(ClaudeUsageCore.remainingPercent(from: -5), 100)
        XCTAssertEqual(ClaudeUsageCore.remainingPercent(from: 150), 0)
        XCTAssertNil(ClaudeUsageCore.remainingPercent(from: nil))
    }

    func testFableWeeklyLimitMatchesCaseInsensitivelyAndIgnoresOtherModels() {
        let opus = ClaudeModelWeeklyLimit(modelName: "Opus", usedPercent: 60, resetsAt: nil)
        let fable = ClaudeModelWeeklyLimit(modelName: "fable", usedPercent: 20, resetsAt: nil)
        XCTAssertEqual(ClaudeUsageCore.fableWeeklyLimit(in: [opus, fable]), fable)
        XCTAssertNil(ClaudeUsageCore.fableWeeklyLimit(in: [opus]))
        XCTAssertNil(ClaudeUsageCore.fableWeeklyLimit(in: []))
    }

    func testCostTitleFormatsSmallAndLargeValues() {
        XCTAssertEqual(ClaudeUsageCore.costTitle(from: 0.0042), "$0.0042")
        XCTAssertEqual(ClaudeUsageCore.costTitle(from: 1.2345), "$1.23")
        XCTAssertNil(ClaudeUsageCore.costTitle(from: 0))
        XCTAssertNil(ClaudeUsageCore.costTitle(from: nil))
    }

    func testFreshnessRequiresRecentPublishedAt() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ClaudeUsageCore.isFresh(publishedAt: Date(timeIntervalSince1970: 800), now: now, freshForSeconds: 600))
        XCTAssertFalse(ClaudeUsageCore.isFresh(publishedAt: Date(timeIntervalSince1970: 300), now: now, freshForSeconds: 600))
        XCTAssertFalse(ClaudeUsageCore.isFresh(publishedAt: nil, now: now, freshForSeconds: 600))
    }

    func testShouldThrottleFetchMatchesCodexsConfiguredCadence() {
        let now = Date(timeIntervalSince1970: 1000)

        // No prior fetch: never throttled.
        XCTAssertFalse(ClaudeUsageCore.shouldThrottleFetch(minimumInterval: 30, lastFetchDate: nil, now: now))

        // Within Codex's cadence: throttled.
        XCTAssertTrue(ClaudeUsageCore.shouldThrottleFetch(
            minimumInterval: 30,
            lastFetchDate: Date(timeIntervalSince1970: 985),
            now: now
        ))

        // At or beyond Codex's cadence: due again.
        XCTAssertFalse(ClaudeUsageCore.shouldThrottleFetch(
            minimumInterval: 30,
            lastFetchDate: Date(timeIntervalSince1970: 970),
            now: now
        ))

        // A timer tick that arrives within scheduling tolerance must not be
        // deferred to the next cycle, which would double Claude's cadence.
        XCTAssertFalse(ClaudeUsageCore.shouldThrottleFetch(
            minimumInterval: 30,
            lastFetchDate: Date(timeIntervalSince1970: 970.5),
            now: now
        ))
        XCTAssertTrue(ClaudeUsageCore.shouldThrottleFetch(
            minimumInterval: 30,
            lastFetchDate: Date(timeIntervalSince1970: 971.1),
            now: now
        ))

        // Auto-refresh off (interval 0): no floor, same as Codex's own manual-only behavior.
        XCTAssertFalse(ClaudeUsageCore.shouldThrottleFetch(
            minimumInterval: 0,
            lastFetchDate: Date(timeIntervalSince1970: 999),
            now: now
        ))
    }

    func testParseRetryAfterAcceptsDeltaSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(ClaudeUsageCore.parseRetryAfterSeconds("120", now: now), 120)
        XCTAssertEqual(ClaudeUsageCore.parseRetryAfterSeconds("0", now: now), 0)
        XCTAssertEqual(ClaudeUsageCore.parseRetryAfterSeconds(" 45 ", now: now), 45)
    }

    func testParseRetryAfterAcceptsHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        let retryAfter = "Thu, 01 Jan 1970 00:23:20 GMT" // epoch 1400 = now(1000) + 400s
        XCTAssertEqual(ClaudeUsageCore.parseRetryAfterSeconds(retryAfter, now: now), 400)
    }

    func testParseRetryAfterRejectsMissingOrUnparseableValues() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(ClaudeUsageCore.parseRetryAfterSeconds(nil, now: now))
        XCTAssertNil(ClaudeUsageCore.parseRetryAfterSeconds("", now: now))
        XCTAssertNil(ClaudeUsageCore.parseRetryAfterSeconds("not-a-value", now: now))
        XCTAssertNil(ClaudeUsageCore.parseRetryAfterSeconds("-5", now: now))
    }

    func testRateLimitBackoffSecondsFallsBackWhenHeaderMissingOrInvalid() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitBackoffSeconds(retryAfterHeader: nil, now: now),
            ClaudeUsageCore.defaultRateLimitBackoffSeconds
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitBackoffSeconds(retryAfterHeader: "garbage", now: now),
            ClaudeUsageCore.defaultRateLimitBackoffSeconds
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitBackoffSeconds(retryAfterHeader: "15", now: now),
            ClaudeUsageCore.defaultRateLimitBackoffSeconds
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitBackoffSeconds(retryAfterHeader: "120", now: now),
            ClaudeUsageCore.defaultRateLimitBackoffSeconds
        )
        XCTAssertEqual(ClaudeUsageCore.rateLimitBackoffSeconds(retryAfterHeader: "7200", now: now), 7_200)
    }

    func testRateLimitCircuitBreakerEscalatesAndCapsItsOwnFloor() {
        XCTAssertEqual(ClaudeUsageCore.circuitBreakerBackoffSeconds(consecutiveRateLimits: 1), 3_600)
        XCTAssertEqual(ClaudeUsageCore.circuitBreakerBackoffSeconds(consecutiveRateLimits: 2), 7_200)
        XCTAssertEqual(ClaudeUsageCore.circuitBreakerBackoffSeconds(consecutiveRateLimits: 3), 14_400)
        XCTAssertEqual(ClaudeUsageCore.circuitBreakerBackoffSeconds(consecutiveRateLimits: 4), 21_600)
        XCTAssertEqual(ClaudeUsageCore.circuitBreakerBackoffSeconds(consecutiveRateLimits: 20), 21_600)

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitBackoffSeconds(
                retryAfterHeader: "43200",
                consecutiveRateLimits: 4,
                now: now
            ),
            43_200,
            "a longer server Retry-After must never be capped by the local circuit"
        )
    }

    func testShouldSkipRateLimitBackoffOnlyWhileRetryAtIsInTheFuture() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ClaudeUsageCore.shouldSkipRateLimitBackoff(retryAt: nil, now: now))
        XCTAssertTrue(ClaudeUsageCore.shouldSkipRateLimitBackoff(retryAt: Date(timeIntervalSince1970: 1_050), now: now))
        XCTAssertFalse(ClaudeUsageCore.shouldSkipRateLimitBackoff(retryAt: Date(timeIntervalSince1970: 1_000), now: now))
        XCTAssertFalse(ClaudeUsageCore.shouldSkipRateLimitBackoff(retryAt: Date(timeIntervalSince1970: 950), now: now))
    }

    func testRateLimitRetryLabelCountsDownAndNeverGoesNegative() {
        let retryAt = Date(timeIntervalSince1970: 1_090)
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitRetryLabel(retryAt: retryAt, now: Date(timeIntervalSince1970: 1_000)),
            "429 · 2분 후 재시도"
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitRetryLabel(retryAt: retryAt, now: Date(timeIntervalSince1970: 1_089.4)),
            "429 · 1초 후 재시도"
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitRetryLabel(retryAt: retryAt, now: Date(timeIntervalSince1970: 1_200)),
            "429 · 0초 후 재시도"
        )
    }

    func testSharedPayloadIncludesClaudeWeeklyAndSessionRemainingUsage() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = ClaudeUsageSnapshot(
            quotaSource: "anthropic-oauth-usage",
            model: "claude-opus",
            weeklyUsedPercent: 28,
            weeklyResetsAt: Date(timeIntervalSince1970: 2_000),
            fiveHourUsedPercent: 40,
            fiveHourResetsAt: Date(timeIntervalSince1970: 1_500),
            contextUsedPercent: nil,
            contextRemainingPercent: nil,
            sessionCostUSD: nil,
            publishedAt: Date(timeIntervalSince1970: 900)
        )

        let payload = ClaudeUsageCore.sharedPayload(from: snapshot, now: now)

        XCTAssertEqual(payload["status"] as? String, "ok")
        XCTAssertEqual(payload["source"] as? String, "anthropic-oauth-usage")
        XCTAssertEqual(payload["weeklyRemainingPercent"] as? Double, 72)
        XCTAssertEqual(payload["fiveHourRemainingPercent"] as? Double, 60)
        XCTAssertEqual(payload["ageSeconds"] as? Int, 100)
        XCTAssertEqual(payload["fresh"] as? Bool, true)
        XCTAssertEqual(payload["freshForSeconds"] as? Int, 660)
        XCTAssertEqual(payload["model"] as? String, "claude-opus")
        XCTAssertNotNil(payload["weeklyResetsAt"] as? String)
    }

    func testSharedPayloadMakesMissingClaudeUsageExplicit() {
        let payload = ClaudeUsageCore.sharedPayload(from: nil)

        XCTAssertEqual(payload["status"] as? String, "unavailable")
        XCTAssertEqual(payload["source"] as? String, "unavailable")
        XCTAssertTrue(payload["weeklyRemainingPercent"] is NSNull)
        XCTAssertEqual(payload["fresh"] as? Bool, false)
    }

    func testRefreshedSharedPayloadRecalculatesClaudeFreshness() {
        let snapshot = makeSnapshot(
            weeklyUsedPercent: 20,
            publishedAt: Date(timeIntervalSince1970: 1_000)
        )
        let stored = ClaudeUsageCore.sharedPayload(
            from: snapshot,
            now: Date(timeIntervalSince1970: 1_100)
        )

        let refreshed = ClaudeUsageCore.refreshedSharedPayload(
            stored,
            now: Date(timeIntervalSince1970: 1_301)
        )

        XCTAssertEqual(refreshed["ageSeconds"] as? Int, 301)
        XCTAssertEqual(refreshed["fresh"] as? Bool, false)
        XCTAssertEqual(refreshed["source"] as? String, "claude-statusline")
    }

    func testRefreshedSharedPayloadLabelsLegacyClaudeCache() {
        let refreshed = ClaudeUsageCore.refreshedSharedPayload([
            "fetchedAt": "1970-01-01T00:16:40.000Z",
            "freshForSeconds": 660
        ], now: Date(timeIntervalSince1970: 1_100))

        XCTAssertEqual(refreshed["source"] as? String, "legacy-ccmb-cache")
    }

    func testClaudeFreshnessWindowDependsOnQuotaSource() {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 1_400)
        let statusLine = makeSnapshot(
            quotaSource: "claude-statusline",
            weeklyUsedPercent: 20,
            publishedAt: observedAt
        )
        let oauth = makeSnapshot(
            quotaSource: "anthropic-oauth-usage",
            weeklyUsedPercent: 20,
            publishedAt: observedAt
        )

        let statusLinePayload = ClaudeUsageCore.sharedPayload(from: statusLine, now: now)
        let oauthPayload = ClaudeUsageCore.sharedPayload(from: oauth, now: now)

        XCTAssertEqual(statusLinePayload["freshForSeconds"] as? Int, 300)
        XCTAssertEqual(statusLinePayload["fresh"] as? Bool, false)
        XCTAssertEqual(oauthPayload["freshForSeconds"] as? Int, 660)
        XCTAssertEqual(oauthPayload["fresh"] as? Bool, true)
    }

    private func makeSnapshot(
        quotaSource: String? = "claude-statusline",
        model: String? = nil,
        weeklyUsedPercent: Double? = nil,
        fiveHourUsedPercent: Double? = nil,
        contextRemainingPercent: Double? = nil,
        sessionCostUSD: Double? = nil,
        publishedAt: Date? = nil,
        modelWeeklyLimits: [ClaudeModelWeeklyLimit] = [],
        extraUsage: ClaudeExtraUsage? = nil,
        account: ClaudeAccountInfo? = nil
    ) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            quotaSource: quotaSource,
            model: model,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyResetsAt: nil,
            fiveHourUsedPercent: fiveHourUsedPercent,
            fiveHourResetsAt: nil,
            contextUsedPercent: nil,
            contextRemainingPercent: contextRemainingPercent,
            sessionCostUSD: sessionCostUSD,
            publishedAt: publishedAt,
            modelWeeklyLimits: modelWeeklyLimits,
            extraUsage: extraUsage,
            account: account
        )
    }

    func testMergePrefersPreferredFieldsAndBackfillsMissingOnes() {
        let live = makeSnapshot(fiveHourUsedPercent: 40, publishedAt: Date(timeIntervalSince1970: 200))
        let cache = makeSnapshot(
            model: "claude-opus",
            weeklyUsedPercent: 10,
            contextRemainingPercent: 55,
            sessionCostUSD: 1.2,
            publishedAt: Date(timeIntervalSince1970: 100)
        )

        let merged = ClaudeUsageCore.merge(preferred: live, fallback: cache)

        XCTAssertEqual(merged.fiveHourUsedPercent, 40)
        XCTAssertEqual(merged.model, "claude-opus")
        XCTAssertEqual(merged.contextRemainingPercent, 55)
        XCTAssertEqual(merged.sessionCostUSD, 1.2)
        XCTAssertEqual(merged.publishedAt, Date(timeIntervalSince1970: 200))
    }

    func testMergeWithNilFallbackReturnsPreferredUnchanged() {
        let live = makeSnapshot(fiveHourUsedPercent: 40, publishedAt: Date(timeIntervalSince1970: 200))
        let merged = ClaudeUsageCore.merge(preferred: live, fallback: nil)
        XCTAssertEqual(merged.fiveHourUsedPercent, 40)
        XCTAssertNil(merged.model)
    }

    func testMergingCacheSnapshotNeverRegressesToOlderCache() {
        let newerLive = makeSnapshot(fiveHourUsedPercent: 40, publishedAt: Date(timeIntervalSince1970: 200))
        let olderCache = makeSnapshot(model: "claude-opus", publishedAt: Date(timeIntervalSince1970: 100))

        let result = ClaudeUsageCore.mergingCacheSnapshot(current: newerLive, cache: olderCache)

        XCTAssertEqual(result?.fiveHourUsedPercent, 40, "must not be overwritten by an older cache read")
        XCTAssertEqual(result?.publishedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(result?.model, "claude-opus", "cache-only fields should still be backfilled")
    }

    func testMergingCacheSnapshotAdoptsNewerCache() {
        let olderLive = makeSnapshot(fiveHourUsedPercent: 40, publishedAt: Date(timeIntervalSince1970: 100))
        let newerCache = makeSnapshot(weeklyUsedPercent: 20, publishedAt: Date(timeIntervalSince1970: 200))

        let result = ClaudeUsageCore.mergingCacheSnapshot(current: olderLive, cache: newerCache)

        XCTAssertEqual(result?.weeklyUsedPercent, 20)
        XCTAssertEqual(result?.publishedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNil(result?.fiveHourUsedPercent, "an older missing quota must not be presented with the newer cache timestamp")
    }

    func testNewerMetadataOnlyStatusLineDoesNotFreshenOldQuota() {
        let olderLive = makeSnapshot(
            fiveHourUsedPercent: 40,
            publishedAt: Date(timeIntervalSince1970: 100)
        )
        let newerMetadataOnlyCache = makeSnapshot(
            model: "Sonnet 5",
            contextRemainingPercent: 80,
            publishedAt: Date(timeIntervalSince1970: 200)
        )

        let result = ClaudeUsageCore.mergingCacheSnapshot(
            current: olderLive,
            cache: newerMetadataOnlyCache
        )

        XCTAssertEqual(result?.fiveHourUsedPercent, 40)
        XCTAssertEqual(result?.model, "Sonnet 5")
        XCTAssertEqual(result?.contextRemainingPercent, 80)
        XCTAssertEqual(result?.publishedAt, Date(timeIntervalSince1970: 100))
    }

    func testMergingCacheSnapshotHandlesNilInputs() {
        let live = makeSnapshot(fiveHourUsedPercent: 40, publishedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(ClaudeUsageCore.mergingCacheSnapshot(current: nil, cache: nil))
        XCTAssertEqual(ClaudeUsageCore.mergingCacheSnapshot(current: live, cache: nil)?.fiveHourUsedPercent, 40)
        XCTAssertEqual(ClaudeUsageCore.mergingCacheSnapshot(current: nil, cache: live)?.fiveHourUsedPercent, 40)
    }

    func testMergeKeepsPreferredModelWeeklyLimitsAndBackfillsWhenEmpty() {
        let opusLimit = ClaudeModelWeeklyLimit(modelName: "Opus", usedPercent: 60, resetsAt: nil)
        let sonnetLimit = ClaudeModelWeeklyLimit(modelName: "Sonnet", usedPercent: 30, resetsAt: nil)

        let preferredWithLimits = makeSnapshot(modelWeeklyLimits: [opusLimit])
        let fallbackWithLimits = makeSnapshot(modelWeeklyLimits: [sonnetLimit])
        XCTAssertEqual(
            ClaudeUsageCore.merge(preferred: preferredWithLimits, fallback: fallbackWithLimits).modelWeeklyLimits,
            [opusLimit],
            "non-empty preferred list must not be overwritten by fallback"
        )

        let preferredEmpty = makeSnapshot(modelWeeklyLimits: [])
        XCTAssertEqual(
            ClaudeUsageCore.merge(preferred: preferredEmpty, fallback: fallbackWithLimits).modelWeeklyLimits,
            [sonnetLimit],
            "empty preferred list should be backfilled from fallback"
        )
    }

    func testMergeKeepsPreferredExtraUsageAndBackfillsWhenNil() {
        let preferredExtra = ClaudeExtraUsage(limitCents: 2000, usedCents: 500, currency: "USD")
        let fallbackExtra = ClaudeExtraUsage(limitCents: 1000, usedCents: 100, currency: "EUR")

        let preferredWithExtra = makeSnapshot(extraUsage: preferredExtra)
        let fallbackWithExtra = makeSnapshot(extraUsage: fallbackExtra)
        XCTAssertEqual(
            ClaudeUsageCore.merge(preferred: preferredWithExtra, fallback: fallbackWithExtra).extraUsage,
            preferredExtra
        )

        let preferredWithoutExtra = makeSnapshot(extraUsage: nil)
        XCTAssertEqual(
            ClaudeUsageCore.merge(preferred: preferredWithoutExtra, fallback: fallbackWithExtra).extraUsage,
            fallbackExtra
        )
    }

    func testSharedPayloadIncludesModelWeeklyLimitsAndExtraUsage() throws {
        let snapshot = makeSnapshot(
            weeklyUsedPercent: 20,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            modelWeeklyLimits: [
                ClaudeModelWeeklyLimit(modelName: "Opus", usedPercent: 60, resetsAt: Date(timeIntervalSince1970: 2_000)),
                ClaudeModelWeeklyLimit(modelName: "Sonnet", usedPercent: 30, resetsAt: nil)
            ],
            extraUsage: ClaudeExtraUsage(limitCents: 2000, usedCents: 450, currency: "USD")
        )

        let payload = ClaudeUsageCore.sharedPayload(from: snapshot, now: Date(timeIntervalSince1970: 1_000))

        let limits = try XCTUnwrap(payload["modelWeeklyLimits"] as? [[String: Any]])
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[0]["model"] as? String, "Opus")
        XCTAssertEqual(limits[0]["usedPercent"] as? Double, 60)
        XCTAssertEqual(limits[0]["remainingPercent"] as? Double, 40)
        XCTAssertNotNil(limits[0]["resetsAt"] as? String)
        XCTAssertEqual(limits[1]["model"] as? String, "Sonnet")
        XCTAssertTrue(limits[1]["resetsAt"] is NSNull)

        let extraUsage = try XCTUnwrap(payload["extraUsage"] as? [String: Any])
        XCTAssertEqual(extraUsage["limitCents"] as? Double, 2000)
        XCTAssertEqual(extraUsage["usedCents"] as? Double, 450)
        XCTAssertEqual(extraUsage["currency"] as? String, "USD")
    }

    func testSharedPayloadOmitsModelWeeklyLimitsAndExtraUsageWhenAbsent() throws {
        let snapshot = makeSnapshot(weeklyUsedPercent: 20, publishedAt: Date(timeIntervalSince1970: 1_000))
        let payload = ClaudeUsageCore.sharedPayload(from: snapshot, now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual((payload["modelWeeklyLimits"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertTrue(payload["extraUsage"] is NSNull)
    }

    func testSharedPayloadForMissingSnapshotIncludesEmptyModelLimitsAndNullExtraUsage() {
        let payload = ClaudeUsageCore.sharedPayload(from: nil)

        XCTAssertEqual((payload["modelWeeklyLimits"] as? [[String: Any]])?.isEmpty, true)
        XCTAssertTrue(payload["extraUsage"] is NSNull)
        XCTAssertTrue(payload["account"] is NSNull)
    }

    func testSharedPayloadIncludesAccountEmailAndOrganization() throws {
        let snapshot = makeSnapshot(
            weeklyUsedPercent: 20,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            account: ClaudeAccountInfo(email: "user@example.com", organizationName: "Acme", organizationUUID: "org-1")
        )

        let payload = ClaudeUsageCore.sharedPayload(from: snapshot, now: Date(timeIntervalSince1970: 1_000))
        let account = try XCTUnwrap(payload["account"] as? [String: Any])

        XCTAssertEqual(account["email"] as? String, "user@example.com")
        XCTAssertEqual(account["organizationName"] as? String, "Acme")
        XCTAssertEqual(account["organizationUUID"] as? String, "org-1")
    }

    func testSharedPayloadRoundTripsIntoRestartSnapshot() throws {
        let original = makeSnapshot(
            model: "Sonnet 5",
            weeklyUsedPercent: 1,
            fiveHourUsedPercent: 11,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            modelWeeklyLimits: [ClaudeModelWeeklyLimit(modelName: "Fable", usedPercent: 0, resetsAt: nil)],
            extraUsage: ClaudeExtraUsage(limitCents: 2_000, usedCents: 100, currency: "USD"),
            account: ClaudeAccountInfo(email: "user@example.com", organizationName: "Personal", organizationUUID: "org-1")
        )
        let payload = ClaudeUsageCore.sharedPayload(from: original, now: Date(timeIntervalSince1970: 1_010))

        let restored = try XCTUnwrap(ClaudeUsageCore.snapshot(fromSharedPayload: payload))

        XCTAssertEqual(restored.quotaSource, original.quotaSource)
        XCTAssertEqual(restored.model, original.model)
        XCTAssertEqual(restored.weeklyUsedPercent, original.weeklyUsedPercent)
        XCTAssertEqual(restored.fiveHourUsedPercent, original.fiveHourUsedPercent)
        XCTAssertEqual(restored.publishedAt, original.publishedAt)
        XCTAssertEqual(restored.modelWeeklyLimits, original.modelWeeklyLimits)
        XCTAssertEqual(restored.extraUsage, original.extraUsage)
        XCTAssertEqual(restored.account, original.account)
    }

    func testRestartSnapshotRejectsEmptySharedPayload() {
        XCTAssertNil(ClaudeUsageCore.snapshot(fromSharedPayload: [:]))
    }

    func testRestartSnapshotLabelsLegacyPayloadWithoutSource() throws {
        let restored = try XCTUnwrap(ClaudeUsageCore.snapshot(fromSharedPayload: [
            "weeklyUsedPercent": 25,
            "fetchedAt": "1970-01-01T00:16:40.000Z"
        ]))

        XCTAssertEqual(restored.quotaSource, "legacy-ccmb-cache")

        let previouslyRepublished = try XCTUnwrap(ClaudeUsageCore.snapshot(fromSharedPayload: [
            "source": "unknown",
            "weeklyUsedPercent": 25,
            "fetchedAt": "1970-01-01T00:16:40.000Z"
        ]))
        XCTAssertEqual(previouslyRepublished.quotaSource, "legacy-ccmb-cache")
    }

    func testMergeKeepsPreferredAccountAndBackfillsWhenNil() {
        let preferredAccount = ClaudeAccountInfo(email: "preferred@example.com", organizationName: nil, organizationUUID: nil)
        let fallbackAccount = ClaudeAccountInfo(email: "fallback@example.com", organizationName: "Fallback Org", organizationUUID: nil)

        let preferredWithAccount = makeSnapshot(account: preferredAccount)
        let fallbackWithAccount = makeSnapshot(account: fallbackAccount)
        XCTAssertEqual(
            ClaudeUsageCore.merge(preferred: preferredWithAccount, fallback: fallbackWithAccount).account,
            preferredAccount
        )

        let preferredWithoutAccount = makeSnapshot(account: nil)
        XCTAssertEqual(
            ClaudeUsageCore.merge(preferred: preferredWithoutAccount, fallback: fallbackWithAccount).account,
            fallbackAccount
        )
    }

    func testWithAccountReplacesOnlyAccountField() {
        let snapshot = makeSnapshot(weeklyUsedPercent: 20, fiveHourUsedPercent: 40)
        let account = ClaudeAccountInfo(email: "user@example.com", organizationName: nil, organizationUUID: nil)

        let updated = snapshot.withAccount(account)

        XCTAssertEqual(updated.account, account)
        XCTAssertEqual(updated.weeklyUsedPercent, 20)
        XCTAssertEqual(updated.fiveHourUsedPercent, 40)
    }
}

final class ClaudeOAuthSecurityRegressionTests: XCTestCase {
    func testClaudeUsageNoLongerRunsClaudeCLIOrReadsSetupTokenFile() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/CodexCreditMenuBar/ClaudeUsagePanel.swift")
            .standardized
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("ClaudeAuthenticationClient"))
        XCTAssertFalse(source.contains("claude-oauth-token"))
        XCTAssertFalse(source.contains("setup-token"))
    }

#if false // Removed legacy token-file resolver tests kept temporarily for diff history.
    func testInitialTokenResolutionPrefersKeychainToken() {
        let resolution = ClaudeOAuthTokenCore.resolveInitialToken(
            keychainResult: .token("keychain-token"),
            fileToken: "file-token"
        )
        XCTAssertEqual(resolution, .token("keychain-token"))
    }

    func testInitialTokenResolutionFallsBackToFileTokenWhenKeychainUnreadable() {
        let withFileToken = ClaudeOAuthTokenCore.resolveInitialToken(
            keychainResult: .unreadable,
            fileToken: "file-token"
        )
        XCTAssertEqual(withFileToken, .token("file-token"))

        let withoutFileToken = ClaudeOAuthTokenCore.resolveInitialToken(
            keychainResult: .unreadable,
            fileToken: nil
        )
        XCTAssertEqual(withoutFileToken, .keychainUnreadable)
    }

    func testInitialTokenResolutionFallsBackToFileTokenWhenKeychainNotFound() {
        let withFileToken = ClaudeOAuthTokenCore.resolveInitialToken(
            keychainResult: .notFound,
            fileToken: "file-token"
        )
        XCTAssertEqual(withFileToken, .token("file-token"))

        let withoutFileToken = ClaudeOAuthTokenCore.resolveInitialToken(
            keychainResult: .notFound,
            fileToken: nil
        )
        XCTAssertEqual(withoutFileToken, .noCredential)
    }

    func testAuthenticationFailureEntersCooldownOnHTTP401And403() {
        let baseTime = Date(timeIntervalSince1970: 1_000)
        let state401 = ClaudeOAuthTokenCore.transition(
            onHTTPStatus: 401,
            currentState: .token("valid-token"),
            now: baseTime,
            cooldown: 600
        )
        XCTAssertEqual(state401, .authenticationFailed(retryAt: Date(timeIntervalSince1970: 1_600)))

        let state403 = ClaudeOAuthTokenCore.transition(
            onHTTPStatus: 403,
            currentState: .token("valid-token"),
            now: baseTime,
            cooldown: 600
        )
        XCTAssertEqual(state403, .authenticationFailed(retryAt: Date(timeIntervalSince1970: 1_600)))
    }

    func testNonAuthenticationHTTPStatusPreservesCurrentTokenState() {
        let state200 = ClaudeOAuthTokenCore.transition(
            onHTTPStatus: 200,
            currentState: .token("valid-token")
        )
        XCTAssertEqual(state200, .token("valid-token"))

        let state429 = ClaudeOAuthTokenCore.transition(
            onHTTPStatus: 429,
            currentState: .token("valid-token")
        )
        XCTAssertEqual(state429, .token("valid-token"))

        let state500 = ClaudeOAuthTokenCore.transition(
            onHTTPStatus: 500,
            currentState: .token("valid-token")
        )
        XCTAssertEqual(state500, .token("valid-token"))
    }

    func testAuthenticationCooldownDoesNotInvokeResolverBeforeRetryTime() {
        let retryAt = Date(timeIntervalSince1970: 1_600)
        let beforeRetryTime = Date(timeIntervalSince1970: 1_599)
        var resolveCount = 0
        let (resolved, newCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .authenticationFailed(retryAt: retryAt),
            now: beforeRetryTime
        ) {
            resolveCount += 1
            return .token("should-not-be-called")
        }

        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(resolved, .authenticationFailed(retryAt: retryAt))
        XCTAssertEqual(newCached, .authenticationFailed(retryAt: retryAt))
    }

    func testAuthenticationCooldownInvokesResolverAndAdoptsNewTokenAtOrAfterRetryTime() {
        let retryAt = Date(timeIntervalSince1970: 1_600)

        // At exact retry time
        var atResolveCount = 0
        let (atResolved, atNewCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .authenticationFailed(retryAt: retryAt),
            now: Date(timeIntervalSince1970: 1_600)
        ) {
            atResolveCount += 1
            return .token("rotated-token-at")
        }
        XCTAssertEqual(atResolveCount, 1)
        XCTAssertEqual(atResolved, .token("rotated-token-at"))
        XCTAssertEqual(atNewCached, .token("rotated-token-at"))

        // After retry time
        var afterResolveCount = 0
        let (afterResolved, afterNewCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .authenticationFailed(retryAt: retryAt),
            now: Date(timeIntervalSince1970: 1_700)
        ) {
            afterResolveCount += 1
            return .token("rotated-token-after")
        }
        XCTAssertEqual(afterResolveCount, 1)
        XCTAssertEqual(afterResolved, .token("rotated-token-after"))
        XCTAssertEqual(afterNewCached, .token("rotated-token-after"))
    }

    func testCachedTokenNeverRetriesResolution() {
        var resolveCount = 0
        let (resolved, newCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .token("existing-token")
        ) {
            resolveCount += 1
            return .token("new-token")
        }

        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(resolved, .token("existing-token"))
        XCTAssertEqual(newCached, .token("existing-token"))
    }

    /// A missing/unreadable credential file is retried on every subsequent
    /// due fetch (no restart required), since resolution is file-only and
    /// re-reading the file costs nothing beyond the existing fetch cadence.
    /// This mirrors the observed bug: CCMB showed a stale "갱신 실패: Claude
    /// Code 실행" state until relaunch, even after the credential file
    /// became readable again.
    func testCachedMissingOrUnreadableCredentialRetriesOnNextResolution() {
        var resolveCount = 0
        let (unreadableResolved, unreadableCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .keychainUnreadable
        ) {
            resolveCount += 1
            return .token("recovered-token")
        }
        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(unreadableResolved, .token("recovered-token"))
        XCTAssertEqual(unreadableCached, .token("recovered-token"))

        let (noCredResolved, noCredCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .noCredential
        ) {
            resolveCount += 1
            return .token("recovered-token")
        }
        XCTAssertEqual(resolveCount, 2)
        XCTAssertEqual(noCredResolved, .token("recovered-token"))
        XCTAssertEqual(noCredCached, .token("recovered-token"))
    }

    /// If the credential file is still missing/unreadable on the retry, the
    /// same failure state is re-cached (not a crash, not silently latched
    /// forever) so the panel keeps surfacing the failure until it's fixed.
    func testCachedMissingOrUnreadableCredentialStaysFailedIfStillUnresolved() {
        let (unreadableResolved, unreadableCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .keychainUnreadable
        ) {
            .keychainUnreadable
        }
        XCTAssertEqual(unreadableResolved, .keychainUnreadable)
        XCTAssertEqual(unreadableCached, .keychainUnreadable)

        let (noCredResolved, noCredCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .noCredential
        ) {
            .noCredential
        }
        XCTAssertEqual(noCredResolved, .noCredential)
        XCTAssertEqual(noCredCached, .noCredential)
    }

    func testUncachedStateInvokesResolutionOnceAndCachesResult() {
        var resolveCount = 0
        let (resolved, newCached) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: nil
        ) {
            resolveCount += 1
            return .token("resolved-token")
        }

        XCTAssertEqual(resolveCount, 1)
        XCTAssertEqual(resolved, .token("resolved-token"))
        XCTAssertEqual(newCached, .token("resolved-token"))
    }
#endif
}

final class ClaudeOAuthUsageParsingTests: XCTestCase {
    /// Guards against reintroducing an in-process Keychain query for
    /// `Claude Code-credentials`. Even a non-interactive `SecItemCopyMatching`
    /// lookup was observed to still present Keychain's legacy
    /// application-access-control dialog in the signed installed app, so
    /// CCMB must never call it for this item — statically checking the
    /// source is the only way to prove the call site itself is gone, since a
    /// runtime test would need the very Keychain item this test forbids
    /// reading.
    func testSourceNeverQueriesKeychainForClaudeCodeCredentials() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/CodexCreditMenuBar/ClaudeUsagePanel.swift")
            .standardized
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Matches the call form, not the API name in this test's own
        // explanatory comment or the source file's doc comment about why the
        // call was removed.
        XCTAssertFalse(source.contains("SecItemCopyMatching("))
        XCTAssertFalse(source.contains("kSecClassGenericPassword"))
        XCTAssertFalse(source.contains("import Security"))
        XCTAssertFalse(source.contains("import LocalAuthentication"))
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    func testResponseWithoutCoreQuotaIsNotAcceptedAsAUsageSuccess() {
        XCTAssertNil(ClaudeOAuthUsageClient.parse(data(#"{"limits":[]}"#)))
        XCTAssertNil(ClaudeOAuthUsageClient.parse(data(#"{"five_hour":null,"seven_day":null}"#)))
    }

    func testLegacyOpusAndSonnetWeeklyLimitsParseInOrder() throws {
        let json = """
        {
            "five_hour": {"utilization": 10, "resets_at": "2026-08-18T10:00:00.000000+00:00"},
            "seven_day": {"utilization": 20, "resets_at": "2026-08-24T00:00:00.000000+00:00"},
            "seven_day_opus": {"utilization": 55, "resets_at": "2026-08-24T00:00:00.000000+00:00"},
            "seven_day_sonnet": {"usage": 33, "resets_at": "2026-08-24T00:00:00.000000+00:00"}
        }
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))

        XCTAssertEqual(snapshot.weeklyUsedPercent, 20)
        XCTAssertEqual(snapshot.modelWeeklyLimits.map(\.modelName), ["Opus", "Sonnet"])
        XCTAssertEqual(snapshot.modelWeeklyLimits[0].usedPercent, 55)
        XCTAssertNotNil(snapshot.modelWeeklyLimits[0].resetsAt)
        XCTAssertEqual(snapshot.modelWeeklyLimits[1].usedPercent, 33)
    }

    func testDynamicModelScopedLimitsPreserveOrderAndExcludeNonModelEntries() throws {
        let json = """
        {
            "five_hour": {"utilization": 5},
            "seven_day": {"utilization": 12},
            "limits": [
                {"kind": "session", "group": "session", "percent": 40, "is_active": true},
                {"kind": "weekly", "group": "model", "percent": 61, "resets_at": "2026-08-24T00:00:00.000000+00:00", "is_active": true, "scope": {"model": {"display_name": "Opus 4.1"}}},
                {"kind": "weekly", "group": "model", "percent": 22, "resets_at": "2026-08-24T00:00:00.000000+00:00", "is_active": true, "scope": {"model": {"display_name": "Sonnet 4.5"}}},
                {"kind": "weekly", "group": "global", "percent": 30, "is_active": true},
                {"kind": "weekly", "group": "model", "percent": 5, "resets_at": "2026-08-24T00:00:00.000000+00:00", "is_active": true, "scope": {"model": {"display_name": "Haiku 4.5"}}}
            ]
        }
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))

        XCTAssertEqual(snapshot.modelWeeklyLimits.map(\.modelName), ["Opus 4.1", "Sonnet 4.5", "Haiku 4.5"])
        XCTAssertEqual(snapshot.modelWeeklyLimits.map(\.usedPercent), [61, 22, 5])
    }

    func testAbsentOptionalDataYieldsEmptyModelLimitsAndNilExtraUsage() throws {
        let json = """
        {"five_hour": {"utilization": 5}, "seven_day": {"utilization": 12}}
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))

        XCTAssertTrue(snapshot.modelWeeklyLimits.isEmpty)
        XCTAssertNil(snapshot.extraUsage)
        XCTAssertEqual(snapshot.fiveHourUsedPercent, 5)
        XCTAssertEqual(snapshot.weeklyUsedPercent, 12)
    }

    func testMalformedLimitsAndExtraUsageDoNotFailTheMainResponse() throws {
        let json = """
        {
            "five_hour": {"utilization": 5},
            "seven_day": {"utilization": 12},
            "limits": "not-an-array",
            "extra_usage": "not-an-object"
        }
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))

        XCTAssertEqual(snapshot.fiveHourUsedPercent, 5)
        XCTAssertEqual(snapshot.weeklyUsedPercent, 12)
        XCTAssertTrue(snapshot.modelWeeklyLimits.isEmpty)
        XCTAssertNil(snapshot.extraUsage)
    }

    func testExtraUsageNormalizesMonthlyLimitAndUsedCreditsVariant() throws {
        let json = """
        {
            "five_hour": {"utilization": 5},
            "seven_day": {"utilization": 12},
            "extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 450, "currency": "USD"}
        }
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))
        let extraUsage = try XCTUnwrap(snapshot.extraUsage)

        XCTAssertEqual(extraUsage.limitCents, 2000)
        XCTAssertEqual(extraUsage.usedCents, 450)
        XCTAssertEqual(extraUsage.currency, "USD")
    }

    func testExtraUsageNormalizesMonthlyCreditLimitAndBalanceCentsVariant() throws {
        let json = """
        {
            "five_hour": {"utilization": 5},
            "seven_day": {"utilization": 12},
            "extra_usage": {"is_enabled": true, "monthly_credit_limit": 1500, "balance_cents": 800, "spend_limit_currency": "EUR"}
        }
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))
        let extraUsage = try XCTUnwrap(snapshot.extraUsage)

        XCTAssertEqual(extraUsage.limitCents, 1500)
        XCTAssertEqual(extraUsage.usedCents, 800)
        XCTAssertEqual(extraUsage.currency, "EUR")
    }

    func testExtraUsageNormalizesSpendLimitAmountCentsVariantWithoutUsage() throws {
        let json = """
        {
            "five_hour": {"utilization": 5},
            "seven_day": {"utilization": 12},
            "extra_usage": {"is_enabled": true, "spend_limit_amount_cents": 999}
        }
        """
        let snapshot = try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(json)))
        let extraUsage = try XCTUnwrap(snapshot.extraUsage)

        XCTAssertEqual(extraUsage.limitCents, 999)
        XCTAssertNil(extraUsage.usedCents)
    }

    func testExtraUsageDisabledOrMissingFlagYieldsNil() throws {
        let disabledJSON = """
        {"five_hour": {"utilization": 5}, "seven_day": {"utilization": 12}, "extra_usage": {"is_enabled": false, "monthly_limit": 2000}}
        """
        let missingFlagJSON = """
        {"five_hour": {"utilization": 5}, "seven_day": {"utilization": 12}, "extra_usage": {"monthly_limit": 2000}}
        """
        let emptyEnabledJSON = """
        {"five_hour": {"utilization": 5}, "seven_day": {"utilization": 12}, "extra_usage": {"is_enabled": true}}
        """

        XCTAssertNil(try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(disabledJSON))).extraUsage)
        XCTAssertNil(try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(missingFlagJSON))).extraUsage)
        XCTAssertNil(try XCTUnwrap(ClaudeOAuthUsageClient.parse(data(emptyEnabledJSON))).extraUsage)
    }

    func testParseProfileReadsEmailAndOrganization() throws {
        let json = """
        {
            "account": {"email": "user@example.com"},
            "organization": {"name": "Acme", "uuid": "org-1"}
        }
        """
        let account = try XCTUnwrap(ClaudeOAuthUsageClient.parseProfile(data(json)))

        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.organizationName, "Acme")
        XCTAssertEqual(account.organizationUUID, "org-1")
    }

    func testParseProfileFallsBackToEmailAddressField() throws {
        let json = """
        {"account": {"email_address": "fallback@example.com"}}
        """
        let account = try XCTUnwrap(ClaudeOAuthUsageClient.parseProfile(data(json)))

        XCTAssertEqual(account.email, "fallback@example.com")
        XCTAssertNil(account.organizationName)
    }

    func testParseProfileReturnsNilWhenNoUsableIdentityFieldsPresent() {
        let json = """
        {"account": {}, "organization": {}}
        """
        XCTAssertNil(ClaudeOAuthUsageClient.parseProfile(data(json)))
    }

    func testParseProfileReturnsNilForMalformedResponse() {
        XCTAssertNil(ClaudeOAuthUsageClient.parseProfile(data("not-json")))
    }
}

final class ClaudeUsageFetchOutcomeTests: XCTestCase {
    func testSkippedOutcomesCarryNoDiagnosticOrLabel() {
        let retryAt = Date(timeIntervalSince1970: 1_000)
        let skips: [ClaudeUsageFetchOutcome] = [
            .skippedInFlight,
            .skippedThrottled(retryAt: retryAt),
            .skippedRateLimitBackoff(retryAt: retryAt)
        ]
        for outcome in skips {
            XCTAssertNil(outcome.diagnosticDescription, "\(outcome) is a routine skip, not a failure")
            XCTAssertNil(outcome.staleReasonLabel)
        }
    }

    func testFailureOutcomesAlwaysCarryADiagnosticAndLabel() {
        let failures: [ClaudeUsageFetchOutcome] = [
            .noCredential,
            .rateLimited(retryAt: Date(timeIntervalSince1970: 1_000)),
            .authenticationRecoveryFailed,
            .httpFailure(status: 401),
            .httpFailure(status: 500),
            .transportFailure,
            .decodeFailure
        ]
        for outcome in failures {
            XCTAssertNotNil(outcome.diagnosticDescription, "\(outcome) must log a reason")
            XCTAssertNotNil(outcome.staleReasonLabel, "\(outcome) must surface an actionable label")
        }
    }

    func testAuthenticationRecoveryFailureExplainsTheNextBeginnerAction() {
        XCTAssertEqual(
            ClaudeUsageFetchOutcome.authenticationRecoveryFailed.staleReasonLabel,
            "아래 버튼으로 Claude 다시 연결"
        )
    }

    func testRateLimitRetryAtIsOnlyCarriedByTheBackoffCases() {
        let retryAt = Date(timeIntervalSince1970: 1_234)
        XCTAssertEqual(ClaudeUsageFetchOutcome.rateLimited(retryAt: retryAt).rateLimitRetryAt, retryAt)
        XCTAssertEqual(ClaudeUsageFetchOutcome.skippedRateLimitBackoff(retryAt: retryAt).rateLimitRetryAt, retryAt)
        XCTAssertNil(ClaudeUsageFetchOutcome.httpFailure(status: 429).rateLimitRetryAt)
        XCTAssertNil(ClaudeUsageFetchOutcome.skippedThrottled(retryAt: retryAt).rateLimitRetryAt)
    }

    // MARK: - Per-refresh consumption strip

    func testConsumptionFollowsTheMetricDirection() {
        // Credits count down.
        XCTAssertEqual(UsageConsumptionCore.consumption(previous: 100, current: 97.5, isDecreasing: true), 2.5)
        // Used-percentage counts up.
        XCTAssertEqual(UsageConsumptionCore.consumption(previous: 40, current: 43, isDecreasing: false), 3)
    }

    func testQuotaResetIsReportedAsZeroConsumptionNotAsASpike() {
        // Weekly % rolling back to 0 at reset.
        XCTAssertEqual(UsageConsumptionCore.consumption(previous: 96, current: 0, isDecreasing: false), 0)
        // A credit top-up.
        XCTAssertEqual(UsageConsumptionCore.consumption(previous: 5, current: 1_000, isDecreasing: true), 0)
    }

    func testAmountTitleKeepsSmallReadingsVisible() {
        // A refresh that burned a hundredth of a credit must not render as "0".
        XCTAssertEqual(UsageConsumptionCore.amountTitle(0.0042, unit: ""), "0.0042")
        XCTAssertEqual(UsageConsumptionCore.amountTitle(1.5, unit: " 크레딧"), "1.5 크레딧")
        XCTAssertEqual(UsageConsumptionCore.amountTitle(2, unit: "%"), "2%")
        XCTAssertEqual(UsageConsumptionCore.amountTitle(0, unit: "%"), "0%")
        // 100.00 must survive trailing-zero trimming intact.
        XCTAssertEqual(UsageConsumptionCore.amountTitle(100, unit: ""), "100")
    }

    /// A positive percent delta too small for one decimal (e.g. a nearly-idle
    /// refresh) must not collapse to the same "0%" a true zero reads as —
    /// the chart bar it labels is visibly non-empty.
    func testAmountTitlePercentNeverFlattensPositiveDeltaToZero() {
        XCTAssertEqual(UsageConsumptionCore.amountTitle(0.02, unit: "%"), "<0.1%")
        XCTAssertEqual(UsageConsumptionCore.amountTitle(0.04, unit: "%"), "<0.1%")
        XCTAssertEqual(UsageConsumptionCore.amountTitle(0, unit: "%"), "0%")
        XCTAssertEqual(UsageConsumptionCore.amountTitle(0.3, unit: "%"), "0.3%")
    }

    func testNewestSampleIsDrawnInTheLeftmostSlot() {
        // Samples are stored oldest-first, so the last one is the newest and it
        // must land in slot 0.
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 0, sampleCount: 3), 2)
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 1, sampleCount: 3), 1)
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 2, sampleCount: 3), 0)
        // Beyond the history: placeholder slots, not a wrapped or clamped index.
        XCTAssertNil(UsageConsumptionCore.sampleIndex(forSlot: 3, sampleCount: 3))
        XCTAssertNil(UsageConsumptionCore.sampleIndex(forSlot: 23, sampleCount: 3))
        XCTAssertNil(UsageConsumptionCore.sampleIndex(forSlot: 0, sampleCount: 0))
        XCTAssertNil(UsageConsumptionCore.sampleIndex(forSlot: -1, sampleCount: 3))
        // A full window fills every slot.
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 0, sampleCount: 40), 39)
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 39, sampleCount: 40), 0)
    }

    func testBarFractionsScaleToTheWindowPeak() {
        XCTAssertEqual(UsageConsumptionCore.barFractions([1, 2, 4]), [0.25, 0.5, 1])
        // An all-quiet window must not divide by zero.
        XCTAssertEqual(UsageConsumptionCore.barFractions([0, 0]), [0, 0])
        XCTAssertEqual(UsageConsumptionCore.barFractions([]), [])
    }

    func testTrackerFirstReadingOnlyEstablishesABaseline() {
        var tracker = UsageConsumptionTracker()
        tracker.record(reading: 100, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "credit")
        XCTAssertTrue(tracker.amounts.isEmpty)
        tracker.record(reading: 98, at: Date(timeIntervalSince1970: 60), isDecreasing: true, metricKey: "credit")
        XCTAssertEqual(tracker.amounts, [2])
    }

    func testTrackerIgnoresRepeatsOfDataItHasAlreadySeen() {
        var tracker = UsageConsumptionTracker()
        let first = Date(timeIntervalSince1970: 0)
        let second = Date(timeIntervalSince1970: 60)
        tracker.record(reading: 100, at: first, isDecreasing: true, metricKey: "credit")
        tracker.record(reading: 98, at: second, isDecreasing: true, metricKey: "credit")
        // A menu open or file-watcher hit re-applies the same snapshot; it must
        // not add a second bar for one refresh.
        tracker.record(reading: 98, at: second, isDecreasing: true, metricKey: "credit")
        tracker.record(reading: 98, at: first, isDecreasing: true, metricKey: "credit")
        XCTAssertEqual(tracker.amounts, [2])
    }

    func testTrackerIgnoresMissingReadings() {
        var tracker = UsageConsumptionTracker()
        tracker.record(reading: 100, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "credit")
        tracker.record(reading: nil, at: Date(timeIntervalSince1970: 60), isDecreasing: true, metricKey: "credit")
        XCTAssertTrue(tracker.amounts.isEmpty)
        // The baseline survives the gap, so the next real reading differences
        // against 100 rather than starting over.
        tracker.record(reading: 95, at: Date(timeIntervalSince1970: 120), isDecreasing: true, metricKey: "credit")
        XCTAssertEqual(tracker.amounts, [5])
    }

    func testTrackerKeepsOnlyTheMostRecentSamples() {
        var tracker = UsageConsumptionTracker()
        for step in 0...60 {
            tracker.record(
                reading: Double(step),
                at: Date(timeIntervalSince1970: TimeInterval(step) * 60),
                isDecreasing: false,
                metricKey: "weekly"
            )
        }
        XCTAssertEqual(tracker.amounts.count, 40)
        XCTAssertEqual(tracker.amounts.allSatisfy { $0 == 1 }, true)
    }

    func testSwitchingMetricsResetsTheStripInsteadOfDrawingOneHugeBar() {
        var tracker = UsageConsumptionTracker()
        tracker.record(reading: 10, at: Date(timeIntervalSince1970: 0), isDecreasing: false, metricKey: "weekly")
        tracker.record(reading: 20, at: Date(timeIntervalSince1970: 60), isDecreasing: false, metricKey: "weekly")
        XCTAssertEqual(tracker.amounts, [10])

        // Weekly is exhausted and Codex starts billing credits: a 1105-credit
        // balance differenced against a 20% reading would be nonsense.
        tracker.record(reading: 1_105, at: Date(timeIntervalSince1970: 120), isDecreasing: true, metricKey: "credit")
        XCTAssertTrue(tracker.amounts.isEmpty)
        tracker.record(reading: 1_100, at: Date(timeIntervalSince1970: 180), isDecreasing: true, metricKey: "credit")
        XCTAssertEqual(tracker.amounts, [5])
    }

    func testTrackerSurvivesAnEncodeDecodeRoundTrip() throws {
        var tracker = UsageConsumptionTracker()
        tracker.record(reading: 100, at: Date(timeIntervalSince1970: 0), isDecreasing: true, metricKey: "credit")
        tracker.record(reading: 97, at: Date(timeIntervalSince1970: 60), isDecreasing: true, metricKey: "credit")

        let data = try JSONEncoder().encode(tracker)
        var restored = try JSONDecoder().decode(UsageConsumptionTracker.self, from: data)
        XCTAssertEqual(restored, tracker)

        // The restored baseline and dedupe clock must survive too, or the first
        // refresh after launch would drop a bar or duplicate one.
        restored.record(reading: 97, at: Date(timeIntervalSince1970: 60), isDecreasing: true, metricKey: "credit")
        XCTAssertEqual(restored.amounts, [3])
        restored.record(reading: 96, at: Date(timeIntervalSince1970: 120), isDecreasing: true, metricKey: "credit")
        XCTAssertEqual(restored.amounts, [3, 1])
    }

    func testRateLimitedOutcomeReportsThe429Label() {
        XCTAssertEqual(
            ClaudeUsageFetchOutcome.rateLimited(retryAt: Date(timeIntervalSince1970: 1_000)).staleReasonLabel,
            "요청 제한(429)"
        )
    }

    func testDiagnosticsAndLabelsNeverIncludeSecretMaterial() throws {
        let diagnostic = try XCTUnwrap(ClaudeUsageFetchOutcome.httpFailure(status: 401).diagnosticDescription)
        XCTAssertFalse(diagnostic.lowercased().contains("bearer"))
        XCTAssertFalse(diagnostic.lowercased().contains("token"))

        let rateLimitedDiagnostic = try XCTUnwrap(
            ClaudeUsageFetchOutcome.rateLimited(retryAt: Date(timeIntervalSince1970: 1_000)).diagnosticDescription
        )
        XCTAssertFalse(rateLimitedDiagnostic.lowercased().contains("bearer"))
        XCTAssertFalse(rateLimitedDiagnostic.lowercased().contains("token"))

        let recoveryDiagnostic = try XCTUnwrap(
            ClaudeUsageFetchOutcome.authenticationRecoveryFailed.diagnosticDescription
        )
        XCTAssertFalse(recoveryDiagnostic.lowercased().contains("bearer"))
        XCTAssertFalse(recoveryDiagnostic.lowercased().contains("refresh_token"))
    }
}

final class NASFutureTimestampTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1792051200)

    // MARK: - Snapshot generated_at tests

    func testSnapshotGeneratedAtNowPlus60Accepted() {
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                NASSnapshotFixtures.codex(),
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ]
        ).replacingOccurrences(of: "\"generated_at\": 1792051200", with: "\"generated_at\": 1792051260")

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.generatedAt, Date(timeIntervalSince1970: 1792051260))
    }

    func testSnapshotGeneratedAtNowPlus61Rejected() {
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                NASSnapshotFixtures.codex(),
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ]
        ).replacingOccurrences(of: "\"generated_at\": 1792051200", with: "\"generated_at\": 1792051261")

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNil(parsed)
    }

    // MARK: - Service fetched_at tests

    func testServiceFetchedAtNowPlus60Accepted() {
        let codexService = NASSnapshotFixtures.service(
            "codex",
            provider: "codex",
            accountRef: nil,
            ok: true,
            fetchedAt: "1792051260",
            items: NASSnapshotFixtures.codexItems
        )
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                codexService,
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ]
        )

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.codex.fetchedAt, Date(timeIntervalSince1970: 1792051260))
        XCTAssertTrue(parsed?.codex.ok == true)
    }

    func testServiceFetchedAtNowPlus61SchemaInvalidIsolatedOthersGood() {
        let badCodexService = NASSnapshotFixtures.service(
            "codex",
            provider: "codex",
            accountRef: nil,
            ok: true,
            fetchedAt: "1792051261",
            items: NASSnapshotFixtures.codexItems
        )
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                badCodexService,
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ]
        )

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNotNil(parsed)
        // Codex card was isolated as schemaInvalid
        XCTAssertEqual(parsed?.codex, NASServiceEntry.schemaInvalid(.codex))
        // Other services remain good
        XCTAssertTrue(parsed?.claude.ok == true)
        XCTAssertTrue(parsed?.gemini.ok == true)
        XCTAssertTrue(parsed?.gemini2.ok == true)
    }

    // MARK: - Future reset timestamp accepted

    func testFutureResetTimestampStillAccepted() {
        let farFutureResetItems = """
        [
            {"name": "codex", "window": "session", "window_minutes": 300, "remaining_percent": 90, "resets_at": 1892055000},
            {"name": "codex", "window": "weekly", "window_minutes": 10080, "remaining_percent": 70, "resets_at": 1992400000}
        ]
        """
        let codexService = NASSnapshotFixtures.service(
            "codex",
            provider: "codex",
            accountRef: nil,
            ok: true,
            fetchedAt: "1792051200",
            items: farFutureResetItems
        )
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                codexService,
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ]
        )

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.codex.ok == true)
        XCTAssertEqual(parsed?.codex.items.first?.resetsAt, Date(timeIntervalSince1970: 1892055000))
    }

    // MARK: - History generatedAt and point.at tests

    private func makeHistoryJSON(
        generatedAtMillis: Double,
        points: [[String: Any]]
    ) -> [String: Any] {
        var series: [String: Any] = [:]
        for key in NASHistoryV2.seriesKeys {
            let unit = key == "codexCredits" ? "credits" : "percent"
            let mappedPoints = points.map { point -> [String: Any] in
                var p = point
                p["unit"] = unit
                return p
            }
            series[key] = [
                "identityGeneration": NSNull(),
                "points": mappedPoints
            ]
        }
        return [
            "schemaVersion": 2,
            "generatedAt": generatedAtMillis,
            "source": "nas",
            "series": series
        ]
    }

    func testHistoryGeneratedAtNowPlus300Accepted() {
        let obj = makeHistoryJSON(
            generatedAtMillis: (fixedNow.timeIntervalSince1970 + 300) * 1000,
            points: [
                [
                    "at": fixedNow.timeIntervalSince1970 * 1000,
                    "consumed": 10.0,
                    "unit": "percent",
                    "segmentId": "seg-1"
                ]
            ]
        )
        let parsed = NASHistoryV2Core.parse(object: obj, now: fixedNow)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.generatedAt, Date(timeIntervalSince1970: fixedNow.timeIntervalSince1970 + 300))
    }

    func testHistoryGeneratedAtNowPlus301Rejected() {
        let obj = makeHistoryJSON(
            generatedAtMillis: (fixedNow.timeIntervalSince1970 + 301) * 1000,
            points: [
                [
                    "at": fixedNow.timeIntervalSince1970 * 1000,
                    "consumed": 10.0,
                    "unit": "percent",
                    "segmentId": "seg-1"
                ]
            ]
        )
        let parsed = NASHistoryV2Core.parse(object: obj, now: fixedNow)
        XCTAssertNil(parsed)
    }

    func testHistoryPointAtNowPlus300Accepted() {
        let obj = makeHistoryJSON(
            generatedAtMillis: fixedNow.timeIntervalSince1970 * 1000,
            points: [
                [
                    "at": (fixedNow.timeIntervalSince1970 + 300) * 1000,
                    "consumed": 10.0,
                    "unit": "percent",
                    "segmentId": "seg-1"
                ]
            ]
        )
        let parsed = NASHistoryV2Core.parse(object: obj, now: fixedNow)
        XCTAssertNotNil(parsed)
    }

    func testHistoryPointAtNowPlus301Rejected() {
        let obj = makeHistoryJSON(
            generatedAtMillis: fixedNow.timeIntervalSince1970 * 1000,
            points: [
                [
                    "at": (fixedNow.timeIntervalSince1970 + 301) * 1000,
                    "consumed": 10.0,
                    "unit": "percent",
                    "segmentId": "seg-1"
                ]
            ]
        )
        let parsed = NASHistoryV2Core.parse(object: obj, now: fixedNow)
        XCTAssertNil(parsed)
    }

    func testHistoryDuplicatePointTimesRejected() {
        let timestampMillis = fixedNow.timeIntervalSince1970 * 1000
        let obj = makeHistoryJSON(
            generatedAtMillis: timestampMillis,
            points: [
                [
                    "at": timestampMillis,
                    "consumed": 10.0,
                    "unit": "percent",
                    "segmentId": "seg-1"
                ],
                [
                    "at": timestampMillis,
                    "consumed": 20.0,
                    "unit": "percent",
                    "segmentId": "seg-2"
                ]
            ]
        )
        let parsed = NASHistoryV2Core.parse(object: obj, now: fixedNow)
        XCTAssertNil(parsed)
    }

    func testHistoryNonAscendingPointTimesRejected() {
        let timestampMillis = fixedNow.timeIntervalSince1970 * 1000
        let obj = makeHistoryJSON(
            generatedAtMillis: timestampMillis,
            points: [
                [
                    "at": timestampMillis,
                    "consumed": 10.0,
                    "unit": "percent",
                    "segmentId": "seg-1"
                ],
                [
                    "at": timestampMillis - 1000,
                    "consumed": 20.0,
                    "unit": "percent",
                    "segmentId": "seg-2"
                ]
            ]
        )
        let parsed = NASHistoryV2Core.parse(object: obj, now: fixedNow)
        XCTAssertNil(parsed)
    }
}

final class NASBackendPhaseTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1792051200)

    func testBackendUppercaseRunningPhaseNormalizedAndCardAttributed() {
        let runningHost = NASSnapshotFixtures.host(
            id: "host-gemini2",
            run: "\"run-101\"",
            account: "\"account2\"",
            phase: "\"RUNNING\"",
            changedAt: "1792051100",
            heartbeatAt: "1792051180",
            returnState: "null"
        )
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                NASSnapshotFixtures.codex(),
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ],
            executionHosts: "[\(runningHost)]",
            autoSwitch: "true"
        )

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNotNil(parsed)
        guard let snapshot = parsed else { return }

        let hosts = snapshot.hostStatus.hosts(for: .gemini2)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.phase, "running")

        var state = NASFourServiceState()
        state.apply(snapshot)
        // .gemini2 is itself the running account, so its own card shows no
        // "other account is running" line; only the idle .gemini card would.
        let footer = NASHostStatusPresentation.footerLines(
            for: .gemini2,
            state: state,
            source: .nas
        )
        XCTAssertEqual(footer, [])
        XCTAssertEqual(
            NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas),
            []
        )
    }

    func testKnownUppercasePhasesNormalizedToLowercase() {
        let cases: [(raw: String, expected: String)] = [
            ("RUNNING", "running"),
            ("PREPARED", "prepared"),
            ("READY", "ready"),
            ("FINISHING", "finishing"),
            ("COMMITTED", "committed"),
            ("REJECTED", "rejected"),
            ("ABORTED", "aborted")
        ]

        for (raw, expected) in cases {
            let hostJSON: [String: Any] = [
                "host_id": "host-test",
                "execution_account": "account1",
                "phase": raw
            ]
            let host = NASExecutionHost.parse(hostJSON)
            XCTAssertNotNil(host, "Phase \(raw) should be parsed")
            XCTAssertEqual(host?.phase, expected)
        }
    }

    func testUnknownUppercasePhaseRejected() {
        let hostJSON: [String: Any] = [
            "host_id": "host-test",
            "execution_account": "account1",
            "phase": "UNKNOWN_PHASE"
        ]
        XCTAssertNil(NASExecutionHost.parse(hostJSON))
    }

    func testIdleNullExecutionAccountDoesNotEraseQuotaCard() {
        let idleHost = """
        {"host_id": "idle-host", "run_id": null, "execution_account": null, "phase": "IDLE"}
        """
        let envelope = NASSnapshotFixtures.envelope(
            services: [
                NASSnapshotFixtures.codex(),
                NASSnapshotFixtures.claude(),
                NASSnapshotFixtures.gemini(),
                NASSnapshotFixtures.gemini2()
            ],
            executionHosts: "[\(idleHost)]"
        )

        let parsed = NASSnapshotV2Core.parse(NASSnapshotFixtures.data(envelope), now: fixedNow)
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.gemini.ok == true)
        XCTAssertTrue(parsed?.gemini2.ok == true)
        XCTAssertEqual(parsed?.hostStatus.hosts.count, 0)
    }
}

final class NASExecutionHostGuardTests: XCTestCase {
    private typealias F = NASSnapshotFixtures
    private let fixedNow = Date(timeIntervalSince1970: 1792051200)

    func testDuplicateHostIDsRetainFirstValidOnly() throws {
        let host1 = F.host(
            id: "duplicate-host-id",
            run: "\"run-1\"",
            account: "\"account1\"",
            phase: "\"running\"",
            changedAt: "1792051000",
            heartbeatAt: "1792051150"
        )
        let host2 = F.host(
            id: "duplicate-host-id",
            run: "\"run-2\"",
            account: "\"account2\"",
            phase: "\"running\"",
            changedAt: "1792051050",
            heartbeatAt: "1792051160"
        )
        let envelope = F.envelope(
            services: [
                F.codex(),
                F.claude(),
                F.gemini(),
                F.gemini2()
            ],
            executionHosts: "[\(host1), \(host2)]"
        )

        let parsed = try XCTUnwrap(NASSnapshotV2Core.parse(F.data(envelope), now: fixedNow))
        XCTAssertEqual(parsed.hostStatus.hosts.count, 1)
        XCTAssertEqual(parsed.hostStatus.hosts(for: .gemini).count, 1)
        XCTAssertEqual(parsed.hostStatus.hosts(for: .gemini2).count, 0)
    }

    func testIdleNullExecutionAccountConfirmedSurvivesParseCacheAndFooter() throws {
        let idleHost = F.host(
            id: "idle-worker-1",
            run: "null",
            account: "null",
            phase: "\"idle\"",
            changedAt: "1792051000",
            heartbeatAt: "1792051150",
            returnState: "\"confirmed\""
        )
        let envelope = F.envelope(
            services: [
                F.codex(),
                F.claude(),
                F.gemini(),
                F.gemini2()
            ],
            executionHosts: "[\(idleHost)]",
            autoSwitch: "true"
        )

        let parsed = try XCTUnwrap(NASSnapshotV2Core.parse(F.data(envelope), now: fixedNow))
        XCTAssertEqual(parsed.hostStatus.hosts.count, 1)
        let host = try XCTUnwrap(parsed.hostStatus.hosts.first)
        XCTAssertEqual(host.phase, "idle")
        XCTAssertNil(host.executionAccount)
        XCTAssertEqual(host.returnState, "confirmed")
        XCTAssertTrue(parsed.hostStatus.hosts(for: .gemini).isEmpty)
        XCTAssertTrue(parsed.hostStatus.hosts(for: .gemini2).isEmpty)

        var state = NASFourServiceState()
        state.apply(parsed)
        let restored = try XCTUnwrap(NASFourServiceState.decodeCache(try XCTUnwrap(state.encodedCache())))
        XCTAssertEqual(restored.hostStatus?.hosts.count, 1)
        XCTAssertEqual(restored.hostStatus?.hosts.first?.phase, "idle")
        XCTAssertEqual(restored.hostStatus?.hosts.first?.returnState, "confirmed")

        // An idle, account-less host never names a running account, so
        // neither card's compact footer shows anything for it.
        let footerGemini = NASHostStatusPresentation.footerLines(for: .gemini, state: state, source: .nas)
        let footerGemini2 = NASHostStatusPresentation.footerLines(for: .gemini2, state: state, source: .nas)
        XCTAssertEqual(footerGemini, [])
        XCTAssertEqual(footerGemini2, [])
    }

    func testRunningAccount2KeepsFixedSecondary() throws {
        let runningHost = F.host(
            id: "host-gemini2-secondary",
            run: "\"run-202\"",
            account: "\"account2\"",
            phase: "\"RUNNING\"",
            changedAt: "1792051100",
            heartbeatAt: "1792051180",
            returnState: "null"
        )
        let envelope = F.envelope(
            services: [
                F.codex(),
                F.claude(),
                F.gemini(),
                F.gemini2()
            ],
            executionHosts: "[\(runningHost)]",
            autoSwitch: "true"
        )

        let parsed = try XCTUnwrap(NASSnapshotV2Core.parse(F.data(envelope), now: fixedNow))
        let gemini2Hosts = parsed.hostStatus.hosts(for: .gemini2)
        XCTAssertEqual(gemini2Hosts.count, 1)
        XCTAssertEqual(gemini2Hosts.first?.phase, "running")
        XCTAssertTrue(parsed.hostStatus.hosts(for: .gemini).isEmpty)
    }

    func testRunningNullAccountDroppedQuotaAccepted() throws {
        let runningNullAccount = F.host(
            id: "running-null-account",
            run: "\"run-303\"",
            account: "null",
            phase: "\"running\""
        )
        let envelope = F.envelope(
            services: [
                F.codex(),
                F.claude(),
                F.gemini(),
                F.gemini2()
            ],
            executionHosts: "[\(runningNullAccount)]"
        )

        let parsed = try XCTUnwrap(NASSnapshotV2Core.parse(F.data(envelope), now: fixedNow))
        XCTAssertTrue(parsed.gemini.ok)
        XCTAssertTrue(parsed.gemini2.ok)
        XCTAssertEqual(parsed.hostStatus.hosts.count, 0)
    }

    func testHostStatusTimestampValidationNumericSeconds() {
        let now = Date().timeIntervalSince1970
        let validHost: [String: Any] = [
            "host_id": "ok",
            "execution_account": "account1",
            "phase": "RUNNING"
        ]

        for field in ["state_changed_at", "last_heartbeat_at"] {
            var badHost = validHost
            badHost["host_id"] = "bad_future"
            badHost[field] = now + 120.0

            var parsed = NASHostStatus.parse(executionHosts: [validHost, badHost], autoSwitchEnabled: true)
            XCTAssertEqual(parsed.hosts.count, 1)
            XCTAssertEqual(parsed.hosts.first?.hostID, "ok")

            var nearFutureHost = validHost
            nearFutureHost["host_id"] = "near_future"
            nearFutureHost[field] = now + 30.0

            parsed = NASHostStatus.parse(executionHosts: [validHost, nearFutureHost], autoSwitchEnabled: true)
            XCTAssertEqual(parsed.hosts.count, 2)
            let ids = Set(parsed.hosts.map { $0.hostID })
            XCTAssertTrue(ids.contains("ok"))
            XCTAssertTrue(ids.contains("near_future"))
        }
    }

    func testHostStatusPendingReturnState() {
        let host: [String: Any] = [
            "host_id": "idle",
            "execution_account": NSNull(),
            "run_id": NSNull(),
            "phase": "idle",
            "return_state": "pending"
        ]
        let status = NASHostStatus.parse(executionHosts: [host], autoSwitchEnabled: false, autoSwitchAvailable: false)
        XCTAssertNil(status.autoSwitchEnabled)
        XCTAssertEqual(status.hosts.count, 1)
        XCTAssertEqual(status.hosts.first?.returnState, "pending")
        XCTAssertNil(status.hosts.first?.executionAccount)
    }
}
