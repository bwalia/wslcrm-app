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
            ServiceRequestFormSheet(request: nil) { _ in
                Task { await model?.load() }
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
                .accessibilityIdentifier("requests.row.\(request.title)")
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

    func convert(_ body: ConvertToJobBody) async -> ConvertToJobResult? {
        busy = true
        defer { busy = false }
        do {
            let result = try await api.convertToJob(uuid, body: body, siteUuid: state.value?.request.siteUuid)
            convertedJobUuid = result.jobUuid
            await load()
            return result
        } catch {
            actionError = error.asAPIError
            return nil
        }
    }

    func replace(_ detail: ServiceRequestDetail) {
        state = .loaded(detail)
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
    @State private var editing = false
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
                AssignConvertToJobSheet(request: detail.request) { body in await model.convert(body) }
            }
        }
        .sheet(isPresented: $editing) {
            if let detail = model.state.value {
                ServiceRequestFormSheet(request: detail.request) { updated in model.replace(updated) }
            }
        }
        .toolbar {
            if session.policy.canUpdateServiceRequests, model.state.value != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit") { editing = true }
                        .accessibilityIdentifier("request.edit")
                }
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

            if (policy.canConvertServiceRequests && request.status.canConvertToJob)
                || (policy.canUpdateServiceRequests && !detail.allowedTransitions.isEmpty) {
                Section {
                    if policy.canConvertServiceRequests, request.status.canConvertToJob {
                        Button {
                            showingConvert = true
                        } label: {
                            Label(detail.jobs.isEmpty ? "Convert to job" : "Create another job", systemImage: "arrow.right.doc.on.clipboard")
                        }
                        .buttonStyle(.large(.progress))
                        .disabled(model.busy)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("request.convert")
                    }
                    if policy.canUpdateServiceRequests, !detail.allowedTransitions.isEmpty {
                        Menu {
                            ForEach(detail.allowedTransitions, id: \.self) { status in
                                Button(status.actionTitle, systemImage: status.systemImage) {
                                    if status == .resolved || status == .closed {
                                        pendingStatus = status
                                    } else {
                                        Task { await model.setStatus(status, resolutionNotes: nil) }
                                    }
                                }
                            }
                        } label: {
                            Label("Change status", systemImage: "arrow.triangle.swap")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .disabled(model.busy)
                        .accessibilityIdentifier("request.changeStatus")
                    }
                } header: {
                    Text("Actions")
                }
            }

            Section("Customer & site") {
                DetailRow(label: "Name", value: request.customerName, systemImage: "person")
                DetailRow(label: "Site", value: request.siteName, systemImage: "building.2")
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
                DetailRow(label: "Unit", value: [request.productName, request.productRef].compactMap { $0 }.joined(separator: " · "),
                          systemImage: "wrench.adjustable")
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
                                        .accessibilityIdentifier("request.job")
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

