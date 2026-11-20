import SwiftUI
import UIKit

// The words of a lesson block, edited natively with formatting: inline HTML (bold, italic,
// underline, strikethrough, code, colour, highlight, subscript, superscript, links) is read into
// styled text for a UITextView and written back as the HTML the web's editor writes. No web view
// and no HTML importer: the markup is read and written here.

extension NSAttributedString.Key {
    /// `AcademyMarks` raw value.
    static let academyMarks = NSAttributedString.Key("academyMarks")
    /// Where a link goes, as written.
    static let academyHref = NSAttributedString.Key("academyHref")
    /// A text colour the author chose (CSS, e.g. `#e11d48`).
    static let academyColour = NSAttributedString.Key("academyColour")
    /// A highlight colour ("" for the standard yellow marker).
    static let academyHighlight = NSAttributedString.Key("academyHighlight")
}

struct AcademyMarks: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let bold = AcademyMarks(rawValue: 1)
    static let italic = AcademyMarks(rawValue: 2)
    static let underline = AcademyMarks(rawValue: 4)
    static let strike = AcademyMarks(rawValue: 8)
    static let code = AcademyMarks(rawValue: 16)
    static let sub = AcademyMarks(rawValue: 32)
    static let sup = AcademyMarks(rawValue: 64)
}

enum AcademyInline {
    /// Colours offered for text and highlights (the web editor's colour picker takes any colour;
    /// these cover what authors use), with plain names.
    static let colours: [(name: String, css: String)] = [
        ("Red", "#dc2626"), ("Orange", "#ea580c"), ("Amber", "#ca8a04"), ("Green", "#16a34a"), ("Teal", "#0d9488"),
        ("Blue", "#2563eb"), ("Purple", "#7c3aed"), ("Pink", "#db2777"), ("Grey", "#6b7280"),
    ]
    static let highlights: [(name: String, css: String)] = [
        ("Yellow", "#fef08a"), ("Green", "#bbf7d0"), ("Blue", "#bfdbfe"), ("Pink", "#fbcfe8"), ("Orange", "#fed7aa"),
    ]

    static var baseFont: UIFont { .preferredFont(forTextStyle: .body) }

    // MARK: What can be edited as text

    /// Whether `html` uses only the inline formatting the text editor keeps (else it stays HTML).
    static func isSupported(_ html: String) -> Bool {
        for token in RichHTMLParser.tokenize(html) {
            guard case .open(let name, let attributes, _) = token else { continue }
            let keys = Set(attributes.keys)
            switch name {
            case "strong", "b", "em", "i", "u", "s", "strike", "del", "code", "sub", "sup", "br":
                if !keys.isEmpty { return false }
            case "a":
                if !keys.isSubset(of: ["href", "target", "rel"]) { return false }
            case "span":
                let css = RichHTMLParser.style(attributes)
                if keys != ["style"] || Set(css.keys) != ["color"] { return false }
            case "mark":
                let css = RichHTMLParser.style(attributes)
                if !keys.isSubset(of: ["style", "data-color"]) || !Set(css.keys).isSubset(of: ["background-color", "color"]) {
                    return false
                }
            default:
                return false
            }
        }
        return true
    }

    // MARK: HTML → styled text

    struct Style: Equatable {
        var marks: AcademyMarks = []
        var href: String?
        var colour: String?
        var highlight: String?
    }

    static func attributed(_ html: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var stack: [(tag: String, style: Style)] = [("", Style())]
        for token in RichHTMLParser.tokenize(html) {
            switch token {
            case .text(let text):
                // Whitespace runs collapse as HTML does; line breaks come from <br>.
                let collapsed = text.replacingOccurrences(of: #"[ \t\n\r]+"#, with: " ", options: .regularExpression)
                result.append(NSAttributedString(string: collapsed, attributes: attributes(for: stack.last?.style ?? Style())))
            case .open(let name, let attributes, _):
                if name == "br" {
                    result.append(NSAttributedString(string: "\n", attributes: self.attributes(for: stack.last?.style ?? Style())))
                    continue
                }
                var style = stack.last?.style ?? Style()
                switch name {
                case "strong", "b": style.marks.insert(.bold)
                case "em", "i": style.marks.insert(.italic)
                case "u": style.marks.insert(.underline)
                case "s", "strike", "del": style.marks.insert(.strike)
                case "code": style.marks.insert(.code)
                case "sub": style.marks.remove(.sup); style.marks.insert(.sub)
                case "sup": style.marks.remove(.sub); style.marks.insert(.sup)
                case "a": style.href = attributes["href"] ?? ""
                case "span": style.colour = RichHTMLParser.style(attributes)["color"] ?? style.colour
                case "mark":
                    style.highlight = attributes["data-color"]?.trimmedOrNil
                        ?? RichHTMLParser.style(attributes)["background-color"]?.trimmedOrNil ?? ""
                default: break
                }
                stack.append((name, style))
            case .close(let name):
                if let index = stack.lastIndex(where: { $0.tag == name }), index > 0 { stack.removeSubrange(index...) }
            }
        }
        // Leading/trailing spaces from the markup's own layout aren't content.
        let text = result.string
        let start = text.prefix { $0 == " " }.count
        let end = text.reversed().prefix { $0 == " " }.count
        if start + end >= text.count { return NSAttributedString(string: "") }
        return result.attributedSubstring(from: NSRange(location: start, length: (text as NSString).length - start - end))
    }

    /// Semantic keys plus what they look like on screen.
    static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [.academyMarks: style.marks.rawValue]
        if let href = style.href { out[.academyHref] = href }
        if let colour = style.colour { out[.academyColour] = colour }
        if let highlight = style.highlight { out[.academyHighlight] = highlight }
        return out.merging(display(style)) { semantic, _ in semantic }
    }

