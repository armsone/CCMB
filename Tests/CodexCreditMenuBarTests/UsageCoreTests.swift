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
