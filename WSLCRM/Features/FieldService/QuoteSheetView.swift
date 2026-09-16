import SwiftUI

/// Customer quotation for a job (opsapi #611): the quote-sheet lines priced up, ready to share
/// or email. A quote is an estimate — it doesn't bill anything or change the job.
struct JobQuoteSheet: View {
    let detail: JobDetail
    var onSent: () -> Void = {}

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var recipient: String
    @State private var message = ""
    @State private var sending = false
    @State private var sentTo: String?
    @State private var error: APIError?
    @State private var pdfURL: URL?

    init(detail: JobDetail, onSent: @escaping () -> Void = {}) {
        self.detail = detail
        self.onSent = onSent
        _recipient = State(initialValue: detail.job.customerEmail ?? "")
    }

    private var items: [JobItem] { QuotePDFRenderer.quotableItems(detail) }
    private var totals: QuotePDFRenderer.Totals { QuotePDFRenderer.totals(items) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Reference", value: QuotePDFRenderer.reference(for: detail.job))
                    LabeledContent("Customer", value: detail.job.customerName ?? "—")
                    LabeledContent("Job", value: "\(detail.job.jobNumber) · \(detail.job.title)")
                }

                Section("Lines") {
                    if items.isEmpty {
                        Text("Nothing on the quote sheet yet. Add labour, materials or hire to the job first.")
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.quoteSummary).font(.subheadline)
                                if item.approvalStatus == .pending {
                                    Text("Not approved yet").font(.caption).foregroundStyle(.secondaryText)
                                }
                            }
                            Spacer()
                            Text(Formatters.money(item.lineTotal, currency: detail.job.currency) ?? "")
                                .font(.subheadline.monospacedDigit())
                        }
                        .accessibilityElement(children: .combine)
                    }
                    LabeledContent("Total") {
                        Text(Formatters.money(totals.total, currency: detail.job.currency) ?? "")
                            .font(.headline.monospacedDigit())
                    }
                }

                Section {
                    if let pdfURL {
                        ShareLink(item: pdfURL) { Label("Share the PDF", systemImage: "square.and.arrow.up") }
                            .frame(minHeight: 44)
                    } else {
                        Button {
                            pdfURL = QuotePDFRenderer.file(for: detail, company: session.workspace?.name)
                        } label: {
                            Label("Build the PDF", systemImage: "doc.richtext")
                        }
                        .frame(minHeight: 44)
                        .disabled(items.isEmpty)
                        .accessibilityIdentifier("quote.preview")
                    }
                }

                Section {
                    TextField("Customer email", text: $recipient)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("quote.recipient")
                    TextField("Add a note (optional)", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Email to the customer")
                } footer: {
                    if detail.job.customerEmail == nil {
                        Text("This customer has no email on file — enter one to send the quote.")
                    } else {
                        Text("Sends the PDF above and records it in the job's activity.")
                    }
                }

                if let sentTo {
                    Section {
                        Label("Quotation emailed to \(sentTo)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                    }
                }
                if let error {
                    Section { InlineErrorRow(error: error) }
                }
            }
            .navigationTitle("Quotation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sentTo == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(sending || items.isEmpty || recipient.trimmedOrNil == nil)
                        .accessibilityIdentifier("quote.send")
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            guard let pdf = QuotePDFRenderer.data(for: detail, company: session.workspace?.name) else {
                error = .validation(ServerError(status: 0, message: "The quotation PDF could not be built.",
                                                fieldErrors: [:], rawBody: ""))
                return
            }
            do {
                let result = try await services.fieldService.emailQuote(
                    jobUuid: detail.job.uuid, pdf: pdf,
                    filename: QuotePDFRenderer.filename(for: detail.job),
                    to: recipient, message: message)
                sentTo = result.to
                onSent()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}
