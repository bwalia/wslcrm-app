import SwiftUI

/// Licences (`/dashboard/billing/licenses`): keys for desktop and self-hosted software, the devices
/// using them, and suspend / resume / reissue / revoke. RBAC module `licenses`.
struct BillingLicencesView: View {
    @Environment(\.services) private var services

    var body: some View {
        BillingLicencesList(api: services.billing)
    }
}

enum BillingLicenceText {
    /// "ABCD1234-•••••".
    static func key(_ row: Record) -> String { "\(row.string("key_prefix") ?? "—")-•••••" }

    /// "2 of 3 devices", "1 of unlimited devices".
    static func devices(_ row: Record) -> String {
        let used = row.int("active_activations") ?? 0
        let max = row.int("max_activations").map(String.init) ?? "unlimited"
        return "\(used) of \(max) devices"
    }

    static func access(_ row: Record) -> String {
        BillingDay.text(row, "access_until").map { "Access until \($0)" } ?? "Perpetual"
    }

    static func appPlan(_ row: Record) -> String {
        "\(row.string("app_name") ?? "—") · \(row.string("plan_name") ?? "customer’s plan")"
    }
}

private struct BillingLicencesList: View {
    let api: BillingAPI
    @Environment(SessionStore.self) private var session
    @State private var source: BillingListSource
    @State private var model: PagedListModel<Record>
    @State private var apps: [BillingAppInfo] = []
    @State private var appFilter = ""
    @State private var statusFilter = ""
    @State private var issuing = false
    @State private var pendingReveal: RevealedSecret?
    @State private var revealed: RevealedSecret?
    @State private var feedback: Feedback = .none

    init(api: BillingAPI) {
        self.api = api
        let source = BillingListSource(api: api, path: "/api/v2/licenses")
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in try await source.fetch(search: search, page: page) })
    }

    var body: some View {
        PagedList(model: model, emptyTitle: "No licences yet", emptySystemImage: "key",
                  emptyDescription: "A licence is a key a customer types into desktop or self-hosted software. Keys are issued when a licensed app is sold, or by hand here.",
                  emptyActionTitle: "Issue a licence",
                  emptyAction: session.permissions.can(.create, moduleName: BillingModule.licences)
                      && appFilter.isEmpty && statusFilter.isEmpty ? { issuing = true } : nil,
                  destination: { row in
                BillingLicenceDetail(uuid: row.id, seed: row) { message in
                    feedback = .done(message)
                    Task { await model.load() }
                }
            }) { row in
            BillingLicenceRow(row: row)
            .accessibilityIdentifier("billing.licence.\(row.id)")
        }
        .navigationTitle("Licences")
        .safeAreaInset(edge: .top, spacing: 0) { FeedbackBar(feedback: feedback) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !apps.isEmpty {
                        Picker("App", selection: Binding(get: { appFilter }, set: { value in
                            appFilter = value
                            source.query["app"] = value.isEmpty ? nil : value
                            Task { await model.load() }
                        })) {
                            Text("Every app").tag("")
                            ForEach(apps) { Text($0.name).tag($0.uuid) }
                        }
                    }
                    Picker("Status", selection: Binding(get: { statusFilter }, set: { value in
                        statusFilter = value
                        source.query["status"] = value.isEmpty ? nil : value
                        Task { await model.load() }
                    })) {
                        Text("Any status").tag("")
                        Text("Active").tag("active")
                        Text("Suspended").tag("suspended")
                        Text("Expired").tag("expired")
                        Text("Revoked").tag("revoked")
                    }
                } label: {
                    Label("Filter", systemImage: appFilter.isEmpty && statusFilter.isEmpty
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("billing.licences.filter")
            }
            if session.permissions.can(.create, moduleName: BillingModule.licences) {
                ToolbarItem(placement: .primaryAction) {
                    Button { issuing = true } label: { Label("Issue a licence", systemImage: "plus") }
                        .accessibilityIdentifier("billing.licences.issue")
                }
            }
        }
        .task { if apps.isEmpty { apps = (try? await api.apps()) ?? [] } }
        .sheet(isPresented: $issuing, onDismiss: {
            if let pending = pendingReveal { revealed = pending; pendingReveal = nil }
        }) {
            NavigationStack {
                BillingIssueLicenceForm(apps: apps) { key in
                    feedback = .done("Licence issued.")
                    pendingReveal = RevealedSecret(
                        title: "Licence key", value: key,
                        message: "Copy the key now and send it to the customer. It won’t be shown again.")
                    Task { await model.load() }
                }
            }
        }
        .revealOnce($revealed)
    }
}

