import SwiftUI

struct JobDetailView: View {
    let jobUuid: String
    @Environment(\.services) private var services
    @Environment(SyncCenter.self) private var sync
    @Environment(SessionStore.self) private var session
    @State private var model: JobDetailViewModel?

    var body: some View {
        Group {
            if let model {
                JobDetailContent(model: model)
            } else {
                SkeletonList(rows: 4)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil {
                model = JobDetailViewModel(jobUuid: jobUuid, api: services.fieldService, sync: sync, session: session)
            }
        }
    }
}

private struct JobDetailContent: View {
    @Bindable var model: JobDetailViewModel
    @Environment(SyncCenter.self) private var sync
    @State private var editMode: EditMode = .inactive
    @State private var cancellingJob = false
    @State private var cancelReason = ""
    @State private var addingItem = false
    @State private var bookingVisit = false
    @State private var invoicing = false
    @State private var quoting = false
    @State private var photos: JobPhotosModel?
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services

    var body: some View {
        content
            .navigationTitle(model.detail?.job.jobNumber ?? "Job")
            .task { await model.load() }
            .refreshable { await model.load() }
            .onChange(of: sync.syncedGeneration) { _, _ in
                if sync.lastSyncedJobIds.contains(model.jobUuid) { Task { await model.load() } }
            }
            .jobActionPrompts(model: model)
            .alert("Cancel this job?", isPresented: $cancellingJob) {
                TextField("Reason (optional)", text: $cancelReason)
                Button("Cancel job", role: .destructive) {
                    Task { await model.changeJobStatus(to: .cancelled, reason: cancelReason.isEmpty ? nil : cancelReason) }
                }
                Button("Keep job", role: .cancel) {}
            } message: {
                Text("Scheduled and en-route visits will also be cancelled.")
            }
            .sheet(isPresented: $addingItem) {
                if let detail = model.detail {
                    AddJobItemSheet(detail: detail) { Task { await model.load() } }
                }
            }
            .sheet(isPresented: $bookingVisit) {
                if let detail = model.detail {
                    BookVisitSheet(detail: detail) { Task { await model.load() } }
                }
            }
            .sheet(isPresented: $quoting) {
                if let detail = model.detail {
                    JobQuoteSheet(detail: detail) { Task { await model.load() } }
                }
            }
            .sheet(isPresented: $invoicing) {
                if let detail = model.detail {
                    JobInvoiceSheet(detail: detail) { Task { await model.load() } }
                }
            }
            .toolbar {
                if let detail = model.detail {
                    let policy = model.policy
                    let canBook = detail.job.status.isOpen && session.permissions.can(.create, .fsVisits)
                    if policy.canAddItem(in: detail) || canBook || policy.canCreateInvoice(for: detail) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                if policy.canAddItem(in: detail) {
                                    Button("Add part or item", systemImage: "shippingbox") { addingItem = true }
                                }
                                if canBook {
                                    Button("Book visit", systemImage: "calendar.badge.plus") { bookingVisit = true }
                                }
                                if policy.canCreateInvoice(for: detail) {
                                    Button("Invoice job", systemImage: "doc.text") { invoicing = true }
                                }
                            } label: {
                                Label("More actions", systemImage: "ellipsis.circle")
                            }
                            .accessibilityIdentifier("job.moreActions")
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            SkeletonList(rows: 4)
        case .failed(let error):
            ErrorStateView(error: error) { Task { await model.load() } }
        case .loaded(let detail):
            loaded(detail)
        }
    }

