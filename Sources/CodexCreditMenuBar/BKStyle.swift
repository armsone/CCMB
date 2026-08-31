import AppKit

/// Selectable visual theme for the usage panel. `기본` preserves the
/// pre-redesign translucent look; `BK Style` layers restrained modern
/// skeuomorphism on the same layout: enamel card surfaces, glossy charcoal
/// structure, thin chrome hairlines, and one structural signal-red accent.
/// Every BK-specific color/gradient/well lives in `BKStyleTokens`, so the
/// theme is fully reversible from this one file.
enum UsagePanelTheme: String, CaseIterable {
    case classic
    case bk

    var displayName: String {
        switch self {
        case .classic: return "기본"
        case .bk: return "BK Style"
        }
    }
}

enum UsagePanelThemeStore {
    static let defaultsKey = "usagePanelThemeV1"

    /// BK Style is the default for this user-directed redesign; a stored
    /// explicit choice (including `기본`) always wins afterward.
    static var current: UsagePanelTheme {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let theme = UsagePanelTheme(rawValue: raw)
            else { return .bk }
            return theme
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// Central BK Style material tokens. Colors are appearance-dynamic so the
/// enamel/charcoal relationship holds in both light and dark mode without
/// any view doing its own appearance checks.
enum BKStyleTokens {
    /// Signature structural accent. Used only for selected/active markers
    /// (the "사용 중" tag, the selected theme), never as decoration.
    static let signalRed = NSColor(srgbRed: 0xE4 / 255.0, green: 0x1E / 255.0, blue: 0x25 / 255.0, alpha: 1)

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// White enamel: the strongest surface, carrying the provider cards.
    static let enamelSurfaceTop = dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
        dark: NSColor(srgbRed: 0.20, green: 0.21, blue: 0.22, alpha: 0.92)
    )
    static let enamelSurfaceBottom = dynamic(
        light: NSColor(srgbRed: 0.955, green: 0.955, blue: 0.96, alpha: 0.92),
        dark: NSColor(srgbRed: 0.155, green: 0.16, blue: 0.17, alpha: 0.92)
    )

    /// Slightly recessed enamel used inside icon wells.
    static let wellFill = dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1),
        dark: NSColor(srgbRed: 0.24, green: 0.25, blue: 0.26, alpha: 1)
    )

    /// Glossy charcoal ink for technical structure: glyphs and group titles.
    static let charcoalInk = dynamic(
        light: NSColor(srgbRed: 0.19, green: 0.20, blue: 0.22, alpha: 1),
        dark: NSColor(srgbRed: 0.86, green: 0.87, blue: 0.88, alpha: 1)
    )

    /// Chrome is limited to precise thin rims and dividers.
    static let chromeLine = dynamic(
        light: NSColor(white: 0, alpha: 0.16),
        dark: NSColor(white: 1, alpha: 0.17)
    )
    static let chromeHighlight = dynamic(
        light: NSColor(white: 1, alpha: 0.85),
        dark: NSColor(white: 1, alpha: 0.10)
    )
    static let contactShadow = dynamic(
        light: NSColor(white: 0, alpha: 0.10),
        dark: NSColor(white: 0, alpha: 0.42)
    )

    /// One enamel card with a chrome rim, a controlled top highlight, and a
    /// hairline contact shadow. Depth stays restrained: no oversized bevels,
    /// no candy gloss.
    static func drawCard(in rect: NSRect, radius: CGFloat) {
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        // Contact shadow: a soft hairline directly under the card only.
        contactShadow.setFill()
        NSBezierPath(
            roundedRect: rect.offsetBy(dx: 0, dy: 1).insetBy(dx: 1.5, dy: 0),
            xRadius: radius,
            yRadius: radius
        ).fill()

        if let gradient = NSGradient(starting: enamelSurfaceTop, ending: enamelSurfaceBottom) {
            gradient.draw(in: path, angle: -90)
        } else {
            enamelSurfaceTop.setFill()
            path.fill()
        }

        // Top highlight kept inside the rim.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        chromeHighlight.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX + radius / 2, y: rect.minY + 0.5, width: rect.width - radius, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        chromeLine.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// Small enamel icon well with a thin chrome rim, shared by every
    /// principal section title.
    static func drawIconWell(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        wellFill.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        chromeHighlight.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX + 2, y: rect.minY + 0.5, width: rect.width - 4, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        chromeLine.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Code-drawn 16pt glyph vocabulary for section titles. Drawn by hand (like
/// the existing provider marks) so the deployment target never depends on
/// SF Symbols availability, and every glyph shares one stroke weight.
enum BKIconGlyph {
    /// Dial with a needle — usage/quota.
    case gauge
    /// Clock face — reset schedules.
    case clock
    /// Card outline with a stripe — credits/spend.
    case creditCard
    /// Three bars — per-model limits and estimates.
    case chart
    /// Prompt chevron — a local CLI source.
    case terminal
    /// Circle with meridians — a web source.
    case globe
}

/// The icon-well unit: an enamel/chrome well (BK theme) or a bare glyph
/// (기본 theme), always drawn in charcoal ink at one shared optical scale.
final class BKIconWellView: NSView {
    var glyph: BKIconGlyph = .gauge { didSet { needsDisplay = true } }
    var theme: UsagePanelTheme = .classic { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let wellRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        if theme == .bk {
            BKStyleTokens.drawIconWell(in: wellRect)
        }
        let ink = theme == .bk ? BKStyleTokens.charcoalInk : NSColor.secondaryLabelColor
        drawGlyph(in: bounds.insetBy(dx: 3.5, dy: 3.5), ink: ink)
    }

    private func drawGlyph(in rect: NSRect, ink: NSColor) {
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        switch glyph {
        case .gauge:
            // Open dial arc plus a needle to the upper right. Angles are in
            // the flipped coordinate space, so "up" is a negative-y sweep.
            path.appendArc(withCenter: center, radius: radius, startAngle: 200, endAngle: -20, clockwise: true)
            path.move(to: center)
            path.line(to: NSPoint(x: center.x + radius * 0.62, y: center.y - radius * 0.62))
        case .clock:
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            path.move(to: center)
            path.line(to: NSPoint(x: center.x, y: center.y - radius * 0.58))
            path.move(to: center)
            path.line(to: NSPoint(x: center.x + radius * 0.42, y: center.y + radius * 0.18))
        case .creditCard:
            let card = NSRect(
                x: rect.minX,
                y: rect.minY + rect.height * 0.16,
                width: rect.width,
                height: rect.height * 0.68
            )
            path.appendRoundedRect(card, xRadius: 1.5, yRadius: 1.5)
            path.move(to: NSPoint(x: card.minX, y: card.minY + card.height * 0.34))
            path.line(to: NSPoint(x: card.maxX, y: card.minY + card.height * 0.34))
        case .chart:
            let baseline = rect.maxY
            let heights: [CGFloat] = [0.45, 0.8, 0.6]
            let step = rect.width / 3
            for (index, height) in heights.enumerated() {
                let x = rect.minX + step * (CGFloat(index) + 0.5)
                path.move(to: NSPoint(x: x, y: baseline))
                path.line(to: NSPoint(x: x, y: baseline - rect.height * height))
            }
        case .terminal:
            path.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
            path.line(to: NSPoint(x: rect.minX + rect.width * 0.42, y: rect.midY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY - rect.height * 0.2))
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.12))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.12))
        case .globe:
            path.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            path.move(to: NSPoint(x: rect.minX, y: center.y))
            path.line(to: NSPoint(x: rect.maxX, y: center.y))
            path.appendOval(in: NSRect(
                x: center.x - radius * 0.45,
                y: rect.minY,
                width: radius * 0.9,
                height: rect.height
            ))
        }

        ink.setStroke()
        path.stroke()
    }
}
