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

    static func menuBarCodexTitle(usedPercent: Double?, creditBalance: Double?) -> String? {
        if let usedPercent {
            let remaining = remainingPercent(from: usedPercent)
            if remaining > 0 {
                return "\(Int(remaining.rounded()))%"
            }
            if let credit = creditTitle(from: creditBalance) {
                return credit
            }
            return "0%"
        }

        return creditTitle(from: creditBalance)
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

    /// Nested `codex` object mirroring `ClaudeUsageCore.sharedPayload`'s
    /// shape, so shared-file consumers can read Codex and Claude with the
    /// same status/weekly/account/freshness concepts.
    static func codexPayload(from snapshot: RateLimitSnapshot?, freshForSeconds: Int, now: Date = Date()) -> [String: Any] {
        guard let snapshot else {
            return [
                "status": "unavailable",
                "weeklyRemainingPercent": NSNull(),
                "weeklyUsedPercent": NSNull(),
                "weeklyResetsAt": NSNull(),
                "account": NSNull(),
                "creditBalance": NSNull(),
                "windowDurationMins": NSNull(),
                "resetCredits": NSNull(),
                "fetchedAt": NSNull(),
                "ageSeconds": NSNull(),
                "freshForSeconds": freshForSeconds,
                "fresh": false
            ]
        }

        let ageSeconds = max(0, Int(now.timeIntervalSince(snapshot.updatedAt)))
        return [
            "status": snapshot.usedPercent == nil ? "partial" : "ok",
            "weeklyRemainingPercent": snapshot.usedPercent.map(remainingPercent) ?? NSNull(),
            "weeklyUsedPercent": snapshot.usedPercent ?? NSNull(),
            "weeklyResetsAt": snapshot.resetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "account": snapshot.accountID ?? NSNull(),
            "creditBalance": snapshot.creditBalance ?? NSNull(),
            "windowDurationMins": snapshot.windowDurationMinutes ?? NSNull(),
            "resetCredits": snapshot.resetCredits ?? NSNull(),
            "fetchedAt": sharedISO8601Formatter.string(from: snapshot.updatedAt),
            "ageSeconds": ageSeconds,
            "freshForSeconds": freshForSeconds,
            "fresh": ageSeconds <= max(0, freshForSeconds)
        ]
    }

    /// Recomputes a stored `codex` payload's `ageSeconds`/`fresh` from its
    /// own `fetchedAt`/`freshForSeconds`, the same role `refreshedSharedPayload`
    /// plays for the Claude side of a cache read.
    static func refreshedCodexPayload(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var output = payload
        let fetchedAt = (payload["fetchedAt"] as? String).flatMap(sharedISO8601Formatter.date(from:))
        let freshForSeconds = (payload["freshForSeconds"] as? NSNumber)?.intValue ?? 45
        let ageSeconds = fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        output["ageSeconds"] = ageSeconds ?? NSNull()
        output["fresh"] = ageSeconds.map { $0 <= max(0, freshForSeconds) } ?? false
        return output
    }

    private static let sharedISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// A single model-scoped seven-day limit row (e.g. Opus, Sonnet), from either
/// the legacy `seven_day_opus`/`seven_day_sonnet` fields or a dynamic
/// model-scoped entry in `limits[]`. Order mirrors the API response order.
struct ClaudeModelWeeklyLimit: Sendable, Equatable {
    let modelName: String
    let usedPercent: Double?
    let resetsAt: Date?
}

/// Optional pay-as-you-go "Extra Usage" spend information. Present only when
/// the account has it enabled and the response carries usable numbers.
/// `limitCents`/`usedCents` mirror the API's cents-denominated values as-is.
struct ClaudeExtraUsage: Sendable, Equatable {
    let limitCents: Double?
    let usedCents: Double?
    let currency: String?
}

/// Account identity from `/api/oauth/profile`, fetched at most once per
/// process/token after a successful usage fetch. A failed or skipped
/// profile fetch simply leaves this `nil` — it never affects usage success.
struct ClaudeAccountInfo: Sendable, Equatable {
    let email: String?
    let organizationName: String?
    let organizationUUID: String?
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
    let modelWeeklyLimits: [ClaudeModelWeeklyLimit]
    let extraUsage: ClaudeExtraUsage?
    let account: ClaudeAccountInfo?

    init(
        model: String? = nil,
        weeklyUsedPercent: Double? = nil,
        weeklyResetsAt: Date? = nil,
        fiveHourUsedPercent: Double? = nil,
        fiveHourResetsAt: Date? = nil,
        contextUsedPercent: Double? = nil,
        contextRemainingPercent: Double? = nil,
        sessionCostUSD: Double? = nil,
        publishedAt: Date? = nil,
        modelWeeklyLimits: [ClaudeModelWeeklyLimit] = [],
        extraUsage: ClaudeExtraUsage? = nil,
        account: ClaudeAccountInfo? = nil
    ) {
        self.model = model
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.contextUsedPercent = contextUsedPercent
        self.contextRemainingPercent = contextRemainingPercent
        self.sessionCostUSD = sessionCostUSD
        self.publishedAt = publishedAt
        self.modelWeeklyLimits = modelWeeklyLimits
        self.extraUsage = extraUsage
        self.account = account
    }

    /// Returns a copy with `account` replaced — used to merge in a profile
    /// fetch's result without reconstructing every other field by hand.
    func withAccount(_ account: ClaudeAccountInfo?) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            model: model,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyResetsAt: weeklyResetsAt,
            fiveHourUsedPercent: fiveHourUsedPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            contextUsedPercent: contextUsedPercent,
            contextRemainingPercent: contextRemainingPercent,
            sessionCostUSD: sessionCostUSD,
            publishedAt: publishedAt,
            modelWeeklyLimits: modelWeeklyLimits,
            extraUsage: extraUsage,
            account: account
        )
    }
}

