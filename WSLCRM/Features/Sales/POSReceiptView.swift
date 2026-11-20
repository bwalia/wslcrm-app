import SwiftUI
import UIKit

/// A sale's receipt after "Complete sale" (or reopened from today's sales): what was sold, how it was paid,
/// the change to give, and the receipt by email, share sheet or printer.
struct POSReceiptView: View {
    let receipt: POSReceipt
    /// "New sale" (nil when reopened: the button just closes).
    var onNewSale: (() -> Void)?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var email: String
    @State private var sending = false
    @State private var notice: String?
    @State private var error: APIError?
    @State private var pdf: URL?

    init(receipt: POSReceipt, onNewSale: (() -> Void)? = nil) {
        self.receipt = receipt
        self.onNewSale = onNewSale
        _email = State(initialValue: receipt.customerEmail ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                if let change = receipt.payment.change, change > 0 {
                    Section {
                        Label("Give \(SalesMoney.format(change, receipt.currency)) change", systemImage: "banknote")
                            .font(.wsTitle3.weight(.bold))
                            .foregroundStyle(Tone.success.textColor)
                            .accessibilityIdentifier("pos.receipt.change")
                    }
                }
                Section {
                    ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(item.quantity) × \(item.name)").font(.wsBody)
                                if let sku = item.sku { Text(sku).font(.wsCaption).foregroundStyle(.secondaryText) }
                            }
                            Spacer()
                            Text(SalesMoney.format(item.total, receipt.currency)).font(.wsBody.monospacedDigit())
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text([receipt.store.name, Formatters.dateTime(receipt.soldAt)].compactMap { $0 }.joined(separator: " · "))
                }
                Section {
                    LabeledContent("Subtotal", value: SalesMoney.format(receipt.subtotal, receipt.currency))
                    if receipt.discount > 0 {
                        LabeledContent("Discount", value: "−" + SalesMoney.format(receipt.discount, receipt.currency))
                    }
                    if receipt.tax > 0 { LabeledContent("Tax", value: SalesMoney.format(receipt.tax, receipt.currency)) }
                    LabeledContent("Total", value: SalesMoney.format(receipt.total, receipt.currency))
                        .font(.wsHeadline)
                    LabeledContent("Paid by", value: paidBy)
                    if let tendered = receipt.payment.tendered {
                        LabeledContent("Cash given", value: SalesMoney.format(tendered, receipt.currency))
                        LabeledContent("Change", value: SalesMoney.format(receipt.payment.change ?? 0, receipt.currency))
                    }
                }
                Section {
                    TextField("customer@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pos.receipt.email")
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView() } else { Label("Email the receipt", systemImage: "envelope") }
                    }
                    .disabled(sending || !SalesMoney.isEmail(email))
                    .accessibilityIdentifier("pos.receipt.send")
                    if let notice { Label(notice, systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor) }
                    if let error { InlineErrorRow(error: error) }
                } header: {
                    Text("Email the receipt")
                }
                Section {
                    if let pdf {
                        ShareLink(item: pdf) { Label("Share the receipt", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("pos.receipt.share")
                    }
                    Button {
                        print()
                    } label: {
                        Label("Print the receipt", systemImage: "printer")
                    }
                    .accessibilityIdentifier("pos.receipt.print")
                }
            }
            .navigationTitle("Sale \(receipt.orderNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(onNewSale == nil ? "Done" : "New sale") {
                        onNewSale?()
                        dismiss()
                    }
                    .accessibilityIdentifier("pos.receipt.newSale")
                }
            }
            .task { pdf = POSReceiptPDF.file(receipt) }
        }
    }

    private var paidBy: String {
        [receipt.payment.label ?? receipt.payment.method.map(Formatters.humanize) ?? "—",
         receipt.payment.reference.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            let result = try await services.sales.emailReceipt(receipt.uuid, to: email.trimmingCharacters(in: .whitespaces))
            error = nil
            notice = "Receipt sent to \(result.to ?? email)."
        } catch {
            notice = nil
            self.error = error.asAPIError
        }
    }

    private func print() {
        guard let data = POSReceiptPDF.data(receipt) else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "Receipt \(receipt.orderNumber)"
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }
}

/// The receipt as a narrow PDF, sized for a receipt printer (80 mm) and readable on A4.
@MainActor
enum POSReceiptPDF {
    static let width: CGFloat = 227   // 80 mm at 72 dpi

    static func data(_ r: POSReceipt) -> Data? {
        let lines = textLines(r)
        let height = CGFloat(lines.count) * 16 + 48
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: max(height, 200)))
        return renderer.pdfData { context in
            context.beginPage()
            var y: CGFloat = 16
            for line in lines {
                let font = line.bold ? UIFont.boldSystemFont(ofSize: line.size) : UIFont.systemFont(ofSize: line.size)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                if let right = line.right {
                    (line.left as NSString).draw(in: CGRect(x: 12, y: y, width: width - 90, height: 16), withAttributes: attributes)
                    let size = (right as NSString).size(withAttributes: attributes)
                    (right as NSString).draw(at: CGPoint(x: width - 12 - size.width, y: y), withAttributes: attributes)
                } else {
                    (line.left as NSString).draw(in: CGRect(x: 12, y: y, width: width - 24, height: 16), withAttributes: attributes)
                }
                y += 16
            }
        }
    }

    static func file(_ r: POSReceipt) -> URL? {
        guard let data = data(r) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Receipt \(r.orderNumber).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    struct Line {
        var left: String
        var right: String?
        var bold = false
        var size: CGFloat = 9
    }

    /// The same content as the web's printed receipt.
    static func textLines(_ r: POSReceipt) -> [Line] {
        let cur = r.currency
        var out: [Line] = [Line(left: r.store.name, bold: true, size: 12)]
        if let address = r.store.address?.trimmedOrNil { out.append(Line(left: address)) }
        if let contact = r.store.contact?.trimmedOrNil { out.append(Line(left: contact)) }
        out.append(Line(left: [r.orderNumber, Formatters.dateTime(r.soldAt)].compactMap { $0 }.joined(separator: " · ")))
        out.append(Line(left: " "))
        for item in r.items {
            out.append(Line(left: "\(item.quantity) × \(item.name)", right: SalesMoney.format(item.total, cur)))
        }
        out.append(Line(left: " "))
        out.append(Line(left: "Subtotal", right: SalesMoney.format(r.subtotal, cur)))
        if r.discount > 0 { out.append(Line(left: "Discount", right: "−" + SalesMoney.format(r.discount, cur))) }
        if r.tax > 0 { out.append(Line(left: "Tax", right: SalesMoney.format(r.tax, cur))) }
        out.append(Line(left: "Total", right: SalesMoney.format(r.total, cur), bold: true, size: 11))
        let method = r.payment.label ?? "—"
        out.append(Line(left: "Paid by \(method)" + (r.payment.reference.map { " (\($0))" } ?? "")))
        if let tendered = r.payment.tendered {
            out.append(Line(left: "Cash \(SalesMoney.format(tendered, cur)) · Change \(SalesMoney.format(r.payment.change ?? 0, cur))"))
        }
        out.append(Line(left: " "))
        out.append(Line(left: "Thank you for your purchase."))
        return out
    }
}
