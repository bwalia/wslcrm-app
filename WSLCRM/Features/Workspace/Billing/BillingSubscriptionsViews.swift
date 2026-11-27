import SwiftUI

/// Subscriptions and sales (`/dashboard/billing/subscriptions`): subscriptions, one-off purchases,
/// granted access and the history of plan changes, with recording a sale, moving a customer to
/// another plan and granting access. RBAC module `subscriptions`.
struct BillingSubscriptionsView: View {
    @Environment(\.services) private var services

    var body: some View {
        BillingSubscriptionsContent(api: services.billing)
    }
}

/// Words for where a subscription or purchase came from.
enum BillingSource {
    static let labels: [String: String] = [
        "stripe": "Card", "manual": "Recorded by hand", "app_store": "App Store", "play_store": "Google Play",
        "wise": "Bank transfer", "external": "Elsewhere",
    ]

    static func label(_ value: String?) -> String? {
        value.map { labels[$0] ?? Formatters.humanize($0) }
    }
}

private enum BillingSalesTab: String, CaseIterable, Identifiable, Hashable {
    case subscriptions, purchases, grants, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subscriptions: "Subscriptions"
        case .purchases: "Purchases"
        case .grants: "Grants"
        case .history: "History"
        }
    }
}

private enum BillingSalesSheet: String, Identifiable {
    case sale, upgrade, grant
    var id: String { rawValue }
}

private struct BillingSubscriptionsContent: View {
    let api: BillingAPI
    @Environment(SessionStore.self) private var session
    @State private var tab: BillingSalesTab = .subscriptions
    @State private var apps: [BillingAppInfo] = []
    @State private var appFilter = ""
    @State private var statusFilter = ""
    @State private var purchaseStatus = ""
    @State private var purchaseSource = ""
    @State private var kindFilter = ""
    @State private var showRevoked = false
    @State private var sources: [BillingSalesTab: BillingListSource]
    @State private var models: [BillingSalesTab: PagedListModel<Record>]
    @State private var sheet: BillingSalesSheet?
    @State private var pendingReveal: RevealedSecret?
    @State private var revealed: RevealedSecret?
    @State private var feedback: Feedback = .none

    init(api: BillingAPI) {
        self.api = api
        let paths: [BillingSalesTab: String] = [
            .subscriptions: "/api/v2/subscriptions", .purchases: "/api/v2/subscriptions/purchases",
            .grants: "/api/v2/subscriptions/grants", .history: "/api/v2/subscriptions/plan-changes",
        ]
        var sources: [BillingSalesTab: BillingListSource] = [:]
        var models: [BillingSalesTab: PagedListModel<Record>] = [:]
        for (tab, path) in paths {
            let source = BillingListSource(api: api, path: path)
            sources[tab] = source
            models[tab] = PagedListModel { search, page in try await source.fetch(search: search, page: page) }
        }
        _sources = State(initialValue: sources)
        _models = State(initialValue: models)
    }

    private var permissions: PermissionSet { session.permissions }
    private var canCreate: Bool { permissions.can(.create, moduleName: BillingModule.subscriptions) }

