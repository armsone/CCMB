import AppKit

/// Color palette and style tokens for the iPhone-style light dashboard.
enum CCMBDashPalette {
    static var canvasTop: NSColor { UsagePanelThemeStore.current.palette.bg }
    static var canvasBottom: NSColor { BKStyleTokens.canvasWash }
    static var cardBackground: NSColor { UsagePanelThemeStore.current.palette.card }
    static var ink: NSColor { UsagePanelThemeStore.current.palette.text }
    static var muted: NSColor { UsagePanelThemeStore.current.palette.muted }
    static var track: NSColor { UsagePanelThemeStore.current.palette.surface2 }
    static var divider: NSColor { UsagePanelThemeStore.current.palette.border }
    static var codexIconBg: NSColor {
        UsagePanelThemeStore.current.isDark
            ? NSColor(srgbRed: 0x16 / 255.0, green: 0x23 / 255.0, blue: 0x37 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 2 / 255.0, green: 23 / 255.0, blue: 44 / 255.0, alpha: 1.0)
    }

    static let codex = NSColor(srgbRed: 16 / 255.0, green: 163 / 255.0, blue: 127 / 255.0, alpha: 1.0)
    static let claude = NSColor(srgbRed: 250 / 255.0, green: 96 / 255.0, blue: 50 / 255.0, alpha: 1.0)
    static let fable = NSColor(srgbRed: 80 / 255.0, green: 101 / 255.0, blue: 158 / 255.0, alpha: 1.0)
    static let geminiMain = NSColor(srgbRed: 66 / 255.0, green: 133 / 255.0, blue: 244 / 255.0, alpha: 1.0)
    static let geminiSecond = NSColor(srgbRed: 234 / 255.0, green: 67 / 255.0, blue: 53 / 255.0, alpha: 1.0)
    static let geminiThird = NSColor(srgbRed: 251 / 255.0, green: 188 / 255.0, blue: 5 / 255.0, alpha: 1.0)
    static let cardRadius: CGFloat = 16.0
}

/// Thin horizontal remaining fill bar (height 7pt, rounded capsule).
@MainActor
final class CompactQuotaFillBar: NSView {
    var remainingPercent: Double? = nil {
        didSet { needsDisplay = true }
    }
    var tint: NSColor = CCMBDashPalette.codex {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let radius = bounds.height / 2
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        CCMBDashPalette.track.setFill()
        trackPath.fill()

        guard let remaining = remainingPercent else { return }
        let fraction = min(max(remaining / 100.0, 0.0), 1.0)
        guard fraction > 0 else { return }
        let fillWidth = max(bounds.height, bounds.width * CGFloat(fraction))
        let fillRect = NSRect(x: bounds.minX, y: bounds.minY, width: fillWidth, height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        tint.setFill()
        fillPath.fill()
    }
}

/// 36pt rounded square service identity icon drawn with AppKit vector primitives.
@MainActor
final class CompactServiceIconView: NSView {
    enum IconKind {
        case codex
        case claude
        case gemini(color: NSColor)
    }

    var kind: IconKind = .codex {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = bounds.width * 0.26
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        switch kind {
        case .codex:
            CCMBDashPalette.codexIconBg.setFill()
            bgPath.fill()

            let w = bounds.width
            let h = bounds.height
            let teal = NSColor(srgbRed: 0.12, green: 0.82, blue: 0.62, alpha: 1.0)
            teal.setStroke()

            let chevron = NSBezierPath()
            chevron.lineWidth = w * 0.085
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: w * 0.25, y: h * 0.33))
            chevron.line(to: NSPoint(x: w * 0.46, y: h * 0.50))
            chevron.line(to: NSPoint(x: w * 0.25, y: h * 0.67))
            chevron.stroke()

            let underscore = NSBezierPath()
            underscore.lineWidth = w * 0.085
            underscore.lineCapStyle = .round
            underscore.move(to: NSPoint(x: w * 0.54, y: h * 0.68))
            underscore.line(to: NSPoint(x: w * 0.76, y: h * 0.68))
            underscore.stroke()

