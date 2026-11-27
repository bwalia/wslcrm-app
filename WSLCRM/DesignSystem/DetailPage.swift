import SwiftUI

// A record's page (a lead, a customer, an invoice, a job…), drawn the same way everywhere.
//
// - iPhone: the grouped list every phone screen uses, one column, the facts straight after the header.
// - iPad and Mac: cards on the canvas, centred at a readable width. A wide window has two columns: the record's work
//   (next step, activity, AI, related records) on the left, its key facts (status, owner, value, dates, contact) in a
//   narrow column on the right.
//
// A screen writes its sections once with `DetailSection`; the page decides whether each is a list section or a card.

/// How the sections of a record's page are drawn.
enum DetailLayout: Sendable {
    /// Rows of an inset grouped `List` (iPhone, and anything not inside a `DetailPage`).
    case list
    /// Cards in a scroll view (iPad, Mac).
    case cards
}

/// Which column of a wide page a card is in. The side column is narrow, so its facts stack the label over the value.
enum DetailColumn: Sendable {
    case main, side
}

/// How a label and its value (`LabeledContent`, `DetailRow`) sit in a card.
enum DetailFactStyleKind: Sendable {
    /// The platform's own row: the label on the left, the value at the far right (a phone's list).
    case automatic
    /// The label in a narrow column, the value right next to it (a wide card or list): no gap the width of a window.
    case columns
    /// The label small above the value (the side column, a grid of facts).
    case stacked
}

extension EnvironmentValues {
    @Entry var detailLayout: DetailLayout = .list
    @Entry var detailColumn: DetailColumn = .main
    @Entry var detailFactStyle: DetailFactStyleKind = .automatic
}

/// The spacing and widths of the design spec, in one place.
enum DetailMetrics {
    /// Page content on a wide window.
    static let maxWidth: CGFloat = 1040
    /// A page with one column (no side facts, or a narrow window).
    static let singleColumnMaxWidth: CGFloat = 780
    /// The facts column.
    static let sideWidth: CGFloat = 320
    /// Two columns from this much content width.
    static let twoColumnMinWidth: CGFloat = 900
    /// A paragraph's longest line.
    static let paragraphWidth: CGFloat = 720
    /// Between cards.
    static let gap: CGFloat = MacSupport.isMac ? 24 : 20
    /// Inside a card.
    static let cardPadding: CGFloat = MacSupport.isMac ? 20 : 16
    /// Around the page.
    static let gutter: CGFloat = 24
    /// Between rows in a card.
    static let rowSpacing: CGFloat = 12
}

// MARK: - Page

/// A record's page: a header, its work (`main`) and its key facts (`side`). See the top of this file.
struct DetailPage<Header: View, Main: View, Side: View>: View {
    private let header: Header
    private let main: Main
    private let side: Side
    private let hasSide: Bool
    private let factsFirst: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    /// `factsFirst`: in one column (a phone, a narrow window) the facts come straight after the header, as the
    /// design spec has it. A record whose page is mostly work to do (a lead) passes false: its work comes first.
    init(factsFirst: Bool = true, @ViewBuilder header: () -> Header, @ViewBuilder main: () -> Main,
         @ViewBuilder side: () -> Side) {
        self.header = header()
        self.main = main()
        self.side = side()
        hasSide = true
        self.factsFirst = factsFirst
    }

    var body: some View {
        if sizeClass == .compact {
            list
        } else {
            cards
        }
    }

    private var list: some View {
        List {
            Section { header }
            if factsFirst { side }
            main
            if !factsFirst { side }
        }
        .listStyle(.insetGrouped)
        .environment(\.detailLayout, .list)
    }

    private var twoColumns: Bool {
        hasSide && width >= DetailMetrics.twoColumnMinWidth + 2 * DetailMetrics.gutter
    }

