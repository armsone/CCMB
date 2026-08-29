import AppKit
import Foundation

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
        let hasQuota = raw.weeklyUsedPercent != nil || raw.fiveHourUsedPercent != nil
        return ClaudeUsageSnapshot(
            quotaSource: hasQuota ? "claude-statusline" : nil,
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
    enum DisplayStyle {
        case ring
        case prominentValue
    }

    let caption: String
    let percentText: String
    /// Remaining fraction (0...1) the ring fills in.
    let fraction: Double
    let color: NSColor
    let accessibilityValue: String
    let displayStyle: DisplayStyle

    init(
        caption: String,
        percentText: String,
        fraction: Double,
        color: NSColor,
        accessibilityValue: String,
        displayStyle: DisplayStyle = .ring
    ) {
        self.caption = caption
        self.percentText = percentText
        self.fraction = fraction
        self.color = color
        self.accessibilityValue = accessibilityValue
        self.displayStyle = displayStyle
    }
}

/// One bucket of work drawn in a column's strip: the ordinary meter, or a
/// worker/model meter (Codex Spark, Claude Fable) measured alongside it.
struct UsageHistorySeries {
    /// Short name used in hover text, e.g. "주간" or "Spark". Empty for a
    /// strip with a single bucket, which keeps its plain amount readout.
    let label: String
    /// Stored oldest-first. Only real readings; short histories are padded at
    /// draw time rather than in the data, and each sample keeps the timestamp
    /// of the refresh it came from so hovering a bar can report it.
    let samples: [UsageConsumptionSample]
    let color: NSColor
}

/// Compact bar strip showing how much the column's metric was consumed at each
/// refresh, drawn directly under the column title.
struct UsageHistoryStrip {
    let caption: String
    /// Buckets stacked into one bar per refresh, ordinary meter first. All
    /// series share `unitSuffix`; a bucket measured in a different unit must
    /// not be stacked here.
    let series: [UsageHistorySeries]
    /// Slots the strip always draws, so the chart keeps a constant width.
    /// Filled from the left with the newest reading first.
    let slotCount: Int
    /// Appended to a hovered bar's value, e.g. " 크레딧" or "%".
    let unitSuffix: String
    let accessibilityValue: String

    init(
        caption: String,
        series: [UsageHistorySeries],
        slotCount: Int,
        unitSuffix: String,
        accessibilityValue: String
    ) {
        self.caption = caption
        self.series = series
        self.slotCount = slotCount
        self.unitSuffix = unitSuffix
        self.accessibilityValue = accessibilityValue
    }

    /// Single-bucket strip, the shape Gemini and Grok still use.
    init(
        caption: String,
        samples: [UsageConsumptionSample],
        slotCount: Int,
        unitSuffix: String,
        color: NSColor,
        accessibilityValue: String
    ) {
        self.init(
            caption: caption,
            series: [UsageHistorySeries(label: "", samples: samples, color: color)],
            slotCount: slotCount,
            unitSuffix: unitSuffix,
            accessibilityValue: accessibilityValue
        )
    }

    /// The ordinary meter's colour, used for the column's identity mark.
    var color: NSColor { series.first?.color ?? .controlAccentColor }
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

    /// Real refreshes only, stored oldest-first, each carrying every bucket
    /// that reported at that refresh. Never padded — padding is a drawing
    /// concern, so the data stays honest about how much was measured.
    /// Drawing reverses the order so the newest reading sits at the left edge.
    var samples: [UsageConsumptionStackedSample] = [] {
        didSet { needsDisplay = true }
    }
    /// One entry per stacked bucket, indexed like `samples[n].amounts`.
    /// Segment `0` (the ordinary meter) sits at the bottom of each bar.
    var seriesLabels: [String] = []
    var seriesColors: [NSColor] = [] {
        didSet { needsDisplay = true }
    }
    /// Appended to the hovered value in the hover readout.
    var unitSuffix: String = ""
    /// Called with the hovered refresh, or `nil` when the pointer leaves the
    /// strip. The owner uses it to swap the caption for a readout.
    var onHover: ((UsageConsumptionStackedSample?) -> Void)?

    private var hoveredSlot: Int?

    private static let hoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// Text shown when a bar is hovered: when the refresh happened and what
    /// each bucket cost. Buckets with no reading at that refresh are omitted.
    static func hoverTitle(
        for sample: UsageConsumptionStackedSample,
        labels: [String],
        unitSuffix: String
    ) -> String {
        let time = hoverTimeFormatter.string(from: sample.at)
        let breakdown = UsageConsumptionCore.breakdownTitle(
            amounts: sample.amounts,
            labels: labels,
            unit: unitSuffix
        )
        return "\(time) · \(breakdown)"
    }

    func hoverTitle(for sample: UsageConsumptionStackedSample) -> String {
        Self.hoverTitle(for: sample, labels: seriesLabels, unitSuffix: unitSuffix)
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

        // Bars scale to the peak combined activity in this strip. The stacked
        // shape keeps every reported bucket visible, but the UI never labels
        // independent quota percentages as one arithmetic total.
        let fractions = UsageConsumptionCore.barFractions(samples.map(\.total))
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
            switch (sampleIndex, fraction) {
            case (.some(let sampleIndex), .some(let value)) where value > 0:
                let height = max(Self.minimumBarHeight, CGFloat(value) * bounds.height)
                let rect = NSRect(x: x, y: baseline - height, width: barWidth, height: height)
                drawStackedBar(samples[sampleIndex], in: rect, radius: radius)
            case (_, .some):
                // Measured, consumed nothing.
                let rect = NSRect(x: x, y: baseline - Self.minimumBarHeight, width: barWidth, height: Self.minimumBarHeight)
                barColor.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            case (_, .none):
                // Not measured yet: an even fainter placeholder so the strip
                // holds its shape without claiming a reading that never happened.
                let rect = NSRect(x: x, y: baseline - Self.minimumBarHeight, width: barWidth, height: Self.minimumBarHeight)
                barColor.withAlphaComponent(0.10).setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }
        }
    }

    /// Fills one bar bottom-up, one segment per bucket that reported, each
    /// sized by its share of the refresh's total. Buckets with no reading
    /// draw nothing. Segments are clipped to the rounded bar outline so a
    /// stacked bar keeps the same silhouette as a plain one.
    private func drawStackedBar(_ sample: UsageConsumptionStackedSample, in rect: NSRect, radius: CGFloat) {
        let total = sample.total
        guard total > 0 else { return }
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        var top = rect.maxY
        for (index, amount) in sample.amounts.enumerated() {
            guard let amount, amount > 0 else { continue }
            let segmentHeight = rect.height * CGFloat(amount / total)
            let color = index < seriesColors.count ? seriesColors[index] : barColor
            color.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: top - segmentHeight, width: rect.width, height: segmentHeight)).fill()
            top -= segmentHeight
        }
        NSGraphicsContext.restoreGraphicsState()
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
        toolTip = sample.map { hoverTitle(for: $0) }
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
    let grok: UsagePanelColumn
}

/// Compact circular progress indicator used for a column's primary quota.
private final class UsageRingView: NSView {
    private static let tickCount = 36
    private static let ornamentInset: CGFloat = 7.5

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
        let clampedFraction = min(max(fraction, 0), 1)
        drawTicks(fraction: clampedFraction)

        // The campaign artwork's ring has a quiet instrument-like face, an
        // illuminated quota arc, and a fine halo of ticks. Keep those layers
        // inside this code-native view so the result remains sharp at every
        // display scale and adapts naturally to light and dark appearances.
        let inset = Self.ornamentInset
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

