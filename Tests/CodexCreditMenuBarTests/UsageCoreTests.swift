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
        XCTAssertEqual(UsageCore.normalizedRefreshInterval(42), 30)
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

    private func makeSnapshot(
        model: String? = nil,
        weeklyUsedPercent: Double? = nil,
        fiveHourUsedPercent: Double? = nil,
        contextRemainingPercent: Double? = nil,
        sessionCostUSD: Double? = nil,
        publishedAt: Date? = nil
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
            publishedAt: publishedAt
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
        XCTAssertEqual(result?.fiveHourUsedPercent, 40, "older snapshot's own fields still backfill what the newer one lacks")
    }

    func testMergingCacheSnapshotHandlesNilInputs() {
        let live = makeSnapshot(fiveHourUsedPercent: 40, publishedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNil(ClaudeUsageCore.mergingCacheSnapshot(current: nil, cache: nil))
        XCTAssertEqual(ClaudeUsageCore.mergingCacheSnapshot(current: live, cache: nil)?.fiveHourUsedPercent, 40)
        XCTAssertEqual(ClaudeUsageCore.mergingCacheSnapshot(current: nil, cache: live)?.fiveHourUsedPercent, 40)
    }
}

final class ClaudeUsageFetchOutcomeTests: XCTestCase {
    func testSkippedOutcomesCarryNoDiagnosticOrLabel() {
        for outcome: ClaudeUsageFetchOutcome in [.skippedInFlight, .skippedThrottled] {
            XCTAssertNil(outcome.diagnosticDescription)
            XCTAssertNil(outcome.staleReasonLabel)
        }
    }

    func testFailureOutcomesAlwaysCarryADiagnosticAndLabel() {
        let failures: [ClaudeUsageFetchOutcome] = [
            .noCredential,
            .keychainCredentialUnreadable,
            .httpFailure(status: 401),
            .httpFailure(status: 429),
            .httpFailure(status: 500),
            .transportFailure,
            .decodeFailure
        ]
        for outcome in failures {
            XCTAssertNotNil(outcome.diagnosticDescription, "\(outcome) must log a reason")
            XCTAssertNotNil(outcome.staleReasonLabel, "\(outcome) must surface an actionable label")
        }
    }

    func testDiagnosticsAndLabelsNeverIncludeSecretMaterial() throws {
        let diagnostic = try XCTUnwrap(ClaudeUsageFetchOutcome.httpFailure(status: 401).diagnosticDescription)
        XCTAssertFalse(diagnostic.lowercased().contains("bearer"))
        XCTAssertFalse(diagnostic.lowercased().contains("token"))
    }
}
