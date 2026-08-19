import AppKit
import Foundation
import Security

/// Reads Claude Code's non-secret cached account metadata only. The OAuth
/// credential file and Keychain token are intentionally outside this path.
enum ClaudePlanStore {
    private static let accountMetadataURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    static func readTitle() -> String? {
        guard let data = try? Data(contentsOf: accountMetadataURL) else { return nil }
        return ClaudePlanCore.title(fromAccountMetadata: data)
    }
}

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
    let isEmphasized: Bool
    let accessibilityLabel: String

    init(
        label: String,
        value: String,
        detail: String? = nil,
        valueColor: NSColor? = nil,
        isEmphasized: Bool = false,
        accessibilityLabel: String? = nil
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.valueColor = valueColor
        self.isEmphasized = isEmphasized
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

/// Compact bar strip showing how much the column's metric was consumed at each
/// refresh, drawn directly under the column title.
struct UsageHistoryStrip {
    let caption: String
    /// Stored oldest-first. Only real readings; short histories are padded at
    /// draw time rather than in the data, and each sample keeps the timestamp
    /// of the refresh it came from so hovering a bar can report it.
    let samples: [UsageConsumptionSample]
    /// Slots the strip always draws, so the chart keeps a constant width.
    /// Filled from the left with the newest reading first.
    let slotCount: Int
    /// Appended to a hovered bar's value, e.g. " 크레딧" or "%".
    let unitSuffix: String
    let color: NSColor
    let accessibilityValue: String
}

struct UsagePanelColumn {
    let title: String
    let accentColor: NSColor
    let quota: UsagePanelQuota?
    /// Optional companion quota shown to the right of the primary ring.
    /// Claude uses this for its weekly window beside the 5-hour session.
    let secondaryQuota: UsagePanelQuota?
    /// Optional third quota ring shown to the right of `secondaryQuota`.
    /// Claude uses this for its overall weekly window when a model-specific
    /// (Fable) weekly limit has already taken the secondary ring slot.
    let tertiaryQuota: UsagePanelQuota?
    let rows: [UsagePanelRow]
    /// Account identity and refresh age are laid out in separate, shared-height
    /// footer bands so all columns line up immediately above the chart.
    let accountLines: [String]
    let refreshLine: String?
    /// Additional status such as a fetch failure or backoff countdown.
    let statusLines: [String]
    let statusColor: NSColor
    /// When set, the *primary* quota ring is drawn as a multi-color sweep
    /// through these colors instead of a solid `quota.color` stroke. Gemini
    /// uses this for Google's four brand colors so it never reads as a
    /// single solid accent the way Codex/Claude do; `nil` for every other
    /// column preserves the existing solid-ring look exactly.
    let primaryQuotaGradientColors: [NSColor]?
    let secondaryQuotaGradientColors: [NSColor]?

    init(
        title: String,
        accentColor: NSColor,
        quota: UsagePanelQuota?,
        secondaryQuota: UsagePanelQuota?,
        tertiaryQuota: UsagePanelQuota? = nil,
        rows: [UsagePanelRow],
        accountLines: [String],
        refreshLine: String?,
        statusLines: [String],
        statusColor: NSColor,
        primaryQuotaGradientColors: [NSColor]? = nil,
        secondaryQuotaGradientColors: [NSColor]? = nil
    ) {
        self.title = title
        self.accentColor = accentColor
        self.quota = quota
        self.secondaryQuota = secondaryQuota
        self.tertiaryQuota = tertiaryQuota
        self.rows = rows
        self.accountLines = accountLines
        self.refreshLine = refreshLine
        self.statusLines = statusLines
        self.statusColor = statusColor
        self.primaryQuotaGradientColors = primaryQuotaGradientColors
        self.secondaryQuotaGradientColors = secondaryQuotaGradientColors
    }
}

/// Fixed-height bar strip, newest sample on the left.
private final class UsageHistoryBarView: NSView {
    private static let barGap: CGFloat = 2
    /// Zero-consumption refreshes still get a hairline, so the strip reads as
    /// "sampled, nothing used" rather than as a hole in the data.
    private static let minimumBarHeight: CGFloat = 1.5

    /// Real samples only, stored oldest-first. Never padded — padding is a
    /// drawing concern, so the data stays honest about how much was measured.
    /// Drawing reverses the order so the newest reading sits at the left edge.
    var samples: [UsageConsumptionSample] = [] {
        didSet { needsDisplay = true }
    }
    /// Appended to the hovered value in the hover readout.
    var unitSuffix: String = ""
    /// Called with the hovered sample, or `nil` when the pointer leaves the
    /// strip. The owner uses it to swap the caption for a readout.
    var onHover: ((UsageConsumptionSample?) -> Void)?

    private var hoveredSlot: Int?

    private static let hoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "a h:mm:ss"
        return formatter
    }()

    /// Text shown when a bar is hovered: when the refresh happened and what it
    /// cost.
    static func hoverTitle(for sample: UsageConsumptionSample, unitSuffix: String) -> String {
        let time = hoverTimeFormatter.string(from: sample.at)
        return "\(time) · \(UsageConsumptionCore.amountTitle(sample.amount, unit: unitSuffix))"
    }
    /// Total slots drawn. Slots with no sample yet render as faint placeholders
    /// so "we measured and nothing was used" stays distinguishable from
    /// "we have not measured this far back yet".
    var slotCount: Int = UsageConsumptionTracker.defaultCapacity {
        didSet { needsDisplay = true }
    }
    var barColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installHoverTracking()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let slots = max(slotCount, samples.count)
        guard slots > 0 else { return }

        let fractions = UsageConsumptionCore.barFractions(samples.map(\.amount))
        let count = CGFloat(slots)
        let totalGap = Self.barGap * max(0, count - 1)
        let barWidth = max(1, (bounds.width - totalGap) / count)
        let baseline = bounds.height
        let radius = min(1.5, barWidth / 2)

        for index in 0..<slots {
            // Slot 0 is the newest reading; older ones trail off to the right.
            let sampleIndex = UsageConsumptionCore.sampleIndex(
                forSlot: index,
                sampleCount: fractions.count
            )
            let fraction = sampleIndex.map { fractions[$0] }
            let height: CGFloat
            let color: NSColor
            switch fraction {
            case .some(let value) where value > 0:
                height = max(Self.minimumBarHeight, CGFloat(value) * bounds.height)
                color = barColor
            case .some:
                // Measured, consumed nothing.
                height = Self.minimumBarHeight
                color = barColor.withAlphaComponent(0.28)
            case .none:
                // Not measured yet: an even fainter placeholder so the strip
                // holds its shape without claiming a reading that never happened.
                height = Self.minimumBarHeight
                color = barColor.withAlphaComponent(0.10)
            }
            let x = CGFloat(index) * (barWidth + Self.barGap)
            if index == hoveredSlot {
                // A faint full-height backdrop, so it is obvious which bar the
                // readout belongs to even when that bar is a hairline.
                NSColor.labelColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(
                    roundedRect: NSRect(x: x - 1, y: 0, width: barWidth + 2, height: bounds.height),
                    xRadius: 2,
                    yRadius: 2
                ).fill()
            }
            let rect = NSRect(x: x, y: baseline - height, width: barWidth, height: height)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
    }

    // MARK: - Hover
    //
    // ONE tracking area, installed once in init and never touched again.
    //
    // The previous version rebuilt a tracking area per slot from inside
    // `updateTrackingAreas()` and from every data/geometry change. Removing and
    // re-adding areas there makes AppKit schedule another update pass, which
    // rebuilds them again — the main thread spins at 100% instead of returning
    // to the event loop. With a menu open that is indistinguishable from a
    // freeze: NSMenu owns keyboard input while tracking, so the whole machine
    // stops accepting keystrokes. `.inVisibleRect` lets AppKit keep this single
    // area's geometry in sync on its own, so nothing ever needs rebuilding.

    private func installHoverTracking() {
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    /// Slot under a point in this view's coordinates, or nil if outside.
    private func slot(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let slots = max(slotCount, samples.count)
        guard slots > 0, bounds.width > 0 else { return nil }
        let totalGap = Self.barGap * CGFloat(max(0, slots - 1))
        let barWidth = max(1, (bounds.width - totalGap) / CGFloat(slots))
        let step = barWidth + Self.barGap
        let index = Int(floor(point.x / step))
        return (0..<slots).contains(index) ? index : nil
    }

    private func updateHover(to slot: Int?) {
        guard slot != hoveredSlot else { return }
        hoveredSlot = slot
        let sample = slot
            .flatMap { UsageConsumptionCore.sampleIndex(forSlot: $0, sampleCount: samples.count) }
            .map { samples[$0] }
        toolTip = sample.map { Self.hoverTitle(for: $0, unitSuffix: unitSuffix) }
        needsDisplay = true
        onHover?(sample)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(to: slot(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(to: slot(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(to: nil)
    }
}

struct UsagePanelModel {
    let codex: UsagePanelColumn
    let claude: UsagePanelColumn
    let gemini: UsagePanelColumn
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
    /// When set, the progress arc is filled with a sweep through these colors
    /// instead of stroked in `progressColor`. Used for Gemini's four-color
    /// brand mark so its quota ring never reads as one flat accent.
    var gradientColors: [NSColor]? {
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
        // Leave a half-point anti-aliasing safety margin so round caps on a
        // full Gemini ring never touch the view edge at 99–100%.
        let inset = lineWidth / 2 + 0.5
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

        if let gradientColors, gradientColors.count >= 2 {
            drawGradientProgress(progress, colors: gradientColors, rect: squareRect)
        } else {
            progressColor.setStroke()
            progress.stroke()
        }
    }

    /// Fills the swept arc with a diagonal linear gradient through
    /// `colors`, by converting the stroke into a fillable outline (via
    /// `CGPath`'s stroking copy) and clipping to it before drawing the
    /// gradient across the ring's own bounding box.
    private func drawGradientProgress(_ progress: NSBezierPath, colors: [NSColor], rect: NSRect) {
        guard let gradient = NSGradient(colors: colors) else {
            progressColor.setStroke()
            progress.stroke()
            return
        }
        let strokedOutline = progress.ccmbCGPath.copy(
            strokingWithWidth: progress.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 1,
            transform: .identity
        )

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath.ccmbMakePath(from: strokedOutline).addClip()
        // The stroked outline extends half a line width beyond `rect`.
        // Drawing the gradient only inside `rect` clipped that outer half at
        // all four extrema, making Gemini's circle look square-cropped.
        // The outline clip still limits paint to the ring itself, so using
        // the full view bounds here restores the complete round stroke.
        gradient.draw(in: bounds, angle: 45)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private extension NSBezierPath {
    /// Hand-converted from the path's own element list. Named distinctly
    /// (not `cgPath`) so this never collides with AppKit's own same-named
    /// convenience on newer macOS SDKs.
    var ccmbCGPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }

    /// Named distinctly (not `init(cgPath:)`) so this never collides with
    /// AppKit's own same-signature convenience on newer macOS SDKs.
    static func ccmbMakePath(from cgPath: CGPath) -> NSBezierPath {
        let path = NSBezierPath()
        cgPath.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                path.move(to: element.points[0])
            case .addLineToPoint:
                path.line(to: element.points[0])
            case .addQuadCurveToPoint:
                let currentPoint = path.currentPoint
                let control = element.points[0]
                let end = element.points[1]
                let control1 = NSPoint(
                    x: currentPoint.x + (control.x - currentPoint.x) * 2 / 3,
                    y: currentPoint.y + (control.y - currentPoint.y) * 2 / 3
                )
                let control2 = NSPoint(
                    x: end.x + (control.x - end.x) * 2 / 3,
                    y: end.y + (control.y - end.y) * 2 / 3
                )
                path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
            case .addCurveToPoint:
                path.curve(to: element.points[2], controlPoint1: element.points[0], controlPoint2: element.points[1])
            case .closeSubpath:
                path.close()
            @unknown default:
                break
            }
        }
        return path
    }
}

/// A single rounded metric row: a leading label, a trailing value, and an
/// optional full-width detail line (e.g. an exact reset date/time).
private final class UsageRowBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Read-only metrics are table rows, not controls. A single hairline
        // separates them without the rounded filled surface used by buttons.
        NSColor.separatorColor.withAlphaComponent(0.45).setFill()
        NSBezierPath.fill(NSRect(x: 4, y: bounds.maxY - 1, width: max(0, bounds.width - 8), height: 1))
    }
}

private final class UsageMetricRowView: NSView {
    private static let horizontalInset: CGFloat = 8
    private static let firstLineHeight: CGFloat = 15
    private static let detailLineHeight: CGFloat = 12
    private static let maximumLabelWidthFraction: CGFloat = 0.55
    private static let minimumValueWidth: CGFloat = 88

    private let backgroundView = UsageRowBackgroundView()
    private let labelField = UsageMetricRowView.makeLabel(color: .secondaryLabelColor, size: 11.5, weight: .regular)
    private let valueField: NSTextField = {
        let field = UsageMetricRowView.makeLabel(color: .labelColor, size: 12, weight: .regular)
        field.alignment = .right
        return field
    }()
    private let detailField = UsageMetricRowView.makeLabel(color: .secondaryLabelColor, size: 10, weight: .regular)

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
        valueField.isHidden = row.value.isEmpty
        valueField.textColor = row.valueColor ?? NSColor.labelColor.withAlphaComponent(0.60)
        valueField.font = .systemFont(ofSize: 12, weight: row.isEmphasized ? .bold : .regular)
        let hasDetail = row.detail != nil
        detailField.stringValue = row.detail ?? ""
        detailField.isHidden = !hasDetail
        setAccessibilityElement(true)
        setAccessibilityLabel(row.accessibilityLabel)

        backgroundView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let inset = Self.horizontalInset
        let firstLineY = hasDetail ? 5 : (height - Self.firstLineHeight) / 2
        let labelWidth: CGFloat
        if row.value.isEmpty {
            labelWidth = max(0, width - inset * 2)
        } else {
            let desiredLabelWidth = ceil(labelField.intrinsicContentSize.width) + 4
            let maximumLabelWidth = width * Self.maximumLabelWidthFraction - inset
            let valueProtectedWidth = width - inset * 2 - Self.minimumValueWidth
            labelWidth = max(0, min(desiredLabelWidth, maximumLabelWidth, valueProtectedWidth))
        }
        labelField.frame = NSRect(x: inset, y: firstLineY, width: labelWidth, height: Self.firstLineHeight)
        if row.value.isEmpty {
            valueField.frame = .zero
        } else {
            let valueX = inset + labelWidth
            let valueWidth = max(0, width - valueX - inset)
            valueField.frame = NSRect(x: valueX, y: firstLineY, width: valueWidth, height: Self.firstLineHeight)
        }

        if hasDetail {
            let detailY = firstLineY + Self.firstLineHeight
            detailField.frame = NSRect(x: inset, y: detailY, width: max(0, width - inset * 2), height: Self.detailLineHeight)
        } else {
            detailField.frame = .zero
        }
    }
}

private final class ProviderTitleMarkView: NSView {
    enum Style {
        case codex, claude, gemini

        init(providerTitle: String) {
            switch providerTitle {
            case "Claude": self = .claude
            case "Gemini": self = .gemini
            default: self = .codex
            }
        }
    }

    var style: Style = .codex { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch style {
        case .codex: drawCodexMark()
        case .claude: drawClaudeMark()
        case .gemini: drawGeminiMark()
        }
    }

    /// Compact six-lobed knot silhouette, kept inside a one-point safety
    /// margin so the OpenAI/Codex mark never clips at menu scale.
    private func drawCodexMark() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.lineWidth = 1.45
        path.lineCapStyle = .round
        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            let next = angle + .pi / 3
            let p1 = NSPoint(x: center.x + cos(angle) * 5, y: center.y + sin(angle) * 5)
            let p2 = NSPoint(x: center.x + cos(next) * 5, y: center.y + sin(next) * 5)
            let control = NSPoint(x: center.x + cos(angle + .pi / 6) * 2.2, y: center.y + sin(angle + .pi / 6) * 2.2)
            path.move(to: p1)
            path.curve(to: p2, controlPoint1: control, controlPoint2: control)
        }
        UsageBrandColors.codex.setStroke()
        path.stroke()
    }

    /// Claude's characteristic radial burst, using the requested terracotta.
    private func drawClaudeMark() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.lineWidth = 1.55
        path.lineCapStyle = .round
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            path.move(to: NSPoint(x: center.x + cos(angle) * 1.7, y: center.y + sin(angle) * 1.7))
            path.line(to: NSPoint(x: center.x + cos(angle) * 5.3, y: center.y + sin(angle) * 5.3))
        }
        UsageBrandColors.claude.setStroke()
        path.stroke()
    }

    /// Four-color Gemini sparkle. Each arm owns one Google brand color so
    /// the 14pt mark stays crisp instead of collapsing a gradient to gray.
    private func drawGeminiMark() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let points = [
            NSPoint(x: c.x, y: 1), NSPoint(x: bounds.maxX - 1, y: c.y),
            NSPoint(x: c.x, y: bounds.maxY - 1), NSPoint(x: 1, y: c.y)
        ]
        for index in 0..<4 {
            let path = NSBezierPath()
            path.move(to: c)
            path.line(to: points[index])
            path.line(to: points[(index + 1) % 4])
            path.close()
            UsageBrandColors.geminiGradient[index].setFill()
            path.fill()
        }
    }
}