    static func display(_ style: Style) -> [NSAttributedString.Key: Any] {
        var font = baseFont
        if style.marks.contains(.code) {
            font = .monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: style.marks.contains(.bold) ? .bold : .regular)
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if style.marks.contains(.bold) { traits.insert(.traitBold) }
            if style.marks.contains(.italic) { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: 0) }
        }
        var out: [NSAttributedString.Key: Any] = [:]
        if style.marks.contains(.sub) || style.marks.contains(.sup) {
            font = font.withSize(font.pointSize * 0.7)
            out[.baselineOffset] = style.marks.contains(.sup) ? baseFont.pointSize * 0.35 : -baseFont.pointSize * 0.15
        }
        out[.font] = font
        out[.foregroundColor] = style.colour.flatMap(uiColour) ?? (style.href != nil ? UIColor.link : UIColor.label)
        if style.marks.contains(.underline) || style.href != nil { out[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.marks.contains(.strike) { out[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let highlight = style.highlight {
            out[.backgroundColor] = uiColour(highlight) ?? UIColor(red: 1, green: 0.94, blue: 0.54, alpha: 1)
        } else if style.marks.contains(.code) {
            out[.backgroundColor] = UIColor.secondarySystemFill
        }
        return out
    }

    static func style(at attributes: [NSAttributedString.Key: Any]) -> Style {
        Style(marks: AcademyMarks(rawValue: attributes[.academyMarks] as? Int ?? 0),
              href: attributes[.academyHref] as? String,
              colour: attributes[.academyColour] as? String,
              highlight: attributes[.academyHighlight] as? String)
    }

    static func uiColour(_ css: String) -> UIColor? {
        guard let colour = RichColor(css: css) else { return nil }
        return UIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: colour.alpha)
    }

    /// Re-draws a range from its semantic keys (after a change of formatting).
    static func restyle(_ storage: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            let style = style(at: attributes)
            for key in [NSAttributedString.Key.font, .foregroundColor, .underlineStyle, .strikethroughStyle,
                        .backgroundColor, .baselineOffset] {
                storage.removeAttribute(key, range: subrange)
            }
            storage.addAttributes(display(style), range: subrange)
        }
    }

    // MARK: Styled text → HTML

    static func html(from text: NSAttributedString) -> String {
        var out = ""
        var openLink: String?
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole) { attributes, range, _ in
            let style = style(at: attributes)
            let piece = (text.string as NSString).substring(with: range)
            if style.href != openLink {
                if openLink != nil { out += "</a>" }
                if let href = style.href {
                    out += "<a target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"\(AcademyContent.escapeAttribute(href))\">"
                }
                openLink = style.href
            }
            out += wrap(piece, style)
        }
        if openLink != nil { out += "</a>" }
        return out
    }

    private static func wrap(_ piece: String, _ style: Style) -> String {
        var open = "", close = ""
        func add(_ tag: String, _ attributes: String = "") {
            open += "<\(tag)\(attributes)>"
            close = "</\(tag)>" + close
        }
        if style.marks.contains(.bold) { add("strong") }
        if style.marks.contains(.italic) { add("em") }
        if style.marks.contains(.underline) { add("u") }
        if style.marks.contains(.strike) { add("s") }
        if style.marks.contains(.code) { add("code") }
        if style.marks.contains(.sub) { add("sub") }
        if style.marks.contains(.sup) { add("sup") }
        if let highlight = style.highlight {
            if highlight.isEmpty { add("mark") } else {
                let value = AcademyContent.escapeAttribute(highlight)
                add("mark", " data-color=\"\(value)\" style=\"background-color: \(value); color: inherit\"")
            }
        }
        if let colour = style.colour { add("span", " style=\"color: \(AcademyContent.escapeAttribute(colour))\"") }
        let body = AcademyContent.escapeText(piece).replacingOccurrences(of: "\n", with: "<br>")
        return open + body + close
    }
}

