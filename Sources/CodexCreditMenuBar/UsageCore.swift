import Foundation

struct RateLimitSnapshot {
    let accountID: String?
    /// Stable app-server `PlanType` identifier (for example `plus` or
    /// `business`). Kept as the protocol value so display wording can evolve
    /// without changing cached usage semantics.
    let planType: String?
    let usedPercent: Double?
    let windowDurationMinutes: Int?
    let resetsAt: Date?
    let resetCredits: Int?
    let creditBalance: Double?
    let sparkUsedPercent: Double?
    let sparkWindowDurationMinutes: Int?
    let sparkResetsAt: Date?
    let detailedCreditsReturned: Bool
    let updatedAt: Date
    /// NAS `credits.unlimited`. Defaulted so the local app-server path,
    /// which has no such flag, keeps constructing snapshots unchanged.
    var creditsUnlimited: Bool = false
}

/// Provider-independent adaptive cadence. Each visible provider owns one
/// instance, so activity in Claude does not unnecessarily accelerate Codex
/// or Gemini. A value change greater than 0.01 immediately returns that
/// provider to fast (30s) monitoring; repeated unchanged reads relax the
/// interval to 120s, then 300s. Callers must only ever pass meaningful usage
/// or account-identity values here (never a poll/fetch timestamp or an
/// `updatedAt` clock), since a value that always differs would pin the
/// policy to `active` forever.
struct SmartRefreshPolicy: Equatable {
    enum Mode: Int, Equatable {
        case active
        case idleShort
        case idleMedium

        var interval: TimeInterval {
            switch self {
            case .active: return 30
            case .idleShort: return 120
            case .idleMedium: return 300
            }
        }

        var unchangedThreshold: Int? {
            switch self {
            case .active: return 3
            case .idleShort: return 6
            case .idleMedium: return nil
            }
        }

        var next: Mode {
            switch self {
            case .active: return .idleShort
            case .idleShort, .idleMedium: return .idleMedium
            }
        }
    }

    private(set) var mode: Mode = .active
    private(set) var unchangedCount = 0
    private(set) var lastValues: [Double?]?
    /// Exact-equality identity tokens (account id/email, reset timestamp as
    /// an unambiguous string), tracked separately from `lastValues` so no
    /// hashing or numeric folding is involved — hashValue is per-process and
    /// can collide, so it must never stand in for identity comparison.
    private(set) var lastIdentityTokens: [String?]?

    var interval: TimeInterval { mode.interval }

    /// Returns true when the effective interval changed. `identityTokens`
    /// are compared with exact string equality (never hashed into
    /// `values`), so a switched account or a confirmed quota reset counts
    /// as activity exactly like a changed usage percentage, with no
    /// collision risk.
    mutating func update(values: [Double?], identityTokens: [String?] = []) -> Bool {
        guard let previousValues = lastValues, let previousIdentityTokens = lastIdentityTokens else {
            lastValues = values
            lastIdentityTokens = identityTokens
            return false
        }
        let valuesChanged = values.count != previousValues.count || zip(values, previousValues).contains { current, old in
            switch (current, old) {
            case let (current?, old?): return abs(current - old) > 0.01
            case (nil, nil): return false
            default: return true
            }
        }
        let identityChanged = identityTokens != previousIdentityTokens
        let changed = valuesChanged || identityChanged
        lastValues = values
        lastIdentityTokens = identityTokens
        if changed {
            let didChangeMode = mode != .active
            mode = .active
            unchangedCount = 0
            return didChangeMode
        }
        unchangedCount += 1
        guard let threshold = mode.unchangedThreshold, unchangedCount >= threshold else { return false }
        mode = mode.next
        unchangedCount = 0
        return true
    }

    mutating func reset() {
        mode = .active
        unchangedCount = 0
        lastValues = nil
        lastIdentityTokens = nil
    }

    /// Formats a reset timestamp as an exact, unambiguous identity token
    /// (epoch seconds), for use in `update(values:identityTokens:)`. Never
    /// pass a poll/fetch timestamp (e.g. `updatedAt`) here — only a
    /// confirmed upstream reset instant.
    static func identityToken(_ date: Date?) -> String? {
        date.map { String($0.timeIntervalSince1970) }
    }

    /// Quota-bucket reset identity token. A fully-unused bucket (`usedIsZero`)
    /// rolls its own reset instant forward on every read even with no real
    /// activity, so it must not contribute to the fingerprint at all. A
    /// used bucket's reset instant can jitter by a second between reads of
    /// the same underlying reset, so it is minute-normalized before
    /// comparison.
    static func quotaResetIdentityToken(_ date: Date?, usedIsZero: Bool) -> String? {
        guard !usedIsZero, let date else { return nil }
        let normalizedSeconds = (date.timeIntervalSince1970 / 60).rounded() * 60
        return String(normalizedSeconds)
    }
}

struct CodexSparkWeeklyWindow: Equatable {
    let usedPercent: Double
    let windowDurationMinutes: Int?
    let resetsAt: Date?
}

enum CodexPlanCore {
    /// User-facing titles for the official app-server `PlanType` enum. Unknown
    /// future values remain hidden instead of being presented as a guessed
    /// product name.
    static func title(for planType: String?) -> String? {
        guard let planType else { return nil }
        switch planType.lowercased() {
        case "free": return "ChatGPT Free"
        case "go": return "ChatGPT Go"
        case "plus": return "ChatGPT Plus"
        case "pro": return "ChatGPT Pro"
        case "prolite": return "ChatGPT Pro Lite"
        case "team": return "ChatGPT Team"
        case "self_serve_business_usage_based": return "ChatGPT Business · 사용량 기반"
        case "business": return "ChatGPT Business"
        case "ent26", "enterprise": return "ChatGPT Enterprise"
        case "enterprise_cbp_usage_based": return "ChatGPT Enterprise · 사용량 기반"
        case "edu": return "ChatGPT Edu"
        default: return nil
        }
    }

    /// Exact keys this switch recognizes, lowercased. Anything else (including
    /// future unknown `planType` values) is hidden rather than guessed.
    static let allowlist: Set<String> = [
        "free", "go", "plus", "pro", "prolite", "team", "self_serve_business_usage_based",
        "business", "ent26", "enterprise", "enterprise_cbp_usage_based", "edu",
    ]
}

/// One bar of a column's consumption strip: how much the tracked metric moved
/// between two consecutive refreshes.
struct UsageConsumptionSample: Codable, Equatable {
    let at: Date
    let amount: Double
}

enum UsageConsumptionCore {
    /// Codex reports a credit balance that counts *down* and a weekly
    /// used-percentage that counts *up*. Both are reported here as positive
    /// consumption so the chart never has to know which meter it is drawing.
    static func consumption(previous: Double, current: Double, isDecreasing: Bool) -> Double {
        let delta = isDecreasing ? previous - current : current - previous
        // A quota reset (weekly % falling back toward 0, a credit top-up) shows
        // up as negative consumption. Report zero: a negative bar is
        // meaningless, and taking the magnitude would draw the reset itself as
        // the largest spike in the window.
        return delta > 0 ? delta : 0
    }

    /// Percentage consumption uses up to one decimal; credit amounts retain their
    /// existing precision, with four decimals for small readings.
    /// Lives here rather than in the app delegate because the hover tooltip in
    /// the chart view needs the same formatting.
    static func amountTitle(_ amount: Double, unit: String) -> String {
        if unit == "%" {
            let clamped = max(0, amount)
            let formatted = String(format: "%.1f%%", clamped)
                .replacingOccurrences(of: ".0%", with: "%")
            // A true zero reads "0%"; a positive delta too small for one
            // decimal (e.g. 0.02%) must not collapse to that same "0%" —
            // the bar it labels is visibly non-empty.
            return (clamped > 0 && formatted == "0%") ? "<0.1%" : formatted
        }
        guard amount > 0 else { return "0\(unit)" }
        let format = amount < 0.01 ? "%.4f" : "%.2f"
        let text = String(format: format, amount)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return "\(text)\(unit)"
    }

    /// Maps a drawing slot to an index into a sample array that is stored
    /// oldest-first.
    ///
    /// Slot 0 is the newest reading, so reading the strip left to right is
    /// reading backwards in time. The strip always draws a fixed number of
    /// slots — it never grows over its first 40 refreshes — and slots past the
    /// end of the 40-reading history return `nil` so the view can draw a placeholder
    /// rather than invent a reading that never happened.
    static func sampleIndex(forSlot slot: Int, sampleCount: Int) -> Int? {
        guard slot >= 0 else { return nil }
        let index = sampleCount - 1 - slot
        return index >= 0 ? index : nil
    }

    /// Bar heights as fractions of the window's own peak. Consumption per
    /// refresh has no natural ceiling, so an absolute scale would flatten every
    /// bar to nothing on a quiet day. An all-zero window yields all zeros
    /// instead of dividing by zero.
    static func barFractions(_ amounts: [Double]) -> [Double] {
        guard let peak = amounts.max(), peak > 0 else {
            return Array(repeating: 0, count: amounts.count)
        }
        return amounts.map { max(0, $0) / peak }
    }

    /// Lines up several trackers' samples by the refresh timestamp they came
    /// from, so one slot of the strip can stack the ordinary bucket and a
    /// worker/model bucket (Codex Spark, Claude Fable) measured at the same
    /// refresh.
    ///
    /// Alignment is by exact timestamp, never by position: a bucket that was
    /// momentarily absent from one refresh simply has no entry in that slot
    /// (`nil`), so it is neither drawn nor counted as zero. Slots are stored
    /// oldest-first and trimmed to the newest `capacity` refreshes.
    static func stackedSamples(
        _ series: [[UsageConsumptionSample]],
        capacity: Int = UsageConsumptionTracker.defaultCapacity
    ) -> [UsageConsumptionStackedSample] {
        let lookups = series.map { samples in
            Dictionary(samples.map { ($0.at, $0.amount) }, uniquingKeysWith: { _, newest in newest })
        }
        let dates = Set(lookups.flatMap(\.keys)).sorted()
        return dates.suffix(max(0, capacity)).map { date in
            UsageConsumptionStackedSample(at: date, amounts: lookups.map { $0[date] })
        }
    }

    /// Hover/caption text for one stacked slot. A single-bucket strip keeps
    /// the plain amount it always showed; a multi-bucket strip names each
    /// bucket that actually reported. Buckets without a reading are left out
    /// rather than written as "0". Percent deltas from independent quota
    /// windows are intentionally never presented as one arithmetic total.
    static func breakdownTitle(
        amounts: [Double?],
        labels: [String],
        unit: String
    ) -> String {
        let present = zip(labels, amounts).compactMap { label, amount in
            amount.map { (label: label, amount: $0) }
        }
        guard let first = present.first else { return amountTitle(0, unit: unit) }
        let parts = present.map { entry -> String in
            entry.label.isEmpty
                ? amountTitle(entry.amount, unit: unit)
                : "\(entry.label) \(amountTitle(entry.amount, unit: unit))"
        }
        guard present.count > 1 else {
            return labels.count > 1 ? parts[0] : amountTitle(first.amount, unit: unit)
        }
        return parts.joined(separator: " · ")
    }
}

/// One drawing slot of a stacked strip: what every tracked bucket consumed
/// at the same refresh. `amounts` is indexed like the series passed to
/// `UsageConsumptionCore.stackedSamples`; `nil` means that bucket has no
/// reading for this refresh.
struct UsageConsumptionStackedSample: Equatable {
    let at: Date
    let amounts: [Double?]

    /// Sum of the buckets that reported. Missing buckets contribute nothing,
    /// which is different from contributing zero: the hover text makes the
    /// distinction visible by omitting them.
    var total: Double {
        amounts.compactMap { $0 }.reduce(0, +)
    }
}

/// Rolling per-refresh consumption history for every provider, persisted
/// to UserDefaults as one JSON blob. A blob written before Gemini support
/// existed (missing `gemini`) still decodes successfully, with `gemini`
/// starting as an empty tracker instead of failing the whole decode and
/// silently discarding the Codex/Claude history alongside it. The same
/// leniency covers the later worker/model buckets (`codexSpark`,
/// `claudeFable`).
struct UsageConsumptionHistoryStore: Codable, Equatable {
    var codex: UsageConsumptionTracker
    /// Codex Spark's own weekly window, tracked beside the ordinary Codex
    /// meter so the chart can show both buckets of work.
    var codexSpark: UsageConsumptionTracker
    var claude: UsageConsumptionTracker
    /// Claude's Fable-specific weekly limit from `modelWeeklyLimits`.
    var claudeFable: UsageConsumptionTracker
    var gemini: UsageConsumptionTracker
    var grok: UsageConsumptionTracker

    enum CodingKeys: String, CodingKey {
        case codex, codexSpark, claude, claudeFable, gemini, grok
    }

    init(
        codex: UsageConsumptionTracker = UsageConsumptionTracker(),
        codexSpark: UsageConsumptionTracker = UsageConsumptionTracker(),
        claude: UsageConsumptionTracker = UsageConsumptionTracker(),
        claudeFable: UsageConsumptionTracker = UsageConsumptionTracker(),
        gemini: UsageConsumptionTracker = UsageConsumptionTracker(),
        grok: UsageConsumptionTracker = UsageConsumptionTracker()
    ) {
        self.codex = codex
        self.codexSpark = codexSpark
        self.claude = claude
        self.claudeFable = claudeFable
        self.gemini = gemini
        self.grok = grok
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        codex = try container.decode(UsageConsumptionTracker.self, forKey: .codex)
        claude = try container.decode(UsageConsumptionTracker.self, forKey: .claude)
        codexSpark = (try? container.decodeIfPresent(UsageConsumptionTracker.self, forKey: .codexSpark)) ?? UsageConsumptionTracker()
        claudeFable = (try? container.decodeIfPresent(UsageConsumptionTracker.self, forKey: .claudeFable)) ?? UsageConsumptionTracker()
        gemini = (try? container.decodeIfPresent(UsageConsumptionTracker.self, forKey: .gemini)) ?? UsageConsumptionTracker()
        grok = (try? container.decodeIfPresent(UsageConsumptionTracker.self, forKey: .grok)) ?? UsageConsumptionTracker()
    }
}

/// Rolling per-refresh consumption history for a single metric.
///
/// Deliberately dumb about *what* it measures: it takes a raw reading plus that
/// metric's direction and an identifying key, and it is the key that makes
/// switching meters safe — when Codex exhausts its weekly quota and starts
/// billing credits, the strip resets rather than drawing the first
/// cross-metric difference as one enormous bar.
struct UsageConsumptionTracker: Codable, Equatable {
    static let defaultCapacity = 40

    private(set) var samples: [UsageConsumptionSample] = []
    private var lastReading: Double?
    private var lastRecordedAt: Date?
    private var metricKey: String?

    init() {}

    var amounts: [Double] { samples.map(\.amount) }

    /// - Parameters:
    ///   - reading: the metric's current absolute value. A `nil` reading is
    ///     ignored so a momentarily missing field never fabricates a bar.
    ///   - date: the source data's own timestamp, never "now". Readings at or
    ///     before the last recorded timestamp are dropped, which is what stops
    ///     plain UI redraws — menu opens, file-watcher hits, offline retries —
    ///     from inventing bars for data that has not actually changed.
    mutating func record(
        reading: Double?,
        at date: Date,
        isDecreasing: Bool,
        metricKey: String,
        capacity: Int = defaultCapacity
    ) {
        if self.metricKey != metricKey {
            self.metricKey = metricKey
            samples.removeAll()
            lastReading = nil
            lastRecordedAt = nil
        }
        guard let reading else { return }
        if let lastRecordedAt, date <= lastRecordedAt { return }
        defer {
            lastReading = reading
            lastRecordedAt = date
        }
        // The first reading only establishes a baseline: there is nothing to
        // difference it against yet.
        guard let previous = lastReading else { return }
        samples.append(UsageConsumptionSample(
            at: date,
            amount: UsageConsumptionCore.consumption(
                previous: previous,
                current: reading,
                isDecreasing: isDecreasing
            )
        ))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }
}