enum ClaudeUsageCore {
    static let sharedFreshForSeconds: TimeInterval = 300
    static let minimumRequestIntervalSeconds: TimeInterval = 90

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

    /// Whether a Claude usage fetch should be skipped as too soon after the
    /// last one. The caller supplies the greater of the configured refresh
    /// cadence and `minimumRequestIntervalSeconds`, including manual refresh,
    /// so this unofficial endpoint is never polled more often than is safe.
    static func shouldThrottleFetch(minimumInterval: TimeInterval, lastFetchDate: Date?, now: Date) -> Bool {
        guard minimumInterval > 0, let lastFetchDate else { return false }
        // The repeating timer has scheduling leeway, so requiring the full
        // interval can reject a tick that arrives a fraction early and defer
        // Claude until the next cycle (effectively doubling its cadence).
        let timerTolerance = min(1, minimumInterval * 0.05)
        return now.timeIntervalSince(lastFetchDate) < minimumInterval - timerTolerance
    }

    /// Conservative fallback when a 429 response omits (or sends an
    /// unparseable) `Retry-After` — long enough to stop hammering the
    /// endpoint, short enough to recover within a couple of Codex's own
    /// refresh cycles.
    static let defaultRateLimitBackoffSeconds: TimeInterval = 90

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// Parses a `Retry-After` header value as either delta-seconds
    /// (`"120"`) or an HTTP-date (`"Wed, 21 Oct 2026 07:28:00 GMT"`),
    /// returning seconds from `now` until retry is allowed. `nil` when the
    /// header is missing or neither form parses.
    static func parseRetryAfterSeconds(_ headerValue: String?, now: Date) -> TimeInterval? {
        guard let headerValue else { return nil }
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let deltaSeconds = TimeInterval(trimmed), deltaSeconds >= 0 {
            return deltaSeconds
        }
        if let date = httpDateFormatter.date(from: trimmed) {
            return max(0, date.timeIntervalSince(now))
        }
        return nil
    }

