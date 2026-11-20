import SwiftUI

/// Billing (`/dashboard/billing`): the apps the workspace sells and the billing sections the person
/// can read (Subscriptions, Licences, Coupons, Payments).
struct BillingHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var apps: LoadState<[BillingAppInfo]> = .idle
    @State private var creating = false
    @State private var opened: BillingAppInfo?

    private var permissions: PermissionSet { session.permissions }
    private var canReadApps: Bool { permissions.can(.read, moduleName: BillingModule.billing) }

    var body: some View {
        List {
            Section {
                Text("Sell your own apps: plans, subscriptions, licence keys and coupons. Customers pay on the app’s own pages; nothing is paid in this app.")
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
            }
            sectionsList
            if canReadApps { appsSection }
            if !canReadApps && !permissions.can(.read, moduleName: BillingModule.subscriptions)
                && !permissions.can(.read, moduleName: BillingModule.licences) {
                Section {
                    Text("Your role can’t see billing in this workspace. Ask the workspace owner for access.")
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .navigationTitle("Billing")
        .toolbar {
            if permissions.can(.create, moduleName: BillingModule.billing) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New app", systemImage: "plus") }
                        .accessibilityIdentifier("billing.newApp")
                }
            }
        }
        .task { if case .idle = apps { await load() } }
        .refreshable { await load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BillingNewAppView { app in
                    opened = app
                    Task { await load() }
                }
            }
        }
        .navigationDestination(item: $opened) { app in BillingAppView(uuid: app.uuid, name: app.name) }
    }

    @ViewBuilder
    private var sectionsList: some View {
        Section("Billing") {
            if permissions.can(.read, moduleName: BillingModule.subscriptions) {
                NavigationLink(value: NativeScreenRoute(WorkspaceScreen.subscriptions)) {
                    Label("Subscriptions and sales", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("billing.link.subscriptions")
            }
            if permissions.can(.read, moduleName: BillingModule.licences) {
                NavigationLink(value: NativeScreenRoute(WorkspaceScreen.licences)) {
                    Label("Licences", systemImage: "key")
                }
                .accessibilityIdentifier("billing.link.licences")
            }
            if canReadApps {
                NavigationLink { BillingCouponsView() } label: { Label("Coupons", systemImage: "ticket") }
                    .accessibilityIdentifier("billing.link.coupons")
                NavigationLink { BillingPaymentsView() } label: { Label("Payments", systemImage: "banknote") }
                    .accessibilityIdentifier("billing.link.payments")
            }
        }
    }

    @ViewBuilder
    private var appsSection: some View {
        Section {
            switch apps {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let list) where list.isEmpty:
                VStack(alignment: .leading, spacing: 6) {
                    Text("No apps yet").font(.wsHeadline)
                    Text("An app is something you sell: a website, a desktop or mobile app, or self-hosted software. Add one, then give it features and plans.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                .padding(.vertical, 4)
            case .loaded(let list):
                ForEach(list) { app in
                    NavigationLink { BillingAppView(uuid: app.uuid, name: app.name) } label: { BillingAppRow(app: app) }
                        .accessibilityIdentifier("billing.app.\(app.uuid)")
                }
            }
        } header: {
            Text("Your apps")
        }
    }

    private func load() async {
        guard canReadApps else { return }
        if apps.value == nil { apps = .loading }
        do {
            apps = .loaded(try await services.billing.apps().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if apps.value == nil { apps = .failed(apiError) }
        }
    }
}

/// An app in the list: its kind, Live/Test, Inactive, slug and what happens offline.
struct BillingAppRow: View {
    let app: BillingAppInfo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconTile(systemImage: icon, color: Palette.tile(for: app.uuid), size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.wsHeadline)
                Text("\(app.kindLabel) · \(app.slug)").font(.wsSubheadline).foregroundStyle(.secondaryText)
                Text(app.offlineLine).font(.wsFootnote).foregroundStyle(.secondaryText)
                HStack(spacing: 6) {
                    StatusBadge(text: app.isLive ? "Live" : "Test", systemImage: app.isLive ? "bolt.fill" : "testtube.2",
                                tone: app.isLive ? .success : .info)
                    if !app.active { StatusBadge(text: "Inactive", systemImage: "pause.circle", tone: .neutral) }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch app.kind {
        case "desktop": "desktopcomputer"
        case "self_hosted": "server.rack"
        case "mobile": "iphone"
        default: "globe"
        }
    }
}

/// New app: a name and a kind, then it opens.
struct BillingNewAppView: View {
    let onCreated: (BillingAppInfo) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "web"
    @State private var feedback: Feedback = .none
    @State private var saving = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                TextField("Name (needed)", text: $name)
                    .accessibilityIdentifier("billing.newApp.name")
                Picker("Kind", selection: $kind) {
                    ForEach(BillingAppInfo.kinds) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("billing.newApp.kind")
            } footer: {
                Text("Desktop and self-hosted apps use licence keys. A new app starts in test mode.")
            }
        }
        .navigationTitle("New app")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await create() } }
                    .disabled(saving || name.trimmedOrNil == nil)
                    .accessibilityIdentifier("billing.newApp.save")
            }
        }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/billing/apps",
                                                           body: .object(["name": .string(name.trimmingCharacters(in: .whitespaces)),
                                                                          "kind": .string(kind)]))
            onCreated(BillingAppInfo(BillingAPI.data(json)))
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

