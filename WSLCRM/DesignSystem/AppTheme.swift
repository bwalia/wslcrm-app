import os
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Choices

/// Light, dark, or whatever the phone is set to.
enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Match my phone"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// One theme colour: the accent for links and buttons, a solid fill that carries white text, and
/// a text colour for words in the accent — each for light and dark. Every pair is at least 4.5:1
/// (`AppThemeTests`). `isHouse`: the build's own colours from the asset catalog (Workstation pink).
struct ThemeAccent: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isHouse: Bool
    let accent: RGB
    let accentDark: RGB
    let fill: RGB
    let fillDark: RGB
    let text: RGB
    let textDark: RGB

    struct RGB: Hashable, Sendable {
        let r: Double, g: Double, b: Double
        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

        /// WCAG relative luminance.
        var luminance: Double {
            func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    private func dynamic(_ light: RGB, _ dark: RGB) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark.uiColor : light.uiColor }
    }

    /// Resolved at draw time, so a colour change reaches screens as they redraw.
    func fillUIColor(_ traits: UITraitCollection) -> UIColor {
        if isHouse { return (UIColor(named: "AccentColor-Fill") ?? fill.uiColor).resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark ? fillDark.uiColor : fill.uiColor
    }

    func textUIColor(_ traits: UITraitCollection) -> UIColor {
        if isHouse { return (UIColor(named: "AccentColor-Text") ?? text.uiColor).resolvedColor(with: traits) }
        return traits.userInterfaceStyle == .dark ? textDark.uiColor : text.uiColor
    }

    /// nil for the house theme: the asset catalog's accent stays in charge.
    var tint: Color? { isHouse ? nil : Color(uiColor: dynamic(accent, accentDark)) }
    var fillColor: Color { isHouse ? Color("AccentColor-Fill") : Color(uiColor: dynamic(fill, fillDark)) }
    var textColor: Color { isHouse ? Color("AccentColor-Text") : Color(uiColor: dynamic(text, textDark)) }
    /// For swatches and icon previews.
    var swatch: Color { Color(uiColor: dynamic(accent, accentDark)) }

    static let workstation = ThemeAccent(id: "workstation", name: "Workstation", isHouse: true,
                                         accent: RGB(0xE6003F), accentDark: RGB(0xFF6088), fill: RGB(0xC20035),
                                         fillDark: RGB(0xE6003F), text: RGB(0xC20035), textDark: RGB(0xFF6088))
    static let ocean = ThemeAccent(id: "ocean", name: "Ocean", isHouse: false,
                                   accent: RGB(0x2563EB), accentDark: RGB(0x60A5FA), fill: RGB(0x1D4ED8),
                                   fillDark: RGB(0x2563EB), text: RGB(0x1D4ED8), textDark: RGB(0x93C5FD))
    static let forest = ThemeAccent(id: "forest", name: "Forest", isHouse: false,
                                    accent: RGB(0x15803D), accentDark: RGB(0x4ADE80), fill: RGB(0x166534),
                                    fillDark: RGB(0x15803D), text: RGB(0x166534), textDark: RGB(0x86EFAC))
    static let sunset = ThemeAccent(id: "sunset", name: "Sunset", isHouse: false,
                                    accent: RGB(0xC2410C), accentDark: RGB(0xFB923C), fill: RGB(0x9A3412),
                                    fillDark: RGB(0xC2410C), text: RGB(0x9A3412), textDark: RGB(0xFDBA74))
    static let violet = ThemeAccent(id: "violet", name: "Violet", isHouse: false,
                                    accent: RGB(0x7C3AED), accentDark: RGB(0xA78BFA), fill: RGB(0x6D28D9),
                                    fillDark: RGB(0x7C3AED), text: RGB(0x6D28D9), textDark: RGB(0xC4B5FD))
    static let graphite = ThemeAccent(id: "graphite", name: "Graphite", isHouse: false,
                                      accent: RGB(0x334155), accentDark: RGB(0x94A3B8), fill: RGB(0x334155),
                                      fillDark: RGB(0x475569), text: RGB(0x334155), textDark: RGB(0xCBD5E1))

    static let all: [ThemeAccent] = [.workstation, .ocean, .forest, .sunset, .violet, .graphite]

    static func named(_ id: String?) -> ThemeAccent { all.first { $0.id == id } ?? .workstation }

    // The theme on screen now, for code that isn't a view (`Tone.brand`).
    private static let storage = OSAllocatedUnfairLock(initialState: ThemeAccent.workstation)
    static var current: ThemeAccent { storage.withLock { $0 } }
    static func setCurrent(_ accent: ThemeAccent) { storage.withLock { $0 = accent } }
}