        let face = NSBezierPath(ovalIn: squareRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        NSColor.controlBackgroundColor.withAlphaComponent(0.16).setFill()
        face.fill()

        let innerRim = NSBezierPath()
        innerRim.appendArc(
            withCenter: center,
            radius: max(0, radius - lineWidth - 2),
            startAngle: 0,
            endAngle: 360
        )
        innerRim.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.08).setStroke()
        innerRim.stroke()

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        trackColor.setStroke()
        track.stroke()

        guard clampedFraction > 0 else { return }
        let progress = NSBezierPath()
        let startAngle: CGFloat = 90
        let endAngle = startAngle - CGFloat(clampedFraction) * 360
        progress.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = 4
        glow.shadowColor = endpointColor(for: clampedFraction).withAlphaComponent(0.42)
        glow.set()
        if let gradientColors, gradientColors.count >= 2 {
            drawGradientProgress(progress, colors: gradientColors, rect: squareRect)
        } else {
            progressColor.setStroke()
            progress.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        let sheen = progress.copy() as! NSBezierPath
        sheen.lineWidth = 1
        NSColor.white.withAlphaComponent(0.34).setStroke()
        sheen.stroke()

        drawEndpoint(center: center, radius: radius, fraction: clampedFraction)
    }

    private func drawTicks(fraction: Double) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let outerRadius = min(bounds.width, bounds.height) / 2 - 0.75
        let innerRadius = outerRadius - 2.25

        for index in 0..<Self.tickCount {
            let tickFraction = Double(index) / Double(Self.tickCount)
            let angle = -.pi / 2 + CGFloat(tickFraction) * 2 * .pi
            let path = NSBezierPath()
            path.lineWidth = index.isMultiple(of: 3) ? 1.05 : 0.75
            path.lineCapStyle = .round
            path.move(to: NSPoint(
                x: center.x + cos(angle) * innerRadius,
                y: center.y + sin(angle) * innerRadius
            ))
            path.line(to: NSPoint(
                x: center.x + cos(angle) * outerRadius,
                y: center.y + sin(angle) * outerRadius
            ))

            if tickFraction <= fraction {
                ringColor(at: tickFraction).withAlphaComponent(0.76).setStroke()
            } else {
                trackColor.withAlphaComponent(0.38).setStroke()
            }
            path.stroke()
        }
    }

    private func drawEndpoint(center: NSPoint, radius: CGFloat, fraction: Double) {
        let angle = -.pi / 2 + CGFloat(fraction) * 2 * .pi
        let point = NSPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
        let color = endpointColor(for: fraction)

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowOffset = .zero
        glow.shadowBlurRadius = 5
        glow.shadowColor = color.withAlphaComponent(0.7)
        glow.set()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.86).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 1.25, y: point.y - 1.25, width: 2.5, height: 2.5)).fill()
    }

    private func endpointColor(for fraction: Double) -> NSColor {
        ringColor(at: max(0, fraction - 0.001))
    }

    private func ringColor(at fraction: Double) -> NSColor {
        guard let gradientColors, !gradientColors.isEmpty else { return progressColor }
        let index = min(
            gradientColors.count - 1,
            Int(fraction * Double(gradientColors.count))
        )
        return gradientColors[index]
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
        case codex, claude, gemini, grok

        init(providerTitle: String) {
            switch providerTitle {
            case "Claude": self = .claude
            case "Gemini": self = .gemini
            case "Grok": self = .grok
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
        case .grok: drawGrokMark()
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

    /// A plain code-native prompt chevron (`>`) plus a trailing cursor bar,
    /// stroked in one restrained neutral ink so it reads as "terminal", not
    /// as a copy of the X social-network mark or as one more colored logo.
    private func drawGrokMark() {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let top = NSPoint(x: 3.5, y: 3.5)
        let mid = NSPoint(x: 8.5, y: bounds.midY)
        let bottom = NSPoint(x: 3.5, y: bounds.maxY - 3.5)
        path.move(to: top)
        path.line(to: mid)
        path.line(to: bottom)

        let cursor = NSBezierPath()
        cursor.lineWidth = 1.5
        cursor.lineCapStyle = .round
        cursor.move(to: NSPoint(x: 9, y: bounds.maxY - 3.5))
        cursor.line(to: NSPoint(x: 13, y: bounds.maxY - 3.5))

        GrokBrandColor.mark.setStroke()
        path.stroke()
        cursor.stroke()
    }
}

/// One column of the panel: a title, an optional primary quota ring, a
/// stack of metric rows, and an aligned account/refresh footer.
private final class UsageColumnView: NSView {
    private static let titleHeight: CGFloat = 16
    private static let titleGap: CGFloat = 6
    private static let quotaDiameter: CGFloat = 54
    private static let quotaLineWidth: CGFloat = 5
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
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
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
            let showsRing = quota.displayStyle == .ring
            ringView.isHidden = !showsRing
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
            ringView.setAccessibilityElement(showsRing)
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
                weight: .regular
            )
            let primaryRingX = (groupWidth - diameter) / 2
            ringView.frame = NSRect(x: primaryRingX, y: y, width: diameter, height: diameter)
            if quota.displayStyle == .prominentValue {
                percentLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
                percentLabel.textColor = quota.color
                percentLabel.frame = NSRect(x: 0, y: y + (diameter - 30) / 2, width: groupWidth, height: 30)
            } else {
                percentLabel.textColor = NSColor.labelColor.withAlphaComponent(0.60)
                percentLabel.frame = NSRect(x: primaryRingX, y: y + (diameter - 16) / 2, width: diameter, height: 16)
            }
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

    /// Leading x of each provider column, left to right.
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
class RolloverButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var restingAttributedTitle: NSAttributedString?
    /// The resting `contentTintColor`, captured once the button lands in a
    /// window. When `hoverTintColor` is set, the button reverts to this
    /// (normally still `nil`, i.e. the system default) once the pointer
    /// leaves, instead of staying stuck on the hover color.
    private var restingTintColor: NSColor?
    /// When set, the button's foreground/bezel stay neutral at rest and only
    /// switch to this color while the pointer is over the button — used by
    /// controls that should read as quiet until rollover names their brand.
    /// `nil` preserves the earlier bezel-only rollover, which leaves
    /// `contentTintColor` exactly as the caller configured it.
    var hoverTintColor: NSColor?

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
        restingTintColor = contentTintColor
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        let tint = hoverTintColor ?? contentTintColor ?? .controlAccentColor
        alphaValue = 1
        contentTintColor = tint
        bezelColor = tint.withAlphaComponent(0.18)
        if hoverTintColor != nil {
            restingAttributedTitle = attributedTitle.copy() as? NSAttributedString
            let coloredTitle = NSMutableAttributedString(attributedString: attributedTitle)
            if coloredTitle.length == 0, !title.isEmpty {
                coloredTitle.append(NSAttributedString(
                    string: title,
                    attributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]
                ))
            }
            coloredTitle.addAttribute(
                .foregroundColor,
                value: tint,
                range: NSRange(location: 0, length: coloredTitle.length)
            )
            attributedTitle = coloredTitle
        }
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = 0.50
        contentTintColor = restingTintColor
        bezelColor = nil
        if let restingAttributedTitle {
            attributedTitle = restingAttributedTitle
            self.restingAttributedTitle = nil
        }
    }
}

