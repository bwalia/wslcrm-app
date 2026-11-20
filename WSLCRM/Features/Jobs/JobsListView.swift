import SwiftUI

@MainActor
@Observable
final class JobsListViewModel {
    var query = JobListQuery()
    private(set) var jobs: [Job] = []
    private(set) var state: LoadState<Void> = .idle
    private(set) var isLoadingMore = false
    private(set) var pageError: APIError?
    private var lastPage: Page<Job>?

    private let api: FieldServiceAPI

    init(api: FieldServiceAPI) {
        self.api = api
    }

    var hasMore: Bool { lastPage?.hasMore ?? false }

    func load() async {
        if jobs.isEmpty { state = .loading }
        var first = query
        first.page = 1
        do {
            let page = try await api.jobs(first)
            jobs = page.items
            lastPage = page
            pageError = nil
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if jobs.isEmpty {
                state = .failed(apiError)
            } else {
                pageError = apiError
            }
        }
    }

    func loadMoreIfNeeded(current job: Job) async {
        guard hasMore, !isLoadingMore, job.id == jobs.last?.id, let lastPage else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        var next = query
        next.page = lastPage.page + 1
        do {
            let page = try await api.jobs(next)
            let known = Set(jobs.map(\.id))
            jobs.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.lastPage = page
            pageError = nil
        } catch {
            pageError = error.asAPIError
        }
    }
}

struct JobsListView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model: JobsListViewModel?

    var body: some View {
        Group {
            if let model {
                JobsListContent(model: model, canFilterMine: session.policy.isDispatcherForJobs,
                                canCreate: session.permissions.can(.create, .fsJobs))
            } else {
                SkeletonList()
            }
        }
        .navigationTitle("Jobs")
        .onAppear {
            if model == nil { model = JobsListViewModel(api: services.fieldService) }
        }
    }
}

struct JobRoute: Hashable {
    let uuid: String
}

private struct JobsListContent: View {
    @Bindable var model: JobsListViewModel
    let canFilterMine: Bool
    let canCreate: Bool
    @Environment(\.services) private var services
    @State private var jobTypes: [JobTypeDetail] = []
    @State private var creating = false
    @State private var created: JobRoute?

    var body: some View {
        List {
            ForEach(model.jobs) { job in
                NavigationLink(value: JobRoute(uuid: job.uuid)) {
                    JobRow(job: job)
                }
                .task { await model.loadMoreIfNeeded(current: job) }
                .accessibilityIdentifier("jobs.row.\(job.jobNumber)")
            }
            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            if let error = model.pageError {
                InlineErrorRow(error: error) {
                    Task {
                        if model.hasMore, let last = model.jobs.last {
                            await model.loadMoreIfNeeded(current: last)
                        } else {
                            await model.load()
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            switch model.state {
            case .idle:
                SkeletonList()
            case .loading where model.jobs.isEmpty:
                SkeletonList()
            case .failed(let error) where model.jobs.isEmpty:
                ErrorStateView(error: error) { Task { await model.load() } }
            case .loaded where model.jobs.isEmpty:
                ContentUnavailableView {
                    Label(model.query.search.isEmpty ? "No jobs" : "No matching jobs", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text(model.query.status == .open ? "There are no open jobs. Try showing all jobs." : "Try a different filter.")
                } actions: {
                    if model.query.status != .all {
                        Button("Show all jobs") { model.query.status = .all }
                            .buttonStyle(.bordered)
                    }
                }
            default:
                EmptyView()
            }
        }
        .searchable(text: $model.query.search, prompt: "Job number, customer, postcode")
        .refreshable { await model.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $model.query.status) {
                        ForEach(JobListQuery.StatusFilter.allCases, id: \.self) { filter in
                            Text(filter == .open ? "Open" : filter == .all ? "All" : Formatters.humanize(filter.rawValue))
                                .tag(filter)
                        }
                    }
                    Picker("Priority", selection: $model.query.priority) {
                        Text("Any priority").tag(String?.none)
                        ForEach(ModuleCatalog.jobPriorityChoices) { Text($0.label).tag(Optional($0.value)) }
                    }
                    if !jobTypes.isEmpty {
                        Picker("Job type", selection: $model.query.jobTypeUuid) {
                            Text("Any job type").tag(String?.none)
                            ForEach(jobTypes) { type in
                                Text(type.isActive ? type.name : "\(type.name) (not in use)").tag(Optional(type.uuid))
                            }
                        }
                    }
                    if canFilterMine {
                        Toggle("Only my jobs", isOn: $model.query.mine)
                    }
                    Toggle("Overdue only", isOn: $model.query.overdue)
                    Toggle("Done, waiting for an invoice", isOn: $model.query.uninvoiced)
                } label: {
                    Label("Filter", systemImage: isFiltered
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityIdentifier("jobs.filter")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $model.query.sort) {
                        ForEach(JobListQuery.Sort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("jobs.sort")
            }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New job", systemImage: "plus") }
                        .accessibilityIdentifier("jobs.new")
                }
            }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ResourceFormView(descriptor: ModuleCatalog.fsJobs, existing: nil) { saved in
                    Task { await model.load() }
                    if let saved { created = JobRoute(uuid: saved.id) }
                }
            }
        }
        .navigationDestination(item: $created) { JobDetailView(jobUuid: $0.uuid) }
        .task { jobTypes = (try? await services.fieldService.jobTypes(includeInactive: true)) ?? [] }
        .task(id: FilterKey(query: model.query)) {
            // Debounce typing; filter changes load immediately.
            if !model.jobs.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }

    private var isFiltered: Bool {
        var plain = JobListQuery(search: model.query.search)
        plain.sort = model.query.sort
        return model.query != plain
    }

    private struct FilterKey: Hashable {
        let status: JobListQuery.StatusFilter
        let search: String
        let mine: Bool
        let overdue: Bool
        let uninvoiced: Bool
        let priority: String?
        let jobType: String?
        let sort: JobListQuery.Sort

        init(query: JobListQuery) {
            status = query.status
            search = query.search
            mine = query.mine
            overdue = query.overdue
            uninvoiced = query.uninvoiced
            priority = query.priority
            jobType = query.jobTypeUuid
            sort = query.sort
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.jobNumber)
                    .font(.wsSubheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondaryText)
                if job.priority == .urgent || job.priority == .high {
                    job.priority.badge
                }
                Spacer()
                job.status.badge
            }
            Text(job.title)
                .font(.wsHeadline)
                .lineLimit(2)
            if let type = job.jobTypeName {
                Label(type, systemImage: "tag").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let customer = job.customerName {
                Label(customer, systemImage: "person")
                    .font(.wsSubheadline)
            }
            if let address = job.fullAddress {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.wsSubheadline)
                    .foregroundStyle(.secondaryText)
                    .lineLimit(1)
            }
            HStack(spacing: 16) {
                if job.phaseCount > 0 {
                    Label("\(job.phasesDone)/\(job.phaseCount) phases", systemImage: "list.bullet.clipboard")
                }
                if let next = job.nextVisitAt {
                    Label(Formatters.dateTime(next) ?? "", systemImage: "calendar")
                }
                if job.isOverdue {
                    Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.danger.color)
                } else if let due = job.dueDate, job.status.isOpen {
                    Label("Due \(Formatters.day(due.date()) ?? "")", systemImage: "calendar.badge.clock")
                }
            }
            .font(.wsFootnote)
            .foregroundStyle(.secondaryText)
            if let next = job.currentPhaseName {
                Text("Next: \(next)").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            if let product = job.productName {
                Label(product, systemImage: "shippingbox").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