    /// Retry-After value to actually back off by. A shorter server hint is
    /// raised to the same conservative floor so the client never resumes an
    /// already-limited endpoint too aggressively.
    static func rateLimitBackoffSeconds(retryAfterHeader: String?, now: Date) -> TimeInterval {
        max(
            parseRetryAfterSeconds(retryAfterHeader, now: now) ?? defaultRateLimitBackoffSeconds,
            defaultRateLimitBackoffSeconds
        )
    }

    /// Whether a Claude usage fetch should be skipped entirely because a
    /// prior 429's backoff window hasn't elapsed yet.
    static func shouldSkipRateLimitBackoff(retryAt: Date?, now: Date) -> Bool {
        guard let retryAt else { return false }
        return now < retryAt
    }

    /// Concise Korean label for a 429 backoff, e.g. `요청 제한(429) · 42초 후 재시도`.
    /// Recomputed from `now` on every call so the same stored `retryAt` keeps
    /// counting down correctly across repeated UI refreshes without a new fetch.
    static func rateLimitRetryLabel(retryAt: Date, now: Date) -> String {
        let remainingSeconds = max(0, Int(ceil(retryAt.timeIntervalSince(now))))
        return "요청 제한(429) · \(remainingSeconds)초 후 재시도"
    }

    static func sharedPayload(from snapshot: ClaudeUsageSnapshot?, now: Date = Date()) -> [String: Any] {
        guard let snapshot else {
            return [
                "status": "unavailable",
                "weeklyRemainingPercent": NSNull(),
                "weeklyUsedPercent": NSNull(),
                "weeklyResetsAt": NSNull(),
                "fiveHourRemainingPercent": NSNull(),
                "fiveHourUsedPercent": NSNull(),
                "fiveHourResetsAt": NSNull(),
                "model": NSNull(),
                "fetchedAt": NSNull(),
                "ageSeconds": NSNull(),
                "freshForSeconds": Int(sharedFreshForSeconds),
                "fresh": false,
                "modelWeeklyLimits": [],
                "extraUsage": NSNull(),
                "account": NSNull()
            ]
        }

        let ageSeconds = snapshot.publishedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        return [
            "status": snapshot.weeklyUsedPercent == nil && snapshot.fiveHourUsedPercent == nil ? "partial" : "ok",
            "weeklyRemainingPercent": remainingPercent(from: snapshot.weeklyUsedPercent) ?? NSNull(),
            "weeklyUsedPercent": snapshot.weeklyUsedPercent ?? NSNull(),
            "weeklyResetsAt": snapshot.weeklyResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "fiveHourRemainingPercent": remainingPercent(from: snapshot.fiveHourUsedPercent) ?? NSNull(),
            "fiveHourUsedPercent": snapshot.fiveHourUsedPercent ?? NSNull(),
            "fiveHourResetsAt": snapshot.fiveHourResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "model": snapshot.model ?? NSNull(),
            "fetchedAt": snapshot.publishedAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "ageSeconds": ageSeconds ?? NSNull(),
            "freshForSeconds": Int(sharedFreshForSeconds),
            "fresh": isFresh(
                publishedAt: snapshot.publishedAt,
                now: now,
                freshForSeconds: sharedFreshForSeconds
            ),
            "modelWeeklyLimits": snapshot.modelWeeklyLimits.map { limit -> [String: Any] in
                [
                    "model": limit.modelName,
                    "usedPercent": limit.usedPercent ?? NSNull(),
                    "remainingPercent": remainingPercent(from: limit.usedPercent) ?? NSNull(),
                    "resetsAt": limit.resetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull()
                ]
            },
            "extraUsage": snapshot.extraUsage.map { extraUsage -> [String: Any] in
                [
                    "limitCents": extraUsage.limitCents ?? NSNull(),
                    "usedCents": extraUsage.usedCents ?? NSNull(),
                    "currency": extraUsage.currency ?? NSNull()
                ]
            } ?? NSNull(),
            "account": snapshot.account.map { account -> [String: Any] in
                [
                    "email": account.email ?? NSNull(),
                    "organizationName": account.organizationName ?? NSNull(),
                    "organizationUUID": account.organizationUUID ?? NSNull()
                ]
            } ?? NSNull()
        ]
    }

