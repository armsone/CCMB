import AppKit
import Foundation
import Security

/// Reads the cache file that `claude-statusline.sh` writes from Claude Code's
/// official statusLine payload. Purely local file I/O — no network calls.
enum ClaudeUsageStore {
    static let cacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("CCMB")
        .appendingPathComponent("claude-usage-v1.json")

    private struct CacheFile: Decodable {
        let model: String?
        let weeklyUsedPercent: Double?
        let weeklyResetsAtEpoch: Double?
        let fiveHourUsedPercent: Double?
        let fiveHourResetsAtEpoch: Double?
        let contextUsedPercent: Double?
        let contextRemainingPercent: Double?
        let sessionCostUSD: Double?
        let publishedAt: String?
    }

    static func read() -> ClaudeUsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard let raw = try? JSONDecoder().decode(CacheFile.self, from: data) else { return nil }

        let publishedAt = raw.publishedAt.flatMap { iso8601Formatter.date(from: $0) }
        return ClaudeUsageSnapshot(
            model: raw.model,
            weeklyUsedPercent: raw.weeklyUsedPercent,
            weeklyResetsAt: raw.weeklyResetsAtEpoch.map { Date(timeIntervalSince1970: $0) },
            fiveHourUsedPercent: raw.fiveHourUsedPercent,
            fiveHourResetsAt: raw.fiveHourResetsAtEpoch.map { Date(timeIntervalSince1970: $0) },
            contextUsedPercent: raw.contextUsedPercent,
            contextRemainingPercent: raw.contextRemainingPercent,
            sessionCostUSD: raw.sessionCostUSD,
            publishedAt: publishedAt
        )
    }
}

/// A single label/value metric row inside a usage panel column. Callers
/// (main.swift) format `label`/`value`/`detail` from `RateLimitSnapshot` /
/// `ClaudeUsageSnapshot` — the view only lays out already-formatted text and
/// never parses it back apart.
struct UsagePanelRow {
    let label: String
    let value: String
    /// Optional second line spanning the full row width (e.g. an exact
    /// reset date/time for a per-model weekly limit row).
    let detail: String?
    let valueColor: NSColor?
    let accessibilityLabel: String

    init(label: String, value: String, detail: String? = nil, valueColor: NSColor? = nil, accessibilityLabel: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        if let accessibilityLabel {
            self.accessibilityLabel = accessibilityLabel
        } else {
            self.accessibilityLabel = detail.map { "\(label) \(value), \($0)" } ?? "\(label) \(value)"
        }
    }
}

/// The column's single most important number, shown as a compact ring with
/// a centered percentage and a caption describing what it measures.
struct UsagePanelQuota {
    let caption: String
    let percentText: String
    /// Remaining fraction (0...1) the ring fills in.
    let fraction: Double
    let color: NSColor
    let accessibilityValue: String
}

struct UsagePanelColumn {
    let title: String
    let accentColor: NSColor
    let quota: UsagePanelQuota?
    let rows: [UsagePanelRow]
    /// Secondary status lines shown below the rows (account/update status,
    /// last-updated age, fetch failure or backoff countdown).
    let statusLines: [String]
    let statusColor: NSColor
}

struct UsagePanelModel {
    let codex: UsagePanelColumn
    let claude: UsagePanelColumn
}

/// Compact circular progress indicator used for a column's primary quota.
private final class UsageRingView: NSView {
    var lineWidth: CGFloat = 4.5
    var trackColor: NSColor = .quaternaryLabelColor {
        didSet { needsDisplay = true }
    }
    var progressColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else { return }
        let diameter = min(rect.width, rect.height)
        let squareRect = NSRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let center = NSPoint(x: squareRect.midX, y: squareRect.midY)
        let radius = diameter / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        trackColor.setStroke()
        track.stroke()

        let clampedFraction = min(max(fraction, 0), 1)
        guard clampedFraction > 0 else { return }
        let progress = NSBezierPath()
        let startAngle: CGFloat = 90
        let endAngle = startAngle - CGFloat(clampedFraction) * 360
        progress.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        progressColor.setStroke()
        progress.stroke()
    }
}