    var body: some View {
        list(for: tab)
            .id(tab)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    SectionTabs(tabs: BillingSalesTab.allCases, selection: $tab) { $0.title }
                    FeedbackBar(feedback: feedback)
                }
            }
            .navigationTitle("Subscriptions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                if canCreate {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { sheet = .sale } label: { Label("Record a sale", systemImage: "cart.badge.plus") }
                                .accessibilityIdentifier("billing.sales.recordSale")
                            if permissions.can(.update, moduleName: BillingModule.subscriptions) {
                                Button { sheet = .upgrade } label: { Label("Move a customer to another plan", systemImage: "arrow.up.circle") }
                                    .accessibilityIdentifier("billing.sales.upgrade")
                            }
                            Button { sheet = .grant } label: { Label("Grant access", systemImage: "gift") }
                                .accessibilityIdentifier("billing.sales.grant")
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .accessibilityIdentifier("billing.sales.add")
                    }
                }
            }
            .task { if apps.isEmpty { apps = (try? await api.apps()) ?? [] } }
            .sheet(item: $sheet, onDismiss: {
                if let pending = pendingReveal { revealed = pending; pendingReveal = nil }
            }) { which in
                NavigationStack {
                    switch which {
                    case .sale:
                        BillingSaleForm(apps: apps) { message, key in finished(message, key: key, reload: [.purchases, .subscriptions, .history]) }
                    case .upgrade:
                        BillingMoveCustomerForm(apps: apps) { message, key in finished(message, key: key, reload: [.subscriptions, .purchases, .history]) }
                    case .grant:
                        BillingGrantForm(apps: apps) { message in finished(message, key: nil, reload: [.grants]) }
                    }
                }
            }
            .revealOnce($revealed)
    }

    @ViewBuilder
    private func list(for tab: BillingSalesTab) -> some View {
        if let model = models[tab] {
            switch tab {
            case .subscriptions:
                PagedList(model: model, emptyTitle: "No subscriptions", emptySystemImage: "arrow.triangle.2.circlepath",
                          emptyDescription: "Customers who pay every month or year appear here.",
                          emptyActionTitle: "Record a sale", emptyAction: canCreate && appFilter.isEmpty ? { sheet = .sale } : nil,
                          destination: { row in
 BillingSubscriptionDetail(subscription: row)
                    }) { row in
 BillingSubscriptionRow(row: row)
                        .accessibilityIdentifier("billing.subscription.\(row.id)")
                }
            case .purchases:
                PagedList(model: model, emptyTitle: "No purchases", emptySystemImage: "bag",
                          emptyDescription: "One-off and fixed-term sales appear here, paid online or recorded by hand.",
                          emptyActionTitle: "Record a sale", emptyAction: canCreate && appFilter.isEmpty ? { sheet = .sale } : nil,
                          destination: { row in
                        BillingPurchaseDetail(purchase: row) { message in finished(message, key: nil, reload: [.purchases, .history]) }
                    }) { row in
                    BillingPurchaseRow(row: row)
                    .accessibilityIdentifier("billing.purchase.\(row.id)")
                }
            case .grants:
                PagedList(model: model, emptyTitle: "No access granted", emptySystemImage: "gift",
                          emptyDescription: "Access you give a customer without a sale (a partner, a trial, a refund) appears here.",
                          emptyActionTitle: "Grant access", emptyAction: canCreate && appFilter.isEmpty ? { sheet = .grant } : nil,
                          destination: { row in
                        BillingGrantDetail(grant: row) { message in finished(message, key: nil, reload: [.grants]) }
                    }) { row in
                    BillingGrantRow(row: row)
                    .accessibilityIdentifier("billing.grant.\(row.id)")
                }
            case .history:
                PagedList(model: model, emptyTitle: "No changes yet", emptySystemImage: "clock.arrow.circlepath",
                          emptyDescription: "Every new sale, upgrade, downgrade, renewal and cancellation is recorded here.") { row in
                    BillingHistoryRow(row: row)
                }
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            if !apps.isEmpty {
                Picker("App", selection: Binding(get: { appFilter }, set: { value in
                    appFilter = value
                    for source in sources.values { source.query["app"] = value.isEmpty ? nil : value }
                    reloadAll()
                })) {
                    Text("Every app").tag("")
                    ForEach(apps) { Text($0.name).tag($0.uuid) }
                }
            }
            switch tab {
            case .subscriptions:
                Picker("Status", selection: filter($statusFilter, tab: .subscriptions, param: "status")) {
                    Text("Any status").tag("")
                    Text("Active").tag("active")
                    Text("On trial").tag("trialing")
                    Text("Payment late").tag("past_due")
                    Text("Cancelled").tag("canceled")
                }
            case .purchases:
                Picker("Status", selection: filter($purchaseStatus, tab: .purchases, param: "status")) {
                    Text("Any status").tag("")
                    Text("Active").tag("active")
                    Text("Refunded").tag("refunded")
                    Text("Revoked").tag("revoked")
                }
                Picker("Paid by", selection: filter($purchaseSource, tab: .purchases, param: "source")) {
                    Text("Any way").tag("")
                    ForEach(["stripe", "manual", "app_store", "play_store", "external"], id: \.self) {
                        Text(BillingSource.label($0) ?? $0).tag($0)
                    }
                }
            case .grants:
                Toggle("Show revoked", isOn: Binding(get: { showRevoked }, set: { on in
                    showRevoked = on
                    sources[.grants]?.query["include_revoked"] = on ? "true" : nil
                    Task { await models[.grants]?.load() }
                }))
            case .history:
                Picker("Change", selection: filter($kindFilter, tab: .history, param: "kind")) {
                    Text("Every change").tag("")
                    ForEach(["new", "upgrade", "downgrade", "renewal", "cancel"], id: \.self) {
                        Text(BillingStatus.style.label(for: $0)).tag($0)
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("billing.sales.filter")
    }

    private func filter(_ state: Binding<String>, tab: BillingSalesTab, param: String) -> Binding<String> {
        Binding(get: { state.wrappedValue }, set: { value in
            state.wrappedValue = value
            sources[tab]?.query[param] = value.isEmpty ? nil : value
            Task { await models[tab]?.load() }
        })
    }

    private func reloadAll() {
        for model in models.values { Task { await model.load() } }
    }

    private func finished(_ message: String, key: String?, reload tabs: [BillingSalesTab]) {
        feedback = .done(message)
        if let key {
            pendingReveal = RevealedSecret(
                title: "Licence key", value: key,
                message: "A licence key was issued. Copy it now and send it to the customer. It won’t be shown again.")
            if sheet == nil { revealed = pendingReveal; pendingReveal = nil }
        }
        for tab in tabs { Task { await models[tab]?.load() } }
    }
}

// MARK: - Rows

private struct BillingCustomerLines: View {
    let row: Record

    var body: some View {
        Text(row.string("customer_email") ?? "A customer").font(.wsHeadline)
        if let external = row.string("customer_external_id") {
            Text("App user id: \(external)").font(.wsCaption).foregroundStyle(.secondaryText)
        }
    }
}

private func appPlan(_ row: Record, fallback: String = "—") -> String {
    [row.string("app_name"), row.string("plan_name") ?? row.string("plan_key")].compactMap { $0 }.joined(separator: " · ")
        .nonEmpty ?? fallback
}

private struct BillingSubscriptionRow: View {
    let row: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                BillingCustomerLines(row: row)
                Text(appPlan(row)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let end = BillingDay.text(row, "current_period_end") {
                    Text((row.bool("cancel_at_period_end") ?? false) ? "Ends \(end)" : "Renews \(end)")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                if let since = BillingDay.text(row, "created_at") {
                    Text("Since \(since)").font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            Spacer()
            BillingStatus.badge(row.string("status") ?? "none")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct BillingPurchaseRow: View {
    let row: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                BillingCustomerLines(row: row)
                Text(appPlan(row)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                Text([row.string("purchase_type") == "fixed_term" ? "Fixed term" : "One-time",
                      BillingSource.label(row.string("source"))].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                Text(BillingPurchaseText.access(row)).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(BillingMoney.text(row.int("amount"), row.string("currency")))
                    .font(.wsSubheadline.monospacedDigit().weight(.semibold))
                BillingStatus.badge(row.string("status") ?? "active")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

enum BillingPurchaseText {
    /// "Access until 1 Jan 2027 · updates to 1 Jan 2026", "Perpetual · all updates".
    static func access(_ row: Record) -> String {
        let access = BillingDay.text(row, "access_until").map { "Access until \($0)" } ?? "Perpetual"
        let updates = BillingDay.text(row, "updates_until").map { "updates to \($0)" } ?? "all updates"
        return "\(access) · \(updates)"
    }

    static func canRefund(_ row: Record) -> Bool {
        row.string("status") == "active" && row.string("source") == "stripe"
            && (row.int("refunded_amount") ?? 0) < (row.int("amount") ?? 0)
    }
}

private struct BillingGrantRow: View {
    let row: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                BillingCustomerLines(row: row)
                Text(appPlan(row, fallback: row.string("app_name") ?? "—")).font(.wsSubheadline).foregroundStyle(.secondaryText)
                let features = BillingGrantText.features(row)
                if !features.isEmpty { Text(features).font(.wsFootnote).foregroundStyle(.secondaryText) }
                if let reason = row.string("reason") { Text(reason).font(.wsFootnote).foregroundStyle(.secondaryText) }
                Text(BillingGrantText.until(row)).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            if row.string("revoked_at") != nil { BillingStatus.badge("revoked") } else { BillingStatus.badge("granted") }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

enum BillingGrantText {
    /// "export: on, seats: 5, storage: unlimited".
    static func features(_ row: Record) -> String {
        BillingFeatureValue.map(row).sorted { $0.key < $1.key }.map { key, value in
            switch value {
            case .included(let on): "\(key): \(on ? "on" : "off")"
            case .limit(let n): "\(key): \(n)"
            case .unlimited: "\(key): unlimited"
            }
        }.joined(separator: ", ")
    }

    static func until(_ row: Record) -> String {
        if row.string("revoked_at") != nil { return "Revoked by hand" }
        return BillingDay.text(row, "expires_at").map { "Until \($0)" } ?? "Until revoked"
    }
}

private struct BillingHistoryRow: View {
    let row: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                BillingStatus.badge(row.string("kind") ?? "new")
                Spacer()
                Text(Formatters.dateTime(row.date("created_at")) ?? "").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Text(row.string("customer_email") ?? "A customer").font(.wsHeadline)
            let from = row.string("from_plan_name")
            let to = row.string("to_plan_name")
            Text([row.string("app_name"), [from, to].compactMap { $0 }.joined(separator: " → ").nonEmpty]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            let amount = row.int("amount") ?? 0
            Text([amount > 0 ? BillingMoney.text(amount, row.string("currency")) : nil,
                  row.string("coupon_code").map { "coupon \($0)" }, BillingSource.label(row.string("source")),
                  row.string("actor")].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let note = row.string("note") { Text(note).font(.wsFootnote) }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Details

/// The customer, with a way to open them when the person can read customers.
private struct BillingCustomerSection: View {
    let row: Record
    @Environment(SessionStore.self) private var session

    var body: some View {
        Section("Customer") {
            BillingLine(label: "Email", value: row.string("customer_email"))
            BillingLine(label: "App user id", value: row.string("customer_external_id"))
            if let uuid = row.string("customer_uuid"), session.permissions.can(.read, moduleName: BillingModule.customers) {
                NavigationLink { CustomerDetailView(customerUuid: uuid) } label: {
                    Label("Open the customer", systemImage: "person.crop.circle")
                }
                .accessibilityIdentifier("billing.openCustomer")
            }
        }
    }
}

/// One subscription and what the customer can use right now.
private struct BillingSubscriptionDetail: View {
    let subscription: Record
    @Environment(\.services) private var services
    @State private var access: LoadState<Record> = .idle

    var body: some View {
        List {
            Section {
                HStack {
                    Text(appPlan(subscription)).font(.wsTitle3.bold())
                    Spacer()
                    BillingStatus.badge(subscription.string("status") ?? "none")
                }
                BillingLine(label: "Paid by", value: BillingSource.label(subscription.string("provider")))
                BillingLine(label: "This period started", value: BillingDay.text(subscription, "current_period_start"))
                BillingLine(label: (subscription.bool("cancel_at_period_end") ?? false) ? "Ends" : "Renews",
                            value: BillingDay.text(subscription, "current_period_end"))
                BillingLine(label: "Trial ends", value: BillingDay.text(subscription, "trial_end"))
                BillingLine(label: "Cancelled", value: BillingDay.text(subscription, "canceled_at"))
                BillingLine(label: "Since", value: BillingDay.text(subscription, "created_at"))
            }
            BillingCustomerSection(row: subscription)
            Section {
                switch access {
                case .loaded(let e):
                    BillingLine(label: "Plan", value: e.string("plan.name") ?? "None")
                    BillingLine(label: "Status", value: BillingStatus.style.label(for: e.string("status") ?? "none"))
                    let features = BillingGrantText.features(e)
                    BillingLine(label: "Can use", value: features.isEmpty ? "Nothing extra" : features)
                case .failed(let error):
                    InlineErrorRow(error: error)
                default:
                    ProgressView()
                }
            } header: {
                Text("Access now")
            } footer: {
                Text("Everything this customer can use in the app right now: their plan, purchases and grants together.")
            }
        }
        .wsDetailList()
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAccess() }
    }

    private func loadAccess() async {
        guard let app = subscription.string("app_uuid"), let customer = subscription.string("customer_uuid") else {
            access = .loaded(Record([:]))
            return
        }
        do {
            let json = try await services.workspace().get("/api/v2/subscriptions/entitlements",
                                                          query: ["app": app, "customer": customer])
            access = .loaded(BillingAPI.data(json))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            access = .failed(apiError)
        }
    }
}

/// A one-off or fixed-term purchase: what was paid, access, and Refund / Revoke.
private struct BillingPurchaseDetail: View {
    let purchase: Record
    let onChange: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var refunding = false
    @State private var confirmingRevoke = false
    @State private var feedback: Feedback = .none

    private var canUpdate: Bool { session.permissions.can(.update, moduleName: BillingModule.subscriptions) }
    private var isActive: Bool { purchase.string("status") == "active" }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            Section {
                HStack {
                    Text(appPlan(purchase)).font(.wsTitle3.bold())
                    Spacer()
                    BillingStatus.badge(purchase.string("status") ?? "active")
                }
                BillingLine(label: "Paid", value: BillingMoney.text(purchase.int("amount"), purchase.string("currency")))
                BillingLine(label: "Coupon", value: purchase.string("coupon_code"))
                if let refunded = purchase.int("refunded_amount"), refunded > 0 {
                    BillingLine(label: "Refunded", value: BillingMoney.text(refunded, purchase.string("currency")))
                }
                BillingLine(label: "Refunded on", value: BillingDay.text(purchase, "refunded_at"))
                BillingLine(label: "Kind", value: purchase.string("purchase_type") == "fixed_term" ? "Fixed term" : "One-time (lifetime)")
                BillingLine(label: "Paid by", value: BillingSource.label(purchase.string("source")))
                BillingLine(label: "Reference", value: purchase.string("external_transaction_id"))
                BillingLine(label: "Access", value: BillingDay.text(purchase, "access_until").map { "Until \($0)" } ?? "Perpetual")
                BillingLine(label: "Updates", value: BillingDay.text(purchase, "updates_until").map { "Until \($0)" } ?? "All updates")
                BillingLine(label: "Recorded by", value: purchase.string("created_by"))
                BillingLine(label: "Date", value: BillingDay.text(purchase, "created_at"))
            }
            BillingCustomerSection(row: purchase)
            if canUpdate && isActive {
                Section {
                    if BillingPurchaseText.canRefund(purchase) {
                        Button { refunding = true } label: { Label("Refund", systemImage: "arrow.uturn.backward.circle") }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("billing.purchase.refund")
                    }
                    Button(role: .destructive) { confirmingRevoke = true } label: {
                        Label("Revoke", systemImage: "xmark.circle")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("billing.purchase.revoke")
                } footer: {
                    Text(purchase.string("source") == "stripe"
                         ? "A refund goes back to the customer’s card. Revoking ends their access without a refund."
                         : "Only card payments can be refunded here. Revoking ends their access.")
                }
            }
        }
        .wsDetailList()
        .navigationTitle("Purchase")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $refunding) {
            NavigationStack {
                BillingRefundForm(purchase: purchase) { message in
                    onChange(message)
                    dismiss()
                }
            }
        }
        .confirmationDialog("Revoke this purchase?", isPresented: $confirmingRevoke, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("The customer loses access now, and any licence it issued stops working. Nothing is refunded.")
        }
    }

    private func revoke() async {
        do {
            try await services.workspace().send(.post, "/api/v2/subscriptions/purchases/\(purchase.id)/revoke")
            onChange("Purchase revoked. The customer’s access has ended.")
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

/// Refund all or part of a card payment. The server asks the payment provider; the refund shows once confirmed.
private struct BillingRefundForm: View {
    let purchase: Record
    let onDone: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var full = true
    @State private var amount = ""
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var working = false
    @State private var idempotencyKey = UUID().uuidString

    private var refundable: Int { (purchase.int("amount") ?? 0) - (purchase.int("refunded_amount") ?? 0) }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                LabeledContent("Can be refunded", value: BillingMoney.text(refundable, purchase.string("currency")))
                Toggle("Refund all of it", isOn: $full)
                if !full {
                    LabeledContent("Amount") {
                        TextField("0.00", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("billing.refund.amount")
                    }
                }
            } footer: {
                Text("The money goes back to the customer’s card. It shows here once the payment provider confirms it, usually within a minute.")
            }
        }
        .navigationTitle("Refund")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Refund") { Task { await refund() } }
                    .disabled(working)
                    .accessibilityIdentifier("billing.refund.confirm")
            }
        }
    }

    private func refund() async {
        var body: [String: JSONValue] = [:]
        if !full {
            guard let pence = BillingMoney.pence(amount), pence > 0 else { problem = "Enter the amount to refund."; return }
            guard pence <= refundable else { problem = "That’s more than can be refunded."; return }
            body["amount"] = .number(Double(pence))
        }
        problem = nil
        working = true
        defer { working = false }
        do {
            try await services.workspace().send(.post, "/api/v2/subscriptions/purchases/\(purchase.id)/refund",
                                                body: .object(body), headers: ["Idempotency-Key": idempotencyKey])
            onDone("Refund sent. It shows on the purchase once the payment provider confirms it.")
            dismiss()
        } catch {
            feedback = .failed(BillingErrors.plain(error.asAPIError))
        }
    }
}

/// Access given by hand: what it adds, until when, and Revoke.
private struct BillingGrantDetail: View {
    let grant: Record
    let onChange: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var feedback: Feedback = .none

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            Section {
                Text(appPlan(grant, fallback: grant.string("app_name") ?? "—")).font(.wsTitle3.bold())
                BillingLine(label: "Adds", value: BillingGrantText.features(grant).nonEmpty)
                BillingLine(label: "Reason", value: grant.string("reason"))
                BillingLine(label: "From", value: BillingDay.text(grant, "starts_at"))
                BillingLine(label: "Until", value: BillingGrantText.until(grant))
                BillingLine(label: "Given by", value: grant.string("granted_by"))
                BillingLine(label: "Revoked", value: BillingDay.text(grant, "revoked_at"))
            }
            BillingCustomerSection(row: grant)
            if grant.string("revoked_at") == nil, session.permissions.can(.delete, moduleName: BillingModule.subscriptions) {
                Section {
                    Button(role: .destructive) { confirming = true } label: { Label("Revoke", systemImage: "xmark.circle") }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("billing.grant.revoke")
                }
            }
        }
        .wsDetailList()
        .navigationTitle("Granted access")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Revoke this access?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Revoke", role: .destructive) { Task { await revoke() } }
        } message: {
            Text("The customer loses what this grant gave them. Their plan and purchases aren’t affected.")
        }
    }

    private func revoke() async {
        do {
            try await services.workspace().send(.delete, "/api/v2/subscriptions/grants/\(grant.id)")
            onChange("Access revoked.")
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

// MARK: - Forms

/// Loads an app's active plans (and features) whenever the chosen app changes.
private struct BillingAppPlansLoader: ViewModifier {
    let app: String
    @Binding var plans: [BillingPlanInfo]
    var features: Binding<[BillingFeatureInfo]>?
    @Environment(\.services) private var services

    func body(content: Content) -> some View {
        content.task(id: app) {
            guard !app.isEmpty else {
                plans = []
                if let features { features.wrappedValue = [] }
                return
            }
            plans = ((try? await services.billing.plans(app: app)) ?? []).filter(\.active)
            if let features {
                features.wrappedValue = ((try? await services.billing.app(app))?.features) ?? []
            }
        }
    }
}

/// Record a sale made outside the app's checkout (an invoice paid, a bank transfer): it extends the
/// customer's access, redeems a coupon and records the plan change. A licensed app returns a new key.
private struct BillingSaleForm: View {
    let apps: [BillingAppInfo]
    let onDone: (String, String?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var app = ""
    @State private var customer = ""
    @State private var customerName = ""
    @State private var plans: [BillingPlanInfo] = []
    @State private var plan = ""
    @State private var price = ""
    @State private var coupon = ""
    @State private var note = ""
    @State private var paidUntil: Date?
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var saving = false

    private var chosen: BillingPlanInfo? { plans.first { $0.uuid == plan } }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                BillingAppPicker(apps: apps, selection: $app)
                BillingCustomerField(uuid: $customer, name: $customerName)
                BillingPlanPicker(plans: plans, selection: $plan)
                    .disabled(app.isEmpty)
            }
            Section {
                LabeledContent("Amount paid" + (chosen.map { " (\($0.currency.uppercased()))" } ?? "")) {
                    TextField("0.00", text: $price).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("billing.sale.amount")
                }
                TextField("Coupon (optional)", text: Binding(get: { coupon }, set: { coupon = $0.uppercased() }))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.wsBody.monospaced())
                if chosen?.purchaseType == "recurring" {
                    BillingOptionalDay(label: "Paid until (needed)", date: $paidUntil)
                }
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...4)
            } footer: {
                Text("The amount is before any coupon. For a subscription, say when the payment covers it until.")
            }
        }
        .navigationTitle("Record a sale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Record") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.sale.save")
            }
        }
        .onAppear { if app.isEmpty, apps.count == 1 { app = apps[0].uuid } }
        .modifier(BillingAppPlansLoader(app: app, plans: $plans))
        .onChange(of: app) { _, _ in plan = "" }
        .onChange(of: plan) { _, _ in if let chosen { price = BillingMoney.pounds(chosen.amount) } }
    }

    private func save() async {
        guard !app.isEmpty, !customer.isEmpty, let chosen else { problem = "Choose the app, the customer and the plan."; return }
        guard let pence = BillingMoney.pence(price) else { problem = "Enter the amount paid (0 or more)."; return }
        if chosen.purchaseType == "recurring", paidUntil == nil { problem = "Say when the payment covers the subscription until."; return }
        problem = nil
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = [
            "app": .string(app), "customer": .string(customer), "plan": .string(chosen.uuid),
            "amount": .number(Double(pence)),
        ]
        if let coupon = coupon.trimmedOrNil { body["coupon"] = .string(coupon) }
        if let note = note.trimmedOrNil { body["note"] = .string(note) }
        if chosen.purchaseType == "recurring", let paidUntil { body["expires_at"] = .string(BillingDay.end(paidUntil)) }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/subscriptions/purchases", body: .object(body))
            let result = BillingAPI.data(json)
            onDone("Sale recorded for \(customerName.isEmpty ? "the customer" : customerName).", result.string("key"))
            dismiss()
        } catch {
            feedback = .failed(BillingErrors.plain(error.asAPIError))
        }
    }
}

/// Move a customer to another plan: the price is worked out first, then confirmed.
private struct BillingMoveCustomerForm: View {
    let apps: [BillingAppInfo]
    let onDone: (String, String?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var app = ""
    @State private var customer = ""
    @State private var customerName = ""
    @State private var plans: [BillingPlanInfo] = []
    @State private var toPlan = ""
    @State private var coupon = ""
    @State private var note = ""
    @State private var quote: Record?
    @State private var quoteError: APIError?
    @State private var feedback: Feedback = .none
    @State private var saving = false

    private var quoteKey: String { [app, customer, toPlan, coupon].joined(separator: "|") }

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            Section {
                BillingAppPicker(apps: apps, selection: $app)
                BillingCustomerField(uuid: $customer, name: $customerName)
                BillingPlanPicker(plans: plans, selection: $toPlan, label: "Move to")
                    .disabled(app.isEmpty)
                TextField("Coupon (optional)", text: Binding(get: { coupon }, set: { coupon = $0.uppercased() }))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.wsBody.monospaced())
                TextField("Note (optional)", text: $note, axis: .vertical).lineLimit(2...4)
            }
            Section("Price") {
                if let quote {
                    let currency = quote.string("currency")
                    Text("\(quote.string("from_plan.name") ?? "Their plan") → \(quote.string("to_plan.name") ?? "the new plan")")
                        .font(.wsHeadline)
                    Text(BillingMoney.text(quote.int("amount"), currency)
                         + ((quote.int("discount") ?? 0) > 0 ? " (after \(BillingMoney.text(quote.int("discount"), currency)) off)" : ""))
                        .font(.wsTitle3.monospacedDigit().bold())
                        .accessibilityIdentifier("billing.move.quote")
                    Text(Self.pricingWords(quote.string("pricing"))).font(.wsFootnote).foregroundStyle(.secondaryText)
                } else if let quoteError {
                    InlineErrorRow(error: quoteError)
                } else {
                    Text("Choose the app, the customer and the plan to see the price.").foregroundStyle(.secondaryText)
                }
            }
        }
        .navigationTitle("Move to another plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move") { Task { await move() } }
                    .disabled(saving || quote == nil)
                    .accessibilityIdentifier("billing.move.confirm")
            }
        }
        .onAppear { if app.isEmpty, apps.count == 1 { app = apps[0].uuid } }
        .modifier(BillingAppPlansLoader(app: app, plans: $plans))
        .onChange(of: app) { _, _ in toPlan = "" }
        .task(id: quoteKey) { await requote() }
    }

    static func pricingWords(_ pricing: String?) -> String {
        switch pricing {
        case "fixed": "A fixed price set for this upgrade."
        case "free": "This upgrade is free."
        default: "They pay the difference between the two plans."
        }
    }

    private var requestBody: [String: JSONValue] {
        var body: [String: JSONValue] = ["app": .string(app), "customer": .string(customer), "to_plan": .string(toPlan)]
        if let coupon = coupon.trimmedOrNil { body["coupon"] = .string(coupon) }
        if let note = note.trimmedOrNil { body["note"] = .string(note) }
        return body
    }

    private func requote() async {
        quote = nil
        quoteError = nil
        guard !app.isEmpty, !customer.isEmpty, !toPlan.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/subscriptions/upgrade",
                                                           body: .object(requestBody), query: ["quote": "1"])
            guard !Task.isCancelled else { return }
            quote = BillingAPI.data(json)
        } catch {
            guard !Task.isCancelled else { return }
            quoteError = BillingErrors.plain(error.asAPIError)
        }
    }

    private func move() async {
        saving = true
        defer { saving = false }
        do {
            let json = try await services.workspace().send(.post, "/api/v2/subscriptions/upgrade", body: .object(requestBody))
            let result = BillingAPI.data(json)
            let plan = result.string("to_plan.name") ?? "the new plan"
            let message = (result.bool("pending") ?? false)
                ? "Moving to \(plan). The customer’s card on file is charged the difference, and the move happens once that payment goes through."
                : "Moved to \(plan)."
            onDone(message, result.string("key"))
            dismiss()
        } catch {
            feedback = .failed(BillingErrors.plain(error.asAPIError))
        }
    }
}

