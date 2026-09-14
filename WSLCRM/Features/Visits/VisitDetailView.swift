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
    var queuedMessage: String?

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
            warnings = result.data.warnings
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

    var isValid: Bool {
        !workSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && labourHours >= 0 && labourHours <= 24
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
    @State private var showingCheckOut = false
    @State private var showingNoAccess = false
    @State private var confirmingCancel = false
    @State private var cancelReason = ""

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

    private func loaded(detail: VisitDetail, visit: Visit) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        visit.status.badge
                            .accessibilityIdentifier("visit.status")
                        if !model.pendingWrites.isEmpty {
                            PendingSyncBadge(failed: model.pendingWrites.contains(where: \.isFailed))
                        }
                    }
                    Text(visit.jobTitle).font(.title2.bold())
                    if let start = visit.scheduledStart {
                        Label(scheduleText(start: start, end: visit.scheduledEnd), systemImage: "clock")
                            .font(.subheadline)
                    }
                    if let checkedIn = visit.checkedInAt {
                        Label("Checked in \(Formatters.time(checkedIn) ?? "")", systemImage: "arrow.down.to.line")
                            .font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
                NavigationLink(value: JobRoute(uuid: visit.jobUuid)) {
                    Label("Open job \(visit.jobNumber)", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("visit.openJob")
                if let cachedAt = model.cachedAt {
                    CachedDataNotice(savedAt: cachedAt)
                }
            }

            if model.canWork {
                actionsSection(visit)
            }

            Section("Site") {
                DetailRow(label: "Customer", value: visit.customerName, systemImage: "person")
                if let phone = visit.customerPhone {
                    PhoneLinkRow(name: visit.customerName, phone: phone)
                }
                if let address = visit.fullAddress {
                    MapsLinkRow(address: address)
                }
                DetailRow(label: "Product", value: [visit.productName, visit.productRef].compactMap { $0 }.joined(separator: " · "),
                          systemImage: "shippingbox")
                if let instructions = visit.instructions, !instructions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Instructions", systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary)
                        Text(instructions)
                    }
                }
            }

            if let phase = detail.phase {
                Section("Phase") {
                    HStack {
                        Text(phase.name).font(.headline)
                        Spacer()
                        phase.status.badge
                    }
                    if !phase.checklist.isEmpty {
                        Label("\(phase.checklist.count - phase.uncheckedCount) of \(phase.checklist.count) checklist items done",
                              systemImage: "checklist")
                            .font(.subheadline)
                    }
                    if phase.needsSignoff {
                        Label("Needs customer sign-off", systemImage: "signature")
                            .font(.subheadline)
                            .foregroundStyle(Tone.warning.color)
                    }
                    NavigationLink(value: JobRoute(uuid: visit.jobUuid)) {
                        Text("Open checklist in job")
                    }
                }
            }

            if visit.status == .completed || visit.status == .noAccess {
                Section("Report") {
                    if let summary = visit.workSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Work summary").font(.caption).foregroundStyle(.secondary)
                            Text(summary)
                        }
                    }
                    DetailRow(label: "Labour", value: Formatters.hours(visit.labourHours))
                    DetailRow(label: "Signed off by", value: visit.customerSignoffName)
                    DetailRow(label: "Checked out", value: Formatters.dateTime(visit.checkedOutAt))
                    if visit.followUpRequired {
                        Label(visit.followUpNotes ?? "Follow-up required", systemImage: "flag.fill")
                            .foregroundStyle(Tone.warning.color)
                    }
                }
            }

            if !detail.items.isEmpty {
                Section("Items logged on this visit") {
                    ForEach(detail.items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.description)
                                Text("Qty \(item.quantity.formatted())").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            item.approvalStatus.badge
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
                    TextField("What did you do?", text: $form.workSummary, axis: .vertical)
                        .lineLimit(4...10)
                        .accessibilityIdentifier("checkout.workSummary")
                } header: {
                    Text("Work report")
                } footer: {
                    Text("Tip: use the microphone on the keyboard to dictate.")
                }

                Section {
                    Stepper(value: $form.labourHours, in: 0...24, step: 0.25) {
                        LabeledContent("Labour", value: Formatters.hours(Decimal(form.labourHours)) ?? "")
                            .font(.title3.monospacedDigit())
                    }
                    .accessibilityIdentifier("checkout.labourHours")
                } footer: {
                    if visit.checkedInAt == nil {
                        Text("You didn't check in, so enter the hours worked.")
                    }
                }

                Section("Customer") {
                    TextField("Customer name for sign-off", text: $form.customerSignoffName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("checkout.signoff")
                }

                if let phase {
                    Section {
                        Toggle("Complete “\(phase.name)”", isOn: $form.completePhase)
                            .disabled(phase.status.isFinished)
                        if form.completePhase {
                            if phase.needsSignoff && form.customerSignoffName.trimmingCharacters(in: .whitespaces).isEmpty {
                                Label("This phase needs the customer's name above.", systemImage: "signature")
                                    .foregroundStyle(Tone.warning.color)
                            }
                            if phase.uncheckedCount > 0 {
                                Toggle("Complete even though \(phase.uncheckedCount) checklist item(s) aren't ticked", isOn: $form.forcePhase)
                            }
                        }
                    } header: {
                        Text("Phase")
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
