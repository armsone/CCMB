import Foundation

struct RateLimitSnapshot {
    let accountID: String?
    let usedPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
    let resetCredits: Int?
    let creditBalance: Double?
    let detailedCreditsReturned: Bool
    let updatedAt: Date
}

enum UsageCore {
    static let usageHelperMarker = "# CCMB_USAGE_HELPER_VERSION="

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

    static func creditDetailTitle(from balance: Double) -> String {
        let value = String(format: "%.2f", balance)
        return value
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    static func canReplaceUsageHelper(existingContents: String?) -> Bool {
        guard let existingContents else { return true }
        return existingContents.contains(usageHelperMarker)
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

/// Mirrors the JSON that `claude-statusline.sh` writes from Claude Code's
/// official statusLine payload (`rate_limits`, `context_window`, `cost`).
struct ClaudeUsageSnapshot {
    let model: String?
    let weeklyUsedPercent: Double?
    let weeklyResetsAt: Date?
    let fiveHourUsedPercent: Double?
    let fiveHourResetsAt: Date?
    let contextUsedPercent: Double?
    let contextRemainingPercent: Double?
    let sessionCostUSD: Double?
    let publishedAt: Date?
}

enum ClaudeUsageCore {
    static func remainingPercent(from usedPercent: Double?) -> Double? {
        guard let usedPercent else { return nil }
        return min(max(100 - usedPercent, 0), 100)
    }

    static func costTitle(from cost: Double?) -> String? {
        guard let cost, cost > 0 else { return nil }
        if cost < 0.01 {
            return String(format: "$%.4f", cost)
        }
        return String(format: "$%.2f", cost)
    }

    static func isFresh(publishedAt: Date?, now: Date, freshForSeconds: TimeInterval) -> Bool {
        guard let publishedAt else { return false }
        return now.timeIntervalSince(publishedAt) <= freshForSeconds
    }
}
