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
    @State private var editingJob = false
    @State private var confirmingDelete = false
    @State private var phaseForm: PhaseFormTarget?
    @State private var deletingPhase: JobPhase?
    @State private var visitForm: VisitFormTarget?
    @State private var cancellingVisit: Visit?
    @State private var visitCancelReason = ""
    @State private var deletingVisit: Visit?
    @State private var editingItem: JobItem?
    @State private var deletingItem: JobItem?
    @State private var jobSheet: URL?
    @State private var notice: String?
    @State private var manageError: APIError?
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    /// Add a phase, or change one.
    struct PhaseFormTarget: Identifiable {
        let phase: JobPhase?
        var id: String { phase?.uuid ?? "new" }
    }

    /// Book a visit, or reschedule / reassign one.
    struct VisitFormTarget: Identifiable {
        let visit: Visit?
        var id: String { visit?.uuid ?? "new" }
    }

    var body: some View {
        toolbarLayer
    }

    /// The screen, its loading and the job-status prompts. The modifiers are split into layers so
    /// the compiler can type-check each in reasonable time.
    private var core: some View {
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
    }

    /// Forms: lines, visits, phases, job details.
    private var sheetLayer: some View {
        core
            .sheet(isPresented: $addingItem) {
                if let detail = model.detail {
                    JobItemFormSheet(jobUuid: detail.job.uuid, currency: detail.job.currency, phases: detail.sortedPhases,
                                     item: nil, visitUuid: myOpenVisit(detail)?.uuid,
                                     showsPrices: model.policy.isDispatcherForJobs) { saved($0) }
                }
            }
            .sheet(item: $editingItem) { item in
                if let detail = model.detail {
                    JobItemFormSheet(jobUuid: detail.job.uuid, currency: detail.job.currency, phases: detail.sortedPhases,
                                     item: item, showsPrices: model.policy.isDispatcherForJobs) { saved($0) }
                }
            }
            .sheet(isPresented: $bookingVisit) {
                if let detail = model.detail {
                    VisitFormSheet(jobUuid: detail.job.uuid, phases: detail.sortedPhases.filter { !$0.status.isFinished },
                                   visit: nil) { saved($0) }
                }
            }
            .sheet(item: $visitForm) { target in
                if let detail = model.detail {
                    VisitFormSheet(jobUuid: detail.job.uuid, phases: detail.sortedPhases, visit: target.visit) { saved($0) }
                }
            }
            .sheet(item: $phaseForm) { target in
                if let detail = model.detail {
                    PhaseFormSheet(title: target.phase == nil ? "Add a phase" : "Edit phase",
                                   initial: target.phase.map(PhaseFormValues.init(phase:)) ?? PhaseFormValues(),
                                   showsNotes: target.phase != nil) { values in
                        try await services.fieldService.savePhase(jobUuid: detail.job.uuid, phaseUuid: target.phase?.uuid,
                                                                  body: values.phaseBody(existing: target.phase))
                        saved(target.phase == nil ? "Phase “\(values.trimmedName)” added." : "Phase saved.")
                    }
                }
            }
            .sheet(isPresented: $editingJob) {
                JobEditSheet(jobUuid: model.jobUuid) { saved("Job details saved.") }
            }
    }

    /// Confirmations before deleting or cancelling, then the quote and invoice sheets.
    private var dialogLayer: some View {
        sheetLayer
            .confirmationDialog("Delete this job?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete job", role: .destructive) { Task { await deleteJob() } }
            } message: {
                Text("Its visits are removed too. Cancel the job instead if you need to keep a record.")
            }
            .confirmationDialog("Remove this phase?", isPresented: .init(get: { deletingPhase != nil },
                                                                        set: { if !$0 { deletingPhase = nil } }),
                                titleVisibility: .visible, presenting: deletingPhase) { phase in
                Button("Remove “\(phase.name)”", role: .destructive) {
                    Task { await manage("Phase removed.") { try await services.fieldService.deletePhase(phase.uuid) } }
                }
            } message: { _ in
                Text("Visits and parts linked to it keep their records but lose the phase link.")
            }
            .confirmationDialog("Delete this visit?", isPresented: .init(get: { deletingVisit != nil },
                                                                        set: { if !$0 { deletingVisit = nil } }),
                                titleVisibility: .visible, presenting: deletingVisit) { visit in
                Button("Delete visit", role: .destructive) {
                    Task { await manage("Visit deleted.") { try await services.fieldService.deleteVisit(visit.uuid) } }
                }
            } message: { _ in
                Text("It's removed from the schedule. Cancel it instead to keep a record.")
            }
            .confirmationDialog("Remove this line?", isPresented: .init(get: { deletingItem != nil },
                                                                       set: { if !$0 { deletingItem = nil } }),
                                titleVisibility: .visible, presenting: deletingItem) { item in
                Button("Remove “\(item.description)”", role: .destructive) {
                    Task { await manage("Line removed.") { try await services.fieldService.deleteItem(itemUuid: item.uuid) } }
                }
            } message: { _ in
                Text("It comes off the job and won't be invoiced.")
            }
    }

    /// Cancelling a visit, and the quote and invoice sheets.
    private var promptLayer: some View {
        dialogLayer
            .alert("Cancel this visit?", isPresented: .init(get: { cancellingVisit != nil },
                                                            set: { if !$0 { cancellingVisit = nil } }),
                   presenting: cancellingVisit) { visit in
                TextField("Reason (optional)", text: $visitCancelReason)
                Button("Cancel visit", role: .destructive) {
                    let reason = visitCancelReason.trimmingCharacters(in: .whitespaces)
                    Task {
                        await manage("Visit cancelled.") {
                            try await services.fieldService.cancelVisit(visit.uuid, reason: reason.isEmpty ? nil : reason)
                        }
                    }
                }
                Button("Keep visit", role: .cancel) {}
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
    }

    /// The "More actions" menu and the job sheet it makes.
    private var toolbarLayer: some View {
        promptLayer
            .toolbar {
                if let detail = model.detail {
                    let policy = model.policy
                    // POST /jobs/:uuid/visits checks fs_visits.create only.
                    let canBook = detail.job.status.isOpen && session.permissions.can(.create, .fsVisits)
                    let editable = detail.job.status != .completed && detail.job.status != .cancelled
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if policy.canAddItem(in: detail) {
                                Button("Add a line", systemImage: "shippingbox") { addingItem = true }
                            }
                            if canBook {
                                Button("Book a visit", systemImage: "calendar.badge.plus") { bookingVisit = true }
                            }
                            if policy.isDispatcherForJobs && editable {
                                Button("Add a phase", systemImage: "list.bullet.rectangle") {
                                    phaseForm = PhaseFormTarget(phase: nil)
                                }
                            }
                            if policy.canCreateInvoice(for: detail) {
                                Button("Invoice job", systemImage: "doc.text") { invoicing = true }
                            }
                            Button("Job sheet (PDF)", systemImage: "printer") {
                                Task { jobSheet = await jobSheetFile(detail) }
                            }
                            if policy.isDispatcherForJobs {
                                Button("Edit job details", systemImage: "pencil") { editingJob = true }
                            }
                            if session.permissions.can(.delete, .fsJobs) && detail.job.invoiceUuid == nil {
                                Button("Delete job", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            }
                        } label: {
                            Label("More actions", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("job.moreActions")
                    }
                }
            }
            .sheet(item: Binding(get: { jobSheet.map { ExportedFile(url: $0) } }, set: { if $0 == nil { jobSheet = nil } })) { file in
                NavigationStack {
                    List {
                        Section {
                            Label("Job sheet ready", systemImage: "doc.richtext")
                            ShareLink(item: file.url) { Label("Share, print or save the PDF", systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("job.sheet.share")
                        } footer: {
                            Text("The engineer's worksheet: customer and site, phases and checklists, visits, labour, "
                                 + "materials, hire, notes and signature lines.")
                        }
                    }
                    .navigationTitle("Job sheet")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { jobSheet = nil } } }
                }
                .presentationDetents([.medium])
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

            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("job.notice")
                }
            }
            if let manageError {
                Section { InlineErrorRow(error: manageError) }
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
                Section {
                    ForEach(detail.visits.sorted { ($0.scheduledStart ?? .distantPast) < ($1.scheduledStart ?? .distantPast) }) { visit in
                        HStack(spacing: 4) {
                            if visit.engineerUserUuid == session.user?.uuid && !policy.isDispatcherForVisits {
                                NavigationLink(value: GuidedVisitRoute(uuid: visit.uuid)) {
                                    VisitSummaryRow(visit: visit, showsJob: false)
                                }
                            } else if policy.isDispatcherForVisits {
                                NavigationLink(value: VisitRoute(uuid: visit.uuid)) {
                                    VisitSummaryRow(visit: visit, showsJob: false)
                                }
                            } else {
                                // GET /visits/:uuid is for the visit's own engineer or fs_visits.update.
                                VStack(alignment: .leading, spacing: 2) {
                                    VisitSummaryRow(visit: visit, showsJob: false)
                                    Text("Only \(visit.engineerName ?? "its engineer") or a manager can open this visit.")
                                        .font(.wsCaption).foregroundStyle(.secondaryText)
                                }
                            }
                            if hasVisitActions(visit, detail: detail) {
                                moreMenu("More for this visit", id: "job.visit.more.\(visit.uuid)") {
                                    visitActions(visit, detail: detail)
                                }
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) { visitActions(visit, detail: detail) }
                        .contextMenu { visitActions(visit, detail: detail) }
                    }
                } header: {
                    Text("Visits")
                } footer: {
                    if canManageVisits(detail) {
                        Text("Tap … on a visit that hasn't started to reschedule, reassign, cancel or delete it.")
                    }
                }
            }

            if !detail.items.isEmpty || policy.canAddItem(in: detail) {
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

            if !detail.activity.isEmpty || policy.isDispatcherForJobs || policy.isEngineer(on: detail) {
                Section("Activity") {
                    if policy.isDispatcherForJobs || policy.isEngineer(on: detail) {
                        JobCommentRow(jobUuid: detail.job.uuid) { saved("Note added to the job.") }
                    }
                    ForEach(detail.activity.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message ?? Formatters.humanize(entry.action)).font(.wsSubheadline)
                            Text([entry.actorName, Formatters.dateTime(entry.createdAt)].compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
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
                            Text(job.invoiceNumber ?? "Invoice").font(.wsHeadline)
                            if let invoicedAt = job.invoicedAt {
                                Text("Raised \(Formatters.dateTime(invoicedAt) ?? "")").font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            InvoiceStatus(api: job.invoiceStatus).badge
                            Text(Formatters.money(job.invoiceTotal, currency: job.currency) ?? "").font(.wsSubheadline.monospacedDigit())
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

    // MARK: Managing the job

    /// The job sheet, carrying the customer's signature from the latest visit they signed at (best effort: without
    /// read access to that visit's signature, the sheet keeps the blank line to sign by hand).
    private func jobSheetFile(_ detail: JobDetail) async -> URL? {
        var signed: JobSheetPDF.CustomerSignature?
        let visits = detail.visits.filter(\.hasCustomerSignature)
            .sorted { ($0.checkedOutAt ?? .distantPast) > ($1.checkedOutAt ?? .distantPast) }
        for visit in visits {
            guard let status = try? await services.fieldService.visitSignature(visit.uuid),
                  let signature = status.signature else { continue }
            let image = (try? await services.fieldService.visitSignatureImage(visit.uuid)).flatMap(UIImage.init(data:))
            signed = .init(name: signature.signerName ?? visit.customerSignoffName, signedAt: signature.signedAt, image: image)
            break
        }
        return JobSheetPDF.file(for: detail, company: session.workspace?.name, customerSignature: signed)
    }

    /// Reschedule / reassign (PUT /visits/:uuid beyond the engineer's report fields) and cancel need
    /// fs_visits.update; delete needs fs_visits.delete (field-service-visits.lua).
    private func canManageVisits(_ detail: JobDetail) -> Bool {
        session.permissions.can(.update, .fsVisits) || session.permissions.can(.delete, .fsVisits)
    }

    @ViewBuilder
    private func visitActions(_ visit: Visit, detail: JobDetail) -> some View {
        let preStart = visit.status == .scheduled || visit.status == .enRoute
        let editable = detail.job.status != .completed && detail.job.status != .cancelled
        if session.permissions.can(.update, .fsVisits) && preStart && editable {
            Button { visitForm = VisitFormTarget(visit: visit) } label: { Label("Reschedule", systemImage: "calendar") }
                .tint(.blue)
            Button {
                visitCancelReason = ""
                cancellingVisit = visit
            } label: { Label("Cancel visit", systemImage: "xmark.circle") }
                .tint(.orange)
        }
        if session.permissions.can(.delete, .fsVisits) && !visit.invoiced && visit.timesheetUuid == nil && visit.status != .onSite {
            Button(role: .destructive) { deletingVisit = visit } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func hasVisitActions(_ visit: Visit, detail: JobDetail) -> Bool {
        let preStart = visit.status == .scheduled || visit.status == .enRoute
        let editable = detail.job.status != .completed && detail.job.status != .cancelled
        return (session.permissions.can(.update, .fsVisits) && preStart && editable)
            || (session.permissions.can(.delete, .fsVisits) && !visit.invoiced && visit.timesheetUuid == nil && visit.status != .onSite)
    }

    private func hasPhaseActions(_ detail: JobDetail) -> Bool {
        model.policy.isDispatcherForJobs && detail.job.status != .completed && detail.job.status != .cancelled
    }

    /// Edit / remove a line, and approve or reject it, from its "…" menu or a long press.
    @ViewBuilder
    private func itemActions(_ item: JobItem, detail: JobDetail, policy: FieldServicePolicy) -> some View {
        if canEditItem(item, detail: detail) {
            Button { editingItem = item } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { deletingItem = item } label: { Label("Remove", systemImage: "trash") }
        }
        if policy.canApproveItems(in: detail), !item.invoiced {
            if item.approvalStatus != .approved {
                Button { Task { await model.setApproval(item, approve: true) } } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
            }
            if item.approvalStatus != .rejected {
                Button { Task { await model.setApproval(item, approve: false) } } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
            }
        }
    }

    /// The visible "…" beside a row, so its actions don't hide behind a swipe.
    private func moreMenu<Content: View>(_ label: String, id: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
                .font(.wsTitle3)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func phaseActions(_ phase: JobPhase, detail: JobDetail) -> some View {
        let editable = detail.job.status != .completed && detail.job.status != .cancelled
        if model.policy.isDispatcherForJobs && editable {
            Button { phaseForm = PhaseFormTarget(phase: phase) } label: { Label("Edit", systemImage: "pencil") }
                .tint(.blue)
            if phase.status != .completed {
                Button(role: .destructive) { deletingPhase = phase } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    /// Managers change any line; an engineer only the lines they logged (as the server checks).
    private func canEditItem(_ item: JobItem, detail: JobDetail) -> Bool {
        guard !item.invoiced, detail.job.status != .cancelled else { return false }
        if model.policy.isDispatcherForJobs { return true }
        return model.policy.isEngineer(on: detail) && item.createdByUuid != nil && item.createdByUuid == session.user?.uuid
    }

    /// The engineer's visit that is on site now: a line they add is logged on it.
    private func myOpenVisit(_ detail: JobDetail) -> Visit? {
        detail.visits.first { $0.engineerUserUuid == session.user?.uuid && $0.status == .onSite }
    }

    private func saved(_ message: String) {
        notice = message
        manageError = nil
        Task { await model.load() }
    }

    private func manage(_ message: String, _ work: () async throws -> Void) async {
        do {
            try await work()
            saved(message)
        } catch {
            manageError = error.asAPIError
            notice = nil
        }
    }

    private func deleteJob() async {
        do {
            try await services.fieldService.deleteJob(model.jobUuid)
            dismiss()
        } catch {
            manageError = error.asAPIError
        }
    }

    private func header(_ detail: JobDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(detail.job.title)
                .font(.wsTitle2.bold())
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
                    .font(.wsSubheadline.weight(.semibold))
            } else if let due = detail.job.dueDate {
                Label("Due \(Formatters.day(due.date()) ?? "")", systemImage: "calendar.badge.clock")
                    .font(.wsSubheadline)
            }
            if let description = detail.job.description, !description.isEmpty {
                Text(description).font(.wsBody).foregroundStyle(.secondaryText)
            }
            if let type = detail.job.jobTypeName {
                Label(type, systemImage: "tag").font(.wsSubheadline)
            }
            if detail.job.estimatedHours != nil || detail.job.hourlyRate != nil {
                Text([detail.job.estimatedHours.map { "Estimate \(Formatters.hours($0) ?? "")" },
                      detail.job.hourlyRate.map { "Rate \(Formatters.money($0, currency: detail.job.currency) ?? "") an hour" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let notes = detail.job.notes, !notes.isEmpty {
                Label("Notes: \(notes)", systemImage: "note.text").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if detail.job.status == .cancelled, let reason = detail.job.cancelledReason {
                Label("Cancelled: \(reason)", systemImage: "xmark.octagon").font(.wsSubheadline)
                    .foregroundStyle(Tone.danger.textColor)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func customerSection(_ job: Job) -> some View {
        if job.customerName != nil || job.fullAddress != nil || job.customerPhone != nil || job.siteName != nil
            || job.customerEmail != nil {
            Section("Customer & site") {
                DetailRow(label: "Customer", value: job.customerName, systemImage: "person")
                DetailRow(label: "Site", value: job.siteName, systemImage: "building.2")
                if let notes = job.siteAccessNotes, !notes.isEmpty {
                    Label(notes, systemImage: "key.fill")
                        .font(.wsSubheadline)
                        .foregroundStyle(Tone.warning.color)
                        .accessibilityLabel("Access notes: \(notes)")
                }
                if let phone = job.customerPhone {
                    PhoneLinkRow(name: job.customerName, phone: phone)
                }
                if let email = job.customerEmail {
                    EmailLinkRow(email: email)
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
                HStack(spacing: 4) {
                    NavigationLink {
                        PhaseDetailView(model: model, phaseUuid: display.phase.uuid)
                    } label: {
                        PhaseRow(display: display)
                    }
                    .accessibilityIdentifier("job.phase.\(display.phase.sortOrder)")
                    if hasPhaseActions(detail), !editMode.isEditing {
                        moreMenu("More for “\(display.phase.name)”", id: "job.phase.more.\(display.phase.sortOrder)") {
                            phaseActions(display.phase, detail: detail)
                        }
                    }
                }
                .swipeActions(allowsFullSwipe: false) { phaseActions(display.phase, detail: detail) }
                .contextMenu { phaseActions(display.phase, detail: detail) }
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
                    .font(.wsSubheadline.weight(.semibold))
                    .textCase(nil)
                    .accessibilityHint("Drag phases to change their order")
                }
            }
        }
    }

    private func itemsSection(_ detail: JobDetail, policy: FieldServicePolicy) -> some View {
        Section("Parts & items") {
            if detail.items.isEmpty {
                Text("No parts, materials or labour logged yet.").foregroundStyle(.secondaryText)
            }
            if policy.canAddItem(in: detail) {
                Button { addingItem = true } label: { Label("Add a line", systemImage: "plus.circle") }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("job.addItem")
            }
            ForEach(detail.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.isLabour || item.isHire ? item.quoteSummary : item.description).font(.wsHeadline)
                        Spacer()
                        Text(Formatters.money(item.lineTotal, currency: detail.job.currency) ?? "")
                            .font(.wsSubheadline.monospacedDigit())
                        if canEditItem(item, detail: detail) || (policy.canApproveItems(in: detail) && !item.invoiced) {
                            moreMenu("More for this line", id: "job.item.more.\(item.uuid)") {
                                itemActions(item, detail: detail, policy: policy)
                            }
                        }
                    }
                    Text(["\(item.quantity.formatted()) × \(Formatters.money(item.unitPrice, currency: detail.job.currency) ?? "")",
                          Formatters.humanize(item.itemType), item.supplier, item.partNumber.map { "Part \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    HStack {
                        item.approvalStatus.badge
                        if item.invoiced {
                            StatusBadge(text: "Invoiced", systemImage: "doc.text.fill", tone: .success)
                        }
                    }
                    if let reason = item.rejectionReason {
                        Text(reason).font(.wsFootnote).foregroundStyle(Tone.danger.color)
                    }
                    // What the engineer photographed on site. Approving a part on the strength of
                    // its evidence is the point of the proposal flow (opsapi #619), so the
                    // evidence has to be here, not a tap away on another screen.
                    if item.isMaterial, !item.invoiced {
                        ItemEvidenceStrip(itemUuid: item.uuid)
                    }
                }
                .padding(.vertical, 4)
                .contextMenu { itemActions(item, detail: detail, policy: policy) }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if canEditItem(item, detail: detail) {
                        Button("Edit") { editingItem = item }.tint(.blue)
                        Button("Remove", role: .destructive) { deletingItem = item }
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
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
            .navigationDestination(for: ProjectRoute.self) { ProjectDetailView(uuid: $0.uuid) }
            .navigationDestination(for: BoardRoute.self) { BoardView(uuid: $0.uuid, name: $0.name) }
            .navigationDestination(for: SprintRoute.self) { SprintDetailView(uuid: $0.uuid, name: $0.name) }
            .navigationDestination(for: TaskRoute.self) { TaskDetailView(uuid: $0.uuid) }
            .navigationDestination(for: TimesheetRoute.self) { TimesheetDetailView(uuid: $0.uuid) }
            .navigationDestination(for: PDTaskRoute.self) { PDTaskDetailView(taskUuid: $0.uuid) }
            .navigationDestination(for: PDDealRoute.self) { PDDealView(dealUuid: $0.uuid) }
            .navigationDestination(for: PDDealsRoute.self) { PDDealsListView(initialFilter: $0.filter) }
            .navigationDestination(for: PDApprovalsRoute.self) { _ in PDApprovalsListView() }
            .navigationDestination(for: PDApprovalRoute.self) { PDApprovalDetailView(approvalUuid: $0.uuid) }
            .navigationDestination(for: PDLeadRoute.self) { PDLeadView(leadUuid: $0.uuid) }
            .navigationDestination(for: PATodayRoute.self) { PATodayView(manager: $0.manager) }
            .navigationDestination(for: PAPrepareRoute.self) { PAPrepareView(route: $0) }
            .navigationDestination(for: PAHandoffRoute.self) { PAHandoffView(uuid: $0.uuid) }
            .navigationDestination(for: PACaptureRoute.self) { PACaptureView(captureUuid: $0.uuid) }
            .navigationDestination(for: PDDueRoute.self) { _ in PDDueView() }
            .navigationDestination(for: PDRenovationsRoute.self) { _ in PDRenovationsListView() }
            .navigationDestination(for: PurchaseOrdersRoute.self) { PurchaseOrdersListView(route: $0) }
            .navigationDestination(for: NativeScreen.self) { $0.view }
            .navigationDestination(for: ResourceListRoute.self) { ResourceListView(route: $0) }
            .navigationDestination(for: ResourceRoute.self) { ResourceDetailView(route: $0) }
            .navigationDestination(for: ResourceReportRoute.self) { ResourceReportView(route: $0) }
            .navigationDestination(for: NativeScreenRoute.self) { NativeScreenView(route: $0) }
            .navigationDestination(for: PurchaseOrderRoute.self) { PurchaseOrderDetailView(uuid: $0.uuid) }
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
                case .projects: ProjectsListView()
                case .timesheets: TimesheetsView()
                case .myTasks: MyTasksView()
                case .reviewQueue: ReviewQueueView()
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
                    .font(.wsHeadline.monospacedDigit())
                    .foregroundStyle(.secondaryText)
                Text(phase.name).font(.wsHeadline)
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
            .font(.wsFootnote)
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
                    .font(.wsBody)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Customer name").font(.wsSubheadline.weight(.semibold))
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
