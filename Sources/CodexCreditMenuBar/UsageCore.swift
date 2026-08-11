import Foundation

struct RateLimitSnapshot {
    let accountID: String?
    let usedPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
    let sparkLimitName: String?
    let sparkUsedPercent: Double?
    let sparkResetsAt: Date?
    let resetCredits: Int?
    let creditBalance: Double?
    let detailedCreditsReturned: Bool
    let updatedAt: Date
}

enum UsageCore {
    static func remainingPercent(from usedPercent: Double) -> Double {
        min(max(100 - usedPercent, 0), 100)
    }

    static func creditTitle(from balance: Double?) -> String? {
        guard let balance, balance > 0 else { return nil }

        if balance < 1 {
            let value = String(format: "%.2f", balance)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
            return value
        }

        return "\(Int(balance.rounded()))"
    }

    static func cacheAgeSeconds(fetchedAt: Date?, now: Date) -> Int {
        guard let fetchedAt else { return Int.max }
        return max(0, Int(now.timeIntervalSince(fetchedAt)))
    }

    static func cacheIsFresh(
        statusOK: Bool,
        processMatches: Bool,
        ageSeconds: Int,
        freshForSeconds: Int
    ) -> Bool {
        statusOK && processMatches && ageSeconds <= max(0, freshForSeconds)
    }

    static func normalizedRefreshInterval(_ seconds: Int?) -> TimeInterval {
        guard let seconds, [0, 30, 60, 300].contains(seconds) else { return 30 }
        return TimeInterval(seconds)
    }
}
