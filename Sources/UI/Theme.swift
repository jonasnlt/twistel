import AppKit
import SwiftUI

enum Theme {
    /// Emerald for surfaces with white text on them: the chosen ring item, the main button, the
    /// number on a stack. White on it meets WCAG AA in every variant (light 5.2 : 1, dark 4.6 : 1, more contrast 7.2 : 1). The app's
    /// own surfaces always use it; system controls take it only when the Mac's accent colour is "Multicolour" (`AccentColor` in
    /// Assets.car).
    static let accentNS = dynamic(name: "TwistelAccent", light: 0x0A7C5A, dark: 0x0B8565, contrastLight: 0x086448, contrastDark: 0x086448)
    /// Emerald as a symbol, line or bar on a surface (a checkmark, progress): brighter on dark glass, where the surface tone is too
    /// weak (#34C08F: at least 4.9 : 1 against dark glass; more contrast #5BD8AA, at least 6.4 : 1).
    static let accentForegroundNS = dynamic(name: "TwistelAccentForeground", light: 0x0A7C5A, dark: 0x34C08F, contrastLight: 0x086448, contrastDark: 0x5BD8AA)
    static let accent = Color(nsColor: accentNS)
    static let accentForeground = Color(nsColor: accentForegroundNS)

    /// The test access draws pictures as with "Increase contrast", without changing the Mac's setting.
    nonisolated(unsafe) static var drawingWithIncreasedContrast = false

    /// Which of the four tones an appearance gets: light or dark, with "Increase contrast" or without. The contrast comes from the Mac's
    /// setting: an appearance asked for by its high-contrast name is the normal one unless that setting is on.
    static func tone(for appearance: NSAppearance, increaseContrast: Bool) -> (dark: Bool, contrast: Bool) {
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let contrast = increaseContrast || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        return (dark, contrast)
    }

    private static func dynamic(name: String, light: Int, dark: Int, contrastLight: Int, contrastDark: Int) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let tone = tone(for: appearance, increaseContrast: drawingWithIncreasedContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            return rgb(tone.contrast ? (tone.dark ? contrastDark : contrastLight) : (tone.dark ? dark : light))
        }
    }

    static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let ink = Color(nsColor: .labelColor)
    static let cardCorner: CGFloat = 12

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// The main button of a card: emerald with white text in any window state (system buttons lose their colour while their window
/// isn't the active one, and twistel's cards never are).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent).brightness(configuration.isPressed ? -0.08 : 0))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct CardSurface: ViewModifier {
    var cornerRadius: CGFloat = Theme.cardCorner

    func body(content: Content) -> some View {
        content
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

extension View {
    func card(cornerRadius: CGFloat = Theme.cardCorner) -> some View {
        modifier(CardSurface(cornerRadius: cornerRadius))
    }
}

struct SegmentedPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