    private var cards: some View {
        let gap = DetailMetrics.gap
        return ScrollView {
            VStack(alignment: .leading, spacing: gap) {
                header
                if twoColumns {
                    HStack(alignment: .top, spacing: gap) {
                        DetailColumnStack { main }
                        DetailColumnStack { side }
                            .frame(width: DetailMetrics.sideWidth)
                            .environment(\.detailColumn, .side)
                            .environment(\.detailFactStyle, .stacked)
                    }
                } else {
                    // One column: the facts after the header (as on a phone), or after the work.
                    if factsFirst { side }
                    main
                    if !factsFirst { side }
                }
            }
            .padding(DetailMetrics.gutter)
            .frame(maxWidth: twoColumns ? DetailMetrics.maxWidth : DetailMetrics.singleColumnMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .brandCanvas()
        .environment(\.detailLayout, .cards)
        .environment(\.detailFactStyle, .columns)
    }
}

extension DetailPage where Side == EmptyView {
    /// A page with one column (no facts of its own beside the work).
    init(@ViewBuilder header: () -> Header, @ViewBuilder main: () -> Main) {
        self.header = header()
        self.main = main()
        side = EmptyView()
        hasSide = false
        factsFirst = true
    }
}

private struct DetailColumnStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DetailMetrics.gap) { content }
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Section

/// One section of a record's page: a list section on a phone, a card on an iPad or a Mac (an SF Symbol and a title,
/// an optional trailing action, then the rows). Has `Section`'s shapes, so a phone's list reads exactly as before.
struct DetailSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer
    @Environment(\.detailLayout) private var layout

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        switch layout {
        case .list:
            Section { content } header: { header } footer: { footer }
        case .cards:
            VStack(alignment: .leading, spacing: DetailMetrics.rowSpacing) {
                // A plain header (a screen's own `Text`) reads as the card's title too.
                header
                    .font(.wsHeadline)
                    .foregroundStyle(Color(.label))
                content
                footer
                    .font(.wsCaption)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.detailRow)
            .labeledContentStyle(DetailFactStyle())
            .brandCard(padding: DetailMetrics.cardPadding, radius: 12)
        }
    }
}

extension DetailSection where Header == EmptyView, Footer == EmptyView {
    /// A section without a title (a notice, the delete button).
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension DetailSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension DetailSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension DetailSection where Footer == Text? {
    /// A titled section: `DetailSection("Next step", systemImage: "flag") { … }`.
    init<Trailing: View>(_ title: String, systemImage: String? = nil, footer: String? = nil,
                         @ViewBuilder content: () -> Content,
                         @ViewBuilder trailing: () -> Trailing) where Header == DetailSectionTitle<Trailing> {
        self.init(content: content,
                  header: { DetailSectionTitle(title, systemImage: systemImage, trailing: trailing) },
                  footer: { footer.map { Text($0) } })
    }

    init(_ title: String, systemImage: String? = nil, footer: String? = nil,
         @ViewBuilder content: () -> Content) where Header == DetailSectionTitle<EmptyView> {
        self.init(title, systemImage: systemImage, footer: footer, content: content, trailing: { EmptyView() })
    }
}

/// A section's title: in a card, an SF Symbol and the title in the headline face with an optional trailing action;
/// in a phone's list, the list's own section header.
struct DetailSectionTitle<Trailing: View>: View {
    let title: String
    let systemImage: String?
    let trailing: Trailing
    @Environment(\.detailLayout) private var layout

    init(_ title: String, systemImage: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        switch layout {
        case .list:
            HStack {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                Spacer(minLength: 8)
                trailing.textCase(nil)
            }
        case .cards:
            HStack(alignment: .center, spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondaryText)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.wsHeadline)
                    .foregroundStyle(Color(.label))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
                    .font(.wsSubheadline)
                    .buttonStyle(.borderless)
            }
            .padding(.bottom, 2)
        }
    }
}

extension DetailSectionTitle where Trailing == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title, systemImage: systemImage, trailing: { EmptyView() })
    }
}

// MARK: - Header

/// The picture at the start of a record's header.
enum DetailAvatar {
    /// A person or business: their initials on a colour that is always the same for the name.
    case monogram(String)
    /// A thing (an invoice, a job): its symbol on a tile.
    case icon(String, Color)
}