private struct BillingLicenceRow: View {
    let row: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(BillingLicenceText.key(row)).font(.wsHeadline.monospaced())
                Text(row.string("customer_email") ?? "A customer").font(.wsSubheadline)
                Text(BillingLicenceText.appPlan(row)).font(.wsFootnote).foregroundStyle(.secondaryText)
                Text("\(BillingLicenceText.devices(row)) · \(BillingLicenceText.access(row))")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            BillingStatus.badge(row.string("status") ?? "active")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One licence: who has it, its limits, the devices using it, and what can be done with it.
private struct BillingLicenceDetail: View {
    let uuid: String
    let seed: Record
    let onChange: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var licence: Record?
    @State private var loadError: APIError?
    @State private var feedback: Feedback = .none
    @State private var busy = false
    @State private var confirmingRevoke = false
    @State private var freeing: Record?
    @State private var editingLimits = false
    @State private var revealed: RevealedSecret?

    private var current: Record { licence ?? seed }
    private var status: String { current.string("status") ?? "active" }
    private var canUpdate: Bool { session.permissions.can(.update, moduleName: BillingModule.licences) && status != "revoked" }
    private var canFree: Bool { session.permissions.can(.delete, moduleName: BillingModule.licences) && status != "revoked" }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            Section {
                HStack {
                    Text(BillingLicenceText.key(current)).font(.wsTitle3.monospaced().bold())
                    Spacer()
                    BillingStatus.badge(status)
                }
                BillingLine(label: "Customer", value: current.string("customer_email"))
                BillingLine(label: "App user id", value: current.string("customer_external_id"))
                BillingLine(label: "App and plan", value: BillingLicenceText.appPlan(current))
                BillingLine(label: "Devices", value: BillingLicenceText.devices(current))
                BillingLine(label: "Access", value: BillingDay.text(current, "access_until").map { "Until \($0)" } ?? "Perpetual")
                BillingLine(label: "Updates", value: BillingDay.text(current, "updates_until").map { "Until \($0)" } ?? "All future versions")
                BillingLine(label: "Came from", value: BillingSource.label(current.string("source")))
                BillingLine(label: "Key last changed", value: BillingDay.text(current, "key_rotated_at"))
                BillingLine(label: "Revoked", value: BillingDay.text(current, "revoked_at"))
                BillingLine(label: "Issued", value: BillingDay.text(current, "created_at"))
            }
            devices
            if canUpdate {
                Section {
                    if status == "active" {
                        actionButton("Suspend", "pause.circle", "Licence suspended. It stops working at the next check-in.") {
                            try await update(["status": .string("suspended")])
                        }
                    } else {
                        actionButton(status == "expired" ? "Resume (remove expiry)" : "Resume", "play.circle", "Licence resumed.") {
                            var body: [String: JSONValue] = ["status": .string("active")]
                            if status == "expired" { body["access_until"] = .null }
                            try await update(body)
                        }
                    }
                    Button { editingLimits = true } label: { Label("Change devices and dates", systemImage: "slider.horizontal.3") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("billing.licence.limits")
                    actionButton("Reissue key", "arrow.triangle.2.circlepath", "New key issued; the old one stopped working.") {
                        let json = try await services.workspace().send(.post, "/api/v2/licenses/\(uuid)/reissue")
                        let result = BillingAPI.data(json)
                        if let key = result.string("key") {
                            revealed = RevealedSecret(
                                title: "New licence key", value: key,
                                message: "Copy the new key now and send it to the customer. It won’t be shown again. Their devices stay activated.")
                        }
                    }
                    Button(role: .destructive) { confirmingRevoke = true } label: { Label("Revoke", systemImage: "xmark.octagon") }
                        .frame(minHeight: 44)
                        .disabled(busy)
                        .accessibilityIdentifier("billing.licence.revoke")
                }
            }
        }
        .wsDetailList()
        .navigationTitle("Licence")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .wsRefreshable { await load() }
        .revealOnce($revealed)
        .sheet(isPresented: $editingLimits) {
            NavigationStack {
                BillingLicenceLimitsForm(licence: current) { body in
                    try await update(body)
                    feedback = .done("Licence limits saved.")
                    onChange("Licence limits saved.")
                }
            }
        }
        .confirmationDialog("Revoke this licence?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                Task {
                    await run("Licence revoked.") {
                        try await services.workspace().send(.post, "/api/v2/licenses/\(uuid)/revoke")
                    }
                }
            }
        } message: {
            Text("It stops working on every device at the next check-in. This can’t be undone; issue a new licence if needed.")
        }
        .confirmationDialog("Free this seat?", isPresented: Binding(
            get: { freeing != nil }, set: { if !$0 { freeing = nil } }), titleVisibility: .visible) {
            if let device = freeing {
                Button("Free seat", role: .destructive) {
                    Task {
                        await run("Seat freed.") {
                            try await services.workspace().send(.delete, "/api/v2/licenses/\(uuid)/activations/\(device.id)")
                        }
                    }
                }
            }
        } message: {
            Text("That device stops using the licence, so another device can use it.")
        }
    }

    @ViewBuilder
    private var devices: some View {
        let live = current.records("activations", idKeys: ["uuid"]).filter { $0.string("deactivated_at") == nil }
        Section {
            if licence == nil && loadError == nil {
                ProgressView()
            } else if live.isEmpty {
                Text("No device is using this licence yet.").foregroundStyle(.secondaryText)
            }
            ForEach(live) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.string("name") ?? "Unnamed device").font(.wsBody)
                        Text([device.string("platform"), device.string("app_version").map { "v\($0)" },
                              Formatters.relative(device.date("last_seen_at")).map { "seen \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                        if let first = BillingDay.text(device, "first_seen_at") {
                            Text("First used \(first)").font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    Spacer()
                    if canFree {
                        Button("Free seat") { freeing = device }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                            .accessibilityIdentifier("billing.licence.free.\(device.id)")
                    }
                }
                .accessibilityElement(children: .contain)
            }
        } header: {
            Text("Devices")
        }
    }

    private func actionButton(_ title: String, _ image: String, _ done: String,
                              _ work: @escaping @MainActor () async throws -> Void) -> some View {
        Button { Task { await run(done, work) } } label: { Label(title, systemImage: image) }
            .frame(minHeight: 44)
            .disabled(busy)
            .accessibilityIdentifier("billing.licence.\(title.lowercased().replacingOccurrences(of: " ", with: "_"))")
    }

    private func update(_ body: [String: JSONValue]) async throws {
        try await services.workspace().send(.put, "/api/v2/licenses/\(uuid)", body: .object(body))
    }

    private func run(_ done: String, _ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        if await perform($feedback, done: done, work) {
            onChange(done)
            await load()
        }
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/licenses/\(uuid)")
            licence = WorkspaceAPI.record(json, idKeys: ["uuid"])
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }
}

