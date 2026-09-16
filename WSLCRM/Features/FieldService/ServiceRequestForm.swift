import SwiftUI

/// Create or edit a service request (opsapi #610 `RequestFormModal`): customer → site → the
/// faulty unit (asset = store product) and its serial, plus the complaint itself.
struct ServiceRequestFormSheet: View {
    let request: ServiceRequest?
    /// Pre-selects the unit when raised from the asset register.
    var initialProduct: Product?
    let onSaved: (ServiceRequestDetail) -> Void

    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var faultCategory: String
    @State private var reportedBy: String
    @State private var channel: String
    @State private var priority: JobPriority
    @State private var customer: CustomerChoice?
    @State private var site: FsSite?
    @State private var product: ProductChoice?
    @State private var productRef: String
    @State private var address: String
    @State private var postcode: String
    @State private var saving = false
    @State private var error: APIError?

    private let channels = ["phone", "email", "app", "portal", "web", "other"]

    struct CustomerChoice: Hashable { let uuid: String; let name: String }
    struct ProductChoice: Hashable { let uuid: String; let name: String }

    init(request: ServiceRequest?, initialProduct: Product? = nil, onSaved: @escaping (ServiceRequestDetail) -> Void) {
        self.request = request
        self.initialProduct = initialProduct
        self.onSaved = onSaved
        _title = State(initialValue: request?.title ?? "")
        _description = State(initialValue: request?.description ?? "")
        _faultCategory = State(initialValue: request?.faultCategory ?? "")
        _reportedBy = State(initialValue: request?.reportedBy ?? "")
        _channel = State(initialValue: request?.channel ?? "phone")
        _priority = State(initialValue: request.map { $0.priority == .unknown ? .normal : $0.priority } ?? .normal)
        _customer = State(initialValue: request?.customerUuid.map { CustomerChoice(uuid: $0, name: request?.customerName ?? "Customer") })
        _site = State(initialValue: request?.siteUuid.map {
            FsSite(uuid: $0, customerUuid: request?.customerUuid, name: request?.siteName ?? "Site", jobCount: 0)
        })
        _product = State(initialValue: request?.productUuid.map { ProductChoice(uuid: $0, name: request?.productName ?? "Unit") }
                         ?? initialProduct.map { ProductChoice(uuid: $0.uuid, name: $0.name) })
        _productRef = State(initialValue: request?.productRef ?? "")
        _address = State(initialValue: request?.serviceAddress ?? "")
        _postcode = State(initialValue: request?.servicePostcode ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Problem") {
                    TextField("What's wrong? e.g. Ward 5 chiller warm", text: $title)
                        .accessibilityIdentifier("request.title")
                    TextField("Details", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("request.description")
                    TextField("Fault category (optional)", text: $faultCategory)
                    Picker("Priority", selection: $priority) {
                        ForEach([JobPriority.low, .normal, .high, .urgent], id: \.self) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    CustomerPickerRow(selection: $customer)
                        .onChange(of: customer) { old, new in
                            if old?.uuid != new?.uuid { site = nil }
                        }
                    SitePickerRow(customerUuid: customer?.uuid, selection: $site)
                        .onChange(of: site) { _, new in
                            // Carry the site's address onto the request, as the dashboard does.
                            if let new {
                                address = [new.addressLine1, new.city].compactMap { $0 }.joined(separator: ", ")
                                postcode = new.postalCode ?? postcode
                            }
                        }
                } header: {
                    Text("Customer & site")
                } footer: {
                    Text("A site is a saved address under the customer — home, office, a hospital ward.")
                }

                Section("Faulty unit") {
                    AssetPickerRow(selection: $product)
                    TextField("Unit serial / reference", text: $productRef)
                        .textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("request.productRef")
                }

                Section("Contact") {
                    TextField("Reported by", text: $reportedBy).textContentType(.name)
                    Picker("Channel", selection: $channel) {
                        ForEach(channels, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                }

                Section("Service address") {
                    TextField("Address", text: $address, axis: .vertical).textContentType(.fullStreetAddress)
                    TextField("Postcode", text: $postcode).textContentType(.postalCode).textInputAutocapitalization(.characters)
                }

                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle(request == nil ? "New request" : "Edit request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request == nil ? "Create" : "Save") { submit() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .accessibilityIdentifier("request.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func submit() {
        let isEdit = request != nil
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // On edit an empty string clears the column; on create it's simply omitted.
            return t.isEmpty ? (isEdit ? "" : nil) : t
        }
        let body = ServiceRequestBody(
            title: title.trimmingCharacters(in: .whitespaces), description: clean(description), faultCategory: clean(faultCategory),
            channel: channel, reportedBy: clean(reportedBy), priority: priority.rawValue,
            customerUuid: customer?.uuid ?? (isEdit ? "" : nil), siteUuid: site?.uuid ?? (isEdit ? "" : nil),
            productUuid: product?.uuid ?? (isEdit ? "" : nil), productRef: clean(productRef),
            serviceAddress: clean(address), servicePostcode: clean(postcode))
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let saved = if let request {
                    try await services.fieldService.updateServiceRequest(request.uuid, body)
                } else {
                    try await services.fieldService.createServiceRequest(body)
                }
                onSaved(saved)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

/// Picks a customer. The customers endpoint has no search, so a page is filtered locally.
struct CustomerPickerRow: View {
    @Binding var selection: ServiceRequestFormSheet.CustomerChoice?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            LabeledContent {
                Text(selection?.name ?? "None").foregroundStyle(selection == nil ? .secondary : .primary)
            } label: {
                Label("Customer", systemImage: "person")
            }
        }
        .accessibilityIdentifier("request.customer")
        .sheet(isPresented: $picking) { CustomerPickerSheet(selection: $selection) }
    }
}

/// Customers, paged.
///
/// `GET /api/v2/customers` has no `search`, so searching means paging until the match turns up.
/// The picker loads a page at a time as the list scrolls, and while a search is active it keeps
/// pulling pages (up to `maxAutoPages`) until it finds matches or reaches the end — a workspace
/// with thousands of customers stays usable instead of being cut off at the first page.
@MainActor
@Observable
final class CustomerPickerModel {
    private(set) var loaded: [Customer] = []
    private(set) var total = 0
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var error: APIError?
    var search = ""

    private let api: CommerceAPI
    private var nextPage = 1
    private let pageSize = 100
    private let maxAutoPages = 20

    init(api: CommerceAPI) {
        self.api = api
    }

    var matches: [Customer] {
        guard !search.isEmpty else { return loaded }
        return loaded.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.email.localizedCaseInsensitiveContains(search)
        }
    }

    /// True while a search is still paging through customers it hasn't seen yet.
    var isSearchingRemainder: Bool { isLoading && !search.isEmpty }

    func loadNextPage() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.customers(page: nextPage, perPage: pageSize)
            loaded.append(contentsOf: page.items)
            total = max(total, page.total)
            nextPage += 1
            reachedEnd = page.items.isEmpty || loaded.count >= page.total
            error = nil
        } catch {
            self.error = error.asAPIError
            reachedEnd = true   // stop hammering a failing endpoint; the row offers a retry
        }
    }

    func retry() async {
        reachedEnd = false
        error = nil
        await loadNextPage()
    }

    /// Keeps paging while a search has nothing to show and there are pages left.
    func continueSearch() async {
        guard !search.isEmpty else { return }
        while matches.isEmpty, !reachedEnd, nextPage <= maxAutoPages, error == nil {
            await loadNextPage()
        }
    }
}

private struct CustomerPickerSheet: View {
    @Binding var selection: ServiceRequestFormSheet.CustomerChoice?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ModelHost(make: { CustomerPickerModel(api: services.commerce) }) { model in
                CustomerPickerList(model: model, selection: $selection, dismiss: dismiss)
            }
            .navigationTitle("Customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if selection != nil {
                    ToolbarItem(placement: .destructiveAction) { Button("Clear") { selection = nil; dismiss() } }
                }
            }
        }
    }
}

