import SwiftUI

// MARK: - List

@MainActor
@Observable
final class ServiceRequestsListViewModel {
    enum Filter: String, CaseIterable, Identifiable {
        case open, all, new, assigned
        case inProgress = "in_progress"
        case resolved, closed

        var id: String { rawValue }
        var title: String { self == .open ? "Open" : self == .all ? "All" : Formatters.humanize(rawValue) }
    }

    var filter: Filter = .open
    var search = ""
    private(set) var items: [ServiceRequest] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var lastPage: Page<ServiceRequest>?
    private(set) var pageError: APIError?
    private(set) var isLoadingMore = false
    private let api: FieldServiceAPI

    init(api: FieldServiceAPI) {
        self.api = api
    }

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            let page = try await api.serviceRequests(status: filter.rawValue, search: search, page: 1)
            items = page.items
            lastPage = page
            pageError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if items.isEmpty { state = .failed(apiError) } else { pageError = apiError }
        }
    }

    func loadMoreIfNeeded(_ item: ServiceRequest) async {
        guard let lastPage, lastPage.hasMore, !isLoadingMore, item.id == items.last?.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.serviceRequests(status: filter.rawValue, search: search, page: lastPage.page + 1)
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            self.lastPage = page
        } catch {
            pageError = error.asAPIError
        }
    }
}