enum UsageCore {
    static func sparkWeeklyWindow(from rateLimitsByLimitID: [String: Any]?) -> CodexSparkWeeklyWindow? {
        guard let rateLimitsByLimitID else { return nil }

        for (key, value) in rateLimitsByLimitID {
            guard let bucket = value as? [String: Any] else { continue }
            let limitID = (bucket["limitId"] as? String) ?? key
            let limitName = bucket["limitName"] as? String
            let isSpark = limitID.caseInsensitiveCompare("codex_bengalfox") == .orderedSame
                || limitName?.localizedCaseInsensitiveContains("spark") == true
            guard isSpark,
                  let weekly = bucket["secondary"] as? [String: Any],
                  let usedPercent = number(weekly["usedPercent"])
            else { continue }

            let duration = number(weekly["windowDurationMins"]).map(Int.init)
            let resetsAt = number(weekly["resetsAt"]).map(Date.init(timeIntervalSince1970:))
            return CodexSparkWeeklyWindow(
                usedPercent: usedPercent,
                windowDurationMinutes: duration,
                resetsAt: resetsAt
            )
        }

        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

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

    static func codexQuotaDisplaysCredits(usedPercent: Double?, creditBalance: Double?) -> Bool {
        guard let usedPercent, let creditBalance, creditBalance > 0 else { return false }
        return remainingPercent(from: usedPercent) <= 0
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

    static let minimumPanelOpacity = 0.95

    static func normalizedPanelOpacity(_ opacity: Double) -> Double {
        min(max(opacity, minimumPanelOpacity), 1.0)
    }

    /// Selectable auto-refresh cadences in seconds, `0` meaning off. The menu,
    /// the persistence normalizer, and the tests all read this one list so a
    /// new cadence cannot be added in one place and forgotten in another.
    /// `-1` selects the bounded adaptive 30s→2→5 minute policy used by the
    /// reference usage monitor; `0` disables automatic refresh.
    static let smartRefreshPreference = -1
    static let refreshIntervalOptions: [Int] = [-1, 0, 60, 180, 300, 600]
    static let claudeRefreshIntervalOptions: [Int] = [-1, 0, 60, 180, 300, 600]
    static let geminiRefreshIntervalOptions: [Int] = [-1, 0, 60, 180, 300, 600]
    static let grokRefreshIntervalOptions: [Int] = [0, 120, 300, 600, 900, 1_800]

    /// Provider-specific defaults balance freshness with each source's cost.
    /// Applies to a fresh install only; a stored valid choice always wins.
    static let defaultRefreshIntervalSeconds = smartRefreshPreference
    static let defaultClaudeRefreshIntervalSeconds = smartRefreshPreference
    static let defaultGeminiRefreshIntervalSeconds = smartRefreshPreference
    static let defaultGrokRefreshIntervalSeconds = 300

    static func normalizedRefreshInterval(_ seconds: Int?) -> TimeInterval {
        guard let seconds, refreshIntervalOptions.contains(seconds) else {
            return TimeInterval(defaultRefreshIntervalSeconds)
        }
        return TimeInterval(seconds)
    }

    static func normalizedClaudeRefreshInterval(_ seconds: Int?) -> TimeInterval {
        guard let seconds, claudeRefreshIntervalOptions.contains(seconds) else {
            return TimeInterval(defaultClaudeRefreshIntervalSeconds)
        }
        return TimeInterval(seconds)
    }

    static func normalizedGeminiRefreshInterval(_ seconds: Int?) -> TimeInterval {
        guard let seconds, geminiRefreshIntervalOptions.contains(seconds) else {
            return TimeInterval(defaultGeminiRefreshIntervalSeconds)
        }
        return TimeInterval(seconds)
    }

    static func normalizedGrokRefreshInterval(_ seconds: Int?) -> TimeInterval {
        guard let seconds, grokRefreshIntervalOptions.contains(seconds) else {
            return TimeInterval(defaultGrokRefreshIntervalSeconds)
        }
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
    /// same status/weekly/account/freshness concepts. Retired Spark keys stay
    /// null for compatibility with older consumers.
    static func codexPayload(from snapshot: RateLimitSnapshot?, freshForSeconds: Int, now: Date = Date()) -> [String: Any] {
        guard let snapshot else {
            return [
                "status": "unavailable",
                "weeklyRemainingPercent": NSNull(),
                "weeklyUsedPercent": NSNull(),
                "weeklyResetsAt": NSNull(),
                "sparkRemainingPercent": NSNull(),
                "sparkUsedPercent": NSNull(),
                "sparkResetsAt": NSNull(),
                "sparkWindowDurationMins": NSNull(),
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
            "sparkRemainingPercent": NSNull(),
            "sparkUsedPercent": NSNull(),
            "sparkResetsAt": NSNull(),
            "sparkWindowDurationMins": NSNull(),
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
        output["sparkRemainingPercent"] = NSNull()
        output["sparkUsedPercent"] = NSNull()
        output["sparkResetsAt"] = NSNull()
        output["sparkWindowDurationMins"] = NSNull()
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

/// A single quota bucket reported by
/// `agy -p '/usage' --mode plan --sandbox --output-format json` under the
/// `command.data.groups[]` entry named `"Gemini Models"`.
struct GeminiUsageBucket: Sendable, Equatable {
    let id: String
    let name: String?
    let window: String
    /// 0...1, already clamped.
    let remainingFraction: Double
    let resetsAt: Date?
}

/// Combines the `gemini-weekly`/`gemini-5h` buckets from `/usage` with the
/// separate `/credits` balance into one snapshot, mirroring
/// `ClaudeUsageSnapshot`'s shape closely enough that the shared-file and
/// panel code can follow the same conventions for a third provider.
struct GeminiUsageSnapshot: Sendable, Equatable {
    let weeklyRemainingFraction: Double?
    let weeklyResetsAt: Date?
    let fiveHourRemainingFraction: Double?
    let fiveHourResetsAt: Date?
    let creditBalance: Int?
    let publishedAt: Date?
    /// Active Google account recorded by the local Gemini/Antigravity CLI.
    /// This is display-only and is deliberately excluded from the shared
    /// usage JSON so enabling CCMB sharing never broadens its account data.
    let accountEmail: String?
    /// Plan inferred only from entitlements present in Antigravity's own
    /// structured `/usage` response; never scraped from a signed-in browser.
    let planTitle: String?

    init(
        weeklyRemainingFraction: Double? = nil,
        weeklyResetsAt: Date? = nil,
        fiveHourRemainingFraction: Double? = nil,
        fiveHourResetsAt: Date? = nil,
        creditBalance: Int? = nil,
        publishedAt: Date? = nil,
        accountEmail: String? = nil,
        planTitle: String? = nil
    ) {
        self.weeklyRemainingFraction = weeklyRemainingFraction
        self.weeklyResetsAt = weeklyResetsAt
        self.fiveHourRemainingFraction = fiveHourRemainingFraction
        self.fiveHourResetsAt = fiveHourResetsAt
        self.creditBalance = creditBalance
        self.publishedAt = publishedAt
        self.accountEmail = accountEmail
        self.planTitle = planTitle
    }
}

/// Pure decoder for Gemini CLI's local account selector. The file contains no
/// OAuth token — only the active email and a list of old accounts — and CCMB
/// accepts only a plausible email-shaped active value. CLI releases have used
/// more than one representation for the active account, so all known local
/// metadata forms are handled without reading credential fields.
enum GeminiAccountCore {
    static func activeEmail(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for candidate in [root["active"], root["activeEmail"], root["active_account"], root["activeAccount"]] {
            if let email = email(from: candidate) { return email }
        }
        if let accounts = root["accounts"] as? [[String: Any]] {
            for account in accounts where (account["active"] as? Bool) == true {
                if let email = email(from: account) { return email }
            }
        }
        return nil
    }

    private static func email(from value: Any?) -> String? {
        if let string = value as? String {
            let email = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return email.isEmpty || !email.contains("@") ? nil : email
        }
        if let object = value as? [String: Any] {
            for key in ["email", "emailAddress", "account", "identifier"] {
                if let email = email(from: object[key]) { return email }
            }
        }
        return nil
    }

    static func metadataEmail(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return metadataEmail(from: root)
    }

    private static func metadataEmail(from value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["email", "emailAddress", "accountEmail", "userEmail", "identity"] {
                if let email = email(from: object[key]) { return email }
                if let nested = object[key], let email = metadataEmail(from: nested) { return email }
            }
            for nested in object.values {
                if let email = metadataEmail(from: nested) { return email }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let email = metadataEmail(from: nested) { return email }
            }
        }
        return nil
    }

    /// Antigravity writes the resolved, non-secret account address after a
    /// successful keychain sign-in. This is the CLI's own authenticated
    /// result, not a guess from the web session. Read only a bounded tail so
    /// an unexpectedly large diagnostic file cannot affect refresh latency.
    static func emailFromCLIAuthLog(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        let tailSize = min(size, 128 * 1_024)
        handle.seek(toFileOffset: size - tailSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"applyAuthResult:\s+email=([^,\s]+)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(text[range])
        guard let emailStart = match.range(of: "email=")?.upperBound else { return nil }
        return email(from: String(match[emailStart...]))
    }

    static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let payload = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        for key in ["email", "upn", "preferred_username"] {
            if let email = email(from: object[key]) { return email }
        }
        return nil
    }
}

enum ClaudePlanCore {
    /// Reads only non-secret account metadata cached by Claude Code. OAuth
    /// credentials live elsewhere and are never opened by this parser.
    static func title(fromAccountMetadata data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }

        let rateLimitTier = account["organizationRateLimitTier"] as? String
        if rateLimitTier?.contains("max_20x") == true { return "Claude Max 20×" }
        if rateLimitTier?.contains("max_5x") == true { return "Claude Max 5×" }

        switch account["organizationType"] as? String {
        case "claude_max": return "Claude Max"
        case "claude_pro": return "Claude Pro"
        case "claude_team": return "Claude Team"
        case "claude_enterprise": return "Claude Enterprise"
        default: return nil
        }
    }

    /// Exact `claude_details.plan_type` values the NAS backend reports,
    /// lowercased. Anything else is hidden rather than guessed.
    static let nasAllowlist: Set<String> = ["max_5x", "max_20x", "max", "pro", "team", "enterprise"]

    /// Display title for a NAS-reported `plan_type`, already restricted to
    /// `nasAllowlist` by the caller.
    static func title(fromNASPlanType planType: String) -> String? {
        switch planType {
        case "max_5x": return "Claude Max 5×"
        case "max_20x": return "Claude Max 20×"
        case "max": return "Claude Max"
        case "pro": return "Claude Pro"
        case "team": return "Claude Team"
        case "enterprise": return "Claude Enterprise"
        default: return nil
        }
    }
}

/// Pure parsing and shared-payload logic for the Gemini/Antigravity `agy`
/// CLI. Deliberately has no knowledge of how `agy` gets launched, so it is
/// fully testable without spawning a process.
enum GeminiUsageCore {
    static let sharedFreshForSeconds: TimeInterval = 300
    /// Smart cadence begins at one minute for all three visible providers.
    /// `agy` still guards overlapping subprocesses internally.
    static let minimumRequestIntervalSeconds: TimeInterval = 60
    static let weeklyBucketID = "gemini-weekly"
    static let fiveHourBucketID = "gemini-5h"
    static let geminiModelsGroupName = "Gemini Models"

    static func remainingPercent(from fraction: Double?) -> Double? {
        guard let fraction else { return nil }
        return min(max(fraction, 0), 1) * 100
    }

    static func isFresh(publishedAt: Date?, now: Date, freshForSeconds: TimeInterval) -> Bool {
        guard let publishedAt else { return false }
        return now.timeIntervalSince(publishedAt) <= freshForSeconds
    }

    /// Same scheduling rule as `ClaudeUsageCore.shouldThrottleFetch`: a timer
    /// tick that arrives within scheduling tolerance is never deferred to the
    /// next cycle.
    static func shouldThrottleFetch(minimumInterval: TimeInterval, lastFetchDate: Date?, now: Date) -> Bool {
        guard minimumInterval > 0, let lastFetchDate else { return false }
        let timerTolerance = min(1, minimumInterval * 0.05)
        return now.timeIntervalSince(lastFetchDate) < minimumInterval - timerTolerance
    }

    /// Envelope shared by every `agy ... --output-format json` command:
    /// `{"command": {"name": "...", "data": {...}}}`.
    private struct CommandEnvelope<CommandData: Decodable>: Decodable {
        struct Command: Decodable {
            let name: String?
            let data: CommandData?
        }
        let command: Command?
    }

    private struct UsageData: Decodable {
        struct Group: Decodable {
            let name: String?
            let buckets: [Bucket]?
        }
        struct Bucket: Decodable {
            let id: String?
            let name: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            enum CodingKeys: String, CodingKey {
                case id, name, window
                case remainingFraction = "remaining_fraction"
                case resetTime = "reset_time"
            }
        }
        let groups: [Group]?
    }

    private struct CreditsData: Decodable {
        let remainingCredits: Int?
        enum CodingKeys: String, CodingKey {
            case remainingCredits = "remaining_credits"
        }
    }

    /// Parses `agy -p '/usage' ... --output-format json` stdout into the
    /// `"Gemini Models"` group's buckets. Returns `nil` for any shape the CLI
    /// contract does not guarantee — wrong `command.name`, an absent group,
    /// or malformed JSON — never throws, so a CLI update never crashes CCMB.
    static func parseUsage(_ data: Data) -> [GeminiUsageBucket]? {
        guard let envelope = try? JSONDecoder().decode(CommandEnvelope<UsageData>.self, from: data),
              envelope.command?.name == "usage",
              let groups = envelope.command?.data?.groups,
              let geminiGroup = groups.first(where: { $0.name == geminiModelsGroupName }),
              let rawBuckets = geminiGroup.buckets
        else { return nil }

        let buckets = rawBuckets.compactMap { bucket -> GeminiUsageBucket? in
            guard let id = bucket.id, !id.isEmpty, let fraction = bucket.remainingFraction else { return nil }
            return GeminiUsageBucket(
                id: id,
                name: bucket.name,
                window: bucket.window ?? "",
                remainingFraction: min(max(fraction, 0), 1),
                resetsAt: parseDate(bucket.resetTime)
            )
        }
        return buckets.isEmpty ? nil : buckets
    }

    /// `/usage` exposes quota groups, not the billing product name. In
    /// particular, the Claude/GPT group is not reliable proof of Ultra, so do
    /// not promote an account from that group alone. A session bucket is the
    /// stable paid-entitlement signal currently available to the CLI.
    static func parsePlanTitle(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CommandEnvelope<UsageData>.self, from: data),
              envelope.command?.name == "usage",
              let groups = envelope.command?.data?.groups
        else { return nil }

        let geminiBuckets = groups.first(where: { $0.name == geminiModelsGroupName })?.buckets ?? []
        if geminiBuckets.contains(where: { $0.id == fiveHourBucketID }) {
            return "Google AI Pro"
        }
        return geminiBuckets.isEmpty ? nil : "Google AI 기본"
    }

    /// Parses `agy -p '/credits' ... --output-format json` stdout into the
    /// remaining AI credit balance. `upgrade_uri` is intentionally never
    /// read here: it is account-specific and must not be persisted or
    /// exposed outside the running process.
    static func parseCredits(_ data: Data) -> Int? {
        guard let envelope = try? JSONDecoder().decode(CommandEnvelope<CreditsData>.self, from: data),
              envelope.command?.name == "credits"
        else { return nil }
        return envelope.command?.data?.remainingCredits
    }

    static func snapshot(
        buckets: [GeminiUsageBucket],
        creditBalance: Int?,
        publishedAt: Date,
        accountEmail: String? = nil,
        planTitle: String? = nil
    ) -> GeminiUsageSnapshot {
        let weekly = buckets.first { $0.id == weeklyBucketID }
        let fiveHour = buckets.first { $0.id == fiveHourBucketID }
        return GeminiUsageSnapshot(
            weeklyRemainingFraction: weekly?.remainingFraction,
            weeklyResetsAt: weekly?.resetsAt,
            fiveHourRemainingFraction: fiveHour?.remainingFraction,
            fiveHourResetsAt: fiveHour?.resetsAt,
            creditBalance: creditBalance,
            publishedAt: publishedAt,
            accountEmail: accountEmail,
            planTitle: planTitle
        )
    }

    /// Nested `gemini` object mirroring `codex`/`claude`'s shape in the
    /// shared `usage-v1.json` file: status/weekly/5-hour/reset/freshness.
    static func sharedPayload(from snapshot: GeminiUsageSnapshot?, now: Date = Date()) -> [String: Any] {
        guard let snapshot else {
            return [
                "status": "unavailable",
                "weeklyRemainingPercent": NSNull(),
                "weeklyResetsAt": NSNull(),
                "fiveHourRemainingPercent": NSNull(),
                "fiveHourResetsAt": NSNull(),
                "creditBalance": NSNull(),
                "planTitle": NSNull(),
                "fetchedAt": NSNull(),
                "ageSeconds": NSNull(),
                "freshForSeconds": Int(sharedFreshForSeconds),
                "fresh": false
            ]
        }

        let ageSeconds = snapshot.publishedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        return [
            "status": (snapshot.weeklyRemainingFraction == nil && snapshot.fiveHourRemainingFraction == nil) ? "partial" : "ok",
            "weeklyRemainingPercent": remainingPercent(from: snapshot.weeklyRemainingFraction) ?? NSNull(),
            "weeklyResetsAt": snapshot.weeklyResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "fiveHourRemainingPercent": remainingPercent(from: snapshot.fiveHourRemainingFraction) ?? NSNull(),
            "fiveHourResetsAt": snapshot.fiveHourResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "creditBalance": snapshot.creditBalance ?? NSNull(),
            "planTitle": snapshot.planTitle ?? NSNull(),
            "fetchedAt": snapshot.publishedAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "ageSeconds": ageSeconds ?? NSNull(),
            "freshForSeconds": Int(sharedFreshForSeconds),
            "fresh": isFresh(publishedAt: snapshot.publishedAt, now: now, freshForSeconds: sharedFreshForSeconds)
        ]
    }

    /// Recomputes a stored `gemini` payload's `ageSeconds`/`fresh` from its
    /// own `fetchedAt`, the same role `refreshedSharedPayload` plays for
    /// Claude on a cache read. A nested `online` object (the Gemini web
    /// snapshot) gets the same recomputation from its own `fetchedAt`.
    static func refreshedSharedPayload(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var output = payload
        let fetchedAt = (payload["fetchedAt"] as? String).flatMap(sharedISO8601Formatter.date(from:))
        let freshForSeconds = (payload["freshForSeconds"] as? NSNumber)?.doubleValue ?? sharedFreshForSeconds
        output["ageSeconds"] = fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? NSNull()
        output["fresh"] = isFresh(publishedAt: fetchedAt, now: now, freshForSeconds: freshForSeconds)
        if let online = payload["online"] as? [String: Any] {
            output["online"] = GeminiOnlineUsageCore.refreshedSharedPayload(online, now: now)
        }
        return output
    }

    /// Restores the last successful Gemini snapshot from CCMB's own shared
    /// JSON, the same role `ClaudeUsageCore.snapshot(fromSharedPayload:)`
    /// plays for Claude so an app restart does not momentarily show "정보
    /// 없음" for data that was fetched minutes ago.
    static func snapshot(fromSharedPayload payload: [String: Any]) -> GeminiUsageSnapshot? {
        func fraction(_ key: String) -> Double? {
            guard let percent = (payload[key] as? NSNumber)?.doubleValue else { return nil }
            return min(max(percent / 100, 0), 1)
        }
        func date(_ key: String) -> Date? {
            (payload[key] as? String).flatMap(sharedISO8601Formatter.date(from:))
        }

        let snapshot = GeminiUsageSnapshot(
            weeklyRemainingFraction: fraction("weeklyRemainingPercent"),
            weeklyResetsAt: date("weeklyResetsAt"),
            fiveHourRemainingFraction: fraction("fiveHourRemainingPercent"),
            fiveHourResetsAt: date("fiveHourResetsAt"),
            creditBalance: (payload["creditBalance"] as? NSNumber)?.intValue,
            publishedAt: date("fetchedAt"),
            planTitle: payload["planTitle"] as? String
        )

        guard snapshot.publishedAt != nil
            || snapshot.weeklyRemainingFraction != nil
            || snapshot.fiveHourRemainingFraction != nil
            || snapshot.creditBalance != nil
            || snapshot.planTitle != nil
        else { return nil }
        return snapshot
    }

    /// `agy`'s `reset_time` is not guaranteed to carry fractional seconds the
    /// way CCMB's own written timestamps do, so both forms are tried.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return sharedISO8601Formatter.date(from: string) ?? sharedISO8601FormatterWholeSeconds.date(from: string)
    }

    private static let sharedISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sharedISO8601FormatterWholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Strict JSON scalar readers shared by the NAS parsers. `JSONSerialization`
/// hands back JSON booleans as `NSNumber` too, so every numeric read here
/// rejects booleans explicitly instead of letting `true` pass as `1`.
enum NASJSON {
    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func bool(_ value: Any?) -> Bool? {
        guard isBool(value), let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// Finite, non-boolean number.
    static func number(_ value: Any?) -> Double? {
        guard !isBool(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Non-boolean number with an exactly integral value (2.5 is rejected).
    static func integer(_ value: Any?) -> Int? {
        guard let double = number(value), double.rounded() == double, abs(double) < 9_007_199_254_740_992 else { return nil }
        return Int(double)
    }

    /// Finite, strictly positive, non-boolean timestamp in whatever unit the
    /// caller's contract names (Unix seconds for the snapshot, milliseconds
    /// for history).
    static func positiveTimestamp(_ value: Any?) -> Double? {
        guard let double = number(value), double > 0 else { return nil }
        return double
    }

    static func isNull(_ value: Any?) -> Bool {
        guard let value else { return false }
        return value is NSNull
    }

    /// Key missing or explicit JSON null.
    static func isAbsent(_ value: Any?) -> Bool {
        value == nil || isNull(value)
    }
}

/// The four fixed card identities, in their fixed display order. Gemini's
/// two accounts are bound to fixed `account_ref`s, never to whichever
/// account currently happens to be active, so their numbers never swap.
enum NASServiceID: String, CaseIterable {
    case codex, claude, gemini, gemini2

    var provider: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini, .gemini2: return "gemini"
        }
    }

    var accountRef: String? {
        switch self {
        case .codex, .claude: return nil
        case .gemini: return "account1"
        case .gemini2: return "account2"
        }
    }
}

/// A service-level `{code, message}` error. Only these two structured fields
/// are read — the error object is never stringified as a whole — and the
/// panel shows a fixed local label per known code rather than any free text.
struct NASServiceError: Equatable {
    let code: String
    let message: String?

    static let localSchemaCode = "schema_changed"

    static func parse(_ value: Any?) -> NASServiceError? {
        guard let object = value as? [String: Any] else { return nil }
        guard let code = object["code"] as? String, isSafeCode(code) else { return nil }
        let message: String?
        if NASJSON.isAbsent(object["message"]) {
            message = nil
        } else if let text = object["message"] as? String, text.count <= 200 {
            message = text
        } else {
            return nil
        }
        return NASServiceError(code: code, message: message)
    }

    static func isSafeCode(_ code: String) -> Bool {
        !code.isEmpty && code.count <= 64 && code.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        }
    }

    var label: String {
        switch code {
        case "not_collected": return "NAS 미수집"
        case "cli_missing": return "NAS 수집 도구 없음"
        case "cli_failed": return "NAS 수집 도구 실패"
        case "timeout": return "NAS 수집 시간 초과"
        case "bad_response", "schema": return "NAS 응답 형식 오류"
        case "schema_changed": return "NAS 형식 변경으로 확인 불가"
        case "creds_missing", "creds_unsafe": return "NAS 자격 증명 확인 불가"
        case "login_required", "reauth_required": return "NAS 쪽 다시 로그인 필요"
        case "refresh_failed": return "NAS 갱신 실패"
        case "forbidden": return "NAS 접근 거부"
        case "rate_limited": return "NAS 요청 제한"
        case "redirect_blocked", "tls_error", "network_error", "http_error": return "NAS 수집 네트워크 오류"
        case "storage_unavailable": return "NAS 저장소 확인 불가"
        case "internal", "adapter_unavailable": return "NAS 내부 오류"
        default: return "NAS 오류(\(code))"
        }
    }
}

/// One sanitized `items[]` entry. Remaining capacity is kept as a 0...100
/// percent: the newer `remaining_fraction` (0...1) is preferred, the legacy
/// `remaining_percent` (0...100) is accepted, and anything else invalidates
/// the item rather than being guessed.
struct NASUsageItem: Equatable {
    enum Window: String {
        case session, weekly

        var minutes: Int { self == .session ? 300 : 10080 }
    }

    let name: String
    let window: Window
    let remainingPercent: Double
    let resetsAt: Date?
    /// Codex-only `credits` object; `hasCredits` records that the object
    /// was present at all (so "no balance" differs from "not reported").
    let hasCredits: Bool
    let creditBalance: Double?
    let creditsUnlimited: Bool
    /// Codex-only `codex_details` object (confirmed app-server plan/reset
    /// voucher count). `hasCodexDetails` records that the object was present
    /// at all, independent of whether its two fields were individually
    /// recognizable.
    let hasCodexDetails: Bool
    let codexPlanType: String?
    let codexResetCreditsAvailable: Int?
    /// Claude-only `claude_details` object on the `전체` aggregate item
    /// (confirmed `/api/oauth/profile`/usage-derived plan and optional
    /// pay-as-you-go spend). `hasClaudeDetails` records that the object was
    /// present at all, independent of whether its sub-fields were
    /// individually recognizable.
    let hasClaudeDetails: Bool
    let claudePlanType: String?
    let claudeExtraUsage: NASClaudeExtraUsage?
    var claudeLimitResets: ClaudeLimitResets? = nil

    var remainingFraction: Double { remainingPercent / 100 }

    static func parse(_ value: Any?, allowsCredits: Bool, allowsClaudeDetails: Bool = false) -> NASUsageItem? {
        guard let object = value as? [String: Any] else { return nil }
        guard let name = object["name"] as? String, !name.isEmpty, name.count <= 64 else { return nil }
        guard let rawWindow = object["window"] as? String, let window = Window(rawValue: rawWindow) else { return nil }
        if let minutes = object["window_minutes"], !(minutes is NSNull) {
            guard NASJSON.integer(minutes) == window.minutes else { return nil }
        }

        let remainingPercent: Double
        if let rawFraction = object["remaining_fraction"], !(rawFraction is NSNull) {
            guard let fraction = NASJSON.number(rawFraction), (0...1).contains(fraction) else { return nil }
            remainingPercent = fraction * 100
        } else if let percent = NASJSON.number(object["remaining_percent"]), (0...100).contains(percent) {
            remainingPercent = percent
        } else {
            return nil
        }

        var resetsAt: Date?
        if !NASJSON.isAbsent(object["resets_at"]) {
            guard let seconds = NASJSON.positiveTimestamp(object["resets_at"]) else { return nil }
            resetsAt = Date(timeIntervalSince1970: seconds)
        }

        var hasCredits = false
        var creditBalance: Double?
        var creditsUnlimited = false
        if !NASJSON.isAbsent(object["credits"]) {
            guard allowsCredits, let credits = object["credits"] as? [String: Any] else { return nil }
            hasCredits = true
            if !NASJSON.isAbsent(credits["balance"]) {
                guard let balance = NASJSON.number(credits["balance"]), balance >= 0 else { return nil }
                creditBalance = balance
            }
            if !NASJSON.isAbsent(credits["unlimited"]) {
                guard let unlimited = NASJSON.bool(credits["unlimited"]) else { return nil }
                creditsUnlimited = unlimited
            }
        }

        // Unlike `credits`, a malformed `codex_details` sub-field never fails
        // the whole item: it only drops that one field, so a foreign/invalid
        // plan_type or reset_credits_available cannot erase the already
        // healthy weekly quota/credit balance carried by the rest of the item.
        var hasCodexDetails = false
        var codexPlanType: String?
        var codexResetCreditsAvailable: Int?
        if allowsCredits, !NASJSON.isAbsent(object["codex_details"]), let details = object["codex_details"] as? [String: Any] {
            hasCodexDetails = true
            if let planType = details["plan_type"] as? String, CodexPlanCore.allowlist.contains(planType.lowercased()) {
                codexPlanType = planType.lowercased()
            }
            if let resetCredits = NASJSON.integer(details["reset_credits_available"]), resetCredits >= 0 {
                codexResetCreditsAvailable = resetCredits
            }
        }

        // Like `codex_details`, a malformed `claude_details` sub-field never
        // fails the whole item: it only drops that one field.
        var hasClaudeDetails = false
        var claudePlanType: String?
        var claudeExtraUsage: NASClaudeExtraUsage?
        var claudeLimitResets: ClaudeLimitResets?
        if allowsClaudeDetails, !NASJSON.isAbsent(object["claude_details"]), let details = object["claude_details"] as? [String: Any] {
            hasClaudeDetails = true
            claudeLimitResets = ClaudeLimitResets.parse(details["limit_resets"])
            if let planType = details["plan_type"] as? String, ClaudePlanCore.nasAllowlist.contains(planType.lowercased()) {
                claudePlanType = planType.lowercased()
            }
            if !NASJSON.isAbsent(details["extra_usage"]) {
                claudeExtraUsage = NASClaudeExtraUsage.parse(details["extra_usage"])
            }
        }

        return NASUsageItem(
            name: name,
            window: window,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            hasCredits: hasCredits,
            creditBalance: creditBalance,
            creditsUnlimited: creditsUnlimited,
            hasCodexDetails: hasCodexDetails,
            codexPlanType: codexPlanType,
            codexResetCreditsAvailable: codexResetCreditsAvailable,
            hasClaudeDetails: hasClaudeDetails,
            claudePlanType: claudePlanType,
            claudeExtraUsage: claudeExtraUsage,
            claudeLimitResets: claudeLimitResets
        )
    }

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "name": name,
            "window": window.rawValue,
            "window_minutes": window.minutes,
            "remaining_percent": remainingPercent,
            "resets_at": resetsAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
        ]
        if hasCredits {
            object["credits"] = [
                "balance": creditBalance.map { $0 as Any } ?? NSNull(),
                "unlimited": creditsUnlimited,
            ]
        }
        if hasCodexDetails {
            object["codex_details"] = [
                "plan_type": codexPlanType.map { $0 as Any } ?? NSNull(),
                "reset_credits_available": codexResetCreditsAvailable.map { $0 as Any } ?? NSNull(),
            ]
        }
        if hasClaudeDetails {
            object["claude_details"] = [
                "plan_type": claudePlanType.map { $0 as Any } ?? NSNull(),
                "extra_usage": claudeExtraUsage?.jsonObject() ?? NSNull(),
                "limit_resets": claudeLimitResets?.jsonObject() ?? NSNull(),
            ]
        }
        return object
    }
}

/// Confirmed grant count and separate current eligibility, never inferred from quota.
struct ClaudeLimitResets: Sendable, Equatable {
    let remainingCount: Int
    let usableNow: Bool?
    let expiresAt: Date?

    static func parse(_ value: Any?) -> ClaudeLimitResets? {
        guard let object = value as? [String: Any],
              let count = NASJSON.integer(object["remaining_count"]), count >= 0
        else { return nil }
        var usable: Bool?
        if !NASJSON.isAbsent(object["usable_now"]) {
            guard let value = NASJSON.bool(object["usable_now"]) else { return nil }
            usable = value
        }
        var expiry: Date?
        if !NASJSON.isAbsent(object["expires_at"]) {
            guard let value = NASJSON.positiveTimestamp(object["expires_at"]), value < 9_007_199_254_740_992
            else { return nil }
            expiry = Date(timeIntervalSince1970: value)
        }
        return ClaudeLimitResets(remainingCount: count, usableNow: usable, expiresAt: expiry)
    }

    func jsonObject() -> [String: Any] {
        ["remaining_count": remainingCount,
         "usable_now": usableNow.map { $0 as Any } ?? NSNull(),
         "expires_at": expiresAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull()]
    }
}

/// Claude-only pay-as-you-go spend sub-object of `claude_details`. Every
/// field is validated and retained independently: an unrecognizable
/// `currency`/`decimal_places` never discards an otherwise-valid
/// `is_enabled`/`utilization`, and vice versa.
struct NASClaudeExtraUsage: Equatable {
    let isEnabled: Bool?
    let monthlyLimitMinor: Double?
    let usedMinor: Double?
    let utilization: Double?
    let currency: String?
    let decimalPlaces: Int?

    static func parse(_ value: Any?) -> NASClaudeExtraUsage? {
        guard let object = value as? [String: Any] else { return nil }

        var isEnabled: Bool?
        if !NASJSON.isAbsent(object["is_enabled"]) {
            isEnabled = NASJSON.bool(object["is_enabled"])
        }
        var monthlyLimitMinor: Double?
        if !NASJSON.isAbsent(object["monthly_limit_minor"]) {
            if let value = NASJSON.number(object["monthly_limit_minor"]), value >= 0 {
                monthlyLimitMinor = value
            }
        }
        var usedMinor: Double?
        if !NASJSON.isAbsent(object["used_minor"]) {
            if let value = NASJSON.number(object["used_minor"]), value >= 0 {
                usedMinor = value
            }
        }
        var utilization: Double?
        if !NASJSON.isAbsent(object["utilization"]) {
            if let value = NASJSON.number(object["utilization"]), (0...100).contains(value) {
                utilization = value
            }
        }
        var currency: String?
        if let rawCurrency = object["currency"] as? String, rawCurrency == "USD" {
            currency = rawCurrency
        }
        var decimalPlaces: Int?
        if !NASJSON.isAbsent(object["decimal_places"]) {
            if let value = NASJSON.integer(object["decimal_places"]), (0...6).contains(value) {
                decimalPlaces = value
            }
        }

        guard isEnabled != nil || monthlyLimitMinor != nil || usedMinor != nil
            || utilization != nil || currency != nil || decimalPlaces != nil
        else { return nil }

        return NASClaudeExtraUsage(
            isEnabled: isEnabled,
            monthlyLimitMinor: monthlyLimitMinor,
            usedMinor: usedMinor,
            utilization: utilization,
            currency: currency,
            decimalPlaces: decimalPlaces
        )
    }

    func jsonObject() -> [String: Any] {
        [
            "is_enabled": isEnabled.map { $0 as Any } ?? NSNull(),
            "monthly_limit_minor": monthlyLimitMinor.map { $0 as Any } ?? NSNull(),
            "used_minor": usedMinor.map { $0 as Any } ?? NSNull(),
            "utilization": utilization.map { $0 as Any } ?? NSNull(),
            "currency": currency.map { $0 as Any } ?? NSNull(),
            "decimal_places": decimalPlaces.map { $0 as Any } ?? NSNull(),
        ]
    }
}

/// Describes the *upstream* collection cadence NAS itself is actually
/// running — never the client's own automatic cached-GET polling, which
/// stays independent (active 30s / idle 120s, up to 300s locally) and is
/// never clamped to this value. A poll/fetch timestamp must never be
/// confused with this: `nextRefreshAt` is NAS's own planned next collection,
/// not "when the client last asked".
struct NASRefreshPolicy: Equatable {
    enum Mode: String { case active, idle, backoff }

    let mode: Mode?
    let intervalSeconds: Double?
    let nextRefreshAt: Date?

    static func parse(_ value: Any?) -> NASRefreshPolicy? {
        guard let object = value as? [String: Any] else { return nil }
        var mode: Mode?
        if let rawMode = object["mode"] as? String {
            mode = Mode(rawValue: rawMode)
        }
        var intervalSeconds: Double?
        if !NASJSON.isAbsent(object["interval_seconds"]) {
            if let value = NASJSON.number(object["interval_seconds"]), value >= 0 {
                intervalSeconds = value
            }
        }
        var nextRefreshAt: Date?
        if !NASJSON.isAbsent(object["next_refresh_at"]) {
            if let seconds = NASJSON.positiveTimestamp(object["next_refresh_at"]) {
                nextRefreshAt = Date(timeIntervalSince1970: seconds)
            }
        }
        guard mode != nil || intervalSeconds != nil || nextRefreshAt != nil else { return nil }
        return NASRefreshPolicy(mode: mode, intervalSeconds: intervalSeconds, nextRefreshAt: nextRefreshAt)
    }

    func jsonObject() -> [String: Any] {
        [
            "mode": mode.map { $0.rawValue as Any } ?? NSNull(),
            "interval_seconds": intervalSeconds.map { $0 as Any } ?? NSNull(),
            "next_refresh_at": nextRefreshAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
        ]
    }
}

/// Service-level `gemini_details` on a `gemini`/`gemini2` entry: the AI
/// credit balance reading NAS collected independently of the session/weekly
/// quota items. A missing/`unavailable` reading is kept distinct from a
/// confirmed `0` balance and never invalidates the quota items alongside it.
struct NASGeminiDetails: Equatable {
    var planTitle: String? = nil
    let creditBalance: Int?
    let creditsFetchedAt: Date?
    let creditsStatus: String?

    static func parse(_ value: Any?) -> NASGeminiDetails? {
        guard let object = value as? [String: Any] else { return nil }
        var creditBalance: Int?
        if !NASJSON.isAbsent(object["credit_balance"]) {
            guard let balance = NASJSON.integer(object["credit_balance"]), balance >= 0 else { return nil }
            creditBalance = balance
        }
        var creditsFetchedAt: Date?
        if !NASJSON.isAbsent(object["credits_fetched_at"]) {
            guard let seconds = NASJSON.positiveTimestamp(object["credits_fetched_at"]) else { return nil }
            creditsFetchedAt = Date(timeIntervalSince1970: seconds)
        }
        var creditsStatus: String?
        if let status = object["credits_status"] as? String, ["ok", "unavailable"].contains(status) {
            creditsStatus = status
        }
        let planTitle = (object["plan_title"] as? String).flatMap { value -> String? in
            let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !title.isEmpty && title.count <= 120 && title.rangeOfCharacter(from: .controlCharacters) == nil ? title : nil
        }
        guard creditBalance != nil || creditsFetchedAt != nil || creditsStatus != nil || planTitle != nil else { return nil }
        return NASGeminiDetails(planTitle: planTitle, creditBalance: creditBalance, creditsFetchedAt: creditsFetchedAt, creditsStatus: creditsStatus)
    }

    func jsonObject() -> [String: Any] {
        [
            "credit_balance": creditBalance.map { $0 as Any } ?? NSNull(),
            "credits_fetched_at": creditsFetchedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "credits_status": creditsStatus.map { $0 as Any } ?? NSNull(),
            "plan_title": planTitle.map { $0 as Any } ?? NSNull(),
        ]
    }
}

/// One entry of the NAS v2 snapshot's fixed four-service envelope. `ok`,
/// `stale`, and `error` are carried through as-is — this layer never
/// invents a successful read out of a failed one, and never zeroes out a
/// missing value; `NASFourServiceState` keeps the last known good entry
/// across failures.
struct NASServiceEntry: Equatable {
    static let maximumItems = 8

    let id: NASServiceID
    let ok: Bool
    let fetchedAt: Date?
    let stale: Bool
    let items: [NASUsageItem]
    let error: NASServiceError?
    var actualAccountRef: String? = nil
    var historyIdentity: String? = nil
    var accountDisplay: String? = nil
    /// Soft-parsed: an unrecognizable `gemini_details` never fails the
    /// envelope the way a malformed `actual_account_ref`/`history_identity`
    /// does, so a bad credit reading cannot turn a successful quota read
    /// into an error.
    var geminiDetails: NASGeminiDetails? = nil
    /// Soft-parsed per-service `refresh_policy`; see `NASRefreshPolicy`.
    var refreshPolicy: NASRefreshPolicy? = nil

    var service: String { id.rawValue }
    var provider: String { id.provider }
    var accountRef: String? { id.accountRef }

    /// A service whose identity fields were valid but whose content broke
    /// the contract: reported as its own schema error without touching the
    /// other three services.
    static func schemaInvalid(_ id: NASServiceID) -> NASServiceEntry {
        NASServiceEntry(
            id: id,
            ok: false,
            fetchedAt: nil,
            stale: true,
            items: [],
            error: NASServiceError(code: NASServiceError.localSchemaCode, message: nil)
        )
    }

    enum ParseOutcome: Equatable {
        case entry(NASServiceEntry)
        /// `service`/`provider`/`account_ref` did not match the fixed
        /// identity: the whole envelope is untrustworthy.
        case identityMismatch
    }

    static func parse(_ value: Any?, expected id: NASServiceID, now: Date = Date()) -> ParseOutcome {
        guard let object = value as? [String: Any] else { return .identityMismatch }
        guard object["service"] as? String == id.rawValue else { return .identityMismatch }
        guard object["provider"] as? String == id.provider else { return .identityMismatch }
        if let accountRef = id.accountRef {
            guard object["account_ref"] as? String == accountRef else { return .identityMismatch }
        } else {
            guard object["account_ref"] == nil || NASJSON.isNull(object["account_ref"]) else { return .identityMismatch }
        }

        let actualAccountRef = object["actual_account_ref"] as? String
        if !NASJSON.isAbsent(object["actual_account_ref"]), actualAccountRef.map(NASExecutionHost.isSafeAccountID) != true {
            return .entry(schemaInvalid(id))
        }
        let historyIdentity = object["history_identity"] as? String
        if !NASJSON.isAbsent(object["history_identity"]), historyIdentity.map(NASExecutionHost.isSafeIdentifier) != true {
            return .entry(schemaInvalid(id))
        }
        guard let ok = NASJSON.bool(object["ok"]), let stale = NASJSON.bool(object["stale"]) else {
            return .entry(schemaInvalid(id))
        }
        var fetchedAt: Date?
        if !NASJSON.isAbsent(object["fetched_at"]) {
            guard let seconds = NASJSON.positiveTimestamp(object["fetched_at"]) else { return .entry(schemaInvalid(id)) }
            if seconds > now.timeIntervalSince1970 + 60 {
                return .entry(schemaInvalid(id))
            }
            fetchedAt = Date(timeIntervalSince1970: seconds)
        }
        guard let rawItems = object["items"] as? [Any], rawItems.count <= maximumItems else {
            return .entry(schemaInvalid(id))
        }
        var items: [NASUsageItem] = []
        for rawItem in rawItems {
            guard let item = NASUsageItem.parse(rawItem, allowsCredits: id == .codex, allowsClaudeDetails: id == .claude) else {
                return .entry(schemaInvalid(id))
            }
            items.append(item)
        }
        var error: NASServiceError?
        if !NASJSON.isAbsent(object["error"]) {
            guard let parsed = NASServiceError.parse(object["error"]) else { return .entry(schemaInvalid(id)) }
            error = parsed
        }
        // ok=true must carry values and no error; ok=false must say why.
        if ok, items.isEmpty || error != nil { return .entry(schemaInvalid(id)) }
        if !ok, error == nil { return .entry(schemaInvalid(id)) }

        var geminiDetails: NASGeminiDetails?
        if (id == .gemini || id == .gemini2), !NASJSON.isAbsent(object["gemini_details"]) {
            geminiDetails = NASGeminiDetails.parse(object["gemini_details"])
        }
        var refreshPolicy: NASRefreshPolicy?
        if !NASJSON.isAbsent(object["refresh_policy"]) {
            refreshPolicy = NASRefreshPolicy.parse(object["refresh_policy"])
        }

        let display = (object["account_display"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountDisplay = display.flatMap { value in
            !value.isEmpty && value.count <= 254 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? value : nil
        }
        return .entry(NASServiceEntry(
            id: id, ok: ok, fetchedAt: fetchedAt, stale: stale, items: items, error: error,
            actualAccountRef: actualAccountRef, historyIdentity: historyIdentity, accountDisplay: accountDisplay,
            geminiDetails: geminiDetails, refreshPolicy: refreshPolicy
        ))
    }

    func jsonObject() -> [String: Any] {
        [
            "service": service,
            "provider": provider,
            "account_ref": accountRef.map { $0 as Any } ?? NSNull(),
            "actual_account_ref": actualAccountRef.map { $0 as Any } ?? NSNull(),
            "history_identity": historyIdentity.map { $0 as Any } ?? NSNull(),
            "account_display": accountDisplay.map { $0 as Any } ?? NSNull(),
            "ok": ok,
            "fetched_at": fetchedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "stale": stale,
            "items": items.map { $0.jsonObject() },
            "error": error.map { error -> Any in
                ["code": error.code, "message": error.message.map { $0 as Any } ?? NSNull()]
            } ?? NSNull(),
            "gemini_details": geminiDetails?.jsonObject() ?? NSNull(),
            "refresh_policy": refreshPolicy?.jsonObject() ?? NSNull(),
        ]
    }
}

/// Which NAS collection pass produced the current entries, surfaced in the
/// UI as a busy/idle indicator — never used to decide whether to retry
/// locally.
struct NASCollectionState: Equatable {
    let state: String?
    let jobID: String?
    let retryAt: Date?
}

/// One sanitized `execution_hosts[]` object: which NAS-relayed execution
/// host is running which fixed Gemini account, and whether it has confirmed
/// returning. Only the whitelisted keys are read; anything else in the
/// object (bindings, gates, emails, worker paths) is never touched.
struct NASExecutionHost: Equatable {
    static let maximumHosts = 8

    let hostID: String
    let runID: String?
    /// The fixed Gemini card this host is attributed to (`account1` →
    /// `.gemini`, `account2` → `.gemini2`); never inferred.
    /// `nil` only for a non-running host that holds no account (e.g. idle).
    let executionAccount: NASServiceID?
    let phase: String?
    let stateChangedAt: Date?
    let lastHeartbeatAt: Date?
    let returnState: String?
    var selectedAccountID: String? = nil
    var selectedService: NASServiceID? = nil
    var selectedRole: String? = nil
    var selectionGeneration: String? = nil
    var observedAt: Date? = nil

    static func isSafeAccountID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        } && value.first != "_" && value.first != "-"
    }

    /// Host/run identifiers: letters, digits and `-_.:`, at most 64
    /// characters, so no email (`@`), path (`/`) or whitespace can pass.
    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "-" || $0 == "_" || $0 == "." || $0 == ":"
        }
    }