/// One column of the panel: a title, an optional primary quota ring, a
/// stack of metric rows, and an aligned account/refresh footer.
private final class UsageColumnView: NSView {
    private static let titleHeight: CGFloat = 16
    private static let titleGap: CGFloat = 6
    private static let quotaDiameter: CGFloat = 46
    private static let quotaLineWidth: CGFloat = 4
    private static let quotaGroupGap: CGFloat = 6
    private static let quotaCaptionHeight: CGFloat = 14
    private static let quotaCaptionGap: CGFloat = 3
    private static let rowGap: CGFloat = 0
    private static let rowsTopGap: CGFloat = 8
    private static let singleLineRowHeight: CGFloat = 26
    private static let detailRowHeight: CGFloat = 38
    private static let statusTopGap: CGFloat = 8
    private static let statusLineHeight: CGFloat = 15

    private let titleLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 13, weight: .regular)
        return field
    }()
    private let titleMarkView = ProviderTitleMarkView()
    private let ringView = UsageRingView()
    private let percentLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        field.alignment = .center
        field.textColor = NSColor.labelColor.withAlphaComponent(0.60)
        return field
    }()
    private let quotaCaptionLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.alignment = .center
        return field
    }()
    private let secondaryRingView = UsageRingView()
    private let secondaryPercentLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .center
        field.textColor = NSColor.labelColor.withAlphaComponent(0.60)
        return field
    }()
    private let secondaryQuotaCaptionLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.alignment = .center
        return field
    }()
    private let tertiaryRingView = UsageRingView()
    private let tertiaryPercentLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .center
        field.textColor = NSColor.labelColor.withAlphaComponent(0.60)
        return field
    }()
    private let tertiaryQuotaCaptionLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.alignment = .center
        return field
    }()
    private let accountLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }()
    private let refreshLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }()
    private let statusLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 11, weight: .medium)
        return field
    }()

    private var rowViews: [UsageMetricRowView] = []
    private var accountLineCount = 0
    private var hasRefreshLine = false
    private var statusLineCount = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(titleMarkView)
        addSubview(titleLabel)
        addSubview(ringView)
        addSubview(percentLabel)
        addSubview(quotaCaptionLabel)
        addSubview(secondaryRingView)
        addSubview(secondaryPercentLabel)
        addSubview(secondaryQuotaCaptionLabel)
        addSubview(tertiaryRingView)
        addSubview(tertiaryPercentLabel)
        addSubview(tertiaryQuotaCaptionLabel)
        addSubview(accountLabel)
        addSubview(refreshLabel)
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Lays out the column immediately using the given fixed width and
    /// returns the body height. The caller then gives all columns one shared
    /// footer origin so account and refresh information align horizontally.
    @discardableResult
    func apply(_ column: UsagePanelColumn, width: CGFloat) -> CGFloat {
        titleLabel.stringValue = column.title
        titleLabel.textColor = column.accentColor
        titleMarkView.style = ProviderTitleMarkView.Style(providerTitle: column.title)
        titleMarkView.frame = NSRect(x: 0, y: 1, width: 14, height: 14)
        titleLabel.frame = NSRect(x: 20, y: 0, width: max(0, width - 20), height: Self.titleHeight)

        var y: CGFloat = Self.titleHeight

        if let quota = column.quota {
            y += Self.titleGap
            ringView.isHidden = false
            percentLabel.isHidden = false
            quotaCaptionLabel.isHidden = false
            ringView.progressColor = quota.color
            ringView.trackColor = quota.fraction <= 0
                ? quota.color.withAlphaComponent(0.55)
                : quota.color.withAlphaComponent(0.18)
            ringView.fraction = quota.fraction
            ringView.gradientColors = column.primaryQuotaGradientColors
            percentLabel.stringValue = quota.percentText
            quotaCaptionLabel.stringValue = quota.caption
            ringView.setAccessibilityElement(true)
            ringView.setAccessibilityLabel(quota.caption)
            ringView.setAccessibilityValue(quota.accessibilityValue)

            // Codex, Claude, and Gemini share one ring grid: identical
            // diameter, stroke, vertical origin, and caption baseline. Only
            // the number of equal-width groups differs by provider.
            let quotaCount = 1
                + (column.secondaryQuota == nil ? 0 : 1)
                + (column.tertiaryQuota == nil ? 0 : 1)
            let groupWidth = (
                width - Self.quotaGroupGap * CGFloat(max(0, quotaCount - 1))
            ) / CGFloat(quotaCount)
            let diameter = Self.quotaDiameter
            ringView.lineWidth = Self.quotaLineWidth
            percentLabel.font = .monospacedDigitSystemFont(
                ofSize: quota.percentText.count >= 4 ? 11 : 13,
                weight: .bold
            )
            let primaryRingX = (groupWidth - diameter) / 2
            ringView.frame = NSRect(x: primaryRingX, y: y, width: diameter, height: diameter)
            percentLabel.frame = NSRect(x: primaryRingX, y: y + (diameter - 16) / 2, width: diameter, height: 16)
            quotaCaptionLabel.frame = NSRect(
                x: 0,
                y: y + diameter + Self.quotaCaptionGap,
                width: groupWidth,
                height: Self.quotaCaptionHeight
            )

            if let secondaryQuota = column.secondaryQuota {
                secondaryRingView.isHidden = false
                secondaryPercentLabel.isHidden = false
                secondaryQuotaCaptionLabel.isHidden = false
                secondaryRingView.progressColor = secondaryQuota.color
                secondaryRingView.trackColor = secondaryQuota.fraction <= 0
                    ? secondaryQuota.color.withAlphaComponent(0.55)
                    : secondaryQuota.color.withAlphaComponent(0.18)
                secondaryRingView.fraction = secondaryQuota.fraction
                secondaryRingView.gradientColors = column.secondaryQuotaGradientColors
                secondaryRingView.lineWidth = Self.quotaLineWidth
                secondaryPercentLabel.stringValue = secondaryQuota.percentText
                secondaryPercentLabel.font = .monospacedDigitSystemFont(
                    ofSize: secondaryQuota.percentText.count >= 4 ? 11 : 13,
                    weight: .regular
                )
                secondaryQuotaCaptionLabel.stringValue = secondaryQuota.caption
                secondaryRingView.setAccessibilityElement(true)
                secondaryRingView.setAccessibilityLabel(secondaryQuota.caption)
                secondaryRingView.setAccessibilityValue(secondaryQuota.accessibilityValue)

                let secondaryGroupX = groupWidth + Self.quotaGroupGap
                let ringX = secondaryGroupX + (groupWidth - diameter) / 2
                secondaryRingView.frame = NSRect(x: ringX, y: y, width: diameter, height: diameter)
                secondaryPercentLabel.frame = NSRect(x: ringX, y: y + (diameter - 16) / 2, width: diameter, height: 16)
                secondaryQuotaCaptionLabel.frame = NSRect(
                    x: secondaryGroupX,
                    y: y + diameter + Self.quotaCaptionGap,
                    width: groupWidth,
                    height: Self.quotaCaptionHeight
                )
            } else {
                secondaryRingView.isHidden = true
                secondaryPercentLabel.isHidden = true
                secondaryQuotaCaptionLabel.isHidden = true
            }

            if let tertiaryQuota = column.tertiaryQuota {
                tertiaryRingView.isHidden = false
                tertiaryPercentLabel.isHidden = false
                tertiaryQuotaCaptionLabel.isHidden = false
                tertiaryRingView.progressColor = tertiaryQuota.color
                tertiaryRingView.trackColor = tertiaryQuota.fraction <= 0
                    ? tertiaryQuota.color.withAlphaComponent(0.55)
                    : tertiaryQuota.color.withAlphaComponent(0.18)
                tertiaryRingView.fraction = tertiaryQuota.fraction
                tertiaryRingView.lineWidth = Self.quotaLineWidth
                tertiaryPercentLabel.stringValue = tertiaryQuota.percentText
                tertiaryPercentLabel.font = .monospacedDigitSystemFont(
                    ofSize: tertiaryQuota.percentText.count >= 4 ? 11 : 13,
                    weight: .regular
                )
                tertiaryQuotaCaptionLabel.stringValue = tertiaryQuota.caption
                tertiaryRingView.setAccessibilityElement(true)
                tertiaryRingView.setAccessibilityLabel(tertiaryQuota.caption)
                tertiaryRingView.setAccessibilityValue(tertiaryQuota.accessibilityValue)

                let tertiaryGroupX = groupWidth * 2 + Self.quotaGroupGap * 2
                let ringX = tertiaryGroupX + (groupWidth - diameter) / 2
                tertiaryRingView.frame = NSRect(x: ringX, y: y, width: diameter, height: diameter)
                tertiaryPercentLabel.frame = NSRect(x: ringX, y: y + (diameter - 16) / 2, width: diameter, height: 16)
                tertiaryQuotaCaptionLabel.frame = NSRect(
                    x: tertiaryGroupX,
                    y: y + diameter + Self.quotaCaptionGap,
                    width: groupWidth,
                    height: Self.quotaCaptionHeight
                )
            } else {
                tertiaryRingView.isHidden = true
                tertiaryPercentLabel.isHidden = true
                tertiaryQuotaCaptionLabel.isHidden = true
            }

            y += diameter + Self.quotaCaptionGap + Self.quotaCaptionHeight
        } else {
            ringView.isHidden = true
            percentLabel.isHidden = true
            quotaCaptionLabel.isHidden = true
            secondaryRingView.isHidden = true
            secondaryPercentLabel.isHidden = true
            secondaryQuotaCaptionLabel.isHidden = true
            tertiaryRingView.isHidden = true
            tertiaryPercentLabel.isHidden = true
            tertiaryQuotaCaptionLabel.isHidden = true
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

        accountLineCount = column.accountLines.count
        accountLabel.stringValue = column.accountLines.joined(separator: "\n")
        accountLabel.isHidden = column.accountLines.isEmpty
        hasRefreshLine = column.refreshLine != nil
        refreshLabel.stringValue = column.refreshLine ?? ""
        refreshLabel.isHidden = column.refreshLine == nil
        statusLineCount = column.statusLines.count
        statusLabel.stringValue = column.statusLines.joined(separator: "\n")
        statusLabel.textColor = column.statusColor
        statusLabel.isHidden = column.statusLines.isEmpty

        var accessibilityParts = [column.title]
        if let quota = column.quota {
            accessibilityParts.append(quota.accessibilityValue)
        }
        if let secondaryQuota = column.secondaryQuota {
            accessibilityParts.append(secondaryQuota.accessibilityValue)
        }
        if let tertiaryQuota = column.tertiaryQuota {
            accessibilityParts.append(tertiaryQuota.accessibilityValue)
        }
        accessibilityParts.append(contentsOf: column.rows.map(\.accessibilityLabel))
        accessibilityParts.append(contentsOf: column.accountLines)
        if let refreshLine = column.refreshLine {
            accessibilityParts.append(refreshLine)
        }
        accessibilityParts.append(contentsOf: column.statusLines)
        let accessibilitySummary = accessibilityParts.joined(separator: ", ")
        setAccessibilityElement(true)
        setAccessibilityLabel(accessibilitySummary)

        return y
    }

    func footerCapacities() -> (account: Int, refresh: Int, status: Int) {
        (accountLineCount, hasRefreshLine ? 1 : 0, statusLineCount)
    }

    func footerHeight(accountCapacity: Int, refreshCapacity: Int, statusCapacity: Int) -> CGFloat {
        let lineCount = accountCapacity + refreshCapacity + statusCapacity
        return lineCount == 0 ? 0 : Self.statusTopGap + CGFloat(lineCount) * Self.statusLineHeight
    }

    func layoutFooter(
        top: CGFloat,
        width: CGFloat,
        accountCapacity: Int,
        refreshCapacity: Int,
        statusCapacity: Int
    ) {
        guard accountCapacity + refreshCapacity + statusCapacity > 0 else { return }
        var y = top + Self.statusTopGap
        let textInset: CGFloat = 8
        let textWidth = max(0, width - textInset * 2)
        let accountHeight = CGFloat(accountLineCount) * Self.statusLineHeight
        let accountOffset = CGFloat(max(0, accountCapacity - accountLineCount)) * Self.statusLineHeight
        accountLabel.frame = NSRect(x: textInset, y: y + accountOffset, width: textWidth, height: accountHeight)
        y += CGFloat(accountCapacity) * Self.statusLineHeight
        refreshLabel.frame = NSRect(x: textInset, y: y, width: textWidth, height: hasRefreshLine ? Self.statusLineHeight : 0)
        y += CGFloat(refreshCapacity) * Self.statusLineHeight
        let statusHeight = CGFloat(statusLineCount) * Self.statusLineHeight
        statusLabel.frame = NSRect(x: textInset, y: y, width: textWidth, height: statusHeight)
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

/// Shared column geometry for every fixed-width row in the usage menu
/// (the split panel itself, the history chart, and the usage-page buttons)
/// so their three columns and two dividers always land at the same x
/// positions and the menu reads as one object end to end.
enum UsagePanelLayout {
    static let columnWidth: CGFloat = 178
    static let columnGap: CGFloat = 12
    static let sidePadding: CGFloat = 12
    static let controlRowHeight: CGFloat = 30
    static let controlVerticalInset: CGFloat = 3
    static let columnCount = 3
    static let viewWidth: CGFloat = sidePadding * 2 + columnWidth * CGFloat(columnCount) + columnGap * CGFloat(columnCount - 1)

    /// Leading x of each of the three columns, left to right.
    static let columnX: [CGFloat] = (0..<columnCount).map { index in
        sidePadding + CGFloat(index) * (columnWidth + columnGap)
    }

    /// x of the hairline divider between column `index` and `index + 1`.
    static func dividerX(after index: Int) -> CGFloat {
        columnX[index] + columnWidth + columnGap / 2
    }
}

/// Native rounded button with a deliberately quiet rollover. Custom views in
/// an `NSMenu` do not always receive AppKit's usual hover treatment, so the
/// bezel gets a light tint only while the pointer is over an enabled button.
@MainActor
final class RolloverButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        alphaValue = 0.50
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        let tint = contentTintColor ?? .controlAccentColor
        alphaValue = 1
        bezelColor = tint.withAlphaComponent(0.18)
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = 0.50
        bezelColor = nil
    }
}

