import SwiftUI
import AppKit

/// The user's appearance choice. `.system` follows macOS; the other two pin the
/// whole app — windows, the menu-bar panel, `NSMenu` and the alert panel — to
/// one appearance.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil means "inherit", which is what SwiftUI wants for "follow the system".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The AppKit half of the same choice. SwiftUI can't reach window chrome,
    /// the popover/panel background, `NSMenu` or the floating alert panel, so
    /// both halves are applied together — see `AppState.applyTheme()`.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

enum PSTheme {
    /// A colour that re-resolves every time the effective appearance changes.
    /// `static let` is still correct for the palette: the stored value is a
    /// *dynamic* NSColor, not a frozen RGBA, so switching between light and
    /// dark needs no reload and no view rebuild.
    private static func adaptive(_ dark: NSColor, _ light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func grey(_ dark: CGFloat, _ light: CGFloat) -> Color {
        adaptive(NSColor(white: dark, alpha: 1), NSColor(white: light, alpha: 1))
    }

    private static func rgb(
        _ dark: (CGFloat, CGFloat, CGFloat),
        _ light: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        adaptive(
            NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: 1),
            NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        )
    }

    /// Like `rgb`, but the dark side carries alpha so a tint can sit over the
    /// dark surface the way it always has, while light mode gets a full-strength
    /// colour. Only for backdrops that carry white text.
    private static func fill(
        _ dark: (CGFloat, CGFloat, CGFloat),
        alpha darkAlpha: CGFloat,
        _ light: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        adaptive(
            NSColor(red: dark.0, green: dark.1, blue: dark.2, alpha: darkAlpha),
            NSColor(red: light.0, green: light.1, blue: light.2, alpha: 1)
        )
    }

    // MARK: - Surfaces

    static let bgPrimary = grey(0.075, 0.980)
    static let bgSecondary = grey(0.105, 0.955)
    static let bgTertiary = grey(0.135, 0.915)
    static let bgSidebar = grey(0.085, 0.945)
    static let bgRow = grey(0.115, 0.935)
    static let bgRowAlt = grey(0.130, 0.905)
    static let stroke = grey(0.220, 0.820)

    // MARK: - Text

    static let textPrimary = grey(0.950, 0.110)
    static let textSecondary = grey(0.650, 0.380)
    static let textMuted = grey(0.450, 0.560)

    // MARK: - Accents
    //
    // The dark values are the original ones, unchanged: dark mode must look
    // exactly as it did before. The light values are the same hues darkened,
    // because the originals were only ever tuned against a near-black surface
    // (saturated yellow on white in particular reads as a highlighter smear).

    static let accent = rgb((1.00, 0.45, 0.30), (0.84, 0.30, 0.14)) // Little Snitch orange
    static let accentGreen = rgb((0.28, 0.78, 0.45), (0.08, 0.52, 0.26))
    static let accentRed = rgb((0.95, 0.30, 0.30), (0.78, 0.15, 0.17))
    static let accentYellow = rgb((1.00, 0.78, 0.20), (0.66, 0.44, 0.00))
    static let accentBlue = rgb((0.30, 0.55, 1.00), (0.12, 0.39, 0.88))
    // MARK: - Traffic
    //
    // Download/in is blue and upload/out is purple, which is the language the
    // rest of the app already speaks. The two constants used to hold the
    // opposite hues, and were never read by anything — so wiring them up for the
    // first time would have silently swapped the colours on every graph.

    static let trafficIn = rgb((0.40, 0.60, 1.00), (0.10, 0.34, 0.85))
    static let trafficOut = rgb((0.62, 0.36, 0.95), (0.42, 0.16, 0.72))

    /// Backdrops that carry white text. A translucent tint over a near-black
    /// surface reads as a deep colour; the same value over a light surface
    /// washes out and leaves white text illegible.
    static let inPillFill = fill((0.30, 0.50, 1.00), alpha: 0.40, (0.08, 0.30, 0.80))
    static let outPillFill = fill((0.58, 0.32, 0.92), alpha: 0.40, (0.40, 0.14, 0.70))
}

enum AppIcon {
    /// Resolves a real application icon from a bundle id, executable/app path,
    /// or app name. Returns nil if the app can't be located on this machine
    /// (callers fall back to an SF Symbol). NSWorkspace caches icons, so this
    /// is cheap enough to call from a list row.
    static func resolve(bundleId: String? = nil, path: String? = nil, name: String? = nil) -> NSImage? {
        let ws = NSWorkspace.shared
        if let bid = bundleId, !bid.isEmpty,
           let url = ws.urlForApplication(withBundleIdentifier: bid) {
            return ws.icon(forFile: url.path)
        }
        if let p = path, !p.isEmpty {
            var appPath = p
            // Match the LAST ".app/" so nested bundles (…/Foo.app/…/Bar.app/…)
            // resolve to the innermost app that owns the executable.
            if let r = appPath.range(of: ".app/", options: .backwards) {
                appPath = String(appPath[..<r.upperBound])
            }
            if FileManager.default.fileExists(atPath: appPath) {
                return ws.icon(forFile: appPath)
            }
        }
        if let n = name, !n.isEmpty {
            let dirs = ["/Applications",
                        "\(NSHomeDirectory())/Applications",
                        "/System/Applications",
                        "/Applications/Utilities",
                        "/System/Applications/Utilities"]
            for dir in dirs {
                let candidate = "\(dir)/\(n).app"
                if FileManager.default.fileExists(atPath: candidate) {
                    return ws.icon(forFile: candidate)
                }
            }
        }
        return nil
    }
}

enum PSFormat {
    static func bytes(_ n: Int64) -> String {
        let b = Double(n)
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1024*1024 { return String(format: "%.1f KB", b/1024) }
        if b < 1024*1024*1024 { return String(format: "%.1f MB", b/1024/1024) }
        return String(format: "%.2f GB", b/1024/1024/1024)
    }
    static func bytesPerSec(_ n: Int64) -> String {
        return "\(bytes(n))/s"
    }
    static func compactCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n)/1000) }
        return String(format: "%.1fM", Double(n)/1_000_000)
    }
}

struct PSChip: View {
    let text: String
    let color: Color
    let icon: String?
    init(_ text: String, color: Color = PSTheme.accent, icon: String? = nil) {
        self.text = text; self.color = color; self.icon = icon
    }
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.18))
        .foregroundColor(color)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
    }
}

struct PSPanel<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        content()
            .background(PSTheme.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PSTheme.stroke, lineWidth: 0.5))
    }
}