/// A single rounded metric row: a leading label, a trailing value, and an
/// optional full-width detail line (e.g. an exact reset date/time).
private final class UsageRowBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

private final class UsageMetricRowView: NSView {
    private static let horizontalInset: CGFloat = 8
    private static let firstLineHeight: CGFloat = 15
    private static let detailLineHeight: CGFloat = 12
    private static let labelWidthFraction: CGFloat = 0.42

    private let backgroundView = UsageRowBackgroundView()
    private let labelField = UsageMetricRowView.makeLabel(color: .secondaryLabelColor, size: 11, weight: .regular)
    private let valueField: NSTextField = {
        let field = UsageMetricRowView.makeLabel(color: .labelColor, size: 11.5, weight: .semibold)
        field.alignment = .right
        return field
    }()
    private let detailField = UsageMetricRowView.makeLabel(color: .tertiaryLabelColor, size: 9.5, weight: .regular)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(backgroundView)
        addSubview(labelField)
        addSubview(valueField)
        addSubview(detailField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeLabel(color: NSColor, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func apply(_ row: UsagePanelRow, width: CGFloat, height: CGFloat) {
        labelField.stringValue = row.label
        valueField.stringValue = row.value
        valueField.textColor = row.valueColor ?? .labelColor
        let hasDetail = row.detail != nil
        detailField.stringValue = row.detail ?? ""
        detailField.isHidden = !hasDetail
        setAccessibilityElement(true)
        setAccessibilityLabel(row.accessibilityLabel)

        backgroundView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let inset = Self.horizontalInset
        let firstLineY = hasDetail ? 5 : (height - Self.firstLineHeight) / 2
        let labelWidth = max(0, width * Self.labelWidthFraction - inset)
        labelField.frame = NSRect(x: inset, y: firstLineY, width: labelWidth, height: Self.firstLineHeight)
        let valueX = inset + labelWidth
        let valueWidth = max(0, width - valueX - inset)
        valueField.frame = NSRect(x: valueX, y: firstLineY, width: valueWidth, height: Self.firstLineHeight)

        if hasDetail {
            let detailY = firstLineY + Self.firstLineHeight
            detailField.frame = NSRect(x: inset, y: detailY, width: max(0, width - inset * 2), height: Self.detailLineHeight)
        } else {
            detailField.frame = .zero
        }
    }
}

/// One column of the panel: a title, an optional primary quota ring, a
/// stack of metric rows, and secondary status lines.
private final class UsageColumnView: NSView {
    private static let titleHeight: CGFloat = 16
    private static let titleGap: CGFloat = 6
    private static let quotaDiameter: CGFloat = 46
    private static let quotaGap: CGFloat = 10
    private static let rowGap: CGFloat = 4
    private static let rowsTopGap: CGFloat = 8
    private static let singleLineRowHeight: CGFloat = 24
    private static let detailRowHeight: CGFloat = 38
    private static let statusTopGap: CGFloat = 8
    private static let statusLineHeight: CGFloat = 13

    private let titleLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        return field
    }()
    private let ringView = UsageRingView()
    private let percentLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        field.alignment = .center
        field.textColor = .labelColor
        return field
    }()
    private let quotaCaptionLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }()
    private let statusLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 9.5)
        field.textColor = .tertiaryLabelColor
        return field
    }()

    private var rowViews: [UsageMetricRowView] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(titleLabel)
        addSubview(ringView)
        addSubview(percentLabel)
        addSubview(quotaCaptionLabel)
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays out the column immediately using the given fixed width and
    /// returns the resulting content height. The caller positions this
    /// view's own frame using that height afterward.
    @discardableResult
    func apply(_ column: UsagePanelColumn, width: CGFloat) -> CGFloat {
        titleLabel.stringValue = column.title
        titleLabel.textColor = column.accentColor
        titleLabel.frame = NSRect(x: 0, y: 0, width: width, height: Self.titleHeight)

        var y: CGFloat = Self.titleHeight

        if let quota = column.quota {
            y += Self.titleGap
            ringView.isHidden = false
            percentLabel.isHidden = false
            quotaCaptionLabel.isHidden = false
            ringView.progressColor = quota.color
            ringView.trackColor = quota.color.withAlphaComponent(0.18)
            ringView.fraction = quota.fraction
            percentLabel.stringValue = quota.percentText
            quotaCaptionLabel.stringValue = quota.caption
            ringView.setAccessibilityElement(true)
            ringView.setAccessibilityLabel(quota.caption)
            ringView.setAccessibilityValue(quota.accessibilityValue)

            let diameter = Self.quotaDiameter
            ringView.frame = NSRect(x: 0, y: y, width: diameter, height: diameter)
            percentLabel.frame = NSRect(x: 0, y: y + (diameter - 18) / 2, width: diameter, height: 18)
            let captionX = diameter + Self.quotaGap
            quotaCaptionLabel.frame = NSRect(
                x: captionX,
                y: y + (diameter - 14) / 2,
                width: max(0, width - captionX),
                height: 14
            )
            y += diameter
        } else {
            ringView.isHidden = true
            percentLabel.isHidden = true
            quotaCaptionLabel.isHidden = true
        }

        syncRows(column.rows)
        if !rowViews.isEmpty {
            y += Self.rowsTopGap
            for (index, rowView) in rowViews.enumerated() {
                let row = column.rows[index]
                let height = row.detail == nil ? Self.singleLineRowHeight : Self.detailRowHeight
                rowView.apply(row, width: width, height: height)
                rowView.frame = NSRect(x: 0, y: y, width: width, height: height)
                y += height + Self.rowGap
            }
            y -= Self.rowGap
        }

        if column.statusLines.isEmpty {
            statusLabel.isHidden = true
        } else {
            y += Self.statusTopGap
            statusLabel.stringValue = column.statusLines.joined(separator: "\n")
            statusLabel.textColor = column.statusColor
            statusLabel.isHidden = false
            let statusHeight = CGFloat(column.statusLines.count) * Self.statusLineHeight
            statusLabel.frame = NSRect(x: 0, y: y, width: width, height: statusHeight)
            y += statusHeight
        }

        let accessibilitySummary = ([column.title]
            + (column.quota.map { [$0.accessibilityValue] } ?? [])
            + column.rows.map(\.accessibilityLabel)
            + column.statusLines).joined(separator: ", ")
        setAccessibilityElement(true)
        setAccessibilityLabel(accessibilitySummary)

        return y
    }

    private func syncRows(_ rows: [UsagePanelRow]) {
        while rowViews.count < rows.count {
            let rowView = UsageMetricRowView()
            addSubview(rowView)
            rowViews.append(rowView)
        }
        while rowViews.count > rows.count {
            rowViews.removeLast().removeFromSuperview()
        }
    }
}