private struct CustomerPickerList: View {
    @Bindable var model: CustomerPickerModel
    @Binding var selection: ServiceRequestFormSheet.CustomerChoice?
    let dismiss: DismissAction

    var body: some View {
        List {
            if let error = model.error, model.loaded.isEmpty {
                InlineErrorRow(error: error) { Task { await model.retry() } }
            }
            ForEach(model.matches) { customer in
                Button {
                    selection = .init(uuid: customer.uuid, name: customer.displayName)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(customer.displayName).font(.headline).foregroundStyle(.primary)
                        Text(customer.email).font(.subheadline).foregroundStyle(.secondaryText)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("customer.row.\(customer.displayName)")
                .task {
                    // Load the next page as the end of the list comes into view.
                    if customer.id == model.matches.last?.id { await model.loadNextPage() }
                }
            }
            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.isSearchingRemainder ? "Searching \(model.total) customers…" : "Loading…")
                        .foregroundStyle(.secondaryText)
                }
            } else if model.matches.isEmpty {
                Text(model.search.isEmpty ? "No customers yet" : "No matching customers")
                    .foregroundStyle(.secondaryText)
            }
        }
        .searchable(text: $model.search, prompt: "Name or email")
        .task { await model.loadNextPage() }
        .task(id: model.search) {
            try? await Task.sleep(for: .milliseconds(250))   // let typing settle
            await model.continueSearch()
        }
    }
}

