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

    /// A present-but-corrupt or unsupported-schema cache must fall back to a
    /// live query the same way a missing cache does, not abort the command.
    static func cacheFallbackReason(cacheExists: Bool, cacheIsCorrupt: Bool) -> String {
        if cacheIsCorrupt { return "corrupt" }
        return cacheExists ? "stale-or-ccmb-not-running" : "missing"
    }

    static func cacheOnlyFailureMessage(cacheIsCorrupt: Bool, path: String) -> String {
        cacheIsCorrupt
            ? "CCMB 공유 파일이 손상되었거나 지원하지 않는 스키마입니다: \(path)"
            : "CCMB 공유 파일이 없습니다: \(path)"
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

    /// Fills any field `preferred` is missing from `fallback`, keeping
    /// `preferred`'s own values (and its `publishedAt`) whenever present.
    /// Used both to backfill statusline-only fields (model/context/session
    /// cost) into a live rate-limit response, and to backfill a live
    /// snapshot's rate-limit fields into a statusline-only cache read.
    static func merge(preferred: ClaudeUsageSnapshot, fallback: ClaudeUsageSnapshot?) -> ClaudeUsageSnapshot {
        guard let fallback else { return preferred }
        return ClaudeUsageSnapshot(
            model: preferred.model ?? fallback.model,
            weeklyUsedPercent: preferred.weeklyUsedPercent ?? fallback.weeklyUsedPercent,
            weeklyResetsAt: preferred.weeklyResetsAt ?? fallback.weeklyResetsAt,
            fiveHourUsedPercent: preferred.fiveHourUsedPercent ?? fallback.fiveHourUsedPercent,
            fiveHourResetsAt: preferred.fiveHourResetsAt ?? fallback.fiveHourResetsAt,
            contextUsedPercent: preferred.contextUsedPercent ?? fallback.contextUsedPercent,
            contextRemainingPercent: preferred.contextRemainingPercent ?? fallback.contextRemainingPercent,
            sessionCostUSD: preferred.sessionCostUSD ?? fallback.sessionCostUSD,
            publishedAt: preferred.publishedAt ?? fallback.publishedAt
        )
    }

    /// Reconciles an in-memory snapshot (which may hold a fresher live
    /// fetch) with a snapshot freshly read from the passive statusline
    /// cache, without ever regressing to the older of the two. Whichever
    /// snapshot has the newer `publishedAt` wins its own fields, and the
    /// older one only backfills fields the newer one lacks.
    static func mergingCacheSnapshot(
        current: ClaudeUsageSnapshot?,
        cache: ClaudeUsageSnapshot?
    ) -> ClaudeUsageSnapshot? {
        guard let cache else { return current }
        guard let current else { return cache }

        let currentDate = current.publishedAt ?? .distantPast
        let cacheDate = cache.publishedAt ?? .distantPast
        return cacheDate > currentDate
            ? merge(preferred: cache, fallback: current)
            : merge(preferred: current, fallback: cache)
    }
}