/// Background-only translucent surface shared by the popup and pinned usage
/// panels. Content always lives in sibling views layered on top rather than
/// as subviews of this one, so fading its `alphaValue` never touches text,
/// charts, or buttons — only the material behind them.
@MainActor
final class PanelBackgroundView: NSVisualEffectView {
    init(blendingMode: NSVisualEffectView.BlendingMode) {
        super.init(frame: .zero)
        material = .popover
        self.blendingMode = blendingMode
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOpacity(_ opacity: Double) {
        alphaValue = CGFloat(UsageCore.normalizedPanelOpacity(opacity))
    }
}

/// Three-column status panel — Codex, Claude, then Gemini — hosted as
/// the `view` of a single NSMenuItem. Grok data is still collected in
/// `UsagePanelModel.grok` but is not rendered while its column is hidden.
@MainActor
final class SplitUsagePanelView: NSView {
    private let columnWidth = UsagePanelLayout.columnWidth
    private let topPadding: CGFloat = 8
    private let bottomPadding: CGFloat = 8

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
    // the visible strips must sit exactly under their provider columns
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
    private let grokCaption = UsageHistoryChartView.makeCaption()
    private let codexBars = UsageHistoryBarView()
    private let claudeBars = UsageHistoryBarView()
    private let geminiBars = UsageHistoryBarView()
    private let grokBars = UsageHistoryBarView()
    /// The caption each column falls back to once the pointer leaves its strip.
    private var codexBaseCaption = ""
    private var claudeBaseCaption = ""
    private var geminiBaseCaption = ""
    private var grokBaseCaption = ""

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        addSubview(codexCaption)
        addSubview(codexBars)
        addSubview(claudeCaption)
        addSubview(claudeBars)
        addSubview(geminiCaption)
        addSubview(geminiBars)
        addSubview(grokCaption)
        addSubview(grokBars)
        setAccessibilityElement(false)

        codexBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.codexCaption.stringValue = sample.map { self.codexBars.hoverTitle(for: $0) } ?? self.codexBaseCaption
        }
        claudeBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.claudeCaption.stringValue = sample.map { self.claudeBars.hoverTitle(for: $0) } ?? self.claudeBaseCaption
        }
        geminiBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.geminiCaption.stringValue = sample.map { self.geminiBars.hoverTitle(for: $0) } ?? self.geminiBaseCaption
        }
        grokBars.onHover = { [weak self] sample in
            guard let self else { return }
            self.grokCaption.stringValue = sample.map { self.grokBars.hoverTitle(for: $0) } ?? self.grokBaseCaption
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
        // A column stacking more than one bucket (Codex + Spark, Claude +
        // Fable) shows those colours side by side as a legend, the same way
        // Gemini's four brand colors are drawn instead of one dot.
        drawSeriesMark(for: codexBars, x: UsagePanelLayout.columnX[0] + Self.columnContentInset, visible: !codexCaption.isHidden)
        drawSeriesMark(for: claudeBars, x: UsagePanelLayout.columnX[1] + Self.columnContentInset, visible: !claudeCaption.isHidden)
        drawGradientMark(colors: UsageBrandColors.geminiGradient, x: UsagePanelLayout.columnX[2] + Self.columnContentInset, visible: !geminiCaption.isHidden)
    }

    private func drawSeriesMark(for bars: UsageHistoryBarView, x: CGFloat, visible: Bool) {
        if bars.seriesColors.count > 1 {
            drawGradientMark(colors: bars.seriesColors, x: x, visible: visible)
        } else {
            drawDot(color: bars.barColor, x: x, visible: visible)
        }
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
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.truncatesLastVisibleLine = false
        return field
    }

    /// Returns false when no column has anything to draw, so the caller can
    /// hide the whole row instead of leaving an empty band in the menu.
    @discardableResult
    func apply(
        codex: UsageHistoryStrip?,
        claude: UsageHistoryStrip?,
        gemini: UsageHistoryStrip?,
        grok: UsageHistoryStrip?
    ) -> Bool {
        codexBaseCaption = codex?.caption ?? ""
        claudeBaseCaption = claude?.caption ?? ""
        geminiBaseCaption = gemini?.caption ?? ""
        grokBaseCaption = grok?.caption ?? ""
        let codexShown = configure(codex, caption: codexCaption, bars: codexBars, x: UsagePanelLayout.columnX[0] + Self.columnContentInset)
        let claudeShown = configure(claude, caption: claudeCaption, bars: claudeBars, x: UsagePanelLayout.columnX[1] + Self.columnContentInset)
        let geminiShown = configure(gemini, caption: geminiCaption, bars: geminiBars, x: UsagePanelLayout.columnX[2] + Self.columnContentInset)
        // Grok samples keep arriving, but the strip stays hidden while the
        // provider has no visible column of its own.
        _ = configure(nil, caption: grokCaption, bars: grokBars, x: 0)
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
        bars.seriesLabels = strip.series.map(\.label)
        bars.seriesColors = strip.series.map(\.color)
        bars.samples = UsageConsumptionCore.stackedSamples(
            strip.series.map(\.samples),
            capacity: strip.slotCount
        )
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
    // The persistent panel mirrors the status menu's own dashboard stack —
    // usage panel, refresh countdown controls, history chart, usage-page
    // buttons, then the same lower settings rows — edge to edge horizontally,
    // with a small balanced top/bottom margin since this stack is no longer
    // sitting inside an `NSMenu`'s own inset.
    private static let horizontalPadding: CGFloat = 0
    private static let topPadding: CGFloat = 8
    private static let bottomPadding: CGFloat = 8
    private static let sectionGap: CGFloat = 0
    private static let defaultContentScale: CGFloat = 0.80
    private static let minimumContentScale: CGFloat = 0.40
    private static let maximumContentScale: CGFloat = 1.00
    private static let contentScaleDefaultsKey = "pinnedUsagePanelContentScale"

    private let usageView = SplitUsagePanelView()
    private let historyView = UsageHistoryChartView()
    private let usagePageButtonsView = UsagePageButtonsView()
    private let refreshIntervalControlsView = RefreshIntervalControlsView()
    private let shareActionsView = SingleActionRowView(title: "사용량 공유")
    private let updateVersionView = VersionOpacityRowView(
        alwaysTitle: "✓ 항상 보기",
        updateTitle: "업데이트 확인…",
        versionTitle: ""
    )
    private let lifecycleActionsView = LifecycleActionsRowView()
    private let containerView = PanelBackgroundView(blendingMode: .behindWindow)
    /// Holds every content view, layered on top of `containerView`, so fading
    /// the background never fades what's drawn on top of it.
    private let contentContainer = NSView()
    private var hasPositionedWindow = false
    /// Children use the panel's fixed natural coordinate system. Resizing the
    /// container's frame while preserving these bounds scales the complete UI
    /// (drawing, hit testing and tracking areas) instead of growing empty space.
    private var naturalContentSize = NSSize(
        width: UsagePanelLayout.viewWidth,
        height: 300
    )
    private var contentScale: CGFloat
    private var isApplyingWindowSize = false
    /// When true, this controller is the status-item's own transient
    /// dropdown replacement rather than the persistent "항상 보기" panel: it
    /// dismisses itself on an outside click or Escape, the same way an
    /// `NSMenu` ends its tracking session, instead of staying open until the
    /// user explicitly closes it.
    private let isTransient: Bool
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    /// The status-item button that opens this transient dropdown, so a click
    /// back on that same button toggles the dropdown closed through
    /// `AppDelegate`'s own action instead of the dismiss monitor closing it
    /// first and `AppDelegate` immediately reopening it.
    var dismissalExcludedView: NSView?

    var onClose: (() -> Void)?
    var onCodexRefreshIntervalChange: ((Int) -> Void)?
    var onClaudeRefreshIntervalChange: ((Int) -> Void)?
    var onGeminiRefreshIntervalChange: ((Int) -> Void)?
    var onGrokRefreshIntervalChange: ((Int) -> Void)?
    var onGrokUsageAction: (() -> Void)?
    var onClaudeUsageAction: (() -> Void)?
    /// Same lower-control actions as the status menu, performed through
    /// callbacks into `AppDelegate` rather than duplicating any business
    /// logic here. "항상 보기" needs no callback of its own when this panel
    /// itself *is* the persistent panel — closing this window already unpins
    /// it via `onClose`. The transient dropdown instead uses
    /// `onToggleAlwaysView` to hand off to that persistent panel.
    var onOpacityChange: ((Double) -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenDiagnosticLog: (() -> Void)?
    var onOpenGitHub: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onRestart: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Only invoked when `isTransient` is true, from the "항상 보기" row.
    var onToggleAlwaysView: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }

    static func normalizedContentScale(_ proposedScale: CGFloat) -> CGFloat {
        min(max(proposedScale, minimumContentScale), maximumContentScale)
    }

    init(transient: Bool = false) {
        self.isTransient = transient
        if transient {
            contentScale = 1
        } else if let storedScale = UserDefaults.standard.object(
            forKey: Self.contentScaleDefaultsKey
        ) as? Double {
            contentScale = Self.normalizedContentScale(CGFloat(storedScale))
        } else {
            contentScale = Self.defaultContentScale
        }
        let width = UsagePanelLayout.viewWidth + Self.horizontalPadding * 2
        let styleMask: NSWindow.StyleMask = transient
            ? [.borderless, .nonactivatingPanel]
            : [.borderless, .nonactivatingPanel, .resizable]
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true

        let rootView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        containerView.frame = rootView.bounds
        containerView.autoresizingMask = [.width, .height]
        contentContainer.frame = rootView.bounds
        contentContainer.autoresizingMask = [.width, .height]
        rootView.addSubview(containerView)
        rootView.addSubview(contentContainer)
        panel.contentView = rootView

        super.init(window: panel)
        panel.delegate = self
        contentContainer.addSubview(usageView)
        contentContainer.addSubview(refreshIntervalControlsView)
        contentContainer.addSubview(historyView)
        contentContainer.addSubview(usagePageButtonsView)
        contentContainer.addSubview(shareActionsView)
        contentContainer.addSubview(updateVersionView)
        contentContainer.addSubview(lifecycleActionsView)

        usagePageButtonsView.codexButton.target = self
        usagePageButtonsView.codexButton.action = #selector(openCodexUsagePage)
        usagePageButtonsView.claudeButton.target = self
        usagePageButtonsView.claudeButton.action = #selector(openClaudeUsagePage)
        usagePageButtonsView.geminiButton.target = self
        usagePageButtonsView.geminiButton.action = #selector(openGeminiUsagePage)
        usagePageButtonsView.grokButton.target = self
        usagePageButtonsView.grokButton.action = #selector(openGrokUsagePage)

        refreshIntervalControlsView.onCodexChange = { [weak self] in self?.onCodexRefreshIntervalChange?($0) }
        refreshIntervalControlsView.onClaudeChange = { [weak self] in self?.onClaudeRefreshIntervalChange?($0) }
        refreshIntervalControlsView.onGeminiChange = { [weak self] in self?.onGeminiRefreshIntervalChange?($0) }
        refreshIntervalControlsView.onGrokChange = { [weak self] in self?.onGrokRefreshIntervalChange?($0) }

        updateVersionView.updateButton.target = self
        updateVersionView.updateButton.action = #selector(triggerCheckForUpdates)
        updateVersionView.opacitySlider.target = self
        updateVersionView.opacitySlider.action = #selector(changeOpacity(_:))

        // The persistent pinned panel only exists while it is visible, so
        // "항상 보기" is always shown checked there; closing this window is
        // itself the unpin action. The transient dropdown instead hands off
        // to that persistent panel and closes itself.
        updateVersionView.alwaysViewButton.target = self
        updateVersionView.alwaysViewButton.action = isTransient
            ? #selector(toggleAlwaysViewTapped)
            : #selector(closeWindow)
        lifecycleActionsView.launchButton.target = self
        lifecycleActionsView.launchButton.action = #selector(triggerToggleLaunchAtLogin)
        lifecycleActionsView.diagnosticButton.target = self
        lifecycleActionsView.diagnosticButton.action = #selector(triggerOpenDiagnosticLog)
        lifecycleActionsView.githubButton.target = self
        lifecycleActionsView.githubButton.action = #selector(triggerOpenGitHub)
        lifecycleActionsView.restartButton.target = self
        lifecycleActionsView.restartButton.action = #selector(triggerRestart)
        lifecycleActionsView.quitButton.target = self
        lifecycleActionsView.quitButton.action = #selector(triggerQuit)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        model: UsagePanelModel,
        codexHistory: UsageHistoryStrip?,
        claudeHistory: UsageHistoryStrip?,
        geminiHistory: UsageHistoryStrip?,
        grokHistory: UsageHistoryStrip?,
        codexRefreshInterval: Int,
        claudeRefreshInterval: Int,
        geminiRefreshInterval: Int,
        grokRefreshInterval: Int
    ) {
        usageView.apply(model)
        let showsHistory = historyView.apply(
            codex: codexHistory,
            claude: claudeHistory,
            gemini: geminiHistory,
            grok: grokHistory
        )
        historyView.isHidden = !showsHistory
        refreshIntervalControlsView.apply(
            codex: codexRefreshInterval,
            claude: claudeRefreshInterval,
            gemini: geminiRefreshInterval,
            grok: grokRefreshInterval
        )

        let historyHeight = showsHistory ? historyView.frame.height : 0
        let historyGap = showsHistory ? Self.sectionGap : 0
        let buttonsHeight = usagePageButtonsView.frame.height
        let shareHeight = shareActionsView.frame.height
        let controlsHeight = refreshIntervalControlsView.frame.height
        let versionHeight = updateVersionView.frame.height
        let lifecycleHeight = lifecycleActionsView.frame.height
        let contentHeight = Self.topPadding + Self.bottomPadding
            + usageView.frame.height
            + Self.sectionGap + controlsHeight
            + historyGap + historyHeight
            + Self.sectionGap + buttonsHeight
            + Self.sectionGap + shareHeight
            + Self.sectionGap + versionHeight
            + Self.sectionGap + lifecycleHeight
        let contentWidth = UsagePanelLayout.viewWidth + Self.horizontalPadding * 2

        // Stacked bottom-up so the top-down reading order matches the status
        // menu exactly: usage panel, refresh controls, history, usage-page
        // buttons, primary settings, lifecycle/support actions.
        var y = Self.bottomPadding
        lifecycleActionsView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)
        y += lifecycleHeight + Self.sectionGap
        updateVersionView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)
        y += versionHeight + Self.sectionGap
        shareActionsView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)
        y += shareHeight + Self.sectionGap
        usagePageButtonsView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)
        y += buttonsHeight + Self.sectionGap
        historyView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)
        y += historyHeight + historyGap
        refreshIntervalControlsView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)
        y += controlsHeight + Self.sectionGap
        usageView.frame.origin = NSPoint(x: Self.horizontalPadding, y: y)

        if let window {
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            naturalContentSize = NSSize(width: contentWidth, height: contentHeight)
            let scale = isTransient ? 1 : contentScale
            window.aspectRatio = naturalContentSize
            window.contentMinSize = scaledContentSize(scale: isTransient ? 1 : Self.minimumContentScale)
            window.contentMaxSize = scaledContentSize(scale: isTransient ? 1 : Self.maximumContentScale)
            isApplyingWindowSize = true
            window.setContentSize(scaledContentSize(scale: scale))
            isApplyingWindowSize = false
            updateScaledContentLayout()
            if hasPositionedWindow {
                window.setFrameTopLeftPoint(topLeft)
            }
        }
    }

    /// Syncs the parts of the lower controls that are not covered by `apply`
    /// (dashboard content) but still need to mirror `AppDelegate`'s own
    /// state: the version string and the "자동 실행" checkmark.
    func applyLowerControlsState(
        versionText: String,
        launchAtLoginEnabled: Bool,
        alwaysViewEnabled: Bool,
        grokLoginRequired: Bool = false,
        grokLoginInProgress: Bool = false
    ) {
        updateVersionView.setVersionText(versionText)
        updateVersionView.alwaysViewButton.title = (isTransient ? alwaysViewEnabled : true)
            ? "✓ 항상 보기"
            : "항상 보기"
        lifecycleActionsView.launchButton.title = launchAtLoginEnabled ? "✓ 자동 실행" : "자동 실행"
        usagePageButtonsView.applyGrokAuthState(
            loginRequired: grokLoginRequired,
            loginInProgress: grokLoginInProgress
        )
    }

    func show() {
        if !hasPositionedWindow {
            window?.center()
            hasPositionedWindow = true
        }
        showWindow(nil)
        window?.orderFrontRegardless()
        if isTransient {
            installDismissMonitors()
        }
    }

    /// Sets this window's top-left corner directly, the same anchor point
    /// `NSMenu.popUp` used to take, and marks the window as already
    /// positioned so a later `apply(...)` height change keeps this corner
    /// fixed instead of re-centering. Used by the transient status-item
    /// dropdown, which must reopen at the status button every time rather
    /// than remembering a dragged position the way the pinned panel does.
    func positionTopLeft(_ point: NSPoint) {
        window?.setFrameTopLeftPoint(point)
        hasPositionedWindow = true
    }

    func updateRefreshCountdown(codex: Int?, claude: Int?, gemini: Int?, grok: Int?) {
        refreshIntervalControlsView.updateCountdown(codex: codex, claude: claude, gemini: gemini, grok: grok)
    }

    func setShareMenu(_ menu: NSMenu) {
        shareActionsView.setMenu(menu)
    }

    /// Fades only `containerView`'s material background, so every row reads
    /// at the same background opacity the user picked while every label,
    /// chart, and button stays fully opaque. Also keeps this window's own
    /// slider in sync when the opacity was changed from the other panel
    /// instead (status dropdown vs. pinned "항상 보기").
    func setOpacity(_ opacity: Double) {
        containerView.setOpacity(opacity)
        updateVersionView.setOpacity(opacity)
    }

    func windowWillClose(_ notification: Notification) {
        removeDismissMonitors()
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isTransient, !isApplyingWindowSize,
              let contentView = window?.contentView,
              naturalContentSize.width > 0 else { return }
        contentScale = Self.normalizedContentScale(
            contentView.bounds.width / naturalContentSize.width
        )
        updateScaledContentLayout()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isTransient else { return }
        UserDefaults.standard.set(Double(contentScale), forKey: Self.contentScaleDefaultsKey)
    }

    private func scaledContentSize(scale: CGFloat) -> NSSize {
        NSSize(
            width: naturalContentSize.width * scale,
            height: naturalContentSize.height * scale
        )
    }

    private func updateScaledContentLayout() {
        guard let rootView = window?.contentView else { return }
        containerView.frame = rootView.bounds
        contentContainer.frame = rootView.bounds
        contentContainer.bounds = NSRect(origin: .zero, size: naturalContentSize)
    }

    /// Ends the transient dropdown's tracking session the same way an
    /// `NSMenu` does: any mouse click outside its own window, or Escape,
    /// closes it. Installed only while visible and torn down on close, so a
    /// stray monitor never outlives this window.
    private func installDismissMonitors() {
        guard outsideClickMonitor == nil else { return }
        // AppKit always invokes event monitor handlers on the main thread,
        // but their closure types aren't `@MainActor`-annotated, so accessing
        // this `@MainActor` controller's own state inside them needs
        // `assumeIsolated` rather than an `async` hop — the hop would make it
        // impossible to synchronously decide the handler's `NSEvent?` result.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window !== window else { return }
                if let excludedView = self.dismissalExcludedView, let excludedWindow = excludedView.window,
                   event.window === excludedWindow {
                    let locationInView = excludedView.convert(event.locationInWindow, from: nil)
                    if excludedView.bounds.contains(locationInView) { return }
                }
                self.close()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* Escape */ else { return event }
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func removeDismissMonitors() {
        [outsideClickMonitor, localClickMonitor, keyMonitor].forEach { monitor in
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        outsideClickMonitor = nil
        localClickMonitor = nil
        keyMonitor = nil
    }

    @objc private func openCodexUsagePage() {
        NSWorkspace.shared.open(UsageDashboardURLs.codex)
    }

    @objc private func openClaudeUsagePage() {
        if let onClaudeUsageAction {
            onClaudeUsageAction()
        } else {
            NSWorkspace.shared.open(UsageDashboardURLs.claude)
        }
    }

    @objc private func openGeminiUsagePage() {
        NSWorkspace.shared.open(UsageDashboardURLs.gemini)
    }

    @objc private func openGrokUsagePage() {
        if let onGrokUsageAction {
            onGrokUsageAction()
        } else {
            NSWorkspace.shared.open(UsageDashboardURLs.grok)
        }
    }

    @objc private func closeWindow() {
        close()
    }

    /// Only wired up when `isTransient`: hands off to the persistent "항상
    /// 보기" panel and closes this dropdown, mirroring how selecting any
    /// item in the old `NSMenu`-based dropdown ended its tracking session.
    @objc private func toggleAlwaysViewTapped() {
        onToggleAlwaysView?()
        close()
    }

    @objc private func triggerCheckForUpdates() {
        onCheckForUpdates?()
    }

    @objc private func triggerOpenDiagnosticLog() {
        onOpenDiagnosticLog?()
    }

    @objc private func triggerOpenGitHub() {
        onOpenGitHub?()
    }

    @objc private func triggerToggleLaunchAtLogin() {
        onToggleLaunchAtLogin?()
    }

    @objc private func triggerRestart() {
        onRestart?()
    }

    @objc private func triggerQuit() {
        onQuit?()
    }

    @objc private func changeOpacity(_ sender: NSSlider) {
        onOpacityChange?(sender.doubleValue)
    }
}

/// One full-width lower action row used where the status menu presents a
/// native submenu item. The pinned panel uses the same label and opens that
/// very same submenu through an AppDelegate callback.
@MainActor
final class SingleActionRowView: NSView {
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight
    private let title: String
    let button: NSPopUpButton

    override var isFlipped: Bool { true }

    init(title: String) {
        self.title = title
        button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.addItem(withTitle: title)
        super.init(frame: NSRect(x: 0, y: 0, width: UsagePanelLayout.viewWidth, height: Self.viewHeight))
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .regular)
        button.alignment = .left
        button.setAccessibilityLabel("사용량 공유")
        addSubview(button)
        let inset = UsagePanelLayout.controlVerticalInset
        button.frame = NSRect(
            x: UsagePanelLayout.columnX[0],
            y: inset,
            width: UsagePanelLayout.viewWidth - UsagePanelLayout.columnX[0] * 2,
            height: Self.viewHeight - inset * 2
        )
    }

    func setMenu(_ menu: NSMenu) {
        // In pull-down mode AppKit uses the first item as the control's
        // persistent title and handles menu tracking itself. This avoids
        // trying to start a second manual tracking loop from an NSButton
        // action inside a nonactivating panel.
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.insertItem(titleItem, at: 0)
        button.menu = menu
        button.selectItem(at: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum UsageDashboardURLs {
    static let codex = URL(string: "https://chatgpt.com/codex/settings/usage")!
    static let claude = URL(string: "https://claude.ai/settings/usage")!
    static let gemini = URL(string: "https://gemini.google.com/usage")!
    static let grok = URL(string: "https://grok.com/?_s=billing")!
}

/// Compact three-button row linking to each provider's usage page
/// web pages, replacing separate vertical menu rows with one native view
/// hosted as a single `NSMenuItem`, directly above the refresh item. Shares
/// the split usage panel's own column geometry.
@MainActor
final class UsagePageButtonsView: NSView {
    private static let viewWidth: CGFloat = UsagePanelLayout.viewWidth
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight

    let codexButton: RolloverButton
    let claudeButton: RolloverButton
    let geminiButton: RolloverButton
    let grokButton: RolloverButton
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
        grokButton = Self.makeButton(title: "Grok 사용량 페이지", accessibilityLabel: "Grok 사용량 페이지 열기")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))

        addSubview(codexButton)
        addSubview(claudeButton)
        addSubview(geminiButton)
        // The Grok button stays configured (auth states included) but out of
        // the visible row while its column is hidden.
        // Quiet/neutral at rest; each button only takes on its provider's
        // brand color while the pointer is over it.
        codexButton.hoverTintColor = UsageBrandColors.codex
        claudeButton.hoverTintColor = UsageBrandColors.claude
        geminiButton.hoverTintColor = UsageBrandColors.geminiText
        grokButton.hoverTintColor = GrokBrandColor.mark
        dividers.forEach(addSubview)
        setAccessibilityElement(false)
        layoutButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyGrokAuthState(loginRequired: Bool, loginInProgress: Bool) {
        if loginInProgress {
            grokButton.title = "Grok 인증 중…"
            grokButton.setAccessibilityLabel("Grok 인증 진행 중")
            grokButton.isEnabled = false
        } else if loginRequired {
            grokButton.title = "Grok 로그인"
            grokButton.setAccessibilityLabel("브라우저에서 Grok 로그인")
            grokButton.isEnabled = true
        } else {
            grokButton.title = "Grok 사용량 페이지"
            grokButton.setAccessibilityLabel("Grok 사용량 페이지 열기")
            grokButton.isEnabled = true
        }
    }

    private static func makeButton(title: String, accessibilityLabel: String) -> RolloverButton {
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

/// Compact control button that shows a provider's live refresh countdown
/// while closed and, on click, an explicit `NSMenu` listing every supported
/// interval with the configured one checkmarked.
///
/// `NSPopUpButton` hosted inside a custom `NSMenuItem` view does not reliably
/// open once the surrounding status-item `NSMenu` starts tracking, so this
/// button builds and pops up its own top-level menu instead. When hosted
/// inside a menu, the enclosing menu's tracking is cancelled first and the
/// interval menu is shown on the next run-loop turn, using a screen-space
/// origin captured before that menu's window goes away — the same mechanism
/// therefore also works unchanged for the pinned panel's ordinary window.
@MainActor
private final class IntervalControlButton: RolloverButton {
    var options: [Int] = []
    var selectedSeconds: Int = 0
    var providerLabel: String = ""
    var onSelect: ((Int) -> Void)?

    /// Updates the closed-state title/tooltip/accessibility value with the
    /// live countdown, or an explicit "off" state when disabled.
    func updateDisplay(remainingSeconds: Int?) {
        let status = remainingSeconds.map { "\(Self.durationTitle($0)) 후" } ?? "끔"
        title = "\(providerLabel) · \(status)"
        toolTip = "\(status) · 클릭해 갱신 시간 목록 열기"
        setAccessibilityValue(status)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let frameInWindow = convert(bounds, to: nil)
        let screenOrigin = window.convertToScreen(frameInWindow).origin
        let hostMenu = enclosingMenuItem?.menu
        hostMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.presentIntervalMenu(at: screenOrigin)
        }
    }

    private func presentIntervalMenu(at screenOrigin: NSPoint) {
        let menu = NSMenu()
        for seconds in options {
            let item = NSMenuItem(
                title: seconds == UsageCore.smartRefreshPreference
                    ? "스마트 (1→3→5→10분)"
                    : (seconds == 0 ? "끔" : Self.durationTitle(seconds)),
                action: #selector(selectInterval(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = seconds
            item.state = seconds == selectedSeconds ? .on : .off
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: screenOrigin, in: nil)
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        selectedSeconds = seconds
        onSelect?(seconds)
    }

    static func durationTitle(_ seconds: Int) -> String {
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes)분"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)분" : "\(minutes)분 \(remainder)초"
        }
        return "\(max(0, seconds))초"
    }
}

/// Three aligned refresh-cadence controls shared by the status menu and the
/// persistent panel. Each exposes every supported value in an explicit list
/// instead of making the user cycle through them one click at a time, and
/// shows a live per-second countdown while closed.
@MainActor
final class RefreshIntervalControlsView: NSView {
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight

    private let codexButton = IntervalControlButton()
    private let claudeButton = IntervalControlButton()
    private let geminiButton = IntervalControlButton()
    private let grokButton = IntervalControlButton()

    var onCodexChange: ((Int) -> Void)?
    var onClaudeChange: ((Int) -> Void)?
    var onGeminiChange: ((Int) -> Void)?
    var onGrokChange: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: UsagePanelLayout.viewWidth, height: Self.viewHeight))
        let controls = [codexButton, claudeButton, geminiButton, grokButton]
        let optionSets = [
            UsageCore.refreshIntervalOptions,
            UsageCore.claudeRefreshIntervalOptions,
            UsageCore.geminiRefreshIntervalOptions,
            UsageCore.grokRefreshIntervalOptions
        ]
        let labels = ["Codex", "Claude", "Gemini", "Grok"]
        let accessibilityLabels = ["Codex 갱신 시간", "Claude 갱신 시간", "Gemini 갱신 시간", "Grok 갱신 시간"]
        let callbacks: [(Int) -> Void] = [
            { [weak self] in self?.onCodexChange?($0) },
            { [weak self] in self?.onClaudeChange?($0) },
            { [weak self] in self?.onGeminiChange?($0) },
            { [weak self] in self?.onGrokChange?($0) }
        ]
        for index in controls.indices {
            configure(
                controls[index],
                options: optionSets[index],
                providerLabel: labels[index],
                accessibilityLabel: accessibilityLabels[index],
                onSelect: callbacks[index]
            )
        }
        // The Grok control stays configured but out of the visible row while
        // its column is hidden.
        [codexButton, claudeButton, geminiButton].forEach { addSubview($0) }
        codexButton.contentTintColor = UsageBrandColors.codex
        claudeButton.contentTintColor = UsageBrandColors.claude
        geminiButton.contentTintColor = UsageBrandColors.geminiText
        grokButton.contentTintColor = GrokBrandColor.mark
        layoutControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(codex: Int, claude: Int, gemini: Int, grok: Int) {
        codexButton.selectedSeconds = codex
        claudeButton.selectedSeconds = claude
        geminiButton.selectedSeconds = gemini
        grokButton.selectedSeconds = grok
    }

    /// Drives the live per-second countdown shown on each closed button.
    func updateCountdown(codex: Int?, claude: Int?, gemini: Int?, grok: Int?) {
        codexButton.updateDisplay(remainingSeconds: codex)
        claudeButton.updateDisplay(remainingSeconds: claude)
        geminiButton.updateDisplay(remainingSeconds: gemini)
        grokButton.updateDisplay(remainingSeconds: grok)
    }

    private func configure(
        _ control: IntervalControlButton,
        options: [Int],
        providerLabel: String,
        accessibilityLabel: String,
        onSelect: @escaping (Int) -> Void
    ) {
        control.options = options
        control.providerLabel = providerLabel
        control.onSelect = onSelect
        control.bezelStyle = .rounded
        control.controlSize = .small
        control.font = .systemFont(ofSize: 11, weight: .regular)
        control.alignment = .center
        control.setAccessibilityLabel(accessibilityLabel)
        control.updateDisplay(remainingSeconds: nil)
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

        if buttons.count <= UsagePanelLayout.columnCount {
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

/// Three-column lifecycle row. The second and third provider-width cells are
/// each split evenly between their closely related actions — support
/// destinations, then restart/quit — keeping the outer grid aligned with
/// every row above it.
@MainActor
final class LifecycleActionsRowView: NSView {
    private static let viewHeight: CGFloat = UsagePanelLayout.controlRowHeight
    private static let innerGap: CGFloat = 2

    let launchButton = LifecycleActionsRowView.makeButton(title: "자동 실행")
    let diagnosticButton = LifecycleActionsRowView.makeButton(title: "진단")
    let githubButton = LifecycleActionsRowView.makeButton(title: "GitHub")
    let restartButton = LifecycleActionsRowView.makeButton(title: "다시 시작")
    let quitButton = LifecycleActionsRowView.makeButton(title: "종료")
    private let columnDividers: [NSView] = (0..<UsagePanelLayout.columnCount - 1).map { _ in
        LifecycleActionsRowView.makeDivider()
    }
    private let supportDivider = LifecycleActionsRowView.makeDivider()
    private let lifecycleDivider = LifecycleActionsRowView.makeDivider()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: UsagePanelLayout.viewWidth,
            height: Self.viewHeight
        ))
        [launchButton, diagnosticButton, githubButton, restartButton, quitButton].forEach(addSubview)
        columnDividers.forEach(addSubview)
        addSubview(supportDivider)
        addSubview(lifecycleDivider)
        layoutButtons()
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

    private static func makeDivider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.separatorColor.cgColor
        return view
    }

    private func layoutButtons() {
        let inset = UsagePanelLayout.controlVerticalInset
        let buttonHeight = Self.viewHeight - inset * 2
        let columnWidth = UsagePanelLayout.columnWidth
        launchButton.frame = NSRect(x: UsagePanelLayout.columnX[0], y: inset, width: columnWidth, height: buttonHeight)

        let supportX = UsagePanelLayout.columnX[1]
        let halfWidth = (columnWidth - Self.innerGap) / 2
        diagnosticButton.frame = NSRect(x: supportX, y: inset, width: halfWidth, height: buttonHeight)
        githubButton.frame = NSRect(
            x: supportX + halfWidth + Self.innerGap,
            y: inset,
            width: halfWidth,
            height: buttonHeight
        )
        let lifecycleX = UsagePanelLayout.columnX[2]
        restartButton.frame = NSRect(x: lifecycleX, y: inset, width: halfWidth, height: buttonHeight)
        quitButton.frame = NSRect(
            x: lifecycleX + halfWidth + Self.innerGap,
            y: inset,
            width: halfWidth,
            height: buttonHeight
        )

        for (index, divider) in columnDividers.enumerated() {
            divider.frame = NSRect(
                x: UsagePanelLayout.dividerX(after: index),
                y: 5,
                width: 1,
                height: Self.viewHeight - 10
            )
        }
        supportDivider.frame = NSRect(
            x: supportX + columnWidth / 2,
            y: 7,
            width: 1,
            height: Self.viewHeight - 14
        )
        lifecycleDivider.frame = NSRect(
            x: lifecycleX + columnWidth / 2,
            y: 7,
            width: 1,
            height: Self.viewHeight - 14
        )
    }
}

