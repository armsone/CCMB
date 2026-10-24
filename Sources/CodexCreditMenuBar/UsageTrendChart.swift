import AppKit

/// Provider tabs of the trend card. Each one owns one chart; Gemini draws its
/// three accounts as three lines in the same chart.
enum UsageTrendProvider: Int, CaseIterable {
    case codex, claude, gemini

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        }
    }

    var color: NSColor {
        switch self {
        case .codex: return UsageBrandColors.codex
        case .claude: return UsageBrandColors.claude
        case .gemini: return UsageTrendPalette.geminiMain
        }
    }

    static let defaultsKey = "usageTrendProviderV1"

    static var stored: UsageTrendProvider {
        get { UsageTrendProvider(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .codex }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Line colors of the three Gemini accounts: Google brand blue, red and
/// yellow, the same colors the account cards use.
enum UsageTrendPalette {
    static let geminiMain = UsageBrandColors.geminiMainAccount
    static let geminiSecond = UsageBrandColors.geminiSecondAccount
    static let geminiThird = UsageBrandColors.geminiThirdAccount
}

/// One 30-minute stretch of one series: the measured consumption of every
/// refresh recorded inside a wall-clock aligned half hour, summed. Buckets are
/// the only thing the chart plots, so a 3-minute refresh cadence reads as a
/// trend instead of a forest of needles. A stretch with no sample has no
/// bucket at all (unknown, never zero); a real zero reading sums to zero.
struct UsageTrendBucket {
    /// Aligned half-hour boundary this bucket belongs to.
    let start: Date
    /// The part of that half hour that is actually on the chart: clipped to
    /// the 24-hour window, to `now`, and to the first recorded sample.
    let from: Date
    let to: Date
    let amount: Double
    let sampleCount: Int
    let firstAt: Date
    let lastAt: Date
    let segment: Int?
    /// The half hour that is still running (left edge).
    let isInProgress: Bool
    /// Cut short at the older edge by the window or by the first recording.
    var isClipped: Bool
    /// Refreshes inside it are further apart than the source's own gap.
    let hasGap: Bool

    var isEdge: Bool { isInProgress || isClipped }
    var midpoint: Date { Date(timeIntervalSince1970: (from.timeIntervalSince1970 + to.timeIntervalSince1970) / 2) }
}

enum UsageTrendBucketing {
    static let bucketSeconds: TimeInterval = 30 * 60

    /// Start of the local half hour that contains `date`.
    static func boundary(for date: Date) -> Date {
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: date))
        let local = date.timeIntervalSince1970 + offset
        return Date(timeIntervalSince1970: floor(local / bucketSeconds) * bucketSeconds - offset)
    }

    private struct Key: Hashable {
        let start: TimeInterval
        let segment: Int?
    }

    /// Newest first. Samples of different baseline segments never share a
    /// bucket, and samples outside `windowStart ... now` are not used.
    static func buckets(
        _ samples: [(sample: UsageConsumptionSample, segment: Int?)],
        gap: TimeInterval,
        now: Date,
        windowStart: Date,
        earliest: Date
    ) -> [UsageTrendBucket] {
        var groups: [Key: [(at: Date, amount: Double)]] = [:]
        for item in samples where item.sample.at >= windowStart {
            let at = min(item.sample.at, now)
            let key = Key(start: boundary(for: at).timeIntervalSince1970, segment: item.segment)
            groups[key, default: []].append((at, item.sample.amount))
        }
        let lowerBound = max(windowStart, earliest)
        var result: [UsageTrendBucket] = []
        for (key, entries) in groups {
            let ordered = entries.sorted { $0.at < $1.at }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let start = Date(timeIntervalSince1970: key.start)
            let end = start.addingTimeInterval(bucketSeconds)
            let from = max(start, lowerBound)
            let to = max(from, min(end, now))
            var hasGap = false
            for (older, newer) in zip(ordered, ordered.dropFirst()) where newer.at.timeIntervalSince(older.at) > gap {
                hasGap = true
            }
            result.append(UsageTrendBucket(
                start: start,
                from: from,
                to: to,
                amount: ordered.reduce(0) { $0 + max(0, $1.amount) },
                sampleCount: ordered.count,
                firstAt: first.at,
                lastAt: last.at,
                segment: key.segment,
                isInProgress: end > now,
                isClipped: start < lowerBound,
                hasGap: hasGap
            ))
        }
        result.sort {
            $0.start != $1.start ? $0.start > $1.start : ($0.segment ?? -1) > ($1.segment ?? -1)
        }
        // A series that began recording part-way into its oldest half hour
        // has only covered part of it.
        if let oldest = result.last, oldest.firstAt.timeIntervalSince(oldest.from) > gap {
            result[result.count - 1].isClipped = true
        }
        return result
    }

    /// Buckets (newest first) stay on one line only when they are neighbouring
    /// half hours of the same baseline segment and the source itself did not
    /// stop reporting between them. An empty half hour is never bridged.
    static func runs(_ buckets: [UsageTrendBucket], gap: TimeInterval) -> [[UsageTrendBucket]] {
        var result: [[UsageTrendBucket]] = []
        var current: [UsageTrendBucket] = []
        for bucket in buckets {
            if let newer = current.last {
                let neighbours = Int(((newer.start.timeIntervalSince(bucket.start)) / bucketSeconds).rounded()) == 1
                if !neighbours || newer.segment != bucket.segment || newer.firstAt.timeIntervalSince(bucket.lastAt) > gap {
                    result.append(current)
                    current = []
                }
            }
            current.append(bucket)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Trailing 24-hour line chart with a restrained gradient under each line.
/// Newest is on the LEFT, 24 hours ago on the RIGHT. Each series plots the
/// measured consumption of every 30-minute stretch (the sum of its real
/// per-refresh amounts), so the line reads as a trend. Nothing is
/// interpolated across a gap, summed across series or baseline segments, or
/// padded: an empty stretch is left open, the stretch older than the first
/// recorded sample is hatched and labelled instead of being drawn as zeros,
/// and the vertical scale is the actual consumption (never a normalised
/// 0–100%). The left-most half hour is still running and is drawn as such.
@MainActor
final class UsageTrendPlotView: NSView {
    static let windowDuration: TimeInterval = 24 * 60 * 60
    static let plotHeight: CGFloat = 112
    static let axisHeight: CGFloat = 16
    private static let topInset: CGFloat = 8
    private static let yAxisWidth: CGFloat = 36
    private static let rightInset: CGFloat = 6
    private static let hoverRadius: CGFloat = 12
    private static let axisFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let noteFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    private static let bubbleFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    static let totalHeight: CGFloat = topInset + plotHeight + axisHeight

    private static let hoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    var strip: UsageHistoryStrip? {
        didSet {
            hoveredStart = nil
            needsDisplay = true
        }
    }

    /// Aligned start of the half hour under the pointer.
    private var hoveredStart: Date?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // ONE tracking area, installed once and kept in sync by AppKit itself
        // (`.inVisibleRect`). Rebuilding areas from geometry updates makes
        // AppKit schedule another update pass and can spin the main thread.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Geometry

    var customPlotHeight: CGFloat? {
        didSet {
            hoveredStart = nil
            needsDisplay = true
        }
    }
    var showsAxisLabels: Bool = true {
        didSet { needsDisplay = true }
    }

    private var currentPlotHeight: CGFloat {
        customPlotHeight ?? Self.plotHeight
    }

    private var plot: NSRect {
        let axisH = showsAxisLabels ? Self.axisHeight : 10
        let yAxisW = showsAxisLabels ? Self.yAxisWidth : 26
        let topIn = showsAxisLabels ? Self.topInset : 4
        let rightIn = showsAxisLabels ? Self.rightInset : 4
        return NSRect(
            x: yAxisW,
            y: topIn,
            width: max(1, bounds.width - yAxisW - rightIn),
            height: max(1, bounds.height - topIn - axisH)
        )
    }

    /// Newest at the left edge, 24 hours ago at the right edge.
    private func x(for date: Date, now: Date) -> CGFloat {
        let fraction = min(max(now.timeIntervalSince(date) / Self.windowDuration, 0), 1)
        return plot.minX + CGFloat(fraction) * plot.width
    }

    private func y(for amount: Double, yMax: Double) -> CGFloat {
        let rect = plot
        guard yMax > 0 else { return rect.maxY }
        return rect.maxY - CGFloat(min(max(amount, 0) / yMax, 1)) * rect.height
    }

    /// Samples inside the trailing window, per series, newest first.
    private func visible(now: Date) -> [[(sample: UsageConsumptionSample, segment: Int?)]] {
        guard let strip else { return [] }
        let start = now.addingTimeInterval(-Self.windowDuration)
        return strip.series.map { entry in
            let keys = entry.segmentKeys
            let paired = entry.samples.enumerated().map { index, sample in
                (sample: sample, segment: (keys != nil && index < keys!.count) ? keys![index] : nil)
            }
            return paired
                .filter { $0.sample.at >= start && $0.sample.at <= now.addingTimeInterval(300) }
                .sorted { $0.sample.at > $1.sample.at }
        }
    }

    /// Everything the chart draws, derived from one `now`: per-series 30-minute
    /// buckets (newest first) and the gap each series is split at.
    private struct Plotted {
        let now: Date
        let earliest: Date?
        let gaps: [TimeInterval]
        let buckets: [[UsageTrendBucket]]
    }

    private func plotted(now: Date) -> Plotted {
        let perSeries = visible(now: now)
        let allSamples = perSeries.flatMap { $0.map(\.sample) }
        let earliest = allSamples.map(\.at).min()
        let fallback = Self.fallbackGap(for: allSamples)
        let windowStart = now.addingTimeInterval(-Self.windowDuration)
        var gaps: [TimeInterval] = []
        var buckets: [[UsageTrendBucket]] = []
        for (index, samples) in perSeries.enumerated() {
            let gap = (strip != nil && index < strip!.series.count ? strip!.series[index].gapSeconds : nil) ?? fallback
            gaps.append(gap)
            buckets.append(UsageTrendBucketing.buckets(
                samples, gap: gap, now: now, windowStart: windowStart, earliest: earliest ?? windowStart
            ))
        }
        return Plotted(now: now, earliest: earliest, gaps: gaps, buckets: buckets)
    }

    private func x(for bucket: UsageTrendBucket, now: Date) -> CGFloat {
        x(for: bucket.midpoint, now: now)
    }

    /// A round axis maximum at or above the peak, so the three grid lines
    /// (0, half, max) carry tidy values.
    static func niceMaximum(for peak: Double) -> Double {
        guard peak > 0 else { return 1 }
        var magnitude = pow(10, floor(log10(peak)))
        while true {
            for mantissa in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0] where mantissa * magnitude >= peak * 0.999 {
                return max(mantissa * magnitude, 0.1)
            }
            magnitude *= 10
        }
    }

    private func tickTitle(_ value: Double) -> String {
        let isPercent = strip?.unitSuffix == "%"
        let text: String
        if value == 0 {
            text = "0"
        } else if value >= 10 || value.rounded() == value {
            text = String(format: "%.0f", value)
        } else {
            text = String(format: "%.2f", value)
                .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        }
        return isPercent ? "\(text)%" : text
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        let rect = plot
        let isBK = UsagePanelThemeStore.current == .bk
        let labelColor = isBK ? BKStyleTokens.secondaryInk : NSColor.secondaryLabelColor
        let mutedColor = isBK ? BKStyleTokens.mutedInk : NSColor.tertiaryLabelColor
        let axisAttributes: [NSAttributedString.Key: Any] = [.font: Self.axisFont, .foregroundColor: labelColor]
        let noteAttributes: [NSAttributedString.Key: Any] = [.font: Self.noteFont, .foregroundColor: mutedColor]

        let data = plotted(now: now)
        let peak = data.buckets.flatMap { $0.map(\.amount) }.max() ?? 0
        let yMax = Self.niceMaximum(for: peak)

        drawGrid(in: rect, yMax: yMax, attributes: axisAttributes)
        drawTimeAxis(in: rect, now: now, attributes: axisAttributes)

        guard let earliest = data.earliest else {
            drawHatch(in: rect, context: context)
            drawCentered("아직 기록된 소모량이 없습니다", in: rect, attributes: noteAttributes)
            return
        }

        // Older than the first recorded sample: hatched and labelled, never zero.
        let earliestX = x(for: earliest, now: now)
        if rect.maxX - earliestX > 6 {
            let blank = NSRect(x: earliestX, y: rect.minY, width: rect.maxX - earliestX, height: rect.height)
            drawHatch(in: blank, context: context)
            let lines = ["기록 없음"]
            let widest = lines.map { ($0 as NSString).size(withAttributes: noteAttributes).width }.max() ?? 0
            let lineHeight = (lines[0] as NSString).size(withAttributes: noteAttributes).height
            if widest + 8 <= blank.width {
                for (index, line) in lines.enumerated() {
                    let size = (line as NSString).size(withAttributes: noteAttributes)
                    (line as NSString).draw(
                        at: NSPoint(x: blank.midX - size.width / 2, y: blank.midY - lineHeight + CGFloat(index) * lineHeight),
                        withAttributes: noteAttributes
                    )
                }
            } else if (lines[0] as NSString).size(withAttributes: noteAttributes).width + 8 <= blank.width {
                drawCentered(lines[0], in: blank, attributes: noteAttributes)
            }
        }

        // Later series first, so the first (main) line ends up on top.
        for index in data.buckets.indices.reversed() {
            guard let strip, index < strip.series.count, !data.buckets[index].isEmpty else { continue }
            let entry = strip.series[index]
            for run in UsageTrendBucketing.runs(data.buckets[index], gap: data.gaps[index]) {
                let points = run.map {
                    TrendPoint(
                        location: NSPoint(x: x(for: $0, now: now), y: y(for: $0.amount, yMax: yMax)),
                        isEdge: $0.isEdge
                    )
                }
                drawRun(points, color: entry.color, baseline: rect.maxY, top: rect.minY, context: context)
            }
        }

        if let hoveredStart {
            drawHover(start: hoveredStart, data: data, yMax: yMax, rect: rect, context: context)
        }
    }

    /// Without a gap the NAS declared (the local tracker), unconnected means
    /// "further apart than four typical refreshes", at least an hour.
    private static func fallbackGap(for samples: [UsageConsumptionSample]) -> TimeInterval {
        let ordered = samples.map(\.at).sorted()
        let gaps = zip(ordered, ordered.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return 3_600 }
        return max(3_600, gaps[gaps.count / 2] * 4)
    }

    private struct TrendPoint {
        let location: NSPoint
        /// The running half hour or a cut-short oldest one: drawn hollow and
        /// linked with a dashed stroke, because it is not a full 30 minutes.
        let isEdge: Bool
    }

    private func drawRun(_ points: [TrendPoint], color: NSColor, baseline: CGFloat, top: CGFloat, context: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            drawMarker(first, color: color)
            return
        }

        // Fill only under complete half hours (edge points sit at the ends).
        let complete = points.filter { !$0.isEdge }.map(\.location)
        if complete.count >= 2, let head = complete.first, let tail = complete.last {
            let area = NSBezierPath()
            area.move(to: head)
            complete.dropFirst().forEach { area.line(to: $0) }
            area.line(to: NSPoint(x: tail.x, y: baseline))
            area.line(to: NSPoint(x: head.x, y: baseline))
            area.close()
            context.saveGState()
            area.addClip()
            let colors = [color.withAlphaComponent(0.20).cgColor, color.withAlphaComponent(0.015).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: top),
                    end: CGPoint(x: 0, y: baseline),
                    options: []
                )
            }
            context.restoreGState()
        }

        color.setStroke()
        for (newer, older) in zip(points, points.dropFirst()) {
            let link = NSBezierPath()
            link.lineWidth = 1.4
            link.lineJoinStyle = .miter
            link.lineCapStyle = .butt
            link.move(to: newer.location)
            link.line(to: older.location)
            if newer.isEdge || older.isEdge {
                link.setLineDash([3, 2.5], count: 2, phase: 0)
            }
            link.stroke()
        }
        for point in points where point.isEdge {
            drawMarker(point, color: color)
        }
    }

    /// Hollow ring for a half hour that is not complete; a small dot for an
    /// isolated complete one that has no neighbour to be joined to.
    private func drawMarker(_ point: TrendPoint, color: NSColor) {
        let dot = NSRect(x: point.location.x - 2.5, y: point.location.y - 2.5, width: 5, height: 5)
        if point.isEdge {
            let ring = NSBezierPath(ovalIn: dot)
            color.setStroke()
            ring.lineWidth = 1.2
            ring.stroke()
        } else {
            color.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5)).fill()
        }
    }

    private func drawGrid(in rect: NSRect, yMax: Double, attributes: [NSAttributedString.Key: Any]) {
        let isBK = UsagePanelThemeStore.current == .bk
        let gridColor = (isBK ? NSColor.white : NSColor.labelColor).withAlphaComponent(isBK ? 0.10 : 0.12)
        let font = NSFont.systemFont(ofSize: showsAxisLabels ? 10 : 8.5, weight: .medium)
        var tickAttributes = attributes
        tickAttributes[.font] = font
        for step in 0...2 {
            let value = yMax * Double(step) / 2
            let lineY = y(for: value, yMax: yMax)
            gridColor.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: lineY - 0.5, width: rect.width, height: step == 0 ? 1 : 0.5)).fill()
            let label = tickTitle(value) as NSString
            let size = label.size(withAttributes: tickAttributes)
            let axisH = showsAxisLabels ? Self.axisHeight : 10
            let labelY = min(max(lineY - size.height / 2, 0), bounds.height - axisH - size.height + 2)
            label.draw(at: NSPoint(x: rect.minX - 4 - size.width, y: labelY), withAttributes: tickAttributes)
        }
        // Faint vertical guides at every 6 hours.
        for hours in [6.0, 12.0, 18.0] {
            let guideX = rect.minX + CGFloat(hours / 24) * rect.width
            gridColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: NSRect(x: guideX - 0.25, y: rect.minY, width: 0.5, height: rect.height)).fill()
        }
    }

    /// 현재/지금 (left) … 24시간 전 (right), at the real window positions.
    private func drawTimeAxis(in rect: NSRect, now: Date, attributes: [NSAttributedString.Key: Any]) {
        let labelY = rect.maxY + 2
        let fontSize: CGFloat = showsAxisLabels ? 10 : 9
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        var fontAttributes = attributes
        fontAttributes[.font] = font

        if !showsAxisLabels {
            // iPhone style compact labels: "지금" at left, "24시간 전" at right
            let leftText = "지금" as NSString
            let rightText = "24시간 전" as NSString
            let rightSize = rightText.size(withAttributes: fontAttributes)
            leftText.draw(at: NSPoint(x: rect.minX, y: labelY), withAttributes: fontAttributes)
            rightText.draw(at: NSPoint(x: rect.maxX - rightSize.width, y: labelY), withAttributes: fontAttributes)
            return
        }

        let stops: [(hours: Double, text: String)] = [
            (0, "지금"), (6, "6h"), (12, "12h"), (18, "18h"), (24, "24시간 전")
        ]
        for stop in stops {
            let tickX = rect.minX + CGFloat(stop.hours / 24) * rect.width
            let text = stop.text as NSString
            let size = text.size(withAttributes: fontAttributes)
            var originX = tickX - size.width / 2
            if stop.hours == 0 { originX = rect.minX }
            if stop.hours == 24 { originX = rect.maxX - size.width }
            originX = min(max(originX, 0), bounds.width - size.width)
            text.draw(at: NSPoint(x: originX, y: labelY), withAttributes: fontAttributes)
        }
    }

    private func drawHatch(in rect: NSRect, context: CGContext) {
        guard rect.width > 1, rect.height > 1 else { return }
        let isBK = UsagePanelThemeStore.current == .bk
        context.saveGState()
        context.clip(to: rect)
        (isBK ? NSColor.white : NSColor.labelColor).withAlphaComponent(isBK ? 0.045 : 0.05).setFill()
        context.fill(rect)
        (isBK ? NSColor.white : NSColor.labelColor).withAlphaComponent(isBK ? 0.08 : 0.09).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        var offset = -rect.height
        while offset < rect.width {
            path.move(to: NSPoint(x: rect.minX + offset, y: rect.maxY))
            path.line(to: NSPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += 7
        }
        path.stroke()
        context.restoreGState()
    }

    private func drawCentered(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Hover

    private func drawHover(
        start: Date,
        data: Plotted,
        yMax: Double,
        rect: NSRect,
        context: CGContext
    ) {
        guard let strip else { return }
        let now = data.now
        var range: (from: Date, to: Date)?
        var inProgress = false
        var anyPartial = false
        var parts: [String] = []
        var hoverX: CGFloat?
        for (index, buckets) in data.buckets.enumerated() where index < strip.series.count {
            let entry = strip.series[index]
            let prefix = entry.label.isEmpty ? "" : "\(entry.label) "
            // Newest baseline segment first when a half hour holds two.
            guard let bucket = buckets.first(where: { $0.start == start }) else {
                parts.append(entry.label.isEmpty ? "—" : "\(entry.label) —")
                continue
            }
            let point = NSPoint(x: x(for: bucket, now: now), y: y(for: bucket.amount, yMax: yMax))
            hoverX = hoverX ?? point.x
            range = range ?? (bucket.from, bucket.to)
            inProgress = inProgress || bucket.isInProgress
            let partial = !bucket.isInProgress && (bucket.isClipped || bucket.hasGap)
            anyPartial = anyPartial || partial
            entry.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            let amount = UsageConsumptionCore.amountTitle(bucket.amount, unit: strip.unitSuffix)
            parts.append("\(prefix)\(amount)\(partial ? "*" : "")")
        }
        guard let hoverX, let range else { return }
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: NSRect(x: hoverX - 0.5, y: rect.minY, width: 1, height: rect.height)).fill()

        let span = "\(Self.hoverTimeFormatter.string(from: range.from))–\(Self.hoverTimeFormatter.string(from: range.to))"
        var head = span
        if inProgress { head += " 진행중" }
        var tail = ""
        if anyPartial { tail = " · * 일부만 수집" }
        let text = "\(head) · \(parts.joined(separator: " · "))\(tail)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bubbleFont, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let bubble = NSRect(
            x: min(max(hoverX - size.width / 2 - 6, rect.minX), max(rect.minX, rect.maxX - size.width - 12)),
            y: rect.minY + 2,
            width: size.width + 12,
            height: size.height + 4
        )
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: bubble.minX + 6, y: bubble.minY + 2), withAttributes: attributes)
    }

    /// Half hour whose bucket centre is nearest the pointer, among all series.
    private func bucketStart(at point: NSPoint) -> Date? {
        let rect = plot
        guard rect.insetBy(dx: -Self.hoverRadius, dy: 0).contains(NSPoint(x: point.x, y: rect.midY)),
              point.y >= 0, point.y <= rect.maxY
        else { return nil }
        let data = plotted(now: Date())
        var best: (start: Date, distance: CGFloat)?
        for bucket in data.buckets.flatMap({ $0 }) {
            let distance = abs(x(for: bucket, now: data.now) - point.x)
            if distance <= Self.hoverRadius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (bucket.start, distance)
            }
        }
        return best?.start
    }

    private func updateHover(to start: Date?) {
        guard start != hoveredStart else { return }
        hoveredStart = start
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(to: bucketStart(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(to: bucketStart(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(to: nil)
    }
}

/// The dashboard's trend card: a title with provider tabs, a legend with the
/// chart's unit, one large chart, and an honest coverage line (what the NAS
/// has actually recorded of the last 24 hours, and as of when). The three
/// tabs keep every provider one click away without stacking three charts.
@MainActor
final class UsageHistoryChartView: NSView {
    private static let viewWidth: CGFloat = UsagePanelLayout.viewWidth
    private static let cardInset: CGFloat = UsagePanelLayout.sidePadding
    private static let cardTop: CGFloat = 4
    private static let cardPadding: CGFloat = 10
    private static let cardCornerRadius: CGFloat = 8
    private static let titleRowHeight: CGFloat = 24
    private static let legendRowHeight: CGFloat = 18
    private static let bottomPadding: CGFloat = 4
    private static let dotDiameter: CGFloat = 7

    private static let cardHeight = cardPadding + titleRowHeight + 4 + legendRowHeight + 2
        + UsageTrendPlotView.totalHeight + cardPadding
    static let viewHeight: CGFloat = cardTop + cardHeight + bottomPadding

    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let tabFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let legendFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let footerFont = NSFont.systemFont(ofSize: 10.5, weight: .regular)
    private static let tabHeight: CGFloat = 22
    private static let tabPadding: CGFloat = 10
    private static let tabGap: CGFloat = 4

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private let plotView = UsageTrendPlotView()
    private var strips: [UsageTrendProvider: UsageHistoryStrip] = [:]
    private var selected = UsageTrendProvider.stored
    private var tabRects: [(provider: UsageTrendProvider, rect: NSRect)] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        addSubview(plotView)
        setAccessibilityElement(false)
        layoutPlot()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func layoutPlot() {
        let top = Self.cardTop + Self.cardPadding + Self.titleRowHeight + 4 + Self.legendRowHeight + 2
        plotView.frame = NSRect(
            x: Self.cardInset + Self.cardPadding - 2,
            y: top,
            width: Self.viewWidth - (Self.cardInset + Self.cardPadding - 2) * 2,
            height: UsageTrendPlotView.totalHeight
        )
    }

    /// Returns false when no provider has anything to draw, so the caller can
    /// hide the whole row instead of leaving an empty band.
    @discardableResult
    func apply(
        codex: UsageHistoryStrip?,
        claude: UsageHistoryStrip?,
        gemini: UsageHistoryStrip?,
        grok _: UsageHistoryStrip?
    ) -> Bool {
        strips = [:]
        if let codex { strips[.codex] = codex }
        if let claude { strips[.claude] = claude }
        if let gemini { strips[.gemini] = gemini }
        if strips[selected] == nil, let first = UsageTrendProvider.allCases.first(where: { strips[$0] != nil }) {
            selected = first
        }
        plotView.strip = strips[selected]
        refreshToolTip()
        needsDisplay = true
        return !strips.isEmpty
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isBK = UsagePanelThemeStore.current == .bk
        let primary = isBK ? BKStyleTokens.bodyInk : NSColor.labelColor
        let secondary = isBK ? BKStyleTokens.secondaryInk : NSColor.secondaryLabelColor

        let card = NSRect(
            x: Self.cardInset,
            y: Self.cardTop,
            width: bounds.width - Self.cardInset * 2,
            height: Self.cardHeight
        )
        if isBK {
            BKStyleTokens.drawCard(in: card, radius: Self.cardCornerRadius)
        } else {
            let path = NSBezierPath(roundedRect: card, xRadius: Self.cardCornerRadius, yRadius: Self.cardCornerRadius)
            NSColor.labelColor.withAlphaComponent(0.045).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let contentX = card.minX + Self.cardPadding
        let titleY = card.minY + Self.cardPadding
        let title = "24시간" as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: primary]
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(at: NSPoint(x: contentX, y: titleY + (Self.titleRowHeight - titleSize.height) / 2), withAttributes: titleAttributes)

        drawTabs(rightEdge: card.maxX - Self.cardPadding, y: titleY + (Self.titleRowHeight - Self.tabHeight) / 2, secondary: secondary, primary: primary)

        let legendY = titleY + Self.titleRowHeight + 4
        drawLegend(x: contentX, rightEdge: card.maxX - Self.cardPadding, y: legendY, secondary: secondary)
    }

    private func drawTabs(rightEdge: CGFloat, y: CGFloat, secondary: NSColor, primary: NSColor) {
        let providers = UsageTrendProvider.allCases
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.tabFont]
        let widths = providers.map { ceil(($0.title as NSString).size(withAttributes: attributes).width) + Self.tabPadding * 2 }
        var x = rightEdge - widths.reduce(0, +) - Self.tabGap * CGFloat(providers.count - 1)
        tabRects = []
        for (provider, width) in zip(providers, widths) {
            let rect = NSRect(x: x, y: y, width: width, height: Self.tabHeight)
            tabRects.append((provider, rect))
            let isSelected = provider == selected
            let hasData = strips[provider] != nil
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if isSelected {
                provider.color.withAlphaComponent(0.22).setFill()
                path.fill()
                provider.color.withAlphaComponent(0.85).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                (NSColor.labelColor).withAlphaComponent(0.06).setFill()
                path.fill()
            }
            let color = isSelected ? primary : (hasData ? secondary : secondary.withAlphaComponent(0.5))
            let text = provider.title as NSString
            let drawAttributes: [NSAttributedString.Key: Any] = [
                .font: isSelected ? NSFont.systemFont(ofSize: 12, weight: .semibold) : Self.tabFont,
                .foregroundColor: color
            ]
            let size = text.size(withAttributes: drawAttributes)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: drawAttributes)
            x += width + Self.tabGap
        }
    }

    /// Series dots and names on the left; the chart's unit on the right. A
    /// series that has recorded less than the whole 24 hours says so.
    private func drawLegend(x: CGFloat, rightEdge: CGFloat, y: CGFloat, secondary: NSColor) {
        guard let strip = strips[selected] else { return }
        var currentX = x
        for entry in strip.series {
            entry.color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: currentX,
                y: y + (Self.legendRowHeight - Self.dotDiameter) / 2,
                width: Self.dotDiameter,
                height: Self.dotDiameter
            )).fill()
            currentX += Self.dotDiameter + 4
            let label = entry.label
            if !label.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: Self.legendFont, .foregroundColor: entry.color]
                let size = (label as NSString).size(withAttributes: attributes)
                (label as NSString).draw(
                    at: NSPoint(x: currentX, y: y + (Self.legendRowHeight - size.height) / 2),
                    withAttributes: attributes
                )
                currentX += ceil(size.width) + 10
            } else {
                currentX += 6
            }
        }
        let unitName = strip.unitSuffix.trimmingCharacters(in: .whitespaces)
        var metric = unitName == "%" ? "30분 소모(%)" : "30분 소모(\(unitName))"
        if let cue = coverageCue(for: strip) { metric += " · \(cue)" }
        let unit = metric as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.footerFont, .foregroundColor: secondary]
        let size = unit.size(withAttributes: attributes)
        if currentX + size.width + 8 <= rightEdge {
            unit.draw(at: NSPoint(x: rightEdge - size.width, y: y + (Self.legendRowHeight - size.height) / 2), withAttributes: attributes)
        }
    }

    /// "22.3h/24h" when less than the whole window has been recorded; nil
    /// when the 24 hours are covered. Source and as-of time go to the tooltip.
    private func coverageCue(for strip: UsageHistoryStrip) -> String? {
        let now = Date()
        let start = now.addingTimeInterval(-UsageTrendPlotView.windowDuration)
        let dates = strip.series.flatMap { $0.samples.map(\.at) }.filter { $0 >= start }
        guard let first = dates.min() else { return "0h/24h" }
        let hours = min(now.timeIntervalSince(first) / 3_600, 24)
        return hours >= 23.5 ? nil : String(format: "%.1fh/24h", hours)
    }

    private func refreshToolTip() {
        guard let strip = strips[selected] else { toolTip = nil; return }
        let start = Date().addingTimeInterval(-UsageTrendPlotView.windowDuration)
        let latest = strip.series.flatMap { $0.samples.map(\.at) }.filter { $0 >= start }.max()
            .map { "마지막 기록 \(Self.timeFormatter.string(from: $0))" }
        toolTip = [strip.sourceNote, latest].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Tabs

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = tabRects.first(where: { $0.rect.insetBy(dx: -2, dy: -4).contains(point) }),
              hit.provider != selected
        else {
            super.mouseDown(with: event)
            return
        }
        selected = hit.provider
        UsageTrendProvider.stored = hit.provider
        plotView.strip = strips[selected]
        refreshToolTip()
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
