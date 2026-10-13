import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What the menu bar glyph shows.
enum GlyphState {
    /// Nothing running: the tower, its mouth empty.
    case idle
    /// Something running: a flame in the mouth.
    case running
    /// A script crashed and is staying down: the flame plus a red dot.
    case attention
}

/// The furnace and its flame, drawn in the 18 × 18 box of the menu bar glyph,
/// y pointing down, the same numbers as the mockups' SVG.
enum GlyphPaths {
    /// The tower with its mouth cut out (fill even-odd).
    static let towerWithMouth: CGPath = {
        let path = CGMutablePath()
        addArch(to: path, left: 3, right: 15, top: 8, bottom: 17)
        addArch(to: path, left: 6, right: 12, top: 12, bottom: 17)
        return path
    }()

    static let mouth: CGPath = {
        let path = CGMutablePath()
        addArch(to: path, left: 6, right: 12, top: 12, bottom: 17)
        return path
    }()

    /// One shape, kept clear of the mouth's edges so it reads at 16 px.
    static let templateFlame = svg("M9 16.6C7.7 16.6 7 15.8 7.1 14.7C7.2 13.9 7.5 13.3 7.6 12.5C8 13 8.2 13.4 8.3 13.8C8.3 12.4 8.9 11.3 9.6 10.4C9.8 11.3 10.2 11.9 10.4 12.4C10.6 12.2 10.7 12 10.8 11.8C11.1 12.6 11.1 13.6 11 14.6C10.9 15.8 10.2 16.6 9 16.6Z")

    static let flameOuter = svg("M9 16.7C7.4 16.7 6.5 15.7 6.6 14.5C6.7 13.5 7.2 12.9 7.4 12C7.8 12.7 8 13.2 8.1 13.6C8.1 12.2 8.7 11 9.4 9.8C9.5 10.9 10.2 11.6 10.6 12.4C10.8 12 10.9 11.6 10.9 11.2C11.4 12.2 11.5 13.4 11.4 14.4C11.3 15.8 10.4 16.7 9 16.7Z")
    static let flameMiddle = svg("M9 16.6C7.9 16.6 7.3 15.9 7.4 15C7.5 14 8.4 13 9.2 11.4C9.4 12.3 9.6 12.9 9.9 13.3C10.1 13 10.3 12.8 10.5 12.5C10.9 13.4 10.9 14.4 10.7 15.2C10.5 16.1 9.9 16.6 9 16.6Z")
    static let flameCore = svg("M9 16.5C8.3 16.5 7.9 16 8 15.4C8.1 14.7 8.6 14.2 9 13.3C9.4 14.1 9.9 14.7 10 15.4C10.1 16 9.7 16.5 9 16.5Z")
    static let coals = svg("M6 17C6.2 16.4 6.8 16.1 7.4 16.3C7.8 15.9 8.5 15.9 9 16.2C9.5 15.8 10.3 15.8 10.8 16.2C11.3 16 11.8 16.1 12 16.4V17Z")

