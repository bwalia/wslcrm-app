import SwiftUI

/// Draws rich content natively (never a web view): a post, a lesson, a form's description, an email.
///
/// `.content` follows the app's own colours and dark mode; `.email` draws the design's own colours
/// on white paper, the way the email arrives.
struct RichTextView: View {
    enum Appearance { case content, email }

    let document: RichDocument
    var appearance: Appearance = .content
    /// Whether links and buttons open (off in previews of something not sent yet).
    var linksOpen = true

    init(_ document: RichDocument, appearance: Appearance = .content, linksOpen: Bool = true) {
        self.document = document
        self.appearance = appearance
        self.linksOpen = linksOpen
    }

    init(html: String, appearance: Appearance = .content, linksOpen: Bool = true) {
        self.init(.html(html), appearance: appearance, linksOpen: linksOpen)
    }

    init(markdown: String, linksOpen: Bool = true) {
        self.init(.markdown(markdown), linksOpen: linksOpen)
    }

    var body: some View {
        if appearance == .email {
            content
                .padding(16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.12)))
                .environment(\.colorScheme, .light)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block, appearance: appearance, linksOpen: linksOpen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in linksOpen ? .systemAction(url) : .discarded })
    }
}

private struct RichBlockView: View {
    let block: RichBlock
    let appearance: RichTextView.Appearance
    let linksOpen: Bool

    var body: some View {
        switch block {
        case .heading(let level, let text, let align):
            Text(text)
                .font(Self.headingFont(level))
                .multilineTextAlignment(align.text)
                .frame(maxWidth: .infinity, alignment: align.frame)
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text, let align, let background):
            let shown = Text(text).font(.wsBody).multilineTextAlignment(align.text)
                .frame(maxWidth: .infinity, alignment: align.frame)
            if appearance == .email, let background {
                shown
                    .foregroundStyle(background.isLight ? Color.black : Color.white)
                    .padding(12)
                    .background(background.color, in: RoundedRectangle(cornerRadius: 6))
            } else {
                shown
            }
        case .listItem(let ordered, let number, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordered ? "\(number)." : (depth == 0 ? "•" : "◦"))
                    .font(.wsBody.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                    .accessibilityHidden(true)
                Text(text).font(.wsBody)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6)).frame(width: 4)
                Text(text).font(.wsBody.italic()).foregroundStyle(.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .image(let url, let alt, let width, let align):
            RichImage(url: url, alt: alt, width: width)
                .frame(maxWidth: .infinity, alignment: align.frame)
        case .button(let label, let url, let background, let foreground, let align):
            let fill = background?.color ?? Color.accentColor
            let ink = foreground?.color ?? ((background?.isLight ?? false) ? Color.black : Color.white)
            Group {
                if linksOpen, let url, url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) { buttonLabel(label, ink: ink, fill: fill) }
                } else {
                    buttonLabel(label, ink: ink, fill: fill)
                        .accessibilityAddTraits(.isButton)
                }
            }
            .frame(maxWidth: .infinity, alignment: align.frame)
        case .rule:
            Divider()
        case .table(let rows, let hasHeader):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(index == 0 && hasHeader ? .wsSubheadline.weight(.semibold) : .wsSubheadline)
                            }
                        }
                        if index == 0 && hasHeader { Divider() }
                    }
                }
                .padding(10)
            }
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .embed(let kind, let url):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kind) in this content").font(.wsSubheadline.weight(.semibold))
                    Text(url?.host() ?? "It plays where the content is published.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            } icon: {
                Image(systemName: kind == "Audio" ? "waveform" : "play.rectangle")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func buttonLabel(_ label: String, ink: Color, fill: Color) -> some View {
        Text(label)
            .font(.wsHeadline)
            .foregroundStyle(ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .wsTitle
        case 2: .wsTitle2
        case 3: .wsTitle3
        default: .wsHeadline
        }
    }
}

/// An image from the content, loaded natively, with its description when it can't load.
struct RichImage: View {
    let url: URL?
    let alt: String?
    var width: Double?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(alt ?? "Image")
            case .failure:
                Label(alt ?? "This image couldn’t be loaded.", systemImage: "photo")
                    .font(.wsFootnote)
                    .foregroundStyle(.secondaryText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            default:
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                    .frame(height: 140)
                    .overlay(ProgressView())
                    .accessibilityLabel("Loading image")
            }
        }
        .frame(maxWidth: width.map { CGFloat($0) })
    }
}