/// Three-column status panel — Codex, Claude, then Gemini — hosted as the
/// `view` of a single NSMenuItem.
@MainActor
final class SplitUsagePanelView: NSView {
    private let columnWidth = UsagePanelLayout.columnWidth
    private let topPadding: CGFloat = 5
    private let bottomPadding: CGFloat = 10

    private let codexColumnView = UsageColumnView()
    private let claudeColumnView = UsageColumnView()
    private let geminiColumnView = UsageColumnView()
    private let dividers: [NSView] = (0..<UsagePanelLayout.columnCount - 1).map { _ in
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: UsagePanelLayout.viewWidth, height: 40))
        addSubview(codexColumnView)
        addSubview(claudeColumnView)
        addSubview(geminiColumnView)
        dividers.forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ model: UsagePanelModel) {
        let columnViews = [codexColumnView, claudeColumnView, geminiColumnView]
        let columns = [model.codex, model.claude, model.gemini]

        let bodyHeights = zip(columnViews, columns).map { view, column in view.apply(column, width: columnWidth) }
        let bodyHeight = max(bodyHeights.max() ?? 1, 1)

        let footers = columnViews.map { $0.footerCapacities() }
        let accountCapacity = footers.map { $0.account }.max() ?? 0
        let refreshCapacity = footers.map { $0.refresh }.max() ?? 0
        let statusCapacity = footers.map { $0.status }.max() ?? 0
        let footerHeight = codexColumnView.footerHeight(
            accountCapacity: accountCapacity,
            refreshCapacity: refreshCapacity,
            statusCapacity: statusCapacity
        )
        let contentHeight = bodyHeight + footerHeight

        for columnView in columnViews {
            columnView.layoutFooter(
                top: bodyHeight,
                width: columnWidth,
                accountCapacity: accountCapacity,
                refreshCapacity: refreshCapacity,
                statusCapacity: statusCapacity
            )
        }

        for (index, columnView) in columnViews.enumerated() {
            columnView.frame = NSRect(x: UsagePanelLayout.columnX[index], y: topPadding, width: columnWidth, height: contentHeight)
        }
        for (index, divider) in dividers.enumerated() {
            divider.frame = NSRect(x: UsagePanelLayout.dividerX(after: index), y: topPadding, width: 1, height: contentHeight)
        }

        var newFrame = frame
        newFrame.size.height = topPadding + contentHeight + bottomPadding
        newFrame.size.width = UsagePanelLayout.viewWidth
        frame = newFrame

        let codexSummary = model.codex.quota?.accessibilityValue ?? model.codex.title
        let claudeSummary = model.claude.quota?.accessibilityValue ?? model.claude.title
        let geminiSummary = model.gemini.quota?.accessibilityValue ?? model.gemini.title
        setAccessibilityLabel("Codex, Claude 및 Gemini 사용량 패널")
        setAccessibilityValue("\(codexSummary), \(claudeSummary), \(geminiSummary)")
    }
}

