import SwiftUI

/// Logs a part, material or labour line against a job (engineers booked on the job may do this).
struct AddJobItemSheet: View {
    let detail: JobDetail
    let onAdded: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var itemType: JobItemType = .part
    @State private var description = ""
    @State private var quantity: Decimal = 1
    @State private var unitPrice: Decimal?
    @State private var phaseUuid: String?
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $itemType) {
                        ForEach(JobItemType.allCases, id: \.self) { Text(Formatters.humanize($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("What was used?", text: $description, axis: .vertical)
                        .accessibilityIdentifier("addItem.description")
                    Stepper(value: $quantity, in: 0.25...10_000, step: itemType == .labour ? 0.25 : 1) {
                        LabeledContent("Quantity", value: quantity.formatted())
                    }
                    TextField("Unit price (optional)", value: $unitPrice, format: .number)
                        .keyboardType(.decimalPad)
                } footer: {
                    if itemType == .part || itemType == .material {
                        Text("Parts and materials need office approval before they're invoiced.")
                    }
                }
                if !detail.phases.isEmpty {
                    Section("Phase") {
                        Picker("Phase", selection: $phaseUuid) {
                            Text("None").tag(String?.none)
                            ForEach(detail.sortedPhases) { Text($0.name).tag(Optional($0.uuid)) }
                        }
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Add item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(description.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear {
                phaseUuid = detail.sortedPhases.first { !$0.status.isFinished }?.uuid
            }
        }
    }

    private func submit() {
        saving = true
        error = nil
        let myOpenVisit = detail.visits.first { $0.engineerUserUuid == session.user?.uuid && $0.status == .onSite }
        let body = AddJobItemBody(itemType: itemType.rawValue, description: description.trimmingCharacters(in: .whitespaces),
                                  quantity: quantity, unitPrice: unitPrice, visitUuid: myOpenVisit?.uuid, phaseUuid: phaseUuid)
        Task {
            defer { saving = false }
            do {
                _ = try await services.fieldService.addItem(jobUuid: detail.job.uuid, body: body)
                onAdded()
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

/// Books an engineer visit (dispatchers with `fs_visits.create`).
struct BookVisitSheet: View {
    let detail: JobDetail
    let onBooked: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                     of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!) ?? Date()
    @State private var durationHours = 2.0
    @State private var engineerUuid: String?
    @State private var engineers: [Engineer] = []
    @State private var phaseUuid: String?
    @State private var instructions = ""
    @State private var saving = false
    @State private var error: APIError?
    @State private var conflicts: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("When") {
                    DatePicker("Start", selection: $start, in: Date()...)
                    Stepper(value: $durationHours, in: 0.5...12, step: 0.5) {
                        LabeledContent("Duration", value: Formatters.hours(Decimal(durationHours)) ?? "")
                    }
                }
                Section("Who") {
                    Picker("Engineer", selection: $engineerUuid) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(engineers) { Text($0.displayName).tag(Optional($0.uuid)) }
                    }
                }
                if !detail.phases.isEmpty {
                    Section("Phase") {
                        Picker("Phase", selection: $phaseUuid) {
                            Text("None").tag(String?.none)
                            ForEach(detail.sortedPhases.filter { !$0.status.isFinished }) { Text($0.name).tag(Optional($0.uuid)) }
                        }
                    }
                }
                Section("Instructions") {
                    TextField("Access notes, parking, contact on arrival…", text: $instructions, axis: .vertical)
                        .lineLimit(2...6)
                }
                if !conflicts.isEmpty {
                    Section {
                        ForEach(conflicts, id: \.self) { Label($0, systemImage: "calendar.badge.exclamationmark") }
                    } header: {
                        Text("Booked — note overlapping visits")
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Book visit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(conflicts.isEmpty ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if conflicts.isEmpty {
                        Button("Book") { submit() }.disabled(saving)
                    }
                }
            }
            .task { engineers = (try? await services.fieldService.engineers()) ?? [] }
        }
    }

    private struct BookingBody: Encodable, Sendable {
        let scheduledStart: Date
        let scheduledEnd: Date
        let engineerUserUuid: String?
        let phaseUuid: String?
        let instructions: String?
    }

    private struct BookingResult: Decodable, Sendable {
        struct Conflict: Decodable, Sendable { let jobNumber: String?; let scheduledStart: Date? }
        let conflicts: LossyArray<Conflict>?
    }

    private func submit() {
        saving = true
        error = nil
        // Dates encode as ISO-8601 UTC — the API silently drops offsets.
        let body = BookingBody(scheduledStart: start, scheduledEnd: start.addingTimeInterval(durationHours * 3600),
                        engineerUserUuid: engineerUuid, phaseUuid: phaseUuid,
                        instructions: instructions.isEmpty ? nil : instructions)
        Task {
            defer { saving = false }
            do {
                let envelope: Envelope.Standard<BookingResult> = try await services.client.send(
                    .post("\(FieldServiceAPI.base)/jobs/\(detail.job.uuid)/visits", json: body))
                onBooked()
                let overlapping = envelope.data.conflicts?.elements ?? []
                if overlapping.isEmpty {
                    dismiss()
                } else {
                    conflicts = overlapping.map { "\($0.jobNumber ?? "Another job") at \(Formatters.dateTime($0.scheduledStart) ?? "")" }
                }
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

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
                    Section("Billable") {
                        if preview.lines.isEmpty {
                            Text("Nothing to invoice — no uninvoiced labour or approved items.").foregroundStyle(.secondaryText)
                        }
                        ForEach(preview.lines, id: \.self) { line in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(line.description)
                                    Text("\(line.quantity.formatted()) × \(Formatters.money(line.unitPrice, currency: preview.currency) ?? "")")
                                        .font(.caption).foregroundStyle(.secondaryText)
                                    if line.missingRate {
                                        Label("No hourly rate", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundStyle(Tone.warning.color)
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
                                Text("Set an hourly rate on the job or job type before invoicing.")
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
            .task { await load() }
        }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await services.invoices.jobInvoicePreview(jobUuid: detail.job.uuid))
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    private func createInvoice() async {
        creating = true
        error = nil
        defer { creating = false }
        do {
            created = try await services.invoices.createJobInvoice(jobUuid: detail.job.uuid, dueDate: nil)
            onInvoiced()
        } catch {
            self.error = error.asAPIError
        }
    }
}