// MARK: - Editing

/// Applies formatting to whichever text box has the cursor (one per sheet; several boxes may share it).
@MainActor
@Observable
final class AcademyInlineController {
    @ObservationIgnored weak var active: UITextView?
    /// The formatting where the cursor is, for the toolbar's on/off states.
    private(set) var current = AcademyInline.Style()
    private(set) var hasSelection = false

    func focus(_ textView: UITextView) {
        active = textView
        refresh()
    }

    func refresh() {
        guard let textView = active else { return }
        let range = textView.selectedRange
        hasSelection = range.length > 0
        if range.length > 0 {
            current = AcademyInline.style(at: textView.attributedText.attributes(at: range.location, effectiveRange: nil))
        } else {
            current = AcademyInline.style(at: textView.typingAttributes)
        }
    }

    func isOn(_ mark: AcademyMarks) -> Bool { current.marks.contains(mark) }

    func toggle(_ mark: AcademyMarks) {
        let turnOn = !isOn(mark)
        change { style in
            if turnOn {
                if mark == .sub { style.marks.remove(.sup) }
                if mark == .sup { style.marks.remove(.sub) }
                style.marks.insert(mark)
            } else {
                style.marks.remove(mark)
            }
        }
    }

    func setColour(_ css: String?) { change { $0.colour = css } }

    func setHighlight(_ css: String?) { change { $0.highlight = css } }

    /// The link where the cursor is, for editing.
    var currentLink: String? { current.href }

    /// Links the selected words (or the link the cursor is in) to `address`; nil removes the link.
    func setLink(_ address: String?) {
        guard let textView = active else { return }
        if textView.selectedRange.length == 0, current.href != nil {
            // The whole link the cursor sits in.
            var effective = NSRange()
            let location = max(0, min(textView.selectedRange.location, textView.attributedText.length - 1))
            if textView.attributedText.length > 0,
               textView.attributedText.attribute(.academyHref, at: location, longestEffectiveRange: &effective,
                                                 in: NSRange(location: 0, length: textView.attributedText.length)) != nil {
                textView.selectedRange = effective
            }
        }
        change { $0.href = address }
    }

    func clearFormatting() { change { $0 = AcademyInline.Style() } }

    /// Applies a change to the selection, or to what is typed next when nothing is selected.
    private func change(_ edit: (inout AcademyInline.Style) -> Void) {
        guard let textView = active else { return }
        let range = textView.selectedRange
        if range.length == 0 {
            var style = AcademyInline.style(at: textView.typingAttributes)
            edit(&style)
            textView.typingAttributes = AcademyInline.attributes(for: style)
            refresh()
            return
        }
        let storage = textView.textStorage
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var style = AcademyInline.style(at: attributes)
            edit(&style)
            for key in [NSAttributedString.Key.academyMarks, .academyHref, .academyColour, .academyHighlight] {
                storage.removeAttribute(key, range: subrange)
            }
            storage.addAttribute(.academyMarks, value: style.marks.rawValue, range: subrange)
            if let href = style.href { storage.addAttribute(.academyHref, value: href, range: subrange) }
            if let colour = style.colour { storage.addAttribute(.academyColour, value: colour, range: subrange) }
            if let highlight = style.highlight { storage.addAttribute(.academyHighlight, value: highlight, range: subrange) }
        }
        AcademyInline.restyle(storage, range: range)
        storage.endEditing()
        textView.selectedRange = range
        textView.delegate?.textViewDidChange?(textView)
        refresh()
    }
}