/// The home-screen icon: the Workstation icon or one of the bundled alternatives.
struct AppIconChoice: Identifiable, Hashable, Sendable {
    /// nil: the primary icon.
    let iconName: String?
    let name: String
    let accent: ThemeAccent
    var id: String { iconName ?? "primary" }

    static let all: [AppIconChoice] = [
        AppIconChoice(iconName: nil, name: "Workstation", accent: .workstation),
        AppIconChoice(iconName: "AppIcon-Ocean", name: "Ocean", accent: .ocean),
        AppIconChoice(iconName: "AppIcon-Forest", name: "Forest", accent: .forest),
        AppIconChoice(iconName: "AppIcon-Sunset", name: "Sunset", accent: .sunset),
        AppIconChoice(iconName: "AppIcon-Violet", name: "Violet", accent: .violet),
        AppIconChoice(iconName: "AppIcon-Graphite", name: "Graphite", accent: .graphite),
    ]
}

/// Which logo the app shows (sign-in, Home, the navigation bar).
enum LogoChoice: String, CaseIterable, Identifiable, Sendable {
    /// The signed-in workspace's own logo (from the server), else Workstation's.
    case workspace
    /// Always Workstation's.
    case house
    /// A picture the person chose on this phone.
    case custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .workspace: "My workspace's logo"
        case .house: "Workstation logo"
        case .custom: "My own picture"
        }
    }
}

// MARK: - Store

/// The person's look for the app on this phone: appearance, colour, home-screen icon and logo.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var appearance: AppearanceChoice
    private(set) var accent: ThemeAccent
    private(set) var logo: LogoChoice
    private(set) var iconName: String?
    /// Bumped when the custom picture changes, so views showing it redraw.
    private(set) var logoVersion = 0
    private(set) var problem: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let customLogoURL: URL

    init(defaults: UserDefaults = .standard, directory: URL = ThemeStore.defaultDirectory()) {
        self.defaults = defaults
        customLogoURL = directory.appendingPathComponent("my-logo.png")
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        accent = ThemeAccent.named(defaults.string(forKey: Keys.accent))
        logo = LogoChoice(rawValue: defaults.string(forKey: Keys.logo) ?? "") ?? .workspace
        iconName = defaults.string(forKey: Keys.icon)
        if logo == .custom, !FileManager.default.fileExists(atPath: customLogoURL.path) { logo = .workspace }
        ThemeAccent.setCurrent(accent)
    }

    enum Keys {
        static let appearance = "theme.appearance"
        static let accent = "theme.accent"
        static let logo = "theme.logo"
        static let icon = "theme.icon"
    }

    nonisolated static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Theme", isDirectory: true)
    }

    func setAppearance(_ choice: AppearanceChoice) {
        appearance = choice
        defaults.set(choice.rawValue, forKey: Keys.appearance)
    }

    func setAccent(_ choice: ThemeAccent) {
        accent = choice
        ThemeAccent.setCurrent(choice)
        defaults.set(choice.id, forKey: Keys.accent)
    }

    func setLogo(_ choice: LogoChoice) {
        guard choice != .custom || FileManager.default.fileExists(atPath: customLogoURL.path) else { return }
        logo = choice
        defaults.set(choice.rawValue, forKey: Keys.logo)
    }

    /// Keeps the person's picture (at most 512 points, as PNG) and shows it as the logo.
    @discardableResult
    func setCustomLogo(_ data: Data) -> Bool {
        guard let image = UIImage(data: data) else {
            problem = "That picture couldn't be opened. Try another one."
            return false
        }
        let side: CGFloat = 512
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = resized.pngData() else { return false }
        do {
            try FileManager.default.createDirectory(at: customLogoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: customLogoURL, options: .atomic)
        } catch {
            problem = "The picture couldn't be saved on this phone."
            return false
        }
        problem = nil
        logoVersion += 1
        setLogo(.custom)
        return true
    }

    /// The home-screen icon. iOS shows its own short message when it changes.
    func setIcon(_ choice: AppIconChoice) async {
        guard UIApplication.shared.supportsAlternateIcons else {
            problem = "This device can't change the app's icon (a Mac keeps the standard one)."
            return
        }
        do {
            try await UIApplication.shared.setAlternateIconName(choice.iconName)
            iconName = choice.iconName
            defaults.set(choice.iconName, forKey: Keys.icon)
            problem = nil
        } catch {
            problem = "The icon couldn't be changed: \(error.localizedDescription)"
        }
    }

    func resetAll() async {
        setAppearance(.system)
        setAccent(.workstation)
        setLogo(.workspace)
        if iconName != nil { await setIcon(AppIconChoice.all[0]) }
    }

    /// The custom picture, when that's the logo in use.
    var customLogo: UIImage? {
        guard logo == .custom else { return nil }
        return UIImage(contentsOfFile: customLogoURL.path)
    }
}

