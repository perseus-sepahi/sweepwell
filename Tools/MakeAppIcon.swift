// Draws the Sweepwell icon and writes every size the macOS asset catalog needs.
// Usage: swift Tools/MakeAppIcon.swift Sweepwell/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A four-point sparkle: a star whose sides curve inwards to the centre.
func sparkle(center: CGPoint, radius: CGFloat, pinch: CGFloat = 0.16) -> CGPath {
    let path = CGMutablePath()
    let tips = (0..<4).map { i -> CGPoint in
        let angle = CGFloat(i) * .pi / 2 + .pi / 2
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    path.move(to: tips[0])
    for i in 1...4 {
        let mid = CGFloat(i) * .pi / 2 + .pi / 4
        let control = CGPoint(x: center.x + cos(mid) * radius * pinch, y: center.y + sin(mid) * radius * pinch)
        path.addQuadCurve(to: tips[i % 4], control: control)
    }
    path.closeSubpath()
    return path
}

/// The broom, drawn around its binding (where handle meets bristles) and tilted mid-sweep,
/// plus the dust it kicks up. `glyph` draws the same shapes in flat black for template images.
func drawBroom(in context: CGContext, glyph: Bool) {
    let ink = color(0x000000)
    func fill(_ path: CGPath, _ normal: CGColor) {
        context.addPath(path)
        context.setFillColor(glyph ? ink : normal)
        context.fillPath()
    }

    // Dust rising from the sweep: fat puffs near the floor, thinning out as they climb.
    let puffs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (218, 300, 60, 0.95), (160, 392, 40, 0.85), (226, 452, 46, 0.8), (150, 520, 28, 0.65),
        (262, 560, 30, 0.6), (196, 632, 20, 0.5), (286, 668, 15, 0.4)
    ]
    for (x, y, r, alpha) in puffs {
        let scale: CGFloat = glyph ? 1.15 : 1
        fill(CGPath(ellipseIn: CGRect(x: x - r * scale, y: y - r * scale, width: 2 * r * scale, height: 2 * r * scale), transform: nil),
             color(0xFFFFFF, alpha))
    }
    if !glyph {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 26, color: color(0x35E0B2, 0.9))
        fill(sparkle(center: CGPoint(x: 352, y: 748), radius: 52), color(0xFFFFFF))
        fill(sparkle(center: CGPoint(x: 214, y: 772), radius: 30), color(0xD8FFF4))
        context.restoreGState()
    }

    context.saveGState()
    context.translateBy(x: 478, y: 452)
    context.rotate(by: -35 * .pi / 180)   // handle leans up-right, bristles sweep down-left

    // Handle
    let handle = CGPath(roundedRect: CGRect(x: -19, y: 0, width: 38, height: 470), cornerWidth: 19, cornerHeight: 19, transform: nil)
    if glyph {
        fill(handle, ink)
    } else {
        context.saveGState()
        context.addPath(handle)
        context.clip()
        let wood = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF), color(0xBFF5E6)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(wood, start: CGPoint(x: -19, y: 0), end: CGPoint(x: 19, y: 0), options: [])
        context.restoreGState()
    }

    // Bristles: a flared head with a gently rounded sweeping edge.
    let bristles = CGMutablePath()
    bristles.move(to: CGPoint(x: -78, y: -36))
    bristles.addLine(to: CGPoint(x: 78, y: -36))
    bristles.addLine(to: CGPoint(x: 168, y: -262))
    bristles.addQuadCurve(to: CGPoint(x: -168, y: -262), control: CGPoint(x: 0, y: -318))
    bristles.closeSubpath()
    if glyph {
        fill(bristles, ink)
    } else {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.35))
        context.addPath(bristles)
        context.setFillColor(color(0x35E0B2))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(bristles)
        context.clip()
        let straw = CGGradient(colorsSpace: nil, colors: [color(0x5CF0C6), color(0x1C9FD8)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(straw, start: CGPoint(x: 0, y: -36), end: CGPoint(x: 0, y: -300), options: [])
        // Individual straws, fanning out with the head.
        context.setStrokeColor(color(0x0B3B52, 0.28))
        context.setLineWidth(7)
        for i in -3...3 {
            context.move(to: CGPoint(x: CGFloat(i) * 20, y: -60))
            context.addLine(to: CGPoint(x: CGFloat(i) * 44, y: -310))
        }
        context.strokePath()
        context.restoreGState()
    }

    // Binding that ties the bristles to the handle. In the glyph it is a gap, so the two
    // parts stay readable at 18 pt.
    let band = CGPath(roundedRect: CGRect(x: -86, y: -58, width: 172, height: 58), cornerWidth: 16, cornerHeight: 16, transform: nil)
    if glyph {
        context.setBlendMode(.clear)
        fill(CGPath(rect: CGRect(x: -120, y: -52, width: 240, height: 24), transform: nil), ink)
        context.setBlendMode(.normal)
    } else {
        fill(band, color(0xFFFFFF))
        context.setStrokeColor(color(0x1C9FD8, 0.55))
        context.setLineWidth(8)
        context.move(to: CGPoint(x: -66, y: -29))
        context.addLine(to: CGPoint(x: 66, y: -29))
        context.strokePath()
    }
    context.restoreGState()
}

