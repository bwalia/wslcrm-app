import SwiftUI

// MARK: - Words

/// Plain words for the delivery module's values.
enum DeliveryWords {
    static let requestStatus = StatusStyle(
        tones: ["pending": .warning, "accepted": .success, "rejected": .danger, "expired": .neutral, "cancelled": .neutral],
        symbols: ["pending": "clock"],
        labels: ["pending": "Waiting for an answer", "rejected": "Declined", "cancelled": "Withdrawn"])

    static let assignmentStatus = StatusStyle(
        tones: ["pending": .warning, "accepted": .info, "rejected": .danger, "picked_up": .progress,
                "in_transit": .progress, "delivered": .success, "failed": .danger],
        symbols: ["picked_up": "shippingbox", "in_transit": "truck.box", "delivered": "checkmark.seal.fill"],
        labels: ["pending": "Waiting for the partner", "rejected": "Declined", "in_transit": "On the way"])

    static let requestFilters = [
        Choice("pending", "Waiting for an answer"), Choice("accepted"), Choice("rejected", "Declined"),
        Choice("cancelled", "Withdrawn"),
    ]

    static let serviceTypes = [Choice("standard", "Standard"), Choice("express", "Express"), Choice("same_day", "Same day")]

    static func serviceType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return serviceTypes.first { $0.value == raw }?.label ?? Formatters.humanize(raw)
    }

    static func pricingModel(_ raw: String?) -> String? {
        switch raw {
        case "flat": "A fixed charge"
        case "per_km": "By distance"
        case "percentage": "A share of the order"
        case "hybrid": "Fixed charge plus distance"
        case let other?: Formatters.humanize(other)
        case nil: nil
        }
    }

    static func requestType(_ raw: String?) -> String {
        raw == "partner_to_seller" ? "They offered to deliver" : "You asked them"
    }

    static func badge(_ style: StatusStyle, _ value: String) -> StatusBadge {
        StatusBadge(text: style.label(for: value), systemImage: style.symbol(for: value), tone: style.tone(for: value))
    }

    static func money(_ record: Record, _ key: String, currency: String?) -> String? {
        Formatters.money(record.decimal(key), currency: currency ?? "GBP")
    }

    /// What the store owner may do with a delivery at each step (the partner marks picked up and delivered).
    /// `accepted → cancelled` is in the route's state machine but the table refuses it, so it isn't offered.
    static func ownerMoves(from status: String) -> [(status: String, title: String, destructive: Bool)] {
        switch status {
        case "pending": [("rejected", "Mark as declined", true)]
        case "picked_up": [("in_transit", "Mark on the way", false)]
        case "in_transit": [("failed", "Mark as failed", true)]
        default: []
        }
    }

    static let onlyTheOwner = "Only the person who set up a store can manage its delivery partners, requests and deliveries."
}

// MARK: - Home