    /// The square's corner at bottom-left and bottom-right, a half circle on top.
    private static func addArch(to path: CGMutablePath, left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        let radius = (right - left) / 2
        let center = left + radius
        let k: CGFloat = 0.5523 * radius
        path.move(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top))
        path.addCurve(to: CGPoint(x: center, y: top - radius),
                      control1: CGPoint(x: left, y: top - k), control2: CGPoint(x: center - k, y: top - radius))
        path.addCurve(to: CGPoint(x: right, y: top),
                      control1: CGPoint(x: center + k, y: top - radius), control2: CGPoint(x: right, y: top - k))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.closeSubpath()
    }

    /// Absolute M, L, H, V, C and Z: all the flame paths use.
    private static func svg(_ data: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var number = ""
        for character in data {
            if character.isLetter {
                if !number.isEmpty { tokens.append(number); number = "" }
                tokens.append(String(character))
            } else if character == " " || character == "," {
                if !number.isEmpty { tokens.append(number); number = "" }
            } else {
                number.append(character)
            }
        }
        if !number.isEmpty { tokens.append(number) }
        var index = 0
        var command = "M"
        var current = CGPoint.zero
        func next() -> CGFloat {
            defer { index += 1 }
            return CGFloat(Double(tokens[index]) ?? 0)
        }
        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = tokens[index]
                index += 1
                if command == "Z" {
                    path.closeSubpath()
                    continue
                }
            }
            switch command {
            case "M":
                current = CGPoint(x: next(), y: next())
                path.move(to: current)
                command = "L"
            case "L":
                current = CGPoint(x: next(), y: next())
                path.addLine(to: current)
            case "H":
                current.x = next()
                path.addLine(to: current)
            case "V":
                current.y = next()
                path.addLine(to: current)
            case "C":
                let c1 = CGPoint(x: next(), y: next())
                let c2 = CGPoint(x: next(), y: next())
                current = CGPoint(x: next(), y: next())
                path.addCurve(to: current, control1: c1, control2: c2)
            default:
                index += 1
            }
        }
        return path
    }
}

// MARK: - Menu bar images

enum StatusGlyph {
    static func image(for state: GlyphState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        switch state {
        case .idle, .running:
            let image = NSImage(size: size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.black.cgColor)
                context.addPath(GlyphPaths.towerWithMouth)
                context.fillPath(using: .evenOdd)
                if state == .running {
                    context.addPath(GlyphPaths.templateFlame)
                    context.fillPath()
                }
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = state == .running ? "Athanor, scripts running" : "Athanor"
            return image
        case .attention:
            // A template image can't keep the red, so this one draws itself in
            // the menu bar's own text color, each time it's drawn.
            let image = NSImage(size: size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
                    context.setFillColor(NSColor.labelColor.cgColor)
                }
                context.addPath(GlyphPaths.towerWithMouth)
                context.fillPath(using: .evenOdd)
                context.addPath(GlyphPaths.templateFlame)
                context.fillPath()
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 14.8 - 3.4, y: 3.4 - 3.4, width: 6.8, height: 6.8))
                context.setBlendMode(.normal)
                context.setFillColor(NSColor.systemRed.cgColor)
                context.fillEllipse(in: CGRect(x: 14.8 - 2.5, y: 3.4 - 2.5, width: 5, height: 5))
                return true
            }
            image.isTemplate = false
            image.cacheMode = .never
            image.accessibilityDescription = "Athanor, a script crashed"
            return image
        }
    }
}

// MARK: - Colored logo

/// The logo in color: copper tower, dark mouth, and when lit, the three-layer flame.
struct LogoMark: View {
    var size: CGFloat = 26
    var lit = true