/// The top of a record's page: picture, title, a one-line subtitle, then `details` (status chips, a pipeline) and
/// `actions` (a `RecordActionBar`: one primary action, the rest bordered, the others under More).
struct DetailHeader<Details: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var avatar: DetailAvatar?
    private let details: Details
    private let actions: Actions
    @Environment(\.detailLayout) private var layout

    init(_ title: String, subtitle: String? = nil, avatar: DetailAvatar? = nil,
         @ViewBuilder details: () -> Details, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.avatar = avatar
        self.details = details()
        self.actions = actions()
    }

    var body: some View {
        switch layout {
        case .list:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    picture(size: 44)
                    titleBlock
                }
                details
                actions
            }
            .padding(.vertical, 4)
        case .cards:
            HStack(alignment: .top, spacing: 16) {
                picture(size: 56)
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    details
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.wsTitle2.bold())
                .foregroundStyle(Color(.label))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func picture(size: CGFloat) -> some View {
        switch avatar {
        case .monogram(let name): Monogram(name: name, size: size)
        case .icon(let systemImage, let color): AppIconTile(systemImage: systemImage, color: color, size: size)
        case nil: EmptyView()
        }
    }
}

extension DetailHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, avatar: DetailAvatar? = nil, @ViewBuilder details: () -> Details) {
        self.init(title, subtitle: subtitle, avatar: avatar, details: details, actions: { EmptyView() })
    }
}

extension DetailHeader where Details == EmptyView, Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, avatar: DetailAvatar? = nil) {
        self.init(title, subtitle: subtitle, avatar: avatar, details: { EmptyView() }, actions: { EmptyView() })
    }
}

/// Status chips under a header's title, wrapping onto a second line rather than squashing.
struct DetailChips<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ChatFlowLayout(spacing: 8) { content }
    }
}

/// A person's or business's initials on their colour.
struct Monogram: View {
    let name: String
    var size: CGFloat = 52

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.tile(for: name).gradient, in: Circle())
            .accessibilityHidden(true)
    }

    /// "Bob Blasdel" → "BB", "harbour vfx ltd" → "HV", "" → "?".
    nonisolated static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        if !letters.isEmpty { return letters.joined() }
        return name.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Facts

/// Key facts as a grid: on an iPad or a Mac, the label small above the value, as many across as fit; on a phone,
/// list rows. Put `DetailRow`s (or any `LabeledContent`) in it; empty ones disappear.
struct FactGrid<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.detailLayout) private var layout
    @Environment(\.detailColumn) private var column

    var body: some View {
        switch layout {
        case .list:
            content
        case .cards:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: column == .side ? 240 : 170), spacing: 20,
                                         alignment: .topLeading)],
                      alignment: .leading, spacing: 16) { content }
                .environment(\.detailFactStyle, .stacked)
        }
    }
}

/// A label and its value in a card: the label secondary, the value primary, close together (`detailFactStyle`).
struct DetailFactStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        DetailFactBody(configuration: configuration)
    }
}

private struct DetailFactBody: View {
    let configuration: LabeledContentStyleConfiguration
    @Environment(\.detailFactStyle) private var style

    var body: some View {
        switch style {
        case .automatic:
            LabeledContent(configuration)
        case .stacked:
            VStack(alignment: .leading, spacing: 4) {
                configuration.label
                    .font(.wsCaption)
                    .foregroundStyle(.secondaryText)
                configuration.content
                    .font(.wsBody)
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .columns:
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                configuration.label
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
                    .frame(width: 168, alignment: .leading)
                configuration.content
                    .font(.wsBody)
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 24)
        }
    }
}

// MARK: - Rows

/// A row that does something, in a card: the full width, the accent colour (red for a destructive one), a highlight
/// under the pointer. A list draws its own rows; this is what a style-less `Button`/`NavigationLink` in a card gets.
struct DetailRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DetailRowButtonBody(configuration: configuration)
    }

    private struct DetailRowButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            // As in a list: a row that can't be used now loses its accent (its own colours stay), it doesn't fade.
            configuration.label
                .foregroundStyle(!isEnabled ? Color.secondaryText
                                 : configuration.role == .destructive ? Tone.danger.textColor : Tone.brand.textColor)
                .frame(maxWidth: .infinity, minHeight: MacSupport.isMac ? 32 : 44, alignment: .leading)
                .padding(.horizontal, 8)
                .background(Color(.label).opacity(configuration.isPressed ? 0.10 : hovering && isEnabled ? 0.05 : 0),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, -8)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == DetailRowButtonStyle {
    static var detailRow: DetailRowButtonStyle { DetailRowButtonStyle() }
}