// MARK: - Payments (Stripe Connect status)

/// Where customers' payments go: the workspace's own Stripe account. Shown natively; setting it up
/// happens on a Stripe page, which this app never opens.
struct BillingPaymentsView: View {
    @Environment(\.services) private var services
    @State private var state: LoadState<Record> = .idle

    var body: some View {
        List {
            Section {
                Text("Customers pay for your apps on a secure checkout page, paid into your own payment account.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            switch state {
            case .loaded(let status):
                statusSections(status)
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .navigationTitle("Payments")
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func statusSections(_ s: Record) -> some View {
        let connected = s.bool("connected") ?? false
        let ready = s.bool("charges_enabled") ?? false
        Section {
            HStack {
                if ready {
                    StatusBadge(text: "Taking payments", systemImage: "checkmark.circle.fill", tone: .success)
                } else if connected {
                    StatusBadge(text: "Setup not finished", systemImage: "exclamationmark.triangle", tone: .warning)
                } else {
                    StatusBadge(text: "Not connected", systemImage: "xmark.circle", tone: .neutral)
                }
                if s.string("mode") == "test" {
                    StatusBadge(text: "Test mode", systemImage: "testtube.2", tone: .info)
                }
            }
            .accessibilityIdentifier("billing.payments.status")
            if let fee = s.decimal("platform_fee_percent"), fee > 0 {
                Text("A \(fee.formatted())% platform fee is taken from each payment.")
                    .font(.wsSubheadline)
            }
            BillingLine(label: "Last checked", value: Formatters.dateTime(s.date("updated_at")))
        }
        if connected {
            Section("Setup") {
                step(true, "Account created" + (s.string("account").map { " (\($0))" } ?? ""))
                step(s.bool("details_submitted") ?? false, "Business details sent")
                step(ready, "Can take payments")
                step(s.bool("payouts_enabled") ?? false, "Payouts to your bank")
            }
        }
        if !ready {
            Section {
                Label("Payments are set up on our website.", systemImage: "info.circle")
                    .font(.wsSubheadline)
                    .accessibilityIdentifier("billing.payments.website")
            }
        }
    }

    private func step(_ done: Bool, _ text: String) -> some View {
        Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? Tone.success.textColor : Color.secondaryText)
            .accessibilityValue(done ? "Done" : "Not done yet")
    }

    private func load() async {
        do {
            let json = try await services.workspace().get("/api/v2/billing/connect")
            state = .loaded(BillingAPI.data(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

// MARK: - Coupons

/// Coupons (`/dashboard/billing/coupons`): percent or amount off, for every app or one app's plans.
struct BillingCouponsView: View {
    @Environment(\.services) private var services

    var body: some View {
        BillingCouponsList(api: services.billing)
    }
}

/// Fetches pages of a billing list; the filters chosen on screen are read at fetch time.
@MainActor
final class BillingListSource {
    let api: BillingAPI
    let path: String
    var query: [String: String?] = [:]
    var searchParam: String?

    init(api: BillingAPI, path: String, searchParam: String? = nil) {
        self.api = api
        self.path = path
        self.searchParam = searchParam
    }

    func fetch(search: String, page: Int) async throws -> Page<Record> {
        var full = query
        if let searchParam, let text = search.trimmedOrNil { full[searchParam] = text }
        return try await api.page(path, query: full, page: page)
    }
}

private struct BillingCouponsList: View {
    let api: BillingAPI
    @Environment(SessionStore.self) private var session
    @State private var source: BillingListSource
    @State private var model: PagedListModel<Record>
    @State private var apps: [BillingAppInfo] = []
    @State private var appFilter = ""
    @State private var creating = false
    @State private var feedback: Feedback = .none

    init(api: BillingAPI) {
        self.api = api
        let source = BillingListSource(api: api, path: "/api/v2/billing/coupons", searchParam: "search")
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in try await source.fetch(search: search, page: page) })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search codes", emptyTitle: "No coupons yet",
                  emptySystemImage: "ticket",
                  emptyDescription: "A coupon takes a percentage or an amount off. Customers type its code when they buy.") { coupon in
            NavigationLink {
                BillingCouponDetailView(coupon: coupon, apps: apps) { Task { await model.load() } }
            } label: {
                BillingCouponRow(coupon: coupon)
            }
            .accessibilityIdentifier("billing.coupon.\(coupon.id)")
        }
        .navigationTitle("Coupons")
        .safeAreaInset(edge: .top, spacing: 0) { FeedbackBar(feedback: feedback) }
        .toolbar {
            if !apps.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("App", selection: Binding(get: { appFilter }, set: { value in
                            appFilter = value
                            source.query["app"] = value.isEmpty ? nil : value
                            Task { await model.load() }
                        })) {
                            Text("Every app").tag("")
                            ForEach(apps) { Text($0.name).tag($0.uuid) }
                        }
                    } label: {
                        Label("Filter", systemImage: appFilter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                         : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("billing.coupons.filter")
                }
            }
            if session.permissions.can(.create, moduleName: BillingModule.billing) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New coupon", systemImage: "plus") }
                        .accessibilityIdentifier("billing.coupons.new")
                }
            }
        }
        .task { apps = (try? await api.apps()) ?? [] }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BillingCouponForm(coupon: nil, apps: apps) {
                    feedback = .done("Coupon created.")
                    Task { await model.load() }
                }
            }
        }
    }
}

