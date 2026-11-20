import SwiftUI

@MainActor
@Observable
final class VisitDetailViewModel {
    let visitUuid: String
    private(set) var state: LoadState<VisitDetail> = .idle
    private(set) var cachedAt: Date?
    private(set) var busy = false
    var actionError: APIError?
    var warnings: [String] = []

    /// The API reports "Phase not completed: …" when check-out couldn't close the task. Say what
    /// to do about it rather than repeating the server's wording (#611).
    nonisolated static func actionable(_ warning: String) -> String {
        guard warning.localizedCaseInsensitiveContains("phase not completed") else { return warning }
        if warning.localizedCaseInsensitiveContains("sign") {
            return "The task stayed open — add the customer's sign-off name to close it."
        }
        if warning.localizedCaseInsensitiveContains("checklist") {
            return "The task stayed open — tick off the remaining checklist items to close it."
        }
        return "The task stayed open, so the office may chase it. Finish the checklist to close it."
    }
    var queuedMessage: String?
    /// Said after an action worked ("Logged 2.5 h to the timesheet").
    var notice: String?

    private let api: FieldServiceAPI
    private let sync: SyncCenter
    private let session: SessionStore
    private let location = LocationProvider()

    init(visitUuid: String, api: FieldServiceAPI, sync: SyncCenter, session: SessionStore) {
        self.visitUuid = visitUuid
        self.api = api
        self.sync = sync
        self.session = session
    }

    var detail: VisitDetail? { state.value }

    /// The visit with any queued writes applied, so the engineer sees what they did offline.
    var displayedVisit: Visit? {
        guard var visit = detail?.visit else { return nil }
        for mutation in sync.pending(for: visit.uuid) {
            switch mutation.kind {
            case .visitEnRoute: visit.status = .enRoute
            case .visitCheckIn: visit.status = .onSite
            case .visitCheckOut: visit.status = .completed
            case .visitNoAccess: visit.status = .noAccess
            default: break
            }
        }
        return visit
    }

    var pendingWrites: [PendingMutation] { sync.pending(for: visitUuid) }
    var canWork: Bool { detail.map { session.policy.canWork($0.visit) } ?? false }
    var canCancel: Bool { displayedVisit.map { session.policy.canCancel($0) } ?? false }

