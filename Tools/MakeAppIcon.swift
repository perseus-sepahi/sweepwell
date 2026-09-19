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

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s / 1024, y: s / 1024)

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
    let glow = CGGradient(colorsSpace: nil, colors: [color(0x35E0B2, 0.55), color(0x1C9FD8, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 300), startRadius: 0,
                               endCenter: CGPoint(x: 330, y: 300), endRadius: 620, options: [])

    // The sweep: one confident arc, thick where it starts and fading as it clears the way.
    let sweep = CGMutablePath()
    sweep.move(to: CGPoint(x: 205, y: 470))
    sweep.addCurve(to: CGPoint(x: 800, y: 330), control1: CGPoint(x: 330, y: 215), control2: CGPoint(x: 640, y: 190))
    sweep.addCurve(to: CGPoint(x: 205, y: 470), control1: CGPoint(x: 630, y: 300), control2: CGPoint(x: 370, y: 330))
    context.addPath(sweep)
    context.clip()
    let sweepColors = CGGradient(colorsSpace: nil, colors: [color(0x35E0B2), color(0x1C9FD8, 0.25)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sweepColors, start: CGPoint(x: 205, y: 400), end: CGPoint(x: 800, y: 300), options: [])
    context.restoreGState()

    // What is left behind: sparkles.
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    context.setShadow(offset: .zero, blur: 40, color: color(0x35E0B2, 0.8))
    context.setFillColor(color(0xFFFFFF))
    context.addPath(sparkle(center: CGPoint(x: 520, y: 600), radius: 205))
    context.fillPath()
    context.setFillColor(color(0xD8FFF4))
    context.addPath(sparkle(center: CGPoint(x: 752, y: 742), radius: 78))
    context.addPath(sparkle(center: CGPoint(x: 300, y: 770), radius: 52))
    context.fillPath()
    context.restoreGState()

    // A hairline highlight keeps the dark plate from dissolving into dark backgrounds.
    context.addPath(CGPath(roundedRect: plate.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(4)
    context.strokePath()

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
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
print("Wrote \(images.count) icon sizes to \(output.path)")