        case .claude:
            CCMBDashPalette.claude.setFill()
            bgPath.fill()

            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let unit = bounds.width
            let rays = 12
            NSColor.white.setStroke()
            for index in 0..<rays {
                let angle = Double(index) / Double(rays) * 2 * .pi
                let outer = (index % 2 == 0 ? 0.31 : 0.25) * unit
                let inner = 0.08 * unit
                let ray = NSBezierPath()
                ray.lineWidth = unit * 0.05
                ray.lineCapStyle = .round
                ray.move(to: NSPoint(x: center.x + CGFloat(cos(angle)) * inner, y: center.y + CGFloat(sin(angle)) * inner))
                ray.line(to: NSPoint(x: center.x + CGFloat(cos(angle)) * outer, y: center.y + CGFloat(sin(angle)) * outer))
                ray.stroke()
            }

        case .gemini(let color):
            NSColor.white.setFill()
            bgPath.fill()

            if let image = CompactServiceIconView.geminiSparkleLogo {
                NSGraphicsContext.saveGraphicsState()
                bgPath.addClip()
                let imgSize = image.size
                let drawRect: NSRect
                if imgSize.width > 0 && imgSize.height > 0 {
                    let scale = min(bounds.width / imgSize.width, bounds.height / imgSize.height)
                    let w = imgSize.width * scale
                    let h = imgSize.height * scale
                    drawRect = NSRect(
                        x: bounds.minX + (bounds.width - w) / 2.0,
                        y: bounds.minY + (bounds.height - h) / 2.0,
                        width: w,
                        height: h
                    )
                } else {
                    drawRect = bounds
                }
                image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
            }

            let strokeWidth: CGFloat = 1.5
            let borderRect = bounds.insetBy(dx: strokeWidth / 2.0, dy: strokeWidth / 2.0)
            let borderPath = NSBezierPath(
                roundedRect: borderRect,
                xRadius: max(0, radius - strokeWidth / 2.0),
                yRadius: max(0, radius - strokeWidth / 2.0)
            )
            borderPath.lineWidth = strokeWidth
            color.setStroke()
            borderPath.stroke()
        }
    }

    private static let geminiSparkleLogo: NSImage? = {
        if let bundleURL = Bundle.main.url(forResource: "GeminiLogo", withExtension: "png"),
           let image = NSImage(contentsOf: bundleURL) {
            return image
        }
        if let image = NSImage(named: "GeminiLogo") {
            return image
        }
        return nil
    }()
}

/// A single quota column (e.g. 세션, 주간, 페이블) displaying label, big 24pt colored %, and reset time.
@MainActor
final class CompactQuotaMetricColumnView: NSView {
    private let labelField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let valueField: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let resetField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(labelField)
        addSubview(valueField)
        addSubview(resetField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(label: String, value: String, color: NSColor, reset: String) {
        labelField.stringValue = label
        valueField.stringValue = value
        valueField.textColor = color
        resetField.stringValue = reset
    }

    override func draw(_ dirtyRect: NSRect) {
        labelField.textColor = CCMBDashPalette.muted
        resetField.textColor = CCMBDashPalette.muted
        super.draw(dirtyRect)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let w = bounds.width
        labelField.frame = NSRect(x: 0, y: 0, width: w, height: 15)
        valueField.frame = NSRect(x: 0, y: 15, width: w, height: 28)
        resetField.frame = NSRect(x: 0, y: 43, width: w, height: 14)
    }
}

/// Base white rounded card (16pt radius) with an AppKit chart plot view at bottom.
@MainActor
class CompactAccountCardBaseView: NSView {
    static let cardRadius: CGFloat = CCMBDashPalette.cardRadius
    let iconView = CompactServiceIconView()
    let titleLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 18, weight: .bold)
        field.textColor = CCMBDashPalette.ink
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    let accountLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        return field
    }()
    let noticeLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 10)
        field.textColor = CCMBDashPalette.muted
        field.isHidden = true
        return field
    }()
    let plotView = UsageTrendPlotView()

    var hasNotice: Bool { !noticeLabel.isHidden && !(noticeLabel.stringValue.isEmpty) }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        plotView.customPlotHeight = 52
        plotView.showsAxisLabels = false
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(accountLabel)
        addSubview(plotView)
        addSubview(noticeLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        titleLabel.textColor = CCMBDashPalette.ink
        accountLabel.textColor = CCMBDashPalette.muted
        if noticeLabel.textColor != .systemRed && noticeLabel.textColor != .systemOrange {
            noticeLabel.textColor = CCMBDashPalette.muted
        }
        super.draw(dirtyRect)
        let cardPath = NSBezierPath(roundedRect: bounds, xRadius: Self.cardRadius, yRadius: Self.cardRadius)
        CCMBDashPalette.cardBackground.setFill()
        cardPath.fill()
        if BKStyleTokens.isAccentTheme {
            NSGraphicsContext.saveGraphicsState()
            cardPath.addClip()
            BKStyleTokens.structureHairline.setFill()
            NSBezierPath(rect: NSRect(
                x: Self.cardRadius / 2,
                y: 0.5,
                width: bounds.width - Self.cardRadius,
                height: 1
            )).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        BKStyleTokens.cardRim.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()
    }
}

