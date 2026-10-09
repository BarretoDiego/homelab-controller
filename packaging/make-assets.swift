// Turns the generated artwork in assets/generated into what the app and the DMG ship:
// AppIcon.icns (tile cut out with transparent corners), menu bar template glyphs, DMG background.
// usage: swift packaging/make-assets.swift <assets/generated> <output-dir>
import AppKit

let source = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func load(_ name: String) -> CGImage {
    let image = NSImage(contentsOf: source.appendingPathComponent(name))!
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (data, w, h)
}

func render(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}

func write(_ image: CGImage, _ url: URL, dpi: CGFloat = 72) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: CGFloat(image.width) * 72 / dpi, height: CGFloat(image.height) * 72 / dpi)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// --- App icon: find the lit tile on the dark canvas, cut it out, place it on Apple's icon grid.
let icon = load("app-icon.png")
let (ip, iw, ih) = pixels(icon)
func lit(_ x: Int, _ y: Int) -> Bool { ip[(y * iw + x) * 4 + 2] > 110 }   // blue channel: tile vs. near-black
let midY = ih / 2, midX = iw / 2
let left = (0..<iw).first { lit($0, midY) }!, right = (0..<iw).last { lit($0, midY) }!
let top = (0..<ih).first { lit(midX, $0) }!, bottom = (0..<ih).last { lit(midX, $0) }!
let inset = 5   // stay inside the glow that bleeds past the tile edge
let tile = CGRect(x: left + inset, y: top + inset, width: right - left - 2 * inset, height: bottom - top - 2 * inset)
print("icon tile:", tile)
let cropped = icon.cropping(to: tile)!
let master = render(1024, 1024) { context in
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.addPath(CGPath(roundedRect: box, cornerWidth: 824 * 0.2237, cornerHeight: 824 * 0.2237, transform: nil))
    context.clip()
    context.draw(cropped, in: box)
}
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let side = points * scale
    let scaled = render(side, side) { $0.draw(master, in: CGRect(x: 0, y: 0, width: side, height: side)) }
    write(scaled, iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
}
write(master, out.appendingPathComponent("AppIcon-1024.png"))