private struct BillingCouponRow: View {
    let coupon: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(coupon.string("code") ?? "—").font(.wsHeadline.monospaced())
                if let name = coupon.string("name") { Text(name).font(.wsSubheadline) }
                Text(BillingCouponText.discount(coupon)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                Text("\(BillingCouponText.appliesTo(coupon)) · \(BillingCouponText.used(coupon))")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                Text("Valid \(BillingCouponText.valid(coupon))").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            let active = coupon.bool("active") ?? true
            StatusBadge(text: active ? "Active" : "Off", systemImage: active ? "checkmark.circle" : "pause.circle",
                        tone: active ? .success : .neutral)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One coupon: what it gives, who it's for, its limits, who used it; edit and delete.
struct BillingCouponDetailView: View {
    @State var coupon: Record
    let apps: [BillingAppInfo]
    let onChange: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var redemptions: LoadState<[Record]> = .idle
    @State private var editing = false
    @State private var feedback: Feedback = .none

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(coupon.string("code") ?? "—").font(.wsTitle3.monospaced().bold())
                    Text(BillingCouponText.discount(coupon)).font(.wsSubheadline)
                }
                BillingLine(label: "Name", value: coupon.string("name"))
                BillingLine(label: "For", value: BillingCouponText.appliesTo(coupon))
                BillingLine(label: "Used", value: BillingCouponText.used(coupon))
                BillingLine(label: "Per customer", value: coupon.int("per_customer_limit").map { "\($0) time\($0 == 1 ? "" : "s")" } ?? "No limit")
                BillingLine(label: "Valid", value: BillingCouponText.valid(coupon))
                BillingLine(label: "Status", value: (coupon.bool("active") ?? true) ? "Active" : "Off")
            }
            Section("Who used it") {
                switch redemptions {
                case .loaded(let rows) where rows.isEmpty:
                    Text("Nobody has used this coupon yet.").foregroundStyle(.secondaryText)
                case .loaded(let rows):
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.string("customer_email") ?? "A customer").font(.wsBody)
                            Text("\(BillingMoney.text(row.int("amount_off"), row.string("currency"))) off · \(BillingDay.text(row, "redeemed_at") ?? "")")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                case .failed(let error):
                    InlineErrorRow(error: error)
                default:
                    ProgressView()
                }
            }
            if session.permissions.can(.delete, moduleName: BillingModule.billing) {
                Section {
                    DeleteButton(title: "Delete coupon",
                                 message: "Customers can no longer use this code. Past discounts are kept.") {
                        do {
                            try await services.workspace().send(.delete, "/api/v2/billing/coupons/\(coupon.id)")
                            onChange()
                            dismiss()
                            return true
                        } catch {
                            feedback = .failed(error.asAPIError)
                            return false
                        }
                    }
                }
            }
        }
        .navigationTitle("Coupon")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.permissions.can(.update, moduleName: BillingModule.billing) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("billing.coupon.edit")
                }
            }
        }
        .task { await loadRedemptions() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                BillingCouponForm(coupon: coupon, apps: apps) {
                    feedback = .done("Coupon saved.")
                    onChange()
                    Task { await reload() }
                }
            }
        }
    }

    private func reload() async {
        if let json = try? await services.workspace().get("/api/v2/billing/coupons/\(coupon.id)"),
           let fresh = WorkspaceAPI.record(json, idKeys: ["uuid"]) {
            coupon = fresh
        }
    }

    private func loadRedemptions() async {
        do {
            let json = try await services.workspace().get("/api/v2/billing/coupons/\(coupon.id)/redemptions",
                                                          query: ["page": "1", "per_page": "100"])
            redemptions = .loaded(WorkspaceAPI.records(json, idKeys: ["uuid"]))
        } catch {
            redemptions = .failed(error.asAPIError)
        }
    }
}