/// Codex Card: 139pt target height.
/// Quota row (weekly % + bar), 3-col stats (토큰 integer / 리셋권 count / 만료 dates), 24h plot.
@MainActor
final class CompactCodexCardView: CompactAccountCardBaseView {
    private let quotaColumn = CompactQuotaMetricColumnView()
    private let quotaBar = CompactQuotaFillBar()
    private let tokenLabel: NSTextField = {
        let field = NSTextField(labelWithString: "토큰")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let tokenValue: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        field.textColor = CCMBDashPalette.ink
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let voucherLabel: NSTextField = {
        let field = NSTextField(labelWithString: "리셋권")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let voucherValue: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        field.textColor = CCMBDashPalette.codex
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let expiryLabel: NSTextField = {
        let field = NSTextField(labelWithString: "리셋권 만료")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byClipping
        return field
    }()
    private let expiryValue: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = false
        return field
    }()
    private let statDivider1 = NSView()
    private let statDivider2 = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.kind = .codex
        titleLabel.stringValue = "Codex"
        accountLabel.stringValue = "본계정"

        quotaBar.tint = CCMBDashPalette.codex
        addSubview(quotaColumn)
        addSubview(quotaBar)

        statDivider1.wantsLayer = true
        statDivider1.layer?.backgroundColor = CCMBDashPalette.divider.cgColor
        statDivider2.wantsLayer = true
        statDivider2.layer?.backgroundColor = CCMBDashPalette.divider.cgColor

        [tokenLabel, tokenValue, voucherLabel, expiryValue, statDivider1, statDivider2].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        tokenLabel.textColor = CCMBDashPalette.muted
        tokenValue.textColor = CCMBDashPalette.ink
        voucherLabel.textColor = CCMBDashPalette.muted
        expiryLabel.textColor = CCMBDashPalette.muted
        expiryValue.textColor = CCMBDashPalette.muted
        statDivider1.layer?.backgroundColor = CCMBDashPalette.divider.cgColor
        statDivider2.layer?.backgroundColor = CCMBDashPalette.divider.cgColor
        super.draw(dirtyRect)
    }