    static func refreshedSharedPayload(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var output = payload
        let fetchedAt = (payload["fetchedAt"] as? String).flatMap(sharedISO8601Formatter.date(from:))
        let freshForSeconds = (payload["freshForSeconds"] as? NSNumber)?.doubleValue
            ?? sharedFreshForSeconds
        output["ageSeconds"] = fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? NSNull()
        output["fresh"] = isFresh(
            publishedAt: fetchedAt,
            now: now,
            freshForSeconds: freshForSeconds
        )
        return output
    }

    /// Restores the last successful account-usage snapshot from CCMB's own
    /// shared JSON so an app restart does not temporarily replace good OAuth
    /// values with an hours-old statusLine-only cache while a 90-second
    /// safety/backoff window is active.
    static func snapshot(fromSharedPayload payload: [String: Any]) -> ClaudeUsageSnapshot? {
        func number(_ key: String) -> Double? {
            (payload[key] as? NSNumber)?.doubleValue
        }
        func date(_ key: String) -> Date? {
            (payload[key] as? String).flatMap(sharedISO8601Formatter.date(from:))
        }

        let modelWeeklyLimits = (payload["modelWeeklyLimits"] as? [[String: Any]] ?? []).compactMap { item -> ClaudeModelWeeklyLimit? in
            guard let modelName = item["model"] as? String, !modelName.isEmpty else { return nil }
            return ClaudeModelWeeklyLimit(
                modelName: modelName,
                usedPercent: (item["usedPercent"] as? NSNumber)?.doubleValue,
                resetsAt: (item["resetsAt"] as? String).flatMap(sharedISO8601Formatter.date(from:))
            )
        }

        let extraUsage = (payload["extraUsage"] as? [String: Any]).map {
            ClaudeExtraUsage(
                limitCents: ($0["limitCents"] as? NSNumber)?.doubleValue,
                usedCents: ($0["usedCents"] as? NSNumber)?.doubleValue,
                currency: $0["currency"] as? String
            )
        }
        let account = (payload["account"] as? [String: Any]).map {
            ClaudeAccountInfo(
                email: $0["email"] as? String,
                organizationName: $0["organizationName"] as? String,
                organizationUUID: $0["organizationUUID"] as? String
            )
        }

        let snapshot = ClaudeUsageSnapshot(
            model: payload["model"] as? String,
            weeklyUsedPercent: number("weeklyUsedPercent"),
            weeklyResetsAt: date("weeklyResetsAt"),
            fiveHourUsedPercent: number("fiveHourUsedPercent"),
            fiveHourResetsAt: date("fiveHourResetsAt"),
            publishedAt: date("fetchedAt"),
            modelWeeklyLimits: modelWeeklyLimits,
            extraUsage: extraUsage,
            account: account
        )

        guard snapshot.publishedAt != nil
            || snapshot.weeklyUsedPercent != nil
            || snapshot.fiveHourUsedPercent != nil
            || snapshot.model != nil
            || snapshot.account != nil
        else { return nil }
        return snapshot
    }

    private static let sharedISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

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
            publishedAt: preferred.publishedAt ?? fallback.publishedAt,
            modelWeeklyLimits: preferred.modelWeeklyLimits.isEmpty ? fallback.modelWeeklyLimits : preferred.modelWeeklyLimits,
            extraUsage: preferred.extraUsage ?? fallback.extraUsage,
            account: preferred.account ?? fallback.account
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