    var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 18
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(GlyphPaths.towerWithMouth), with: .color(Color(nsColor: NSColor(hex: 0xC4763A))),
                         style: FillStyle(eoFill: true))
            context.fill(Path(GlyphPaths.mouth), with: .color(Color(nsColor: NSColor(hex: 0x2A1510))))
            if lit {
                context.fill(Path(GlyphPaths.flameOuter), with: .color(Color(nsColor: NSColor(hex: 0xE0602A))))
                context.fill(Path(GlyphPaths.flameMiddle), with: .color(Color(nsColor: NSColor(hex: 0xF5B95C))))
                context.fill(Path(GlyphPaths.flameCore), with: .color(Color(nsColor: NSColor(hex: 0xFFF1C9))))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - App icon

/// The app icon, drawn rather than shipped as images: the build renders an
/// iconset from it (`Athanor --export-iconset DIR`).
enum AppIcon {
    static func render(pixels: Int) -> CGImage? {
        let size = CGFloat(pixels)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Work on Apple's 1024 grid, y down like the glyph paths.
        context.translateBy(x: 0, y: size)
        context.scaleBy(x: size / 1024, y: -size / 1024)

        // The tile: 824 square with continuous-looking corners, and a soft shadow.
        let tile = CGPath(roundedRect: CGRect(x: 100, y: 92, width: 824, height: 824),
                          cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        context.addPath(tile)
        context.setFillColor(cg(0x1F1A16))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(tile)
        context.clip()
        // A little light from above, so the tile isn't flat black.
        let sheen = CGGradient(colorsSpace: nil, colors: [cg(0x2E2620), cg(0x1A1512)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 92), end: CGPoint(x: 512, y: 916), options: [])
        context.restoreGState()

        // The tower: 12 × 15 glyph units, scaled to 560 px tall, centered.
        let unit: CGFloat = 37.5
        context.saveGState()
        context.translateBy(x: 512 - 9 * unit, y: 512 - 9.5 * unit + 8)
        context.scaleBy(x: unit, y: unit)

        context.saveGState()
        context.addPath(GlyphPaths.towerWithMouth)
        context.clip(using: .evenOdd)
        let copper = CGGradient(colorsSpace: nil, colors: [cg(0xD48A4E), cg(0xC4763A), cg(0xA9612C)] as CFArray,
                                locations: [0, 0.5, 1])!
        context.drawLinearGradient(copper, start: CGPoint(x: 9, y: 2), end: CGPoint(x: 9, y: 17), options: [])
        context.restoreGState()

        context.saveGState()
        context.addPath(GlyphPaths.mouth)
        context.clip()
        context.setFillColor(cg(0x2A1510))
        context.fill(CGRect(x: 5, y: 8, width: 8, height: 10))
        let glow = CGGradient(colorsSpace: nil,
                              colors: [cg(0xF5B95C, 0.6), cg(0xE0602A, 0.22), cg(0xE0602A, 0)] as CFArray,
                              locations: [0, 0.5, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 9, y: 16.2), startRadius: 0,
                                   endCenter: CGPoint(x: 9, y: 16.2), endRadius: 5.2, options: [])
        context.restoreGState()

        fill(context, GlyphPaths.flameOuter, [cg(0xF28C2E), cg(0xE0602A), cg(0xB8341A)], [0, 0.55, 1], from: 16.7, to: 9.8)
        fill(context, GlyphPaths.flameMiddle, [cg(0xFFD98A), cg(0xF59A36)], [0, 1], from: 16.6, to: 11.4)
        fill(context, GlyphPaths.flameCore, [cg(0xFFFCF2), cg(0xFFE3A0)], [0, 1], from: 16.5, to: 13.3)

        context.addPath(GlyphPaths.coals)
        context.setFillColor(cg(0x7E2A12))
        context.fillPath()
        for (x, y, r, color) in [(7.1, 16.6, 0.28, 0xFF9A3D), (8.6, 16.55, 0.22, 0xFFC266),
                                 (10.2, 16.6, 0.26, 0xFF9A3D), (11.3, 16.75, 0.18, 0xFFC266),
                                 (10.6, 10.5, 0.16, 0xFFD58A), (7.9, 11.1, 0.12, 0xF5B95C)] as [(CGFloat, CGFloat, CGFloat, UInt32)] {
            context.setFillColor(cg(color))
            context.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        context.restoreGState()
        return context.makeImage()
    }

    /// Writes the PNGs `iconutil -c icns` wants.
    static func exportIconset(to directory: String) {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let image = render(pixels: points * scale),
                      let destination = CGImageDestinationCreateWithURL(
                          folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil
                      ) else { continue }
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    private static func fill(_ context: CGContext, _ path: CGPath, _ colors: [CGColor], _ locations: [CGFloat],
                             from bottom: CGFloat, to top: CGFloat) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: locations)!
        context.drawLinearGradient(gradient, start: CGPoint(x: 9, y: bottom), end: CGPoint(x: 9, y: top),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    private static func cg(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        NSColor(hex: hex, alpha: alpha).cgColor
    }
}