    /// `phase`/`return_state`: lowercase snake-case tokens, at most 32.
    static func isSafeToken(_ value: String) -> Bool {
        value.count <= 32 && NASServiceError.isSafeCode(value)
    }

    /// Canonical backend `return_state` values; anything else drops the host.
    static func isCanonicalReturnState(_ value: String) -> Bool {
        value == "pending" || value == "confirmed" || value == "not_required" || value == "failed"
    }

    /// Only these phases mean an account is actively executing.
    static func isRunningPhase(_ phase: String?) -> Bool {
        phase == "running" || phase == "active"
    }

    /// Whitelisted uppercase backend phase tokens normalized to lowercase.
    private static let knownUppercasePhases: [String: String] = [
        "RUNNING": "running",
        "PREPARED": "prepared",
        "READY": "ready",
        "FINISHING": "finishing",
        "COMMITTED": "committed",
        "REJECTED": "rejected",
        "ABORTED": "aborted",
    ]

    static func normalizePhase(_ value: String) -> String? {
        if let lower = knownUppercasePhases[value] {
            return lower
        }
        if isSafeToken(value) {
            return value
        }
        return nil
    }

    /// Any malformed whitelisted field drops the whole host (`nil`); the
    /// host is never partially trusted and never stringified.
    static func parse(_ value: Any?) -> NASExecutionHost? {
        guard let object = value as? [String: Any] else { return nil }
        guard let hostID = object["host_id"] as? String, isSafeIdentifier(hostID) else { return nil }
        let selectedAccountID = object["selected_account_id"] as? String
        let selectedService = (object["selected_service"] as? String).flatMap(NASServiceID.init(rawValue:))
        let selectedRole = object["role"] as? String
        if !NASJSON.isAbsent(object["selected_account_id"]) {
            guard let selectedAccountID, isSafeAccountID(selectedAccountID),
                  (selectedService == .gemini && selectedRole == "primary") || (selectedService == .gemini2 && selectedRole == "secondary")
            else { return nil }
        }
        let executionAccount: NASServiceID?
        if NASJSON.isAbsent(object["execution_account"]) {
            executionAccount = nil
        } else {
            switch object["execution_account"] as? String {
            case "account1"?: executionAccount = .gemini
            case "account2"?: executionAccount = .gemini2
            case let ref? where ref == selectedAccountID && selectedService != nil:
                executionAccount = selectedService
            default: return nil
            }
        }

        func optionalString(_ key: String, _ isSafe: (String) -> Bool) -> String?? {
            if NASJSON.isAbsent(object[key]) { return .some(nil) }
            guard let text = object[key] as? String, isSafe(text) else { return nil }
            return .some(text)
        }
        func optionalPhase(_ key: String) -> String?? {
            if NASJSON.isAbsent(object[key]) { return .some(nil) }
            guard let text = object[key] as? String, let normalized = normalizePhase(text) else { return nil }
            return .some(normalized)
        }
        func optionalTimestamp(_ key: String) -> Date?? {
            if NASJSON.isAbsent(object[key]) { return .some(nil) }
            // Host metadata only: a timestamp more than 60 s in the future
            // drops this host record (quota resets are unaffected).
            guard let seconds = NASJSON.positiveTimestamp(object[key]),
                  seconds <= Date().timeIntervalSince1970 + 60
            else { return nil }
            return .some(Date(timeIntervalSince1970: seconds))
        }
        guard let runID = optionalString("run_id", isSafeIdentifier),
              let phase = optionalPhase("phase"),
              let returnState = optionalString("return_state", isCanonicalReturnState),
              let stateChangedAt = optionalTimestamp("state_changed_at"),
              let lastHeartbeatAt = optionalTimestamp("last_heartbeat_at")
        else { return nil }
        // A running/active host must name a valid account.
        if executionAccount == nil && selectedAccountID == nil && isRunningPhase(phase) { return nil }
        guard let observedAt = optionalTimestamp("observed_at") else { return nil }
        var selectionGeneration: String?
        if !NASJSON.isAbsent(object["selection_generation"]) {
            if let n = NASJSON.integer(object["selection_generation"]), n >= 0 { selectionGeneration = String(n) }
            else if let text = object["selection_generation"] as? String, isSafeIdentifier(text) { selectionGeneration = text }
            else { return nil }
        }

        return NASExecutionHost(
            hostID: hostID,
            runID: runID,
            executionAccount: executionAccount,
            phase: phase,
            stateChangedAt: stateChangedAt,
            lastHeartbeatAt: lastHeartbeatAt,
            returnState: returnState,
            selectedAccountID: selectedAccountID,
            selectedService: selectedService,
            selectedRole: selectedRole,
            selectionGeneration: selectionGeneration,
            observedAt: observedAt
        )
    }