/// Two-column status panel: Codex info on the left, Claude info on the right,
/// hosted as the `view` of a single NSMenuItem.
@MainActor
final class SplitUsagePanelView: NSView {
    private let columnWidth: CGFloat = 230
    private let columnGap: CGFloat = 18
    private let sidePadding: CGFloat = 16
    private let topPadding: CGFloat = 10
    private let bottomPadding: CGFloat = 10

    private let leftColumnView = UsageColumnView()
    private let rightColumnView = UsageColumnView()
    private let dividerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
        addSubview(leftColumnView)
        addSubview(rightColumnView)
        addSubview(dividerView)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ model: UsagePanelModel) {
        let leftHeight = leftColumnView.apply(model.codex, width: columnWidth)
        let rightHeight = rightColumnView.apply(model.claude, width: columnWidth)
        let contentHeight = max(leftHeight, rightHeight, 1)

        let leftX = sidePadding
        let rightX = sidePadding + columnWidth + columnGap
        let dividerX = sidePadding + columnWidth + (columnGap / 2)

        leftColumnView.frame = NSRect(x: leftX, y: topPadding, width: columnWidth, height: contentHeight)
        rightColumnView.frame = NSRect(x: rightX, y: topPadding, width: columnWidth, height: contentHeight)
        dividerView.frame = NSRect(x: dividerX, y: topPadding, width: 1, height: contentHeight)

        var newFrame = frame
        newFrame.size.height = topPadding + contentHeight + bottomPadding
        newFrame.size.width = sidePadding * 2 + columnWidth * 2 + columnGap
        frame = newFrame

        let codexSummary = model.codex.quota?.accessibilityValue ?? model.codex.title
        let claudeSummary = model.claude.quota?.accessibilityValue ?? model.claude.title
        setAccessibilityLabel("Codex 및 Claude 사용량 패널")
        setAccessibilityValue("\(codexSummary), \(claudeSummary)")
    }
}

