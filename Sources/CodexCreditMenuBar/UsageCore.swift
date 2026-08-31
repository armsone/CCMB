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
}

/// Provider-independent adaptive cadence. Each visible provider owns one
/// instance, so activity in Claude does not unnecessarily accelerate Codex
/// or Gemini. A value change greater than 0.01 immediately returns that
/// provider to one-minute monitoring.
struct SmartRefreshPolicy: Equatable {
    enum Mode: Int, Equatable {
        case active
        case idleShort
        case idleMedium
        case idleLong

        var interval: TimeInterval {
            switch self {
            case .active: return 60
            case .idleShort: return 180
            case .idleMedium: return 300
            case .idleLong: return 600
            }
        }

        var unchangedThreshold: Int? {
            switch self {
            case .active: return 3
            case .idleShort: return 6
            case .idleMedium: return 12
            case .idleLong: return nil
            }
        }

        var next: Mode {
            switch self {
            case .active: return .idleShort
            case .idleShort: return .idleMedium
            case .idleMedium, .idleLong: return .idleLong
            }
        }
    }

    private(set) var mode: Mode = .active
    private(set) var unchangedCount = 0
    private(set) var lastValues: [Double?]?

    var interval: TimeInterval { mode.interval }

    /// Returns true when the effective interval changed.
    mutating func update(values: [Double?]) -> Bool {
        guard let previous = lastValues else {
            lastValues = values
            return false
        }
        let changed = values.count != previous.count || zip(values, previous).contains { current, old in
            switch (current, old) {
            case let (current?, old?): return abs(current - old) > 0.01
            case (nil, nil): return false
            default: return true
            }
        }
        lastValues = values
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

    /// Consumption per refresh is often a fraction of a percent or of a credit,
    /// so two decimals would round most readings to "0". Small values keep four.
    /// Lives here rather than in the app delegate because the hover tooltip in
    /// the chart view needs the same formatting.
    static func amountTitle(_ amount: Double, unit: String) -> String {
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
    /// `-1` selects the adaptive 1→3→5→10 minute policy used by the
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
    /// same status/weekly/account/freshness concepts and optional Spark weekly
    /// quota details when present.
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
            "sparkRemainingPercent": snapshot.sparkUsedPercent.map(remainingPercent) ?? NSNull(),
            "sparkUsedPercent": snapshot.sparkUsedPercent ?? NSNull(),
            "sparkResetsAt": snapshot.sparkResetsAt.map(sharedISO8601Formatter.string(from:)) ?? NSNull(),
            "sparkWindowDurationMins": snapshot.sparkWindowDurationMinutes ?? NSNull(),
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
/// accepts only a plausible email-shaped active value.
enum GeminiAccountCore {
    private struct AccountsFile: Decodable {
        let active: String?
    }

    static func activeEmail(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(AccountsFile.self, from: data),
              let active = decoded.active?.trimmingCharacters(in: .whitespacesAndNewlines),
              !active.isEmpty,
              active.contains("@")
        else { return nil }
        return active
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
            fetchedAt: now
        )
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
    let account: ClaudeAccountInfo?

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
        account: ClaudeAccountInfo? = nil
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
        self.account = account
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
            account: account
        )
    }

    var hasRateLimitUsage: Bool {
        weeklyUsedPercent != nil || fiveHourUsedPercent != nil
    }
}

enum ClaudeUsageCore {
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
                "account": NSNull()
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
                account: current.account
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
            account: current.account
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