    func jsonObject() -> [String: Any] {
        [
            "host_id": hostID,
            "run_id": runID.map { $0 as Any } ?? NSNull(),
            "execution_account": (executionAccount?.accountRef).map { $0 as Any } ?? NSNull(),
            "phase": phase.map { $0 as Any } ?? NSNull(),
            "state_changed_at": stateChangedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "last_heartbeat_at": lastHeartbeatAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "return_state": returnState.map { $0 as Any } ?? NSNull(),
            "selected_account_id": selectedAccountID.map { $0 as Any } ?? NSNull(),
            "selected_service": selectedService.map { $0.rawValue as Any } ?? NSNull(),
            "role": selectedRole.map { $0 as Any } ?? NSNull(),
            "selection_generation": selectionGeneration.map { $0 as Any } ?? NSNull(),
            "observed_at": observedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
        ]
    }
}

/// Read-only execution-host metadata from the snapshot root. Entirely
/// optional: a missing, malformed or partly malformed value only drops the
/// affected hosts — it never rejects the envelope or touches the four
/// services' own `fetched_at`/`stale`/`error`.
struct NASHostStatus: Equatable {
    let hosts: [NASExecutionHost]
    /// Server's `auto_switch_enabled`; `nil` when absent or not a boolean
    /// (legacy NAS), so the UI never claims automatic switching is on.
    let autoSwitchEnabled: Bool?

