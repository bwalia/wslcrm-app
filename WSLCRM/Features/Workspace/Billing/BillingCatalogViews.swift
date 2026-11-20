import SwiftUI

// MARK: - Features

/// An app's features (`/api/v2/billing/apps/:app/features`): what plans can include.
struct BillingFeaturesTab: View {
    let appUUID: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[BillingFeatureInfo]> = .idle
    @State private var editing: BillingFeatureInfo?
    @State private var creating = false
    @State private var deleting: BillingFeatureInfo?
    @State private var feedback: Feedback = .none

    private var permissions: PermissionSet { session.permissions }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch state {
            case .loaded(let features) where features.isEmpty:
                ContentUnavailableView("No features yet", systemImage: "list.bullet.rectangle",
                                       description: Text("A feature is something a plan can include: switched on or off (\u{201C}Export to PDF\u{201D}) or a limit (\u{201C}5 projects\u{201D})."))
            case .loaded(let features):
                ForEach(features) { feature in
                    Button {
                        if permissions.can(.update, moduleName: BillingModule.billing) { editing = feature }
                    } label: {
                        BillingFeatureRow(feature: feature)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("billing.feature.row.\(feature.key)")
                    .swipeActions {
                        if permissions.can(.delete, moduleName: BillingModule.billing) {
                            Button("Delete", role: .destructive) { deleting = feature }
                        }
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            if permissions.can(.create, moduleName: BillingModule.billing) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New feature", systemImage: "plus") }
                        .accessibilityIdentifier("billing.features.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BillingFeatureForm(appUUID: appUUID, feature: nil) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .sheet(item: $editing) { feature in
            NavigationStack {
                BillingFeatureForm(appUUID: appUUID, feature: feature) { message in
                    feedback = .done(message)
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this feature")?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let feature = deleting {
                Button("Delete feature", role: .destructive) { Task { await delete(feature) } }
            }
        } message: {
            Text("It is taken off every plan and grant of this app.")
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.billing.features(app: appUUID).sorted { $0.sortOrder < $1.sortOrder })
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { feedback = .failed(apiError) }
        }
    }

    private func delete(_ feature: BillingFeatureInfo) async {
        await perform($feedback, done: "\(feature.name) deleted.") {
            try await services.workspace().send(.delete, "/api/v2/billing/apps/\(appUUID)/features/\(feature.key)")
        }
        await load()
    }
}

private struct BillingFeatureRow: View {
    let feature: BillingFeatureInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(feature.name).font(.wsHeadline)
                Spacer()
                Text(feature.typeLabel).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let description = feature.description {
                Text(description).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            HStack {
                Text(feature.key).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                if let released = feature.releasedAt.flatMap({ CalendarDay(string: $0)?.date() }) {
                    Text("· Released \(Formatters.day(released) ?? "")").font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Add or change a feature. Its key and type are fixed once it exists (the server refuses to change them).
private struct BillingFeatureForm: View {
    let appUUID: String
    let feature: BillingFeatureInfo?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var type = "boolean"
    @State private var name = ""
    @State private var description = ""
    @State private var unit = ""
    @State private var sortOrder = "0"
    @State private var released: Date?
    @State private var feedback: Feedback = .none
    @State private var problem: String?
    @State private var saving = false
    @State private var prepared = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("Name (needed), e.g. Export to PDF", text: $name)
                    .accessibilityIdentifier("billing.feature.name")
                if let feature {
                    LabeledContent("Key", value: feature.key)
                    LabeledContent("Type", value: feature.typeLabel)
                } else {
                    TextField("Key (needed), e.g. pdf_export", text: Binding(get: { key }, set: { key = $0.lowercased() }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.wsBody.monospaced())
                        .accessibilityIdentifier("billing.feature.key")
                    Picker("Type", selection: $type) {
                        Text("On / off").tag("boolean")
                        Text("Limit").tag("limit")
                    }
                }
            } footer: {
                Text(feature == nil ? "Your app checks the key. Key and type can’t change later: delete the feature and add a new one instead."
                                    : "Key and type can’t change. Delete the feature and add a new one instead.")
            }
            Section {
                TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                if (feature?.type ?? type) == "limit" {
                    TextField("Unit, e.g. projects", text: $unit)
                }
                LabeledContent("Order") {
                    TextField("0", text: $sortOrder).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                BillingOptionalDay(label: "Released", date: $released,
                                   help: "One-time buyers get features released inside their updates window.")
            }
        }
        .navigationTitle(feature == nil ? "New feature" : "Edit feature")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(feature == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.feature.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            guard let feature else { return }
            name = feature.name
            description = feature.description ?? ""
            unit = feature.unit ?? ""
            sortOrder = String(feature.sortOrder)
            released = feature.releasedAt.flatMap { CalendarDay(string: $0)?.date() }
        }
    }

    private func save() async {
        if name.trimmedOrNil == nil { problem = "Give the feature a name."; return }
        if feature == nil, key.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) == nil {
            problem = "The key can only use lowercase letters, numbers and _."
            return
        }
        problem = nil
        saving = true
        defer { saving = false }
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "description": .textOrEmpty(description),
            "sort_order": .number(Double(Int(sortOrder) ?? 0)),
            "released_at": released.map { .string(BillingDay.start($0)) } ?? .null,
        ]
        if (feature?.type ?? type) == "limit" { body["unit"] = .textOrEmpty(unit) }
        do {
            if let feature {
                try await services.workspace().send(.put, "/api/v2/billing/apps/\(appUUID)/features/\(feature.key)",
                                                    body: .object(body))
                onSaved("\(name) saved.")
            } else {
                body["key"] = .string(key)
                body["type"] = .string(type)
                try await services.workspace().send(.post, "/api/v2/billing/apps/\(appUUID)/features", body: .object(body))
                onSaved("\(name) added. Give it a value on each plan.")
            }
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

// MARK: - Plans

/// An app's plans: price, what each includes, and whether customers can choose it.
struct BillingPlansTab: View {
    let appUUID: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var plans: LoadState<[BillingPlanInfo]> = .idle
    @State private var features: [BillingFeatureInfo] = []
    @State private var editing: BillingPlanInfo?
    @State private var creating = false
    @State private var feedback: Feedback = .none

    private var permissions: PermissionSet { session.permissions }
    /// Plans also accept `namespace.manage` on the server.
    private func can(_ action: Action) -> Bool {
        permissions.can(action, moduleName: BillingModule.billing) || permissions.can(.manage, moduleName: "namespace")
    }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch plans {
            case .loaded(let list) where list.isEmpty:
                ContentUnavailableView("No plans yet", systemImage: "square.stack",
                                       description: Text("A plan is what customers choose: a subscription, a one-time purchase or a fixed term, and what it includes."))
            case .loaded(let list):
                ForEach(list) { plan in
                    Button {
                        if can(.update) { editing = plan }
                    } label: {
                        BillingPlanRow(plan: plan, features: features)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("billing.plan.row.\(plan.uuid)")
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            if can(.create) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New plan", systemImage: "plus") }
                        .accessibilityIdentifier("billing.plans.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BillingPlanForm(appUUID: appUUID, plan: nil, features: features, canDelete: false) { message in
                    feedback = message
                    Task { await load() }
                }
            }
        }
        .sheet(item: $editing) { plan in
            NavigationStack {
                BillingPlanForm(appUUID: appUUID, plan: plan, features: features, canDelete: can(.delete)) { message in
                    feedback = message
                    Task { await load() }
                }
            }
        }
    }

    private func load() async {
        do {
            let billing = services.billing
            let app = appUUID
            async let planList = billing.plans(app: app)
            async let featureList = billing.features(app: app)
            let (loadedPlans, loadedFeatures) = try await (planList, featureList)
            features = loadedFeatures.sorted { $0.sortOrder < $1.sortOrder }
            plans = .loaded(loadedPlans)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if plans.value == nil { plans = .failed(apiError) } else { feedback = .failed(apiError) }
        }
    }
}

private struct BillingPlanRow: View {
    let plan: BillingPlanInfo
    let features: [BillingFeatureInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.name).font(.wsHeadline)
                if plan.isDefault {
                    Image(systemName: "star.fill").foregroundStyle(Tone.warning.textColor).accessibilityLabel("Default plan")
                }
                Spacer()
                StatusBadge(text: plan.statusText, systemImage: plan.active ? (plan.isPublic ? "eye" : "eye.slash") : "pause.circle",
                            tone: plan.active ? (plan.isPublic ? .success : .neutral) : .neutral)
            }
            Text(plan.planKey).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
            Text(plan.priceText).font(.wsBody.monospacedDigit().weight(.semibold))
            Text(plan.typeLine).font(.wsFootnote).foregroundStyle(.secondaryText)
            ForEach(features) { feature in
                Text("\(feature.name): \(BillingFeatureValue.describe(feature, plan.features[feature.key]))")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Create or edit a plan: how it's sold (with only the fields that kind of sale needs), its price,
/// what it includes, store product ids and whether it is default, public and active.
private struct BillingPlanForm: View {
    let appUUID: String
    let plan: BillingPlanInfo?
    let features: [BillingFeatureInfo]
    let canDelete: Bool
    let onSaved: (Feedback) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BillingPlanDraft()
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
                TextField("Name (needed), e.g. Pro", text: $draft.name)
                    .accessibilityIdentifier("billing.plan.name")
                TextField("Plan key, e.g. pro (from the name if blank)", text: Binding(get: { draft.planKey },
                                                                                     set: { draft.planKey = $0.lowercased() }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.wsBody.monospaced())
            }
            Section {
                Picker("Sold as", selection: $draft.purchaseType) {
                    ForEach(BillingPlanInfo.purchaseTypes) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("billing.plan.type")
                LabeledContent("Price") {
                    TextField("0.00", text: $draft.price)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("billing.plan.price")
                }
                Picker("Currency", selection: $draft.currency) {
                    ForEach(currencies, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                switch draft.purchaseType {
                case "recurring":
                    Picker("Billed every", selection: $draft.interval) {
                        Text("Month").tag("month")
                        Text("Year").tag("year")
                        Text("Week").tag("week")
                        Text("Day").tag("day")
                    }
                    LabeledContent("Free trial (days)") {
                        TextField("0", text: $draft.trialDays).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                case "fixed_term":
                    LabeledContent("Term (days)") {
                        TextField("30", text: $draft.termDays).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    Picker("The term covers", selection: $draft.termCovers) {
                        Text("Access").tag("access")
                        Text("Updates only").tag("updates")
                    }
                default:
                    LabeledContent("Updates included (days)") {
                        TextField("Every future version", text: $draft.updatesDays)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Price")
            } footer: {
                Text(typeHelp + " Enter 0 for a free plan.")
            }
            Section {
                BillingFeatureValuesEditor(features: features, values: $draft.features)
            } header: {
                Text("Includes")
            }
            Section {
                TextField("App Store product id, e.g. com.example.pro", text: $draft.appStoreID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Google Play product id, e.g. pro_yearly", text: $draft.playStoreID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("App store products")
            } footer: {
                Text("Only for plans also sold through the App Store or Google Play.")
            }
            Section {
                Toggle(isOn: $draft.isDefault) { title("Default plan", "Every customer gets it for free") }
                Toggle(isOn: $draft.isPublic) { title("Public", "Shown on the pricing page") }
                Toggle(isOn: $draft.active) { title("Active", "Can be chosen") }
            }
            if let plan, canDelete {
                Section {
                    DeleteButton(title: "Delete plan",
                                 message: "Customers can no longer choose it. Existing subscriptions and purchases are kept.") {
                        do {
                            try await services.workspace().send(.delete, "/api/v2/billing/plans/\(plan.uuid)")
                            onSaved(.done("\(plan.name) deleted."))
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
        .navigationTitle(plan.map { "Edit \($0.name)" } ?? "New plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(plan == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.plan.save")
            }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            draft = BillingPlanDraft(plan: plan, features: features)
        }
    }

    private var currencies: [String] {
        BillingMoney.currencies.contains(draft.currency) ? BillingMoney.currencies : BillingMoney.currencies + [draft.currency]
    }

    private var typeHelp: String {
        switch draft.purchaseType {
        case "recurring": "Renews every period until cancelled."
        case "one_time": "Paid once; access never ends. Leave updates blank for every future version."
        default: "Paid once for a number of days; buying again adds more."
        }
    }

    private func title(_ text: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
            Text(hint).font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    private func save() async {
        problem = draft.problem()
        guard problem == nil else { return }
        saving = true
        defer { saving = false }
        do {
            let json: JSONValue
            if let plan {
                json = try await services.workspace().send(.put, "/api/v2/billing/plans/\(plan.uuid)", body: draft.body(app: nil))
            } else {
                json = try await services.workspace().send(.post, "/api/v2/billing/plans", body: draft.body(app: appUUID))
            }
            let name = draft.name.trimmingCharacters(in: .whitespaces)
            if let syncError = WorkspaceAPI.object(json).string("sync_error") {
                onSaved(.done("\(name) saved, but the price couldn’t be sent to the payment provider yet: \(syncError)"))
            } else {
                onSaved(.done(plan == nil ? "\(name) added." : "\(name) saved."))
            }
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}

// MARK: - Upgrades

/// Which plans a customer can move up to, and what they pay to do it.
struct BillingUpgradesTab: View {
    let appUUID: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var paths: LoadState<[Record]> = .idle
    @State private var plans: [BillingPlanInfo] = []
    @State private var creating = false
    @State private var deleting: Record?
    @State private var feedback: Feedback = .none

    static let pricingLabels: [String: String] = [
        "difference": "Pays the price difference", "fixed": "Pays a fixed price", "free": "Free",
    ]

    private var permissions: PermissionSet { session.permissions }

    var body: some View {
        List {
            FeedbackSection(feedback: feedback)
            switch paths {
            case .loaded(let list) where list.isEmpty:
                ContentUnavailableView("No upgrades yet", systemImage: "arrow.up.circle",
                                       description: Text("An upgrade lets a customer move from one plan to a better one, paying the difference, a fixed price or nothing."))
            case .loaded(let list):
                ForEach(list) { path in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(path.string("from_plan_name") ?? "?") → \(path.string("to_plan_name") ?? "?")").font(.wsHeadline)
                        Text(Self.price(path)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        if permissions.can(.update, moduleName: BillingModule.billing) {
                            Toggle("Active", isOn: Binding(get: { path.bool("active") ?? true },
                                                           set: { on in Task { await setActive(path, on) } }))
                                .accessibilityIdentifier("billing.upgrade.active.\(path.id)")
                        } else {
                            Text((path.bool("active") ?? true) ? "Active" : "Off").font(.wsFootnote)
                        }
                    }
                    .padding(.vertical, 2)
                    .swipeActions {
                        if permissions.can(.delete, moduleName: BillingModule.billing) {
                            Button("Remove", role: .destructive) { deleting = path }
                        }
                    }
                }
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            if permissions.can(.create, moduleName: BillingModule.billing) {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New upgrade", systemImage: "plus") }
                        .accessibilityIdentifier("billing.upgrades.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                BillingUpgradeForm(appUUID: appUUID, plans: plans.filter(\.active)) {
                    feedback = .done("Upgrade added.")
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Remove this upgrade?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            if let path = deleting {
                Button("Remove upgrade", role: .destructive) { Task { await delete(path) } }
            }
        } message: {
            Text("Customers can no longer move between these two plans this way.")
        }
    }

    static func price(_ path: Record) -> String {
        let pricing = path.string("pricing") ?? "difference"
        if pricing == "fixed", let amount = path.int("amount") { return BillingMoney.text(amount, path.string("currency")) }
        return pricingLabels[pricing] ?? Formatters.humanize(pricing)
    }

    private func load() async {
        do {
            let billing = services.billing
            let app = appUUID
            async let list = billing.api.get("/api/v2/billing/apps/\(app)/upgrades")
            async let planList = billing.plans(app: app)
            let (json, loadedPlans) = try await (list, planList)
            plans = loadedPlans
            paths = .loaded(WorkspaceAPI.records(json, idKeys: ["uuid"]))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if paths.value == nil { paths = .failed(apiError) } else { feedback = .failed(apiError) }
        }
    }

    private func setActive(_ path: Record, _ on: Bool) async {
        await perform($feedback, done: on ? "Upgrade switched on." : "Upgrade switched off.") {
            try await services.workspace().send(.put, "/api/v2/billing/apps/\(appUUID)/upgrades/\(path.id)",
                                                body: .object(["active": .bool(on)]))
        }
        await load()
    }

    private func delete(_ path: Record) async {
        await perform($feedback, done: "Upgrade removed.") {
            try await services.workspace().send(.delete, "/api/v2/billing/apps/\(appUUID)/upgrades/\(path.id)")
        }
        await load()
    }
}

private struct BillingUpgradeForm: View {
    let appUUID: String
    let plans: [BillingPlanInfo]
    let onSaved: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var from = ""
    @State private var to = ""
    @State private var pricing = "difference"
    @State private var price = ""
    @State private var problem: String?
    @State private var feedback: Feedback = .none
    @State private var saving = false

    var body: some View {
        Form {
            FeedbackSection(feedback: feedback)
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            if plans.count < 2 {
                Section { Text("Add at least two active plans first.").foregroundStyle(.secondaryText) }
            }
            Section {
                BillingPlanPicker(plans: plans, selection: $from, label: "From plan")
                BillingPlanPicker(plans: plans.filter { $0.uuid != from }, selection: $to, label: "To plan")
            }
            Section {
                Picker("Price", selection: $pricing) {
                    ForEach(["difference", "fixed", "free"], id: \.self) {
                        Text(BillingUpgradesTab.pricingLabels[$0] ?? $0).tag($0)
                    }
                }
                if pricing == "fixed" {
                    LabeledContent("Upgrade price") {
                        TextField("0.00", text: $price).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                Text("In the target plan’s currency.")
            }
        }
        .navigationTitle("New upgrade")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("billing.upgrade.save")
            }
        }
    }

    private func save() async {
        if from.isEmpty || to.isEmpty { problem = "Choose both plans."; return }
        var body: [String: JSONValue] = ["from_plan": .string(from), "to_plan": .string(to), "pricing": .string(pricing)]
        if pricing == "fixed" {
            guard let pence = BillingMoney.pence(price) else { problem = "Enter the upgrade price."; return }
            body["amount"] = .number(Double(pence))
        }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            try await services.workspace().send(.post, "/api/v2/billing/apps/\(appUUID)/upgrades", body: .object(body))
            onSaved()
            dismiss()
        } catch {
            feedback = .failed(error.asAPIError)
        }
    }
}
