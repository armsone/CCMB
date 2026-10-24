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

/// Line colors of the three Gemini accounts: blue, cyan and teal, close
/// enough to read as one family and far enough apart to follow in one chart.
enum UsageTrendPalette {
    static let geminiMain = NSColor(srgbRed: 76 / 255.0, green: 141 / 255.0, blue: 246 / 255.0, alpha: 1)
    static let geminiSecond = NSColor(srgbRed: 62 / 255.0, green: 195 / 255.0, blue: 240 / 255.0, alpha: 1)
    static let geminiThird = NSColor(srgbRed: 47 / 255.0, green: 208 / 255.0, blue: 166 / 255.0, alpha: 1)
}

/// Trailing 24-hour line chart with a restrained gradient under each line.
/// Newest is on the LEFT, 24 hours ago on the RIGHT. Every series is drawn
/// only from its real per-refresh samples, at the moment they were recorded:
/// nothing is interpolated across a gap, summed across series, or padded. The
/// stretch older than the first recorded sample is hatched and labelled
/// instead of being drawn as zeros, and the vertical scale is the actual
/// per-refresh consumption (never a normalised 0–100%).
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
            hoveredDate = nil
            needsDisplay = true
        }
    }

    private var hoveredDate: Date?

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

    private var plot: NSRect {
        NSRect(
            x: Self.yAxisWidth,
            y: Self.topInset,
            width: max(1, bounds.width - Self.yAxisWidth - Self.rightInset),
            height: max(1, bounds.height - Self.topInset - Self.axisHeight)
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

        let perSeries = visible(now: now)
        let allSamples = perSeries.flatMap { $0.map(\.sample) }
        let peak = allSamples.map(\.amount).max() ?? 0
        let yMax = Self.niceMaximum(for: peak)

        drawGrid(in: rect, yMax: yMax, attributes: axisAttributes)
        drawTimeAxis(in: rect, now: now, attributes: axisAttributes)

        guard let earliest = allSamples.map(\.at).min() else {
            drawHatch(in: rect, context: context)
            drawCentered("아직 기록된 소모량이 없습니다", in: rect, attributes: noteAttributes)
            return
        }

        // Older than the first recorded sample: hatched and labelled, never zero.
        let earliestX = x(for: earliest, now: now)
        if rect.maxX - earliestX > 6 {
            let blank = NSRect(x: earliestX, y: rect.minY, width: rect.maxX - earliestX, height: rect.height)
            drawHatch(in: blank, context: context)
            let lines = ["기록 없음", "수집 시작 \(Self.startFormatter.string(from: earliest))"]
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

        let gapFallback = Self.fallbackGap(for: allSamples)
        // Later series first, so the first (main) line ends up on top.
        for index in perSeries.indices.reversed() {
            guard let strip, index < strip.series.count, !perSeries[index].isEmpty else { continue }
            let entry = strip.series[index]
            let gap = entry.gapSeconds ?? gapFallback
            let runs = Self.runs(perSeries[index], gap: gap)
            for run in runs {
                let points = run.map { NSPoint(x: x(for: $0.sample.at, now: now), y: y(for: $0.sample.amount, yMax: yMax)) }
                drawRun(points, color: entry.color, baseline: rect.maxY, top: rect.minY, context: context)
            }
        }

        if let hoveredDate {
            drawHover(date: hoveredDate, perSeries: perSeries, now: now, yMax: yMax, rect: rect, context: context)
        }
    }

    /// Consecutive samples (newest first) stay in one run only when they are
    /// close enough in time and belong to the same baseline segment.
    private static func runs(
        _ samples: [(sample: UsageConsumptionSample, segment: Int?)],
        gap: TimeInterval
    ) -> [[(sample: UsageConsumptionSample, segment: Int?)]] {
        var result: [[(sample: UsageConsumptionSample, segment: Int?)]] = []
        var current: [(sample: UsageConsumptionSample, segment: Int?)] = []
        for item in samples {
            if let last = current.last,
               last.sample.at.timeIntervalSince(item.sample.at) > gap || last.segment != item.segment {
                result.append(current)
                current = []
            }
            current.append(item)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Without a gap the NAS declared (the local tracker), unconnected means
    /// "further apart than four typical refreshes", at least an hour.
    private static func fallbackGap(for samples: [UsageConsumptionSample]) -> TimeInterval {
        let ordered = samples.map(\.at).sorted()
        let gaps = zip(ordered, ordered.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return 3_600 }
        return max(3_600, gaps[gaps.count / 2] * 4)
    }

    private func drawRun(_ points: [NSPoint], color: NSColor, baseline: CGFloat, top: CGFloat, context: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)).fill()
            return
        }
        let line = NSBezierPath()
        line.lineWidth = 1.6
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: first)
        points.dropFirst().forEach { line.line(to: $0) }

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: points[points.count - 1].x, y: baseline))
        area.line(to: NSPoint(x: first.x, y: baseline))
        area.close()
        context.saveGState()
        area.addClip()
        let colors = [color.withAlphaComponent(0.26).cgColor, color.withAlphaComponent(0.02).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: top),
                end: CGPoint(x: 0, y: baseline),
                options: []
            )
        }
        context.restoreGState()

        color.setStroke()
        line.stroke()
    }

    private func drawGrid(in rect: NSRect, yMax: Double, attributes: [NSAttributedString.Key: Any]) {
        let isBK = UsagePanelThemeStore.current == .bk
        let gridColor = (isBK ? NSColor.white : NSColor.labelColor).withAlphaComponent(isBK ? 0.10 : 0.12)
        for step in 0...2 {
            let value = yMax * Double(step) / 2
            let lineY = y(for: value, yMax: yMax)
            gridColor.setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: lineY - 0.5, width: rect.width, height: step == 0 ? 1 : 0.5)).fill()
            let label = tickTitle(value) as NSString
            let size = label.size(withAttributes: attributes)
            let labelY = min(max(lineY - size.height / 2, 0), bounds.height - Self.axisHeight - size.height + 2)
            label.draw(at: NSPoint(x: rect.minX - 5 - size.width, y: labelY), withAttributes: attributes)
        }
        // Faint vertical guides at every 6 hours.
        for hours in [6.0, 12.0, 18.0] {
            let guideX = rect.minX + CGFloat(hours / 24) * rect.width
            gridColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: NSRect(x: guideX - 0.25, y: rect.minY, width: 0.5, height: rect.height)).fill()
        }
    }

    /// 현재 (left) … 24시간 전 (right), at the real window positions.
    private func drawTimeAxis(in rect: NSRect, now: Date, attributes: [NSAttributedString.Key: Any]) {
        let labelY = rect.maxY + 3
        let stops: [(hours: Double, text: String)] = [
            (0, "현재"), (6, "6시간 전"), (12, "12시간 전"), (18, "18시간 전"), (24, "24시간 전")
        ]
        for stop in stops {
            let tickX = rect.minX + CGFloat(stop.hours / 24) * rect.width
            let text = stop.text as NSString
            let size = text.size(withAttributes: attributes)
            var originX = tickX - size.width / 2
            if stop.hours == 0 { originX = rect.minX }
            if stop.hours == 24 { originX = rect.maxX - size.width }
            originX = min(max(originX, 0), bounds.width - size.width)
            text.draw(at: NSPoint(x: originX, y: labelY), withAttributes: attributes)
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
        date: Date,
        perSeries: [[(sample: UsageConsumptionSample, segment: Int?)]],
        now: Date,
        yMax: Double,
        rect: NSRect,
        context: CGContext
    ) {
        guard let strip else { return }
        let hoverX = x(for: date, now: now)
        NSColor.labelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: NSRect(x: hoverX - 0.5, y: rect.minY, width: 1, height: rect.height)).fill()

        var parts: [String] = []
        for (index, samples) in perSeries.enumerated() where index < strip.series.count {
            let entry = strip.series[index]
            let match = samples.min { abs($0.sample.at.timeIntervalSince(date)) < abs($1.sample.at.timeIntervalSince(date)) }
            guard let match, abs(match.sample.at.timeIntervalSince(date)) <= 90 else {
                parts.append(entry.label.isEmpty ? "—" : "\(entry.label) —")
                continue
            }
            let point = NSPoint(x: x(for: match.sample.at, now: now), y: y(for: match.sample.amount, yMax: yMax))
            entry.color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
            let amount = UsageConsumptionCore.amountTitle(match.sample.amount, unit: strip.unitSuffix)
            parts.append(entry.label.isEmpty ? amount : "\(entry.label) \(amount)")
        }
        let text = "\(Self.hoverTimeFormatter.string(from: date)) · \(parts.joined(separator: " · "))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.bubbleFont, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let bubble = NSRect(
            x: min(max(hoverX - size.width / 2 - 6, rect.minX), rect.maxX - size.width - 12),
            y: rect.minY + 2,
            width: size.width + 12,
            height: size.height + 4
        )
        NSColor(white: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: bubble.minX + 6, y: bubble.minY + 2), withAttributes: attributes)
    }

    private func sampleDate(at point: NSPoint) -> Date? {
        let rect = plot
        guard rect.insetBy(dx: -Self.hoverRadius, dy: 0).contains(NSPoint(x: point.x, y: rect.midY)),
              point.y >= 0, point.y <= rect.maxY
        else { return nil }
        let now = Date()
        var best: (date: Date, distance: CGFloat)?
        for sample in visible(now: now).flatMap({ $0 }) {
            let distance = abs(x(for: sample.sample.at, now: now) - point.x)
            if distance <= Self.hoverRadius, distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (sample.sample.at, distance)
            }
        }
        return best?.date
    }

    private func updateHover(to date: Date?) {
        guard date != hoveredDate else { return }
        hoveredDate = date
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(to: sampleDate(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(to: sampleDate(at: convert(event.locationInWindow, from: nil)))
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
    private static let footerRowHeight: CGFloat = 16
    private static let bottomPadding: CGFloat = 4
    private static let dotDiameter: CGFloat = 7

    private static let cardHeight = cardPadding + titleRowHeight + 4 + legendRowHeight + 2
        + UsageTrendPlotView.totalHeight + 4 + footerRowHeight + cardPadding
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
        let title = "최근 24시간 소모량" as NSString
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: Self.titleFont, .foregroundColor: primary]
        let titleSize = title.size(withAttributes: titleAttributes)
        title.draw(at: NSPoint(x: contentX, y: titleY + (Self.titleRowHeight - titleSize.height) / 2), withAttributes: titleAttributes)

        drawTabs(rightEdge: card.maxX - Self.cardPadding, y: titleY + (Self.titleRowHeight - Self.tabHeight) / 2, secondary: secondary, primary: primary)

        let legendY = titleY + Self.titleRowHeight + 4
        drawLegend(x: contentX, rightEdge: card.maxX - Self.cardPadding, y: legendY, secondary: secondary)

        let footerY = legendY + Self.legendRowHeight + 2 + UsageTrendPlotView.totalHeight + 4
        drawFooter(x: contentX, rightEdge: card.maxX - Self.cardPadding, y: footerY, secondary: secondary)
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
        let now = Date()
        let windowStart = now.addingTimeInterval(-UsageTrendPlotView.windowDuration)
        for entry in strip.series {
            entry.color.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: currentX,
                y: y + (Self.legendRowHeight - Self.dotDiameter) / 2,
                width: Self.dotDiameter,
                height: Self.dotDiameter
            )).fill()
            currentX += Self.dotDiameter + 4
            var label = entry.label
            if strip.series.count > 1, let first = entry.samples.map(\.at).min(), first > windowStart.addingTimeInterval(1_200) {
                let hours = now.timeIntervalSince(first) / 3_600
                label += String(format: " %.1f시간", hours)
            }
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
        let unit = "갱신당 소모량 (\(strip.unitSuffix.trimmingCharacters(in: .whitespaces)))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.footerFont, .foregroundColor: secondary]
        let size = unit.size(withAttributes: attributes)
        if currentX + size.width + 8 <= rightEdge {
            unit.draw(at: NSPoint(x: rightEdge - size.width, y: y + (Self.legendRowHeight - size.height) / 2), withAttributes: attributes)
        }
    }

    /// Left: which source and as-of time. Right: how much of the 24 hours is
    /// actually covered.
    private func drawFooter(x: CGFloat, rightEdge: CGFloat, y: CGFloat, secondary: NSColor) {
        guard let strip = strips[selected] else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.footerFont, .foregroundColor: secondary]
        let now = Date()
        let start = now.addingTimeInterval(-UsageTrendPlotView.windowDuration)
        let dates = strip.series.flatMap { $0.samples.map(\.at) }.filter { $0 >= start }
        let coverage: String
        if let first = dates.min() {
            let hours = min(now.timeIntervalSince(first) / 3_600, 24)
            coverage = hours >= 23.5 ? "24시간 전체 기록" : String(format: "24시간 중 %.1f시간만 기록", hours)
        } else {
            coverage = "24시간 중 기록 없음"
        }
        let latest = dates.max().map { Self.timeFormatter.string(from: $0) }
        let source = [strip.sourceNote, latest.map { "마지막 기록 \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let sourceText = source as NSString
        let coverageText = coverage as NSString
        let coverageSize = coverageText.size(withAttributes: attributes)
        coverageText.draw(at: NSPoint(x: rightEdge - coverageSize.width, y: y), withAttributes: attributes)
        let available = rightEdge - x - coverageSize.width - 10
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var sourceAttributes = attributes
        sourceAttributes[.paragraphStyle] = paragraph
        sourceText.draw(in: NSRect(x: x, y: y, width: max(0, available), height: Self.footerRowHeight), withAttributes: sourceAttributes)
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
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
