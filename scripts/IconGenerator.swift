// Deterministic icon renderer for Bean. Draws the coffee-bean app icon and the
// monochrome menu bar template with CoreGraphics — no external SVG rasterizer
// needed (only AppKit, which ships with macOS). Mirrors Resources/Icons/AppIcon.svg.
//
// Usage:  swift scripts/IconGenerator.swift <output-dir>
// Writes: <output-dir>/AppIcon.iconset/icon_*.png  (all macOS sizes)
//         <output-dir>/MenuBarTemplate.png          (36px @2x template)
//
// scripts/generate_icons.sh then runs `iconutil` to produce AppIcon.icns.

import AppKit
import CoreGraphics

// MARK: - PNG helper

func renderPNG(dimension: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: dimension, pixelsHigh: dimension,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: dimension, height: dimension)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
    draw(ctx, CGFloat(dimension))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

// MARK: - Bean path (long axis vertical, centred at origin)

func beanPath(width: CGFloat, height: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), transform: nil)
}

func groovePath(width: CGFloat, height: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: height * 0.42))
    p.addCurve(
        to: CGPoint(x: 0, y: -height * 0.42),
        control1: CGPoint(x: width * 0.5, y: height * 0.12),
        control2: CGPoint(x: -width * 0.5, y: -height * 0.12)
    )
    return p
}

// MARK: - App icon

func drawAppIcon(_ ctx: CGContext, _ s: CGFloat) {
    let pad = s * 0.06
    let body = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = body.width * 0.2237
    let bgPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Warm-neutral background gradient.
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: cs,
                        colors: [color(0.980, 0.972, 0.957), color(0.906, 0.882, 0.839)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])
    ctx.restoreGState()

    // Bean, tilted -30°.
    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.rotate(by: -.pi / 6)
    let bw = s * 0.42, bh = s * 0.60
    let bean = beanPath(width: bw, height: bh)

    // Soft shadow cast by a solid fill.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: color(0, 0, 0, 0.22))
    ctx.addPath(bean)
    ctx.setFillColor(color(0.18, 0.17, 0.15))
    ctx.fillPath()
    ctx.restoreGState()

    // Charcoal gradient body.
    ctx.saveGState()
    ctx.addPath(bean)
    ctx.clip()
    let beanGrad = CGGradient(colorsSpace: cs,
                              colors: [color(0.290, 0.278, 0.259), color(0.173, 0.165, 0.149)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(beanGrad, start: CGPoint(x: 0, y: bh / 2),
                           end: CGPoint(x: 0, y: -bh / 2), options: [])
    ctx.restoreGState()

    // Groove.
    ctx.addPath(groovePath(width: bw, height: bh))
    ctx.setStrokeColor(color(0.949, 0.933, 0.902, 0.85))
    ctx.setLineWidth(s * 0.022)
    ctx.setLineCap(.round)
    ctx.strokePath()

    ctx.restoreGState()
}

// MARK: - Menu bar template (monochrome, alpha = shape)

func drawMenuBarTemplate(_ ctx: CGContext, _ s: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: s / 2, y: s / 2)
    ctx.rotate(by: -.pi / 6)
    let bw = s * 0.52, bh = s * 0.74

    // Solid black bean.
    ctx.addPath(beanPath(width: bw, height: bh))
    ctx.setFillColor(color(0, 0, 0, 1))
    ctx.fillPath()

    // Carve a transparent groove so the shape reads as a bean.
    ctx.setBlendMode(.clear)
    ctx.addPath(groovePath(width: bw, height: bh))
    ctx.setLineWidth(s * 0.07)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.setBlendMode(.normal)

    ctx.restoreGState()
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: IconGenerator.swift <output-dir>\n".utf8))
    exit(2)
}
let outDir = args[1]
let fm = FileManager.default
let iconsetDir = (outDir as NSString).appendingPathComponent("AppIcon.iconset")
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// (filename, pixel dimension)
let iconsetSizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, dim) in iconsetSizes {
    let data = renderPNG(dimension: dim, drawAppIcon)
    let path = (iconsetDir as NSString).appendingPathComponent(name)
    try! data.write(to: URL(fileURLWithPath: path))
}
print("Wrote \(iconsetSizes.count) app-icon PNGs to \(iconsetDir)")

let menuData = renderPNG(dimension: 36, drawMenuBarTemplate)
let menuPath = (outDir as NSString).appendingPathComponent("MenuBarTemplate.png")
try! menuData.write(to: URL(fileURLWithPath: menuPath))
print("Wrote menu bar template to \(menuPath)")