/// A related record in a section (a deal, an order, a visit): its symbol, name, a line under it, a value at the end.
/// The label of a `NavigationLink`; in a card it carries its own chevron (a list adds one).
struct RelatedRow: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var trailing: String?
    var tone: Tone = .neutral
    @Environment(\.detailLayout) private var layout

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tone.textColor)
                    .frame(width: 30, height: 30)
                    .background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.wsBody).foregroundStyle(Color(.label)).lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing).font(.wsSubheadline.monospacedDigit()).foregroundStyle(Color(.label))
            }
            if layout == .cards {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One thing that happened (a call, an email, a status change): a tinted symbol, what it was, when and who, and what
/// was said, at a readable width.
struct TimelineRow<Accessory: View>: View {
    let title: String
    var meta: String?
    var detail: String?
    var systemImage = "circle.fill"
    var tone: Tone = .neutral
    private let accessory: Accessory

    init(_ title: String, meta: String? = nil, detail: String? = nil, systemImage: String = "circle.fill",
         tone: Tone = .neutral, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.meta = meta
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.textColor)
                .frame(width: 28, height: 28)
                .background(tone.color.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                ChatFlowLayout(spacing: 6) {
                    Text(title).font(.wsSubheadline.weight(.semibold)).foregroundStyle(Color(.label))
                    accessory
                }
                if let meta, !meta.isEmpty {
                    Text(meta).font(.wsCaption).foregroundStyle(.secondaryText)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.wsSubheadline)
                        .foregroundStyle(Color(.label))
                        .lineSpacing(3)
                        .frame(maxWidth: DetailMetrics.paragraphWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

extension TimelineRow where Accessory == EmptyView {
    init(_ title: String, meta: String? = nil, detail: String? = nil, systemImage: String = "circle.fill",
         tone: Tone = .neutral) {
        self.init(title, meta: meta, detail: detail, systemImage: systemImage, tone: tone, accessory: { EmptyView() })
    }
}

// MARK: - Text

extension View {
    /// A paragraph (AI text, an email, a note): body size, a little air between lines, never wider than a readable
    /// line, never cut short.
    func wsParagraph(_ font: Font = .wsBody) -> some View {
        self.font(font)
            .lineSpacing(3)
            .frame(maxWidth: DetailMetrics.paragraphWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A long paragraph shown in part, with "Show more" (nothing important is cut off for good).
struct ExpandableText: View {
    let text: String
    var lineLimit = 6
    var font: Font = .wsBody
    @State private var expanded = false

    /// Heuristic: long enough, or enough lines, that `lineLimit` lines likely cut it.
    // ponytail: guesses from length rather than measuring the laid-out text; measure if a short text ever gets a
    // needless "Show more".
    private var isLong: Bool {
        text.count > lineLimit * 90 || text.split(separator: "\n", omittingEmptySubsequences: false).count > lineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .wsParagraph(font)
                .lineLimit(expanded || !isLong ? nil : lineLimit)
                .textSelection(.enabled)
            if isLong {
                Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    .buttonStyle(.borderless)
                    .font(.wsSubheadline.weight(.semibold))
            }
        }
    }
}

// MARK: - Lists that aren't cards yet

extension View {
    /// A record's page that is still a `List` or `Form`: on an iPad or a Mac, centred at a readable width, sections
    /// further apart, and each label next to its value instead of a window's width away. No change on a phone.
    func wsDetailList() -> some View {
        modifier(DetailListChrome())
    }
}

private struct DetailListChrome: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                // Safe-area padding, not content margins: content margins would also push in every horizontal scroll
                // view inside the rows.
                .safeAreaPadding(.horizontal, max(0, (width - DetailMetrics.singleColumnMaxWidth) / 2))
                .listSectionSpacing(DetailMetrics.gap)
                .labeledContentStyle(DetailFactStyle())
                .environment(\.detailFactStyle, .columns)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            content
        }
    }
}
