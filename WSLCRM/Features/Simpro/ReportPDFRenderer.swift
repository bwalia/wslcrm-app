import UIKit

/// Renders any report from the pack as a branded A4 landscape PDF.
///
/// Same layout as the dashboard's lib/report-pdf.ts, which follows DBS's own Simpro report sample:
/// a letterhead band, the title and summary, a paginated table, and the company's legal footer
/// (registered name, address, company number, VAT number) on every page.
struct ReportPDFRenderer {
    let company: ReportCompany

    private static let navy = UIColor(red: 11 / 255, green: 37 / 255, blue: 69 / 255, alpha: 1)
    private static let teal = UIColor(red: 19 / 255, green: 168 / 255, blue: 158 / 255, alpha: 1)
    private static let dark = UIColor(red: 30 / 255, green: 41 / 255, blue: 59 / 255, alpha: 1)
    private static let muted = UIColor(red: 100 / 255, green: 116 / 255, blue: 139 / 255, alpha: 1)
    private static let line = UIColor(red: 226 / 255, green: 232 / 255, blue: 240 / 255, alpha: 1)
    private static let soft = UIColor(red: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)

    // A4 landscape in points.
    static let pageSize = CGSize(width: 842, height: 595)
    private let margin: CGFloat = 32
    private let footerHeight: CGFloat = 34
    /// Wide reports (the Power BI extract has 29 columns) are capped so each stays legible;
    /// the CSV carries every column.
    static let maxColumns = 12

