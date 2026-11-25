import SwiftUI
import UIKit

// MARK: - Palette

/// The brand's surfaces, from the website theme (ws-theme.css). The accent itself stays the
/// build's own (`Color.accentColor`: Workstation pink, DBS blue), so a white-label build keeps
/// its colour; navy and indigo are the dark "brand moment" surfaces both builds share.
enum Palette {
    static let navy = Color(red: 0x0D / 255, green: 0x0B / 255, blue: 0x21 / 255)
    static let navyAlt = Color(red: 0x15 / 255, green: 0x13 / 255, blue: 0x2B / 255)
    static let indigo = Color(red: 0x22 / 255, green: 0x1D / 255, blue: 0x4C / 255)
    static let indigo2 = Color(red: 0x2C / 255, green: 0x25 / 255, blue: 0x59 / 255)

    /// Text on the dark surfaces, identical in both appearances (ws-theme: on-dark-*).
    static let onDarkInk = Color(red: 0xE9 / 255, green: 0xE7 / 255, blue: 0xF5 / 255)
    static let onDarkMuted = Color(red: 0xA1 / 255, green: 0x9D / 255, blue: 0xC2 / 255)

    /// The screen background behind cards: a faint brand-tinted grey, near-black in dark mode.
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.035, blue: 0.09, alpha: 1)
            : UIColor(red: 0.965, green: 0.96, blue: 0.98, alpha: 1)
    })

    /// A card on the canvas.
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.09, green: 0.08, blue: 0.17, alpha: 1)
            : .white
    })

    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06)
    })

    static let heroGradient = LinearGradient(colors: [navy, indigo2], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Distinct, readable tile colours for app icons, picked by area so the same area always has
    /// the same colour. White glyphs on each are above 4.5:1.
    static let tileColors: [Color] = [
        Color(red: 0.84, green: 0.00, blue: 0.25),   // pink
        Color(red: 0.36, green: 0.22, blue: 0.80),   // violet
        Color(red: 0.00, green: 0.42, blue: 0.75),   // blue
        Color(red: 0.00, green: 0.45, blue: 0.42),   // teal
        Color(red: 0.11, green: 0.45, blue: 0.20),   // green
        Color(red: 0.70, green: 0.33, blue: 0.00),   // amber
        Color(red: 0.62, green: 0.13, blue: 0.55),   // magenta
        Color(red: 0.22, green: 0.25, blue: 0.36),   // slate
    ]

    /// A stable colour for a key (an area or group), the same on every launch.
    static func tile(for key: String) -> Color {
        let sum = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tileColors[sum % tileColors.count]
    }
}

// MARK: - Surfaces

extension View {
    /// The app's card: rounded, on the canvas, with a hairline and soft shadow.
    func brandCard(padding: CGFloat = 16, radius: CGFloat = 20) -> some View {
        // The Mac: tighter corners and a crisper shadow, as desktop panels have.
        let radius = MacSupport.isMac ? min(radius, 12) : radius
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.hairline))
            .shadow(color: .black.opacity(MacSupport.isMac ? 0.06 : 0.05), radius: MacSupport.isMac ? 3 : 12,
                    y: MacSupport.isMac ? 1 : 4)
    }

    /// The canvas behind a scrolling dashboard of cards.
    func brandCanvas() -> some View {
        background(Palette.canvas.ignoresSafeArea())
    }
}

/// A rounded "squircle" app icon: white SF Symbol on a colour tile.
struct AppIconTile: View {
    let systemImage: String
    var color: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.92), color], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A section heading on a dashboard: mono eyebrow over an optional trailing action.
struct DashboardSectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.brandEyebrow)
                .tracking(1.2)
                .foregroundStyle(.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
                .font(.brandCaption)
        }
        .padding(.horizontal, 4)
    }
}

extension DashboardSectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// A small rounded label: "Web", "3 unsynced", a workspace name.
struct Pill: View {
    let text: String
    var systemImage: String?
    var foreground: Color = .secondaryText
    var background: Color = Color(.tertiarySystemFill)

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.brandCaption)
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background, in: Capsule())
    }
}

extension Tone {
    /// Overdue, unassigned, waiting: a number in this tone needs someone.
    var needsAttention: Bool { self == .danger || self == .warning }
}

extension View {
    /// The card every number in the app sits on (MetricCard, StatTile, MetricTile): the card surface, a hairline edge
    /// and a soft shadow. A number that needs someone carries its tone's colour: a soft wash and a coloured edge.
    func numberCard(tone: Tone = .brand, padding: CGFloat = 14) -> some View {
        modifier(NumberCardChrome(tone: tone, padding: padding))
    }
}

private struct NumberCardChrome: ViewModifier {
    let tone: Tone
    let padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MacSupport.isMac ? 12 : 18, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Palette.card)
                if tone.needsAttention {
                    shape.fill(LinearGradient(colors: [tone.color.opacity(0.13), tone.color.opacity(0.03)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay(shape.stroke(tone.needsAttention ? tone.color.opacity(0.40) : Palette.hairline))
            .shadow(color: .black.opacity(MacSupport.isMac ? 0.06 : 0.05), radius: MacSupport.isMac ? 3 : 10,
                    y: MacSupport.isMac ? 1 : 3)
    }
}

/// A number on a dashboard: big Unbounded figure, small caption, tinted icon. A number that needs someone (a danger
/// or warning tone: overdue, unassigned, waiting) carries its colour: a soft wash, a coloured edge and figure, so the
/// eye finds it first.
struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    var tone: Tone = .brand
    /// A phone's dashboard of many numbers: the icon beside the figure, so the cards are a third shorter.
    var compact = false

    private var needsAttention: Bool { tone.needsAttention }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            if compact {
                HStack(spacing: 10) { icon; figure }
            } else {
                icon
                figure
            }
            Text(title)
                .font(.brandCaption)
                .foregroundStyle(.secondaryText)
                .lineLimit(2)
        }
        .numberCard(tone: tone, padding: compact ? 12 : 14)
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tone.textColor)
            .frame(width: 30, height: 30)
            .background(tone.color.opacity(needsAttention ? 0.20 : 0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var figure: some View {
        Text(value)
            .font(.brandMetric)
            .monospacedDigit()
            .foregroundStyle(needsAttention ? tone.textColor : Color(.label))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// Press feedback for cards and tiles: a slight shrink, no colour flash. With a pointer (Mac, iPad trackpad) the
/// card lifts a little under it, so it reads as clickable.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableCardBody(configuration: configuration)
    }

    private struct PressableCardBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.9 : 1)
                .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 10, y: 4)
                .offset(y: hovering && !configuration.isPressed ? -1 : 0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PressableCardStyle {
    static var pressableCard: PressableCardStyle { PressableCardStyle() }
}
