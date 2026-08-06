import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/CodexCreditMenuBar.icns")
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetURL) }

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for size in sizes {
    let image = NSImage(size: NSSize(width: size.pixels, height: size.pixels))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size.pixels, height: size.pixels)
    NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.08, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: CGFloat(size.pixels) * 0.22, yRadius: CGFloat(size.pixels) * 0.22).fill()

    let inset = CGFloat(size.pixels) * 0.08
    NSColor(calibratedRed: 0.10, green: 0.68, blue: 0.50, alpha: 1).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: CGFloat(size.pixels) * 0.17, yRadius: CGFloat(size.pixels) * 0.17)
    border.lineWidth = max(1, CGFloat(size.pixels) * 0.018)
    border.stroke()

    let symbolSize = CGFloat(size.pixels) * 0.46
    let symbolRect = NSRect(
        x: (CGFloat(size.pixels) - symbolSize) / 2,
        y: CGFloat(size.pixels) * 0.42,
        width: symbolSize,
        height: symbolSize
    )
    NSColor(calibratedRed: 0.10, green: 0.68, blue: 0.50, alpha: 1).setFill()
    NSBezierPath(ovalIn: symbolRect).fill()

    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: symbolRect.midX + symbolSize * 0.10, y: symbolRect.maxY - symbolSize * 0.16))
    bolt.line(to: NSPoint(x: symbolRect.midX - symbolSize * 0.22, y: symbolRect.midY + symbolSize * 0.02))
    bolt.line(to: NSPoint(x: symbolRect.midX - symbolSize * 0.03, y: symbolRect.midY + symbolSize * 0.02))
    bolt.line(to: NSPoint(x: symbolRect.midX - symbolSize * 0.13, y: symbolRect.minY + symbolSize * 0.15))
    bolt.line(to: NSPoint(x: symbolRect.midX + symbolSize * 0.24, y: symbolRect.midY - symbolSize * 0.06))
    bolt.line(to: NSPoint(x: symbolRect.midX + symbolSize * 0.04, y: symbolRect.midY - symbolSize * 0.06))
    bolt.close()
    NSColor.white.setFill()
    bolt.fill()

    let titleFontSize = max(5, CGFloat(size.pixels) * 0.092)
    let subtitleFontSize = max(4, CGFloat(size.pixels) * 0.075)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byClipping

    let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: titleFontSize, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: subtitleFontSize, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.78),
        .paragraphStyle: paragraph
    ]

    NSString(string: "Codex").draw(
        in: NSRect(x: inset, y: CGFloat(size.pixels) * 0.235, width: CGFloat(size.pixels) - inset * 2, height: titleFontSize * 1.3),
        withAttributes: titleAttributes
    )
    NSString(string: "Credit").draw(
        in: NSRect(x: inset, y: CGFloat(size.pixels) * 0.135, width: CGFloat(size.pixels) - inset * 2, height: subtitleFontSize * 1.3),
        withAttributes: subtitleAttributes
    )

    image.unlockFocus()

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(size.name)")
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(size.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}
