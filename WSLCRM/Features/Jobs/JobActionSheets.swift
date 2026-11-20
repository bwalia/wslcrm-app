import SwiftUI

/// Shows billable labour and approved items, then creates a draft invoice.
struct JobInvoiceSheet: View {
    let detail: JobDetail
    let onInvoiced: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<JobInvoicePreview> = .idle
    @State private var creating = false
    @State private var error: APIError?
    @State private var created: JobInvoiceResult?
    @State private var labourVAT: Decimal? = 20
    @State private var fallbackRate: Decimal?
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var notes = ""

    private var options: JobInvoiceOptions {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return JobInvoiceOptions(labourTaxRate: labourVAT, hourlyRate: fallbackRate,
                                 dueDate: hasDueDate ? CalendarDay(date: dueDate) : nil,
                                 notes: trimmed.isEmpty ? nil : trimmed)
    }

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .idle, .loading:
                    SkeletonRow()
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let preview):
                    if let created {
                        Section {
                            Label("Draft invoice \(created.invoiceNumber ?? "") created", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Tone.success.color)
                            NavigationLink("Open invoice") { InvoiceDetailView(invoiceUuid: created.invoiceUuid) }
                                .accessibilityIdentifier("jobInvoice.open")
                        }
                    }
                    if created == nil {
                        Section {
                            LabeledContent("Labour VAT %") {
                                TextField("20", value: $labourVAT, format: .number)
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("jobInvoice.labourVAT")
                            }
                            LabeledContent("Hourly rate if missing") {
                                TextField("Only if missing", value: $fallbackRate, format: .number)
                                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("jobInvoice.fallbackRate")
                            }
                            Toggle("Set a due date", isOn: $hasDueDate)
                            if hasDueDate {
                                DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                            }
                            TextField("Invoice notes (optional)", text: $notes, axis: .vertical)
                                .lineLimit(1...4)
                        } header: {
                            Text("Invoice options")
                        } footer: {
                            Text("The fallback rate prices labour that has no hourly rate on the visit, job or job type.")
                        }
                    }
                    Section("Billable") {
                        if preview.lines.isEmpty {
                            Text("Nothing to invoice — no uninvoiced labour or approved items.").foregroundStyle(.secondaryText)
                        }
                        ForEach(preview.lines, id: \.self) { line in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(line.description)
                                    Text("\(line.quantity.formatted()) × \(Formatters.money(line.unitPrice, currency: preview.currency) ?? "")")
                                        .font(.wsCaption).foregroundStyle(.secondaryText)
                                    if line.missingRate {
                                        Label("No hourly rate", systemImage: "exclamationmark.triangle.fill")
                                            .font(.wsCaption).foregroundStyle(Tone.warning.color)
                                    }
                                }
                                Spacer()
                                Text(Formatters.money(line.total, currency: preview.currency) ?? "").monospacedDigit()
                            }
                        }
                    }
                    Section("Totals") {
                        DetailRow(label: "Subtotal", value: Formatters.money(preview.subtotal, currency: preview.currency))
                        DetailRow(label: "Tax", value: Formatters.money(preview.taxAmount, currency: preview.currency))
                        DetailRow(label: "Total", value: Formatters.money(preview.total, currency: preview.currency))
                    }
                    if created == nil {
                        Section {
                            Button {
                                Task { await createInvoice() }
                            } label: {
                                if creating { ProgressView().tint(.white) } else { Text("Create draft invoice") }
                            }
                            .buttonStyle(.large(.success))
                            .disabled(!preview.canInvoice || creating)
                            .accessibilityIdentifier("jobInvoice.create")
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        } footer: {
                            if preview.missingRate {
                                Text("Enter a fallback hourly rate above (or set one on the job) to price the labour marked “No hourly rate”.")
                            } else if !preview.canInvoice {
                                Text("Draft and cancelled jobs can't be invoiced.")
                            }
                        }
                    }
                    if let error { Section { InlineErrorRow(error: error) } }
                }
            }
            .navigationTitle("Invoice \(detail.job.jobNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: PreviewKey(labourVAT: labourVAT, fallbackRate: fallbackRate)) {
                if state.value != nil { try? await Task.sleep(for: .milliseconds(400)) }
                guard !Task.isCancelled, created == nil else { return }
                await load()
            }
        }
    }

    private struct PreviewKey: Hashable {
        let labourVAT: Decimal?
        let fallbackRate: Decimal?
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.fieldService.invoicePreview(jobUuid: detail.job.uuid, options: options))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func createInvoice() async {
        creating = true
        error = nil
        defer { creating = false }
        do {
            created = try await services.fieldService.createInvoice(jobUuid: detail.job.uuid, options: options)
            onInvoiced()
        } catch {
            self.error = error.asAPIError
        }
    }
}