    static func parse(
        executionHosts rawHosts: Any?,
        autoSwitchEnabled rawAutoSwitch: Any?,
        autoSwitchAvailable rawAvailable: Any? = nil
    ) -> NASHostStatus {
        var hosts: [NASExecutionHost] = []
        var seenHostIDs = Set<String>()
        if let array = rawHosts as? [Any] {
            // The 256 KiB document cap already bounds the array; at most
            // `maximumHosts` valid hosts are kept.
            for raw in array where hosts.count < NASExecutionHost.maximumHosts {
                // Invalid records drop alone; only the first valid record
                // per host ID is kept, so duplicates never repeat UI lines.
                guard let host = NASExecutionHost.parse(raw),
                      seenHostIDs.insert(host.hostID).inserted
                else { continue }
                hosts.append(host)
            }
        }
        // `auto_switch_available: false` means the state is unknown, even
        // when `auto_switch_enabled` is false; only a known false is "off".
        let autoSwitchEnabled: Bool? = NASJSON.bool(rawAvailable) == false ? nil : NASJSON.bool(rawAutoSwitch)
        return NASHostStatus(hosts: hosts, autoSwitchEnabled: autoSwitchEnabled)
    }

    func hosts(for id: NASServiceID) -> [NASExecutionHost] {
        hosts.filter { $0.executionAccount == id }
    }

    /// Hosts holding no account (idle); shown on both Gemini cards.
    var commonHosts: [NASExecutionHost] {
        hosts.filter { $0.executionAccount == nil }
    }

    func jsonObject() -> [String: Any] {
        [
            "execution_hosts": hosts.map { $0.jsonObject() },
            "auto_switch_enabled": autoSwitchEnabled.map { $0 as Any } ?? NSNull(),
        ]
    }
}

struct NASSnapshotV2: Equatable {
    let generatedAt: Date?
    let collection: NASCollectionState?
    /// Entries in the fixed `codex, claude, gemini, gemini2` order.
    let entries: [NASServiceEntry]
    var hostStatus = NASHostStatus(hosts: [], autoSwitchEnabled: nil)
    /// Report-level `refresh_policy`: NAS's own overall collection cadence,
    /// metadata only (see `NASRefreshPolicy`).
    var refreshPolicy: NASRefreshPolicy? = nil

    func entry(_ id: NASServiceID) -> NASServiceEntry {
        entries.first { $0.id == id } ?? NASServiceEntry.schemaInvalid(id)
    }

    var codex: NASServiceEntry { entry(.codex) }
    var claude: NASServiceEntry { entry(.claude) }
    var gemini: NASServiceEntry { entry(.gemini) }
    var gemini2: NASServiceEntry { entry(.gemini2) }
}

/// Strict reader/validator for the NAS's four-service v2 envelope
/// (`schema_version` exactly the integer 2, `quota_origin == "nas"`, and
/// `services` exactly `codex, claude, gemini, gemini2` in that order, each
/// with its fixed `provider`/`account_ref`). Root-level deviations — an
/// unknown schema, a missing/extra/duplicate/reordered service, or a wrong
/// identity pairing — reject the whole envelope with `nil`. A single
/// service whose *content* breaks the contract becomes that service's own
/// `schema_changed` error so the other three keep their values. This parser
/// never falls back to the legacy shape or to a local collector.
enum NASSnapshotV2Core {
    static func parse(_ data: Data, now: Date = Date()) -> NASSnapshotV2? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard NASJSON.integer(object["schema_version"]) == 2 else { return nil }
        guard (object["quota_origin"] as? String) == "nas" else { return nil }
        guard let rawServices = object["services"] as? [Any], rawServices.count == NASServiceID.allCases.count else { return nil }

        var entries: [NASServiceEntry] = []
        for (raw, id) in zip(rawServices, NASServiceID.allCases) {
            switch NASServiceEntry.parse(raw, expected: id, now: now) {
            case .identityMismatch: return nil
            case .entry(let entry): entries.append(entry)
            }
        }

        var generatedAt: Date?
        if !NASJSON.isAbsent(object["generated_at"]) {
            guard let seconds = NASJSON.positiveTimestamp(object["generated_at"]) else { return nil }
            if seconds > now.timeIntervalSince1970 + 60 {
                return nil
            }
            generatedAt = Date(timeIntervalSince1970: seconds)
        }
        let hostStatus = NASHostStatus.parse(
            executionHosts: object["execution_hosts"],
            autoSwitchEnabled: object["auto_switch_enabled"],
            autoSwitchAvailable: object["auto_switch_available"]
        )
        let collection: NASCollectionState? = (object["collection"] as? [String: Any]).map { raw in
            NASCollectionState(
                state: raw["state"] as? String,
                jobID: raw["job_id"] as? String,
                retryAt: NASJSON.positiveTimestamp(raw["retry_at"]).map { Date(timeIntervalSince1970: $0) }
            )
        }
        var refreshPolicy: NASRefreshPolicy?
        if !NASJSON.isAbsent(object["refresh_policy"]) {
            refreshPolicy = NASRefreshPolicy.parse(object["refresh_policy"])
        }
        return NASSnapshotV2(generatedAt: generatedAt, collection: collection, entries: entries, hostStatus: hostStatus, refreshPolicy: refreshPolicy)
    }
}

/// Converts one NAS service entry's sanitized `items` into the
/// provider-specific snapshot types the panel already renders. Every item
/// is selected by its exact name and window; a missing or duplicated
/// selection is "unknown", never the first match or a borrowed value.
enum NASItemMappingCore {
    private static func unique(_ items: [NASUsageItem], window: NASUsageItem.Window, matching: (String) -> Bool) -> NASUsageItem? {
        let matches = items.filter { $0.window == window && matching($0.name) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Only the "Gemini Models" quota group. The separate "Claude and GPT
    /// models" pool is never read into a Gemini card.
    static func isGeminiModelsItem(_ name: String) -> Bool {
        name.hasPrefix("Gemini Models")
    }

    static func geminiSnapshot(from entry: NASServiceEntry) -> GeminiUsageSnapshot? {
        guard entry.ok, entry.id == .gemini || entry.id == .gemini2, let fetchedAt = entry.fetchedAt else { return nil }
        let session = unique(entry.items, window: .session, matching: isGeminiModelsItem)
        let weekly = unique(entry.items, window: .weekly, matching: isGeminiModelsItem)
        guard session != nil || weekly != nil else { return nil }
        // `credits_status == "unavailable"` or an absent `gemini_details`
        // both map to a nil `creditBalance` — a missing reading, never a
        // confirmed zero — so the quota rows above are never downgraded.
        let creditBalance = entry.geminiDetails?.creditsStatus == "ok" ? entry.geminiDetails?.creditBalance : nil
        return GeminiUsageSnapshot(
            weeklyRemainingFraction: weekly?.remainingFraction,
            weeklyResetsAt: weekly?.resetsAt,
            fiveHourRemainingFraction: session?.remainingFraction,
            fiveHourResetsAt: session?.resetsAt,
            creditBalance: creditBalance,
            publishedAt: fetchedAt,
            accountEmail: entry.accountDisplay,
            planTitle: entry.geminiDetails?.planTitle
        )
    }

    /// Codex's item named `codex` with the weekly window is the existing
    /// primary (weekly) quota — `usedPercent`, a 10080-minute window, and its
    /// reset — and its `credits` object fills the existing credit fields.
    /// Codex has no NAS-side account identity, so `accountID` stays nil
    /// rather than borrowing the local Mac's.
    static func codexSnapshot(from entry: NASServiceEntry) -> RateLimitSnapshot? {
        guard entry.ok, entry.id == .codex, let fetchedAt = entry.fetchedAt else { return nil }
        guard let weekly = unique(entry.items, window: .weekly, matching: { $0 == "codex" }) else { return nil }
        return RateLimitSnapshot(
            accountID: entry.accountDisplay,
            planType: weekly.codexPlanType,
            usedPercent: 100 - weekly.remainingPercent,
            windowDurationMinutes: NASUsageItem.Window.weekly.minutes,
            resetsAt: weekly.resetsAt,
            resetCredits: weekly.codexResetCreditsAvailable,
            creditBalance: weekly.creditBalance,
            sparkUsedPercent: nil,
            sparkWindowDurationMinutes: nil,
            sparkResetsAt: nil,
            detailedCreditsReturned: weekly.hasCredits,
            updatedAt: fetchedAt,
            creditsUnlimited: weekly.creditsUnlimited
        )
    }

    /// Claude's overall meters are the items named `전체`; Fable (any case)
    /// and any other named weekly model limit go to `modelWeeklyLimits`.
    static func claudeSnapshot(from entry: NASServiceEntry) -> ClaudeUsageSnapshot? {
        guard entry.ok, entry.id == .claude, let fetchedAt = entry.fetchedAt else { return nil }
        let overallName = "전체"
        let session = unique(entry.items, window: .session, matching: { $0 == overallName })
        let weekly = unique(entry.items, window: .weekly, matching: { $0 == overallName })

        var modelLimits: [ClaudeModelWeeklyLimit] = []
        let modelNames = entry.items
            .filter { $0.window == .weekly && $0.name != overallName }
            .map(\.name)
        var seen = Set<String>()
        for name in modelNames where seen.insert(name.lowercased()).inserted {
            guard let item = unique(entry.items, window: .weekly, matching: { $0.lowercased() == name.lowercased() }) else { continue }
            let displayName = name.lowercased() == "fable" ? "Fable" : name
            modelLimits.append(ClaudeModelWeeklyLimit(
                modelName: displayName,
                usedPercent: 100 - item.remainingPercent,
                resetsAt: item.resetsAt
            ))
        }

        guard session != nil || weekly != nil || !modelLimits.isEmpty else { return nil }
        // `claude_details` lives on the `전체` item; it can arrive on either
        // the weekly or session entry, so both are checked, weekly first.
        let details = weekly?.hasClaudeDetails == true ? weekly : (session?.hasClaudeDetails == true ? session : nil)
        let planTitle = details?.claudePlanType.flatMap(ClaudePlanCore.title(fromNASPlanType:))
        let extraUsage = claudeExtraUsage(from: details?.claudeExtraUsage)
        return ClaudeUsageSnapshot(
            quotaSource: "nas",
            weeklyUsedPercent: weekly.map { 100 - $0.remainingPercent },
            weeklyResetsAt: weekly?.resetsAt,
            fiveHourUsedPercent: session.map { 100 - $0.remainingPercent },
            fiveHourResetsAt: session?.resetsAt,
            publishedAt: fetchedAt,
            modelWeeklyLimits: modelLimits,
            extraUsage: extraUsage,
            limitResets: details?.claudeLimitResets,
            account: entry.accountDisplay.map { ClaudeAccountInfo(email: $0, organizationName: nil, organizationUUID: nil) },
            planTitle: planTitle
        )
    }

    /// `monthly_limit_minor`/`used_minor` are converted into the
    /// cents-denominated `ClaudeExtraUsage` fields only when the currency is
    /// confirmedly `USD` and the exponent is known. Unknown currency/exponent leaves the
    /// monetary fields `nil` rather than mislabeling an unconvertible amount
    /// as dollars. `isEnabled` and `currency` pass through independently of
    /// that conversion so a known `false` still renders as "disabled".
    static func claudeExtraUsage(from raw: NASClaudeExtraUsage?) -> ClaudeExtraUsage? {
        guard let raw else { return nil }
        let canConvertToCents = raw.currency == "USD" && raw.decimalPlaces != nil
        func cents(_ value: Double?) -> Double? {
            guard canConvertToCents, let value, let places = raw.decimalPlaces else { return nil }
            let converted = value * pow(10, Double(2 - places))
            return converted.isFinite ? converted : nil
        }
        let limitCents = cents(raw.monthlyLimitMinor)
        let usedCents = cents(raw.usedMinor)
        guard raw.isEnabled != nil || limitCents != nil || usedCents != nil else { return nil }
        return ClaudeExtraUsage(
            limitCents: limitCents,
            usedCents: usedCents,
            currency: canConvertToCents ? raw.currency : nil,
            isEnabled: raw.isEnabled
        )
    }

    static func isUsable(_ entry: NASServiceEntry) -> Bool {
        switch entry.id {
        case .codex: return codexSnapshot(from: entry) != nil
        case .claude: return claudeSnapshot(from: entry) != nil
        case .gemini, .gemini2: return geminiSnapshot(from: entry) != nil
        }
    }
}

/// Per-card NAS state: the last entry that actually mapped to values, plus
/// why the most recent read (if any) did not replace it.
struct NASServiceSlot: Equatable {
    var lastGood: NASServiceEntry?
    var retryAt: Date? = nil
    /// True when the values on screen are not the latest successful read:
    /// the NAS marked them stale, a later read failed, or they were
    /// restored from disk at launch.
    var isStale: Bool = true
    /// Fixed label for the latest failure (service error, schema problem, or
    /// transport failure). `nil` once a fresh usable entry arrives.
    var issue: String?
}

/// The NAS side of the four cards, kept entirely separate from the local
/// Mac collectors' state. A failure — of one service, of the whole
/// envelope, or of the SSH transport — only records an issue label; it
/// never erases a card's last known values and never borrows another
/// card's, so Gemini account1/account2 can never swap or blank each other.
struct NASFourServiceState: Equatable {
    static let cacheVersion = 1

    private(set) var slots: [NASServiceID: NASServiceSlot] = Dictionary(
        uniqueKeysWithValues: NASServiceID.allCases.map { ($0, NASServiceSlot()) }
    )

    /// Last execution-host metadata the NAS sent; `nil` until the first
    /// NAS read (or cache restore). Replaced wholesale on every readable
    /// envelope, independent of the per-service slots.
    private(set) var hostStatus: NASHostStatus?
    /// True when `hostStatus` came from the cache or a later read failed.
    private(set) var hostStatusIsStale = true

    func slot(_ id: NASServiceID) -> NASServiceSlot {
        slots[id] ?? NASServiceSlot()
    }

    mutating func apply(_ snapshot: NASSnapshotV2) {
        hostStatus = snapshot.hostStatus
        hostStatusIsStale = false
        for id in NASServiceID.allCases {
            let entry = snapshot.entry(id)
            var slot = self.slot(id)
            slot.retryAt = entry.ok ? nil : entry.refreshPolicy?.nextRefreshAt
            let previousAccount = slot.lastGood?.actualAccountRef ?? id.accountRef
            let incomingAccount = entry.actualAccountRef ?? id.accountRef
            if previousAccount != incomingAccount { slot.lastGood = nil }
            if NASItemMappingCore.isUsable(entry) {
                slot.lastGood = entry
                slot.isStale = entry.stale
                slot.issue = nil
            } else {
                slot.isStale = true
                slot.issue = entry.error?.label ?? "NAS 값 형식 확인 필요"
            }
            slots[id] = slot
        }
    }

    /// Transport failure or an unreadable envelope: every card keeps its
    /// values and shows the same failure label.
    mutating func applyFailure(label: String) {
        hostStatusIsStale = true
        for id in NASServiceID.allCases {
            var slot = self.slot(id)
            slot.isStale = true
            slot.issue = label
            slots[id] = slot
        }
    }

    var codexSnapshot: RateLimitSnapshot? { slot(.codex).lastGood.flatMap(NASItemMappingCore.codexSnapshot(from:)) }
    var claudeSnapshot: ClaudeUsageSnapshot? { slot(.claude).lastGood.flatMap(NASItemMappingCore.claudeSnapshot(from:)) }
    var geminiSnapshot: GeminiUsageSnapshot? { slot(.gemini).lastGood.flatMap(NASItemMappingCore.geminiSnapshot(from:)) }
    var gemini2Snapshot: GeminiUsageSnapshot? { slot(.gemini2).lastGood.flatMap(NASItemMappingCore.geminiSnapshot(from:)) }

    /// NAS 실행 범위의 명시 선택을 idle에서도 유지한다. 다른 호스트는 이를 바꾸지 않는다.
    var selectedGeminiServiceID: NASServiceID {
        guard let hostStatus, hostStatus.autoSwitchEnabled == true,
              let host = hostStatus.hosts.first(where: { $0.hostID == "nas" })
        else { return .gemini }
        if host.selectedAccountID != nil, let service = host.selectedService { return service }
        return NASExecutionHost.isRunningPhase(host.phase) ? (host.executionAccount ?? .gemini) : .gemini
    }

    private var selectedNASAccountID: String? {
        guard hostStatus?.autoSwitchEnabled == true else { return nil }
        return hostStatus?.hosts.first(where: { $0.hostID == "nas" })?.selectedAccountID
    }

    var selectedGeminiSnapshot: GeminiUsageSnapshot? {
        let id = selectedGeminiServiceID
        if let selectedNASAccountID,
           selectedNASAccountID != (slot(id).lastGood?.actualAccountRef ?? id.accountRef) { return nil }
        return id == .gemini2 ? gemini2Snapshot : geminiSnapshot
    }

    func canShowHistory(_ series: NASHistorySeries?, for id: NASServiceID) -> Bool {
        guard let entry = slot(id).lastGood else { return false }
        if let selectedNASAccountID, selectedNASAccountID != (entry.actualAccountRef ?? id.accountRef) { return false }
        if let expected = entry.historyIdentity { return series?.identityGeneration == expected }
        return entry.actualAccountRef == nil || entry.actualAccountRef == id.accountRef
    }

    /// Persists only the last good entries, in the same sanitized shape the
    /// NAS sent, under their fixed service IDs.
    func encodedCache() -> Data? {
        var services: [String: Any] = [:]
        for id in NASServiceID.allCases {
            if let entry = slot(id).lastGood { services[id.rawValue] = entry.jsonObject() }
        }
        var root: [String: Any] = ["version": Self.cacheVersion, "source": "nas", "services": services]
        if let hostStatus { root["host_status"] = hostStatus.jsonObject() }
        return try? JSONSerialization.data(withJSONObject: root)
    }

    /// Restores cached entries through the same strict per-service parser.
    /// Restored values are always shown as stale until a new NAS read lands.
    static func decodeCache(_ data: Data) -> NASFourServiceState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NASJSON.integer(root["version"]) == cacheVersion,
              root["source"] as? String == "nas",
              let services = root["services"] as? [String: Any]
        else { return nil }
        var state = NASFourServiceState()
        for id in NASServiceID.allCases {
            guard let raw = services[id.rawValue],
                  case .entry(let entry) = NASServiceEntry.parse(raw, expected: id),
                  NASItemMappingCore.isUsable(entry)
            else { continue }
            state.slots[id] = NASServiceSlot(lastGood: entry, isStale: true, issue: nil)
        }
        // Optional, additive key: caches written before it existed simply
        // restore without host status.
        if let rawHostStatus = root["host_status"] as? [String: Any] {
            state.hostStatus = NASHostStatus.parse(
                executionHosts: rawHostStatus["execution_hosts"],
                autoSwitchEnabled: rawHostStatus["auto_switch_enabled"]
            )
        }
        return state
    }
}

/// 실행·호스트 진단은 카드 밖에서 다룬다.
enum NASHostStatusPresentation {
    static func footerLines(for _: NASServiceID, state _: NASFourServiceState, source _: DataCollectionSource) -> [String] {
        [] // 호스트·전환 진단은 카드에 표시하지 않는다.
    }
}

enum NASHistoryUnit: String, Equatable {
    case percent, credits
}

/// One point of a NAS v2 history series: a consumption amount inside one
/// baseline segment. Points are never re-diffed or summed across segments.
struct NASHistoryPoint: Equatable {
    let at: Date
    let consumed: Double
    let unit: NASHistoryUnit
    let segmentId: String
}

struct NASHistorySeries: Equatable {
    let identityGeneration: String?
    let points: [NASHistoryPoint]
}

/// The NAS's consumption-history v2 envelope: `schemaVersion == 2`,
/// `source == "nas"`, and exactly the six fixed series keys below — one
/// series per metric bucket, with Gemini's second account kept fully
/// independent rather than folded into the first.
struct NASHistoryV2: Equatable {
    static let seriesKeys = ["codex", "codexCredits", "claude", "claudeFable", "gemini", "gemini2"]