/// Create or edit a coupon. Once used, its discount can't change; its code and app never can.
struct BillingCouponForm: View {
    let coupon: Record?
    let apps: [BillingAppInfo]
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BillingCouponDraft()
    @State private var plans: [BillingPlanInfo] = []
    @State private var feedback: Feedback = .none
    @State private var problem: String?
    @State private var saving = false
    @State private var prepared = false

    private var isNew: Bool { coupon == nil }
    private var used: Bool { (coupon?.int("redemptions_count") ?? 0) > 0 }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("Code (needed), e.g. LAUNCH25", text: Binding(get: { draft.code }, set: { draft.code = $0.uppercased() }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .disabled(!isNew)
                    .accessibilityIdentifier("billing.coupon.code")
                TextField("Name (optional), e.g. Launch offer", text: $draft.name)
                if isNew {
                    BillingAppPicker(apps: apps, selection: $draft.app, allowsNone: true)
                } else {
                    LabeledContent("App", value: coupon?.string("app_name") ?? "Every app")
                }
            } footer: {
                if !isNew { Text("A coupon’s code and app can’t change.") }
            }
            if !draft.app.isEmpty && !plans.isEmpty {
                Section {
                    ForEach(plans) { plan in
                        Toggle(plan.name, isOn: Binding(
                            get: { draft.plans.contains(plan.uuid) },
                            set: { on in if on { draft.plans.insert(plan.uuid) } else { draft.plans.remove(plan.uuid) } }))
                    }
                } header: {
                    Text("Only for these plans")
                } footer: {
                    Text("Tick none to allow every plan of the app.")
                }
            }
            Section {
                Picker("Discount", selection: $draft.discountType) {
                    Text("Percent off").tag("percent")
                    Text("Amount off").tag("amount")
                }
                LabeledContent(draft.discountType == "percent" ? "Percent" : "Amount") {
                    TextField(draft.discountType == "percent" ? "25" : "10.00", text: $draft.value)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("billing.coupon.value")
                }
                if draft.discountType == "amount" {
                    Picker("Currency", selection: $draft.currency) {
                        ForEach(BillingMoney.currencies, id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                }
                Picker("Applies to", selection: $draft.duration) {
                    Text("First payment").tag("once")
                    Text("For some months").tag("repeating")
                    Text("Every payment").tag("forever")
                }
                if draft.duration == "repeating" {
                    LabeledContent("Months") {
                        TextField("3", text: $draft.months).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Discount")
            } footer: {
                if used { Text("This coupon has been used, so its discount can’t change.") }
                else { Text("Months and every payment only matter for subscriptions.") }
            }
            .disabled(used)
            Section("Limits") {
                LabeledContent("Uses in total") {
                    TextField("No limit", text: $draft.maxUses).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                LabeledContent("Uses per customer") {
                    TextField("No limit", text: $draft.perCustomer).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                BillingOptionalDay(label: "Starts", date: $draft.starts, help: "Blank: from now.")
                BillingOptionalDay(label: "Ends", date: $draft.expires, help: "Blank: no end.")
                Toggle("Active", isOn: $draft.active)
            }
        }
        .navigationTitle(isNew ? "New coupon" : "Edit \(coupon?.string("code") ?? "coupon")")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.coupon.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            if let coupon { draft = BillingCouponDraft(coupon: coupon) }
        }
        .task(id: draft.app) {
            guard !draft.app.isEmpty else { plans = []; return }
            plans = ((try? await services.billing.plans(app: draft.app)) ?? []).filter(\.active)
        }
    }

    private func save() async {
        problem = draft.problem(isNew: isNew, used: used)
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let body = draft.body(isNew: isNew, used: used)
            if let coupon {
                try await services.workspace().send(.put, "/api/v2/billing/coupons/\(coupon.id)", body: body)
            } else {
                try await services.workspace().send(.post, "/api/v2/billing/coupons", body: body)
            }
            onSaved()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}
