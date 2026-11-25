import SwiftUI

// MARK: - Home

struct CRMHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: LoadState<CRMDashboardStats> = .idle

    var body: some View {
        List {
            // The figures come from deals (`GET /crm/dashboard/stats` needs crm_deals read).
            if session.permissions.can(.read, .crmDeals) {
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
            }
            Section {
                if session.permissions.shows(.leads) {
                    NavigationLink { LeadsHomeView() } label: {
                        Label("Leads", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                // The board lists pipelines (crm_pipelines) and then their deals (crm_deals).
                if session.permissions.can(.read, .crmDeals), session.permissions.can(.read, .crmPipelines) {
                    NavigationLink { DealPipelineView() } label: {
                        Label("Deal board", systemImage: "rectangle.split.3x1")
                    }
                    .accessibilityIdentifier("crm.board")
                }
                if session.permissions.can(.read, .crmDeals) {
                    NavigationLink { CRMDealsListView() } label: {
                        Label("All deals", systemImage: "briefcase")
                    }
                    .accessibilityIdentifier("crm.deals")
                }
                if session.permissions.can(.read, .crmAccounts) {
                    NavigationLink { CRMAccountsListView() } label: {
                        Label("Accounts", systemImage: "building.2")
                    }
                }
                if session.permissions.can(.read, .crmContacts) {
                    NavigationLink { CRMContactsListView() } label: {
                        Label("Contacts", systemImage: "person.crop.circle")
                    }
                }
                if session.permissions.can(.read, moduleName: "crm_activities") {
                    NavigationLink(value: ResourceListRoute(ModuleCatalog.crmActivities.id)) {
                        Label("Activities", systemImage: "calendar.badge.clock")
                    }
                    .accessibilityIdentifier("crm.activities")
                }
            }
            Section("Set up") {
                if session.permissions.can(.read, .crmPipelines) {
                    NavigationLink { CRMPipelinesView() } label: {
                        Label("Pipelines and stages", systemImage: "list.number")
                    }
                    .accessibilityIdentifier("crm.pipelines")
                }
                if session.permissions.can(.read, .crmAccounts) {
                    NavigationLink { PartnersHubView() } label: {
                        Label("Partners and referrals", systemImage: "person.2.badge.gearshape")
                    }
                    .accessibilityIdentifier("crm.partners")
                } else {
                    Label("Partners and referrals need access to accounts. Ask a workspace admin.", systemImage: "lock")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
        }
        .navigationTitle("CRM")
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private func load() async {
        guard session.permissions.can(.read, .crmDeals) else { return }
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
            StatTile(title: "Deal value", value: Formatters.money(stats.totalValue, currency: nil) ?? "0",
                     systemImage: "sterlingsign.circle")
            StatTile(title: "Won", value: "\(stats.wonDeals)", systemImage: "trophy")
            StatTile(title: "Win rate", value: "\(stats.winRate.formatted(.number.precision(.fractionLength(0...1))))%",
                     systemImage: "percent")
            StatTile(title: "Accounts", value: "\(stats.totalAccounts)", systemImage: "building.2")
            StatTile(title: "Activities today", value: "\(stats.activitiesToday)", systemImage: "calendar")
        }
        .padding(.vertical, 4)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Icon above the words: side by side, a narrow tile broke words mid-way ("Ope / n").
            Image(systemName: systemImage)
                .font(.wsFootnote.weight(.semibold))
                .foregroundStyle(Tone.brand.textColor)
                .frame(width: 28, height: 28)
                .background(Tone.brand.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(value)
                .font(.wsTitle.monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.wsFootnote)
                // `.secondary` is 60% of label colour: it fails the contrast audit on this card.
                .foregroundStyle(Color(.label).opacity(0.85))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// What the person may change, per CRM area: the server checks each one separately (opsapi #849).
extension SessionStore {
    func canCreate(_ module: Module) -> Bool { permissions.can(.create, module) }
    func canUpdate(_ module: Module) -> Bool { permissions.can(.update, module) }
    func canDelete(_ module: Module) -> Bool { permissions.can(.delete, module) }
}

/// "All / Active / Inactive" for accounts and contacts (`?status=`).
enum CRMRecordStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "", active, inactive
    var id: String { rawValue }
    var label: String { self == .all ? "All" : Formatters.humanize(rawValue) }
    var query: String? { self == .all ? nil : rawValue }
}

/// Lets a list's fetch closure read the current filter without capturing view state.
@MainActor
final class CRMFilterBox {
    var status: String?
    var pipelineId: Int?
}

// MARK: - Accounts

struct CRMAccountsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false
    @State private var filter: CRMRecordStatusFilter = .all
    @State private var box = CRMFilterBox()

    var body: some View {
        ModelHost(make: { [crm = services.crm, box] in
            PagedListModel<CRMAccount> { search, page in try await crm.accounts(search: search, status: box.status, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No accounts", emptySystemImage: "building.2",
                      emptyDescription: "Companies you work with.",
                      emptyActionTitle: "New account",
                      emptyAction: session.canCreate(.crmAccounts) ? { creating = true } : nil,
                      destination: { account in
                    CRMAccountDetailView(accountUuid: account.uuid) { updated in
                        if let updated { model.replace(updated) } else { model.remove(id: account.id) }
                    }
                }) { account in
                CRMAccountRow(account: account)
                .accessibilityIdentifier("crm.account.\(account.uuid)")
            }
            .onChange(of: filter) { _, value in
                box.status = value.query
                Task { await model.load() }
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
            ToolbarItem(placement: .topBarTrailing) { CRMStatusFilterMenu(filter: $filter) }
            if session.canCreate(.crmAccounts) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New account", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("crm.account.new")
                }
            }
        }
    }
}

struct CRMStatusFilterMenu: View {
    @Binding var filter: CRMRecordStatusFilter

    var body: some View {
        Menu {
            Picker("Status", selection: $filter) {
                ForEach(CRMRecordStatusFilter.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle"
                                                        : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("crm.filter")
    }
}

private struct CRMAccountRow: View {
    let account: CRMAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(account.name).font(.wsHeadline)
                Spacer()
                if account.status != "active" {
                    StatusBadge(text: Formatters.humanize(account.status), systemImage: "pause.circle", tone: .neutral)
                }
            }
            if let line = [account.industry, account.city, account.email].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
    @State private var addingContact = false
    @State private var addingDeal = false
    @State private var deleteError: APIError?
    @State private var reload = 0
    @State private var notice: String?

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
        .wsRefreshable { await load() }
        .toolbar {
            if session.canUpdate(.crmAccounts), state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let account = state.value {
                CRMAccountForm(account: account) { body in
                    let updated = try await services.crm.updateAccount(account.uuid, body)
                    state = .loaded(updated)
                    onChange(updated)
                    notice = "Account saved."
                    return updated
                }
            }
        }
        .sheet(isPresented: $addingContact) {
            if let account = state.value {
                CRMContactForm(contact: nil, presetAccountId: account.id, presetAccountName: account.name) { body in
                    let created = try await services.crm.createContact(body)
                    notice = "\(created.fullName) added to \(account.name)."
                    await load()
                    return created
                }
            }
        }
        .sheet(isPresented: $addingDeal) {
            if let account = state.value {
                CRMDealForm(deal: nil, pipeline: nil, presetAccountId: account.id, presetAccountName: account.name) { body in
                    let created = try await services.crm.createDeal(body)
                    notice = "Deal “\(created.name)” added."
                    await load()
                    return created
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
                    if let industry = account.industry { Text(industry).foregroundStyle(.secondaryText) }
                }
                if let phone = account.phone { PhoneLinkRow(name: account.name, phone: phone) }
                if let email = account.email { EmailLinkRow(email: email) }
                if let address = account.address { MapsLinkRow(address: address) }
                if let website = account.website, let url = URL(string: website.hasPrefix("http") ? website : "https://\(website)") {
                    Link(destination: url) { Label(website, systemImage: "globe").frame(minHeight: 44) }
                }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            Section("Summary") {
                DetailRow(label: "Contacts", value: account.contactCount.map(String.init))
                DetailRow(label: "Deals", value: account.dealCount.map(String.init))
                DetailRow(label: "Deal value", value: Formatters.money(account.totalDealValue, currency: nil))
                DetailRow(label: "Employees", value: account.employeeCount.map(String.init))
                DetailRow(label: "Annual revenue", value: Formatters.money(account.annualRevenue, currency: nil))
                DetailRow(label: "Added", value: Formatters.day(account.createdAt))
            }
            if session.permissions.can(.read, .crmContacts) {
                Section("Contacts") {
                    ForEach(contacts) { contact in
                        NavigationLink { CRMContactDetailView(contactUuid: contact.uuid) } label: {
                            VStack(alignment: .leading) {
                                Text(contact.fullName).font(.wsHeadline)
                                if let title = contact.jobTitle { Text(title).font(.wsSubheadline).foregroundStyle(.secondaryText) }
                            }
                        }
                    }
                    if contacts.isEmpty {
                        Text("No contacts at this account yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    if session.canCreate(.crmContacts) {
                        Button("Add a contact", systemImage: "person.badge.plus") { addingContact = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("crm.account.addContact")
                    }
                }
            }
            if session.permissions.can(.read, .crmDeals) {
                Section("Deals") {
                    ForEach(deals) { deal in
                        NavigationLink { CRMDealDetailView(dealUuid: deal.uuid) } label: { DealRow(deal: deal) }
                    }
                    if deals.isEmpty {
                        Text("No deals with this account yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    if session.canCreate(.crmDeals) {
                        Button("Add a deal", systemImage: "briefcase") { addingDeal = true }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("crm.account.addDeal")
                    }
                }
            }
            CRMActivitiesSection(relation: .account(id: account.id, uuid: account.uuid), reload: reload)
            if session.canDelete(.crmAccounts) {
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
            reload += 1
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
    @State private var revenue: String
    @State private var employees: String
    @State private var saving = false
    @State private var error: APIError?

    init(account: CRMAccount?, save: @escaping (AccountBody) async throws -> CRMAccount) {
        self.account = account
        self.save = save
        _body_ = State(initialValue: AccountBody(
            name: account?.name ?? "", industry: account?.industry, website: account?.website, phone: account?.phone,
            email: account?.email, addressLine1: account?.addressLine1, addressLine2: account?.addressLine2,
            city: account?.city, state: account?.state, postalCode: account?.postalCode, country: account?.country,
            status: account?.status ?? "active"))
        _revenue = State(initialValue: account?.annualRevenue.map { "\($0)" } ?? "")
        _employees = State(initialValue: account?.employeeCount.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name (needed)", text: $body_.name)
                        .accessibilityIdentifier("crm.accountForm.name")
                    OptionalTextField("Industry", text: $body_.industry)
                    Picker("Status", selection: Binding(get: { body_.status ?? "active" }, set: { body_.status = $0 })) {
                        Text("Active").tag("active")
                        Text("Inactive").tag("inactive")
                    }
                }
                Section("Contact details") {
                    OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    OptionalTextField("Email", text: $body_.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    OptionalTextField("Website", text: $body_.website).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Section("Address") {
                    OptionalTextField("Street", text: $body_.addressLine1).textContentType(.streetAddressLine1)
                    OptionalTextField("Suite, unit, building", text: $body_.addressLine2).textContentType(.streetAddressLine2)
                    OptionalTextField("Town or city", text: $body_.city).textContentType(.addressCity)
                    OptionalTextField("County or state", text: $body_.state).textContentType(.addressState)
                    OptionalTextField("Postcode", text: $body_.postalCode).textContentType(.postalCode)
                    OptionalTextField("Country", text: $body_.country).textContentType(.countryName)
                }
                Section("Size") {
                    TextField("Employees", text: $employees).keyboardType(.numberPad)
                    TextField("Annual revenue", text: $revenue).keyboardType(.decimalPad)
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
                        .accessibilityIdentifier("crm.accountForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func submit() {
        saving = true
        error = nil
        var body = body_
        body.annualRevenue = Decimal(string: revenue.replacingOccurrences(of: ",", with: ""))
        body.employeeCount = Int(employees.trimmingCharacters(in: .whitespaces))
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
    @State private var filter: CRMRecordStatusFilter = .all
    @State private var box = CRMFilterBox()

    var body: some View {
        ModelHost(make: { [crm = services.crm, box] in
            PagedListModel<CRMContact> { search, page in try await crm.contacts(search: search, status: box.status, page: page) }
        }) { model in
            PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No contacts", emptySystemImage: "person.crop.circle",
                      emptyDescription: "The people at your accounts.",
                      emptyActionTitle: "New contact",
                      emptyAction: session.canCreate(.crmContacts) ? { creating = true } : nil,
                      destination: { contact in
                    CRMContactDetailView(contactUuid: contact.uuid)
                }) { contact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.fullName).font(.wsHeadline)
                    if let line = [contact.jobTitle, contact.accountName, contact.email].compactMap({ $0 })
                        .joined(separator: " · ").nonEmpty {
                        Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("crm.contact.\(contact.uuid)")
            }
            .onChange(of: filter) { _, value in
                box.status = value.query
                Task { await model.load() }
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
            ToolbarItem(placement: .topBarTrailing) { CRMStatusFilterMenu(filter: $filter) }
            if session.canCreate(.crmContacts) {
                ToolbarItem(placement: .primaryAction) {
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
    @State private var reload = 0
    @State private var accountUuid: String?

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
                            Text(contact.fullName).font(.wsTitle2.bold())
                            if let line = [contact.jobTitle, contact.department].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                                Text(line).foregroundStyle(.secondaryText)
                            }
                            if contact.status != "active" {
                                StatusBadge(text: Formatters.humanize(contact.status), systemImage: "pause.circle", tone: .neutral)
                            }
                        }
                        if let account = contact.accountName {
                            if let accountUuid, session.permissions.can(.read, .crmAccounts) {
                                NavigationLink { CRMAccountDetailView(accountUuid: accountUuid) } label: {
                                    Label(account, systemImage: "building.2")
                                }
                            } else {
                                Label(account, systemImage: "building.2")
                            }
                        }
                    }
                    Section("Reach") {
                        if let mobile = contact.mobile { PhoneLinkRow(name: "Mobile", phone: mobile) }
                        if let phone = contact.phone { PhoneLinkRow(name: "Phone", phone: phone) }
                        if let email = contact.email { EmailLinkRow(email: email) }
                        if contact.mobile == nil && contact.phone == nil && contact.email == nil {
                            Text("No phone or email yet. Tap Edit to add them.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                    }
                    CRMActivitiesSection(relation: .contact(id: contact.id, uuid: contact.uuid), reload: reload)
                    if session.canDelete(.crmContacts) {
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
        .wsRefreshable { await load() }
        .toolbar {
            if session.canUpdate(.crmContacts), state.value != nil {
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
            let contact = try await services.crm.contact(contactUuid)
            state = .loaded(contact)
            reload += 1
            // Contacts carry the account's numeric id only; find its uuid to open it.
            if let accountId = contact.accountId, accountUuid == nil, session.permissions.can(.read, .crmAccounts) {
                let accounts = (try? await services.crm.accounts(search: contact.accountName ?? "", page: 1, perPage: 50).items) ?? []
                accountUuid = accounts.first { $0.id == accountId }?.uuid
            }
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
    private let accountName: String?

    init(contact: CRMContact?, presetAccountId: Int? = nil, presetAccountName: String? = nil,
         save: @escaping (ContactBody) async throws -> CRMContact) {
        self.contact = contact
        self.accountName = contact?.accountName ?? presetAccountName
        self.save = save
        _body_ = State(initialValue: ContactBody(firstName: contact?.firstName ?? "", lastName: contact?.lastName,
                                                 email: contact?.email, phone: contact?.phone, mobile: contact?.mobile,
                                                 jobTitle: contact?.jobTitle, department: contact?.department,
                                                 status: contact?.status ?? "active",
                                                 accountId: contact?.accountId ?? presetAccountId))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("First name (needed)", text: $body_.firstName).textContentType(.givenName)
                        .accessibilityIdentifier("crm.contactForm.firstName")
                    OptionalTextField("Last name", text: $body_.lastName).textContentType(.familyName)
                    OptionalTextField("Job title", text: $body_.jobTitle).textContentType(.jobTitle)
                    OptionalTextField("Department", text: $body_.department)
                }
                Section("Reach") {
                    OptionalTextField("Mobile", text: $body_.mobile).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad)
                    OptionalTextField("Email", text: $body_.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("Account") {
                    CRMAccountPicker(accountId: $body_.accountId, name: accountName)
                    Picker("Status", selection: Binding(get: { body_.status ?? "active" }, set: { body_.status = $0 })) {
                        Text("Active").tag("active")
                        Text("Inactive").tag("inactive")
                    }
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
                    .accessibilityIdentifier("crm.contactForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

/// Picks an account, saved by its numeric id (the only link form CRM updates accept): search every account.
struct CRMAccountPicker: View {
    @Binding var accountId: Int?
    /// The current account's name, when the record carries it.
    var name: String?
    @State private var chosen: String??
    @State private var picking = false

    static let spec = ReferenceSpec(list: "\(CRMAPI.base)/accounts", valueKey: "id", titleKeys: ["name"],
                                    subtitleKeys: ["industry", "city"], paging: .pageAndPerPage)

    var body: some View {
        Button { picking = true } label: {
            LabeledContent("Account") {
                Text(accountId == nil ? "None" : (chosen ?? name) ?? "Chosen")
                    .foregroundStyle(accountId == nil ? Color.secondaryText : Color.primary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("crm.picker.account")
        .sheet(isPresented: $picking) {
            NavigationStack {
                ReferencePicker(title: "Choose an account", spec: Self.spec) { record in
                    accountId = record.int("id")
                    chosen = .some(record.string("name"))
                } clear: {
                    accountId = nil
                    chosen = .some(nil)
                }
            }
        }
    }
}

/// Picks a contact, saved by numeric id: search the chosen account's people, or everyone when there is none.
struct CRMContactPicker: View {
    @Binding var contactId: Int?
    var accountId: Int?
    /// The current contact's name, when the record carries it.
    var name: String?
    @State private var chosen: String??
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            LabeledContent("Contact") {
                Text(contactId == nil ? "None" : (chosen ?? name) ?? "Chosen")
                    .foregroundStyle(contactId == nil ? Color.secondaryText : Color.primary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("crm.picker.contact")
        .sheet(isPresented: $picking) {
            NavigationStack {
                CRMContactChoices(accountId: accountId) { contact in
                    contactId = contact?.id
                    chosen = .some(contact?.fullName)
                    picking = false
                }
            }
        }
    }
}

/// The kit's picker can't filter by account, so contacts are listed here from the typed API
/// (`GET /crm/contacts?account_id=&search=&page=&per_page=`).
private struct CRMContactChoices: View {
    let accountId: Int?
    let pick: (CRMContact?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ModelHost(make: { [crm = services.crm, accountId] in
            PagedListModel<CRMContact> { search, page in
                try await crm.contacts(search: search, accountId: accountId, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No contacts",
                      emptySystemImage: "person.crop.circle",
                      emptyDescription: accountId == nil ? "Add people under Contacts first."
                                                         : "This account has no contacts yet. Add one on the account.") { contact in
                Button { pick(contact) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.fullName).font(.wsHeadline)
                        if let detail = [contact.accountName, contact.email].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                            Text(detail).font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityIdentifier("crm.picker.contact.\(contact.id)")
            }
        }
        .navigationTitle(accountId == nil ? "Choose a contact" : "Choose from the account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) { Button("None") { pick(nil) } }
        }
    }
}

extension String {
    /// nil for an empty string, so optional chains can skip it.
    var nonEmpty: String? { isEmpty ? nil : self }
}