    /// Each series has exactly one unit: credits only for `codexCredits`.
    static func unit(for key: String) -> NASHistoryUnit {
        key == "codexCredits" ? .credits : .percent
    }

    let generatedAt: Date
    let series: [String: NASHistorySeries]
}

/// What the `--history-json` helper produced.
enum NASHistoryReadResult: Equatable {
    case history(NASHistoryV2)
    /// The helper's own `{ok:false,error:{code,message}}` (e.g.
    /// `not_collected`, `schema_changed`, `storage_unavailable`). Never an
    /// empty history.
    case helperError(NASServiceError)
    case invalid
}

/// Strict reader for the NAS consumption-history v2 output. Any deviation —
/// a non-integer or unknown `schemaVersion`, a missing/extra root or series
/// key, more than 40 points, a non-positive or non-finite time, a negative,
/// boolean or non-finite `consumed`, a unit that differs from the series'
/// fixed unit, or an empty/oversized/odd `segmentId` — rejects the whole
/// envelope rather than partially accepting it.
enum NASHistoryV2Core {
    static let maximumPointsPerSeries = 40
    static let maximumSegmentIDLength = 64
    static let maximumIdentityGenerationLength = 128
    private static let rootKeys: Set<String> = ["schemaVersion", "generatedAt", "source", "series"]
    private static let seriesObjectKeys: Set<String> = ["identityGeneration", "points"]
    private static let pointKeys: Set<String> = ["at", "consumed", "unit", "segmentId"]

    static func parse(_ data: Data, now: Date = Date()) -> NASHistoryV2? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object: object, now: now)
    }

    static func parse(object: [String: Any], now: Date = Date()) -> NASHistoryV2? {
        // The SSH helper adds `ok: true` to a successful read; nothing else
        // may appear beside the four fixed root keys.
        var keys = Set(object.keys)
        if keys.contains("ok") {
            guard NASJSON.bool(object["ok"]) == true else { return nil }
            keys.remove("ok")
        }
        guard keys == rootKeys else { return nil }
        guard NASJSON.integer(object["schemaVersion"]) == 2 else { return nil }
        guard (object["source"] as? String) == "nas" else { return nil }
        guard let generatedAtMillis = NASJSON.positiveTimestamp(object["generatedAt"]) else { return nil }
        let generatedAtSeconds = generatedAtMillis / 1000
        if generatedAtSeconds > now.timeIntervalSince1970 + 300 {
            return nil
        }
        guard let rawSeries = object["series"] as? [String: Any] else { return nil }
        guard Set(rawSeries.keys) == Set(NASHistoryV2.seriesKeys) else { return nil }

        var series: [String: NASHistorySeries] = [:]
        for key in NASHistoryV2.seriesKeys {
            guard let parsed = parseSeries(rawSeries[key], unit: NASHistoryV2.unit(for: key), now: now) else { return nil }
            series[key] = parsed
        }
        return NASHistoryV2(generatedAt: Date(timeIntervalSince1970: generatedAtSeconds), series: series)
    }

    /// Classifies the helper's stdout together with its exit status. A
    /// structured failure body is reported as that failure; a success body
    /// is only accepted from a zero exit.
    static func interpret(stdout: Data, exitStatus: Int32, now: Date = Date()) -> NASHistoryReadResult {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else { return .invalid }
        if NASJSON.bool(object["ok"]) == false {
            guard Set(object.keys) == ["ok", "error"], let error = NASServiceError.parse(object["error"]) else { return .invalid }
            return .helperError(error)
        }
        guard exitStatus == 0, let history = parse(object: object, now: now) else { return .invalid }
        return .history(history)
    }

    /// Re-serializes a parsed history in the exact v2 shape (without the
    /// helper's `ok` flag) for the NAS-only on-disk cache, so a relaunch can
    /// restore it through the same strict `parse`.
    static func encode(_ history: NASHistoryV2) -> Data? {
        var series: [String: Any] = [:]
        for key in NASHistoryV2.seriesKeys {
            guard let value = history.series[key] else { return nil }
            series[key] = [
                "identityGeneration": value.identityGeneration.map { $0 as Any } ?? NSNull(),
                "points": value.points.map { point -> [String: Any] in
                    [
                        "at": (point.at.timeIntervalSince1970 * 1000).rounded(),
                        "consumed": point.consumed,
                        "unit": point.unit.rawValue,
                        "segmentId": point.segmentId,
                    ]
                },
            ]
        }
        let root: [String: Any] = [
            "schemaVersion": 2,
            "generatedAt": (history.generatedAt.timeIntervalSince1970 * 1000).rounded(),
            "source": "nas",
            "series": series,
        ]
        return try? JSONSerialization.data(withJSONObject: root)
    }

    static func isValidSegmentID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumSegmentIDLength && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func parseSeries(_ value: Any?, unit: NASHistoryUnit, now: Date = Date()) -> NASHistorySeries? {
        guard let raw = value as? [String: Any], Set(raw.keys) == seriesObjectKeys else { return nil }
        // The key is required (checked above) and must be a string or null.
        let identityGeneration: String?
        if NASJSON.isNull(raw["identityGeneration"]) {
            identityGeneration = nil
        } else if let value = raw["identityGeneration"] as? String,
                  !value.isEmpty, value.count <= maximumIdentityGenerationLength {
            identityGeneration = value
        } else {
            return nil
        }
        guard let rawPoints = raw["points"] as? [Any], rawPoints.count <= maximumPointsPerSeries else { return nil }

        var points: [NASHistoryPoint] = []
        points.reserveCapacity(rawPoints.count)
        var lastAtMillis: Double?
        for rawPoint in rawPoints {
            guard let point = rawPoint as? [String: Any], Set(point.keys) == pointKeys else { return nil }
            guard let atMillis = NASJSON.positiveTimestamp(point["at"]) else { return nil }
            if (atMillis / 1000) > now.timeIntervalSince1970 + 300 {
                return nil
            }
            if let last = lastAtMillis, atMillis <= last {
                return nil
            }
            lastAtMillis = atMillis
            guard let consumed = NASJSON.number(point["consumed"]), consumed >= 0 else { return nil }
            guard (point["unit"] as? String) == unit.rawValue else { return nil }
            guard let segmentId = point["segmentId"] as? String, isValidSegmentID(segmentId) else { return nil }
            points.append(NASHistoryPoint(
                at: Date(timeIntervalSince1970: atMillis / 1000),
                consumed: consumed,
                unit: unit,
                segmentId: segmentId
            ))
        }
        return NASHistorySeries(identityGeneration: identityGeneration, points: points)
    }
}

/// Keeps the last known-good parsed history across a NAS fetch/parse
/// failure, so an unknown schema, a helper error, or a transport failure
/// never blanks out a chart that still has a good earlier reading — and
/// never substitutes local history for it.
enum NASHistoryV2Cache {
    static func apply(_ result: NASHistoryReadResult, previous: NASHistoryV2?) -> (history: NASHistoryV2?, failureLabel: String?) {
        switch result {
        case .history(let history): return (history, nil)
        case .helperError(let error): return (previous, "이력 \(error.label)")
        case .invalid: return (previous, "NAS 이력 형식 확인 불가")
        }
    }
}

/// Chart projection of one NAS history series. Each point is already a
/// per-refresh consumption amount inside its own segment, so points are
/// only ordered by time — never re-diffed, and never added across segments,
/// units or accounts. A point whose unit differs from the strip's unit is
/// dropped rather than drawn on the wrong scale.
enum NASHistoryChartCore {
    static func samples(_ series: NASHistorySeries?, unit: NASHistoryUnit) -> [UsageConsumptionSample] {
        guard let series else { return [] }
        return series.points
            .filter { $0.unit == unit }
            .sorted { $0.at < $1.at }
            .map { UsageConsumptionSample(at: $0.at, amount: $0.consumed) }
    }

    static func segmentCount(_ series: NASHistorySeries?) -> Int {
        Set(series?.points.map(\.segmentId) ?? []).count
    }
}

/// Global collection-source gating. Local collectors (Codex app-server,
/// Claude OAuth, Gemini `agy`/account metadata, Gemini web) only run in the
/// explicit local mode, and a result is only accepted if it was requested
/// under the source and switch generation that are still current — so an
/// in-flight local read finishing after a switch to NAS (or vice versa) is
/// dropped instead of overwriting the other source's values.
enum DataSourceGate {
    static func allowsLocalCollection(_ source: DataCollectionSource) -> Bool {
        source == .localMac
    }

    static func accepts(
        resultFrom origin: DataCollectionSource,
        generation: Int,
        current: DataCollectionSource,
        currentGeneration: Int
    ) -> Bool {
        origin == current && generation == currentGeneration
    }
}

/// Snapshot parsed from the visible text of `https://gemini.google.com/usage`
/// ("Gemini 온라인"). Only the two usage percentages and their visible reset
/// captions are kept — never any other page content — and the reset captions
/// stay as the page's own wording (e.g. "오전 2:08에 초기화") rather than a
/// guessed timestamp CCMB cannot verify.
struct GeminiOnlineUsageSnapshot: Sendable, Equatable, Codable {
    /// "현재 사용량" section, the web app's session window.
    let sessionUsedPercent: Double?
    let sessionResetText: String?
    /// "주간 한도" section.
    let weeklyUsedPercent: Double?
    let weeklyResetText: String?
    let accountEmail: String?
    let fetchedAt: Date
}

/// Pure parsing, freshness, persistence, and shared-payload logic for the
/// Gemini web usage page. Deliberately has no knowledge of WebKit — the
/// AppKit-side `GeminiOnlineWebController` hands it the rendered page's
/// visible text, and this either returns real numbers or `nil`. It never
/// guesses when the page structure has changed.
enum GeminiOnlineUsageCore {
    /// The page is only re-read on a conservative background cadence, so its
    /// values stay presentable for a longer window than CLI-fetched data
    /// before being flagged as stale.
    static let sharedFreshForSeconds: TimeInterval = 1_800
    static let minimumQuietRefreshIntervalSeconds: TimeInterval = 900

    static let snapshotDefaultsKey = "geminiOnlineUsageSnapshotV1"
    static let hasConnectedDefaultsKey = "geminiOnlineHasConnectedV1"

    static func remainingPercent(from usedPercent: Double?) -> Double? {
        guard let usedPercent else { return nil }
        return min(max(100 - usedPercent, 0), 100)
    }