    func apply(column: UsagePanelColumn, historyStrip: UsageHistoryStrip?) {
        plotView.strip = historyStrip
        let email = column.accountLines.first ?? ""
        accountLabel.stringValue = CompactDashboardView.formatAccountDisplay(email, defaultName: "본계정")

        let remainingText = column.quota?.percentText ?? "—"
        let fraction = column.quota?.fraction ?? 0
        let resetText = column.allRows.first(where: { $0.label.contains("주간 초기화") })?.value ?? ""
        quotaColumn.apply(label: "주간", value: remainingText, color: CCMBDashPalette.codex, reset: resetText)

        if let num = Double(remainingText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
            quotaBar.remainingPercent = num
        } else {
            quotaBar.remainingPercent = fraction > 0 ? fraction * 100 : nil
        }

        // Credit token balance
        if let creditRow = column.allRows.first(where: { $0.label.contains("남은 크레딧") }) {
            if creditRow.value == "무제한" {
                tokenValue.stringValue = "무제한"
            } else if let num = Double(creditRow.value.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) {
                tokenValue.stringValue = CompactDashboardView.formatGroupedInteger(num)
            } else {
                tokenValue.stringValue = creditRow.value
            }
        } else {
            tokenValue.stringValue = "—"
        }

        // Reset vouchers
        if let voucherRow = column.allRows.first(where: { $0.label.contains("리셋권") || $0.label == "초기화" }) {
            let countStr = voucherRow.value.replacingOccurrences(of: "개", with: "").trimmingCharacters(in: .whitespaces)
            voucherValue.stringValue = countStr.isEmpty ? "—" : "\(countStr)개"

            if let detail = voucherRow.detail, !detail.isEmpty {
                // Strip "만료 " and "1개 ·" prefixes
                let lines = detail.components(separatedBy: "\n").map { line in
                    var clean = line.replacingOccurrences(of: "만료 ", with: "")
                    if clean.hasPrefix("1개 · ") { clean = String(clean.dropFirst(5)) }
                    if clean.hasPrefix("1개 ·") { clean = String(clean.dropFirst(4)) }
                    return clean.trimmingCharacters(in: .whitespaces)
                }
                expiryValue.stringValue = lines.prefix(2).joined(separator: "\n")
            } else {
                expiryValue.stringValue = "없음"
            }
        } else {
            voucherValue.stringValue = "—"
            expiryValue.stringValue = "없음"
        }
        voucherLabel.stringValue = "리셋권 \(voucherValue.stringValue)"

        if !column.statusLines.isEmpty {
            noticeLabel.stringValue = column.statusLines.joined(separator: " · ")
            noticeLabel.textColor = column.statusColor
            noticeLabel.isHidden = false
        } else {
            noticeLabel.isHidden = true
        }

        let summary = "Codex 주간 남음 \(remainingText), 토큰 \(tokenValue.stringValue), 리셋권 \(voucherValue.stringValue)"
        setAccessibilityLabel(summary)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        iconView.frame = NSRect(x: pad, y: 10, width: 36, height: 36)

        let blockW: CGFloat = 236
        let blockX = w - pad - blockW
        let colW = (blockW - 2) / 3.0
        let quotaW: CGFloat = 176

        let headerTextW = max(80, blockX - (pad + 44) - 8)
        titleLabel.frame = NSRect(x: pad + 44, y: 8, width: headerTextW, height: 22)
        accountLabel.frame = NSRect(x: pad + 44, y: 31, width: headerTextW, height: 16)

        voucherLabel.frame = NSRect(x: blockX, y: 6, width: colW, height: 15)
        expiryValue.frame = NSRect(x: blockX, y: 23, width: colW, height: 32)
        statDivider1.frame = NSRect(x: blockX + colW, y: 10, width: 1, height: 48)

        quotaColumn.frame = NSRect(x: blockX + colW + 1, y: 6, width: colW, height: 57)
        statDivider2.frame = NSRect(x: blockX + colW * 2 + 1, y: 10, width: 1, height: 48)

        tokenLabel.frame = NSRect(x: blockX + colW * 2 + 2, y: 6, width: colW, height: 15)
        tokenValue.frame = NSRect(x: blockX + colW * 2 + 2, y: 23, width: colW, height: 28)

        quotaBar.frame = NSRect(x: w - pad - quotaW, y: 66, width: quotaW, height: 7)

        var plotY: CGFloat = 78
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: pad, y: plotY, width: w - pad * 2, height: 15)
            plotY += 17
        }
        plotView.frame = NSRect(x: 6, y: plotY, width: w - 12, height: max(1, bounds.height - plotY - 4))
    }
}

