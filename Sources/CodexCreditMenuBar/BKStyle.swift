import AppKit

/// Selectable visual theme for the usage panel based on Byungki-style themes.
/// Requested themes and order: light, friday, jarvis, ultron.
enum UsagePanelTheme: String, CaseIterable {
    case light = "light"
    case friday = "friday"
    case jarvis = "jarvis"
    case ultron = "ultron"

    var displayName: String {
        switch self {
        case .light: return "라이트"
        case .friday: return "프라이데이"
        case .jarvis: return "자비스"
        case .ultron: return "울트론"
        }
    }

    var isDark: Bool {
        switch self {
        case .light, .friday: return false
        case .jarvis, .ultron: return true
        }
    }

    var nextTheme: UsagePanelTheme {
        switch self {
        case .light: return .friday
        case .friday: return .jarvis
        case .jarvis: return .ultron
        case .ultron: return .light
        }
    }

    var palette: BKThemePalette {
        switch self {
        case .light: return .light
        case .friday: return .friday
        case .jarvis: return .jarvis
        case .ultron: return .ultron
        }
    }
}

/// Official Byungki-style palette token set
struct BKThemePalette {
    let bg: NSColor
    let card: NSColor
    let surface: NSColor
    let surface2: NSColor
    let text: NSColor
    let text2: NSColor
    let muted: NSColor
    let border: NSColor
    let border2: NSColor
    let accent: NSColor
    let accentStrong: NSColor
    let accentSoft: NSColor
    let onAccent: NSColor
    let warn: NSColor
    let warnSoft: NSColor
    let warnInk: NSColor
    let danger: NSColor
    let dangerSoft: NSColor

    private static func color(_ hex: UInt32) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xff) / 255.0
        let g = CGFloat((hex >> 8) & 0xff) / 255.0
        let b = CGFloat(hex & 0xff) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    static let light = BKThemePalette(
        bg: color(0xf5f4f0),
        card: color(0xfbfaf7),
        surface: color(0xffffff),
        surface2: color(0xecebe4),
        text: color(0x1f211c),
        text2: color(0x4a4c44),
        muted: color(0x666860),
        border: color(0xe2dfd5),
        border2: color(0xd0cdc0),
        accent: color(0x5c6b3c),
        accentStrong: color(0x46532c),
        accentSoft: color(0xe8ebdb),
        onAccent: color(0xffffff),
        warn: color(0x9c5415),
        warnSoft: color(0xf7e9d8),
        warnInk: color(0x6d3c10),
        danger: color(0x9c3b2a),
        dangerSoft: color(0xf6e3de)
    )

    static let friday = BKThemePalette(
        bg: color(0xf7efe3),
        card: color(0xfffaf1),
        surface: color(0xfffdf8),
        surface2: color(0xf0e2cc),
        text: color(0x2a1f16),
        text2: color(0x55422f),
        muted: color(0x725b45),
        border: color(0xe8d8c0),
        border2: color(0xd3bb98),
        accent: color(0x9a4a12),
        accentStrong: color(0x743508),
        accentSoft: color(0xf6dfc0),
        onAccent: color(0xffffff),
        warn: color(0x8a5a00),
        warnSoft: color(0xf8e6b8),
        warnInk: color(0x6d3c10),
        danger: color(0xa3204a),
        dangerSoft: color(0xf8dce4)
    )

    static let jarvis = BKThemePalette(
        bg: color(0x071a33),
        card: color(0x0c2748),
        surface: color(0x11335d),
        surface2: color(0x173f70),
        text: color(0xe3edf7),
        text2: color(0xb9cde3),
        muted: color(0x93abc6),
        border: color(0x1d4d7a),
        border2: color(0x2b87b0),
        accent: color(0x35c8f0),
        accentStrong: color(0x8fe3fa),
        accentSoft: color(0x0e3a5c),
        onAccent: color(0x04202b),
        warn: color(0xf0b45c),
        warnSoft: color(0x3a2d16),
        warnInk: color(0xf4cf94),
        danger: color(0xf28b82),
        dangerSoft: color(0x3d2126)
    )

    static let ultron = BKThemePalette(
        bg: color(0x0f1012),
        card: color(0x1a1b1e),
        surface: color(0x222326),
        surface2: color(0x2b2c30),
        text: color(0xe6e7ea),
        text2: color(0xb8bbc2),
        muted: color(0x8e929b),
        border: color(0x3a2a2e),
        border2: color(0x8a2c3a),
        accent: color(0xdc4057),
        accentStrong: color(0xff7a88),
        accentSoft: color(0x3a1519),
        onAccent: color(0xffffff),
        warn: color(0xe8a24f),
        warnSoft: color(0x36291a),
        warnInk: color(0xf2c27f),
        danger: color(0xff9a9a),
        dangerSoft: color(0x3e1f22)
    )
}

