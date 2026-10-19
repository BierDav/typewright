// Renders the app icon set and logo. Usage: swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824pt body centred in 1024.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(red: 0.27, green: 0.45, blue: 0.86, alpha: 1),
               ending: NSColor(red: 0.12, green: 0.20, blue: 0.47, alpha: 1))!.draw(in: shape, angle: -90)

    let font = NSFont(descriptor: NSFont.systemFont(ofSize: 600 * s, weight: .bold).fontDescriptor
        .withDesign(.serif)!, size: 600 * s)!
    let glyph = NSAttributedString(string: "t", attributes: [.font: font, .foregroundColor: NSColor.white])
    let g = glyph.size()
    glyph.draw(at: NSPoint(x: body.midX - g.width / 2 - 40 * s, y: body.midY - g.height / 2 + 10 * s))

    // Text cursor.
    NSColor(red: 0.45, green: 0.86, blue: 0.95, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: body.midX + 125 * s, y: body.midY - 200 * s, width: 44 * s, height: 400 * s),
                 xRadius: 22 * s, yRadius: 22 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = "macApp/Sources/Typewright/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(set)/\(name)"))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(set)/Contents.json"))
try render(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "macApp/Resources/logo.png"))