/// Compact two-button row linking to the Codex and Claude usage web pages,
/// replacing two separate vertical menu rows with one native view hosted as
/// a single `NSMenuItem`, directly above the refresh item. Roughly matches
/// the split usage panel's own width.
@MainActor
final class UsagePageButtonsView: NSView {
    private static let viewWidth: CGFloat = 510
    private static let viewHeight: CGFloat = 30
    private static let sidePadding: CGFloat = 16
    private static let buttonGap: CGFloat = 10

    let codexButton: NSButton
    let claudeButton: NSButton
    private let dividerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }()

    override var isFlipped: Bool { true }

    init() {
        codexButton = Self.makeButton(title: "Codex 사용량 페이지", accessibilityLabel: "Codex 사용량 페이지 열기")
        claudeButton = Self.makeButton(title: "Claude 사용량 페이지", accessibilityLabel: "Claude 사용량 페이지 열기")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))

        addSubview(codexButton)
        addSubview(dividerView)
        addSubview(claudeButton)
        setAccessibilityElement(false)
        layoutButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeButton(title: String, accessibilityLabel: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .recessed
        button.font = .systemFont(ofSize: 11.5, weight: .medium)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityRole(.button)
        return button
    }

    private func layoutButtons() {
        let usableWidth = Self.viewWidth - Self.sidePadding * 2 - Self.buttonGap - 1
        let buttonWidth = (usableWidth / 2).rounded(.down)
        let buttonHeight = Self.viewHeight - 6
        let y: CGFloat = 3

        codexButton.frame = NSRect(x: Self.sidePadding, y: y, width: buttonWidth, height: buttonHeight)
        let dividerX = Self.sidePadding + buttonWidth + Self.buttonGap / 2
        dividerView.frame = NSRect(x: dividerX, y: 5, width: 1, height: Self.viewHeight - 10)
        let claudeX = Self.sidePadding + buttonWidth + Self.buttonGap + 1
        claudeButton.frame = NSRect(x: claudeX, y: y, width: buttonWidth, height: buttonHeight)
    }
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Outcome of a `ClaudeOAuthUsageClient.fetchIfDue` attempt. The
/// `skipped*` cases are routine scheduling decisions, not failures — every
/// other case is an explicit, sanitized (no tokens/bodies/secrets) reason
/// the caller can log and surface so stale data is never presented as
/// healthy current data.
enum ClaudeUsageFetchOutcome {
    case success(ClaudeUsageSnapshot)
    case skippedInFlight
    case skippedThrottled
    /// A prior 429's backoff window is still active, so this call never hit
    /// the network. Carries the same `retryAt` the original `.rateLimited`
    /// outcome stored, so the UI's countdown stays accurate.
    case skippedRateLimitBackoff(retryAt: Date)
    case noCredential
    case keychainCredentialUnreadable
    /// An actual 429 response, with the backoff deadline computed from its
    /// `Retry-After` header (or the conservative fallback).
    case rateLimited(retryAt: Date)
    case httpFailure(status: Int)
    case transportFailure
    case decodeFailure

    /// Sanitized, single-line reason safe for the app's private log. `nil`
    /// for routine skips (including an active rate-limit backoff) so they
    /// don't spam the log on every timer tick.
    var diagnosticDescription: String? {
        switch self {
        case .success, .skippedInFlight, .skippedThrottled, .skippedRateLimitBackoff:
            return nil
        case .noCredential:
            return "no Claude credential found"
        case .keychainCredentialUnreadable:
            return "keychain credential unreadable"
        case .rateLimited(let retryAt):
            return "http 429, backoff until epoch \(Int(retryAt.timeIntervalSince1970))"
        case .httpFailure(let status):
            return "http \(status)"
        case .transportFailure:
            return "network error"
        case .decodeFailure:
            return "response decode failed"
        }
    }