/// Full-width per-refresh consumption chart, hosted as its own NSMenuItem
/// directly above the usage-page buttons. Its column geometry deliberately
/// matches `SplitUsagePanelView` so each strip lines up under the Codex and
/// Claude columns it belongs to.
@MainActor
final class UsageHistoryChartView: NSView {
    // Column geometry comes from the shared `UsagePanelLayout` on purpose:
    // the three strips must sit exactly under the Codex, Claude and Gemini
    // columns above them, and the inner dividers must line up with that
    // panel's dividers. That alignment is what makes the whole menu read as
    // one object.
    private static let viewWidth: CGFloat = UsagePanelLayout.viewWidth
    private static let columnWidth: CGFloat = UsagePanelLayout.columnWidth

    /// The card is inset from the strips, not the other way round, so the bars
    /// keep their column alignment while the card frames them.
    private static let cardInset: CGFloat = UsagePanelLayout.sidePadding
    private static let columnContentInset: CGFloat = 6
    private static let cardTop: CGFloat = 5
    private static let cardPadding: CGFloat = 8
    private static let cardCornerRadius: CGFloat = 10

    private static let captionHeight: CGFloat = 13
    private static let captionGap: CGFloat = 4
    private static let barsHeight: CGFloat = 56
    private static let bottomPadding: CGFloat = 5
    private static let dotDiameter: CGFloat = 6
    private static let dotTextGap: CGFloat = 10