// --- Menu bar: black-on-white drawing becomes an alpha-only template, cropped to the glyph.
let glyph = load("menubar-glyph.png")
let (gp, gw, gh) = pixels(glyph)
var minX = gw, maxX = 0, minY = gh, maxY = 0
var mask = [UInt8](repeating: 0, count: gw * gh * 4)
for y in 0..<gh {
    for x in 0..<gw {
        let i = (y * gw + x) * 4
        let luminance = (Int(gp[i]) * 299 + Int(gp[i + 1]) * 587 + Int(gp[i + 2]) * 114) / 1000
        let alpha = UInt8(255 - luminance)
        mask[i + 3] = alpha                      // premultiplied black: colour stays 0
        if alpha > 128 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
let maskImage = mask.withUnsafeMutableBytes { buffer in
    CGContext(data: buffer.baseAddress, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}
let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
print("glyph bounds:", bounds)
let glyphOnly = maskImage.cropping(to: bounds)!
let pointHeight: CGFloat = 16, pointWidth = (pointHeight * bounds.width / bounds.height).rounded()
for scale in [1, 2, 3] {
    let w = Int(pointWidth) * scale, h = Int(pointHeight) * scale
    let plain = render(w, h) { $0.draw(glyphOnly, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    write(plain, out.appendingPathComponent("menubar\(scale == 1 ? "" : "@\(scale)x").png"), dpi: 72 * CGFloat(scale))
    // Connected: a dot in the lower-right corner, with a gap cut around it so it reads at 16 pt.
    let connected = render(w, h) { context in
        context.draw(glyphOnly, in: CGRect(x: 0, y: 0, width: w, height: h))
        let r = CGFloat(h) * 0.17, centre = CGPoint(x: CGFloat(w) - r, y: r)
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: centre.x - r * 1.55, y: centre.y - r * 1.55, width: r * 3.1, height: r * 3.1))
        context.setBlendMode(.normal)
        context.setFillColor(.black)
        context.fillEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }
    write(connected, out.appendingPathComponent("menubar-connected\(scale == 1 ? "" : "@\(scale)x").png"), dpi: 72 * CGFloat(scale))
}

// --- DMG background, drawn here so every position matches packaging/dmg-settings.py.
// Layout in points, origin top-left, for a 720x440 content area. The canvas is much larger than the
// window and keeps the same dark tone, so a taller or wider Finder window never shows a white margin.
let layout = (width: 720.0, height: 440.0)
let canvas = (width: 1200.0, height: 800.0)
let appSpot = CGPoint(x: 180, y: 196), applicationsSpot = CGPoint(x: 540, y: 196), readmeSpot = CGPoint(x: 360, y: 352)
let iconSize = 96.0

func drawBackground(scale: CGFloat) -> CGImage {
    render(Int(canvas.width * scale), Int(canvas.height * scale)) { context in
        context.scaleBy(x: scale, y: scale)
        // Flip to a top-left origin, like the Finder's icon coordinates.
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        let space = CGColorSpaceCreateDeviceRGB()
        func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        let base = CGGradient(colorsSpace: space, colors: [color(0x141A45), color(0x0B1020)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(base, start: .zero, end: CGPoint(x: canvas.width * 0.7, y: canvas.height), options: [.drawsAfterEndLocation])
        func glow(_ hex: UInt32, _ centre: CGPoint, _ radius: CGFloat, _ peak: CGFloat) {
            let gradient = CGGradient(colorsSpace: space, colors: [color(hex, peak), color(hex, peak * 0.3), color(hex, 0)] as CFArray, locations: [0, 0.5, 1])!
            context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
        }
        glow(0x3DE0FF, CGPoint(x: 150, y: 150), 330, 0.22)
        glow(0x8B5CFF, CGPoint(x: 600, y: 260), 380, 0.26)

        func text(_ string: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, alpha: CGFloat = 1, centre: CGPoint) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: NSColor(cgColor: color(hex, alpha))!]
            let line = NSAttributedString(string: string, attributes: attributes)
            let bounds = line.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            line.draw(at: CGPoint(x: centre.x - bounds.width / 2, y: centre.y - bounds.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        text("Home Lab", size: 26, weight: .bold, hex: 0xFFFFFF, centre: CGPoint(x: layout.width / 2, y: 44))
        text("Arraste o app para a pasta Applications", size: 14, weight: .medium, hex: 0xFFFFFF, alpha: 0.82,
             centre: CGPoint(x: layout.width / 2, y: 76))

        // The arrow between the two icons.
        let from = CGPoint(x: appSpot.x + 92, y: appSpot.y), to = CGPoint(x: applicationsSpot.x - 92, y: applicationsSpot.y)
        let arrow = CGMutablePath()
        arrow.move(to: from)
        arrow.addLine(to: to)
        arrow.move(to: CGPoint(x: to.x - 20, y: to.y - 16))
        arrow.addLine(to: to)
        arrow.addLine(to: CGPoint(x: to.x - 20, y: to.y + 16))
        for (width, alpha) in [(16.0, 0.10), (9.0, 0.22), (4.0, 1.0)] {
            context.addPath(arrow)
            context.setStrokeColor(color(0x3DE0FF, alpha))
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }

        // Finder draws the file names itself, in black or white depending on its appearance.
        // A mid-tone plate under each name keeps either one readable on the dark background.
        func plate(under spot: CGPoint, width: CGFloat) {
            let rect = CGRect(x: spot.x - width / 2, y: spot.y + iconSize / 2 + 5, width: width, height: 24)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.setFillColor(color(0x7482BA))
            context.fillPath()
        }
        plate(under: appSpot, width: 150)
        plate(under: applicationsSpot, width: 150)
        plate(under: readmeSpot, width: 150)

        // Pointer to the read-me.
        text("Primeira vez?", size: 13, weight: .semibold, hex: 0xFFFFFF, centre: CGPoint(x: readmeSpot.x - 150, y: readmeSpot.y - 10))
        text("Leia antes de abrir", size: 12, weight: .regular, hex: 0xFFFFFF, alpha: 0.75, centre: CGPoint(x: readmeSpot.x - 150, y: readmeSpot.y + 9))
        let hint = CGMutablePath()
        hint.move(to: CGPoint(x: readmeSpot.x - 88, y: readmeSpot.y))
        hint.addLine(to: CGPoint(x: readmeSpot.x - 62, y: readmeSpot.y))
        hint.move(to: CGPoint(x: readmeSpot.x - 70, y: readmeSpot.y - 7))
        hint.addLine(to: CGPoint(x: readmeSpot.x - 62, y: readmeSpot.y))
        hint.addLine(to: CGPoint(x: readmeSpot.x - 70, y: readmeSpot.y + 7))
        context.addPath(hint)
        context.setStrokeColor(color(0x3DE0FF, 0.9))
        context.setLineWidth(2.5)
        context.strokePath()
        text("requisitos e primeiro uso", size: 12, weight: .regular, hex: 0xFFFFFF, alpha: 0.75, centre: CGPoint(x: readmeSpot.x + 160, y: readmeSpot.y))
    }
}
write(drawBackground(scale: 1), out.appendingPathComponent("dmg-background.png"))
write(drawBackground(scale: 2), out.appendingPathComponent("dmg-background@2x.png"), dpi: 144)
print("assets written to", out.path)