/// How many devices a licence allows and until when it gives access and updates.
private struct BillingLicenceLimitsForm: View {
    let licence: Record
    let save: ([String: JSONValue]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var devices = ""
    @State private var accessUntil: Date?
    @State private var updatesUntil: Date?
    @State private var prepared = false
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var saving = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                LabeledContent("Devices") {
                    TextField("Unlimited", text: $devices).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("billing.licence.devices")
                }
                BillingOptionalDay(label: "Access until", date: $accessUntil, help: "Blank: perpetual.")
                BillingOptionalDay(label: "Updates until", date: $updatesUntil, help: "Blank: every future version.")
            } footer: {
                Text("Leave devices blank for unlimited.")
            }
        }
        .navigationTitle("Devices and dates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await submit() } }.disabled(saving)
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            devices = licence.int("max_activations").map(String.init) ?? ""
            accessUntil = licence.string("access_until").flatMap { CalendarDay(string: $0)?.date() }
            updatesUntil = licence.string("updates_until").flatMap { CalendarDay(string: $0)?.date() }
        }
    }

    private func submit() async {
        let body = BillingLicenceLimits.body(devices: devices, accessUntil: accessUntil, updatesUntil: updatesUntil)
        guard let body else { problem = "Devices must be a whole number of 1 or more, or blank."; return }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            try await save(body)
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

enum BillingLicenceLimits {
    /// `{max_activations, access_until, updates_until}`: blank devices = unlimited (null), no date = null.
    /// nil when the devices number isn't valid.
    static func body(devices: String, accessUntil: Date?, updatesUntil: Date?) -> [String: JSONValue]? {
        var body: [String: JSONValue] = [
            "access_until": accessUntil.map { .string(BillingDay.end($0)) } ?? .null,
            "updates_until": updatesUntil.map { .string(BillingDay.end($0)) } ?? .null,
        ]
        if let text = devices.trimmedOrNil {
            guard let count = Int(text), count >= 1 else { return nil }
            body["max_activations"] = .number(Double(count))
        } else {
            body["max_activations"] = .null
        }
        return body
    }
}

/// Issue a licence by hand: the key is shown once.
private struct BillingIssueLicenceForm: View {
    let apps: [BillingAppInfo]
    let onIssued: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var app = ""
    @State private var customer = ""
    @State private var customerName = ""
    @State private var plans: [BillingPlanInfo] = []
    @State private var plan = ""
    @State private var devices = "1"
    @State private var accessUntil: Date?
    @State private var updatesUntil: Date?
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var saving = false

    /// Licences are for desktop and self-hosted apps; every app is offered if there are none.
    private var licensable: [BillingAppInfo] {
        let filtered = apps.filter(\.usesLicences)
        return filtered.isEmpty ? apps : filtered
    }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                BillingAppPicker(apps: licensable, selection: $app)
                BillingCustomerField(uuid: $customer, name: $customerName)
                BillingPlanPicker(plans: plans, selection: $plan, noneLabel: "The customer’s own plan")
                    .disabled(app.isEmpty)
            } footer: {
                Text("Without a plan the licence follows the customer’s own plan and grants.")
            }
            Section {
                LabeledContent("Devices") {
                    TextField("Unlimited", text: $devices).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                BillingOptionalDay(label: "Access until", date: $accessUntil, help: "Blank: perpetual.")
                BillingOptionalDay(label: "Updates until", date: $updatesUntil, help: "Blank: every future version.")
            } footer: {
                Text("Leave devices blank for unlimited.")
            }
        }
        .navigationTitle("Issue a licence")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Issue") { Task { await issue() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.licence.issueSave")
            }
        }
        .onAppear { if app.isEmpty, licensable.count == 1 { app = licensable[0].uuid } }
        .task(id: app) {
            plan = ""
            guard !app.isEmpty else { plans = []; return }
            plans = ((try? await services.billing.plans(app: app)) ?? []).filter(\.active)
        }
    }

    private func issue() async {
        guard !app.isEmpty, !customer.isEmpty else { problem = "Choose the app and the customer."; return }
        guard var body = BillingLicenceLimits.body(devices: devices, accessUntil: accessUntil, updatesUntil: updatesUntil) else {
            problem = "Devices must be a whole number of 1 or more, or blank."
            return
        }
        // A new licence leaves out dates that aren't set (the server reads null as "not set" either way).
        if accessUntil == nil { body["access_until"] = nil }
        if updatesUntil == nil { body["updates_until"] = nil }
        body["app"] = .string(app)
        body["customer"] = .string(customer)
        if !plan.isEmpty { body["plan"] = .string(plan) }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/licenses", body: .object(body))
            let result = BillingAPI.data(json)
            guard let key = result.string("key") else {
                feedback = .failed(ResourceService.problem(500, "The licence was made but its key didn’t come back. Reissue the key from the licence."))
                return
            }
            onIssued(key)
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}