    /// Short Korean label safe to show next to the stale Claude panel data.
    var staleReasonLabel: String? {
        switch self {
        case .success, .skippedInFlight, .skippedThrottled, .skippedRateLimitBackoff:
            return nil
        case .noCredential:
            return "인증 정보 없음"
        case .keychainCredentialUnreadable:
            return "키체인 인증 정보를 읽을 수 없음"
        case .rateLimited:
            return "요청 제한(429)"
        case .httpFailure(let status) where status == 401 || status == 403:
            return "인증 만료"
        case .httpFailure(let status):
            return "서버 오류(\(status))"
        case .transportFailure:
            return "네트워크 오류"
        case .decodeFailure:
            return "응답 처리 실패"
        }
    }

    /// Present only for `.rateLimited`/`.skippedRateLimitBackoff`, so the
    /// caller can render a live countdown from a stored `retryAt` without
    /// needing a fresh fetch on every UI refresh.
    var rateLimitRetryAt: Date? {
        switch self {
        case .rateLimited(let retryAt), .skippedRateLimitBackoff(let retryAt):
            return retryAt
        default:
            return nil
        }
    }
}

/// Fetches Claude account rate-limit usage directly from Anthropic's
/// undocumented OAuth usage endpoint, using the long-lived token from
/// `claude setup-token` already stored locally. This endpoint is not
/// officially documented for third-party use and may change or stop
/// working without notice — the caller receives a `ClaudeUsageFetchOutcome`
/// so it can fall back to the passive statusLine cache (`ClaudeUsageStore`)
/// while making the failure visible instead of presenting stale data as
/// healthy.
enum ClaudeOAuthUsageClient {
    private static let lastFetchDefaultsKey = "claudeUsageLastFetchAt"
    private static let rateLimitRetryDefaultsKey = "claudeUsageRateLimitRetryAt"
    private static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("CCMB")
        .appendingPathComponent("claude-oauth-token")

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Tokens a profile fetch has already been attempted for, so the
    /// unofficial endpoint is hit at most once per process per token
    /// regardless of how many usage fetches succeed afterward.
    @MainActor private static var attemptedProfileTokens = Set<String>()
    @MainActor private static var latestAccountInfo: ClaudeAccountInfo?
    /// Keep the credential in memory after the first successful Keychain
    /// read. Re-reading a protected Keychain item on every 90-second usage
    /// refresh can repeatedly show a macOS authorization dialog, especially
    /// for locally rebuilt ad-hoc-signed copies of CCMB. An authentication
    /// failure clears this value so Claude Code's refreshed token is picked
    /// up on the next request.
    @MainActor private static var cachedAccessToken: String?
    /// Cache a failed credential lookup for the life of this process. A
    /// denied Keychain prompt must not be shown again every refresh; after
    /// fixing login or permission, restarting CCMB performs one fresh read.
    @MainActor private static var cachedTokenResolutionFailure: TokenResolution?

    // Mutated both when a fetch is kicked off (main actor caller) and when the
    // background URLSession completion handler finishes; isolate to the main
    // actor and hop back onto it in the completion handler instead of touching
    // these from the URLSession callback's background queue directly.
    @MainActor private static var lastFetchDate: Date? =
        UserDefaults.standard.object(forKey: lastFetchDefaultsKey) as? Date
    @MainActor private static var isFetchInFlight = false
    /// Set from a 429's `Retry-After`; cleared on the next success. While in
    /// the future, `fetchIfDue` skips the network call entirely instead of
    /// retrying into another rate limit.
    @MainActor private static var rateLimitRetryAt: Date? =
        UserDefaults.standard.object(forKey: rateLimitRetryDefaultsKey) as? Date

