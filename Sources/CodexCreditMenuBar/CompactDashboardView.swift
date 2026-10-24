import AppKit

/// Color palette and style tokens for the iPhone-style light dashboard.
enum CCMBDashPalette {
    static let canvasTop = NSColor(srgbRed: 240 / 255.0, green: 249 / 255.0, blue: 253 / 255.0, alpha: 1.0)
    static let canvasBottom = NSColor(srgbRed: 233 / 255.0, green: 246 / 255.0, blue: 254 / 255.0, alpha: 1.0)
    static let cardBackground = NSColor.white
    static let ink = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
    static let muted = NSColor(srgbRed: 0.345, green: 0.424, blue: 0.627, alpha: 1.0)
    static let track = NSColor(srgbRed: 229 / 255.0, green: 233 / 255.0, blue: 238 / 255.0, alpha: 1.0)
    static let divider = NSColor(srgbRed: 0.89, green: 0.91, blue: 0.945, alpha: 1.0)
    static let codexIconBg = NSColor(srgbRed: 2 / 255.0, green: 23 / 255.0, blue: 44 / 255.0, alpha: 1.0)

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

        case .gemini:
            // User-supplied multicolor Gemini sparkle PNG identically on all three Gemini cards
            if let image = CompactServiceIconView.geminiSparkleLogo {
                let insetRatio: CGFloat = 0.08
                let drawRect = bounds.insetBy(dx: bounds.width * insetRatio, dy: bounds.height * insetRatio)
                image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else {
                CCMBDashPalette.cardBackground.setFill()
                bgPath.fill()
            }
        }
    }

    private static let geminiSparkleLogo: NSImage? = {
        // Try Bundle resources first
        if let bundleURL = Bundle.main.url(forResource: "GeminiLogo", withExtension: "png"),
           let image = NSImage(contentsOf: bundleURL) {
            return image
        }
        // Fallback to local workspace Assets folder
        let localPath = "/Users/armsone/git/CCMB-MacOS/Assets/GeminiLogo.png"
        if let image = NSImage(contentsOfFile: localPath) {
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
        return field
    }()
    private let valueField: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 24, weight: .bold)
        field.alignment = .center
        return field
    }()
    private let resetField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
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

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let w = bounds.width
        labelField.frame = NSRect(x: 0, y: 0, width: w, height: 13)
        valueField.frame = NSRect(x: 0, y: 13, width: w, height: 26)
        resetField.frame = NSRect(x: 0, y: 39, width: w, height: 12)
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
        return field
    }()
    let accountLabel: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
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
        super.draw(dirtyRect)
        let cardPath = NSBezierPath(roundedRect: bounds, xRadius: Self.cardRadius, yRadius: Self.cardRadius)
        CCMBDashPalette.cardBackground.setFill()
        cardPath.fill()
    }
}