/// The `delivery` menu item: a store's delivery partners, delivery requests and the delivery prices.
struct DeliveryHomeView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case partners = "Partners", requests = "Requests", prices = "Prices"
        var id: String { rawValue }
    }

    @Environment(\.services) private var services
    @AppStorage("delivery.store") private var savedStore = ""
    @State private var stores: LoadState<[Record]> = .idle
    @State private var tab: Tab = .partners

    private var store: Record? {
        guard let stores = stores.value else { return nil }
        return stores.first { $0.id == savedStore } ?? (stores.count == 1 ? stores.first : nil)
    }

    var body: some View {
        Group {
            if tab == .prices {
                DeliveryPricesList()
            } else if let store {
                switch tab {
                case .partners: DeliveryPartnersList(store: store)
                case .requests: DeliveryRequestsList(store: store)
                case .prices: EmptyView()
                }
            } else if let error = stores.error {
                List { InlineErrorRow(error: error) { Task { await load() } } }
            } else if let list = stores.value, list.isEmpty {
                ContentUnavailableView("No stores yet", systemImage: "storefront",
                                       description: Text("Delivery partners deliver a store's orders. Set up a store first, then come back to link a delivery company to it."))
            } else if stores.value != nil {
                ContentUnavailableView("Choose a store", systemImage: "storefront",
                                       description: Text("Pick the store whose deliveries you want to manage, above."))
            } else {
                SkeletonList()
            }
        }
        .safeAreaInset(edge: .top) { header }
        .navigationTitle("Delivery")
        .task { if stores.value == nil { await load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let list = stores.value, list.count > 1 {
                Picker("Store", selection: $savedStore) {
                    Text("Choose a store").tag("")
                    ForEach(list) { Text($0.string("name") ?? "Store").tag($0.id) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("delivery.store")
            } else if let store {
                Label(store.string("name") ?? "Store", systemImage: "storefront").font(.wsSubheadline)
            }
            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("delivery.tab")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func load() async {
        stores = .loading
        do {
            stores = .loaded(try await services.delivery.stores())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            stores = .failed(apiError)
        }
    }
}

// MARK: - Partners

struct DeliveryPartnersList: View {
    let store: Record
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var adding = false
    @State private var notice: String?

    private var slug: String { store.string("slug") ?? store.id }

    var body: some View {
        List {
            if let error = state.error {
                Section {
                    InlineErrorRow(error: error) { Task { await load() } }
                } footer: {
                    Text(DeliveryWords.onlyTheOwner)
                }
            } else if let partners = state.value {
                if partners.isEmpty {
                    ContentUnavailableView("No delivery partners yet", systemImage: "truck.box",
                                           description: Text("Link a delivery company to \(store.string("name") ?? "this store") so you can ask them to deliver its orders."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(partners) { partner in
                            NavigationLink {
                                DeliveryPartnerDetailView(store: store, partner: partner, onChanged: load)
                            } label: {
                                DeliveryPartnerRow(partner: partner, linked: true)
                            }
                        }
                    } footer: {
                        Text("The preferred partner is listed first. A paused partner stays linked but isn’t asked.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add a partner", systemImage: "plus") }
                    .accessibilityIdentifier("delivery.addPartner")
            }
        }
        .sheet(isPresented: $adding) {
            DeliveryPartnerSearchSheet(store: store, linked: Set((state.value ?? []).map(\.id))) { name in
                notice = "\(name) is now a delivery partner for \(store.string("name") ?? "this store")."
                await load()
            }
        }
        .alert("Done", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: { Text(notice ?? "") }
        .task(id: store.id) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.delivery.partners(store: slug))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

struct DeliveryPartnerRow: View {
    let partner: Record
    var linked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(partner.string("company_name") ?? "Delivery partner").font(.wsHeadline)
                Spacer()
                if linked, partner.bool("is_preferred") == true {
                    StatusBadge(text: "Preferred", systemImage: "star.fill", tone: .brand)
                }
            }
            Text(details.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            HStack(spacing: 6) {
                if linked, partner.bool("is_active") == false {
                    StatusBadge(text: "Paused", systemImage: "pause.circle", tone: .neutral)
                }
                if partner.bool("partner_is_active") == false {
                    StatusBadge(text: "Not taking work", systemImage: "moon.zzz", tone: .warning)
                }
                if partner.bool("is_verified") == false {
                    StatusBadge(text: "Not verified", systemImage: "exclamationmark.shield", tone: .warning)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var details: [String] {
        var parts: [String] = []
        if let name = partner.string("contact_person_name") { parts.append(name) }
        if let type = DeliveryWords.serviceType(partner.string("service_type")) { parts.append(type) }
        if let rating = partner.decimal("rating"), rating > 0 {
            parts.append("★ \(rating.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let count = partner.int("total_deliveries") { parts.append("\(count) deliver\(count == 1 ? "y" : "ies")") }
        if let city = partner.string("city") { parts.append(city) }
        return parts
    }
}

struct DeliveryPartnerDetailView: View {
    let store: Record
    @State var partner: Record
    let onChanged: () async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var confirmingRemove = false

    private var slug: String { store.string("slug") ?? store.id }
    private var currency: String? { store.string("currency") }
    private var name: String { partner.string("company_name") ?? "This partner" }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    DeliveryPartnerRow(partner: partner, linked: true)
                }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            Section("Contact") {
                DetailRow(label: "Name", value: partner.string("contact_person_name"))
                if let phone = partner.string("contact_person_phone") {
                    PhoneLinkRow(name: partner.string("contact_person_name"), phone: phone)
                }
                if let email = partner.string("contact_person_email") { EmailLinkRow(email: email) }
            }
            Section("Their service") {
                DetailRow(label: "Service", value: DeliveryWords.serviceType(partner.string("service_type")))
                DetailRow(label: "Rating", value: partner.decimal("rating").map { "★ \($0.formatted(.number.precision(.fractionLength(0...1))))" })
                DetailRow(label: "Deliveries made", value: partner.int("total_deliveries")?.formatted())
                DetailRow(label: "Delivered successfully", value: partner.int("successful_deliveries")?.formatted())
                DetailRow(label: "Orders with them now", value: partner.int("current_active_orders")?.formatted())
                DetailRow(label: "Most orders a day", value: partner.int("max_daily_capacity")?.formatted())
                DetailRow(label: "Verified", value: partner.bool("is_verified").map { $0 ? "Yes" : "Not yet" })
            }
            Section("What they charge") {
                DetailRow(label: "Pricing", value: DeliveryWords.pricingModel(partner.string("pricing_model")))
                DetailRow(label: "Fixed charge", value: DeliveryWords.money(partner, "base_charge", currency: currency))
                DetailRow(label: "Per km", value: DeliveryWords.money(partner, "per_km_charge", currency: currency))
                DetailRow(label: "Share of the order", value: partner.decimal("percentage_charge").flatMap { $0 > 0 ? "\($0.formatted())%" : nil })
            }
            Section {
                DetailRow(label: "Linked", value: Formatters.dateTime(partner.date("linked_at")))
                if partner.bool("is_preferred") != true {
                    Button { Task { await run(.prefer) } } label: { Label("Make them the preferred partner", systemImage: "star") }
                        .accessibilityIdentifier("delivery.prefer")
                }
                Button { Task { await run(.toggle) } } label: {
                    if partner.bool("is_active") == false {
                        Label("Use them again", systemImage: "play.circle")
                    } else {
                        Label("Pause them for this store", systemImage: "pause.circle")
                    }
                }
                .accessibilityIdentifier("delivery.toggle")
                Button(role: .destructive) { confirmingRemove = true } label: {
                    Label("Remove from this store", systemImage: "trash")
                }
                .accessibilityIdentifier("delivery.remove")
            } header: {
                Text("For \(store.string("name") ?? "this store")")
            } footer: {
                Text("A partner can’t be removed while they still have orders from this store that aren’t delivered.")
            }
        }
        .disabled(busy)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await run(.remove) } }
        } message: {
            Text("They will no longer deliver for \(store.string("name") ?? "this store"). You can link them again later.")
        }
        .alert("Done", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: { Text(notice ?? "") }
    }

    private enum Step { case prefer, toggle, remove }

    private func run(_ step: Step) async {
        guard let uuid = partner.string("uuid") else { return }
        busy = true
        defer { busy = false }
        do {
            switch step {
            case .prefer:
                try await services.delivery.prefer(store: slug, partnerUUID: uuid)
                partner = partner.setting("is_preferred", .bool(true))
                notice = "\(name) is now the preferred partner."
            case .toggle:
                let active = try await services.delivery.toggle(store: slug, partnerUUID: uuid) ?? !(partner.bool("is_active") ?? true)
                partner = partner.setting("is_active", .bool(active))
                notice = active ? "\(name) will be asked again." : "\(name) is paused for this store."
            case .remove:
                try await services.delivery.unlink(store: slug, partnerUUID: uuid)
                await onChanged()
                dismiss()
                return
            }
            actionError = nil
            await onChanged()
        } catch {
            actionError = error.asAPIError
        }
    }
}

extension Record {
    /// A copy with one top-level field changed (keeps the row on screen in step with what was just done).
    func setting(_ key: String, _ value: JSONValue) -> Record {
        var fields = self.fields
        fields[key] = value
        return Record(fields, idKeys: ["uuid", "id"])
    }
}

/// Finds a verified delivery company and links it to the store.
struct DeliveryPartnerSearchSheet: View {
    let store: Record
    let linked: Set<String>
    let onLinked: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var search = DeliveryPartnerSearch()
    @State private var results: LoadState<[Record]> = .idle
    @State private var preferred = false
    @State private var linking: String?
    @State private var linkError: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Town or city", text: $search.city).textContentType(.addressCity)
                        .accessibilityIdentifier("delivery.search.city")
                    TextField("County or state", text: $search.state).textContentType(.addressState)
                    Picker("Service", selection: $search.serviceType) {
                        Text("Any").tag("")
                        ForEach(DeliveryWords.serviceTypes) { Text($0.label).tag($0.value) }
                    }
                    Picker("Rated at least", selection: $search.minRating) {
                        Text("Any").tag("")
                        Text("★ 3").tag("3")
                        Text("★ 4").tag("4")
                        Text("★ 4.5").tag("4.5")
                    }
                    Button { Task { await find() } } label: { Label("Find delivery partners", systemImage: "magnifyingglass") }
                        .disabled(results.isLoading)
                        .accessibilityIdentifier("delivery.search.go")
                } header: {
                    Text("Where they deliver")
                } footer: {
                    Text("Only verified delivery companies are listed.")
                }
                if let error = results.error {
                    Section { InlineErrorRow(error: error) { Task { await find() } } }
                }
                if let linkError { Section { InlineErrorRow(error: linkError) } }
                if let found = results.value {
                    Section {
                        if found.isEmpty {
                            Text("No verified delivery partner matches. Try another town, or leave the filters empty.")
                                .foregroundStyle(.secondaryText)
                        } else {
                            Toggle("Make them the preferred partner", isOn: $preferred)
                            ForEach(found) { partner in
                                Button {
                                    Task { await link(partner) }
                                } label: {
                                    HStack {
                                        DeliveryPartnerRow(partner: partner)
                                        Spacer()
                                        if linked.contains(partner.id) {
                                            Text("Linked").font(.wsFootnote).foregroundStyle(.secondaryText)
                                        } else if linking == partner.id {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(linked.contains(partner.id) || linking != nil)
                            }
                        }
                    } header: {
                        Text(found.isEmpty ? "Results" : "Tap one to link it")
                    }
                }
            }
            .navigationTitle("Add a delivery partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await find() }
        }
    }

    private func find() async {
        results = .loading
        do {
            results = .loaded(try await services.delivery.search(search))
        } catch {
            results = .failed(error.asAPIError)
        }
    }

    private func link(_ partner: Record) async {
        guard let uuid = partner.string("uuid") else { return }
        linking = partner.id
        defer { linking = nil }
        do {
            try await services.delivery.link(store: store.string("slug") ?? store.id, partnerUUID: uuid, preferred: preferred)
            linkError = nil
            await onLinked(partner.string("company_name") ?? "The partner")
            dismiss()
        } catch {
            linkError = error.asAPIError
        }
    }
}

// MARK: - Requests

struct DeliveryRequestsList: View {
    let store: Record
    @Environment(\.services) private var services
    @State private var state: LoadState<[Record]> = .idle
    @State private var status = ""
    @State private var asking = false
    @State private var notice: String?

    private var slug: String { store.string("slug") ?? store.id }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $status) {
                    Text("All requests").tag("")
                    ForEach(DeliveryWords.requestFilters) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("delivery.requests.filter")
            }
            if let error = state.error {
                Section {
                    InlineErrorRow(error: error) { Task { await load() } }
                } footer: {
                    Text(DeliveryWords.onlyTheOwner)
                }
            } else if let requests = state.value {
                if requests.isEmpty {
                    ContentUnavailableView("No delivery requests", systemImage: "tray",
                                           description: Text(status.isEmpty
                                                             ? "Ask a delivery partner to deliver an order, or wait for a partner to offer."
                                                             : "Nothing with this status. Choose All requests to see the rest."))
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(requests) { request in
                            NavigationLink {
                                DeliveryRequestDetailView(store: store, request: request, onChanged: load)
                            } label: {
                                DeliveryRequestRow(request: request, currency: store.string("currency"))
                            }
                        }
                    } footer: {
                        Text("Requests whose time ran out drop off this list.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { asking = true } label: { Label("Ask a partner to deliver", systemImage: "paperplane") }
                    .accessibilityIdentifier("delivery.ask")
            }
        }
        .sheet(isPresented: $asking) {
            DeliveryAskSheet(store: store) { text in
                notice = text
                await load()
            }
        }
        .alert("Sent", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: { Text(notice ?? "") }
        .task(id: "\(store.id)|\(status)") { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.delivery.requests(store: slug, status: status.isEmpty ? nil : status))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

struct DeliveryRequestRow: View {
    let request: Record
    let currency: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.string("order.order_number") ?? "Order").font(.wsSubheadline.monospacedDigit().weight(.semibold))
                Spacer()
                DeliveryWords.badge(DeliveryWords.requestStatus, request.string("status") ?? "pending")
            }
            Text(request.string("delivery_partner.company_name") ?? "Delivery partner").font(.wsHeadline)
            Text([DeliveryWords.requestType(request.string("request_type")),
                  DeliveryWords.money(request, "proposed_fee", currency: currency).map { "fee \($0)" },
                  Formatters.relative(request.date("created_at"))].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct DeliveryRequestDetailView: View {
    let store: Record
    @State var request: Record
    let onChanged: () async -> Void
    @Environment(\.services) private var services
    @State private var reply = ""
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?

    private var currency: String? { store.string("currency") }
    private var status: String { request.string("status") ?? "pending" }
    private var partnerName: String { request.string("delivery_partner.company_name") ?? "The partner" }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    DeliveryWords.badge(DeliveryWords.requestStatus, status)
                    Text(DeliveryWords.requestType(request.string("request_type"))).font(.wsHeadline)
                    if let message = request.string("message") { Text("“\(message)”").font(.wsBody) }
                }
                .padding(.vertical, 4)
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            if status == "pending", request.string("request_type") == "partner_to_seller" {
                Section {
                    TextField("Reply to them (optional)", text: $reply, axis: .vertical)
                        .accessibilityIdentifier("delivery.reply")
                    Button { Task { await answer(true) } } label: { Label("Accept their offer", systemImage: "checkmark.circle") }
                        .buttonStyle(.large(.success, prominent: true))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("delivery.accept")
                    Button { Task { await answer(false) } } label: { Label("Decline", systemImage: "xmark.circle") }
                        .buttonStyle(.large(.danger, prominent: false))
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("delivery.decline")
                } header: {
                    Text("Answer \(partnerName)")
                } footer: {
                    Text("Accepting hands them the order and declines any other offers for it.")
                }
            } else if status == "pending" {
                Section { Label("Waiting for \(partnerName) to answer.", systemImage: "clock").foregroundStyle(.secondaryText) }
            }
            if status == "accepted", let orderUUID = request.string("order.uuid") {
                Section {
                    NavigationLink {
                        DeliveryOrderView(orderUUID: orderUUID, currency: currency)
                    } label: {
                        Label("Follow the delivery", systemImage: "truck.box")
                    }
                    .accessibilityIdentifier("delivery.follow")
                }
            }
            Section("Order") {
                DetailRow(label: "Number", value: request.string("order.order_number"))
                DetailRow(label: "Status", value: request.string("order.status").map { Formatters.humanize($0) })
                DetailRow(label: "Total", value: DeliveryWords.money(request, "order.total_amount", currency: currency))
                DetailRow(label: "Deliver to", value: [request.string("order.delivery_address"), request.string("order.delivery_city"),
                                                      request.string("order.delivery_state")].compactMap { $0 }.joined(separator: ", "))
            }
            Section("Delivery partner") {
                DetailRow(label: "Company", value: request.string("delivery_partner.company_name"))
                DetailRow(label: "Contact", value: request.string("delivery_partner.contact_person_name"))
                if let phone = request.string("delivery_partner.contact_person_phone") {
                    PhoneLinkRow(name: request.string("delivery_partner.contact_person_name"), phone: phone)
                }
                DetailRow(label: "Service", value: DeliveryWords.serviceType(request.string("delivery_partner.service_type")))
                DetailRow(label: "Vehicles", value: request.array("delivery_partner.vehicle_types").compactMap(\.stringValue)
                    .map { Formatters.humanize($0) }.joined(separator: ", "))
            }
            Section("Request") {
                DetailRow(label: "Fee", value: DeliveryWords.money(request, "proposed_fee", currency: currency))
                DetailRow(label: "Their reply", value: request.string("response_message"))
                DetailRow(label: "Made", value: Formatters.dateTime(request.date("created_at")))
                DetailRow(label: "Answer needed by", value: Formatters.dateTime(request.date("expires_at")))
                DetailRow(label: "Answered", value: Formatters.dateTime(request.date("responded_at")))
            }
        }
        .disabled(busy)
        .navigationTitle(request.string("order.order_number") ?? "Delivery request")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Done", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: { Text(notice ?? "") }
    }

    private func answer(_ accept: Bool) async {
        busy = true
        defer { busy = false }
        do {
            try await services.delivery.answer(request: request.string("uuid") ?? request.id, accept: accept, message: reply)
            request = request.setting("status", .string(accept ? "accepted" : "rejected"))
            actionError = nil
            notice = accept ? "\(partnerName) will deliver this order." : "You declined \(partnerName)’s offer."
            await onChanged()
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// Asks one of the store's partners to deliver one of its orders.
struct DeliveryAskSheet: View {
    let store: Record
    let onSent: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var orders: LoadState<[Record]> = .idle
    @State private var partners: [Record] = []
    @State private var ask = DeliveryAsk(orderID: "", partnerID: "", fee: "", message: "")
    @State private var sending = false
    @State private var sendError: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error = orders.error {
                    Section {
                        InlineErrorRow(error: error) { Task { await load() } }
                    } footer: {
                        Text(DeliveryWords.onlyTheOwner)
                    }
                } else if let list = orders.value {
                    if list.isEmpty {
                        Section {
                            Text("No order is ready for delivery. A partner can be asked once an order is confirmed, being processed or packed.")
                                .foregroundStyle(.secondaryText)
                        }
                    } else {
                        Section("Order") {
                            Picker("Order", selection: $ask.orderID) {
                                Text("Choose an order").tag("")
                                ForEach(list, id: \.id) { order in
                                    Text(orderLabel(order)).tag(order.string("id") ?? "")
                                }
                            }
                            .accessibilityIdentifier("delivery.ask.order")
                        }
                        Section {
                            if partners.isEmpty {
                                Text("This store has no delivery partner taking work. Link one under Partners first.")
                                    .foregroundStyle(.secondaryText)
                            } else {
                                Picker("Partner", selection: $ask.partnerID) {
                                    Text("Choose a partner").tag("")
                                    ForEach(partners, id: \.id) { partner in
                                        Text(partnerLabel(partner)).tag(partner.string("id") ?? "")
                                    }
                                }
                                .accessibilityIdentifier("delivery.ask.partner")
                            }
                        } header: {
                            Text("Delivery partner")
                        }
                        Section {
                            TextField("Fee you offer (e.g. 4.50)", text: $ask.fee).keyboardType(.decimalPad)
                                .accessibilityIdentifier("delivery.ask.fee")
                            TextField("Message for them (optional)", text: $ask.message, axis: .vertical)
                        } footer: {
                            Text("They have 24 hours to answer. The Prices tab can estimate a fair fee.")
                        }
                    }
                } else {
                    Section { ProgressView() }
                }
                if let sendError { Section { InlineErrorRow(error: sendError) } }
                if orders.value?.isEmpty == false, let problem = ask.problem {
                    Section { Text(problem).font(.wsFootnote).foregroundStyle(Tone.warning.textColor) }
                }
            }
            .navigationTitle("Ask a partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(ask.problem != nil || sending)
                        .accessibilityIdentifier("delivery.ask.send")
                }
            }
            .task { await load() }
        }
    }

    private func orderLabel(_ order: Record) -> String {
        let customer = [order.string("customer_first_name"), order.string("customer_last_name")].compactMap { $0 }.joined(separator: " ")
        return [order.string("order_number") ?? "Order", customer.isEmpty ? nil : customer,
                Formatters.money(order.decimal("total_amount"), currency: order.string("currency") ?? "GBP")]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func partnerLabel(_ partner: Record) -> String {
        (partner.string("company_name") ?? "Partner") + (partner.bool("is_preferred") == true ? " (preferred)" : "")
    }

    private func load() async {
        orders = .loading
        do {
            async let found = services.delivery.deliverableOrders(storeUUID: store.string("uuid") ?? store.id)
            async let linked = services.delivery.partners(store: store.string("slug") ?? store.id)
            let (orderRows, partnerRows) = try await (found, linked)
            partners = partnerRows.filter { $0.bool("is_active") != false && $0.bool("partner_is_active") != false }
            if ask.partnerID.isEmpty, let preferred = partners.first(where: { $0.bool("is_preferred") == true }) {
                ask.partnerID = preferred.string("id") ?? ""
            }
            orders = .loaded(orderRows)
        } catch {
            orders = .failed(error.asAPIError)
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await services.delivery.ask(ask)
            let order = orders.value?.first { $0.string("id") == ask.orderID }?.string("order_number") ?? "the order"
            let partner = partners.first { $0.string("id") == ask.partnerID }?.string("company_name") ?? "The partner"
            await onSent("\(partner) has been asked to deliver \(order). You’ll see their answer under Requests.")
            dismiss()
        } catch {
            sendError = error.asAPIError
        }
    }
}

// MARK: - A delivery

/// An order's delivery: who has it, where it is going, and the store owner's steps.
struct DeliveryOrderView: View {
    let orderUUID: String
    let currency: String?
    @Environment(\.services) private var services
    @State private var assignment: LoadState<Record?> = .idle
    @State private var notes = ""
    @State private var pending: (status: String, title: String, destructive: Bool)?
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?

    var body: some View {
        List {
            switch assignment {
            case .idle, .loading:
                Section { ProgressView() }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } } footer: { Text(DeliveryWords.onlyTheOwner) }
            case .loaded(nil):
                ContentUnavailableView("Not with a delivery partner yet", systemImage: "truck.box",
                                       description: Text("Once a partner accepts the order, its delivery shows here."))
                    .listRowBackground(Color.clear)
            case .loaded(let record?):
                content(record)
            }
        }
        .disabled(busy)
        .navigationTitle("Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .alert(pending?.title ?? "", isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            TextField("Note (optional)", text: $notes)
            Button(pending?.title ?? "OK", role: pending?.destructive == true ? .destructive : nil) {
                if let move = pending { Task { await run(move.status) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Done", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK") {}
        } message: { Text(notice ?? "") }
    }

    @ViewBuilder
    private func content(_ a: Record) -> some View {
        let status = a.string("status") ?? "pending"
        let cur = a.string("currency") ?? currency
        Section {
            VStack(alignment: .leading, spacing: 8) {
                DeliveryWords.badge(DeliveryWords.assignmentStatus, status)
                Text(a.string("order_number") ?? "Order").font(.wsTitle3.monospacedDigit().weight(.semibold))
                DetailRow(label: "Fee", value: DeliveryWords.money(a, "delivery_fee", currency: cur))
            }
            .padding(.vertical, 4)
        }
        if let actionError { Section { InlineErrorRow(error: actionError) } }
        let moves = DeliveryWords.ownerMoves(from: status)
        Section {
            ForEach(Array(moves.enumerated()), id: \.offset) { _, move in
                Button {
                    notes = ""
                    pending = move
                } label: {
                    Label(move.title, systemImage: DeliveryWords.assignmentStatus.symbol(for: move.status))
                }
                .buttonStyle(.large(move.destructive ? .danger : .progress, prominent: false))
                .listRowSeparator(.hidden)
            }
        } footer: {
            Text(moves.isEmpty && !["delivered", "failed", "rejected"].contains(status)
                 ? "The delivery partner marks the order picked up and delivered from their own app."
                 : "The delivery partner marks the order picked up and delivered; the order’s status follows.")
        }
        Section("Customer") {
            DetailRow(label: "Name", value: a.string("customer_name"))
            if let phone = a.string("customer_phone") { PhoneLinkRow(name: a.string("customer_name"), phone: phone) }
            if let email = a.string("customer_email") { EmailLinkRow(email: email) }
        }
        Section("Where") {
            DetailRow(label: "Pick up from", value: a.string("pickup_address"))
            DetailRow(label: "Deliver to", value: [a.string("delivery_address"), a.string("delivery_city"),
                                                  a.string("delivery_postal_code")].compactMap { $0 }.joined(separator: ", "))
            DetailRow(label: "Pick-up instructions", value: a.string("pickup_instructions"))
            DetailRow(label: "Delivery instructions", value: a.string("delivery_instructions"))
            DetailRow(label: "Distance", value: a.decimal("distance_km").map { "\($0.formatted()) km" })
        }
        Section("Delivery partner") {
            DetailRow(label: "Company", value: a.string("delivery_company"))
            DetailRow(label: "Contact", value: a.string("contact_person_name"))
            if let phone = a.string("contact_person_phone") { PhoneLinkRow(name: a.string("contact_person_name"), phone: phone) }
        }
        Section("Times") {
            DetailRow(label: "Accepted", value: Formatters.dateTime(a.date("accepted_at")))
            DetailRow(label: "Pick-up expected", value: Formatters.dateTime(a.date("estimated_pickup_time")))
            DetailRow(label: "Picked up", value: Formatters.dateTime(a.date("actual_pickup_time")))
            DetailRow(label: "Delivery expected", value: Formatters.dateTime(a.date("estimated_delivery_time")))
            DetailRow(label: "Delivered", value: Formatters.dateTime(a.date("actual_delivery_time")))
        }
        Section("Proof and notes") {
            DetailRow(label: "Tracking number", value: a.string("tracking_number"))
            DetailRow(label: "Proof of delivery", value: a.string("proof_of_delivery"))
            DetailRow(label: "Notes", value: a.string("notes"))
        }
    }

    private func load() async {
        if assignment.value == nil { assignment = .loading }
        do {
            let order = try await services.delivery.order(orderUUID)
            guard let uuid = order.string("delivery_assignment.uuid") else {
                assignment = .loaded(nil)
                return
            }
            assignment = .loaded(try await services.delivery.assignment(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            assignment = .failed(apiError)
        }
    }

    private func run(_ status: String) async {
        guard let uuid = assignment.value??.string("uuid") else { return }
        busy = true
        defer { busy = false }
        do {
            try await services.delivery.move(assignment: uuid, to: status, notes: notes)
            actionError = nil
            notice = "The delivery is now “\(DeliveryWords.assignmentStatus.label(for: status))”."
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

// MARK: - Prices

/// The platform's delivery prices and a fee estimate (read only: platform admins set the prices).
struct DeliveryPricesList: View {
    @Environment(\.services) private var services
    @State private var config: LoadState<Record?> = .idle
    @State private var distance = ""
    @State private var orderValue = ""
    @State private var estimate: Record?
    @State private var estimating = false
    @State private var estimateError: APIError?

    private var currency: String? { config.value??.string("currency") }

    var body: some View {
        List {
            switch config {
            case .idle, .loading:
                Section { ProgressView() }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let record):
                if let c = record {
                    Section {
                        DetailRow(label: "Starting fee", value: DeliveryWords.money(c, "base_fee", currency: currency))
                        DetailRow(label: "Per km", value: DeliveryWords.money(c, "per_km_rate", currency: currency))
                        DetailRow(label: "Free within", value: c.decimal("free_delivery_radius_km").map { "\($0.formatted()) km" })
                        DetailRow(label: "Lowest fee", value: DeliveryWords.money(c, "min_delivery_fee", currency: currency))
                        DetailRow(label: "Highest fee", value: DeliveryWords.money(c, "max_delivery_fee", currency: currency))
                        DetailRow(label: "Night surcharge", value: c.decimal("night_surcharge_percent").map { "\($0.formatted())%" })
                        DetailRow(label: "Busy-hours surcharge", value: c.decimal("peak_hour_surcharge").map { "\($0.formatted())%" })
                    } header: {
                        Text("Delivery prices")
                    } footer: {
                        Text("Set for the whole platform by its administrators.")
                    }
                    let brackets = c.records("distance_brackets")
                    if !brackets.isEmpty {
                        Section("By distance") {
                            ForEach(Array(brackets.enumerated()), id: \.offset) { _, bracket in
                                DetailRow(label: "Up to \(bracket.decimal("max_km")?.formatted() ?? "?") km",
                                          value: DeliveryWords.money(bracket, "rate", currency: currency).map { "\($0) per km" })
                            }
                        }
                    }
                }
            }
            Section {
                TextField("Distance in km", text: $distance).keyboardType(.decimalPad)
                    .accessibilityIdentifier("delivery.estimate.distance")
                TextField("Order value", text: $orderValue).keyboardType(.decimalPad)
                    .accessibilityIdentifier("delivery.estimate.value")
                Button { Task { await runEstimate() } } label: { Label("Estimate the fee", systemImage: "function") }
                    .disabled(Decimal(string: distance) == nil || estimating)
                    .accessibilityIdentifier("delivery.estimate.go")
                if let estimateError { InlineErrorRow(error: estimateError) }
                if let e = estimate {
                    let cur = e.string("estimate.currency") ?? currency
                    DetailRow(label: "Estimated fee", value: DeliveryWords.money(e, "estimate.estimated_fee", currency: cur))
                    DetailRow(label: "Range", value: [DeliveryWords.money(e, "estimate.min_fee", currency: cur),
                                                      DeliveryWords.money(e, "estimate.max_fee", currency: cur)]
                        .compactMap { $0 }.joined(separator: " to "))
                    DetailRow(label: "Starting fee", value: DeliveryWords.money(e, "estimate.breakdown.base", currency: cur))
                    DetailRow(label: "Distance", value: DeliveryWords.money(e, "estimate.breakdown.distance", currency: cur))
                    DetailRow(label: "Surcharges", value: DeliveryWords.money(e, "estimate.breakdown.surcharges", currency: cur))
                    if let note = e.string("note") { Text(note).font(.wsFootnote).foregroundStyle(.secondaryText) }
                }
            } header: {
                Text("Estimate a fee")
            } footer: {
                Text("A guide for what to offer a delivery partner.")
            }
        }
        .listStyle(.insetGrouped)
        .task { if config.value == nil { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            config = .loaded(try await services.delivery.pricing())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            config = .failed(apiError)
        }
    }

    private func runEstimate() async {
        estimating = true
        defer { estimating = false }
        do {
            estimate = try await services.delivery.estimate(distanceKm: distance.trimmingCharacters(in: .whitespaces),
                                                            orderValue: orderValue.trimmedOrNil ?? "0")
            estimateError = nil
        } catch {
            estimateError = error.asAPIError
        }
    }
}
