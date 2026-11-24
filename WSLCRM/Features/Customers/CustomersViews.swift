import SwiftUI

// MARK: - Customers (`/api/v2/customers`, RBAC customers)

struct CustomersListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var creating = false
    @State private var sort: Sort = .newest
    @State private var box = SortBox()

    enum Sort: String, CaseIterable, Identifiable {
        case newest, oldest, name, email
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: "Newest first"
            case .oldest: "Oldest first"
            case .name: "Name A–Z"
            case .email: "Email A–Z"
            }
        }
        var orderBy: String {
            switch self {
            case .newest, .oldest: "created_at"
            case .name: "name"
            case .email: "email"
            }
        }
        var orderDir: String { self == .newest ? "desc" : "asc" }
    }

    @MainActor
    final class SortBox { var sort: Sort = .newest }

    var body: some View {
        ModelHost(make: { [commerce = services.commerce, box] in
            PagedListModel<Customer> { search, page in
                try await commerce.customers(search: search, orderBy: box.sort.orderBy, orderDir: box.sort.orderDir, page: page)
            }
        }) { model in
            PagedList(model: model, searchPrompt: "Name or email", emptyTitle: "No customers",
                      emptySystemImage: "person.crop.rectangle.stack",
                      emptyDescription: "People who buy from you. Tap + to add one.") { customer in
                NavigationLink {
                    CustomerDetailView(customerUuid: customer.uuid) { updated in
                        if let updated { model.replace(updated) } else { model.remove(id: customer.id) }
                    }
                } label: {
                    CustomerRow(customer: customer)
                }
                .accessibilityIdentifier("customers.row.\(customer.displayName)")
            }
            .onChange(of: sort) { _, value in
                box.sort = value
                Task { await model.load() }
            }
            .sheet(isPresented: $creating) {
                CustomerForm(customer: nil) { body in
                    let created = try await services.commerce.createCustomer(body)
                    await model.load()
                    return created
                }
            }
        }
        .navigationTitle("Customers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("customers.sort")
            }
            if session.permissions.can(.create, .customers) {
                ToolbarItem(placement: .primaryAction) {
                    Button("New customer", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("customers.new")
                }
            }
        }
    }
}

