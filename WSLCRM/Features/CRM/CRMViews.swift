import SwiftUI

// MARK: - Home

struct CRMHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: LoadState<CRMDashboardStats> = .idle

    var body: some View {
        List {
            Section {
                switch stats {
                case .idle, .loading:
                    SkeletonRow()
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let stats):
                    statsGrid(stats)
                }
            }
            Section {
                NavigationLink { DealPipelineView() } label: {
                    Label("Deal pipeline", systemImage: "rectangle.split.3x1")
                }
                NavigationLink { CRMAccountsListView() } label: {
                    Label("Accounts", systemImage: "building.2")
                }
                NavigationLink { CRMContactsListView() } label: {
                    Label("Contacts", systemImage: "person.crop.circle")
                }
            }
        }
        .navigationTitle("CRM")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if stats.value == nil { stats = .loading }
        do {
            stats = .loaded(try await services.crm.dashboardStats())
        } catch {
            stats = .failed(error.asAPIError)
        }
    }

    private func statsGrid(_ stats: CRMDashboardStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
            StatTile(title: "Open deals", value: "\(stats.openDeals)", systemImage: "briefcase")
            StatTile(title: "Won", value: "\(stats.wonDeals)", systemImage: "trophy")
            StatTile(title: "Win rate", value: "\(stats.winRate.formatted(.number.precision(.fractionLength(0...1))))%",
                     systemImage: "percent")
            StatTile(title: "Accounts", value: "\(stats.totalAccounts)", systemImage: "building.2")
        }
        .padding(.vertical, 4)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private extension SessionStore {
    var canCreateCRM: Bool { permissions.can(.create, .crmAccounts) }
    var canUpdateCRM: Bool { permissions.can(.update, .crmAccounts) }
    var canDeleteCRM: Bool { permissions.can(.delete, .crmAccounts) }
}

// MARK: - Accounts

