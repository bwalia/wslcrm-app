import UIKit

/// Form responses as a PDF made on the phone (the server only exports CSV): every response the filter
/// shows, or one, each as its questions and answers.
enum WebFormResponsesPDF {
    struct Row: Equatable, Sendable {
        let label: String
        let value: String
    }

    struct Entry: Equatable, Sendable {
        let heading: String
        let rows: [Row]
    }

    // ponytail: stops at 40 pages of 50 (2,000 responses); a bigger PDF is better made from the CSV.
    static let maxPages = 40

    /// Every response matching the filter, following `meta.next_cursor` 50 at a time.
    static func all(_ api: WebFormsAPI, form: String, filter: WebFormsAPI.ResponseFilter)
        async throws -> (columns: [WebFormField], items: [WebFormSubmission]) {
        var items: [WebFormSubmission] = []
        var columns: [WebFormField] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await api.responses(form, filter: filter, cursor: cursor, limit: 50)
            if columns.isEmpty { columns = page.columns.map(\.field) }
            items += page.items
            guard let next = page.next, next != cursor else { break }
            cursor = next
        }
        return (columns, items)
    }

    /// One entry per response: when it came in (and from whom), then each question with its answer.
    static func entries(fields: [WebFormField], submissions: [WebFormSubmission]) -> [Entry] {
        submissions.map { s in
            let questions = s.fields.isEmpty ? fields : s.fields.filter { $0.key != nil && $0.type.isInput }
            let rows = questions.compactMap { field -> Row? in
                guard let key = field.key else { return nil }
                let text = WebFormRules.show(field, s.answers[key])
                return Row(label: field.label, value: text.isEmpty ? "—" : text)
            }
            let when = Formatters.dateTime(s.createdAt.flatMap(APIDate.parse)) ?? s.createdAt ?? ""
            let heading = ["Received \(when)", s.respondentEmail.map { "from \($0)" },
                           s.status == .complete ? nil : s.status.label.lowercased()]
                .compactMap { $0 }.joined(separator: " ")
            return Entry(heading: heading, rows: rows)
        }
    }

    /// "Customer survey-responses.pdf" style names, safe for a file.
    static func filename(_ title: String, suffix: String) -> String {
        let safe = title.replacingOccurrences(of: "[^A-Za-z0-9-_ ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(60)
        return (safe.isEmpty ? "form" : String(safe)) + "-\(suffix).pdf"
    }

    @MainActor
    static func file(title: String, subtitle: String, entries: [Entry], name: String) -> URL? {
        let margin = DocumentPDF.margin
        let width = DocumentPDF.pageSize.width - margin * 2
        let labelWidth: CGFloat = 170
        return DocumentPDF.file(named: name) { page in
            page.y += page.text(title, x: margin, font: .boldSystemFont(ofSize: 18), width: width) + 4
            page.y += page.text(subtitle, x: margin, font: .systemFont(ofSize: 11), color: .darkGray, width: width) + 14
            if entries.isEmpty {
                page.text("No responses.", x: margin, font: .systemFont(ofSize: 12), width: width)
            }
            for entry in entries {
                page.pageBreakIfNeeded(keeping: 70)
                page.y += page.text(entry.heading, x: margin, font: .boldSystemFont(ofSize: 13), width: width) + 4
                page.rule()
                page.y += 6
                for row in entry.rows {
                    page.pageBreakIfNeeded(keeping: 30)
                    let left = page.text(row.label, x: margin, font: .systemFont(ofSize: 10), color: .darkGray, width: labelWidth - 10)
                    let right = page.text(row.value, x: margin + labelWidth, font: .systemFont(ofSize: 11), width: width - labelWidth)
                    page.y += max(left, right) + 6
                }
                page.y += 14
            }
        }
    }
}