private struct CustomerRow: View {
    let customer: Customer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(customer.displayName).font(.wsHeadline)
                Spacer()
                if let state = customer.state, state != "enabled" {
                    StatusBadge(text: Formatters.humanize(state), systemImage: "pause.circle", tone: .neutral)
                }
            }
            if let line = [customer.email.trimmedOrNil, customer.phone].compactMap({ $0 }).joined(separator: " · ").trimmedOrNil {
                Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let place = [customer.primaryAddress?.city, customer.primaryAddress?.province, customer.primaryAddress?.country]
                .compactMap({ $0?.trimmedOrNil }).joined(separator: ", ").trimmedOrNil {
                Label(place, systemImage: "mappin").font(.wsCaption).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct CustomerDetailView: View {
    let customerUuid: String
    var onChange: (Customer?) -> Void = { _ in }
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<Customer> = .idle
    @State private var editing = false
    @State private var deleteError: APIError?
    @State private var notice: String?
    @State private var formResponses: [WebFormRecordResponse] = []
    @State private var billing = CustomerBilling()
    @State private var newInvoice = false
    @State private var newOrder = false
    @State private var openedInvoice: InvoiceRoute?
    @State private var openedOrder: CreatedStoreOrder?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let customer):
                content(customer)
            }
        }
        .navigationTitle("Customer")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: customerUuid) {
            formResponses = await WebFormRecordResponsesSection.load(services: services, session: session,
                                                                     entityType: "customer", entityUUID: customerUuid)
            billing = await CustomerBilling.load(services: services, session: session, customerUuid: customerUuid)
        }
        .sheet(isPresented: $newInvoice) {
            if let customer = state.value {
                InvoiceCreateSheet(prefill: PickedCustomer(customer)) { body in
                    let created = try await services.invoices.create(body)
                    openedInvoice = InvoiceRoute(uuid: created.id)
                    return created
                }
            }
        }
        .sheet(isPresented: $newOrder) {
            if let customer = state.value {
                CreateStoreOrderView(prefill: PickedCustomer(customer)) { created in openedOrder = created }
            }
        }
        .navigationDestination(item: $openedInvoice) { route in
            InvoiceDetailView(invoiceUuid: route.uuid, opening: "Invoice created as a draft. Check it, then email it to the customer.")
        }
        .navigationDestination(item: $openedOrder) { created in
            StoreOrderDetailView(uuid: created.uuid, orderNumber: created.orderNumber,
                                 opening: "Order \(created.orderNumber ?? "") created.")
        }
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if session.permissions.can(.update, .customers), state.value != nil {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true } }
            }
        }
        .sheet(isPresented: $editing) {
            if let customer = state.value {
                CustomerForm(customer: customer) { body in
                    let updated = try await services.commerce.updateCustomer(customer.uuid, body)
                    state = .loaded(updated)
                    onChange(updated)
                    notice = "Customer saved."
                    return updated
                }
            }
        }
    }

    private func content(_ customer: Customer) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(customer.displayName).font(.wsTitle2.bold())
                    HStack {
                        let state = customer.state ?? "enabled"
                        StatusBadge(text: Formatters.humanize(state), systemImage: state == "enabled" ? "checkmark.circle" : "pause.circle",
                                    tone: state == "enabled" ? .success : .neutral)
                        if customer.taxExempt { StatusBadge(text: "Tax exempt", systemImage: "percent", tone: .info) }
                    }
                }
                .padding(.vertical, 4)
                if let phone = customer.phone { PhoneLinkRow(name: customer.displayName, phone: phone) }
                if !customer.email.isEmpty { EmailLinkRow(email: customer.email) }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if canStartSale {
                Section {
                    if session.permissions.can(.create, .invoices) {
                        Button { newInvoice = true } label: { Label("New invoice", systemImage: "doc.badge.plus") }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("customer.newInvoice")
                    }
                    if session.permissions.can(.create, .orders) {
                        Button { newOrder = true } label: { Label("New order", systemImage: "cart.badge.plus") }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("customer.newOrder")
                    }
                    if canQuote {
                        NavigationLink {
                            ShopQuoteBuilderView(kind: .quote, customer: PickedCustomer(customer).shopDraft)
                        } label: {
                            Label("New quote", systemImage: "doc.text")
                        }
                        .accessibilityIdentifier("customer.newQuote")
                    }
                } header: {
                    Text("Sell to \(customer.displayName)")
                } footer: {
                    Text("Their name, email and address are filled in for you.")
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                    if canSeeOrders && !customer.email.isEmpty {
                        NavigationLink {
                            SalesOrdersView(search: customer.email)
                        } label: {
                            StatTile(title: "Orders", value: "\(customer.ordersCount)", systemImage: "bag")
                                .accessibilityHint("Shows this customer's orders")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("customer.orders")
                    } else {
                        StatTile(title: "Orders", value: "\(customer.ordersCount)", systemImage: "bag")
                    }
                    StatTile(title: "Total spent", value: Formatters.money(customer.totalSpent, currency: nil) ?? "0",
                             systemImage: "sterlingsign.circle")
                    StatTile(title: "Average order", value: Formatters.money(customer.averageOrderValue ?? 0, currency: nil) ?? "0",
                             systemImage: "chart.bar")
                    StatTile(title: "Last order", value: Formatters.day(customer.lastOrderDate) ?? "—", systemImage: "calendar")
                }
                .padding(.vertical, 4)
            }
            if !customer.addresses.isEmpty {
                Section("Addresses") {
                    ForEach(customer.addresses, id: \.self) { address in
                        VStack(alignment: .leading, spacing: 2) {
                            if address.isDefault == true { Text("Primary").font(.wsCaption).foregroundStyle(.secondaryText) }
                            MapsLinkRow(address: address.formatted)
                        }
                    }
                }
            }
            Section("Details") {
                DetailRow(label: "Date of birth", value: customer.dateOfBirth.flatMap { Formatters.day($0.date()) })
                DetailRow(label: "Tags", value: customer.tags)
                DetailRow(label: "Marketing", value: customer.acceptsMarketing ? "Opted in" : "Not opted in")
                DetailRow(label: "Opt-in level", value: customer.marketingOptInLevel.map(Formatters.humanize))
                DetailRow(label: "Email verified", value: customer.verifiedEmail ? "Yes" : "No")
                DetailRow(label: "Customer since", value: Formatters.day(customer.createdAt))
            }
            if let notes = customer.notes, !notes.isEmpty {
                Section("Notes") { Text(notes).textSelection(.enabled) }
            }
            CustomerBillingSection(billing: billing)
            // What this customer told us in the workspace's forms (as on the web's customer page).
            WebFormRecordResponsesSection(items: formResponses)
            if session.permissions.can(.delete, .customers) {
                Section {
                    DeleteButton(title: "Delete customer",
                                 message: "This permanently deletes the customer. Their orders are kept but unlinked.") {
                        do {
                            try await services.commerce.deleteCustomer(customer.uuid)
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

    private var canQuote: Bool {
        session.permissions.menuKeys.contains("shop") && session.permissions.can(.create, .shop)
    }

    private var canStartSale: Bool {
        session.permissions.can(.create, .invoices) || session.permissions.can(.create, .orders) || canQuote
    }

    /// Sales orders list shop orders with shop.read and store orders with orders.read.
    private var canSeeOrders: Bool {
        session.permissions.shows(.orders) || session.permissions.can(.read, .shop)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.commerce.customer(customerUuid))
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }
}

struct CustomerForm: View {
    let customer: Customer?
    let save: (CustomerBody) async throws -> Customer
    @Environment(\.dismiss) private var dismiss
    @State private var body_: CustomerBody
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @State private var address: CustomerBody.AddressBody
    @State private var saving = false
    @State private var error: APIError?

    static let states = [Choice("enabled", "Enabled"), Choice("disabled", "Disabled"), Choice("invited", "Invited"),
                         Choice("declined", "Declined")]
    static let optInLevels = [Choice("single_opt_in", "Single opt-in"), Choice("confirmed_opt_in", "Confirmed opt-in"),
                              Choice("unknown", "Unknown")]

    init(customer: Customer?, save: @escaping (CustomerBody) async throws -> Customer) {
        self.customer = customer
        self.save = save
        _body_ = State(initialValue: CustomerBody(
            email: customer?.email ?? "", firstName: customer?.firstName, lastName: customer?.lastName, phone: customer?.phone,
            notes: customer?.notes, tags: customer?.tags, acceptsMarketing: customer?.acceptsMarketing ?? false,
            verifiedEmail: customer?.verifiedEmail ?? false, taxExempt: customer?.taxExempt ?? false,
            marketingOptInLevel: customer?.marketingOptInLevel ?? "single_opt_in", state: customer?.state ?? "enabled"))
        _hasBirthday = State(initialValue: customer?.dateOfBirth != nil)
        _birthday = State(initialValue: customer?.dateOfBirth?.date() ?? Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date())
        let primary = customer?.primaryAddress
        _address = State(initialValue: primary.map(CustomerBody.AddressBody.init)
            ?? CustomerBody.AddressBody(address1: nil, address2: nil, city: nil, province: nil, zip: nil, country: nil, isDefault: true))
    }

    /// The body sent: the primary address first, the customer's other addresses kept as they were (up to 10 in all).
    static func finalBody(_ body: CustomerBody, address: CustomerBody.AddressBody, birthday: Date?,
                          existing: [CustomerAddress]) -> CustomerBody {
        var b = body
        b.email = b.email.trimmingCharacters(in: .whitespaces)
        b.dateOfBirth = birthday.map { CalendarDay(date: $0).isoString }
        var primary = address
        primary.isDefault = true
        let rest = existing.filter { $0.isDefault != true }.dropFirst(existing.contains { $0.isDefault == true } ? 0 : 1)
            .prefix(9).map(CustomerBody.AddressBody.init)
        b.addresses = (primary.isEmpty ? [] : [primary]) + rest
        return b
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    OptionalTextField("First name", text: $body_.firstName).textContentType(.givenName)
                    OptionalTextField("Last name", text: $body_.lastName).textContentType(.familyName)
                    Toggle("Date of birth", isOn: $hasBirthday)
                    if hasBirthday {
                        DatePicker("Born", selection: $birthday, in: ...Date(), displayedComponents: .date)
                    }
                }
                Section {
                    TextField("Email (needed)", text: $body_.email)
                        .keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                        .accessibilityIdentifier("customerForm.email")
                    OptionalTextField("Phone", text: $body_.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                } footer: {
                    Text("Email addresses must be unique.")
                }
                Section("Primary address") {
                    OptionalTextField("Address line 1", text: $address.address1).textContentType(.streetAddressLine1)
                    OptionalTextField("Address line 2", text: $address.address2).textContentType(.streetAddressLine2)
                    OptionalTextField("Town or city", text: $address.city).textContentType(.addressCity)
                    OptionalTextField("County or state", text: $address.province).textContentType(.addressState)
                    OptionalTextField("Postcode", text: $address.zip).textContentType(.postalCode)
                    OptionalTextField("Country", text: $address.country).textContentType(.countryName)
                }
                Section("Preferences") {
                    OptionalTextField("Tags, e.g. vip, wholesale", text: $body_.tags)
                    Picker("Account status", selection: Binding(get: { body_.state ?? "enabled" }, set: { body_.state = $0 })) {
                        ForEach(Self.states) { Text($0.label).tag($0.value) }
                    }
                    Picker("Marketing opt-in level", selection: Binding(get: { body_.marketingOptInLevel ?? "single_opt_in" },
                                                                        set: { body_.marketingOptInLevel = $0 })) {
                        ForEach(Self.optInLevels) { Text($0.label).tag($0.value) }
                    }
                    Toggle("Accepts marketing", isOn: Binding(get: { body_.acceptsMarketing ?? false }, set: { body_.acceptsMarketing = $0 }))
                    Toggle("Email verified", isOn: Binding(get: { body_.verifiedEmail ?? false }, set: { body_.verifiedEmail = $0 }))
                    Toggle("Tax exempt", isOn: Binding(get: { body_.taxExempt ?? false }, set: { body_.taxExempt = $0 }))
                }
                Section("Notes") {
                    TextField("Internal notes about this customer", text: Binding(get: { body_.notes ?? "" }, set: { body_.notes = $0 }),
                              axis: .vertical)
                        .lineLimit(2...6)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(customer == nil ? "New customer" : "Edit customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        error = nil
                        let body = Self.finalBody(body_, address: address, birthday: hasBirthday ? birthday : nil,
                                                  existing: customer?.addresses ?? [])
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
                    .disabled(!body_.email.contains("@") || saving)
                    .accessibilityIdentifier("customerForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}
