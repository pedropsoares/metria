import SwiftUI
import UIKit

/// Mirrors the color thresholds and logo mapping in `apps/pwa/public/app.js`'s
/// `usageColor`/`providerLogo`, so the widget and the app render the same numbers the
/// same way the PWA and the Mac dashboard already do.
public enum UsagePresentation {
    public static func color(for percent: Double) -> Color {
        if percent >= 85 { return Color(red: 1, green: 0.27, blue: 0.23) }
        if percent >= 65 { return Color(red: 1, green: 0.62, blue: 0.04) }
        if percent >= 40 { return Color(red: 1, green: 0.84, blue: 0.04) }
        return Color(red: 0.19, green: 0.82, blue: 0.35)
    }

    public static func logoAssetName(for providerName: String) -> String? {
        switch providerName {
        case "Claude": "claude-logo"
        case "Codex": "codex-logo"
        case "OpenCode Go": "opencode-logo"
        case "Cursor": "cursor-logo"
        default: nil
        }
    }

    /// The provider logos ship as loose PNGs copied from `Assets/` (the same files the
    /// macOS app and the PWA use) rather than as an asset catalog, and SwiftUI's
    /// `Image(_:)` resolves catalog entries only — so load them from the bundle by path.
    /// Look in `Bundle.main` so the same helper works in the app and in the widget
    /// extension, each of which copies the PNGs into its own product.
    public static func image(named name: String) -> Image? {
        guard let uiImage = uiImage(named: name) else { return nil }
        return Image(uiImage: uiImage.withRenderingMode(.alwaysOriginal))
    }

    public static func logo(for providerName: String, size: CGFloat) -> some View {
        Group {
            if let name = logoAssetName(for: providerName), let image = image(named: name) {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "chart.bar.fill").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func uiImage(named name: String) -> UIImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Assets"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return UIImage(named: name)
    }
}

/// A funny offline line paired with the true age of the last reading, never a jokey
/// stand-in for it — see Plan 004 Phase 4. Chosen deterministically from the age so it
/// does not flicker between one timeline reload and the next.
public enum OfflineCopy {
    private static let lines = [
        "Your Mac is asleep. Your quota is not.",
        "No signal from the Mac. Assume you spent it all.",
        "Offline. The tokens are burning unsupervised.",
        "Can't reach the Mac. Hope is not a usage strategy."
    ]

    public static func line(for age: TimeInterval) -> String {
        let bucket = Int(age / 600)
        return lines[bucket % lines.count]
    }
}