    private static let contentTop = cardTop + cardPadding
    private static let barsTop = contentTop + captionHeight + captionGap
    private static let baselineY = barsTop + barsHeight
    private static let cardHeight =
        cardPadding + captionHeight + captionGap + barsHeight + cardPadding

    static let viewHeight: CGFloat = cardTop + cardHeight + bottomPadding

    private let codexCaption = UsageHistoryChartView.makeCaption()
    private let claudeCaption = UsageHistoryChartView.makeCaption()
    private let geminiCaption = UsageHistoryChartView.makeCaption()
    private let codexBars = UsageHistoryBarView()
    private let claudeBars = UsageHistoryBarView()
    private let geminiBars = UsageHistoryBarView()
    /// The caption each column falls back to once the pointer leaves its strip.
    private var codexBaseCaption = ""
    private var claudeBaseCaption = ""
    private var geminiBaseCaption = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        addSubview(codexCaption)
        addSubview(codexBars)
        addSubview(claudeCaption)
        addSubview(claudeBars)
        addSubview(geminiCaption)
        addSubview(geminiBars)
        setAccessibilityElement(false)

        codexBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.codexCaption.stringValue = sample
                .map { UsageHistoryBarView.hoverTitle(for: $0, unitSuffix: self.codexBars.unitSuffix) }
                ?? self.codexBaseCaption
        }
        claudeBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.claudeCaption.stringValue = sample
                .map { UsageHistoryBarView.hoverTitle(for: $0, unitSuffix: self.claudeBars.unitSuffix) }
                ?? self.claudeBaseCaption
        }
        geminiBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.geminiCaption.stringValue = sample
                .map { UsageHistoryBarView.hoverTitle(for: $0, unitSuffix: self.geminiBars.unitSuffix) }
                ?? self.geminiBaseCaption
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // The card. A single low-contrast surface with a hairline edge is
        // enough to read the three strips as one panel; a heavier box would
        // compete with the usage panel directly above it.
        let card = NSRect(
            x: Self.cardInset,
            y: Self.cardTop,
            width: bounds.width - Self.cardInset * 2,
            height: Self.cardHeight
        )
        let cardPath = NSBezierPath(
            roundedRect: card,
            xRadius: Self.cardCornerRadius,
            yRadius: Self.cardCornerRadius
        )
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        cardPath.fill()
        NSColor.separatorColor.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        // Dividers between columns, at the same x as the usage panel's.
        NSColor.separatorColor.setFill()
        for index in 0..<(UsagePanelLayout.columnCount - 1) {
            NSBezierPath(rect: NSRect(
                x: UsagePanelLayout.dividerX(after: index),
                y: Self.contentTop,
                width: 1,
                height: Self.baselineY - Self.contentTop
            )).fill()
        }

        // A recessive floor under each strip, so the bars read as sitting on an
        // axis rather than floating.
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        for x in UsagePanelLayout.columnX {
            NSBezierPath(rect: NSRect(
                x: x + Self.columnContentInset,
                y: Self.baselineY,
                width: Self.columnWidth - Self.columnContentInset * 2,
                height: 1
            )).fill()
        }

        // Identity marks. The caption text itself stays in secondary ink —
        // the mark carries the series colour so the label never has to.
        // Gemini draws its four brand colors side by side instead of one
        // dot, so it is never presented as a single solid accent even here.
        drawDot(color: codexBars.barColor, x: UsagePanelLayout.columnX[0] + Self.columnContentInset, visible: !codexCaption.isHidden)
        drawDot(color: claudeBars.barColor, x: UsagePanelLayout.columnX[1] + Self.columnContentInset, visible: !claudeCaption.isHidden)
        drawGradientMark(colors: UsageBrandColors.geminiGradient, x: UsagePanelLayout.columnX[2] + Self.columnContentInset, visible: !geminiCaption.isHidden)
    }

    private func drawDot(color: NSColor, x: CGFloat, visible: Bool) {
        guard visible else { return }
        let y = Self.contentTop + (Self.captionHeight - Self.dotDiameter) / 2
        color.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: x,
            y: y,
            width: Self.dotDiameter,
            height: Self.dotDiameter
        )).fill()
    }

    private func drawGradientMark(colors: [NSColor], x: CGFloat, visible: Bool) {
        guard visible, !colors.isEmpty else { return }
        let y = Self.contentTop + (Self.captionHeight - Self.dotDiameter) / 2
        let sliceWidth = Self.dotDiameter / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            NSBezierPath(rect: NSRect(
                x: x + CGFloat(index) * sliceWidth,
                y: y,
                width: sliceWidth,
                height: Self.dotDiameter
            )).fill()
        }
    }

    private static func makeCaption() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 10, weight: .medium)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// Returns false when no column has anything to draw, so the caller can
    /// hide the whole row instead of leaving an empty band in the menu.
    @discardableResult
    func apply(codex: UsageHistoryStrip?, claude: UsageHistoryStrip?, gemini: UsageHistoryStrip?) -> Bool {
        codexBaseCaption = codex?.caption ?? ""
        claudeBaseCaption = claude?.caption ?? ""
        geminiBaseCaption = gemini?.caption ?? ""
        let codexShown = configure(codex, caption: codexCaption, bars: codexBars, x: UsagePanelLayout.columnX[0] + Self.columnContentInset)
        let claudeShown = configure(claude, caption: claudeCaption, bars: claudeBars, x: UsagePanelLayout.columnX[1] + Self.columnContentInset)
        let geminiShown = configure(gemini, caption: geminiCaption, bars: geminiBars, x: UsagePanelLayout.columnX[2] + Self.columnContentInset)
        let anyShown = codexShown || claudeShown || geminiShown
        needsDisplay = true
        return anyShown
    }

    private func configure(
        _ strip: UsageHistoryStrip?,
        caption: NSTextField,
        bars: UsageHistoryBarView,
        x: CGFloat
    ) -> Bool {
        guard let strip else {
            caption.isHidden = true
            bars.isHidden = true
            return false
        }
        caption.isHidden = false
        bars.isHidden = false
        caption.stringValue = strip.caption
        // Shifted right to clear the identity dot drawn at `x`.
        caption.frame = NSRect(
            x: x + Self.dotTextGap,
            y: Self.contentTop,
            width: max(0, Self.columnWidth - Self.columnContentInset * 2 - Self.dotTextGap),
            height: Self.captionHeight
        )
        bars.samples = Array(strip.samples.suffix(strip.slotCount))
        bars.slotCount = strip.slotCount
        bars.unitSuffix = strip.unitSuffix
        bars.barColor = strip.color
        bars.frame = NSRect(
            x: x,
            y: Self.barsTop,
            width: Self.columnWidth - Self.columnContentInset * 2,
            height: Self.barsHeight
        )
        bars.setAccessibilityElement(true)
        bars.setAccessibilityRole(.image)
        bars.setAccessibilityLabel(strip.caption)
        bars.setAccessibilityValue(strip.accessibilityValue)
        return true
    }
}