enum UsagePanelThemeStore {
    static let defaultsKey = "usagePanelThemeV1"

    /// Migrates old stored strings safely to the 4 Byungki style themes:
    /// - classic, daytime -> light
    /// - bk, night, dark -> jarvis
    /// - casual -> friday
    /// - light -> light
    /// - friday -> friday
    /// - jarvis -> jarvis
    /// - ultron -> ultron
    /// - unknown/default -> light
    static func migrate(raw: String?) -> UsagePanelTheme {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .light
        }
        switch raw {
        case "light", "라이트", "밝은":
            return .light
        case "friday", "프라이데이":
            return .friday
        case "jarvis", "자비스":
            return .jarvis
        case "ultron", "울트론":
            return .ultron
        case "classic", "daytime", "기본":
            return .light
        case "bk", "bk style", "night", "dark", "어두운", "중간", "medium":
            return .jarvis
        case "casual":
            return .friday
        default:
            return .light
        }
    }

    private static var _current: UsagePanelTheme = {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        let theme = migrate(raw: stored)
        // Persist immediately before first frame if migrated or missing
        if stored != theme.rawValue {
            UserDefaults.standard.set(theme.rawValue, forKey: defaultsKey)
        }
        return theme
    }()

    static var current: UsagePanelTheme {
        get {
            return _current
        }
        set {
            _current = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// Central BK Style material tokens driven by the current theme palette.
enum BKStyleTokens {
    static var currentPalette: BKThemePalette { UsagePanelThemeStore.current.palette }

    /// Structural accent / signal color from theme palette
    static var signalRed: NSColor { currentPalette.accent }

    static var enamelSurfaceTop: NSColor { currentPalette.card }
    static var enamelSurfaceBottom: NSColor { currentPalette.surface }
    static var panelBackground: NSColor { currentPalette.bg }
    static var wellFill: NSColor { currentPalette.surface2 }

    static var charcoalInk: NSColor { currentPalette.text }
    static var bodyInk: NSColor { currentPalette.text }
    static var secondaryInk: NSColor { currentPalette.text2 }
    static var mutedInk: NSColor { currentPalette.muted }

    /// Restrained bar colors: green / coral / blue.
    static let barGreen = NSColor(srgbRed: 0x30 / 255.0, green: 0xA4 / 255.0, blue: 0x6C / 255.0, alpha: 1)
    static let barCoral = NSColor(srgbRed: 0xEB / 255.0, green: 0x63 / 255.0, blue: 0x4B / 255.0, alpha: 1)
    static let barBlue = NSColor(srgbRed: 0x4A / 255.0, green: 0x94 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
    static let barLow = NSColor(srgbRed: 0xF2 / 255.0, green: 0xB6 / 255.0, blue: 0x3C / 255.0, alpha: 1)
    static var barTrack: NSColor { currentPalette.surface2 }

    static var chromeLine: NSColor { currentPalette.border }
    static var chromeHighlight: NSColor { currentPalette.border2 }

    /// Dark themes (Jarvis cyan / Ultron crimson) carry their identity in the
    /// structural lines: card rims, top hairlines and header rule. Light and
    /// Friday keep the plain chrome tokens.
    static var isAccentTheme: Bool { UsagePanelThemeStore.current.isDark }
    static var cardRim: NSColor { isAccentTheme ? currentPalette.border2 : currentPalette.border }
    static var structureHairline: NSColor {
        isAccentTheme ? currentPalette.accent.withAlphaComponent(0.55) : currentPalette.border2
    }
    /// Large canvas wash: blue under Jarvis, crimson-graphite under Ultron.
    static var canvasWash: NSColor {
        switch UsagePanelThemeStore.current {
        case .jarvis: return NSColor(srgbRed: 0x0f / 255.0, green: 0x3a / 255.0, blue: 0x68 / 255.0, alpha: 1)
        case .ultron: return NSColor(srgbRed: 0x2a / 255.0, green: 0x1a / 255.0, blue: 0x1e / 255.0, alpha: 1)
        case .light, .friday: return currentPalette.surface2
        }
    }
    static var contactShadow: NSColor {
        UsagePanelThemeStore.current.isDark ? NSColor(white: 0, alpha: 0.42) : NSColor(white: 0, alpha: 0.10)
    }

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
        structureHairline.setFill()
        NSBezierPath(rect: NSRect(x: rect.minX + radius / 2, y: rect.minY + 0.5, width: rect.width - radius, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        cardRim.setStroke()
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
        cardRim.setStroke()
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
    var theme: UsagePanelTheme = .light { didSet { needsDisplay = true } }

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
        BKStyleTokens.drawIconWell(in: wellRect)
        let ink = BKStyleTokens.charcoalInk
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