func bitmap(size: Int, draw: (CGContext) -> Void) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(context)
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

func draw(size: Int) -> Data {
    bitmap(size: size) { context in
        // macOS does not mask icons: the squircle, its margin and its shadow are part of the art.
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let squircle = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
        context.addPath(squircle)
        context.setFillColor(color(0x12142A))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(squircle)
        context.clip()
        let background = CGGradient(colorsSpace: nil, colors: [color(0x232A5C), color(0x12142A)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        let glow = CGGradient(colorsSpace: nil, colors: [color(0x35E0B2, 0.5), color(0x1C9FD8, 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 300), startRadius: 0,
                                   endCenter: CGPoint(x: 300, y: 300), endRadius: 600, options: [])
        // The floor, already swept clean behind the broom.
        context.setStrokeColor(color(0xFFFFFF, 0.22))
        context.setLineWidth(10)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: 230, y: 188))
        context.addLine(to: CGPoint(x: 794, y: 188))
        context.strokePath()
        drawBroom(in: context, glyph: false)
        context.restoreGState()

        // A hairline highlight keeps the dark plate from dissolving into dark backgrounds.
        context.addPath(CGPath(roundedRect: plate.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
        context.setStrokeColor(color(0xFFFFFF, 0.14))
        context.setLineWidth(4)
        context.strokePath()
    }
}

/// Monochrome broom for the menu bar and sidebar, rendered as a template image so macOS
/// tints it for light and dark menu bars.
func drawGlyph(size: Int) -> Data {
    bitmap(size: size) { context in
        // The icon art leaves a margin for the plate; the glyph uses the whole canvas.
        context.translateBy(x: 512, y: 512)
        context.scaleBy(x: 1.32, y: 1.32)
        context.translateBy(x: -470, y: -520)
        drawBroom(in: context, glyph: true)
    }
}

var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try draw(size: points * scale).write(to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))

let glyphSet = output.deletingLastPathComponent().appendingPathComponent("BroomGlyph.imageset", isDirectory: true)
try FileManager.default.createDirectory(at: glyphSet, withIntermediateDirectories: true)
var glyphImages: [[String: String]] = []
for scale in 1...3 {
    let name = "broom@\(scale)x.png"
    try drawGlyph(size: 18 * scale).write(to: glyphSet.appendingPathComponent(name))
    glyphImages.append(["idiom": "universal", "scale": "\(scale)x", "filename": name])
}
let glyphContents: [String: Any] = ["images": glyphImages, "info": ["author": "xcode", "version": 1],
                                    "properties": ["template-rendering-intent": "template"]]
try JSONSerialization.data(withJSONObject: glyphContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: glyphSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon sizes and the broom glyph next to \(output.lastPathComponent)")