    static func isFresh(fetchedAt: Date?, now: Date, freshForSeconds: TimeInterval = sharedFreshForSeconds) -> Bool {
        guard let fetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) <= freshForSeconds
    }

    /// Parses the usage page's visible text. The Korean and English section
    /// headers are both recognized; any other shape returns `nil`, so a page
    /// redesign degrades to "확인 불가" instead of a wrong number. Sections
    /// are bounded so parsing never wanders into unrelated page content.
    static func parse(visibleText: String, now: Date = Date()) -> GeminiOnlineUsageSnapshot? {
        guard let sessionHeader = firstRange(
                  of: ["현재 사용량", "Current usage"],
                  in: visibleText,
                  from: visibleText.startIndex
              ),
              let weeklyHeader = firstRange(
                  of: ["주간 한도", "Weekly limit"],
                  in: visibleText,
                  from: sessionHeader.upperBound
              )
        else { return nil }

        let sessionSection = boundedSection(of: visibleText, from: sessionHeader.upperBound, to: weeklyHeader.lowerBound)
        let weeklySection = boundedSection(of: visibleText, from: weeklyHeader.upperBound, to: visibleText.endIndex)
        let sessionUsed = usedPercent(in: sessionSection)
        let weeklyUsed = usedPercent(in: weeklySection)
        guard sessionUsed != nil || weeklyUsed != nil else { return nil }

        return GeminiOnlineUsageSnapshot(
            sessionUsedPercent: sessionUsed,
            sessionResetText: resetText(in: sessionSection),
            weeklyUsedPercent: weeklyUsed,
            weeklyResetText: resetText(in: weeklySection),
            accountEmail: email(in: visibleText),
            fetchedAt: now
        )
    }

    private static func email(in text: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(text[range])
    }

    /// Distinguishes "signed out" from "page structure changed" after a
    /// parse failure, so the recovery message can honestly say which one.
    static func textLooksSignedOut(_ text: String) -> Bool {
        let markers = ["로그인", "Sign in", "계정 선택", "Choose an account"]
        return markers.contains { text.range(of: $0, options: [.caseInsensitive]) != nil }
    }

    // MARK: - Persistence (parsed snapshot only, never page content)

    static func loadPersistedSnapshot(defaults: UserDefaults = .standard) -> GeminiOnlineUsageSnapshot? {
        guard let data = defaults.data(forKey: snapshotDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(GeminiOnlineUsageSnapshot.self, from: data)
    }

    static func persist(_ snapshot: GeminiOnlineUsageSnapshot, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotDefaultsKey)
        defaults.set(true, forKey: hasConnectedDefaultsKey)
    }

    /// Whether a CCMB-owned WebKit session has ever produced a snapshot.
    /// Background quiet refresh is gated on this, so CCMB never loads the
    /// sign-in flow behind the user's back.
    static func hasConnectedBefore(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hasConnectedDefaultsKey)
    }

    /// Nested `online` object written under the shared file's `gemini`
    /// payload. Returns `nil` when there is no snapshot, so the shared file
    /// only ever carries truthful fields. `fiveHour*` names mirror the
    /// sibling CLI fields; reset values stay as the page's visible captions.
    static func sharedPayload(from snapshot: GeminiOnlineUsageSnapshot?, now: Date = Date()) -> [String: Any]? {
        guard let snapshot else { return nil }
        let ageSeconds = max(0, Int(now.timeIntervalSince(snapshot.fetchedAt)))
        let fresh = isFresh(fetchedAt: snapshot.fetchedAt, now: now)
        return [
            "source": "gemini-web-usage-page",
            "status": (snapshot.sessionUsedPercent == nil && snapshot.weeklyUsedPercent == nil)
                ? "partial"
                : (fresh ? "ok" : "stale"),
            "fiveHourUsedPercent": snapshot.sessionUsedPercent ?? NSNull(),
            "fiveHourRemainingPercent": remainingPercent(from: snapshot.sessionUsedPercent) ?? NSNull(),
            "fiveHourResetText": snapshot.sessionResetText ?? NSNull(),
            "weeklyUsedPercent": snapshot.weeklyUsedPercent ?? NSNull(),
            "weeklyRemainingPercent": remainingPercent(from: snapshot.weeklyUsedPercent) ?? NSNull(),
            "weeklyResetText": snapshot.weeklyResetText ?? NSNull(),
            "fetchedAt": sharedISO8601Formatter.string(from: snapshot.fetchedAt),
            "ageSeconds": ageSeconds,
            "freshForSeconds": Int(sharedFreshForSeconds),
            "fresh": fresh
        ]
    }

    /// Recomputes a stored `online` payload's `ageSeconds`/`fresh` from its
    /// own `fetchedAt` on a cache read, mirroring the sibling providers.
    static func refreshedSharedPayload(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var output = payload
        let fetchedAt = (payload["fetchedAt"] as? String).flatMap(sharedISO8601Formatter.date(from:))
        let freshForSeconds = (payload["freshForSeconds"] as? NSNumber)?.doubleValue ?? sharedFreshForSeconds
        output["ageSeconds"] = fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? NSNull()
        output["fresh"] = isFresh(fetchedAt: fetchedAt, now: now, freshForSeconds: freshForSeconds)
        return output
    }

    // MARK: - Private helpers

    private static func firstRange(
        of candidates: [String],
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        candidates
            .compactMap { text.range(of: $0, options: [.caseInsensitive], range: start..<text.endIndex) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    /// Caps a section at a few hundred characters so a reset caption or a
    /// percentage is never matched from unrelated content further down the
    /// page.
    private static func boundedSection(of text: String, from: String.Index, to: String.Index) -> String {
        let end = text.index(from, offsetBy: 600, limitedBy: to) ?? to
        return String(text[from..<end])
    }

    private static let usedPercentRegex = try? NSRegularExpression(
        pattern: "([0-9]+(?:[.,][0-9]+)?)\\s*%\\s*(?:사용됨|used)",
        options: [.caseInsensitive]
    )

    private static func usedPercent(in section: String) -> Double? {
        guard let regex = usedPercentRegex else { return nil }
        let range = NSRange(section.startIndex..., in: section)
        guard let match = regex.firstMatch(in: section, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: section),
              let value = Double(section[valueRange].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return min(max(value, 0), 100)
    }

    /// The page's own short reset caption (e.g. "오전 2:08에 초기화"). Long
    /// lines are rejected so an unrelated sentence can never be captured.
    private static func resetText(in section: String) -> String? {
        for line in section.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 4, trimmed.count <= 60 else { continue }
            if trimmed.contains("초기화") || trimmed.range(of: "reset", options: [.caseInsensitive]) != nil {
                return trimmed
            }
        }
        return nil
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
    /// Tri-state: `nil` when the source never reported it (all existing
    /// local-origin snapshots), `true`/`false` when a NAS `claude_details`
    /// confirmed it. A known `false` is a distinct, renderable "disabled"
    /// state — never conflated with "unknown".
    let isEnabled: Bool?

    init(limitCents: Double? = nil, usedCents: Double? = nil, currency: String? = nil, isEnabled: Bool? = nil) {
        self.limitCents = limitCents
        self.usedCents = usedCents
        self.currency = currency
        self.isEnabled = isEnabled
    }
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
    /// Source of the quota percentages and their `publishedAt` timestamp.
    /// Other optional metadata may have been backfilled from an older source.
    let quotaSource: String?
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
    let limitResets: ClaudeLimitResets?
    let account: ClaudeAccountInfo?
    /// Confirmed plan display title. For a NAS-sourced snapshot this comes
    /// from `claude_details.plan_type`; for a local-only snapshot this stays
    /// `nil` — `ClaudePlanStore`'s own local file read remains the only
    /// local-only fallback, applied by the caller, not here.
    let planTitle: String?

    init(
        quotaSource: String? = nil,
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
        limitResets: ClaudeLimitResets? = nil,
        account: ClaudeAccountInfo? = nil,
        planTitle: String? = nil
    ) {
        self.quotaSource = quotaSource
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
        self.limitResets = limitResets
        self.account = account
        self.planTitle = planTitle
    }

    /// Returns a copy with `account` replaced — used to merge in a profile
    /// fetch's result without reconstructing every other field by hand.
    func withAccount(_ account: ClaudeAccountInfo?) -> ClaudeUsageSnapshot {
        ClaudeUsageSnapshot(
            quotaSource: quotaSource,
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
            limitResets: limitResets,
            account: account,
            planTitle: planTitle
        )
    }

    var hasRateLimitUsage: Bool {
        weeklyUsedPercent != nil || fiveHourUsedPercent != nil
    }
}

enum ClaudeUsageCore {
    static func limitResetsTitle(_ resets: ClaudeLimitResets?) -> String {
        guard let resets else { return "확인 불가" }
        let count = "\(resets.remainingCount)개"
        guard resets.remainingCount > 0, let usable = resets.usableNow else { return count }
        return count + (usable ? " · 사용 가능" : " · 대기")
    }

    /// The shared cache remains valid through the longest smart-refresh step
    /// plus one minute of timer leeway. Fetch failures still hide its values
    /// immediately rather than presenting stale numbers as live.
    static let sharedFreshForSeconds: TimeInterval = 660
    static let statusLineFreshForSeconds: TimeInterval = 300
    static let minimumRequestIntervalSeconds: TimeInterval = 60

    static func remainingPercent(from usedPercent: Double?) -> Double? {
        guard let usedPercent else { return nil }
        return min(max(100 - usedPercent, 0), 100)
    }

    /// The Fable-specific weekly limit, matched case-insensitively, so it can
    /// be promoted to its own quota ring instead of a lower metric row.
    static func fableWeeklyLimit(in limits: [ClaudeModelWeeklyLimit]) -> ClaudeModelWeeklyLimit? {
        limits.first { $0.modelName.caseInsensitiveCompare("Fable") == .orderedSame }
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
    /// cadence and `minimumRequestIntervalSeconds`, including manual refresh.
    static func shouldThrottleFetch(minimumInterval: TimeInterval, lastFetchDate: Date?, now: Date) -> Bool {
        guard minimumInterval > 0, let lastFetchDate else { return false }
        // The repeating timer has scheduling leeway, so requiring the full
        // interval can reject a tick that arrives a fraction early and defer
        // Claude until the next cycle (effectively doubling its cadence).
        let timerTolerance = min(1, minimumInterval * 0.05)
        return now.timeIntervalSince(lastFetchDate) < minimumInterval - timerTolerance
    }

    /// The OAuth usage endpoint is undocumented and has produced persistent
    /// 429s with missing or zero Retry-After values. Open a real circuit on
    /// the first 429 instead of turning the normal ten-minute cadence into a
    /// tight retry loop.
    static let defaultRateLimitBackoffSeconds: TimeInterval = 3_600
    static let maximumInternalRateLimitBackoffSeconds: TimeInterval = 21_600

    static func circuitBreakerBackoffSeconds(consecutiveRateLimits: Int) -> TimeInterval {
        let step = max(1, min(consecutiveRateLimits, 4))
        let multiplier = pow(2.0, Double(step - 1))
        return min(defaultRateLimitBackoffSeconds * multiplier, maximumInternalRateLimitBackoffSeconds)
    }

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
    static func rateLimitBackoffSeconds(
        retryAfterHeader: String?,
        consecutiveRateLimits: Int = 1,
        now: Date
    ) -> TimeInterval {
        max(
            parseRetryAfterSeconds(retryAfterHeader, now: now) ?? 0,
            circuitBreakerBackoffSeconds(consecutiveRateLimits: consecutiveRateLimits)
        )
    }

    /// Whether a Claude usage fetch should be skipped entirely because a
    /// prior 429's backoff window hasn't elapsed yet.
    static func shouldSkipRateLimitBackoff(retryAt: Date?, now: Date) -> Bool {
        guard let retryAt else { return false }
        return now < retryAt
    }

    /// Concise Korean label for a 429 backoff, e.g.
    /// `429 · 59분 후 재시도`.
    /// Recomputed from `now` on every call so the same stored `retryAt` keeps
    /// counting down correctly across repeated UI refreshes without a new fetch.
    static func rateLimitRetryLabel(retryAt: Date, now: Date) -> String {
        let remainingSeconds = max(0, Int(ceil(retryAt.timeIntervalSince(now))))
        let duration: String
        if remainingSeconds >= 3_600 {
            let totalMinutes = Int(ceil(Double(remainingSeconds) / 60))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            duration = minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
        } else if remainingSeconds >= 60 {
            duration = "\(Int(ceil(Double(remainingSeconds) / 60)))분"
        } else {
            duration = "\(remainingSeconds)초"
        }
        return "429 · \(duration) 후 재시도"
    }

    static func sharedPayload(from snapshot: ClaudeUsageSnapshot?, now: Date = Date()) -> [String: Any] {
        guard let snapshot else {
            return [
                "status": "unavailable",
                "source": "unavailable",
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
                "limitResets": NSNull(),
                "account": NSNull(),
                "planTitle": NSNull()
            ]
        }

        let ageSeconds = snapshot.publishedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        let freshForSeconds = snapshot.quotaSource == "claude-statusline"
            ? statusLineFreshForSeconds
            : sharedFreshForSeconds
        let isCurrent = isFresh(
            publishedAt: snapshot.publishedAt,
            now: now,
            freshForSeconds: freshForSeconds
        )
        return [
            "status": !isCurrent
                ? "stale"
                : (snapshot.weeklyUsedPercent == nil && snapshot.fiveHourUsedPercent == nil ? "partial" : "ok"),
            "source": snapshot.quotaSource ?? "unknown",
            "weeklyRemainingPercent": remainingPercent(from: snapshot.weeklyUsedPercent) ?? NSNull(),
            "weeklyUsedPercent": snapshot.weeklyUsedPercent ?? NSNull(),
            "weeklyResetsAt": snapshot.weeklyResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "fiveHourRemainingPercent": remainingPercent(from: snapshot.fiveHourUsedPercent) ?? NSNull(),
            "fiveHourUsedPercent": snapshot.fiveHourUsedPercent ?? NSNull(),
            "fiveHourResetsAt": snapshot.fiveHourResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "model": snapshot.model ?? NSNull(),
            "fetchedAt": snapshot.publishedAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "ageSeconds": ageSeconds ?? NSNull(),
            "freshForSeconds": Int(freshForSeconds),
            "fresh": isCurrent,
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
                    "currency": extraUsage.currency ?? NSNull(),
                    "isEnabled": extraUsage.isEnabled ?? NSNull()
                ]
            } ?? NSNull(),
            "limitResets": snapshot.limitResets?.jsonObject() ?? NSNull(),
            "account": snapshot.account.map { account -> [String: Any] in
                [
                    "email": account.email ?? NSNull(),
                    "organizationName": account.organizationName ?? NSNull(),
                    "organizationUUID": account.organizationUUID ?? NSNull()
                ]
            } ?? NSNull(),
            "planTitle": snapshot.planTitle ?? NSNull()
        ]
    }

    static func refreshedSharedPayload(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var output = payload
        if payload["source"] == nil {
            output["source"] = "legacy-ccmb-cache"
        }
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
                currency: $0["currency"] as? String,
                isEnabled: $0["isEnabled"] as? Bool
            )
        }
        let account = (payload["account"] as? [String: Any]).map {
            ClaudeAccountInfo(
                email: $0["email"] as? String,
                organizationName: $0["organizationName"] as? String,
                organizationUUID: $0["organizationUUID"] as? String
            )
        }

        let storedSource = payload["source"] as? String
        let restoredSource = storedSource == nil || storedSource == "unknown"
            ? "legacy-ccmb-cache"
            : storedSource
        let snapshot = ClaudeUsageSnapshot(
            quotaSource: restoredSource,
            model: payload["model"] as? String,
            weeklyUsedPercent: number("weeklyUsedPercent"),
            weeklyResetsAt: date("weeklyResetsAt"),
            fiveHourUsedPercent: number("fiveHourUsedPercent"),
            fiveHourResetsAt: date("fiveHourResetsAt"),
            publishedAt: date("fetchedAt"),
            modelWeeklyLimits: modelWeeklyLimits,
            extraUsage: extraUsage,
            limitResets: ClaudeLimitResets.parse(payload["limitResets"]),
            account: account,
            planTitle: payload["planTitle"] as? String
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
            quotaSource: preferred.quotaSource ?? fallback.quotaSource,
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
            limitResets: preferred.limitResets,
            account: preferred.account ?? fallback.account,
            planTitle: preferred.planTitle ?? fallback.planTitle
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
        guard cacheDate > currentDate else {
            return merge(preferred: current, fallback: cache)
        }

        if cache.hasRateLimitUsage {
            // The official statusLine payload owns primary quota fields when
            // it is newer. Do not make an old missing quota look freshly
            // updated by backfilling it from a prior OAuth snapshot.
            return ClaudeUsageSnapshot(
                quotaSource: cache.quotaSource ?? current.quotaSource,
                model: cache.model ?? current.model,
                weeklyUsedPercent: cache.weeklyUsedPercent,
                weeklyResetsAt: cache.weeklyResetsAt,
                fiveHourUsedPercent: cache.fiveHourUsedPercent,
                fiveHourResetsAt: cache.fiveHourResetsAt,
                contextUsedPercent: cache.contextUsedPercent ?? current.contextUsedPercent,
                contextRemainingPercent: cache.contextRemainingPercent ?? current.contextRemainingPercent,
                sessionCostUSD: cache.sessionCostUSD ?? current.sessionCostUSD,
                publishedAt: cache.publishedAt,
                modelWeeklyLimits: current.modelWeeklyLimits,
                extraUsage: current.extraUsage,
                limitResets: cache.quotaSource == "claude-statusline" ? current.limitResets : cache.limitResets,
                account: current.account,
                planTitle: cache.planTitle ?? current.planTitle
            )
        }

        // A statusLine event can contain only session metadata before the
        // first Claude response. Adopt that metadata without refreshing the
        // timestamp attached to older quota values.
        return ClaudeUsageSnapshot(
            quotaSource: current.quotaSource,
            model: cache.model ?? current.model,
            weeklyUsedPercent: current.weeklyUsedPercent,
            weeklyResetsAt: current.weeklyResetsAt,
            fiveHourUsedPercent: current.fiveHourUsedPercent,
            fiveHourResetsAt: current.fiveHourResetsAt,
            contextUsedPercent: cache.contextUsedPercent ?? current.contextUsedPercent,
            contextRemainingPercent: cache.contextRemainingPercent ?? current.contextRemainingPercent,
            sessionCostUSD: cache.sessionCostUSD ?? current.sessionCostUSD,
            publishedAt: current.publishedAt,
            modelWeeklyLimits: current.modelWeeklyLimits,
            extraUsage: current.extraUsage,
            limitResets: current.limitResets,
            account: current.account,
            planTitle: current.planTitle
        )
    }
}

/// Combines Grok's weekly `creditUsagePercent` window with its optional
/// monthly fallback into one snapshot, mirroring `GeminiUsageSnapshot`'s
/// shape so the shared-file and panel code can follow the same conventions
/// for a fourth provider.
struct GrokRollingTokenUsage: Sendable, Equatable {
    let usedTokens: Int
    let limitTokens: Int
    let recoveryAt: Date?

    var remainingPercent: Double {
        guard limitTokens > 0 else { return 0 }
        return min(max((1 - (Double(usedTokens) / Double(limitTokens))) * 100, 0), 100)
    }
}

struct GrokTokenUsageRecord: Sendable, Equatable {
    let completedAt: Date
    let totalTokens: Int
}