/// Claude Card: 139pt target height.
/// Quota row: 세션, 주간, 페이블 3 columns with fill bar for primary.
@MainActor
final class CompactClaudeCardView: CompactAccountCardBaseView {
    private let sessionColumn = CompactQuotaMetricColumnView()
    private let weekColumn = CompactQuotaMetricColumnView()
    private let fableColumn = CompactQuotaMetricColumnView()
    private let divider1 = NSView()
    private let divider2 = NSView()
    private let quotaBar = CompactQuotaFillBar()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.kind = .claude
        titleLabel.stringValue = "Claude"
        accountLabel.stringValue = "본계정"

        divider1.wantsLayer = true
        divider1.layer?.backgroundColor = CCMBDashPalette.divider.cgColor
        divider2.wantsLayer = true
        divider2.layer?.backgroundColor = CCMBDashPalette.divider.cgColor

        quotaBar.tint = CCMBDashPalette.claude
        [fableColumn, divider1, sessionColumn, divider2, weekColumn, quotaBar].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        divider1.layer?.backgroundColor = CCMBDashPalette.divider.cgColor
        divider2.layer?.backgroundColor = CCMBDashPalette.divider.cgColor
        super.draw(dirtyRect)
    }

    func apply(column: UsagePanelColumn, historyStrip: UsageHistoryStrip?) {
        plotView.strip = historyStrip
        let email = column.accountLines.first ?? ""
        accountLabel.stringValue = CompactDashboardView.formatAccountDisplay(email, defaultName: "본계정")

        let sessionPercent = column.quota?.percentText ?? "—"
        let sessionReset = column.allRows.first(where: { $0.label.contains("세션 초기화") })?.value ?? ""
        sessionColumn.apply(label: "세션", value: sessionPercent, color: CCMBDashPalette.claude, reset: sessionReset)

        let weekQuota = column.tertiaryQuota ?? column.secondaryQuota
        let weekPercent = weekQuota?.percentText ?? "—"
        let weekReset = column.allRows.first(where: { $0.label.contains("주간 초기화") })?.value ?? ""
        weekColumn.apply(label: "주간", value: weekPercent, color: CCMBDashPalette.claude, reset: weekReset)

        let fableQuota = column.tertiaryQuota != nil ? column.secondaryQuota : nil
        let fablePercent = fableQuota?.percentText ?? "—"
        let fableReset = column.allRows.first(where: { $0.label.contains("Fable 초기화") })?.value ?? ""
        fableColumn.apply(label: "페이블", value: fablePercent, color: CCMBDashPalette.fable, reset: fableReset)

        if let num = Double(sessionPercent.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
            quotaBar.remainingPercent = num
        } else {
            quotaBar.remainingPercent = (column.quota?.fraction ?? 0) * 100
        }

        if !column.statusLines.isEmpty {
            noticeLabel.stringValue = column.statusLines.joined(separator: " · ")
            noticeLabel.textColor = column.statusColor
            noticeLabel.isHidden = false
        } else {
            noticeLabel.isHidden = true
        }

        let summary = "Claude 페이블 남음 \(fablePercent), 세션 \(sessionPercent), 주간 \(weekPercent)"
        setAccessibilityLabel(summary)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        iconView.frame = NSRect(x: pad, y: 10, width: 36, height: 36)

        let blockW: CGFloat = 236
        let blockX = w - pad - blockW
        let colW = (blockW - 2) / 3.0

        let headerTextW = max(80, blockX - (pad + 44) - 8)
        titleLabel.frame = NSRect(x: pad + 44, y: 8, width: headerTextW, height: 22)
        accountLabel.frame = NSRect(x: pad + 44, y: 31, width: headerTextW, height: 16)

        fableColumn.frame = NSRect(x: blockX, y: 6, width: colW, height: 57)
        divider1.frame = NSRect(x: blockX + colW, y: 10, width: 1, height: 48)

        sessionColumn.frame = NSRect(x: blockX + colW + 1, y: 6, width: colW, height: 57)
        divider2.frame = NSRect(x: blockX + colW * 2 + 1, y: 10, width: 1, height: 48)

        weekColumn.frame = NSRect(x: blockX + colW * 2 + 2, y: 6, width: colW, height: 57)

        let barW: CGFloat = 176
        quotaBar.frame = NSRect(x: w - pad - barW, y: 66, width: barW, height: 7)

        var plotY: CGFloat = 78
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: pad, y: plotY, width: w - pad * 2, height: 15)
            plotY += 17
        }
        plotView.frame = NSRect(x: 6, y: plotY, width: w - 12, height: max(1, bounds.height - plotY - 4))
    }
}