/// Give a customer access without a sale: a plan, or extra features, until a date or until revoked.
private struct BillingGrantForm: View {
    let apps: [BillingAppInfo]
    let onDone: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var app = ""
    @State private var customer = ""
    @State private var customerName = ""
    @State private var plans: [BillingPlanInfo] = []
    @State private var features: [BillingFeatureInfo] = []
    @State private var plan = ""
    @State private var values: [String: BillingFeatureValue] = [:]
    @State private var starts: Date?
    @State private var ends: Date?
    @State private var reason = ""
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
                BillingAppPicker(apps: apps, selection: $app)
                BillingCustomerField(uuid: $customer, name: $customerName)
                BillingPlanPicker(plans: plans, selection: $plan, noneLabel: "No plan, just the features below")
                    .disabled(app.isEmpty)
            }
            if !app.isEmpty {
                Section {
                    BillingFeatureValuesEditor(features: features, values: $values, optional: true)
                } header: {
                    Text("Extra features")
                } footer: {
                    Text("Leave a feature as “Not changed” to keep what their plan gives them.")
                }
            }
            Section {
                BillingOptionalDay(label: "Starts", date: $starts, help: "Blank: from now.")
                BillingOptionalDay(label: "Ends", date: $ends, help: "Blank: until revoked.")
                TextField("Reason (optional)", text: $reason, axis: .vertical).lineLimit(2...4)
            }
        }
        .navigationTitle("Grant access")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Grant") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.grant.save")
            }
        }
        .onAppear { if app.isEmpty, apps.count == 1 { app = apps[0].uuid } }
        .modifier(BillingAppPlansLoader(app: app, plans: $plans, features: $features))
        .onChange(of: app) { _, _ in plan = ""; values = [:] }
    }

    private func save() async {
        guard !app.isEmpty, !customer.isEmpty else { problem = "Choose the app and the customer."; return }
        guard !plan.isEmpty || !values.isEmpty else { problem = "Choose a plan or set at least one feature."; return }
        if reason.count > 500 { problem = "Keep the reason under 500 characters."; return }
        problem = nil
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = ["app": .string(app), "customer": .string(customer)]
        if !plan.isEmpty { body["plan"] = .string(plan) }
        if !values.isEmpty { body["features"] = BillingFeatureValue.json(values) }
        if let reason = reason.trimmedOrNil { body["reason"] = .string(reason) }
        if let starts { body["starts_at"] = .string(BillingDay.start(starts)) }
        if let ends { body["expires_at"] = .string(BillingDay.end(ends)) }
        do {
            try await services.workspace().send(.post, "/api/v2/subscriptions/grants", body: .object(body))
            onDone("Access granted to \(customerName.isEmpty ? "the customer" : customerName).")
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}
