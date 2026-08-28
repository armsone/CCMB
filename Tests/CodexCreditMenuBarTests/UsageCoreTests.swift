import XCTest
import LocalAuthentication
import Security
@testable import CodexCreditMenuBar

final class UsageCoreTests: XCTestCase {
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
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(nil), 30)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(60), 60)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(180), 180)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(600), 600)
        // An unknown stored value falls back to the default, not to whatever
        // the first option happens to be.
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(42), 30)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(30), 30)

        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(nil), 600)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(300), 600)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(600), 600)
        XCTAssertEqual(UsageCore.normalizedClaudeRefreshInterval(42), 600)

        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(nil), 300)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(120), 120)
        XCTAssertEqual(UsageCore.normalizedGeminiRefreshInterval(42), 300)
    }

    func testRefreshIntervalOptionsCoverTheAdvertisedCadences() {
        XCTAssertEqual(UsageCore.refreshIntervalOptions, [0, 30, 60, 180, 300, 600])
        XCTAssertEqual(UsageCore.claudeRefreshIntervalOptions, [0, 600, 900, 1_800, 3_600])
        XCTAssertEqual(UsageCore.geminiRefreshIntervalOptions, [0, 120, 300, 600, 900, 1_800])
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

    func testCodexPayloadIncludesSparkWeeklyUsage() {
        let now = Date(timeIntervalSince1970: 1_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
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

        XCTAssertEqual(payload["sparkRemainingPercent"] as? Double, 80)
        XCTAssertEqual(payload["sparkUsedPercent"] as? Double, 20)
        XCTAssertEqual(payload["sparkWindowDurationMins"] as? Int, 1_440)
        XCTAssertEqual(payload["sparkResetsAt"] as? String, formatter.string(from: sparkResetsAt))
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

    func testRefreshedCodexPayloadPreservesSparkFields() {
        let stored = UsageCore.codexPayload(
            from: makeRateLimitSnapshot(
                usedPercent: 10,
                sparkUsedPercent: 20,
                sparkWindowDurationMinutes: 1_440,
                sparkResetsAt: Date(timeIntervalSince1970: 1_200),
                updatedAt: Date(timeIntervalSince1970: 1_000)
            ),
            freshForSeconds: 45,
            now: Date(timeIntervalSince1970: 1_000)
        )

        let refreshed = UsageCore.refreshedCodexPayload(stored, now: Date(timeIntervalSince1970: 1_100))

        XCTAssertEqual(refreshed["sparkRemainingPercent"] as? Double, 80)
        XCTAssertEqual(refreshed["sparkUsedPercent"] as? Double, 20)
        XCTAssertEqual(refreshed["sparkWindowDurationMins"] as? Int, 1_440)
        XCTAssertTrue((refreshed["sparkResetsAt"] as? String)?.contains("1970-01-01T00:20:00") == true)
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

final class ClaudeOAuthTokenResolutionTests: XCTestCase {
    func testClaudeCredentialRefreshIsStrictlyNonInteractive() {
        XCTAssertEqual(
            ClaudeAuthenticationClient.refreshArguments,
            [
                "-p",
                "--safe-mode",
                "--no-session-persistence",
                "--tools", "",
                "--model", "haiku",
                "--max-turns", "1",
                "Reply only OK."
            ]
        )
        XCTAssertFalse(ClaudeAuthenticationClient.refreshArguments.contains("auth"))
        XCTAssertFalse(ClaudeAuthenticationClient.refreshArguments.contains("login"))
        XCTAssertFalse(ClaudeAuthenticationClient.refreshArguments.contains("setup-token"))
    }

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

    func testCachedMissingOrUnreadableCredentialNeverRetriesResolution() {
        var resolveCount = 0
        let (unreadableResolved, _) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .keychainUnreadable
        ) {
            resolveCount += 1
            return .token("retry")
        }
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(unreadableResolved, .keychainUnreadable)

        let (noCredResolved, _) = ClaudeOAuthTokenCore.resolveToken(
            cachedState: .noCredential
        ) {
            resolveCount += 1
            return .token("retry")
        }
        XCTAssertEqual(resolveCount, 0)
        XCTAssertEqual(noCredResolved, .noCredential)
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
}

final class ClaudeOAuthUsageParsingTests: XCTestCase {
    func testPassiveKeychainLookupCannotPresentAuthenticationUI() {
        let query = ClaudeOAuthUsageClient.keychainTokenQuery()
        let context = query[kSecUseAuthenticationContext as String] as? LAContext

        XCTAssertEqual(context?.interactionNotAllowed, true)
        // `...UIFail` is explicitly documented to fail immediately instead
        // of presenting authentication UI when this single-item lookup needs
        // user interaction.
        // Compare the exported CFString value directly so the test itself
        // does not introduce a deprecation warning for this legacy-Keychain
        // compatibility safeguard.
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, "u_AuthUIF")
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials")
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertNil(query[kSecReturnAttributes as String])
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
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
            .keychainCredentialUnreadable,
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
            "Claude Code 실행 또는 다시 로그인"
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