/// Gemini Card: 132pt target height.
/// Quota row: 세션, 주간 2 columns with fill bar for primary.
@MainActor
final class CompactGeminiCardView: CompactAccountCardBaseView {
    private let sessionColumn = CompactQuotaMetricColumnView()
    private let weekColumn = CompactQuotaMetricColumnView()
    private let divider = NSView()
    private let quotaBar = CompactQuotaFillBar()
    private let accountColor: NSColor

    init(frame frameRect: NSRect, accountTitle: String, color: NSColor) {
        self.accountColor = color
        super.init(frame: frameRect)
        iconView.kind = .gemini(color: color)
        titleLabel.stringValue = "Gemini"
        accountLabel.stringValue = accountTitle

        divider.wantsLayer = true
        divider.layer?.backgroundColor = CCMBDashPalette.divider.cgColor

        quotaBar.tint = color
        [sessionColumn, divider, weekColumn, quotaBar].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(
        email: String?,
        sessionPercent: String,
        sessionReset: String,
        weekPercent: String,
        weekReset: String,
        statusText: String?,
        statusColor: NSColor,
        historyStrip: UsageHistoryStrip?
    ) {
        plotView.strip = historyStrip
        if let email, !email.isEmpty {
            accountLabel.stringValue = CompactDashboardView.formatAccountDisplay(email, defaultName: accountLabel.stringValue)
        }

        sessionColumn.apply(label: "세션", value: sessionPercent, color: accountColor, reset: sessionReset)
        weekColumn.apply(label: "주간", value: weekPercent, color: accountColor, reset: weekReset)

        if let num = Double(sessionPercent.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
            quotaBar.remainingPercent = num
        } else {
            quotaBar.remainingPercent = nil
        }

        if let statusText, !statusText.isEmpty {
            noticeLabel.stringValue = statusText
            noticeLabel.textColor = statusColor
            noticeLabel.isHidden = false
        } else {
            noticeLabel.isHidden = true
        }

        let summary = "Gemini \(accountLabel.stringValue) 세션 남음 \(sessionPercent), 주간 \(weekPercent)"
        setAccessibilityLabel(summary)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        iconView.frame = NSRect(x: pad, y: 10, width: 36, height: 36)

        let blockW: CGFloat = 236
        let blockX = w - pad - blockW
        let colW = (blockW - 2) / 3.0

        let headerTextW = max(80, blockX - (pad + 44) - 8)
        titleLabel.frame = NSRect(x: pad + 44, y: 8, width: headerTextW, height: 22)
        accountLabel.frame = NSRect(x: pad + 44, y: 31, width: headerTextW, height: 16)

        sessionColumn.frame = NSRect(x: blockX + colW + 1, y: 6, width: colW, height: 57)
        divider.frame = NSRect(x: blockX + colW * 2 + 1, y: 10, width: 1, height: 48)
        weekColumn.frame = NSRect(x: blockX + colW * 2 + 2, y: 6, width: colW, height: 57)

        let barW: CGFloat = 176
        quotaBar.frame = NSRect(x: w - pad - barW, y: 66, width: barW, height: 7)

        var plotY: CGFloat = 78
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: pad, y: plotY, width: w - pad * 2, height: 15)
            plotY += 17
        }
        plotView.frame = NSRect(x: 6, y: plotY, width: w - 12, height: max(1, bounds.height - plotY - 4))
    }
}