/// Three-column settings row: always-on-top, combined update/version, opacity.
@MainActor
final class VersionOpacityRowView: NSView {
    private static let viewHeight: CGFloat = 48
    private static let cellInset: CGFloat = UsagePanelLayout.controlVerticalInset

    let alwaysViewButton: NSButton
    /// One clickable control carrying both the update action and the current
    /// version text, via `setVersionText(_:)`.
    let updateButton: NSButton
    let opacitySlider: NSSlider
    private let updateTitle: String
    private let opacityLabel = NSTextField(labelWithString: "투명도")
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let dividers: [NSView]

    override var isFlipped: Bool { true }

    init(alwaysTitle: String, updateTitle: String, versionTitle: String) {
        self.updateTitle = updateTitle
        alwaysViewButton = Self.makeButton(title: alwaysTitle)
        updateButton = Self.makeButton(title: updateTitle)
        opacitySlider = NSSlider(
            value: 1,
            minValue: UsageCore.minimumPanelOpacity,
            maxValue: 1,
            target: nil,
            action: nil
        )
        dividers = (0..<UsagePanelLayout.columnCount - 1).map { _ in
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.separatorColor.cgColor
            return view
        }
        super.init(frame: NSRect(x: 0, y: 0, width: UsagePanelLayout.viewWidth, height: Self.viewHeight))
        addSubview(alwaysViewButton)
        addSubview(updateButton)
        addSubview(opacityLabel)
        addSubview(opacitySlider)
        addSubview(opacityValueLabel)
        dividers.forEach(addSubview)

        opacitySlider.controlSize = .small
        opacitySlider.isContinuous = true
        opacitySlider.setAccessibilityLabel("패널 투명도")
        opacityLabel.font = .systemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor
        opacityLabel.alignment = .left
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        opacityValueLabel.textColor = .secondaryLabelColor
        opacityValueLabel.alignment = .right
        setVersionText(versionTitle)
        setOpacity(1)
        layoutSubviews()
    }

