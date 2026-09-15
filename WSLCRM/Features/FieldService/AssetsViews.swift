import SwiftUI

// Asset register.
//
// OPSAPI has no dedicated assets API: `fs_assets` (migration 862) was dropped in field-service-v2
// (884), which made the customer's *store product* the serviced asset and `product_ref` the
// specific unit's serial. So asset search = product search (store-scoped), and an asset's service
// history = jobs + requests filtered by `product_uuid` — both real, existing endpoints.

@MainActor
@Observable
final class AssetSearchModel {
    private(set) var stores: [Store] = []
    var selectedStoreUuid: String? { didSet { selection.uuid = selectedStoreUuid } }
    let list: PagedListModel<Product>

    @ObservationIgnored private let selection = StoreSelection()
    private let commerce: CommerceAPI
    private let namespaceInternalId: Int?

    @MainActor
    private final class StoreSelection { var uuid: String? }

    init(commerce: CommerceAPI, namespaceInternalId: Int?) {
        self.commerce = commerce
        self.namespaceInternalId = namespaceInternalId
        let selection = self.selection
        list = PagedListModel<Product> { search, page in
            try await commerce.products(search: search, storeUuid: selection.uuid, namespaceInternalId: namespaceInternalId, page: page)
        }
    }

    func loadStores() async {
        stores = (try? await commerce.myStores(namespaceInternalId: namespaceInternalId)) ?? []
        if selectedStoreUuid == nil, stores.count == 1 { selectedStoreUuid = stores.first?.uuid }
    }
}

struct AssetSearchView: View {
    enum Mode {
        case browse
        case pick((Product) -> Void)
    }

    var mode: Mode = .browse
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        ModelHost(make: { AssetSearchModel(commerce: services.commerce, namespaceInternalId: session.workspace?.internalId) }) { model in
            AssetSearchContent(model: model, mode: mode)
        }
        .navigationTitle("Assets")
    }
}

private struct AssetSearchContent: View {
    @Bindable var model: AssetSearchModel
    let mode: AssetSearchView.Mode

    var body: some View {
        PagedList(model: model.list, searchPrompt: "Unit, model or description", emptyTitle: "No assets found",
                  emptySystemImage: "wrench.adjustable",
                  emptyDescription: "Assets are the equipment models you service (store products).") { product in
            switch mode {
            case .browse:
                NavigationLink(value: AssetRoute(product: product)) {
                    AssetRow(product: product)
                }
                .accessibilityIdentifier("asset.row.\(product.name)")
            case .pick(let choose):
                Button { choose(product) } label: { AssetRow(product: product) }
                    .accessibilityIdentifier("asset.row.\(product.name)")
            }
        }
        .safeAreaInset(edge: .top) {
            if model.stores.count > 1 {
                Picker("Store", selection: $model.selectedStoreUuid) {
                    Text("All my stores").tag(String?.none)
                    ForEach(model.stores) { Text($0.name).tag(Optional($0.uuid)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
        .task { await model.loadStores() }
        .onChange(of: model.selectedStoreUuid) { _, _ in Task { await model.list.load() } }
    }
}

struct AssetRow: View {
    let product: Product

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.adjustable.fill")
                .frame(width: 40, height: 40)
                .background(Tone.progress.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Tone.progress.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name).font(.headline).foregroundStyle(.primary)
                Text([product.sku, product.categoryName, product.storeName].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }
}

/// A serviced unit and everything done to it.
struct AssetDetailView: View {
    let product: Product
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var jobs: LoadState<[Job]> = .idle
    @State private var requests: LoadState<[ServiceRequest]> = .idle
    @State private var raising = false
    @State private var createdRequest: ServiceRequestRoute?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(product.name).font(.title2.bold())
                    Text([product.sku.map { "SKU \($0)" }, product.categoryName, product.storeName].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let description = product.description, !description.isEmpty {
                        Text(description).font(.subheadline)
                    }
                }
                .padding(.vertical, 4)
                if session.policy.canCreateServiceRequest {
                    Button {
                        raising = true
                    } label: {
                        Label("Raise a service request", systemImage: "exclamationmark.bubble")
                    }
                    .buttonStyle(.large(.info, prominent: false))
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("asset.raiseRequest")
                }
            }

            Section("Service requests") {
                switch requests {
                case .idle, .loading: ProgressView()
                case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let items):
                    if items.isEmpty { Text("No requests for this unit").foregroundStyle(.secondary) }
                    ForEach(items) { request in
                        NavigationLink(value: ServiceRequestRoute(uuid: request.uuid)) { ServiceRequestRow(request: request) }
                    }
                }
            }

            Section("Jobs") {
                switch jobs {
                case .idle, .loading: ProgressView()
                case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
                case .loaded(let items):
                    if items.isEmpty { Text("No jobs for this unit").foregroundStyle(.secondary) }
                    ForEach(items) { job in
                        NavigationLink(value: JobRoute(uuid: job.uuid)) { JobRow(job: job) }
                    }
                }
            }
        }
        .navigationTitle("Asset")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $raising) {
            ServiceRequestFormSheet(request: nil, initialProduct: product) { created in
                createdRequest = ServiceRequestRoute(uuid: created.request.uuid)
                Task { await load() }
            }
        }
        .navigationDestination(item: $createdRequest) { ServiceRequestDetailView(requestUuid: $0.uuid) }
    }

    private func load() async {
        let api = services.fieldService
        async let jobsTask = api.jobs(JobListQuery(status: .all, productUuid: product.uuid, perPage: 50))
        async let requestsTask = api.serviceRequests(status: nil, search: "", page: 1, perPage: 50, productUuid: product.uuid)
        do { jobs = .loaded(try await jobsTask.items) } catch { jobs = .failed(error.asAPIError) }
        do { requests = .loaded(try await requestsTask.items) } catch { requests = .failed(error.asAPIError) }
    }
}