/// The entire narrow 440pt pale ice blue dashboard view containing 5 stacked white cards.
@MainActor
final class CompactDashboardView: NSView {
    static let viewWidth: CGFloat = 440.0
    static let cardGap: CGFloat = 8.0
    static let sidePadding: CGFloat = 10.0

    let codexCard = CompactCodexCardView()
    let claudeCard = CompactClaudeCardView()
    let geminiMainCard = CompactGeminiCardView(frame: .zero, accountTitle: "본계정", color: CCMBDashPalette.geminiMain)
    let geminiSecondCard = CompactGeminiCardView(frame: .zero, accountTitle: "부계정", color: CCMBDashPalette.geminiSecond)
    let geminiThirdCard = CompactGeminiCardView(frame: .zero, accountTitle: "세 번째 계정", color: CCMBDashPalette.geminiThird)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: 840))
        [codexCard, claudeCard, geminiMainCard, geminiSecondCard, geminiThirdCard].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let gradient = NSGradient(starting: CCMBDashPalette.canvasTop, ending: CCMBDashPalette.canvasBottom)
        gradient?.draw(in: bounds, angle: 90.0)
    }

    static func formatAccountDisplay(_ raw: String, defaultName: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "계정 정보 없음" { return defaultName }
        var email = clean
        for prefix in ["본계정 ", "부계정 ", "세 번째 계정 ", "세 번째 ", "계정 "] {
            if email.hasPrefix(prefix) {
                email = String(email.dropFirst(prefix.count))
                break
            }
        }
        if let atIndex = email.firstIndex(of: "@") {
            let local = String(email[email.startIndex..<atIndex])
            return local.isEmpty ? defaultName : local
        }
        return email.isEmpty ? defaultName : email
    }

    static func formatGroupedInteger(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.roundingMode = .down
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value.rounded(.towardZero))
    }

    func apply(
        model: UsagePanelModel,
        codexHistory: UsageHistoryStrip?,
        claudeHistory: UsageHistoryStrip?,
        geminiHistory: UsageHistoryStrip?
    ) {
        // 1. Codex Card
        codexCard.apply(column: model.codex, historyStrip: codexHistory)

        // 2. Claude Card
        claudeCard.apply(column: model.claude, historyStrip: claudeHistory)

        // 3. Extract individual Gemini account strips if available
        let (geminiMainStrip, geminiSecondStrip, geminiThirdStrip) = splitGeminiStrip(geminiHistory)

        // Gemini columns helper
        let geminiCol = model.gemini
        func resetValue(_ keys: [String]) -> String {
            geminiCol.allRows.first(where: { row in keys.contains(where: { row.label.contains($0) }) })?.value ?? ""
        }

        let mainEmail = geminiCol.accountLines.first(where: { $0.contains("본") }) ?? geminiCol.accountLines.first
        geminiMainCard.apply(
            email: mainEmail,
            sessionPercent: geminiCol.quota?.percentText ?? "—",
            sessionReset: resetValue(["본 세션", "C세션 초기화"]),
            weekPercent: geminiCol.secondaryQuota?.percentText ?? "—",
            weekReset: resetValue(["본 주간", "C주간 초기화"]),
            statusText: geminiCol.statusLines.first(where: { $0.contains("본계정") }),
            statusColor: geminiCol.statusColor,
            historyStrip: geminiMainStrip
        )

        let secondEmail = geminiCol.accountLines.first(where: { $0.contains("부") }) ?? (geminiCol.accountLines.count > 1 ? geminiCol.accountLines[1] : nil)
        geminiSecondCard.apply(
            email: secondEmail,
            sessionPercent: geminiCol.tertiaryQuota?.percentText ?? "—",
            sessionReset: resetValue(["부 세션", "O세션 초기화"]),
            weekPercent: geminiCol.quaternaryQuota?.percentText ?? "—",
            weekReset: resetValue(["부 주간", "O주간 초기화"]),
            statusText: geminiCol.statusLines.first(where: { $0.contains("부계정") }),
            statusColor: geminiCol.statusColor,
            historyStrip: geminiSecondStrip
        )

        let session3 = geminiCol.supplementalQuotas.first
        let week3 = geminiCol.supplementalQuotas.count > 1 ? geminiCol.supplementalQuotas[1] : nil
        let hasThird = session3 != nil || geminiCol.accountLines.contains(where: { $0.hasPrefix("세 번째") })
        let thirdEmail = geminiCol.accountLines.first(where: { $0.hasPrefix("세 번째") })
        geminiThirdCard.apply(
            email: thirdEmail,
            sessionPercent: session3?.percentText ?? (hasThird ? "—" : "미등록"),
            sessionReset: resetValue(["3 세션"]),
            weekPercent: week3?.percentText ?? (hasThird ? "—" : "미등록"),
            weekReset: resetValue(["3 주간"]),
            statusText: geminiCol.statusLines.first(where: { $0.contains("세 번째") }),
            statusColor: geminiCol.statusColor,
            historyStrip: geminiThirdStrip
        )

        layoutCards()
    }

    private func splitGeminiStrip(_ full: UsageHistoryStrip?) -> (main: UsageHistoryStrip?, second: UsageHistoryStrip?, third: UsageHistoryStrip?) {
        guard let full else { return (nil, nil, nil) }
        guard full.series.count > 1 else {
            return (full, nil, nil)
        }
        func singleSeriesStrip(from series: UsageHistorySeries) -> UsageHistoryStrip {
            UsageHistoryStrip(
                caption: "\(series.label) \(series.samples.last.map { UsageConsumptionCore.amountTitle($0.amount, unit: full.unitSuffix) } ?? "—")",
                series: [series],
                slotCount: full.slotCount,
                unitSuffix: full.unitSuffix,
                accessibilityValue: "\(series.label) 24시간 사용 기록",
                sourceNote: full.sourceNote
            )
        }
        var main: UsageHistoryStrip? = nil
        var second: UsageHistoryStrip? = nil
        var third: UsageHistoryStrip? = nil

        for s in full.series {
            if s.label.contains("본") || s.color == CCMBDashPalette.geminiMain {
                main = singleSeriesStrip(from: s)
            } else if s.label.contains("부") || s.color == CCMBDashPalette.geminiSecond {
                second = singleSeriesStrip(from: s)
            } else if s.label.contains("세") || s.color == CCMBDashPalette.geminiThird {
                third = singleSeriesStrip(from: s)
            }
        }
        if main == nil, !full.series.isEmpty { main = singleSeriesStrip(from: full.series[0]) }
        if second == nil, full.series.count > 1 { second = singleSeriesStrip(from: full.series[1]) }
        if third == nil, full.series.count > 2 { third = singleSeriesStrip(from: full.series[2]) }
        return (main, second, third)
    }

    private func layoutCards() {
        let cardW = Self.viewWidth - Self.sidePadding * 2
        var y: CGFloat = 8

        let codexH: CGFloat = codexCard.hasNotice ? 170 : 154
        codexCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: codexH)
        y += codexH + Self.cardGap

        let claudeH: CGFloat = claudeCard.hasNotice ? 170 : 154
        claudeCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: claudeH)
        y += claudeH + Self.cardGap

        let geminiMainH: CGFloat = geminiMainCard.hasNotice ? 164 : 148
        geminiMainCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: geminiMainH)
        y += geminiMainH + Self.cardGap

        let geminiSecondH: CGFloat = geminiSecondCard.hasNotice ? 164 : 148
        geminiSecondCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: geminiSecondH)
        y += geminiSecondH + Self.cardGap

        let geminiThirdH: CGFloat = geminiThirdCard.hasNotice ? 164 : 148
        geminiThirdCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: geminiThirdH)
        y += geminiThirdH + 8

        frame = NSRect(x: 0, y: 0, width: Self.viewWidth, height: y)
        needsDisplay = true
    }
}