/// A persistent companion for the transient status-menu content. Native
/// `NSMenu` tracking always ends when the user clicks elsewhere, so keeping
/// the same live usage summary visible requires a small floating panel rather
/// than trying to override macOS menu dismissal behavior.
@MainActor
final class PinnedUsageWindowController: NSWindowController, NSWindowDelegate {
    // The persistent panel uses the exact same edge-to-edge dashboard stack as
    // the menu so switching to "always visible" never changes its geometry.
    private static let padding: CGFloat = 0
    private static let sectionGap: CGFloat = 0

    private let usageView = SplitUsagePanelView()
    private let historyView = UsageHistoryChartView()
    private let usagePageButtonsView = UsagePageButtonsView()
    private let refreshIntervalControlsView = RefreshIntervalControlsView()
    private let containerView = NSVisualEffectView()
    private var hasPositionedWindow = false

    var onClose: (() -> Void)?
    var onCodexRefreshIntervalChange: ((Int) -> Void)?
    var onClaudeRefreshIntervalChange: ((Int) -> Void)?
    var onGeminiRefreshIntervalChange: ((Int) -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    init() {
        let width = UsagePanelLayout.viewWidth + Self.padding * 2
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "CCMB 사용량 · 항상 보기"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true

        containerView.material = .popover
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        panel.contentView = containerView

        super.init(window: panel)
        panel.delegate = self
        containerView.addSubview(usageView)
        containerView.addSubview(historyView)
        containerView.addSubview(usagePageButtonsView)
        containerView.addSubview(refreshIntervalControlsView)

        usagePageButtonsView.codexButton.target = self
        usagePageButtonsView.codexButton.action = #selector(openCodexUsagePage)
        usagePageButtonsView.claudeButton.target = self
        usagePageButtonsView.claudeButton.action = #selector(openClaudeUsagePage)
        usagePageButtonsView.geminiButton.target = self
        usagePageButtonsView.geminiButton.action = #selector(openGeminiUsagePage)

        refreshIntervalControlsView.onCodexChange = { [weak self] in self?.onCodexRefreshIntervalChange?($0) }
        refreshIntervalControlsView.onClaudeChange = { [weak self] in self?.onClaudeRefreshIntervalChange?($0) }
        refreshIntervalControlsView.onGeminiChange = { [weak self] in self?.onGeminiRefreshIntervalChange?($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        model: UsagePanelModel,
        codexHistory: UsageHistoryStrip?,
        claudeHistory: UsageHistoryStrip?,
        geminiHistory: UsageHistoryStrip?,
        codexRefreshInterval: Int,
        claudeRefreshInterval: Int,
        geminiRefreshInterval: Int
    ) {
        usageView.apply(model)
        let showsHistory = historyView.apply(
            codex: codexHistory,
            claude: claudeHistory,
            gemini: geminiHistory
        )
        historyView.isHidden = !showsHistory
        refreshIntervalControlsView.apply(
            codex: codexRefreshInterval,
            claude: claudeRefreshInterval,
            gemini: geminiRefreshInterval
        )

        let historyHeight = showsHistory ? historyView.frame.height : 0
        let historyGap = showsHistory ? Self.sectionGap : 0
        let buttonsHeight = usagePageButtonsView.frame.height
        let controlsHeight = refreshIntervalControlsView.frame.height
        let contentHeight = Self.padding * 2
            + usageView.frame.height
            + historyGap + historyHeight
            + Self.sectionGap + buttonsHeight
            + Self.sectionGap + controlsHeight
        let contentWidth = UsagePanelLayout.viewWidth + Self.padding * 2

        usagePageButtonsView.frame.origin = NSPoint(x: Self.padding, y: Self.padding)
        historyView.frame.origin = NSPoint(
            x: Self.padding,
            y: Self.padding + buttonsHeight + Self.sectionGap
        )
        refreshIntervalControlsView.frame.origin = NSPoint(
            x: Self.padding,
            y: Self.padding + buttonsHeight + Self.sectionGap + historyHeight + historyGap
        )
        usageView.frame.origin = NSPoint(
            x: Self.padding, y: Self.padding + buttonsHeight + Self.sectionGap
                + historyHeight + historyGap + controlsHeight + Self.sectionGap
        )

        if let window {
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(NSSize(width: contentWidth, height: contentHeight))
            if hasPositionedWindow {
                window.setFrameTopLeftPoint(topLeft)
            }
        }
    }

    func show() {
        if !hasPositionedWindow {
            window?.center()
            hasPositionedWindow = true
        }
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func updateRefreshCountdown(codex: Int?, claude: Int?, gemini: Int?) {
        refreshIntervalControlsView.updateCountdown(codex: codex, claude: claude, gemini: gemini)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    @objc private func openCodexUsagePage() {
        NSWorkspace.shared.open(UsageDashboardURLs.codex)
    }

    @objc private func openClaudeUsagePage() {
        NSWorkspace.shared.open(UsageDashboardURLs.claude)
    }

    @objc private func openGeminiUsagePage() {
        NSWorkspace.shared.open(UsageDashboardURLs.gemini)
    }
}

enum UsageDashboardURLs {
    static let codex = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let claude = URL(string: "https://claude.ai/settings/usage")!
    static let gemini = URL(string: "https://gemini.google.com/usage")!
}

/// Compact three-button row linking to the Codex, Claude, and Gemini usage
/// web pages, replacing separate vertical menu rows with one native view
/// hosted as a single `NSMenuItem`, directly above the refresh item. Shares
/// the split usage panel's own column geometry.
@MainActor
final class UsagePageButtonsView: NSView {
    private static let viewWidth: CGFloat = UsagePanelLayout.viewWidth
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight

    let codexButton: NSButton
    let claudeButton: NSButton
    let geminiButton: NSButton
    private let dividers: [NSView] = (0..<UsagePanelLayout.columnCount - 1).map { _ in
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    override var isFlipped: Bool { true }

    init() {
        codexButton = Self.makeButton(title: "Codex 사용량 페이지", accessibilityLabel: "Codex 사용량 페이지 열기")
        claudeButton = Self.makeButton(title: "Claude 사용량 페이지", accessibilityLabel: "Claude 사용량 페이지 열기")
        geminiButton = Self.makeButton(title: "Gemini 사용량 페이지", accessibilityLabel: "Gemini 사용량 페이지 열기")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))

        addSubview(codexButton)
        addSubview(claudeButton)
        addSubview(geminiButton)
        codexButton.contentTintColor = UsageBrandColors.codex
        claudeButton.contentTintColor = UsageBrandColors.claude
        geminiButton.contentTintColor = UsageBrandColors.geminiText
        dividers.forEach(addSubview)
        setAccessibilityElement(false)
        layoutButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeButton(title: String, accessibilityLabel: String) -> NSButton {
        let button = RolloverButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11, weight: .regular)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityRole(.button)
        return button
    }

    private func layoutButtons() {
        let inset = UsagePanelLayout.controlVerticalInset
        let buttonHeight = Self.viewHeight - inset * 2
        let y = inset
        let buttons = [codexButton, claudeButton, geminiButton]

        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: UsagePanelLayout.columnX[index], y: y, width: UsagePanelLayout.columnWidth, height: buttonHeight)
        }
        for (index, divider) in dividers.enumerated() {
            divider.frame = NSRect(x: UsagePanelLayout.dividerX(after: index), y: 5, width: 1, height: Self.viewHeight - 10)
        }
    }
}

/// Three aligned countdown buttons. A plain button is intentional: AppKit's
/// nested NSPopUpButton menu works in a regular window but is unreliable while
/// the status menu itself owns mouse tracking. Clicking advances only that
/// provider to its next supported cadence, identically in both presentations.
@MainActor
final class RefreshIntervalControlsView: NSView {
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight

    let codexButton = NSButton(title: "", target: nil, action: nil)
    let claudeButton = NSButton(title: "", target: nil, action: nil)
    let geminiButton = NSButton(title: "", target: nil, action: nil)

    var onCodexChange: ((Int) -> Void)?
    var onClaudeChange: ((Int) -> Void)?
    var onGeminiChange: ((Int) -> Void)?
    private var selectedIntervals = [0, 0, 0]
    private let options = [
        UsageCore.refreshIntervalOptions,
        UsageCore.claudeRefreshIntervalOptions,
        UsageCore.geminiRefreshIntervalOptions
    ]

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: UsagePanelLayout.viewWidth, height: Self.viewHeight))
        configure(codexButton, action: #selector(changeCodex), accessibilityLabel: "Codex 갱신 시간 변경")
        configure(claudeButton, action: #selector(changeClaude), accessibilityLabel: "Claude 갱신 시간 변경")
        configure(geminiButton, action: #selector(changeGemini), accessibilityLabel: "Gemini 갱신 시간 변경")
        [codexButton, claudeButton, geminiButton].forEach {
            $0.alignment = .center
            addSubview($0)
        }
        codexButton.contentTintColor = UsageBrandColors.codex
        claudeButton.contentTintColor = UsageBrandColors.claude
        geminiButton.contentTintColor = UsageBrandColors.geminiText
        layoutControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(codex: Int, claude: Int, gemini: Int) {
        selectedIntervals = [codex, claude, gemini]
        let buttons = [codexButton, claudeButton, geminiButton]
        for index in buttons.indices {
            buttons[index].title = Self.title(selectedIntervals[index])
        }
    }

    /// Updates only the visible selected titles. The underlying menu tags stay
    /// equal to the configured intervals, so each live countdown remains a
    /// clickable cadence editor rather than becoming a new interval value.
    func updateCountdown(codex: Int?, claude: Int?, gemini: Int?) {
        let buttons = [codexButton, claudeButton, geminiButton]
        let remaining = [codex, claude, gemini]
        for index in buttons.indices {
            buttons[index].title = remaining[index].map(Self.countdownTitle) ?? "자동 갱신 끔"
        }
    }

    private func configure(_ button: NSButton, action: Selector, accessibilityLabel: String) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = "클릭하여 다음 갱신 주기로 변경"
    }

    private func layoutControls() {
        let controls = [codexButton, claudeButton, geminiButton]
        let inset = UsagePanelLayout.controlVerticalInset
        for (index, button) in controls.enumerated() {
            button.frame = NSRect(
                x: UsagePanelLayout.columnX[index],
                y: inset,
                width: UsagePanelLayout.columnWidth,
                height: Self.viewHeight - inset * 2
            )
        }
    }

    private static func title(_ seconds: Int) -> String {
        guard seconds > 0 else { return "자동 갱신 끔" }
        return "\(seconds)초 후 갱신"
    }

    private static func countdownTitle(_ seconds: Int) -> String {
        "\(max(0, seconds))초 후 갱신"
    }

    private func nextInterval(for index: Int) -> Int {
        let values = options[index]
        guard let current = values.firstIndex(of: selectedIntervals[index]) else {
            return values.first ?? 0
        }
        return values[(current + 1) % values.count]
    }

    @objc private func changeCodex() { onCodexChange?(nextInterval(for: 0)) }
    @objc private func changeClaude() { onClaudeChange?(nextInterval(for: 1)) }
    @objc private func changeGemini() { onGeminiChange?(nextInterval(for: 2)) }
}

/// A compact action row used by the menu's lower controls. Keeping these
/// actions in shared geometry makes each group scan as one unit.
@MainActor
final class MenuActionRowView: NSView {
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight
    let buttons: [NSButton]
    private let dividers: [NSView]

    var leftButton: NSButton { buttons[0] }
    var rightButton: NSButton { buttons[1] }

    override var isFlipped: Bool { true }

    init(titles: [String]) {
        precondition(titles.count >= 2)
        buttons = titles.map(Self.makeButton(title:))
        dividers = (0..<(titles.count - 1)).map { _ in
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.separatorColor.cgColor
            return view
        }
        super.init(frame: NSRect(x: 0, y: 0, width: UsagePanelLayout.viewWidth, height: Self.viewHeight))
        buttons.forEach(addSubview)
        dividers.forEach(addSubview)
        layoutButtons()
    }

    convenience init(leftTitle: String, rightTitle: String) {
        self.init(titles: [leftTitle, rightTitle])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeButton(title: String) -> NSButton {
        let button = RolloverButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .regular)
        button.contentTintColor = .controlAccentColor
        button.alignment = .center
        return button
    }

    private func layoutButtons() {
        let gap: CGFloat = 6
        let sidePadding = UsagePanelLayout.sidePadding
        let verticalInset = UsagePanelLayout.controlVerticalInset

        if buttons.count == UsagePanelLayout.columnCount {
            for (index, button) in buttons.enumerated() {
                button.frame = NSRect(
                    x: UsagePanelLayout.columnX[index],
                    y: verticalInset,
                    width: UsagePanelLayout.columnWidth,
                    height: Self.viewHeight - verticalInset * 2
                )
            }
            for (index, divider) in dividers.enumerated() {
                divider.frame = NSRect(
                    x: UsagePanelLayout.dividerX(after: index),
                    y: 5,
                    width: 1,
                    height: Self.viewHeight - 10
                )
            }
            return
        }

        let availableWidth = bounds.width - sidePadding * 2
        let width = (availableWidth - (gap * CGFloat(buttons.count - 1))) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: sidePadding + CGFloat(index) * (width + gap),
                y: verticalInset,
                width: width,
                height: Self.viewHeight - verticalInset * 2
            )
        }
        for (index, divider) in dividers.enumerated() {
            divider.frame = NSRect(
                x: sidePadding + width + gap / 2 + CGFloat(index) * (width + gap),
                y: 5,
                width: 1,
                height: Self.viewHeight - 10
            )
        }
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