/// Picks the serviced unit from the asset register (store products).
struct AssetPickerRow: View {
    @Binding var selection: ServiceRequestFormSheet.ProductChoice?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            LabeledContent {
                Text(selection?.name ?? "None").foregroundStyle(selection == nil ? .secondary : .primary)
            } label: {
                Label("Unit / asset", systemImage: "wrench.adjustable")
            }
        }
        .accessibilityIdentifier("request.asset")
        .sheet(isPresented: $picking) {
            NavigationStack {
                AssetSearchView(mode: .pick { product in
                    selection = .init(uuid: product.uuid, name: product.name)
                    picking = false
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { picking = false } }
                    if selection != nil {
                        ToolbarItem(placement: .destructiveAction) { Button("Clear") { selection = nil; picking = false } }
                    }
                }
            }
        }
    }
}

/// Convert a request into a job and, optionally, assign the engineer by booking their first
/// visit — that moves the job to `scheduled` and puts it in their My Work (opsapi #610).
struct AssignConvertToJobSheet: View {
    let request: ServiceRequest
    let convert: (ConvertToJobBody) async -> ConvertToJobResult?
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var priority: JobPriority
    @State private var jobTypes: [JobType] = []
    @State private var members: [Engineer] = []
    @State private var jobTypeUuid: String?
    @State private var engineerUuid: String?
    @State private var managerUuid: String?
    @State private var firstVisit = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0,
                                                          of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!) ?? Date()
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var submitting = false

    init(request: ServiceRequest, convert: @escaping (ConvertToJobBody) async -> ConvertToJobResult?) {
        self.request = request
        self.convert = convert
        _title = State(initialValue: request.title)
        _priority = State(initialValue: request.priority == .unknown ? .normal : request.priority)
        _managerUuid = State(initialValue: request.assignedManagerUuid)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job title", text: $title)
                    Picker("Job type", selection: $jobTypeUuid) {
                        Text("None — add phases later").tag(String?.none)
                        ForEach(jobTypes) { type in
                            Text(type.phaseCount.map { "\(type.name) (\($0) phases)" } ?? type.name).tag(Optional(type.uuid))
                        }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach([JobPriority.low, .normal, .high, .urgent], id: \.self) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Job")
                } footer: {
                    Text("The customer, site and faulty unit carry over from \(request.requestNumber).")
                }

                Section {
                    Picker("Engineer", selection: $engineerUuid) {
                        Text("Assign later").tag(String?.none)
                        ForEach(members) { Text($0.pickerLabel).tag(Optional($0.uuid)) }
                    }
                    .accessibilityIdentifier("convert.engineer")
                    if engineerUuid != nil {
                        DatePicker("First visit", selection: $firstVisit, in: Date().addingTimeInterval(-3600)...)
                            .accessibilityIdentifier("convert.firstVisit")
                    }
                } header: {
                    Text("Assign the engineer")
                } footer: {
                    Text(engineerUuid == nil
                         ? "Pick an engineer to book their first visit now, or leave it and schedule later."
                         : "Books their first visit — the job is scheduled and appears in the engineer's My Work straight away.")
                }

                Section("Management") {
                    Picker("Service manager", selection: $managerUuid) {
                        Text("Unassigned").tag(String?.none)
                        ForEach(members) { Text($0.pickerLabel).tag(Optional($0.uuid)) }
                    }
                    Toggle("Due date", isOn: $hasDueDate)
                    if hasDueDate { DatePicker("Due", selection: $dueDate, displayedComponents: .date) }
                }
            }
            .navigationTitle("Convert to job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(engineerUuid == nil ? "Create job" : "Create & assign") { submit() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                        .accessibilityIdentifier("convert.submit")
                }
            }
            .task {
                async let types = services.fieldService.jobTypes()
                async let engineers = services.fieldService.engineers()
                jobTypes = (try? await types) ?? []
                members = (try? await engineers) ?? []
            }
            .interactiveDismissDisabled(submitting)
        }
    }

    private func submit() {
        submitting = true
        let body = ConvertToJobBody(title: title.trimmingCharacters(in: .whitespaces), priority: priority.rawValue,
                                    jobTypeUuid: jobTypeUuid, dueDate: hasDueDate ? CalendarDay(date: dueDate) : nil,
                                    serviceManagerUuid: managerUuid, engineerUuid: engineerUuid,
                                    scheduledStart: engineerUuid != nil ? firstVisit : nil)
        Task {
            let result = await convert(body)
            submitting = false
            if result != nil { dismiss() }
        }
    }
}
