import XCTest
@testable import CodexCreditMenuBar

final class UsageCoreTests: XCTestCase {
    func testRemainingPercentIsClamped() {
        XCTAssertEqual(UsageCore.remainingPercent(from: -5), 100)
        XCTAssertEqual(UsageCore.remainingPercent(from: 25), 75)
        XCTAssertEqual(UsageCore.remainingPercent(from: 120), 0)
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
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(nil), 180)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(0), 0)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(60), 60)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(180), 180)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(600), 600)
        // An unknown stored value falls back to the default, not to whatever
        // the first option happens to be.
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(42), 180)
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(30), 30)
    }

    func testRefreshIntervalOptionsCoverTheAdvertisedCadences() {
        XCTAssertEqual(UsageCore.refreshIntervalOptions, [0, 30, 60, 180, 300, 600])
        XCTAssertTrue(UsageCore.refreshIntervalOptions.contains(UsageCore.defaultRefreshIntervalSeconds))
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
        usedPercent: Double? = nil,
        windowDurationMinutes: Int? = nil,
        resetsAt: Date? = nil,
        resetCredits: Int? = nil,
        creditBalance: Double? = nil,
        detailedCreditsReturned: Bool = false,
        updatedAt: Date
    ) -> RateLimitSnapshot {
        RateLimitSnapshot(
            accountID: accountID,
            usedPercent: usedPercent,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt,
            resetCredits: resetCredits,
            creditBalance: creditBalance,
            detailedCreditsReturned: detailedCreditsReturned,
            updatedAt: updatedAt
        )
    }

    func testCodexPayloadForMissingSnapshotIsExplicitlyUnavailable() {
        let payload = UsageCore.codexPayload(from: nil, freshForSeconds: 45)

        XCTAssertEqual(payload["status"] as? String, "unavailable")
        XCTAssertTrue(payload["weeklyRemainingPercent"] is NSNull)
        XCTAssertTrue(payload["account"] is NSNull)
        XCTAssertEqual(payload["fresh"] as? Bool, false)
        XCTAssertEqual(payload["freshForSeconds"] as? Int, 45)
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
}

final class ClaudeUsageCoreTests: XCTestCase {
    func testRemainingPercentIsClampedAndNilSafe() {
        XCTAssertEqual(ClaudeUsageCore.remainingPercent(from: 28), 72)
        XCTAssertEqual(ClaudeUsageCore.remainingPercent(from: -5), 100)
        XCTAssertEqual(ClaudeUsageCore.remainingPercent(from: 150), 0)
        XCTAssertNil(ClaudeUsageCore.remainingPercent(from: nil))
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
        XCTAssertEqual(ClaudeUsageCore.rateLimitBackoffSeconds(retryAfterHeader: "120", now: now), 120)
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
            "요청 제한(429) · 90초 후 재시도"
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitRetryLabel(retryAt: retryAt, now: Date(timeIntervalSince1970: 1_089.4)),
            "요청 제한(429) · 1초 후 재시도"
        )
        XCTAssertEqual(
            ClaudeUsageCore.rateLimitRetryLabel(retryAt: retryAt, now: Date(timeIntervalSince1970: 1_200)),
            "요청 제한(429) · 0초 후 재시도"
        )
    }

    func testSharedPayloadIncludesClaudeWeeklyAndSessionRemainingUsage() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = ClaudeUsageSnapshot(
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
        XCTAssertEqual(payload["weeklyRemainingPercent"] as? Double, 72)
        XCTAssertEqual(payload["fiveHourRemainingPercent"] as? Double, 60)
        XCTAssertEqual(payload["ageSeconds"] as? Int, 100)
        XCTAssertEqual(payload["fresh"] as? Bool, true)
        XCTAssertEqual(payload["model"] as? String, "claude-opus")
        XCTAssertNotNil(payload["weeklyResetsAt"] as? String)
    }

    func testSharedPayloadMakesMissingClaudeUsageExplicit() {
        let payload = ClaudeUsageCore.sharedPayload(from: nil)

        XCTAssertEqual(payload["status"] as? String, "unavailable")
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
    }

    private func makeSnapshot(
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

final class ClaudeOAuthUsageParsingTests: XCTestCase {
    private func data(_ json: String) -> Data {
        Data(json.utf8)
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
        let skips: [ClaudeUsageFetchOutcome] = [.skippedInFlight, .skippedThrottled, .skippedRateLimitBackoff(retryAt: retryAt)]
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

    func testRateLimitRetryAtIsOnlyCarriedByTheBackoffCases() {
        let retryAt = Date(timeIntervalSince1970: 1_234)
        XCTAssertEqual(ClaudeUsageFetchOutcome.rateLimited(retryAt: retryAt).rateLimitRetryAt, retryAt)
        XCTAssertEqual(ClaudeUsageFetchOutcome.skippedRateLimitBackoff(retryAt: retryAt).rateLimitRetryAt, retryAt)
        XCTAssertNil(ClaudeUsageFetchOutcome.httpFailure(status: 429).rateLimitRetryAt)
        XCTAssertNil(ClaudeUsageFetchOutcome.skippedThrottled.rateLimitRetryAt)
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
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 0, sampleCount: 24), 23)
        XCTAssertEqual(UsageConsumptionCore.sampleIndex(forSlot: 23, sampleCount: 24), 0)
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
        for step in 0...30 {
            tracker.record(
                reading: Double(step),
                at: Date(timeIntervalSince1970: TimeInterval(step) * 60),
                isDecreasing: false,
                metricKey: "weekly",
                capacity: 24
            )
        }
        XCTAssertEqual(tracker.amounts.count, 24)
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
    }
}
