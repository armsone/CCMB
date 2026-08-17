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
}