struct ServiceRequestsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: ServiceRequestsListViewModel?
    @State private var creating = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Service requests")
        .toolbar {
            if session.policy.canCreateServiceRequest {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New request", systemImage: "plus") { creating = true }
                        .accessibilityIdentifier("requests.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NewServiceRequestSheet { created in
                creating = false
                Task { await model?.load() }
                _ = created
            }
        }
        .onAppear {
            if model == nil { model = ServiceRequestsListViewModel(api: services.fieldService) }
        }
    }

    private func content(_ model: ServiceRequestsListViewModel) -> some View {
        @Bindable var model = model
        return List {
            ForEach(model.items) { request in
                NavigationLink(value: ServiceRequestRoute(uuid: request.uuid)) {
                    ServiceRequestRow(request: request)
                }
                .task { await model.loadMoreIfNeeded(request) }
            }
            if model.isLoadingMore { HStack { Spacer(); ProgressView(); Spacer() } }
            if let error = model.pageError {
                InlineErrorRow(error: error) { Task { await model.load() } }
            }
        }
        .listStyle(.plain)
        .overlay {
            switch model.state {
            case .idle:
                SkeletonList()
            case .loading where model.items.isEmpty:
                SkeletonList()
            case .failed(let error) where model.items.isEmpty:
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded where model.items.isEmpty:
                ContentUnavailableView("No service requests", systemImage: "exclamationmark.bubble",
                                       description: Text(model.filter == .open ? "Nothing open right now." : "Try another filter."))
            default:
                EmptyView()
            }
        }
        .searchable(text: $model.search, prompt: "Number, title, customer")
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Filter", selection: $model.filter) {
                    ForEach(ServiceRequestsListViewModel.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .task(id: "\(model.filter.rawValue)|\(model.search)") {
            if !model.items.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }
}

struct ServiceRequestRow: View {
    let request: ServiceRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.requestNumber)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                if request.priority == .urgent || request.priority == .high {
                    request.priority.badge
                }
                Spacer()
                request.status.badge
            }
            Text(request.title).font(.headline).lineLimit(2)
            if let customer = request.customerName {
                Label(customer, systemImage: "person").font(.subheadline)
            }
            HStack(spacing: 12) {
                Label(Formatters.humanize(request.channel), systemImage: "phone.arrow.down.left")
                if request.slaBreached {
                    Label("SLA breached", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.danger.color)
                }
                if let created = request.createdAt {
                    Text(Formatters.relative(created) ?? "")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

@MainActor
@Observable
final class ServiceRequestDetailViewModel {
    let uuid: String
    private(set) var state: LoadState<ServiceRequestDetail> = .idle
    private(set) var busy = false
    var actionError: APIError?
    var convertedJobUuid: String?
    private let api: FieldServiceAPI

    init(uuid: String, api: FieldServiceAPI) {
        self.uuid = uuid
        self.api = api
    }

    func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await api.serviceRequest(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }

    func setStatus(_ status: ServiceRequestStatus, resolutionNotes: String?) async {
        busy = true
        defer { busy = false }
        do {
            state = .loaded(try await api.setServiceRequestStatus(uuid, body: ServiceRequestStatusBody(
                status: status.rawValue, resolutionNotes: resolutionNotes?.isEmpty == false ? resolutionNotes : nil)))
        } catch {
            actionError = error.asAPIError
        }
    }

    func assign(to engineer: Engineer) async {
        busy = true
        defer { busy = false }
        do {
            state = .loaded(try await api.assignServiceRequest(uuid, managerUuid: engineer.uuid))
        } catch {
            actionError = error.asAPIError
        }
    }

    func convert(_ body: ConvertToJobBody) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let result = try await api.convertToJob(uuid, body: body)
            convertedJobUuid = result.jobUuid
            await load()
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

struct ServiceRequestDetailView: View {
    let requestUuid: String
    @Environment(\.services) private var services
    @State private var model: ServiceRequestDetailViewModel?

    var body: some View {
        Group {
            if let model {
                ServiceRequestDetailContent(model: model)
            } else {
                SkeletonList(rows: 3)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if model == nil { model = ServiceRequestDetailViewModel(uuid: requestUuid, api: services.fieldService) }
        }
    }
}

private struct ServiceRequestDetailContent: View {
    @Bindable var model: ServiceRequestDetailViewModel
    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var pendingStatus: ServiceRequestStatus?
    @State private var resolutionNotes = ""
    @State private var showingConvert = false
    @State private var showingAssign = false
    @State private var openJob: JobRoute?

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                SkeletonList(rows: 3)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded(let detail):
                loaded(detail)
            }
        }
        .navigationTitle(model.state.value?.request.requestNumber ?? "Request")
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Couldn't update the request", isPresented: .init(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }),
               presenting: model.actionError) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.localizedDescription)
        }
        .alert(pendingStatus?.actionTitle ?? "", isPresented: .init(get: { pendingStatus != nil }, set: { if !$0 { pendingStatus = nil } }),
               presenting: pendingStatus) { status in
            TextField("Resolution notes (optional)", text: $resolutionNotes)
            Button(status.actionTitle) {
                let notes = resolutionNotes
                resolutionNotes = ""
                Task { await model.setStatus(status, resolutionNotes: notes) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingConvert) {
            if let detail = model.state.value {
                ConvertToJobSheet(request: detail.request) { body in await model.convert(body) }
            }
        }
        .sheet(isPresented: $showingAssign) {
            EngineerPickerSheet(title: "Assign manager") { engineer in
                Task { await model.assign(to: engineer) }
            }
        }
        .onChange(of: model.convertedJobUuid) { _, uuid in
            if let uuid { openJob = JobRoute(uuid: uuid) }
        }
        .navigationDestination(item: $openJob) { route in
            JobDetailView(jobUuid: route.uuid)
        }
    }

    private func loaded(_ detail: ServiceRequestDetail) -> some View {
        let request = detail.request
        let policy = session.policy
        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(request.title).font(.title2.bold())
                    HStack {
                        request.status.badge
                        if request.priority != .normal { request.priority.badge }
                        if request.slaBreached {
                            StatusBadge(text: "SLA breached", systemImage: "exclamationmark.triangle.fill", tone: .danger)
                        }
                    }
                    if let description = request.description {
                        Text(description).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if policy.canUpdateServiceRequests, !detail.allowedTransitions.isEmpty {
                Section("Actions") {
                    ForEach(detail.allowedTransitions, id: \.self) { status in
                        Button {
                            if status == .resolved || status == .closed {
                                pendingStatus = status
                            } else {
                                Task { await model.setStatus(status, resolutionNotes: nil) }
                            }
                        } label: {
                            Label(status.actionTitle, systemImage: status.systemImage)
                        }
                        .buttonStyle(.large(status.tone == .neutral ? .info : status.tone, prominent: false))
                        .disabled(model.busy)
                        .listRowSeparator(.hidden)
                    }
                }
            }

            if policy.canConvertServiceRequests, request.status.canConvertToJob {
                Section {
                    Button {
                        showingConvert = true
                    } label: {
                        Label("Convert to job", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .buttonStyle(.large(.progress))
                    .disabled(model.busy)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("request.convert")
                }
            }

            Section("Customer") {
                DetailRow(label: "Name", value: request.customerName, systemImage: "person")
                if let phone = request.customerPhone {
                    PhoneLinkRow(name: request.customerName, phone: phone)
                }
                DetailRow(label: "Email", value: request.customerEmail, systemImage: "envelope")
                if let address = request.fullAddress {
                    MapsLinkRow(address: address)
                }
                DetailRow(label: "Reported by", value: request.reportedBy)
                DetailRow(label: "Channel", value: Formatters.humanize(request.channel))
                DetailRow(label: "Category", value: request.faultCategory)
                DetailRow(label: "Product", value: [request.productName, request.productRef].compactMap { $0 }.joined(separator: " · "))
            }

            Section("Handling") {
                LabeledContent("Manager") {
                    HStack {
                        Text(request.assignedManagerName ?? "Unassigned")
                        if policy.canUpdateServiceRequests {
                            Button("Change") { showingAssign = true }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                DetailRow(label: "Respond by", value: Formatters.dateTime(request.slaResponseDueAt))
                DetailRow(label: "Resolve by", value: Formatters.dateTime(request.slaResolveDueAt))
                DetailRow(label: "Resolution", value: request.resolutionNotes)
            }

            if !detail.jobs.isEmpty {
                Section("Jobs") {
                    ForEach(detail.jobs) { job in
                        NavigationLink(value: JobRoute(uuid: job.uuid)) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(job.jobNumber ?? "Job").font(.headline)
                                    Text(job.title ?? "").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                JobStatus(api: job.status).badge
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Sheets

struct ConvertToJobSheet: View {
    let request: ServiceRequest
    let convert: (ConvertToJobBody) async -> Bool
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var priority: JobPriority
    @State private var jobTypes: [JobType] = []
    @State private var jobTypeUuid: String?
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var submitting = false

    init(request: ServiceRequest, convert: @escaping (ConvertToJobBody) async -> Bool) {
        self.request = request
        self.convert = convert
        _title = State(initialValue: request.title)
        _priority = State(initialValue: request.priority == .unknown ? .normal : request.priority)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Priority", selection: $priority) {
                        ForEach([JobPriority.low, .normal, .high, .urgent], id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Job type", selection: $jobTypeUuid) {
                        Text("None").tag(String?.none)
                        ForEach(jobTypes) { Text($0.name).tag(Optional($0.uuid)) }
                    }
                    Toggle("Due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                    }
                } header: {
                    Text("Job")
                } footer: {
                    Text("The job type adds its standard phases. Customer, product and address are copied from the request.")
                }
                Section {
                    Button {
                        submitting = true
                        Task {
                            let body = ConvertToJobBody(title: title, priority: priority.rawValue, jobTypeUuid: jobTypeUuid,
                                                        dueDate: hasDueDate ? CalendarDay(date: dueDate) : nil)
                            let ok = await convert(body)
                            submitting = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if submitting { ProgressView().tint(.white) } else { Text("Create job") }
                    }
                    .buttonStyle(.large(.progress))
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Convert to job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { jobTypes = (try? await services.fieldService.jobTypes()) ?? [] }
        }
    }
}

struct EngineerPickerSheet: View {
    let title: String
    let onPick: (Engineer) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var state: LoadState<[Engineer]> = .idle

    var body: some View {
        NavigationStack {
            List {
                switch state {
                case .idle, .loading:
                    ProgressView()
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let engineers):
                    ForEach(engineers) { engineer in
                        Button {
                            onPick(engineer)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(engineer.displayName).font(.headline).foregroundStyle(.primary)
                                if let email = engineer.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                            }
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(250))
                await load()
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.fieldService.engineers(search: search))
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

struct NewServiceRequestSheet: View {
    let onCreated: (ServiceRequestDetail) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var reportedBy = ""
    @State private var channel = "phone"
    @State private var priority: JobPriority = .normal
    @State private var address = ""
    @State private var postcode = ""
    @State private var submitting = false
    @State private var error: APIError?

    private let channels = ["phone", "email", "app", "portal", "web", "other"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Problem") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("newRequest.title")
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                    Picker("Priority", selection: $priority) {
                        ForEach([JobPriority.low, .normal, .high, .urgent], id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Contact") {
                    TextField("Reported by", text: $reportedBy)
                        .textContentType(.name)
                    Picker("Channel", selection: $channel) {
                        ForEach(channels, id: \.self) { Text(Formatters.humanize($0)).tag($0) }
                    }
                }
                Section("Site") {
                    TextField("Address", text: $address, axis: .vertical)
                        .textContentType(.fullStreetAddress)
                    TextField("Postcode", text: $postcode)
                        .textContentType(.postalCode)
                        .textInputAutocapitalization(.characters)
                }
                if let error {
                    Section { InlineErrorRow(error: error) }
                }
            }
            .navigationTitle("New request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { submit() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
                }
            }
        }
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            defer { submitting = false }
            func clean(_ s: String) -> String? {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            do {
                let created = try await services.fieldService.createServiceRequest(CreateServiceRequestBody(
                    title: title.trimmingCharacters(in: .whitespaces), description: clean(description), faultCategory: nil,
                    channel: channel, reportedBy: clean(reportedBy), priority: priority.rawValue,
                    serviceAddress: clean(address), servicePostcode: clean(postcode)))
                onCreated(created)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}