    private func loaded(_ detail: JobDetail) -> some View {
        let policy = model.policy
        return List {
            Section {
                header(detail)
                if let cachedAt = model.cachedAt {
                    CachedDataNotice(savedAt: cachedAt)
                }
            }

            if policy.canChangeJobStatus(detail) {
                Section("Actions") {
                    ForEach(orderedTransitions(detail.allowedTransitions), id: \.self) { status in
                        Button {
                            if status == .cancelled {
                                cancelReason = ""
                                cancellingJob = true
                            } else {
                                Task { await model.changeJobStatus(to: status) }
                            }
                        } label: {
                            Label(status.actionTitle, systemImage: status.systemImage)
                        }
                        .buttonStyle(.large(status == .cancelled ? .danger : status.tone,
                                            prominent: status == .completed || status == .inProgress))
                        .listRowSeparator(.hidden)
                        .disabled(model.busyKey != nil)
                        .accessibilityIdentifier("job.action.\(status.rawValue)")
                    }
                }
            }

            customerSection(detail.job)

            phasesSection(detail, policy: policy)

            if !detail.visits.isEmpty {
                Section("Visits") {
                    ForEach(detail.visits.sorted { ($0.scheduledStart ?? .distantPast) < ($1.scheduledStart ?? .distantPast) }) { visit in
                        Group {
                            if visit.engineerUserUuid == session.user?.uuid && !policy.isDispatcherForVisits {
                                NavigationLink(value: GuidedVisitRoute(uuid: visit.uuid)) {
                                    VisitSummaryRow(visit: visit, showsJob: false)
                                }
                            } else {
                                NavigationLink(value: VisitRoute(uuid: visit.uuid)) {
                                    VisitSummaryRow(visit: visit, showsJob: false)
                                }
                            }
                        }
                    }
                }
            }

            if !detail.items.isEmpty {
                itemsSection(detail, policy: policy)
            }

            quoteSection(detail, policy: policy)
            invoiceSection(detail, policy: policy)

            if let photos {
                Section {
                    PhotosSection(model: photos, canEdit: detail.job.status != .cancelled
                                  && (policy.isDispatcherForJobs || policy.isEngineer(on: detail)))
                }
            }

            if let totals = detail.totals {
                Section("Totals") {
                    DetailRow(label: "Labour hours", value: Formatters.hours(totals.labourHours))
                    DetailRow(label: "Labour value", value: Formatters.money(totals.labourValue, currency: detail.job.currency))
                    DetailRow(label: "Parts & materials", value: Formatters.money(totals.itemsValue, currency: detail.job.currency))
                    DetailRow(label: "Not yet invoiced", value: Formatters.money(totals.uninvoicedValue, currency: detail.job.currency))
                    if totals.missingRate {
                        Label("Some labour has no hourly rate", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Tone.warning.color)
                    }
                }
            }

            if !detail.activity.isEmpty {
                Section("Activity") {
                    ForEach(detail.activity.prefix(15)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message ?? Formatters.humanize(entry.action)).font(.subheadline)
                            Text([entry.actorName, Formatters.dateTime(entry.createdAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .onAppear {
            if photos == nil { photos = JobPhotosModel(jobUuid: detail.job.uuid, visitUuid: nil, api: services.fieldService) }
        }
    }

    /// Customer quotation (#611): the sheet's lines priced up as an estimate, shared or emailed.
    /// Nothing here bills — that stays with the invoice below.
    @ViewBuilder
    private func quoteSection(_ detail: JobDetail, policy: FieldServicePolicy) -> some View {
        if policy.canQuote(for: detail) {
            Section {
                Button {
                    quoting = true
                } label: {
                    Label("Customer quotation", systemImage: "doc.plaintext")
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("job.quote")
            } header: {
                Text("Quotation")
            } footer: {
                Text(QuotePDFRenderer.quotableItems(detail).isEmpty
                     ? "Add labour, materials or hire to the sheet to quote for this job."
                     : "An estimate for the customer, built from the job's quote sheet.")
            }
        }
    }

    /// Invoice status on the job, with a link to the invoice, or the way to raise one.
    @ViewBuilder
    private func invoiceSection(_ detail: JobDetail, policy: FieldServicePolicy) -> some View {
        let job = detail.job
        if let invoiceUuid = job.invoiceUuid {
            Section("Invoice") {
                NavigationLink(value: InvoiceRoute(uuid: invoiceUuid)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.invoiceNumber ?? "Invoice").font(.headline)
                            if let invoicedAt = job.invoicedAt {
                                Text("Raised \(Formatters.dateTime(invoicedAt) ?? "")").font(.caption).foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            InvoiceStatus(api: job.invoiceStatus).badge
                            Text(Formatters.money(job.invoiceTotal, currency: job.currency) ?? "").font(.subheadline.monospacedDigit())
                        }
                    }
                }
                .accessibilityIdentifier("job.invoice")
                if policy.canCreateInvoice(for: detail), (detail.totals?.uninvoicedValue ?? 0) > 0 {
                    Button("Invoice new work", systemImage: "doc.badge.plus") { invoicing = true }
                        .frame(minHeight: 44)
                }
            }
        } else if policy.canCreateInvoice(for: detail) {
            Section {
                Button {
                    invoicing = true
                } label: {
                    Label(job.status == .completed ? "Create invoice" : "Preview invoice", systemImage: "doc.text")
                }
                .buttonStyle(.large(.success, prominent: job.status == .completed))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("job.createInvoice")
            } header: {
                Text("Invoice")
            } footer: {
                Text("Bills completed labour and approved parts, materials and hire.")
            }
        }
    }

    private func header(_ detail: JobDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.job.title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                detail.job.status.badge
                    .accessibilityIdentifier("job.status")
                if detail.job.priority != .normal && detail.job.priority != .unknown {
                    detail.job.priority.badge
                }
            }
            if detail.job.isOverdue, let due = detail.job.dueDate {
                Label("Overdue — due \(Formatters.day(due.date()) ?? "")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.danger.color)
                    .font(.subheadline.weight(.semibold))
            } else if let due = detail.job.dueDate {
                Label("Due \(Formatters.day(due.date()) ?? "")", systemImage: "calendar.badge.clock")
                    .font(.subheadline)
            }
            if let description = detail.job.description, !description.isEmpty {
                Text(description).font(.body).foregroundStyle(.secondaryText)
            }
            if let type = detail.job.jobTypeName {
                Label(type, systemImage: "tag").font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func customerSection(_ job: Job) -> some View {
        if job.customerName != nil || job.fullAddress != nil || job.customerPhone != nil || job.siteName != nil {
            Section("Customer & site") {
                DetailRow(label: "Customer", value: job.customerName, systemImage: "person")
                DetailRow(label: "Site", value: job.siteName, systemImage: "building.2")
                if let notes = job.siteAccessNotes, !notes.isEmpty {
                    Label(notes, systemImage: "key.fill")
                        .font(.subheadline)
                        .foregroundStyle(Tone.warning.color)
                        .accessibilityLabel("Access notes: \(notes)")
                }
                if let phone = job.customerPhone {
                    PhoneLinkRow(name: job.customerName, phone: phone)
                }
                if let address = job.fullAddress {
                    MapsLinkRow(address: address)
                }
                DetailRow(label: "Product", value: [job.productName, job.productRef].compactMap { $0 }.joined(separator: " · "),
                          systemImage: "shippingbox")
                DetailRow(label: "Customer ref", value: job.customerReference, systemImage: "number")
                DetailRow(label: "Manager", value: job.serviceManagerName, systemImage: "person.badge.shield.checkmark")
            }
        }
    }

    private func phasesSection(_ detail: JobDetail, policy: FieldServicePolicy) -> some View {
        Section {
            if detail.phases.isEmpty {
                Text("No phases on this job.").foregroundStyle(.secondaryText)
            }
            ForEach(model.displayedPhases, id: \.phase.uuid) { display in
                NavigationLink {
                    PhaseDetailView(model: model, phaseUuid: display.phase.uuid)
                } label: {
                    PhaseRow(display: display)
                }
                .accessibilityIdentifier("job.phase.\(display.phase.sortOrder)")
            }
            .onMove { source, destination in
                Task { await model.movePhases(from: source, to: destination) }
            }
            .moveDisabled(!policy.canReorderPhases(in: detail))
        } header: {
            HStack {
                Text("Phases \(detail.job.phasesDone)/\(detail.job.phaseCount)")
                Spacer()
                if policy.canReorderPhases(in: detail) {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .accessibilityHint("Drag phases to change their order")
                }
            }
        }
    }

    private func itemsSection(_ detail: JobDetail, policy: FieldServicePolicy) -> some View {
        Section("Parts & items") {
            ForEach(detail.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.isLabour || item.isHire ? item.quoteSummary : item.description).font(.headline)
                        Spacer()
                        Text(Formatters.money(item.lineTotal, currency: detail.job.currency) ?? "")
                            .font(.subheadline.monospacedDigit())
                    }
                    Text(["\(item.quantity.formatted()) × \(Formatters.money(item.unitPrice, currency: detail.job.currency) ?? "")",
                          Formatters.humanize(item.itemType), item.supplier, item.partNumber.map { "Part \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondaryText)
                    HStack {
                        item.approvalStatus.badge
                        if item.invoiced {
                            StatusBadge(text: "Invoiced", systemImage: "doc.text.fill", tone: .success)
                        }
                    }
                    if let reason = item.rejectionReason {
                        Text(reason).font(.footnote).foregroundStyle(Tone.danger.color)
                    }
                    // What the engineer photographed on site. Approving a part on the strength of
                    // its evidence is the point of the proposal flow (opsapi #619), so the
                    // evidence has to be here, not a tap away on another screen.
                    if item.isMaterial, !item.invoiced {
                        ItemEvidenceStrip(itemUuid: item.uuid)
                    }
                }
                .padding(.vertical, 4)
                .swipeActions {
                    if policy.canApproveItems(in: detail), !item.invoiced {
                        if item.approvalStatus != .approved {
                            Button("Approve") { Task { await model.setApproval(item, approve: true) } }
                                .tint(.green)
                        }
                        if item.approvalStatus != .rejected {
                            Button("Reject") { Task { await model.setApproval(item, approve: false) } }
                                .tint(.red)
                        }
                    }
                }
            }
        }
    }

    /// Positive progress first, destructive last.
    private func orderedTransitions(_ transitions: [JobStatus]) -> [JobStatus] {
        let order: [JobStatus] = [.inProgress, .completed, .scheduled, .onHold, .draft, .cancelled]
        return transitions.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
}

struct VisitRoute: Hashable { let uuid: String }
struct InvoiceRoute: Hashable { let uuid: String }
struct ServiceRequestRoute: Hashable { let uuid: String }

extension View {
    /// Registers value-based destinations once, at the root of a navigation stack.
    func withAppDestinations() -> some View {
        navigationDestination(for: JobRoute.self) { JobDetailView(jobUuid: $0.uuid) }
            .navigationDestination(for: VisitRoute.self) { VisitDetailView(visitUuid: $0.uuid) }
            .navigationDestination(for: ServiceRequestRoute.self) { ServiceRequestDetailView(requestUuid: $0.uuid) }
            .navigationDestination(for: GuidedVisitRoute.self) { GuidedVisitView(visitUuid: $0.uuid) }
            .navigationDestination(for: InvoiceRoute.self) { InvoiceDetailView(invoiceUuid: $0.uuid) }
            .navigationDestination(for: AssetRoute.self) { AssetDetailView(product: $0.product) }
            .navigationDestination(for: SiteRoute.self) { SiteDetailView(site: $0.site) }
            .navigationDestination(for: CustomerAssetRoute.self) { CustomerAssetDetailView(assetUuid: $0.uuid) }
            .navigationDestination(for: ReportRoute.self) { ReportDetailView(route: $0) }
            .navigationDestination(for: FieldServiceArea.self) { area in
                switch area {
                case .requests: ServiceRequestsListView()
                case .jobs: JobsListView()
                case .assets: AssetSearchView()
                case .sites: SitesListView()
                case .invoices: InvoicesListView()
                case .customerAssets: CustomerAssetsListView()
                case .reports: ReportsListView()
                case .simpro: SimproSyncStatusView()
                }
            }
    }
}

struct PhaseRow: View {
    let display: JobDetailViewModel.PhaseDisplay

    var body: some View {
        let phase = display.phase
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(phase.sortOrder).")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                Text(phase.name).font(.headline)
                Spacer()
                phase.status.badge
            }
            HStack(spacing: 14) {
                if !phase.checklist.isEmpty {
                    Label("\(phase.checklist.count - phase.uncheckedCount)/\(phase.checklist.count) checked",
                          systemImage: "checklist")
                }
                if phase.requiresSignoff {
                    Label(phase.signedOffAt == nil ? "Sign-off needed" : "Signed off", systemImage: "signature")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondaryText)
            if display.hasPendingWrites {
                PendingSyncBadge(failed: display.hasFailedWrites)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Prompts shared by job and phase screens

private struct JobActionPrompts: ViewModifier {
    @Bindable var model: JobDetailViewModel
    @State private var signoffName = ""

    func body(content: Content) -> some View {
        content
            .alert("Complete anyway?", isPresented: .init(get: { model.forcePrompt != nil }, set: { if !$0 { model.forcePrompt = nil } }),
                   presenting: model.forcePrompt) { prompt in
                Button("Complete anyway", role: .destructive) {
                    Task { await model.confirmForce(prompt) }
                }
                Button("Not yet", role: .cancel) {}
            } message: { prompt in
                Text(prompt.message)
            }
            .alert("Something went wrong", isPresented: .init(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
                   presenting: model.actionError) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text(error.localizedDescription + (error.serverError?.correlationId.map { "\n\nReference: \($0)" } ?? ""))
            }
            .alert("Saved offline", isPresented: .init(get: { model.infoMessage != nil }, set: { if !$0 { model.infoMessage = nil } }),
                   presenting: model.infoMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .sheet(item: $model.signoffPrompt) { prompt in
                SignoffSheet(phaseName: prompt.phaseName, name: $signoffName) {
                    let name = signoffName
                    signoffName = ""
                    Task { await model.submitSignoff(prompt, name: name) }
                }
                .presentationDetents([.medium, .large])
            }
    }
}

extension View {
    func jobActionPrompts(model: JobDetailViewModel) -> some View {
        modifier(JobActionPrompts(model: model))
    }
}

struct SignoffSheet: View {
    let phaseName: String
    @Binding var name: String
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("“\(phaseName)” needs the customer's sign-off before it can be completed.")
                    .font(.body)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Customer name").font(.subheadline.weight(.semibold))
                    TextField("Full name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(submit)
                        .fieldStyle()
                        .accessibilityIdentifier("signoff.name")
                }
                Button("Sign off and complete", action: submit)
                    .buttonStyle(.large(.success))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("signoff.submit")
                Spacer()
            }
            .padding(24)
            .navigationTitle("Customer sign-off")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dismiss()
        onSubmit()
    }
}
