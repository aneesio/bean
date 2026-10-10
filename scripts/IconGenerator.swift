// Deterministic icon renderer for Bean. Renders the editable AppIcon.svg artwork
// with offscreen macOS WebKit, then scales it and draws a menu bar template.
// AppIcon.png is a generated preview, never an input to this renderer.
//
// Usage:  swift scripts/IconGenerator.swift <output-dir> [source-svg]
// Source: Resources/Icons/AppIcon.svg by default, resolved relative to this script.
// Writes: <output-dir>/AppIcon.png                (1024px SVG preview)
//         <output-dir>/AppIcon.iconset/icon_*.png  (all macOS sizes)
//         <output-dir>/MenuBarTemplate.png         (36px @2x template)
//
// scripts/generate_icons.sh then runs `iconutil` to produce AppIcon.icns.

import AppKit
import CoreGraphics
import ImageIO
import WebKit

enum IconError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

// MARK: - PNG helpers

func pngData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        throw IconError.message("could not create a PNG encoder")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.message("could not encode a PNG")
    }
    return data as Data
}

func renderPNG(dimension: Int, colorSpace: CGColorSpace,
               _ draw: (CGContext, CGFloat) -> Void) throws -> Data {
    guard let context = CGContext(
        data: nil, width: dimension, height: dimension,
        bitsPerComponent: 8, bytesPerRow: dimension * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw IconError.message("could not create a \(dimension)px image context")
    }
    // Start transparent and draw without a matte so artwork alpha is retained.
    context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
    context.interpolationQuality = .high
    draw(context, CGFloat(dimension))
    guard let image = context.makeImage() else {
        throw IconError.message("could not render a \(dimension)px image")
    }
    return try pngData(image)
}

// MARK: - App icon (authoritative vector artwork)

final class SVGValidator: NSObject, XMLParserDelegate {
    var problem: String?
    private var hasRoot = false

    private func reject(_ message: String, parser: XMLParser) {
        problem = message
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = elementName.lowercased()
        if !hasRoot {
            hasRoot = true
            guard name == "svg" else {
                reject("app icon source must have an SVG root element", parser: parser)
                return
            }
            if let viewBox = attributes["viewBox"] {
                let values = viewBox.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
                guard values.count == 4, values.allSatisfy({ $0.isFinite }),
                      values[2] > 0, values[2] == values[3] else {
                    reject("app icon SVG must have a square, positive viewBox", parser: parser)
                    return
                }
            }
            if let width = attributes["width"], let height = attributes["height"] {
                let widthValue = Double(width.replacingOccurrences(of: "px", with: ""))
                let heightValue = Double(height.replacingOccurrences(of: "px", with: ""))
                guard let widthValue = widthValue, let heightValue = heightValue,
                      widthValue.isFinite, widthValue > 0, widthValue == heightValue else {
                    reject("app icon SVG must have a square, positive pixel canvas", parser: parser)
                    return
                }
            } else if attributes["viewBox"] == nil {
                reject("app icon SVG must define a square viewBox or pixel canvas", parser: parser)
                return
            }
        }
        guard !["image", "feimage", "script", "foreignobject"].contains(name) else {
            reject("app icon SVG must contain vector artwork only; <\(elementName)> is not supported", parser: parser)
            return
        }
        for (key, value) in attributes {
            let attribute = key.lowercased()
            if attribute == "href" || attribute.hasSuffix(":href") {
                guard value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") else {
                    reject("app icon SVG cannot reference external resources: \(value)", parser: parser)
                    return
                }
            }
            if attribute.hasPrefix("on") || attribute == "src" || attribute == "xml:base" {
                reject("app icon SVG cannot contain scripts or external resource attributes: \(key)", parser: parser)
                return
            }
        }
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        if target.lowercased() == "xml-stylesheet" {
            reject("app icon SVG cannot use an external stylesheet", parser: parser)
        }
    }

    static func validate(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw IconError.message("app icon source must be a readable UTF-8 SVG")
        }
        let lowercase = text.lowercased()
        guard !lowercase.contains("<!doctype"), !lowercase.contains("<!entity"),
              !lowercase.contains("@import") else {
            throw IconError.message("app icon SVG cannot use external entities or stylesheet imports")
        }
        // Fragment URLs are the SVG's own gradients, filters, masks, and clips.
        let pattern = #"(?i)url\s*\(\s*['\"]?([^\s)'\"]+)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: fullRange) {
            if let range = Range(match.range(at: 1), in: text), !text[range].hasPrefix("#") {
                throw IconError.message("app icon SVG cannot reference external resources: \(text[range])")
            }
        }
        let validator = SVGValidator()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        guard parser.parse(), validator.hasRoot else {
            throw IconError.message(validator.problem ?? "app icon source must be valid SVG XML: \(parser.parserError?.localizedDescription ?? "missing SVG root")")
        }
    }
}

