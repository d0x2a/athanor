import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}

/// The palette from the logo — Copper #C4763A, Ember #F5B95C, Soot #1F1A16,
/// Parchment #E9DFCC — stretched into light and dark variants. Text colors
/// keep 4.5:1 against the grounds they sit on.
enum Palette {
    static let ground = NSColor.dynamic(light: 0xF6F1E7, dark: 0x1F1A16)
    static let raised = NSColor.dynamic(light: 0xEAE1D0, dark: 0x2A2420)
    static let well = NSColor.dynamic(light: 0xFBF8F2, dark: 0x15110E)
    static let line = NSColor.dynamic(light: 0xE2D8C6, dark: 0x2F2822)
    static let border = NSColor.dynamic(light: 0xD8CDB9, dark: 0x3A322B)
    static let text = NSColor.dynamic(light: 0x1F1A16, dark: 0xE9DFCC)
    static let secondary = NSColor.dynamic(light: 0x6B5F51, dark: 0xA89C8A)
    static let tertiary = NSColor.dynamic(light: 0x7A6D5D, dark: 0x948878)
    static let accentText = NSColor.dynamic(light: 0x9A5524, dark: 0xE0A36B)
    static let accentFill = NSColor.dynamic(light: 0x9A5524, dark: 0xC4763A)
    static let onAccent = NSColor.dynamic(light: 0xFFFFFF, dark: 0x1F1A16)
    static let lit = NSColor.dynamic(light: 0xD98A1F, dark: 0xF5B95C)
    static let unlit = NSColor.dynamic(light: 0x9C8F7E, dark: 0x8C8072)
    static let danger = NSColor.dynamic(light: 0xB83226, dark: 0xFF8A7E)
    static let dangerMark = NSColor.dynamic(light: 0xD93A2B, dark: 0xFF6B5E)
    static let dangerWash = NSColor.dynamic(light: 0xF7E3DC, dark: 0x2E201C)
    static let dangerBorder = NSColor.dynamic(light: 0xE9B9AC, dark: 0x4A2B25)
    static let dangerNote = NSColor.dynamic(light: 0x8E2A20, dark: 0xF2C4BC)
    static let chip = NSColor.dynamic(light: 0xEFE3D0, dark: 0x2E2620)
    static let selection = NSColor.dynamic(light: 0xE8D9C1, dark: 0x33291F)
    static let errorLine = NSColor.dynamic(light: 0xFBE9E4, dark: 0x2A1714)
}

enum Theme {
    static let ground = Color(nsColor: Palette.ground)
    static let raised = Color(nsColor: Palette.raised)
    static let well = Color(nsColor: Palette.well)
    static let line = Color(nsColor: Palette.line)
    static let border = Color(nsColor: Palette.border)
    static let text = Color(nsColor: Palette.text)
    static let secondary = Color(nsColor: Palette.secondary)
    static let tertiary = Color(nsColor: Palette.tertiary)
    static let accentText = Color(nsColor: Palette.accentText)
    static let accentFill = Color(nsColor: Palette.accentFill)
    static let onAccent = Color(nsColor: Palette.onAccent)
    static let lit = Color(nsColor: Palette.lit)
    static let unlit = Color(nsColor: Palette.unlit)
    static let danger = Color(nsColor: Palette.danger)
    static let dangerMark = Color(nsColor: Palette.dangerMark)
    static let dangerWash = Color(nsColor: Palette.dangerWash)
    static let dangerBorder = Color(nsColor: Palette.dangerBorder)
    static let dangerNote = Color(nsColor: Palette.dangerNote)
    static let chip = Color(nsColor: Palette.chip)
    static let selection = Color(nsColor: Palette.selection)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Buttons

/// Gives a button style its hover state.
private struct Hoverable<Content: View>: View {
    @State private var hovering = false
    let content: (Bool) -> Content

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

/// A square icon button: start, stop, add, settings.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = Theme.text
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hovering in
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size > 28 ? 8 : 7, style: .continuous)
                        .fill(filled || hovering ? Theme.raised : .clear)
                )
                .brightness(hovering ? 0.04 : 0)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// A small bordered text button, as in the expanded row: Restart, Open log.
struct SmallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hovering in
            configuration.label
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Theme.raised : Theme.ground.opacity(0.0001))
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// A filled button for the one thing to do next: Start again, Save and Start.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hovering in
            configuration.label
                .font(.system(size: height > 28 ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, height > 28 ? 14 : 12)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accentFill))
                .brightness(hovering ? 0.05 : 0)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// A filled neutral button: Start all and Stop all in the popover; bordered,
/// every secondary button in the windows (Cancel, Save, Choose…, Edit).
struct FilledButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var bordered = false
    var fill = Theme.raised
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: bordered ? 7 : 8, style: .continuous)
        return Hoverable { hovering in
            configuration.label
                .font(.system(size: height > 28 ? 13 : 12))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, height > 28 ? 14 : height > 24 ? 12 : 10)
                .frame(height: height)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(bordered ? Theme.border : .clear))
                .brightness(hovering ? 0.04 : 0)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// An on/off button that glows when on: Follow in the logs window.
struct LitToggleStyle: ToggleStyle {
    var height: CGFloat = 26
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let on = configuration.isOn
        return Hoverable { hovering in
            Button {
                configuration.isOn.toggle()
            } label: {
                configuration.label
                    .font(.system(size: 12, weight: on ? .medium : .regular))
                    .foregroundStyle(on ? Theme.accentText : Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: height)
                    .background(shape.fill(on ? Theme.selection : Theme.raised))
                    .overlay(shape.strokeBorder(on ? Theme.accentFill.opacity(0.55) : Theme.border))
                    .brightness(hovering ? 0.04 : 0)
                    .opacity(isEnabled ? 1 : 0.45)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(on ? "On" : "Off")
        }
    }
}

/// Text only, in the secondary color: Logs, Quit.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Theme.secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hovering in
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(hovering && isEnabled ? Theme.text : tint)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
                .contentShape(Rectangle())
        }
    }
}

/// A thin rule between sections.
struct Rule: View {
    var body: some View {
        Theme.line.frame(height: 1)
    }
}