    /// Shows the current version on the same clickable update control.
    func setVersionText(_ text: String) {
        let compactVersion = text
            .replacingOccurrences(of: "현재 버전 ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compactUpdateTitle = updateTitle.replacingOccurrences(of: "…", with: "")
        updateButton.title = compactVersion.isEmpty
            ? updateTitle
            : "\(compactUpdateTitle) · \(compactVersion)"
        updateButton.setAccessibilityLabel(
            text.isEmpty ? updateTitle : "\(updateTitle), \(text)"
        )
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

    func setOpacity(_ opacity: Double) {
        let normalizedOpacity = UsageCore.normalizedPanelOpacity(opacity)
        opacitySlider.doubleValue = normalizedOpacity
        let percent = Int((normalizedOpacity * 100).rounded())
        opacityValueLabel.stringValue = "\(percent)%"
        opacitySlider.setAccessibilityValueDescription("\(percent)%")
    }

    private func layoutSubviews() {
        let verticalInset = Self.cellInset
        alwaysViewButton.frame = NSRect(
            x: UsagePanelLayout.columnX[0],
            y: verticalInset,
            width: UsagePanelLayout.columnWidth,
            height: Self.viewHeight - verticalInset * 2
        )
        let updateX = UsagePanelLayout.columnX[1]
        updateButton.frame = NSRect(
            x: updateX,
            y: verticalInset,
            width: UsagePanelLayout.columnWidth,
            height: Self.viewHeight - verticalInset * 2
        )
        let opacityX = UsagePanelLayout.columnX[2]
        let textY = (Self.viewHeight - 16) / 2
        let sliderY = (Self.viewHeight - 20) / 2
        let contentX = opacityX + 8
        let valueWidth: CGFloat = 38
        let labelWidth: CGFloat = 42
        let controlGap: CGFloat = 6
        let valueX = opacityX + UsagePanelLayout.columnWidth - 8 - valueWidth
        let sliderX = contentX + labelWidth + controlGap
        let sliderWidth = valueX - controlGap - sliderX
        opacityLabel.frame = NSRect(x: contentX, y: textY, width: labelWidth, height: 16)
        opacitySlider.frame = NSRect(
            x: sliderX,
            y: sliderY,
            width: sliderWidth,
            height: 20
        )
        opacityValueLabel.frame = NSRect(x: valueX, y: textY, width: valueWidth, height: 16)

        for (index, divider) in dividers.enumerated() {
            divider.frame = NSRect(
                x: UsagePanelLayout.dividerX(after: index),
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
    /// The persisted request cadence has not elapsed yet. Carries the exact
    /// next eligible instant so an app relaunch cannot postpone the retry by
    /// another full refresh interval.
    case skippedThrottled(retryAt: Date)
    /// A prior 429's backoff window is still active, so this call never hit
    /// the network. Carries the same `retryAt` the original `.rateLimited`
    /// outcome stored, so the UI's countdown stays accurate.
    case skippedRateLimitBackoff(retryAt: Date)
    case noCredential
    /// An actual 429 response, with the backoff deadline computed from its
    /// `Retry-After` header (or the conservative fallback).
    case rateLimited(retryAt: Date)
    /// The access token was rejected (HTTP 401/403) or authentication cooldown is active.
    /// The user must run Claude Code or sign in again to rotate the credential.
    case authenticationRecoveryFailed
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
        case .rateLimited(let retryAt):
            return "http 429, backoff until epoch \(Int(retryAt.timeIntervalSince1970))"
        case .authenticationRecoveryFailed:
            return "Claude authentication failed"
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
        case .rateLimited:
            return "요청 제한(429)"
        case .authenticationRecoveryFailed:
            return "아래 버튼으로 Claude 다시 연결"
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
/// undocumented OAuth usage endpoint, using CCMB's own browser-authorized
/// OAuth account and automatically refreshed access token. This endpoint is not
/// officially documented for third-party use and may change or stop
/// working without notice — the caller receives a `ClaudeUsageFetchOutcome`
/// so it can fall back to the passive statusLine cache (`ClaudeUsageStore`)
/// while making the failure visible instead of presenting stale data as
/// healthy.
enum ClaudeOAuthUsageClient {
    private static let lastFetchDefaultsKey = "claudeUsageLastFetchAt"
    private static let rateLimitRetryDefaultsKey = "claudeUsageRateLimitRetryAt"
    private static let consecutiveRateLimitsDefaultsKey = "claudeUsageConsecutiveRateLimits"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// Tokens a profile fetch has already been attempted for, so the
    /// unofficial endpoint is hit at most once per process per token
    /// regardless of how many usage fetches succeed afterward.
    @MainActor private static var attemptedProfileTokens = Set<String>()
    @MainActor private static var latestAccountInfo: ClaudeAccountInfo?
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
    /// Persist the breaker step alongside its deadline so relaunching CCMB
    /// cannot collapse a multi-hour circuit back to the first one-hour step.
    @MainActor private static var consecutiveRateLimits =
        min(max(UserDefaults.standard.integer(forKey: consecutiveRateLimitsDefaultsKey), 0), 4)

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
        if ClaudeUsageCore.shouldThrottleFetch(minimumInterval: minimumInterval, lastFetchDate: lastFetchDate, now: now),
           let lastFetchDate {
            completion(.skippedThrottled(retryAt: lastFetchDate.addingTimeInterval(minimumInterval)))
            return
        }

        ClaudeOAuthAccountClient.accessToken { result in
            switch result {
            case .success(let token):
                performFetch(token: token, completion: completion)
            case .failure(let error as ClaudeOAuthAccountError) where error.isNoCredential:
                completion(.noCredential)
            case .failure:
                completion(.authenticationRecoveryFailed)
            }
        }
    }

    @MainActor
    static func resetAfterAccountConnection() {
        lastFetchDate = nil
        rateLimitRetryAt = nil
        consecutiveRateLimits = 0
        UserDefaults.standard.removeObject(forKey: lastFetchDefaultsKey)
        UserDefaults.standard.removeObject(forKey: rateLimitRetryDefaultsKey)
        UserDefaults.standard.removeObject(forKey: consecutiveRateLimitsDefaultsKey)
    }

    @MainActor
    private static func performFetch(
        token: String,
        allowAuthenticationRecovery: Bool = true,
        completion: @escaping (ClaudeUsageFetchOutcome) -> Void
    ) {
        isFetchInFlight = true
        let fetchDate = Date()
        let nextRateLimitCount = min(consecutiveRateLimits + 1, 4)
        lastFetchDate = fetchDate
        UserDefaults.standard.set(fetchDate, forKey: lastFetchDefaultsKey)

        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        request.setValue("CCMB/\(appVersion)", forHTTPHeaderField: "User-Agent")
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
                        consecutiveRateLimits: nextRateLimitCount,
                        now: now
                    )
                    outcome = .rateLimited(retryAt: now.addingTimeInterval(backoffSeconds))
                } else if http.statusCode == 401 || http.statusCode == 403 {
                    outcome = .authenticationRecoveryFailed
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
                    consecutiveRateLimits = 0
                    UserDefaults.standard.removeObject(forKey: consecutiveRateLimitsDefaultsKey)
                    fetchProfileIfNeeded(token: token) { accountInfo in
                        completion(.success(accountInfo.map(snapshot.withAccount) ?? snapshot))
                    }
                case .authenticationRecoveryFailed where allowAuthenticationRecovery:
                    // Discard only the short-lived access token. The CCMB-owned
                    // refresh token remains in Keychain and obtains a new access
                    // token before the one permitted retry.
                    isFetchInFlight = true
                    ClaudeOAuthAccountClient.clearCachedAccessToken()
                    ClaudeOAuthAccountClient.accessToken { result in
                        isFetchInFlight = false
                        switch result {
                        case .success(let refreshedToken):
                            performFetch(
                                token: refreshedToken,
                                allowAuthenticationRecovery: false,
                                completion: completion
                            )
                        case .failure:
                            completion(.authenticationRecoveryFailed)
                        }
                    }
                case .rateLimited(let retryAt):
                    rateLimitRetryAt = retryAt
                    UserDefaults.standard.set(retryAt, forKey: rateLimitRetryDefaultsKey)
                    consecutiveRateLimits = nextRateLimitCount
                    UserDefaults.standard.set(nextRateLimitCount, forKey: consecutiveRateLimitsDefaultsKey)
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
        let snapshot = ClaudeUsageSnapshot(
            quotaSource: "anthropic-oauth-usage",
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
        // A syntactically valid 200 with no core quota is not a successful
        // usage observation. Treat it as a decode failure so it cannot close
        // an open 429 circuit or make an older value look freshly verified.
        return snapshot.hasRateLimitUsage ? snapshot : nil
    }
}