    func render(_ report: Report, generatedAt: Date = Date()) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: report.title,
            kCGPDFContextCreator as String: company.name,
        ]
        let bounds = CGRect(origin: .zero, size: Self.pageSize)
        let columns = Array(report.columns.prefix(Self.maxColumns))

        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
            var page = 0
            var y: CGFloat = 0

            func newPage() {
                context.beginPage()
                page += 1
                drawLetterhead()
                drawFooter(page: page)
                y = 84
            }

            newPage()

            // Title block
            draw(report.title, at: CGPoint(x: margin, y: y), font: .boldSystemFont(ofSize: 17), color: Self.dark)
            let stamp = "Generated \(generatedAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))"
            drawRight(stamp, rightX: bounds.width - margin, y: y + 3, font: .systemFont(ofSize: 8.5), color: Self.muted)
            y += 22
            y += drawWrapped(report.description, in: CGRect(x: margin, y: y, width: bounds.width - margin * 2, height: 40),
                             font: .systemFont(ofSize: 9), color: Self.muted) + 8

            // Summary strip
            let summary = report.summaryItems
            if !summary.isEmpty {
                let cellWidth = min(118, (bounds.width - margin * 2) / CGFloat(summary.count))
                for (i, item) in summary.enumerated() {
                    let rect = CGRect(x: margin + CGFloat(i) * cellWidth, y: y, width: cellWidth - 5, height: 36)
                    let path = UIBezierPath(roundedRect: rect, cornerRadius: 4)
                    Self.soft.setFill(); path.fill()
                    Self.line.setStroke(); path.stroke()
                    draw(item.label, at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), font: .systemFont(ofSize: 7), color: Self.muted,
                         maxWidth: rect.width - 12)
                    draw(item.value, at: CGPoint(x: rect.minX + 6, y: rect.minY + 16), font: .boldSystemFont(ofSize: 12), color: Self.navy,
                         maxWidth: rect.width - 12)
                }
                y += 46
            }

            // Table
            let tableWidth = bounds.width - margin * 2
            let widths = columnWidths(columns, rows: report.rows, total: tableWidth)
            let headerFont = UIFont.boldSystemFont(ofSize: 7.5)
            let bodyFont = UIFont.systemFont(ofSize: 7.5)

            func drawHeader() {
                let rect = CGRect(x: margin, y: y, width: tableWidth, height: 18)
                Self.navy.setFill(); UIRectFill(rect)
                var x = margin
                for (i, column) in columns.enumerated() {
                    let cell = CGRect(x: x + 4, y: y + 4, width: widths[i] - 8, height: 12)
                    drawCell(column.label, in: cell, font: headerFont, color: .white, alignRight: column.isNumeric)
                    x += widths[i]
                }
                y += 18
            }

            drawHeader()
            let pageBottom = bounds.height - footerHeight - 8

            if report.rows.isEmpty {
                draw("No rows for these filters.", at: CGPoint(x: margin, y: y + 8), font: .systemFont(ofSize: 10), color: Self.muted)
            }

            for (index, row) in report.rows.enumerated() {
                let texts = columns.map { ReportFormat.cell(row[$0.key], type: $0.type) }
                let height = rowHeight(texts, widths: widths, font: bodyFont)
                if y + height > pageBottom {
                    newPage()
                    drawHeader()
                }
                if index.isMultiple(of: 2) == false {
                    Self.soft.setFill(); UIRectFill(CGRect(x: margin, y: y, width: tableWidth, height: height))
                }
                var x = margin
                for (i, column) in columns.enumerated() {
                    drawCell(texts[i], in: CGRect(x: x + 4, y: y + 3, width: widths[i] - 8, height: height - 6),
                             font: bodyFont, color: Self.dark, alignRight: column.isNumeric)
                    x += widths[i]
                }
                Self.line.setStroke()
                let rule = UIBezierPath()
                rule.move(to: CGPoint(x: margin, y: y + height))
                rule.addLine(to: CGPoint(x: margin + tableWidth, y: y + height))
                rule.lineWidth = 0.5
                rule.stroke()
                y += height
            }

            if report.columns.count > columns.count {
                let note = "Showing the first \(columns.count) of \(report.columns.count) columns. The CSV export includes all of them."
                if y + 18 > pageBottom { newPage() }
                draw(note, at: CGPoint(x: margin, y: y + 6), font: .italicSystemFont(ofSize: 8), color: Self.muted)
            }
        }
    }

    // MARK: - Page furniture

    private func drawLetterhead() {
        let width = Self.pageSize.width
        Self.navy.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: width, height: 60))
        Self.teal.setFill(); UIRectFill(CGRect(x: 0, y: 60, width: width, height: 4))
        draw(company.name, at: CGPoint(x: margin, y: 14), font: .boldSystemFont(ofSize: 20), color: .white)
        if let strapline = company.strapline {
            draw(strapline, at: CGPoint(x: margin, y: 41), font: .systemFont(ofSize: 8.5), color: .white)
        }
        let contact = [company.phone.map { "Tel: \($0)" }, company.email].compactMap { $0 }.joined(separator: "   ")
        if !contact.isEmpty {
            drawRight(contact, rightX: width - margin, y: 22, font: .systemFont(ofSize: 8.5), color: .white)
        }
    }

    private func drawFooter(page: Int) {
        let size = Self.pageSize
        let top = size.height - footerHeight
        Self.line.setStroke()
        let rule = UIBezierPath()
        rule.move(to: CGPoint(x: margin, y: top))
        rule.addLine(to: CGPoint(x: size.width - margin, y: top))
        rule.lineWidth = 0.5
        rule.stroke()
        let footer = company.legalFooter
        if !footer.isEmpty {
            let attributes = textAttributes(font: .systemFont(ofSize: 7), color: Self.muted, alignment: .center)
            (footer as NSString).draw(in: CGRect(x: margin, y: top + 6, width: size.width - margin * 2, height: 12),
                                      withAttributes: attributes)
        }
        drawRight("Page \(page)", rightX: size.width - margin, y: top + 19, font: .systemFont(ofSize: 7), color: Self.muted)
    }

    // MARK: - Layout helpers

    /// Share the width in proportion to each column's longest content, within sensible bounds.
    private func columnWidths(_ columns: [ReportColumn], rows: [[String: JSONValue]], total: CGFloat) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let sample = rows.prefix(60)
        let weights: [CGFloat] = columns.map { column in
            let longest = sample.map { ReportFormat.cell($0[column.key], type: column.type).count }.max() ?? 0
            return CGFloat(min(max(max(longest, column.label.count), 5), 34))
        }
        let sum = weights.reduce(0, +)
        return weights.map { total * $0 / sum }
    }

    private func rowHeight(_ texts: [String], widths: [CGFloat], font: UIFont) -> CGFloat {
        var tallest: CGFloat = font.lineHeight
        for (i, text) in texts.enumerated() {
            let bounding = (text as NSString).boundingRect(
                with: CGSize(width: widths[i] - 8, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: font], context: nil)
            tallest = max(tallest, min(ceil(bounding.height), font.lineHeight * 3))
        }
        return tallest + 6
    }

    private func textAttributes(font: UIFont, color: UIColor, alignment: NSTextAlignment = .left) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    private func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor, maxWidth: CGFloat? = nil) {
        if let maxWidth {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            (text as NSString).draw(in: CGRect(x: point.x, y: point.y, width: maxWidth, height: font.lineHeight + 2),
                                    withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        } else {
            (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
        }
    }

    private func drawRight(_ text: String, rightX: CGFloat, y: CGFloat, font: UIFont, color: UIColor) {
        let size = (text as NSString).size(withAttributes: [.font: font])
        draw(text, at: CGPoint(x: rightX - size.width, y: y), font: font, color: color)
    }

    @discardableResult
    private func drawWrapped(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) -> CGFloat {
        let attributes = textAttributes(font: font, color: color)
        let bounding = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: rect.height),
                                                       options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        (text as NSString).draw(in: rect, withAttributes: attributes)
        return ceil(bounding.height)
    }

    private func drawCell(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignRight: Bool) {
        let attributes = textAttributes(font: font, color: color, alignment: alignRight ? .right : .left)
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }
}
