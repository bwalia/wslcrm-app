import SwiftUI

/// The assistant's replies are markdown (the web renders them with react-markdown + GFM): headings,
/// paragraphs, bullet and numbered lists, quotes, code blocks, tables and inline bold / italic /
/// code / links. SwiftUI's own markdown only does the inline part, so blocks are parsed here.
enum ChatMarkdown {
    struct ListItem: Equatable, Sendable {
        var marker: String
        var text: String
        var indent: Int
    }

    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListItem])
        case quote(String)
        case code(String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            if let heading = Self.heading(trimmed) {
                flush()
                blocks.append(heading)
                i += 1
                continue
            }
            if trimmed.range(of: #"^(-\s*){3,}$|^(\*\s*){3,}$|^(_\s*){3,}$"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.rule)
                i += 1
                continue
            }
            if trimmed.contains("|"), i + 1 < lines.count, Self.isTableSeparator(lines[i + 1]) {
                flush()
                let header = Self.cells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    var cells = Self.cells(row)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(max(header.count, 1))))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if Self.listItem(line) != nil {
                flush()
                var items: [ListItem] = []
                while i < lines.count {
                    let current = lines[i]
                    if let item = Self.listItem(current) {
                        items.append(item)
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              current.first == " " || current.first == "\t", !items.isEmpty {
                        // A wrapped line of the item above.
                        items[items.count - 1].text += " " + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.list(items))
                continue
            }
            if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while i < lines.count {
                    let current = lines[i].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    quoted.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return blocks
    }

    /// Bold, italic, inline code, strikethrough and links, keeping the line breaks.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The words without the markup (for reading aloud and notification previews).
    static func plainText(_ source: String) -> String {
        parse(source).map { block -> String in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text):
                return String(inline(text).characters)
            case .list(let items):
                return items.map { String(inline($0.text).characters) }.joined(separator: "\n")
            case .code(let code):
                return code
            case .table(let header, let rows):
                return ([header] + rows).map { $0.map { String(inline($0).characters) }.joined(separator: ", ") }
                    .joined(separator: "\n")
            case .rule:
                return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    // MARK: Pieces

    private static func heading(_ trimmed: String) -> Block? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let match = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            return ListItem(marker: "•", text: String(trimmed[match.upperBound...]), indent: indent)
        }
        if let match = trimmed.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            let marker = trimmed[match].trimmingCharacters(in: .whitespaces)
            return ListItem(marker: marker.replacingOccurrences(of: ")", with: "."),
                            text: String(trimmed[match.upperBound...]), indent: indent)
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        return trimmed.range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$"#, options: .regularExpression) != nil
    }

    static func cells(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

/// Draws an assistant reply. Links go through the environment's `openURL` (the assistant screen
/// turns links to dashboard pages into native screens).
struct ChatMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = ChatMarkdown.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: ChatMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(ChatMarkdown.inline(text))
                .font(level <= 2 ? .wsTitle3 : .wsHeadline)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(ChatMarkdown.inline(text))
                .font(.wsBody)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.wsBody.monospacedDigit())
                            .foregroundStyle(.secondaryText)
                        Text(ChatMarkdown.inline(item.text))
                            .font(.wsBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(min(item.indent, 4)) * 14)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(ChatMarkdown.inline(text))
                    .font(.wsBody)
                    .foregroundStyle(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .table(let header, let rows):
            ChatMarkdownTable(header: header, rows: rows)
        case .rule:
            Divider()
        }
    }
}

/// A markdown table: scrolls sideways when it's wider than the bubble.
private struct ChatMarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, bold: true)
                    }
                }
                .background(Color(.tertiarySystemFill))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellView(cell, bold: false)
                        }
                    }
                }
            }
            .overlay(Rectangle().stroke(Color(.separator)))
        }
    }

    private func cellView(_ text: String, bold: Bool) -> some View {
        Text(ChatMarkdown.inline(text))
            .font(bold ? .wsFootnote.weight(.semibold) : .wsFootnote)
            .frame(maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(Rectangle().stroke(Color(.separator).opacity(0.6), lineWidth: 0.5))
    }
}