/// A text box for inline HTML, with the formatting applied by an `AcademyInlineController`.
struct AcademyInlineEditor: UIViewRepresentable {
    @Binding var html: String
    let controller: AcademyInlineController
    var placeholder = "Type here"
    var accessibilityID = "academy.text"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.attributedText = AcademyInline.attributed(html)
        view.typingAttributes = AcademyInline.attributes(for: AcademyInline.Style())
        view.accessibilityIdentifier = accessibilityID
        view.accessibilityHint = placeholder
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.lastHTML = html
        context.coordinator.placeholder.text = placeholder
        context.coordinator.placeholder.font = AcademyInline.baseFont
        context.coordinator.placeholder.textColor = .placeholderText
        context.coordinator.placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(context.coordinator.placeholder)
        NSLayoutConstraint.activate([
            context.coordinator.placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            context.coordinator.placeholder.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
        ])
        context.coordinator.placeholder.isHidden = !html.isEmpty
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        guard html != context.coordinator.lastHTML else { return }
        view.attributedText = AcademyInline.attributed(html)
        context.coordinator.lastHTML = html
        context.coordinator.placeholder.isHidden = !html.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(44, fitted.height))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AcademyInlineEditor
        var lastHTML = ""
        let placeholder = UILabel()

        init(_ parent: AcademyInlineEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            let out = AcademyInline.html(from: textView.attributedText)
            lastHTML = out
            placeholder.isHidden = textView.attributedText.length > 0
            if parent.html != out { parent.html = out }
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.controller.focus(textView) }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if parent.controller.active === textView { parent.controller.refresh() }
        }
    }
}

/// The formatting buttons for an `AcademyInlineController` (bold, italic… colour, link).
struct AcademyFormatBar: View {
    let controller: AcademyInlineController
    @State private var editingLink = false
    @State private var linkAddress = "https://"
    @State private var linkProblem: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                mark(.bold, "bold", "Bold")
                mark(.italic, "italic", "Italic")
                mark(.underline, "underline", "Underline")
                mark(.strike, "strikethrough", "Strikethrough")
                mark(.code, "chevron.left.forwardslash.chevron.right", "Code")
                colourMenu
                highlightMenu
                mark(.sub, "textformat.subscript", "Subscript")
                mark(.sup, "textformat.superscript", "Superscript")
                Button {
                    linkAddress = controller.currentLink ?? "https://"
                    linkProblem = nil
                    editingLink = true
                } label: {
                    icon("link", on: controller.currentLink != nil)
                }
                .accessibilityLabel(controller.currentLink == nil ? "Add a link" : "Change the link")
                .accessibilityIdentifier("academy.format.link")
                if controller.currentLink != nil {
                    Button { controller.setLink(nil) } label: { icon("link.badge.plus", on: false) }
                        .accessibilityLabel("Remove the link")
                        .accessibilityIdentifier("academy.format.unlink")
                }
                Button { controller.clearFormatting() } label: { icon("eraser", on: false) }
                    .accessibilityLabel("Clear formatting")
                    .accessibilityIdentifier("academy.format.clear")
            }
            .padding(.vertical, 4)
        }
        .alert("Link", isPresented: $editingLink) {
            TextField("https://…", text: $linkAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save link") { saveLink() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(linkProblem ?? (controller.hasSelection || controller.currentLink != nil
                ? "Where should these words go?" : "Select some words first, then add the link."))
        }
    }

    private func saveLink() {
        let address = linkAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme), address.count > scheme.count + 1 else {
            linkProblem = "That isn’t a web address. It should start with https://"
            editingLink = true
            return
        }
        controller.setLink(address)
    }

    private func mark(_ mark: AcademyMarks, _ symbol: String, _ label: String) -> some View {
        Button { controller.toggle(mark) } label: { icon(symbol, on: controller.isOn(mark)) }
            .accessibilityLabel(label)
            .accessibilityValue(controller.isOn(mark) ? "On" : "Off")
            .accessibilityIdentifier("academy.format.\(label.lowercased())")
    }

    private var colourMenu: some View {
        Menu {
            Button("Default colour") { controller.setColour(nil) }
            ForEach(AcademyInline.colours, id: \.css) { colour in
                Button { controller.setColour(colour.css) } label: {
                    Label(colour.name, systemImage: "circle.fill")
                }
                .tint(Color(uiColor: AcademyInline.uiColour(colour.css) ?? .label))
            }
        } label: {
            icon("paintpalette", on: controller.current.colour != nil)
        }
        .accessibilityLabel("Text colour")
        .accessibilityIdentifier("academy.format.colour")
    }

    private var highlightMenu: some View {
        Menu {
            Button("No highlight") { controller.setHighlight(nil) }
            Button("Highlight") { controller.setHighlight("") }
            ForEach(AcademyInline.highlights, id: \.css) { colour in
                Button("\(colour.name) highlight") { controller.setHighlight(colour.css) }
            }
        } label: {
            icon("highlighter", on: controller.current.highlight != nil)
        }
        .accessibilityLabel("Highlight")
        .accessibilityIdentifier("academy.format.highlight")
    }

    private func icon(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.wsBody.weight(.semibold))
            .frame(minWidth: 40, minHeight: 40)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Tone.brand.solidColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
