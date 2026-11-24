import CoreText
import SwiftUI
import UIKit

/// The brand's type system, the same as the website and web dashboard (ws-theme.css):
///
/// - **Poppins** — body copy and UI
/// - **Unbounded** — display headings and brand moments (large titles, hero numbers)
/// - **JetBrains Mono** — eyebrows, prices, references, data
///
/// Every style scales with Dynamic Type (`relativeTo:`), so a person's text size setting is
/// respected exactly as it was with the system font.
enum BrandFont {
    enum Face: String, CaseIterable {
        case regular = "Poppins-Regular"
        case medium = "Poppins-Medium"
        case semibold = "Poppins-SemiBold"
        case bold = "Poppins-Bold"
        case displaySemibold = "Unbounded-SemiBold"
        case display = "Unbounded-Bold"
        case mono = "JetBrainsMono-Regular"
        case monoMedium = "JetBrainsMono-Medium"
    }

    /// Registers the bundled font files once, before the first screen draws. Registering at run
    /// time (rather than `UIAppFonts`) keeps every build configuration's Info.plist untouched.
    @MainActor
    static func register(bundle: Bundle = .main) {
        guard !registered else { return }
        registered = true
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        BrandAppearance.apply()
    }

    @MainActor private static var registered = false

    /// True when the face is installed; otherwise the styles fall back to the system font.
    static func isAvailable(_ face: Face) -> Bool {
        UIFont(name: face.rawValue, size: 12) != nil
    }

    /// The Mac reads from further away than a phone, and a Mac window is wide: every size steps up
    /// there, so text isn't left looking tiny on a big screen (the system's own Mac text styles
    /// don't apply to the brand's custom faces).
    static let platformScale: CGFloat = ProcessInfo.processInfo.isMacCatalystApp ? 1.18 : 1

    static func font(_ face: Face, size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom(face.rawValue, size: (size * platformScale).rounded(), relativeTo: style)
    }

    static func uiFont(_ face: Face, size: CGFloat, style: UIFont.TextStyle) -> UIFont {
        let scaled = (size * platformScale).rounded()
        let base = UIFont(name: face.rawValue, size: scaled) ?? .systemFont(ofSize: scaled)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
}

extension Font {
    // Display (Unbounded): sparingly, for the one thing a screen is about.
    static let brandHero = BrandFont.font(.display, size: 30, relativeTo: .largeTitle)
    static let brandDisplay = BrandFont.font(.display, size: 24, relativeTo: .title)
    static let brandTitle = BrandFont.font(.displaySemibold, size: 20, relativeTo: .title2)
    static let brandMetric = BrandFont.font(.display, size: 26, relativeTo: .title)

    // Text (Poppins).
    static let brandHeadline = BrandFont.font(.semibold, size: 17, relativeTo: .headline)
    static let brandBody = BrandFont.font(.regular, size: 16, relativeTo: .body)
    static let brandCallout = BrandFont.font(.medium, size: 15, relativeTo: .callout)
    static let brandSubheadline = BrandFont.font(.regular, size: 15, relativeTo: .subheadline)
    static let brandFootnote = BrandFont.font(.medium, size: 14, relativeTo: .footnote)
    static let brandCaption = BrandFont.font(.medium, size: 13, relativeTo: .caption)

    // Data (JetBrains Mono): eyebrows, references, amounts.
    static let brandEyebrow = BrandFont.font(.monoMedium, size: 12.5, relativeTo: .caption)
    static let brandMono = BrandFont.font(.mono, size: 14, relativeTo: .subheadline)
}

/// UIKit chrome SwiftUI doesn't style itself: navigation bar titles and the tab bar.
@MainActor
enum BrandAppearance {
    static func apply() {
        let large = BrandFont.uiFont(.display, size: 30, style: .largeTitle)
        let inline = BrandFont.uiFont(.semibold, size: 17, style: .headline)
        let bar = UINavigationBar.appearance()
        bar.largeTitleTextAttributes = [.font: large]
        bar.titleTextAttributes = [.font: inline]

        let barButton = BrandFont.uiFont(.medium, size: 17, style: .body)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: barButton], for: .normal)

        let tab = BrandFont.uiFont(.medium, size: 10, style: .caption2)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .selected)

        UISegmentedControl.appearance().setTitleTextAttributes(
            [.font: BrandFont.uiFont(.medium, size: 13, style: .footnote)], for: .normal)
    }
}

/// Brand faces for each system text style, so every screen reads in the brand's type while keeping
/// the style's role and Dynamic Type scaling: `.font(.wsHeadline)` where a screen would have said
/// `.font(.headline)`. Weight modifiers (`.weight(.semibold)`, `.bold()`) resolve within the family.
extension Font {
    static let wsLargeTitle = BrandFont.font(.display, size: 30, relativeTo: .largeTitle)
    static let wsTitle = BrandFont.font(.displaySemibold, size: 24, relativeTo: .title)
    static let wsTitle2 = BrandFont.font(.displaySemibold, size: 20, relativeTo: .title2)
    static let wsTitle3 = BrandFont.font(.semibold, size: 19, relativeTo: .title3)
    static let wsHeadline = BrandFont.font(.semibold, size: 16, relativeTo: .headline)
    static let wsBody = BrandFont.font(.regular, size: 16, relativeTo: .body)
    static let wsCallout = BrandFont.font(.regular, size: 15, relativeTo: .callout)
    static let wsSubheadline = BrandFont.font(.regular, size: 15, relativeTo: .subheadline)
    static let wsFootnote = BrandFont.font(.medium, size: 13.5, relativeTo: .footnote)
    // Small Poppins Regular is thin; Medium keeps captions and footnotes legible (HIG › Typography).
    static let wsCaption = BrandFont.font(.medium, size: 13, relativeTo: .caption)
    static let wsCaption2 = BrandFont.font(.medium, size: 12, relativeTo: .caption2)
}