/// Applies the person's appearance and colour to everything below it (the app's root).
struct ThemeModifier: ViewModifier {
    @State private var theme = ThemeStore.shared

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.appearance.colorScheme)
            .tint(theme.accent.tint)
            // `Color.accentColor` (used across the app) follows this; `.tint` covers controls.
            .accentColor(theme.accent.tint)
    }
}

// MARK: - Settings › Appearance

struct AppearanceSettingsView: View {
    @State private var theme = ThemeStore.shared
    @State private var photo: PhotosPickerItem?
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(get: { theme.appearance }, set: { theme.setAppearance($0) })) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("appearance.mode")
            } header: {
                Text("Light or dark")
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                    ForEach(ThemeAccent.all) { accent in
                        Button { theme.setAccent(accent) } label: {
                            VStack(spacing: 8) {
                                Circle()
                                    .fill(accent.swatch)
                                    .frame(width: 44, height: 44)
                                    .overlay {
                                        if theme.accent == accent {
                                            Image(systemName: "checkmark").font(.headline.bold()).foregroundStyle(.white)
                                        }
                                    }
                                Text(accent.name).font(.wsFootnote).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 72)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(accent.name)\(theme.accent == accent ? ", chosen" : "")")
                        .accessibilityIdentifier("appearance.accent.\(accent.id)")
                    }
                }
                .padding(.vertical, 6)
                previewButtons
            } header: {
                Text("Colour")
            } footer: {
                Text("Buttons, links and highlights across the app use this colour.")
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)], spacing: 14) {
                    ForEach(AppIconChoice.all) { icon in
                        Button { Task { await theme.setIcon(icon) } } label: {
                            VStack(spacing: 8) {
                                IconPreview(accent: icon.accent, chosen: theme.iconName == icon.iconName)
                                Text(icon.name).font(.wsFootnote).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 84)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(icon.name) icon\(theme.iconName == icon.iconName ? ", chosen" : "")")
                        .accessibilityIdentifier("appearance.icon.\(icon.id)")
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("Home screen icon")
            }

            Section {
                HStack(spacing: 14) {
                    BrandMark(size: 56)
                    Text(theme.logo.label).font(.wsHeadline)
                }
                .padding(.vertical, 4)
                Picker("Logo", selection: Binding(get: { theme.logo }, set: { theme.setLogo($0) })) {
                    ForEach(LogoChoice.allCases.filter { $0 != .custom || theme.customLogo != nil || theme.logo == .custom }) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("appearance.logo")
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(theme.customLogo == nil ? "Choose a picture" : "Choose a different picture", systemImage: "photo")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("appearance.logo.pick")
            } header: {
                Text("Logo")
            } footer: {
                Text("Shown when you sign in, on Home and at the top of screens. Your workspace's logo for everyone is set by its owner in Workspace settings.")
            }

            if let problem = theme.problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }

            Section {
                Button("Go back to the standard look", role: .destructive) { confirmingReset = true }
                    .accessibilityIdentifier("appearance.reset")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { theme.setCustomLogo(data) }
                photo = nil
            }
        }
        .confirmationDialog("Go back to the standard look?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Use the standard look", role: .destructive) { Task { await theme.resetAll() } }
        } message: {
            Text("Light or dark follows your phone, the colour, icon and logo go back to Workstation's.")
        }
    }

    /// A live preview of the colour on a button, a link and a status pill.
    private var previewButtons: some View {
        HStack(spacing: 12) {
            Text("Button")
                .font(.wsSubheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(theme.accent.fillColor, in: Capsule())
            Text("A link").font(.wsSubheadline).foregroundStyle(theme.accent.textColor)
            StatusBadge(text: "Chosen", systemImage: "star", tone: .brand)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of the colour")
    }
}

/// A drawn preview of a home-screen icon (iOS doesn't hand an app its alternate icons as images).
private struct IconPreview: View {
    let accent: ThemeAccent
    let chosen: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [accent.swatch.opacity(0.85), accent.fillColor],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 56, height: 56)
            .overlay { Text("W").font(.system(size: 28, weight: .black)).foregroundStyle(.white) }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(chosen ? Color.primary : .clear, lineWidth: 3)
                    .padding(-4)
            }
            .accessibilityHidden(true)
    }
}
