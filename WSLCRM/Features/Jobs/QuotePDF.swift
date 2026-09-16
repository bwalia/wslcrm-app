import UIKit

/// The customer quotation (opsapi #611): the job's quote-sheet lines priced up as an estimate.
/// A quote is not an invoice — nothing here bills or changes the job.
@MainActor
enum QuotePDFRenderer {
    /// Lines a quote shows: everything logged on the sheet that is billable and not rejected.
    nonisolated static func quotableItems(_ detail: JobDetail) -> [JobItem] {
        detail.items.filter { $0.isBillable && $0.approvalStatus != .rejected }
    }

    nonisolated static func reference(for job: Job) -> String {
        "QUO-\(job.jobNumber.isEmpty ? "job" : job.jobNumber)"
    }

    nonisolated static func filename(for job: Job) -> String {
        "Quote-\(job.jobNumber.isEmpty ? "job" : job.jobNumber).pdf"
    }

    struct Totals: Equatable {
        var net: Decimal = 0
        var tax: Decimal = 0
        var total: Decimal = 0
    }

    nonisolated static func totals(_ items: [JobItem]) -> Totals {
        items.reduce(into: Totals()) { totals, item in
            let net = item.quantity * item.unitPrice
            totals.net += net
            totals.tax += net * item.taxRate / 100
            totals.total += item.lineTotal
        }
    }

    static func data(for detail: JobDetail, company: String?) -> Data? {
        DocumentPDF.data { canvas in draw(detail: detail, company: company, on: canvas) }
    }

    static func file(for detail: JobDetail, company: String?) -> URL? {
        DocumentPDF.file(named: filename(for: detail.job)) { canvas in
            draw(detail: detail, company: company, on: canvas)
        }
    }

    private static func draw(detail: JobDetail, company: String?, on canvas: DocumentPDF.Canvas) {
        let job = detail.job
        let items = quotableItems(detail)
        let sums = totals(items)
        let money = { (value: Decimal) in Formatters.money(value, currency: job.currency) ?? "" }
        let right = NSTextAlignment.right

        canvas.text("QUOTATION", x: 48, font: .boldSystemFont(ofSize: 28))
        canvas.text(reference(for: job), x: 287, font: .monospacedSystemFont(ofSize: 14, weight: .semibold),
                    width: 260, alignment: right)
        canvas.y += 40
        if let company, !company.isEmpty {
            canvas.y += canvas.text(company, x: 287, font: .systemFont(ofSize: 11), color: .darkGray,
                                    width: 260, alignment: right)
        }
        canvas.text("For", x: 48, font: .systemFont(ofSize: 10), color: .darkGray)
        canvas.text("Prepared \(Formatters.day(Date()) ?? "")", x: 287, font: .systemFont(ofSize: 11),
                    width: 260, alignment: right)
        canvas.y += 14
        let customer = [job.customerName, job.customerEmail, job.fullAddress].compactMap { $0 }.joined(separator: "\n")
        canvas.y += canvas.text(customer.isEmpty ? "—" : customer, x: 48, font: .systemFont(ofSize: 12))
        canvas.y += 24
        canvas.y += canvas.text("\(job.jobNumber) · \(job.title)", x: 48, font: .boldSystemFont(ofSize: 13), width: 499)
        canvas.y += 18

        canvas.text("Description", x: 48, font: .boldSystemFont(ofSize: 11))
        canvas.text("Qty", x: 300, font: .boldSystemFont(ofSize: 11), width: 50, alignment: right)
        canvas.text("Price", x: 360, font: .boldSystemFont(ofSize: 11), width: 80, alignment: right)
        canvas.text("Total", x: 447, font: .boldSystemFont(ofSize: 11), width: 100, alignment: right)
        canvas.y += 16
        canvas.rule()
        canvas.y += 8

        if items.isEmpty {
            canvas.y += canvas.text("No quotable lines on this job yet.", x: 48, font: .systemFont(ofSize: 11),
                                    color: .darkGray, width: 499)
        }
        for item in items {
            canvas.pageBreakIfNeeded(keeping: 40)
            let detailLine = [item.labourCategory?.label, item.supplier, item.partNumber.map { "Part no. \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            var height = canvas.text(item.description, x: 48, font: .systemFont(ofSize: 11), width: 240)
            canvas.text(item.quantity.formatted(), x: 300, font: .systemFont(ofSize: 11), width: 50, alignment: right)
            canvas.text(money(item.unitPrice), x: 360, font: .systemFont(ofSize: 11), width: 80, alignment: right)
            canvas.text(money(item.lineTotal), x: 447, font: .systemFont(ofSize: 11), width: 100, alignment: right)
            if !detailLine.isEmpty {
                canvas.y += height
                height = canvas.text(detailLine, x: 48, font: .systemFont(ofSize: 9), color: .darkGray, width: 240)
            }
            canvas.y += max(height, 14) + 6
        }

        canvas.y += 10
        canvas.rule()
        canvas.y += 10
        for (label, value, bold) in [("Subtotal", sums.net, false), ("Tax", sums.tax, false), ("Total", sums.total, true)] {
            canvas.text(label, x: 300, font: .systemFont(ofSize: 12), width: 140, alignment: right)
            canvas.text(money(value), x: 447, font: bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12),
                        width: 100, alignment: right)
            canvas.y += 18
        }
        canvas.y += 20
        canvas.text("This quotation is an estimate and is valid for 30 days.", x: 48,
                    font: .systemFont(ofSize: 10), color: .darkGray, width: 499)
    }
}