/// Codex Card: 173pt target height.
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
        return field
    }()
    private let tokenValue: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        field.textColor = CCMBDashPalette.ink
        field.alignment = .center
        return field
    }()
    private let voucherLabel: NSTextField = {
        let field = NSTextField(labelWithString: "리셋권")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        return field
    }()
    private let voucherValue: NSTextField = {
        let field = NSTextField(labelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 20, weight: .bold)
        field.textColor = CCMBDashPalette.codex
        field.alignment = .center
        return field
    }()
    private let expiryLabel: NSTextField = {
        let field = NSTextField(labelWithString: "리셋권 만료")
        field.font = .systemFont(ofSize: 12)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
        return field
    }()
    private let expiryValue: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "—")
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        field.textColor = CCMBDashPalette.muted
        field.alignment = .center
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

        [tokenLabel, tokenValue, voucherLabel, voucherValue, expiryLabel, expiryValue, statDivider1, statDivider2].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        titleLabel.frame = NSRect(x: pad + 44, y: 10, width: 140, height: 20)
        accountLabel.frame = NSRect(x: pad + 44, y: 30, width: 140, height: 14)

        let quotaW: CGFloat = 176
        quotaColumn.frame = NSRect(x: w - pad - quotaW, y: 8, width: quotaW, height: 51)
        quotaBar.frame = NSRect(x: w - pad - quotaW, y: 61, width: quotaW, height: 7)

        // 3-column stats
        let statsY: CGFloat = 72
        let statColW = (w - pad * 2) / 3.0
        tokenLabel.frame = NSRect(x: pad, y: statsY, width: statColW, height: 14)
        tokenValue.frame = NSRect(x: pad, y: statsY + 14, width: statColW, height: 24)

        statDivider1.frame = NSRect(x: pad + statColW - 0.5, y: statsY + 2, width: 1, height: 34)

        voucherLabel.frame = NSRect(x: pad + statColW, y: statsY, width: statColW, height: 14)
        voucherValue.frame = NSRect(x: pad + statColW, y: statsY + 14, width: statColW, height: 24)

        statDivider2.frame = NSRect(x: pad + statColW * 2 - 0.5, y: statsY + 2, width: 1, height: 34)

        expiryLabel.frame = NSRect(x: pad + statColW * 2, y: statsY, width: statColW, height: 14)
        expiryValue.frame = NSRect(x: pad + statColW * 2, y: statsY + 14, width: statColW, height: 26)

        var plotY: CGFloat = 114
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: pad, y: plotY, width: w - pad * 2, height: 14)
            plotY += 16
        }
        plotView.frame = NSRect(x: 6, y: plotY, width: w - 12, height: bounds.height - plotY - 4)
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
        [sessionColumn, divider1, weekColumn, divider2, fableColumn, quotaBar].forEach(addSubview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

        let summary = "Claude 세션 남음 \(sessionPercent), 주간 \(weekPercent), 페이블 \(fablePercent)"
        setAccessibilityLabel(summary)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        iconView.frame = NSRect(x: pad, y: 10, width: 36, height: 36)
        titleLabel.frame = NSRect(x: pad + 44, y: 10, width: 140, height: 20)
        accountLabel.frame = NSRect(x: pad + 44, y: 30, width: 140, height: 14)

        let blockW: CGFloat = 236
        let blockX = w - pad - blockW
        let colW = (blockW - 2) / 3.0

        sessionColumn.frame = NSRect(x: blockX, y: 8, width: colW, height: 51)
        divider1.frame = NSRect(x: blockX + colW, y: 14, width: 1, height: 38)

        weekColumn.frame = NSRect(x: blockX + colW + 1, y: 8, width: colW, height: 51)
        divider2.frame = NSRect(x: blockX + colW * 2 + 1, y: 14, width: 1, height: 38)

        fableColumn.frame = NSRect(x: blockX + colW * 2 + 2, y: 8, width: colW, height: 51)

        let barW: CGFloat = 176
        quotaBar.frame = NSRect(x: w - pad - barW, y: 61, width: barW, height: 7)

        var plotY: CGFloat = 72
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: pad, y: plotY, width: w - pad * 2, height: 14)
            plotY += 16
        }
        plotView.frame = NSRect(x: 6, y: plotY, width: w - 12, height: bounds.height - plotY - 4)
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
        titleLabel.frame = NSRect(x: pad + 44, y: 10, width: 140, height: 20)
        accountLabel.frame = NSRect(x: pad + 44, y: 30, width: 140, height: 14)

        let blockW: CGFloat = 176
        let blockX = w - pad - blockW
        let colW = (blockW - 1) / 2.0

        sessionColumn.frame = NSRect(x: blockX, y: 8, width: colW, height: 51)
        divider.frame = NSRect(x: blockX + colW, y: 14, width: 1, height: 38)
        weekColumn.frame = NSRect(x: blockX + colW + 1, y: 8, width: colW, height: 51)

        quotaBar.frame = NSRect(x: blockX, y: 61, width: blockW, height: 7)

        var plotY: CGFloat = 72
        if !noticeLabel.isHidden {
            noticeLabel.frame = NSRect(x: pad, y: plotY, width: w - pad * 2, height: 14)
            plotY += 16
        }
        plotView.frame = NSRect(x: 6, y: plotY, width: w - 12, height: bounds.height - plotY - 4)
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

        let codexH: CGFloat = 173
        codexCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: codexH)
        y += codexH + Self.cardGap

        let claudeH: CGFloat = 139
        claudeCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: claudeH)
        y += claudeH + Self.cardGap

        let geminiH: CGFloat = 132
        geminiMainCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: geminiH)
        y += geminiH + Self.cardGap

        geminiSecondCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: geminiH)
        y += geminiH + Self.cardGap

        geminiThirdCard.frame = NSRect(x: Self.sidePadding, y: y, width: cardW, height: geminiH)
        y += geminiH + 8

        frame = NSRect(x: 0, y: 0, width: Self.viewWidth, height: y)
        needsDisplay = true
    }
}