    /// - Parameter minimumInterval: Floor on how often this endpoint is
    ///   actually hit, independent of how often the caller asks. The caller
    ///   applies CCMB's 90-second Claude safety floor before invoking this.
    @MainActor
    static func fetchIfDue(minimumInterval: TimeInterval, completion: @escaping (ClaudeUsageFetchOutcome) -> Void) {
        guard !isFetchInFlight else {
            completion(.skippedInFlight)
            return
        }
        let now = Date()
        if let rateLimitRetryAt, ClaudeUsageCore.shouldSkipRateLimitBackoff(retryAt: rateLimitRetryAt, now: now) {
            completion(.skippedRateLimitBackoff(retryAt: rateLimitRetryAt))
            return
        }
        if ClaudeUsageCore.shouldThrottleFetch(minimumInterval: minimumInterval, lastFetchDate: lastFetchDate, now: now) {
            completion(.skippedThrottled)
            return
        }

        switch resolveToken() {
        case .token(let token):
            performFetch(token: token, completion: completion)
        case .keychainUnreadable:
            completion(.keychainCredentialUnreadable)
        case .none:
            completion(.noCredential)
        }
    }

    @MainActor
    private static func performFetch(token: String, completion: @escaping (ClaudeUsageFetchOutcome) -> Void) {
        isFetchInFlight = true
        let fetchDate = Date()
        lastFetchDate = fetchDate
        UserDefaults.standard.set(fetchDate, forKey: lastFetchDefaultsKey)

        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let now = Date()
            let outcome: ClaudeUsageFetchOutcome
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    if let data, let snapshot = parse(data) {
                        outcome = .success(snapshot)
                    } else {
                        outcome = .decodeFailure
                    }
                } else if http.statusCode == 429 {
                    let backoffSeconds = ClaudeUsageCore.rateLimitBackoffSeconds(
                        retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                        now: now
                    )
                    outcome = .rateLimited(retryAt: now.addingTimeInterval(backoffSeconds))
                } else {
                    outcome = .httpFailure(status: http.statusCode)
                }
            } else {
                outcome = .transportFailure
            }
            DispatchQueue.main.async { @MainActor in
                isFetchInFlight = false
                switch outcome {
                case .success(let snapshot):
                    rateLimitRetryAt = nil
                    UserDefaults.standard.removeObject(forKey: rateLimitRetryDefaultsKey)
                    fetchProfileIfNeeded(token: token) { accountInfo in
                        completion(.success(accountInfo.map(snapshot.withAccount) ?? snapshot))
                    }
                case .httpFailure(let status) where status == 401 || status == 403:
                    cachedAccessToken = nil
                    completion(outcome)
                case .rateLimited(let retryAt):
                    rateLimitRetryAt = retryAt
                    UserDefaults.standard.set(retryAt, forKey: rateLimitRetryDefaultsKey)
                    completion(outcome)
                default:
                    completion(outcome)
                }
            }
        }.resume()
    }

    /// Fetches Claude account identity (email, organization) from the
    /// undocumented `/api/oauth/profile` endpoint using the same Bearer
    /// token as the usage fetch that just succeeded. At most one attempt is
    /// made per token per process; later usage fetches with the same token
    /// reuse whatever this first attempt returned (including `nil` on
    /// failure) without hitting the network again. A failure here never
    /// surfaces as a usage-refresh failure — it only leaves account info
    /// absent.
    @MainActor
    private static func fetchProfileIfNeeded(token: String, completion: @escaping (ClaudeAccountInfo?) -> Void) {
        guard !attemptedProfileTokens.contains(token) else {
            completion(latestAccountInfo)
            return
        }
        attemptedProfileTokens.insert(token)

        var request = URLRequest(url: profileURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, _ in
            var accountInfo: ClaudeAccountInfo?
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data {
                accountInfo = parseProfile(data)
            }
            DispatchQueue.main.async { @MainActor in
                latestAccountInfo = accountInfo
                completion(accountInfo)
            }
        }.resume()
    }

    private struct ProfileResponse: Decodable {
        struct Account: Decodable {
            let email: String?
            let emailAddress: String?
            enum CodingKeys: String, CodingKey {
                case email
                case emailAddress = "email_address"
            }
        }
        struct Organization: Decodable {
            let name: String?
            let uuid: String?
        }
        let account: Account?
        let organization: Organization?
    }

    /// Internal (not `private`) so unit tests can exercise response parsing
    /// via `@testable import` without a live network fetch.
    static func parseProfile(_ data: Data) -> ClaudeAccountInfo? {
        guard let response = try? JSONDecoder().decode(ProfileResponse.self, from: data) else { return nil }
        let email = response.account?.email ?? response.account?.emailAddress
        let organizationName = response.organization?.name
        let organizationUUID = response.organization?.uuid
        guard email != nil || organizationName != nil || organizationUUID != nil else { return nil }
        return ClaudeAccountInfo(email: email, organizationName: organizationName, organizationUUID: organizationUUID)
    }

    private enum KeychainTokenResult {
        case token(String)
        case notFound
        /// Item exists but couldn't be read back or decoded — distinct from
        /// `notFound` so the caller can surface that exact actionable state
        /// instead of silently falling through as if no credential existed.
        case unreadable
    }

    private enum TokenResolution {
        case token(String)
        case keychainUnreadable
        case none
    }

    /// The interactive `claude` CLI session's own OAuth token, stored by Claude
    /// Code in the login keychain. Unlike the `claude setup-token` file token,
    /// this one carries `user:profile` scope, which this usage endpoint
    /// requires. The caller keeps a successful read in process memory and
    /// clears it only after an authentication failure, avoiding recurring
    /// Keychain authorization prompts while still picking up rotated tokens.
    private static func readKeychainToken() -> KeychainTokenResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .notFound : .unreadable
        }
        guard let data = item as? Data,
              let credentials = try? JSONDecoder().decode(StoredCredentials.self, from: data)
        else { return .unreadable }
        return .token(credentials.claudeAiOauth.accessToken)
    }

    private struct StoredCredentials: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
        }
        let claudeAiOauth: OAuth
    }

    private static func readFileToken() -> String? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty ?? true) ? nil : token
    }

    /// Tries the keychain first, then falls back to the `claude setup-token`
    /// file — preserving both existing credential sources. A keychain item
    /// that exists but can't be decoded is only reported as `keychainUnreadable`
    /// if the file fallback also has no usable token.
    @MainActor
    private static func resolveToken() -> TokenResolution {
        if let cachedAccessToken {
            return .token(cachedAccessToken)
        }
        if let cachedTokenResolutionFailure {
            return cachedTokenResolutionFailure
        }

        switch readKeychainToken() {
        case .token(let token):
            cachedAccessToken = token
            return .token(token)
        case .unreadable:
            if let fileToken = readFileToken() {
                cachedAccessToken = fileToken
                return .token(fileToken)
            }
            cachedTokenResolutionFailure = .keychainUnreadable
            return .keychainUnreadable
        case .notFound:
            if let fileToken = readFileToken() {
                cachedAccessToken = fileToken
                return .token(fileToken)
            }
            cachedTokenResolutionFailure = TokenResolution.none
            return .none
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let usage: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case usage
            case resetsAt = "resets_at"
        }

        var value: Double? { utilization ?? usage }
    }

    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        let limits: [LimitEntry]?
        let extraUsage: ExtraUsageResponse?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case limits
            case extraUsage = "extra_usage"
        }

        /// `fiveHour`/`sevenDay` keep the pre-existing strict behavior (a
        /// malformed core field still fails the whole response). The newer
        /// optional fields are decoded leniently so a malformed
        /// `seven_day_opus`/`seven_day_sonnet`, `limits[]` entry, or
        /// `extra_usage` degrades to unavailable instead of breaking the
        /// core five-hour/weekly parse.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try container.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
            sevenDay = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
            sevenDayOpus = (try? container.decodeIfPresent(UsageWindow.self, forKey: .sevenDayOpus)) ?? nil
            sevenDaySonnet = (try? container.decodeIfPresent(UsageWindow.self, forKey: .sevenDaySonnet)) ?? nil
            limits = (try? container.decodeIfPresent([LimitEntry].self, forKey: .limits)) ?? nil
            extraUsage = (try? container.decodeIfPresent(ExtraUsageResponse.self, forKey: .extraUsage)) ?? nil
        }
    }

    /// A dynamic entry from `limits[]`. Only entries carrying a nonempty
    /// `scope.model.display_name` and a numeric `percent` become a
    /// model-specific weekly row — this naturally excludes session- and
    /// global-scoped entries in the same array.
    private struct LimitEntry: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String?
                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }
            let model: Model?
        }

        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case percent
            case resetsAt = "resets_at"
            case scope
        }
    }

    /// Optional pay-as-you-go spend info. Field names vary across API
    /// versions, so every known variant is decoded and reconciled defensively
    /// in `parseExtraUsage`.
    private struct ExtraUsageResponse: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let monthlyCreditLimit: Double?
        let spendLimitAmountCents: Double?
        let usedCredits: Double?
        let balanceCents: Double?
        let currency: String?
        let spendLimitCurrency: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case monthlyCreditLimit = "monthly_credit_limit"
            case spendLimitAmountCents = "spend_limit_amount_cents"
            case usedCredits = "used_credits"
            case balanceCents = "balance_cents"
            case currency
            case spendLimitCurrency = "spend_limit_currency"
        }
    }

    /// The live endpoint returns `resets_at` with fractional seconds
    /// (e.g. `2026-08-17T16:50:00.014898+00:00`), which the plain
    /// `iso8601Formatter` (used elsewhere for the statusLine cache's
    /// whole-second timestamps) can't parse.
    private static let resetsAtFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseResetsAt(_ string: String?) -> Date? {
        guard let string else { return nil }
        return resetsAtFormatter.date(from: string) ?? iso8601Formatter.date(from: string)
    }

    /// Legacy `seven_day_opus`/`seven_day_sonnet` rows come first (in that
    /// order), followed by any dynamic model-scoped `limits[]` entries in
    /// their original API order.
    private static func parseModelWeeklyLimits(_ response: UsageResponse) -> [ClaudeModelWeeklyLimit] {
        var limits: [ClaudeModelWeeklyLimit] = []

        if let opus = response.sevenDayOpus, let percent = opus.value {
            limits.append(ClaudeModelWeeklyLimit(modelName: "Opus", usedPercent: percent, resetsAt: parseResetsAt(opus.resetsAt)))
        }
        if let sonnet = response.sevenDaySonnet, let percent = sonnet.value {
            limits.append(ClaudeModelWeeklyLimit(modelName: "Sonnet", usedPercent: percent, resetsAt: parseResetsAt(sonnet.resetsAt)))
        }
        for entry in response.limits ?? [] {
            guard let displayName = entry.scope?.model?.displayName, !displayName.isEmpty,
                  let percent = entry.percent
            else { continue }
            limits.append(ClaudeModelWeeklyLimit(modelName: displayName, usedPercent: percent, resetsAt: parseResetsAt(entry.resetsAt)))
        }

        return limits
    }

    /// Missing, disabled, or malformed `extra_usage` all resolve to `nil`
    /// rather than failing the whole parse.
    private static func parseExtraUsage(_ raw: ExtraUsageResponse?) -> ClaudeExtraUsage? {
        guard let raw, raw.isEnabled == true else { return nil }

        let limitCents = raw.monthlyLimit ?? raw.monthlyCreditLimit ?? raw.spendLimitAmountCents
        let usedCents = raw.usedCredits ?? raw.balanceCents
        guard limitCents != nil || usedCents != nil else { return nil }

        return ClaudeExtraUsage(
            limitCents: limitCents,
            usedCents: usedCents,
            currency: raw.currency ?? raw.spendLimitCurrency
        )
    }

    /// Internal (not `private`) so unit tests can exercise response parsing
    /// via `@testable import` without a live network fetch.
    static func parse(_ data: Data) -> ClaudeUsageSnapshot? {
        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: data) else { return nil }
        return ClaudeUsageSnapshot(
            model: nil,
            weeklyUsedPercent: response.sevenDay?.value,
            weeklyResetsAt: parseResetsAt(response.sevenDay?.resetsAt),
            fiveHourUsedPercent: response.fiveHour?.value,
            fiveHourResetsAt: parseResetsAt(response.fiveHour?.resetsAt),
            contextUsedPercent: nil,
            contextRemainingPercent: nil,
            sessionCostUSD: nil,
            publishedAt: Date(),
            modelWeeklyLimits: parseModelWeeklyLimits(response),
            extraUsage: parseExtraUsage(response.extraUsage)
        )
    }
}