struct GrokUsageSnapshot: Sendable, Equatable {
    let weeklyUsedPercent: Double?
    let weeklyResetsAt: Date?
    let monthlyUsedPercent: Double?
    let monthlyResetsAt: Date?
    /// Grok's billing API reports these monetary credit values in cents.
    /// CCMB normalizes them to display credits (for example, 280 -> 2.80).
    let monthlyUsedCredits: Double?
    let extraCreditBalance: Double?
    let subscriptionTier: String?
    /// Best-effort total from successful Grok CLI turns recorded on this Mac.
    /// It cannot include Grok web usage or calls made on another device.
    let rollingTokenUsage: GrokRollingTokenUsage?
    let publishedAt: Date?
    /// Non-secret identity read from the local `auth.json` entry. The access
    /// token itself never becomes part of this snapshot.
    let accountEmail: String?

    init(
        weeklyUsedPercent: Double? = nil,
        weeklyResetsAt: Date? = nil,
        monthlyUsedPercent: Double? = nil,
        monthlyResetsAt: Date? = nil,
        monthlyUsedCredits: Double? = nil,
        extraCreditBalance: Double? = nil,
        subscriptionTier: String? = nil,
        rollingTokenUsage: GrokRollingTokenUsage? = nil,
        publishedAt: Date? = nil,
        accountEmail: String? = nil
    ) {
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.monthlyUsedPercent = monthlyUsedPercent
        self.monthlyResetsAt = monthlyResetsAt
        self.monthlyUsedCredits = monthlyUsedCredits
        self.extraCreditBalance = extraCreditBalance
        self.subscriptionTier = subscriptionTier
        self.rollingTokenUsage = rollingTokenUsage
        self.publishedAt = publishedAt
        self.accountEmail = accountEmail
    }

    var hasUsage: Bool {
        weeklyUsedPercent != nil
            || monthlyUsedPercent != nil
            || monthlyUsedCredits != nil
            || extraCreditBalance != nil
            || subscriptionTier != nil
            || rollingTokenUsage != nil
    }
}

/// Pure parsing and shared-payload logic for the Grok CLI's `/v1/billing`
/// proxy endpoint. Has no knowledge of how the request is issued or how the
/// local OAuth token is read, so it is fully testable without a live fetch
/// or a real `auth.json`.
enum GrokUsageCore {
    static let sharedFreshForSeconds: TimeInterval = 300
    static let minimumRequestIntervalSeconds: TimeInterval = 120
    static let freeRollingTokenLimit = 500_000
    static let rollingTokenWindowSeconds: TimeInterval = 24 * 60 * 60

    static func parseTokenUsageRecords(_ data: Data) -> [GrokTokenUsageRecord] {
        data.split(separator: 0x0A).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let timestamp = (object["timestamp"] as? NSNumber)?.doubleValue,
                  let params = object["params"] as? [String: Any],
                  let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "turn_completed",
                  let usage = update["usage"] as? [String: Any],
                  let totalTokens = (usage["totalTokens"] as? NSNumber)?.intValue,
                  totalTokens > 0
            else { return nil }
            return GrokTokenUsageRecord(
                completedAt: Date(timeIntervalSince1970: timestamp),
                totalTokens: totalTokens
            )
        }
    }

    static func rollingTokenUsage(
        records: [GrokTokenUsageRecord],
        now: Date,
        limitTokens: Int = freeRollingTokenLimit
    ) -> GrokRollingTokenUsage? {
        let cutoff = now.addingTimeInterval(-rollingTokenWindowSeconds)
        let active = records
            .filter { $0.completedAt > cutoff && $0.completedAt <= now && $0.totalTokens > 0 }
            .sorted { $0.completedAt < $1.completedAt }
        guard !active.isEmpty, limitTokens > 0 else { return nil }

        let usedTokens = active.reduce(0) { partial, record in
            partial.addingReportingOverflow(record.totalTokens).overflow
                ? Int.max
                : partial + record.totalTokens
        }
        var recoveryAt: Date?
        if usedTokens >= limitTokens {
            var remaining = usedTokens
            for record in active {
                remaining -= record.totalTokens
                if remaining < limitTokens {
                    recoveryAt = record.completedAt.addingTimeInterval(rollingTokenWindowSeconds)
                    break
                }
            }
        }
        return GrokRollingTokenUsage(
            usedTokens: usedTokens,
            limitTokens: limitTokens,
            recoveryAt: recoveryAt
        )
    }

    static func addingRollingTokenUsage(
        _ rollingTokenUsage: GrokRollingTokenUsage?,
        to snapshot: GrokUsageSnapshot
    ) -> GrokUsageSnapshot {
        GrokUsageSnapshot(
            weeklyUsedPercent: snapshot.weeklyUsedPercent,
            weeklyResetsAt: snapshot.weeklyResetsAt,
            monthlyUsedPercent: snapshot.monthlyUsedPercent,
            monthlyResetsAt: snapshot.monthlyResetsAt,
            monthlyUsedCredits: snapshot.monthlyUsedCredits,
            extraCreditBalance: snapshot.extraCreditBalance,
            subscriptionTier: snapshot.subscriptionTier,
            rollingTokenUsage: rollingTokenUsage,
            publishedAt: snapshot.publishedAt,
            accountEmail: snapshot.accountEmail
        )
    }

    static func remainingPercent(from usedPercent: Double?) -> Double? {
        guard let usedPercent else { return nil }
        return min(max(100 - usedPercent, 0), 100)
    }

    static func isFresh(publishedAt: Date?, now: Date, freshForSeconds: TimeInterval) -> Bool {
        guard let publishedAt else { return false }
        return now.timeIntervalSince(publishedAt) <= freshForSeconds
    }

    static func shouldThrottleFetch(minimumInterval: TimeInterval, lastFetchDate: Date?, now: Date) -> Bool {
        guard minimumInterval > 0, let lastFetchDate else { return false }
        let timerTolerance = min(1, minimumInterval * 0.05)
        return now.timeIntervalSince(lastFetchDate) < minimumInterval - timerTolerance
    }

    /// Only a percentage explicitly returned by Grok is trustworthy. A
    /// missing field must stay unavailable: matching period bounds identify
    /// the window, but do not prove that the account has used zero quota.
    static func weeklyUsedPercent(creditUsagePercent: Double?) -> Double? {
        guard let creditUsagePercent else { return nil }
        return min(max(creditUsagePercent, 0), 100)
    }

    /// A zero or missing monthly limit (the proxy's own default response
    /// shape) must never be displayed as a percentage; only a finite,
    /// positive limit paired with a finite used value yields one.
    static func monthlyUsedPercent(limit: Double?, used: Double?) -> Double? {
        guard let limit, limit.isFinite, limit > 0,
              let used, used.isFinite
        else { return nil }
        return min(max((used / limit) * 100, 0), 100)
    }

    private struct BillingResponse: Decodable {
        struct Period: Decodable {
            let type: String?
            let start: String?
            let end: String?
        }
        struct ValueField: Decodable {
            let val: Double?
        }
        struct Config: Decodable {
            let currentPeriod: Period?
            let billingPeriodStart: String?
            let billingPeriodEnd: String?
            let creditUsagePercent: Double?
            let monthlyLimit: ValueField?
            let used: ValueField?
            let prepaidBalance: ValueField?
        }
        let config: Config?
        let currentPeriod: Period?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
        let creditUsagePercent: Double?
        let monthlyLimit: ValueField?
        let used: ValueField?
        let prepaidBalance: ValueField?

        var effectiveConfig: Config {
            config ?? Config(
                currentPeriod: currentPeriod,
                billingPeriodStart: billingPeriodStart,
                billingPeriodEnd: billingPeriodEnd,
                creditUsagePercent: creditUsagePercent,
                monthlyLimit: monthlyLimit,
                used: used,
                prepaidBalance: prepaidBalance
            )
        }
    }

    private struct SettingsResponse: Decodable {
        let subscriptionTierDisplay: String?
        let subscriptionTier: String?

        enum CodingKeys: String, CodingKey {
            case subscriptionTierDisplay = "subscription_tier_display"
            case subscriptionTier = "subscription_tier"
        }
    }

    /// Internal (not `private`) so unit tests can exercise response parsing
    /// via `@testable import` without a live network fetch.
    static func parse(_ data: Data, accountEmail: String?, now: Date = Date()) -> GrokUsageSnapshot? {
        guard let response = try? JSONDecoder().decode(BillingResponse.self, from: data) else { return nil }
        let config = response.effectiveConfig

        let weeklyUsed = weeklyUsedPercent(creditUsagePercent: config.creditUsagePercent)
        let monthlyUsed = monthlyUsedPercent(limit: config.monthlyLimit?.val, used: config.used?.val)
        guard weeklyUsed != nil || monthlyUsed != nil || config.prepaidBalance?.val != nil else { return nil }

        return GrokUsageSnapshot(
            weeklyUsedPercent: weeklyUsed,
            weeklyResetsAt: parseDate(config.currentPeriod?.end),
            monthlyUsedPercent: monthlyUsed,
            monthlyResetsAt: nil,
            extraCreditBalance: config.prepaidBalance?.val.map { $0 / 100 },
            publishedAt: now,
            accountEmail: accountEmail
        )
    }

    /// Combines the three read-only Grok endpoints used by the official CLI:
    /// weekly/credit-period billing, legacy monthly billing, and settings.
    static func parseCombined(
        creditsData: Data,
        billingData: Data,
        settingsData: Data,
        accountEmail: String?,
        now: Date = Date()
    ) -> GrokUsageSnapshot? {
        guard let credits = parse(creditsData, accountEmail: accountEmail, now: now),
              let billing = try? JSONDecoder().decode(BillingResponse.self, from: billingData),
              let settings = try? JSONDecoder().decode(SettingsResponse.self, from: settingsData)
        else { return nil }

        let billingConfig = billing.effectiveConfig
        let tier = settings.subscriptionTierDisplay ?? settings.subscriptionTier
        return GrokUsageSnapshot(
            weeklyUsedPercent: credits.weeklyUsedPercent,
            weeklyResetsAt: credits.weeklyResetsAt,
            monthlyUsedPercent: monthlyUsedPercent(
                limit: billingConfig.monthlyLimit?.val,
                used: billingConfig.used?.val
            ),
            monthlyResetsAt: parseDate(billingConfig.billingPeriodEnd),
            monthlyUsedCredits: billingConfig.used?.val.map { $0 / 100 },
            extraCreditBalance: credits.extraCreditBalance,
            subscriptionTier: tier,
            publishedAt: now,
            accountEmail: accountEmail
        )
    }

    /// Nested `grok` object mirroring `gemini`'s shape in the shared
    /// `usage-v1.json` file: status/weekly/monthly/reset/freshness.
    static func sharedPayload(from snapshot: GrokUsageSnapshot?, now: Date = Date()) -> [String: Any] {
        guard let snapshot else {
            return [
                "status": "unavailable",
                "weeklyRemainingPercent": NSNull(),
                "weeklyUsedPercent": NSNull(),
                "weeklyUsageConfirmed": false,
                "weeklyResetsAt": NSNull(),
                "monthlyRemainingPercent": NSNull(),
                "monthlyUsedPercent": NSNull(),
                "monthlyResetsAt": NSNull(),
                "monthlyUsedCredits": NSNull(),
                "extraCreditBalance": NSNull(),
                "subscriptionTier": NSNull(),
                "rollingTokenUsedEstimate": NSNull(),
                "rollingTokenLimit": NSNull(),
                "rollingTokenRemainingPercentEstimate": NSNull(),
                "rollingTokenRecoveryAtEstimate": NSNull(),
                "account": NSNull(),
                "fetchedAt": NSNull(),
                "ageSeconds": NSNull(),
                "freshForSeconds": Int(sharedFreshForSeconds),
                "fresh": false
            ]
        }

        let ageSeconds = snapshot.publishedAt.map { max(0, Int(now.timeIntervalSince($0))) }
        return [
            "status": snapshot.hasUsage ? "ok" : "partial",
            "weeklyRemainingPercent": remainingPercent(from: snapshot.weeklyUsedPercent) ?? NSNull(),
            "weeklyUsedPercent": snapshot.weeklyUsedPercent ?? NSNull(),
            "weeklyUsageConfirmed": snapshot.weeklyUsedPercent != nil,
            "weeklyResetsAt": snapshot.weeklyResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "monthlyRemainingPercent": remainingPercent(from: snapshot.monthlyUsedPercent) ?? NSNull(),
            "monthlyUsedPercent": snapshot.monthlyUsedPercent ?? NSNull(),
            "monthlyResetsAt": snapshot.monthlyResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "monthlyUsedCredits": snapshot.monthlyUsedCredits ?? NSNull(),
            "extraCreditBalance": snapshot.extraCreditBalance ?? NSNull(),
            "subscriptionTier": snapshot.subscriptionTier ?? NSNull(),
            "rollingTokenUsedEstimate": snapshot.rollingTokenUsage?.usedTokens ?? NSNull(),
            "rollingTokenLimit": snapshot.rollingTokenUsage?.limitTokens ?? NSNull(),
            "rollingTokenRemainingPercentEstimate": snapshot.rollingTokenUsage?.remainingPercent ?? NSNull(),
            "rollingTokenRecoveryAtEstimate": snapshot.rollingTokenUsage?.recoveryAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "account": snapshot.accountEmail ?? NSNull(),
            "fetchedAt": snapshot.publishedAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "ageSeconds": ageSeconds ?? NSNull(),
            "freshForSeconds": Int(sharedFreshForSeconds),
            "fresh": isFresh(publishedAt: snapshot.publishedAt, now: now, freshForSeconds: sharedFreshForSeconds)
        ]
    }

    /// Recomputes a stored `grok` payload's `ageSeconds`/`fresh` from its own
    /// `fetchedAt`, the same role `refreshedSharedPayload` plays for Gemini.
    static func refreshedSharedPayload(_ payload: [String: Any], now: Date = Date()) -> [String: Any] {
        var output = payload
        let fetchedAt = (payload["fetchedAt"] as? String).flatMap(sharedISO8601Formatter.date(from:))
        let freshForSeconds = (payload["freshForSeconds"] as? NSNumber)?.doubleValue ?? sharedFreshForSeconds
        output["ageSeconds"] = fetchedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? NSNull()
        output["fresh"] = isFresh(publishedAt: fetchedAt, now: now, freshForSeconds: freshForSeconds)
        return output
    }

    /// Restores the last successful Grok snapshot from CCMB's own shared
    /// JSON so an app restart does not momentarily show "정보 없음" for data
    /// fetched minutes ago.
    static func snapshot(fromSharedPayload payload: [String: Any]) -> GrokUsageSnapshot? {
        func percent(_ key: String) -> Double? {
            (payload[key] as? NSNumber)?.doubleValue
        }
        func date(_ key: String) -> Date? {
            (payload[key] as? String).flatMap(sharedISO8601Formatter.date(from:))
        }

        let storedWeeklyUsedPercent = percent("weeklyUsedPercent")
        // Payloads written before `weeklyUsageConfirmed` existed may contain
        // the old inferred 0%. Preserve explicit nonzero readings, but migrate
        // the ambiguous zero to unavailable instead of restoring a false 100%.
        let weeklyUsageConfirmed = (payload["weeklyUsageConfirmed"] as? Bool)
            ?? (storedWeeklyUsedPercent.map { $0 != 0 } ?? false)
        let snapshot = GrokUsageSnapshot(
            weeklyUsedPercent: weeklyUsageConfirmed ? storedWeeklyUsedPercent : nil,
            weeklyResetsAt: date("weeklyResetsAt"),
            monthlyUsedPercent: percent("monthlyUsedPercent"),
            monthlyResetsAt: date("monthlyResetsAt"),
            monthlyUsedCredits: percent("monthlyUsedCredits"),
            extraCreditBalance: percent("extraCreditBalance"),
            subscriptionTier: payload["subscriptionTier"] as? String,
            rollingTokenUsage: {
                guard let used = (payload["rollingTokenUsedEstimate"] as? NSNumber)?.intValue,
                      let limit = (payload["rollingTokenLimit"] as? NSNumber)?.intValue,
                      used >= 0, limit > 0
                else { return nil }
                return GrokRollingTokenUsage(
                    usedTokens: used,
                    limitTokens: limit,
                    recoveryAt: date("rollingTokenRecoveryAtEstimate")
                )
            }(),
            publishedAt: date("fetchedAt"),
            accountEmail: payload["account"] as? String
        )

        guard snapshot.publishedAt != nil
            || snapshot.weeklyUsedPercent != nil
            || snapshot.monthlyUsedPercent != nil
            || snapshot.monthlyUsedCredits != nil
            || snapshot.extraCreditBalance != nil
            || snapshot.subscriptionTier != nil
            || snapshot.rollingTokenUsage != nil
            || snapshot.accountEmail != nil
        else { return nil }
        return snapshot
    }

    /// The billing endpoint's own period boundaries are not guaranteed to
    /// carry fractional seconds, so both forms are tried the same way
    /// Gemini's `reset_time` is parsed.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return sharedISO8601Formatter.date(from: string) ?? sharedISO8601FormatterWholeSeconds.date(from: string)
    }

    private static let sharedISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let sharedISO8601FormatterWholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