struct CRMAccountsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false

    var body: some View {
        ModelHost(make: { [crm = services.crm] in
            PagedListModel<CRMAccount> { search, page in try await crm.accounts(search: search, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No accounts", emptySystemImage: "building.2") { account in
                NavigationLink {
                    CRMAccountDetailView(accountUuid: account.uuid) { updated in
                        if let updated { model.replace(updated) } else { model.remove(id: account.id) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name).font(.headline)
                        Text([account.industry, account.city].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .sheet(isPresented: $creating) {
                CRMAccountForm(account: nil) { body in
                    let created = try await services.crm.createAccount(body)
                    await model.load()
                    return created
                }
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            if session.canCreateCRM {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New account", systemImage: "plus") { creating = true }
                }
            }
        }
    }
}

struct CRMAccountDetailView: View {
    let accountUuid: String
    var onChange: (CRMAccount?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<CRMAccount> = .idle
    @State private var contacts: [CRMContact] = []
    @State private var deals: [CRMDeal] = []
    @State private var editing = false
    @State private var deleteError: APIError?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let account):
                content(account)
            }
        }
        .navigationTitle(state.value?.name ?? "Account")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.canUpdateCRM, state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let account = state.value {
                CRMAccountForm(account: account) { body in
                    let updated = try await services.crm.updateAccount(account.uuid, body)
                    state = .loaded(updated)
                    onChange(updated)
                    return updated
                }
            }
        }
    }

    private func content(_ account: CRMAccount) -> some View {
        List {
            Section {
                HStack(spacing: 8) {
                    StatusBadge(text: Formatters.humanize(account.status), systemImage: "circle.fill",
                                tone: account.status == "active" ? .success : .neutral)
                    if let industry = account.industry { Text(industry).foregroundStyle(.secondary) }
                }
                if let phone = account.phone { PhoneLinkRow(name: account.name, phone: phone) }
                if let email = account.email { EmailLinkRow(email: email) }
                if let address = account.address { MapsLinkRow(address: address) }
                if let website = account.website, let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                    Link(destination: url) { Label(website, systemImage: "safari").frame(minHeight: 44) }
                }
            }
            Section("Summary") {
                DetailRow(label: "Contacts", value: account.contactCount.map(String.init))
                DetailRow(label: "Deals", value: account.dealCount.map(String.init))
                DetailRow(label: "Deal value", value: Formatters.money(account.totalDealValue, currency: nil))
                DetailRow(label: "Employees", value: account.employeeCount.map(String.init))
                DetailRow(label: "Annual revenue", value: Formatters.money(account.annualRevenue, currency: nil))
            }
            if !contacts.isEmpty {
                Section("Contacts") {
                    ForEach(contacts) { contact in
                        NavigationLink { CRMContactDetailView(contactUuid: contact.uuid) } label: {
                            VStack(alignment: .leading) {
                                Text(contact.fullName).font(.headline)
                                if let title = contact.jobTitle { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            if !deals.isEmpty {
                Section("Deals") {
                    ForEach(deals) { deal in
                        NavigationLink { CRMDealDetailView(dealUuid: deal.uuid) } label: { DealRow(deal: deal) }
                    }
                }
            }
            if session.canDeleteCRM {
                Section {
                    DeleteButton(title: "Delete account", message: "Contacts and deals keep their link to this account's name.") {
                        do {
                            try await services.crm.deleteAccount(account.uuid)
                            onChange(nil)
                            return true
                        } catch {
                            deleteError = error.asAPIError
                            return false
                        }
                    }
                    if let deleteError { InlineErrorRow(error: deleteError) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let account = try await services.crm.account(accountUuid)
            state = .loaded(account)
            async let contactsPage = services.crm.contacts(search: "", accountId: account.id, page: 1, perPage: 50)
            async let dealsPage = services.crm.deals(accountId: account.id, page: 1, perPage: 50)
            contacts = (try? await contactsPage.items) ?? []
            deals = (try? await dealsPage.items) ?? []
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

struct CRMAccountForm: View {
    let account: CRMAccount?
    let save: (AccountBody) async throws -> CRMAccount
    @Environment(\.dismiss) private var dismiss
    @State private var body_: AccountBody
    @State private var saving = false
    @State private var error: APIError?

    init(account: CRMAccount?, save: @escaping (AccountBody) async throws -> CRMAccount) {
        self.account = account
        self.save = save
        _body_ = State(initialValue: AccountBody(
            name: account?.name ?? "", industry: account?.industry, website: account?.website, phone: account?.phone,
            email: account?.email, addressLine1: account?.addressLine1, city: account?.city,
            postalCode: account?.postalCode, country: account?.country, status: account?.status ?? "active"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $body_.name)
                    OptionalTextField("Industry", text: $body_.industry)
                    Picker("Status", selection: Binding(get: { body_.status ?? "active" }, set: { body_.status = $0 })) {
                        Text("Active").tag("active")
                        Text("Inactive").tag("inactive")
                        Text("Prospect").tag("prospect")
                    }
                }
                Section("Contact details") {
                    OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    OptionalTextField("Email", text: $body_.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    OptionalTextField("Website", text: $body_.website).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Section("Address") {
                    OptionalTextField("Street", text: $body_.addressLine1).textContentType(.streetAddressLine1)
                    OptionalTextField("City", text: $body_.city).textContentType(.addressCity)
                    OptionalTextField("Postcode", text: $body_.postalCode).textContentType(.postalCode)
                    OptionalTextField("Country", text: $body_.country).textContentType(.countryName)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .disabled(body_.name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func submit() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                _ = try await save(body_)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

/// A text field bound to an optional string. Clearing sends `""` (the API rejects `null`).
struct OptionalTextField: View {
    let title: String
    @Binding var text: String?

    init(_ title: String, text: Binding<String?>) {
        self.title = title
        _text = text
    }

    var body: some View {
        TextField(title, text: Binding(get: { text ?? "" }, set: { text = $0 }))
    }
}

// MARK: - Contacts

struct CRMContactsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false

    var body: some View {
        ModelHost(make: { [crm = services.crm] in
            PagedListModel<CRMContact> { search, page in try await crm.contacts(search: search, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No contacts", emptySystemImage: "person.crop.circle") { contact in
                NavigationLink {
                    CRMContactDetailView(contactUuid: contact.uuid)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(contact.fullName).font(.headline)
                        Text([contact.jobTitle, contact.accountName].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .sheet(isPresented: $creating) {
                CRMContactForm(contact: nil) { body in
                    let created = try await services.crm.createContact(body)
                    await model.load()
                    return created
                }
            }
        }
        .navigationTitle("Contacts")
        .toolbar {
            if session.canCreateCRM {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New contact", systemImage: "plus") { creating = true }
                }
            }
        }
    }
}

struct CRMContactDetailView: View {
    let contactUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<CRMContact> = .idle
    @State private var editing = false
    @State private var deleteError: APIError?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let contact):
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(contact.fullName).font(.title2.bold())
                            Text([contact.jobTitle, contact.department].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        if let account = contact.accountName {
                            Label(account, systemImage: "building.2")
                        }
                    }
                    Section("Reach") {
                        if let mobile = contact.mobile { PhoneLinkRow(name: "Mobile", phone: mobile) }
                        if let phone = contact.phone { PhoneLinkRow(name: "Phone", phone: phone) }
                        if let email = contact.email { EmailLinkRow(email: email) }
                    }
                    if session.canDeleteCRM {
                        Section {
                            DeleteButton(title: "Delete contact", message: "This removes the contact from CRM.") {
                                do {
                                    try await services.crm.deleteContact(contact.uuid)
                                    return true
                                } catch {
                                    deleteError = error.asAPIError
                                    return false
                                }
                            }
                            if let deleteError { InlineErrorRow(error: deleteError) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.canUpdateCRM, state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let contact = state.value {
                CRMContactForm(contact: contact) { body in
                    let updated = try await services.crm.updateContact(contact.uuid, body)
                    state = .loaded(updated)
                    return updated
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.crm.contact(contactUuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

struct CRMContactForm: View {
    let contact: CRMContact?
    let save: (ContactBody) async throws -> CRMContact
    @Environment(\.dismiss) private var dismiss
    @State private var body_: ContactBody
    @State private var saving = false
    @State private var error: APIError?

    init(contact: CRMContact?, save: @escaping (ContactBody) async throws -> CRMContact) {
        self.contact = contact
        self.save = save
        _body_ = State(initialValue: ContactBody(firstName: contact?.firstName ?? "", lastName: contact?.lastName,
                                                 email: contact?.email, phone: contact?.phone, mobile: contact?.mobile,
                                                 jobTitle: contact?.jobTitle, accountId: contact?.accountId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("First name", text: $body_.firstName).textContentType(.givenName)
                    OptionalTextField("Last name", text: $body_.lastName).textContentType(.familyName)
                    OptionalTextField("Job title", text: $body_.jobTitle).textContentType(.jobTitle)
                }
                Section("Reach") {
                    OptionalTextField("Mobile", text: $body_.mobile).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad)
                    OptionalTextField("Email", text: $body_.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Account") {
                    CRMAccountPicker(accountId: $body_.accountId)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(contact == nil ? "New contact" : "Edit contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        error = nil
                        Task {
                            defer { saving = false }
                            do {
                                _ = try await save(body_)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(body_.firstName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }
}

/// Picks an account by numeric id (the only link form CRM updates accept).
struct CRMAccountPicker: View {
    @Binding var accountId: Int?
    @Environment(\.services) private var services
    @State private var accounts: [CRMAccount] = []

    var body: some View {
        Picker("Account", selection: $accountId) {
            Text("None").tag(Int?.none)
            ForEach(accounts) { Text($0.name).tag(Optional($0.id)) }
        }
        .task {
            accounts = (try? await services.crm.accounts(search: "", page: 1, perPage: 100).items) ?? []
        }
    }
}

// MARK: - Deals

struct DealRow: View {
    let deal: CRMDeal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(deal.name).font(.headline).lineLimit(2)
                Spacer()
                Text(Formatters.money(deal.value, currency: deal.currency) ?? "")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            HStack(spacing: 8) {
                deal.statusBadge
                Text(Formatters.humanize(deal.stage)).font(.subheadline).foregroundStyle(.secondary)
                if deal.probability > 0 {
                    Text("\(deal.probability)%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let account = deal.accountName ?? deal.contactName {
                Label(account, systemImage: "building.2").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

extension CRMDeal {
    var statusBadge: StatusBadge {
        switch status {
        case .open: StatusBadge(text: "Open", systemImage: "circle", tone: .info)
        case .won: StatusBadge(text: "Won", systemImage: "trophy.fill", tone: .success)
        case .lost: StatusBadge(text: "Lost", systemImage: "xmark.circle.fill", tone: .danger)
        case .unknown: StatusBadge(text: "Unknown", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

@MainActor
@Observable
final class DealPipelineViewModel {
    private(set) var pipelines: [CRMPipeline] = []
    var selectedPipelineUuid: String?
    var selectedStage: String?
    private(set) var dealsByStage: [String: [CRMDeal]] = [:]
    private(set) var state: LoadState<Void> = .idle
    /// Used when the workspace has no pipelines: all deals grouped by stage.
    private(set) var unpipelinedDeals: [CRMDeal] = []
    private let api: CRMAPI

    init(api: CRMAPI) {
        self.api = api
    }

    var selectedPipeline: CRMPipeline? { pipelines.first { $0.uuid == selectedPipelineUuid } }

    /// Columns from the pipeline definition, plus any stage names that only appear on deals.
    var stages: [String] {
        let defined = selectedPipeline?.orderedStages.map(\.name) ?? []
        let source = selectedPipeline == nil ? Dictionary(grouping: unpipelinedDeals, by: \.stage) : dealsByStage
        let extra = source.keys.filter { !defined.contains($0) }.sorted()
        return defined + extra
    }

    func deals(in stage: String) -> [CRMDeal] {
        if selectedPipeline == nil {
            return unpipelinedDeals.filter { $0.stage == stage }
        }
        return dealsByStage[stage] ?? []
    }

    func load() async {
        if pipelines.isEmpty && unpipelinedDeals.isEmpty { state = .loading }
        do {
            pipelines = try await api.pipelines()
            if selectedPipelineUuid == nil || !pipelines.contains(where: { $0.uuid == selectedPipelineUuid }) {
                selectedPipelineUuid = (pipelines.first { $0.isDefault } ?? pipelines.first)?.uuid
            }
            try await loadDeals()
            state = .loaded(())
        } catch {
            state = .failed(error.asAPIError)
        }
    }

    func loadDeals() async throws {
        if let uuid = selectedPipelineUuid {
            dealsByStage = try await api.dealsByStage(pipelineUuid: uuid)
        } else {
            unpipelinedDeals = try await api.deals(page: 1, perPage: 100).items
        }
        if selectedStage == nil || !stages.contains(selectedStage!) {
            selectedStage = stages.first
        }
    }

    func move(_ deal: CRMDeal, to stage: String) async throws {
        _ = try await api.updateDeal(deal.uuid, DealBody(stage: stage,
                                                         probability: selectedPipeline?.stages.first { $0.name == stage }?.probability))
        try await loadDeals()
    }
}

struct DealPipelineView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false

    var body: some View {
        ModelHost(make: { DealPipelineViewModel(api: services.crm) }) { model in
            DealPipelineContent(model: model)
                .sheet(isPresented: $creating) {
                    CRMDealForm(deal: nil, pipeline: model.selectedPipeline) { body in
                        let created = try await services.crm.createDeal(body)
                        try? await model.loadDeals()
                        return created
                    }
                }
        }
        .navigationTitle("Pipeline")
        .toolbar {
            if session.canCreateCRM {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New deal", systemImage: "plus") { creating = true }
                }
            }
        }
    }
}

private struct DealPipelineContent: View {
    @Bindable var model: DealPipelineViewModel
    @Environment(SessionStore.self) private var session
    @State private var moveError: APIError?

    var body: some View {
        List {
            if model.pipelines.count > 1 {
                Picker("Pipeline", selection: $model.selectedPipelineUuid) {
                    ForEach(model.pipelines) { Text($0.name).tag(Optional($0.uuid)) }
                }
            }
            if !model.stages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.stages, id: \.self) { stage in
                            let selected = model.selectedStage == stage
                            Button {
                                model.selectedStage = stage
                            } label: {
                                Text("\(Formatters.humanize(stage)) · \(model.deals(in: stage).count)")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .background(selected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            if let moveError {
                InlineErrorRow(error: moveError)
            }
            if let stage = model.selectedStage {
                let deals = model.deals(in: stage)
                Section("\(Formatters.humanize(stage)) — \(Formatters.money(deals.reduce(0) { $0 + $1.value }, currency: deals.first?.currency) ?? "")") {
                    if deals.isEmpty {
                        Text("No deals in this stage").foregroundStyle(.secondary)
                    }
                    ForEach(deals) { deal in
                        NavigationLink { CRMDealDetailView(dealUuid: deal.uuid) } label: { DealRow(deal: deal) }
                            .contextMenu {
                                if session.permissions.can(.update, .crmAccounts) {
                                    moveMenu(deal)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                if session.permissions.can(.update, .crmAccounts), let next = nextStage(after: stage) {
                                    Button("Move to \(Formatters.humanize(next))") {
                                        Task { await move(deal, to: next) }
                                    }
                                    .tint(.indigo)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            switch model.state {
            case .idle, .loading:
                SkeletonList()
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded where model.stages.isEmpty:
                ContentUnavailableView("No deals yet", systemImage: "briefcase",
                                       description: Text(model.pipelines.isEmpty ? "This workspace has no pipelines." : "Create a deal to start the pipeline."))
            default:
                EmptyView()
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .onChange(of: model.selectedPipelineUuid) { _, _ in
            Task { try? await model.loadDeals() }
        }
    }

    @ViewBuilder
    private func moveMenu(_ deal: CRMDeal) -> some View {
        ForEach(model.stages.filter { $0 != deal.stage }, id: \.self) { stage in
            Button("Move to \(Formatters.humanize(stage))") { Task { await move(deal, to: stage) } }
        }
    }

    private func nextStage(after stage: String) -> String? {
        guard let index = model.stages.firstIndex(of: stage), index + 1 < model.stages.count else { return nil }
        return model.stages[index + 1]
    }

    private func move(_ deal: CRMDeal, to stage: String) async {
        do {
            try await model.move(deal, to: stage)
            moveError = nil
        } catch {
            moveError = error.asAPIError
        }
    }
}

struct CRMDealDetailView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<CRMDeal> = .idle
    @State private var editing = false
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var markingLost = false
    @State private var lostReason = ""

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let deal):
                content(deal)
            }
        }
        .navigationTitle("Deal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.canUpdateCRM, state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let deal = state.value {
                CRMDealForm(deal: deal, pipeline: nil) { body in
                    let updated = try await services.crm.updateDeal(deal.uuid, body)
                    state = .loaded(updated)
                    return updated
                }
            }
        }
        .alert("Mark as lost", isPresented: $markingLost) {
            TextField("Reason (optional)", text: $lostReason)
            Button("Mark lost", role: .destructive) {
                let reason = lostReason
                Task { await update(DealBody(stage: "lost", lostReason: reason.isEmpty ? nil : reason)) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func content(_ deal: CRMDeal) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(deal.name).font(.title2.bold())
                    Text(Formatters.money(deal.value, currency: deal.currency) ?? "")
                        .font(.title3.monospacedDigit())
                    HStack {
                        deal.statusBadge
                        StatusBadge(text: Formatters.humanize(deal.stage), systemImage: "flag", tone: .progress)
                    }
                }
                .padding(.vertical, 4)
            }
            if session.canUpdateCRM {
                Section("Stage") {
                    if !deal.pipelineStages.isEmpty {
                        Menu {
                            ForEach(deal.pipelineStages.map(\.name).filter { $0 != deal.stage }, id: \.self) { stage in
                                Button(Formatters.humanize(stage)) { Task { await update(DealBody(stage: stage)) } }
                            }
                        } label: {
                            Label("Move to stage…", systemImage: "arrow.right.circle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                    if deal.status == .open {
                        Button { Task { await update(DealBody(stage: "won")) } } label: {
                            Label("Mark won", systemImage: "trophy.fill")
                        }
                        .buttonStyle(.large(.success, prominent: false))
                        .listRowSeparator(.hidden)
                        Button { lostReason = ""; markingLost = true } label: {
                            Label("Mark lost", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.large(.danger, prominent: false))
                        .listRowSeparator(.hidden)
                    } else {
                        Button("Reopen deal") { Task { await update(DealBody(stage: "new", status: "open")) } }
                            .frame(minHeight: 44)
                    }
                    if let actionError { InlineErrorRow(error: actionError) }
                }
                .disabled(busy)
            }
            Section("Details") {
                DetailRow(label: "Account", value: deal.accountName, systemImage: "building.2")
                DetailRow(label: "Contact", value: deal.contactName, systemImage: "person")
                if let email = deal.contactEmail { EmailLinkRow(email: email) }
                DetailRow(label: "Pipeline", value: deal.pipelineName)
                DetailRow(label: "Probability", value: "\(deal.probability)%")
                DetailRow(label: "Expected close", value: deal.expectedCloseDate.flatMap { Formatters.day($0.date()) })
                DetailRow(label: "Closed", value: deal.actualCloseDate.flatMap { Formatters.day($0.date()) })
                DetailRow(label: "Lost reason", value: deal.lostReason)
            }
            if session.canDeleteCRM {
                Section {
                    DeleteButton(title: "Delete deal", message: "This removes the deal from the pipeline.") {
                        do {
                            try await services.crm.deleteDeal(deal.uuid)
                            return true
                        } catch {
                            actionError = error.asAPIError
                            return false
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.crm.deal(dealUuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func update(_ body: DealBody) async {
        busy = true
        defer { busy = false }
        do {
            state = .loaded(try await services.crm.updateDeal(dealUuid, body))
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }
}

struct CRMDealForm: View {
    let deal: CRMDeal?
    let pipeline: CRMPipeline?
    let save: (DealBody) async throws -> CRMDeal
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var value: Decimal
    @State private var currency: String
    @State private var probability: Int
    @State private var accountId: Int?
    @State private var hasCloseDate: Bool
    @State private var closeDate: Date
    @State private var saving = false
    @State private var error: APIError?

    init(deal: CRMDeal?, pipeline: CRMPipeline?, save: @escaping (DealBody) async throws -> CRMDeal) {
        self.deal = deal
        self.pipeline = pipeline
        self.save = save
        _name = State(initialValue: deal?.name ?? "")
        _value = State(initialValue: deal?.value ?? 0)
        _currency = State(initialValue: deal?.currency ?? "GBP")
        _probability = State(initialValue: deal?.probability ?? 10)
        _accountId = State(initialValue: deal?.accountId)
        _hasCloseDate = State(initialValue: deal?.expectedCloseDate != nil)
        _closeDate = State(initialValue: deal?.expectedCloseDate?.date() ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())!)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Deal") {
                    TextField("Name", text: $name)
                    TextField("Value", value: $value, format: .number)
                        .keyboardType(.decimalPad)
                    Picker("Currency", selection: $currency) {
                        ForEach(["GBP", "EUR", "USD"], id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Probability \(probability)%", value: $probability, in: 0...100, step: 10)
                }
                Section("Timing") {
                    Toggle("Expected close date", isOn: $hasCloseDate)
                    if hasCloseDate {
                        DatePicker("Close by", selection: $closeDate, displayedComponents: .date)
                    }
                }
                Section("Account") {
                    CRMAccountPicker(accountId: $accountId)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(deal == nil ? "New deal" : "Edit deal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { submit() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
    }

    private func submit() {
        saving = true
        error = nil
        var body = DealBody(name: name.trimmingCharacters(in: .whitespaces), value: value, currency: currency,
                            probability: probability, accountId: accountId)
        if hasCloseDate { body.expectedCloseDate = CalendarDay(date: closeDate) }
        if deal == nil {
            body.pipelineId = pipeline?.id
            body.stage = pipeline?.orderedStages.first?.name ?? "new"
        }
        Task {
            defer { saving = false }
            do {
                _ = try await save(body)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}