final class SVGRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let window: NSWindow
    private var result: Result<NSImage, Error>?

    override init() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                            configuration: configuration)
        // WebKit's transparent backing is needed in addition to transparent CSS.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        window = NSWindow(contentRect: webView.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
        // The backing window is never ordered on screen or made active.
    }

    func render(_ svg: Data) throws -> Data {
        let markup = String(decoding: svg, as: UTF8.self)
        let html = """
        <html><head><meta name="viewport" content="width=1024,initial-scale=1">
        <style>html,body{margin:0;width:1024px;height:1024px;background:transparent;overflow:hidden;}
        svg{display:block;width:1024px;height:1024px;}</style></head><body>\(markup)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(15)
        while result == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let result = result else {
            throw IconError.message("timed out rendering the SVG with macOS WebKit")
        }
        let snapshot = try result.get()
        return try renderPNG(dimension: 1024, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) { context, size in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            snapshot.draw(in: CGRect(x: 0, y: 0, width: size, height: size), from: .zero,
                          operation: .sourceOver, fraction: 1, respectFlipped: false,
                          hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        configuration.snapshotWidth = 1024
        webView.takeSnapshot(with: configuration) { image, error in
            if let error = error {
                self.result = .failure(error)
            } else if let image = image {
                self.result = .success(image)
            } else {
                self.result = .failure(IconError.message("WebKit returned no rendered SVG image"))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        result = .failure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        result = .failure(error)
    }
}

struct AppIconSource {
    let data: Data
    let image: CGImage

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IconError.message("app icon source is missing: \(url.path)")
        }
        let svgData = try Data(contentsOf: url)
        try SVGValidator.validate(svgData)
        // WebKit renders the SVG itself; AppKit's SVG image rep mishandles some
        // layered radial gradients. No procedural copy of the artwork is used.
        data = try SVGRenderer().render(svgData)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw IconError.message("could not decode the rendered SVG artwork")
        }
        self.image = image
    }

    func scaledPNG(dimension: Int) throws -> Data {
        // Keep the rendered preview's pixels and alpha exactly at native size.
        if dimension == image.width { return data }
        let colorSpace = image.colorSpace?.model == .rgb
            ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        return try renderPNG(dimension: dimension, colorSpace: colorSpace) { context, size in
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }
}

// MARK: - Menu bar template (monochrome, alpha = shape)

func beanPath(width: CGFloat, height: CGFloat) -> CGPath {
    let path = CGMutablePath()
    // The same gentle bend as AppIcon.svg, converted from SVG's downward Y axis.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - 530) / 800 * width, y: (512 - y) / 740 * height)
    }
    path.move(to: point(310, 856))
    path.addCurve(to: point(139, 704), control1: point(215, 845), control2: point(150, 782))
    path.addCurve(to: point(262, 496), control1: point(124, 612), control2: point(171, 528))
    path.addCurve(to: point(382, 436), control1: point(312, 478), control2: point(348, 468))
    path.addCurve(to: point(450, 301), control1: point(416, 404), control2: point(421, 360))
    path.addCurve(to: point(620, 162), control1: point(484, 230), control2: point(548, 184))
    path.addCurve(to: point(863, 223), control1: point(710, 123), control2: point(808, 147))
    path.addCurve(to: point(894, 554), control1: point(923, 306), control2: point(936, 431))
    path.addCurve(to: point(621, 836), control1: point(849, 684), control2: point(747, 790))
    path.addCurve(to: point(310, 856), control1: point(516, 875), control2: point(407, 877))
    path.closeSubpath()
    return path
}

func drawMenuBarTemplate(_ context: CGContext, _ size: CGFloat) {
    context.saveGState()
    context.translateBy(x: size / 2, y: size / 2)
    context.rotate(by: .pi / 36)
    let width = size * 0.80, height = size * 0.77

    context.addPath(beanPath(width: width, height: height))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()

    // The enlarged seed scar remains a transparent cutout in the system template.
    context.setBlendMode(.clear)
    context.translateBy(x: (443 - 530) / 800 * width, y: (512 - 471) / 740 * height)
    context.rotate(by: 40 * .pi / 180)
    let scarWidth = 80 * 1.7 / 800 * width, scarHeight = 36 * 1.45 / 740 * height
    context.fillEllipse(in: CGRect(x: -scarWidth / 2, y: -scarHeight / 2,
                                  width: scarWidth, height: scarHeight))
    context.restoreGState()
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3 else {
    FileHandle.standardError.write(Data("usage: IconGenerator.swift <output-dir> [source-svg]\n".utf8))
    exit(2)
}

do {
    let outputURL = URL(fileURLWithPath: args[1], isDirectory: true)
    let defaultSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Icons/AppIcon.svg")
    let sourceURL = args.count == 3 ? URL(fileURLWithPath: args[2]) : defaultSourceURL
    // Validate the source before creating or changing any outputs.
    let source = try AppIconSource(url: sourceURL)
    let iconsetURL = outputURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    let previewURL = outputURL.appendingPathComponent("AppIcon.png")
    try source.data.write(to: previewURL)
    print("Wrote SVG preview to \(previewURL.path)")

    // (filename, pixel dimension)
    let iconsetSizes: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]

    for (name, dimension) in iconsetSizes {
        try source.scaledPNG(dimension: dimension).write(to: iconsetURL.appendingPathComponent(name))
    }
    print("Wrote \(iconsetSizes.count) app-icon PNGs to \(iconsetURL.path)")

    let menuData = try renderPNG(dimension: 36, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 drawMenuBarTemplate)
    let menuURL = outputURL.appendingPathComponent("MenuBarTemplate.png")
    try menuData.write(to: menuURL)
    print("Wrote menu bar template to \(menuURL.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