    func load() async {
        if detail == nil { state = .loading }
        do {
            let fetched = try await api.visit(visitUuid)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if detail == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    func markEnRoute() async {
        guard let visit = detail?.visit, let context = session.mutationContext else { return }
        await perform(FieldServiceAPI.Mutations.enRoute(visit, context: context))
    }

    func checkIn() async {
        guard let visit = detail?.visit, let context = session.mutationContext else { return }
        busy = true
        let coordinates = await location.currentCoordinates()
        busy = false
        await perform(FieldServiceAPI.Mutations.checkIn(visit, coordinates: coordinates, context: context))
    }

    func checkOut(_ form: CheckOutForm) async -> Bool {
        guard let visit = detail?.visit, let context = session.mutationContext else { return false }
        busy = true
        let coordinates = await location.currentCoordinates()
        busy = false
        let body = form.body(coordinates: coordinates)
        return await perform(FieldServiceAPI.Mutations.checkOut(visit, body: body, context: context))
    }

    func markNoAccess(reason: String) async -> Bool {
        guard let visit = detail?.visit, let context = session.mutationContext else { return false }
        return await perform(FieldServiceAPI.Mutations.noAccess(visit, reason: reason, context: context))
    }

    /// Quote-sheet line logged on site; queued offline like the other on-site writes.
    func addItem(_ body: AddJobItemBody) async -> Bool {
        guard let visit = detail?.visit, let context = session.mutationContext else { return false }
        var body = body
        body.visitUuid = visit.uuid
        body.phaseUuid = body.phaseUuid ?? visit.phaseUuid
        busy = true
        defer { busy = false }
        do {
            switch try await sync.perform(FieldServiceAPI.Mutations.addItem(visit, body: body, context: context)) {
            case .sent:
                await load()
            case .queued:
                queuedMessage = "Saved on this device. It will be added to the job when you're back online."
            }
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }

    /// Ticks a checklist item on the visit's phase (engineer booked on the job).
    func toggleChecklist(index: Int) async {
        guard var detail, var phase = detail.phase, phase.checklist.indices.contains(index),
              let context = session.mutationContext else { return }
        let done = !phase.checklist[index].done
        phase.checklist[index].done = done
        detail.phase = phase
        state = .loaded(detail)
        let mutation = FieldServiceAPI.Mutations.checklist(phase: phase, index: index, done: done,
                                                           jobUuid: detail.visit.jobUuid, context: context)
        do {
            if case .sent(let data) = try await sync.perform(mutation),
               let envelope = try? JSONDecoder.opsAPI().decode(Envelope.Standard<JobPhase>.self, from: data) {
                detail.phase = envelope.data
                state = .loaded(detail)
            }
        } catch {
            phase.checklist[index].done = !done
            detail.phase = phase
            state = .loaded(detail)
            actionError = error.asAPIError
        }
    }

    func replace(_ updated: VisitDetail) {
        state = .loaded(updated)
        cachedAt = nil
    }

    /// Quote lines waiting to sync for this visit.
    var pendingItemSummaries: [PendingMutation] {
        sync.pending(for: visitUuid).filter { $0.kind == .jobItemAdd }
    }

    var showsPrices: Bool { session.permissions.can(.update, .fsJobs) }

    func cancelVisit(reason: String?) async {
        busy = true
        defer { busy = false }
        do {
            let endpoint = Endpoint.post("\(FieldServiceAPI.base)/visits/\(visitUuid)/cancel", json: ReasonBody(reason: reason))
            let envelope: Envelope.Standard<VisitDetail> = try await api.client.send(endpoint)
            state = .loaded(envelope.data)
        } catch {
            actionError = error.asAPIError
        }
    }

    // MARK: Timesheet, phase and items

    /// A completed visit with labour hours and an engineer, not yet on a timesheet.
    var canLogTimesheet: Bool {
        guard canWork, let visit = detail?.visit else { return false }
        return Self.canLogTimesheet(visit)
    }

    nonisolated static func canLogTimesheet(_ visit: Visit) -> Bool {
        visit.status == .completed && visit.timesheetUuid == nil && (visit.labourHours ?? 0) > 0
            && visit.engineerUserUuid != nil
    }

    func logTimesheet() async {
        busy = true
        defer { busy = false }
        do {
            let result = try await api.logTimesheet(visitUuid: visitUuid)
            notice = "\(Formatters.hours(result.hours) ?? "The hours") logged to the timesheet."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    /// Completes the visit's phase. `signoffName` is needed when the phase asks for a sign-off;
    /// `force` completes it with checklist items still unticked (the server says no otherwise).
    func completePhase(signoffName: String?, force: Bool) async -> Bool {
        guard let detail, let phase = detail.phase, let context = session.mutationContext else { return false }
        let name = signoffName?.trimmingCharacters(in: .whitespaces)
        let body = PhaseStatusChangeBody(status: PhaseStatus.completed.rawValue,
                                         signoffName: name?.isEmpty == false ? name : nil,
                                         force: force ? true : nil, notes: nil)
        busy = true
        defer { busy = false }
        do {
            switch try await sync.perform(FieldServiceAPI.Mutations.phaseStatus(phase: phase, body: body,
                                                                                 jobUuid: detail.visit.jobUuid,
                                                                                 context: context)) {
            case .sent:
                notice = "“\(phase.name)” is complete."
                await load()
            case .queued:
                queuedMessage = "Saved on this device. The phase will be completed when you're back online."
            }
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }

    /// Managers change any line; an engineer only the lines they logged (as the server checks).
    func canEdit(_ item: JobItem) -> Bool {
        guard !item.invoiced else { return false }
        if session.permissions.can(.update, .fsJobs) { return true }
        return canWork && item.createdByUuid != nil && item.createdByUuid == session.user?.uuid
    }

    /// After the line form saved: say so and show the new state.
    func itemSaved(_ message: String) {
        notice = message
        Task { await load() }
    }

    func deleteItem(_ item: JobItem) async {
        busy = true
        defer { busy = false }
        do {
            try await api.deleteItem(itemUuid: item.uuid)
            notice = "“\(item.description)” removed from the visit."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    @discardableResult
    private func perform(_ mutation: PendingMutation) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            switch try await sync.perform(mutation) {
            case .sent(let data):
                apply(responseData: data, kind: mutation.kind)
            case .queued:
                queuedMessage = "Saved on this device. It will be sent automatically when you're back online."
            }
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }

    private func apply(responseData data: Data, kind: PendingMutation.Kind) {
        let decoder = JSONDecoder.opsAPI()
        if kind == .visitCheckOut, let result = try? decoder.decode(Envelope.Standard<CheckOutResult>.self, from: data) {
            state = .loaded(result.data.visit)
            warnings = result.data.warnings.map(Self.actionable)
        } else if let envelope = try? decoder.decode(Envelope.Standard<VisitDetail>.self, from: data) {
            state = .loaded(envelope.data)
        }
        cachedAt = nil
    }
}

/// The work report collected at check-out.
struct CheckOutForm: Equatable {
    var workSummary = ""
    var labourHours: Double = 1
    var customerSignoffName = ""
    var followUpRequired = false
    var followUpNotes = ""
    var completePhase = false
    var forcePhase = false

    init(visit: Visit, phase: JobPhase?, now: Date = Date()) {
        if let checkedIn = visit.checkedInAt {
            let hours = now.timeIntervalSince(checkedIn) / 3600
            // Nearest quarter hour, clamped to the API's 0–24 range.
            labourHours = min(24, max(0.25, (hours * 4).rounded() / 4))
        }
        if let phase {
            completePhase = !phase.status.isFinished
        }
    }

    /// The work summary is optional server-side (#610 finish sheet); hours must be within 0–24.
    var isValid: Bool {
        labourHours >= 0 && labourHours <= 24
    }

    func body(coordinates: Coordinates?) -> CheckOutBody {
        let trimmedSignoff = customerSignoffName.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = followUpNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return CheckOutBody(workSummary: workSummary.trimmingCharacters(in: .whitespacesAndNewlines),
                            labourHours: Decimal(labourHours),
                            customerSignoffName: trimmedSignoff.isEmpty ? nil : trimmedSignoff,
                            followUpRequired: followUpRequired,
                            followUpNotes: followUpRequired && !trimmedNotes.isEmpty ? trimmedNotes : nil,
                            completePhase: completePhase,
                            forcePhase: completePhase && forcePhase,
                            latitude: coordinates?.latitude,
                            longitude: coordinates?.longitude)
    }
}

struct VisitDetailView: View {
    let visitUuid: String
    @Environment(\.services) private var services
    @Environment(SyncCenter.self) private var sync
    @Environment(SessionStore.self) private var session
    @State private var model: VisitDetailViewModel?

    var body: some View {
        Group {
            if let model {
                VisitDetailContent(model: model)
            } else {
                SkeletonList(rows: 3)
            }
        }
        .navigationTitle("Visit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil {
                model = VisitDetailViewModel(visitUuid: visitUuid, api: services.fieldService, sync: sync, session: session)
            }
        }
    }
}

private struct VisitDetailContent: View {
    @Bindable var model: VisitDetailViewModel
    @Environment(SessionStore.self) private var session
    @State private var showingCheckOut = false
    @State private var showingNoAccess = false
    @State private var confirmingCancel = false
    @State private var cancelReason = ""
    @State private var quoteKind: QuoteLineSheet.Kind?
    @State private var editingItem: JobItem?
    @State private var addingLine = false
    @State private var deletingItem: JobItem?
    @State private var completingPhase = false
    @State private var signoffName = ""

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded(let detail):
                if let visit = model.displayedVisit {
                    loaded(detail: detail, visit: visit)
                }
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $showingCheckOut) {
            if let detail = model.detail {
                CheckOutSheet(visit: detail.visit, phase: detail.phase) { form in
                    await model.checkOut(form)
                }
            }
        }
        .sheet(isPresented: $showingNoAccess) {
            NoAccessSheet { reason in await model.markNoAccess(reason: reason) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $quoteKind) { kind in
            QuoteLineSheet(kind: kind, showsPrices: model.showsPrices) { body in
                await model.addItem(body)
            }
        }
        .sheet(item: $editingItem) { item in
            if let detail = model.detail {
                JobItemFormSheet(jobUuid: detail.visit.jobUuid, currency: detail.visit.jobCurrency ?? "GBP",
                                 phases: detail.phase.map { [$0] } ?? [], item: item,
                                 showsPrices: model.showsPrices) { message in model.itemSaved(message) }
            }
        }
        .sheet(isPresented: $addingLine) {
            if let detail = model.detail {
                JobItemFormSheet(jobUuid: detail.visit.jobUuid, currency: detail.visit.jobCurrency ?? "GBP",
                                 phases: detail.phase.map { [$0] } ?? [], item: nil, visitUuid: detail.visit.uuid,
                                 showsPrices: model.showsPrices) { message in model.itemSaved(message) }
            }
        }
        .confirmationDialog("Remove this line?", isPresented: .init(get: { deletingItem != nil },
                                                                   set: { if !$0 { deletingItem = nil } }),
                            titleVisibility: .visible, presenting: deletingItem) { item in
            Button("Remove “\(item.description)”", role: .destructive) {
                Task { await model.deleteItem(item) }
            }
        } message: { _ in
            Text("It comes off the job and won't be invoiced.")
        }
        .alert("Complete this phase?", isPresented: $completingPhase) {
            if model.detail?.phase?.needsSignoff == true {
                TextField("Customer's name for sign-off", text: $signoffName)
            }
            Button("Complete phase") {
                let unticked = model.detail?.phase?.uncheckedCount ?? 0
                Task { _ = await model.completePhase(signoffName: signoffName, force: unticked > 0) }
            }
            Button("Not yet", role: .cancel) {}
        } message: {
            Text(completeMessage)
        }
        .alert("Cancel this visit?", isPresented: $confirmingCancel) {
            TextField("Reason (optional)", text: $cancelReason)
            Button("Cancel visit", role: .destructive) {
                Task { await model.cancelVisit(reason: cancelReason.isEmpty ? nil : cancelReason) }
            }
            Button("Keep visit", role: .cancel) {}
        }
        .alert("Couldn't update the visit", isPresented: .init(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
               presenting: model.actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription + (error.serverError?.correlationId.map { "\n\nReference: \($0)" } ?? ""))
        }
        .alert("Checked out with warnings", isPresented: .init(get: { !model.warnings.isEmpty }, set: { if !$0 { model.warnings = [] } }),
               presenting: model.warnings) { _ in
            Button("OK", role: .cancel) {}
        } message: { warnings in
            Text("The visit is complete, but:\n• " + warnings.joined(separator: "\n• "))
        }
        .alert("Saved offline", isPresented: .init(get: { model.queuedMessage != nil }, set: { if !$0 { model.queuedMessage = nil } }),
               presenting: model.queuedMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var completeMessage: String {
        guard let phase = model.detail?.phase else { return "" }
        var lines: [String] = []
        if phase.uncheckedCount > 0 {
            lines.append("\(phase.uncheckedCount) checklist item(s) aren't ticked. The phase will be completed anyway.")
        }
        if phase.needsSignoff { lines.append("This phase needs the customer's name.") }
        return lines.isEmpty ? "“\(phase.name)” will be marked complete." : lines.joined(separator: " ")
    }

    private func loaded(detail: VisitDetail, visit: Visit) -> some View {
        let jobOpen = visit.jobStatus != .completed && visit.jobStatus != .cancelled
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        visit.status.badge
                            .accessibilityIdentifier("visit.status")
                        if visit.isUrgent { visit.jobPriority.badge }
                        if !model.pendingWrites.isEmpty {
                            PendingSyncBadge(failed: model.pendingWrites.contains(where: \.isFailed))
                        }
                    }
                    Text(visit.jobTitle).font(.wsTitle2.bold())
                    if let start = visit.scheduledStart {
                        Label(scheduleText(start: start, end: visit.scheduledEnd), systemImage: "clock")
                            .font(.wsSubheadline)
                    }
                    Label(visit.engineerName ?? "No engineer assigned yet", systemImage: "person.fill")
                        .font(.wsSubheadline)
                        .foregroundStyle(visit.engineerName == nil ? Tone.warning.textColor : .primary)
                    if let phase = visit.phaseName {
                        Label("Phase: \(phase)", systemImage: "list.bullet.clipboard").font(.wsSubheadline)
                    }
                    if let checkedIn = visit.checkedInAt {
                        Label("Checked in \(Formatters.time(checkedIn) ?? "")", systemImage: "arrow.down.to.line")
                            .font(.wsSubheadline)
                    }
                    if visit.followUpRequired {
                        Label("Follow-up needed", systemImage: "flag.fill")
                            .font(.wsSubheadline.weight(.semibold))
                            .foregroundStyle(Tone.warning.textColor)
                    }
                }
                .padding(.vertical, 4)
                if session.permissions.can(.read, .fsJobs) {
                    NavigationLink(value: JobRoute(uuid: visit.jobUuid)) {
                        Label("Open job \(visit.jobNumber)", systemImage: "wrench.and.screwdriver")
                    }
                    .accessibilityIdentifier("visit.openJob")
                }
                if let cachedAt = model.cachedAt {
                    CachedDataNotice(savedAt: cachedAt)
                }
            }

            if let notice = model.notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("visit.notice")
                }
            }

            if model.canWork {
                actionsSection(visit)
            }

            Section("Site") {
                DetailRow(label: "Customer", value: visit.customerName ?? "No customer", systemImage: "person")
                if let phone = visit.customerPhone {
                    PhoneLinkRow(name: visit.customerName ?? "Customer", phone: phone)
                }
                if let address = visit.fullAddress {
                    MapsLinkRow(address: address)
                }
                DetailRow(label: "Product", value: [visit.productName, visit.productRef].compactMap { $0 }.joined(separator: " · "),
                          systemImage: "shippingbox")
                if let access = visit.siteAccessNotes, !access.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Getting in", systemImage: "key").font(.wsCaption).foregroundStyle(.secondaryText)
                        Text(access)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("Instructions", systemImage: "text.bubble").font(.wsCaption).foregroundStyle(.secondaryText)
                    Text(visit.instructions?.isEmpty == false ? visit.instructions! : "No instructions.")
                }
            }

            Section {
                FGasCard(visit: visit, canEdit: model.canWork) { updated in model.replace(updated) }
            }

            if let phase = detail.phase {
                phaseSection(phase, canTick: model.canWork && jobOpen)
            }

            reportSection(visit)

            itemsSection(detail: detail, visit: visit)
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func phaseSection(_ phase: JobPhase, canTick: Bool) -> some View {
        Section {
            HStack {
                Text(phase.name).font(.wsHeadline)
                Spacer()
                phase.status.badge
            }
            if let description = phase.description, !description.isEmpty {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if phase.checklist.isEmpty {
                Label("No checklist for this phase.", systemImage: "checklist").foregroundStyle(.secondaryText)
            }
            ForEach(Array(phase.checklist.enumerated()), id: \.offset) { index, item in
                Button {
                    Task { await model.toggleChecklist(index: index) }
                } label: {
                    Label {
                        Text(item.label).foregroundStyle(.primary).strikethrough(item.done)
                    } icon: {
                        Image(systemName: item.done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(item.done ? Tone.success.textColor : .secondaryText)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(!canTick)
                .accessibilityValue(item.done ? "Done" : "Not done")
                .accessibilityIdentifier("visit.checklist.\(index)")
            }
            if phase.needsSignoff {
                Label("Needs the customer's sign-off", systemImage: "signature")
                    .font(.wsSubheadline)
                    .foregroundStyle(Tone.warning.textColor)
            } else if let signed = phase.signoffName {
                Label("Signed off by \(signed)", systemImage: "signature").font(.wsSubheadline)
            }
            if canTick && !phase.status.isFinished {
                Button {
                    signoffName = ""
                    completingPhase = true
                } label: {
                    Label("Complete phase", systemImage: "checkmark.circle")
                }
                .frame(minHeight: 44)
                .disabled(model.busy)
                .accessibilityIdentifier("visit.completePhase")
            }
        } header: {
            Text("Phase")
        } footer: {
            if !canTick && !phase.checklist.isEmpty {
                Text("The checklist can be ticked by the engineer on this visit while the job is open.")
            }
        }
    }

    @ViewBuilder
    private func reportSection(_ visit: Visit) -> some View {
        let hasReport = visit.checkedInAt != nil || visit.checkedOutAt != nil || visit.workSummary != nil
            || visit.customerSignoffName != nil || visit.followUpNotes != nil || visit.cancelledReason != nil
            || visit.timesheetUuid != nil
        if hasReport {
            Section("Report") {
                if let summary = visit.workSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Work carried out").font(.wsCaption).foregroundStyle(.secondaryText)
                        Text(summary)
                    }
                }
                if let checkedIn = visit.checkedInAt {
                    DetailRow(label: "Checked in", value: Formatters.dateTime(checkedIn))
                }
                if let checkedOut = visit.checkedOutAt {
                    DetailRow(label: "Checked out", value: Formatters.dateTime(checkedOut))
                }
                if let hours = Formatters.hours(visit.labourHours) {
                    DetailRow(label: "Labour", value: hours)
                }
                if let signoff = visit.customerSignoffName {
                    Label("Signed off by \(signoff)\(visit.customerSignedAt.flatMap { " · \(Formatters.dateTime($0) ?? "")" } ?? "")",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Tone.success.textColor)
                }
                if let notes = visit.followUpNotes {
                    Label("\(visit.status == .noAccess ? "No access" : "Follow-up"): \(notes)", systemImage: "flag.fill")
                        .foregroundStyle(Tone.warning.textColor)
                }
                if let reason = visit.cancelledReason {
                    Label("Cancelled: \(reason)", systemImage: "xmark.octagon")
                        .foregroundStyle(Tone.danger.textColor)
                }
                if visit.timesheetUuid != nil {
                    Label("Logged to the timesheet", systemImage: "clock.badge.checkmark")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func itemsSection(detail: VisitDetail, visit: Visit) -> some View {
        let canLog = model.canWork && visit.jobStatus != .cancelled
        if !detail.items.isEmpty || canLog {
            Section {
                if detail.items.isEmpty {
                    Text("Nothing logged on this visit yet.").foregroundStyle(.secondaryText)
                }
                ForEach(detail.items) { item in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.description)
                            Text([Formatters.humanize(item.itemType), "Qty \(item.quantity.formatted())",
                                  model.showsPrices ? Formatters.money(item.lineTotal, currency: visit.jobCurrency ?? "GBP") : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        item.approvalStatus.badge
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        if model.canEdit(item) {
                            Button("Remove", role: .destructive) { deletingItem = item }
                            Button("Edit") { editingItem = item }
                        }
                    }
                    .contextMenu {
                        if model.canEdit(item) {
                            Button { editingItem = item } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { deletingItem = item } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
                if canLog {
                    Menu {
                        Button { addingLine = true } label: { Label("Part from the catalogue, or any line", systemImage: "shippingbox") }
                        ForEach(QuoteLineSheet.Kind.allCases) { kind in
                            Button { quoteKind = kind } label: { Label(kind.title, systemImage: kind.systemImage) }
                        }
                    } label: {
                        Label("Log a part, labour or hire", systemImage: "plus.circle")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("visit.logItem")
                }
            } header: {
                Text("Parts and labour on this visit")
            } footer: {
                if detail.items.contains(where: { model.canEdit($0) }) {
                    Text("Swipe a line to edit or remove it.")
                }
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ visit: Visit) -> some View {
        let open = visit.status.isOpen
        if open {
            Section {
                switch visit.status {
                case .scheduled:
                    actionButton("Check in", systemImage: "mappin.and.ellipse", tone: .success, prominent: true, id: "checkIn") {
                        Task { await model.checkIn() }
                    }
                    actionButton("On my way", systemImage: "car.fill", tone: .info, prominent: false, id: "enRoute") {
                        Task { await model.markEnRoute() }
                    }
                case .enRoute:
                    actionButton("Check in", systemImage: "mappin.and.ellipse", tone: .success, prominent: true, id: "checkIn") {
                        Task { await model.checkIn() }
                    }
                case .onSite:
                    actionButton("Check out", systemImage: "checkmark.circle.fill", tone: .success, prominent: true, id: "checkOut") {
                        showingCheckOut = true
                    }
                default:
                    EmptyView()
                }
                actionButton("No access to site", systemImage: "door.left.hand.closed", tone: .danger, prominent: false, id: "noAccess") {
                    showingNoAccess = true
                }
                if visit.status != .onSite {
                    Button("Complete without checking in…") { showingCheckOut = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("visit.action.checkOutDirect")
                }
                if model.canCancel {
                    Button("Cancel visit", role: .destructive) {
                        cancelReason = ""
                        confirmingCancel = true
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            } footer: {
                Text("Your location is recorded only at check-in and check-out.")
            }
        } else if model.canLogTimesheet {
            Section {
                actionButton("Log to timesheet", systemImage: "clock.badge.checkmark", tone: .info, prominent: false,
                             id: "logTimesheet") {
                    Task { await model.logTimesheet() }
                }
            } footer: {
                Text("Adds this visit's \(Formatters.hours(visit.labourHours) ?? "hours") to the engineer's timesheet.")
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, tone: Tone, prominent: Bool, id: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if model.busy {
                ProgressView().tint(prominent ? .white : tone.color)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .buttonStyle(.large(tone, prominent: prominent))
        .disabled(model.busy)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("visit.action.\(id)")
    }

    private func scheduleText(start: Date, end: Date?) -> String {
        let startText = start.formatted(date: .abbreviated, time: .shortened)
        guard let end else { return startText }
        return "\(startText) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}

struct CheckOutSheet: View {
    let visit: Visit
    let phase: JobPhase?
    let submit: (CheckOutForm) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var form: CheckOutForm
    @State private var submitting = false

    init(visit: Visit, phase: JobPhase?, submit: @escaping (CheckOutForm) async -> Bool) {
        self.visit = visit
        self.phase = phase
        self.submit = submit
        _form = State(initialValue: CheckOutForm(visit: visit, phase: phase))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SheetSectionTitle("Work report")
                    TextField("What did you do?", text: $form.workSummary, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("checkout.workSummary")
                } footer: {
                    Text("Tip: use the microphone on the keyboard to dictate.")
                }

                Section {
                    Stepper(value: $form.labourHours, in: 0...24, step: 0.25) {
                        LabeledContent("Labour", value: Formatters.hours(Decimal(form.labourHours)) ?? "")
                            .font(.wsTitle3.monospacedDigit())
                    }
                    .accessibilityIdentifier("checkout.labourHours")
                } footer: {
                    if visit.checkedInAt == nil {
                        Text("You didn't check in, so enter the hours worked.")
                    }
                }

                Section {
                    SheetSectionTitle("Customer")
                    TextField("Customer name for sign-off", text: $form.customerSignoffName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("checkout.signoff")
                }

                if let phase {
                    Section {
                        SheetSectionTitle("Phase")
                        Toggle("Complete “\(phase.name)”", isOn: $form.completePhase)
                            .disabled(phase.status.isFinished)
                        if form.completePhase {
                            if phase.needsSignoff && form.customerSignoffName.trimmingCharacters(in: .whitespaces).isEmpty {
                                Label("This phase needs the customer's name above.", systemImage: "signature")
                                    .foregroundStyle(Tone.warning.textColor)
                            }
                            if phase.uncheckedCount > 0 {
                                Toggle("Complete even though \(phase.uncheckedCount) checklist item(s) aren't ticked", isOn: $form.forcePhase)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Follow-up visit needed", isOn: $form.followUpRequired)
                    if form.followUpRequired {
                        TextField("What needs doing next?", text: $form.followUpNotes, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                Section {
                    Button {
                        submitting = true
                        Task {
                            let ok = await submit(form)
                            submitting = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if submitting { ProgressView().tint(.white) } else { Text("Check out") }
                    }
                    .buttonStyle(.large(.success))
                    .disabled(!form.isValid || submitting)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityIdentifier("checkout.submit")
                }
            }
            .navigationTitle("Check out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .interactiveDismissDisabled(submitting)
        }
    }
}

struct NoAccessSheet: View {
    let submit: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var submitting = false
    private let quickReasons = ["Nobody home", "Site locked", "Customer cancelled on arrival", "Unsafe to work"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    ForEach(quickReasons, id: \.self) { quick in
                        Button {
                            reason = quick
                        } label: {
                            HStack {
                                Text(quick).foregroundStyle(.primary)
                                Spacer()
                                if reason == quick { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    TextField("Other reason", text: $reason, axis: .vertical)
                }
                Section {
                    Button {
                        submitting = true
                        Task {
                            let ok = await submit(reason)
                            submitting = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if submitting { ProgressView().tint(.white) } else { Text("Record no access") }
                    }
                    .buttonStyle(.large(.danger))
                    .disabled(reason.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("A follow-up will be flagged for the office.")
                }
            }
            .navigationTitle("No access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
