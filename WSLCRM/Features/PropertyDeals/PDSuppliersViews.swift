import SwiftUI

/// The trades and firms for property deals (EPC assessors, surveyors, solicitors…), with how fast
/// they really are: search, filter by type or active, sort by name, speed, on-time or rating; add one
/// (it creates the CRM company too) and "Book the nearest".
struct PDSuppliersView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        PDSuppliersList(raw: services.pdRaw, canCreate: session.propertyDeals?.can(.create, .suppliers) ?? false,
                        canBook: PDWriteGates.canBookNearest(session.propertyDeals))
    }

    /// `GET /suppliers` query (search is `q`; kind is one of the kinds).
    static func query(search: String, kind: String, sort: String, active: String) -> [String: String?] {
        ["q": search.trimmedOrNil, "kind": kind.trimmedOrNil, "sort": sort, "active": active.trimmedOrNil]
    }
}

@MainActor
private final class PDSuppliersSource {
    let raw: PDRaw
    var kind = ""
    var sort = "name"
    var active = ""
    init(raw: PDRaw) { self.raw = raw }

    func fetch(search: String, page: Int) async throws -> Page<Record> {
        try await raw.page("/suppliers", PDSuppliersView.query(search: search, kind: kind, sort: sort, active: active), page: page)
    }
}

private struct PDSuppliersList: View {
    let canCreate: Bool
    let canBook: Bool
    @State private var source: PDSuppliersSource
    @State private var model: PagedListModel<Record>
    @State private var kind = ""
    @State private var sort = "name"
    @State private var active = ""
    @State private var adding = false
    @State private var booking = false
    @State private var notice: String?
    @State private var appeared = false

    init(raw: PDRaw, canCreate: Bool, canBook: Bool) {
        self.canCreate = canCreate
        self.canBook = canBook
        let source = PDSuppliersSource(raw: raw)
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in try await source.fetch(search: search, page: page) })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search by name or town", emptyTitle: "No suppliers yet",
                  emptySystemImage: "wrench.and.screwdriver",
                  emptyDescription: "EPC assessors, surveyors, solicitors and more, with how fast they really are.",
                  emptyActionTitle: "Add supplier", emptyAction: canCreate ? { adding = true } : nil) { supplier in
            NavigationLink(value: NativeScreenRoute("pd.supplier", supplier.id)) { PDSupplierRow(supplier: supplier) }
                .accessibilityIdentifier("pd.suppliers.row.\(supplier.id)")
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Text("Trades and firms for property deals. Suppliers of goods are under Shop → Suppliers.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.vertical, 6)
                PDNoticeBar(notice: notice, error: nil)
            }
            .background(.bar)
        }
        .navigationTitle("Property suppliers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Type", selection: $kind) {
                        Text("Any type").tag("")
                        ForEach(ModuleCatalog.pdSupplierKinds) { Text($0.label).tag($0.value) }
                    }
                    Picker("Sort", selection: $sort) {
                        Text("Name").tag("name")
                        Text("Fastest").tag("speed")
                        Text("Most on time").tag("on_time")
                        Text("Rating").tag("rating")
                    }
                    Picker("Active", selection: $active) {
                        Text("Active or not").tag("")
                        Text("Active").tag("true")
                        Text("Not active").tag("false")
                    }
                } label: {
                    Label("Filter", systemImage: kind.isEmpty && active.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                                 : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("pd.suppliers.filter")
            }
            if canBook {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { booking = true } label: { Label("Book the nearest", systemImage: "location.north.circle") }
                        .accessibilityIdentifier("pd.suppliers.bookNearest")
                }
            }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add supplier", systemImage: "plus") }
                        .accessibilityIdentifier("pd.suppliers.add")
                }
            }
        }
        .onChange(of: kind) { _, value in source.kind = value; Task { await model.load() } }
        .onChange(of: sort) { _, value in source.sort = value; Task { await model.load() } }
        .onChange(of: active) { _, value in source.active = value; Task { await model.load() } }
        .onAppear {
            if appeared { Task { await model.load() } }
            appeared = true
        }
        .sheet(isPresented: $adding) {
            PDSupplierFormSheet(supplier: nil) { name in notice = "\(name) added."; Task { await model.load() } }
        }
        .sheet(isPresented: $booking) {
            PDBookNearestSheet { message in notice = message }
        }
    }
}

private struct PDSupplierRow: View {
    let supplier: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(supplier.string("name") ?? "Supplier").font(.wsHeadline)
                Spacer()
                if supplier.bool("active") == false { StatusBadge(text: "Not active", systemImage: "pause.circle", tone: .neutral) }
            }
            Text(PDSupplierWords.kinds(supplier)).font(.wsSubheadline).foregroundStyle(.secondaryText)
            Text(PDSupplierWords.speed(supplier)).font(.wsCaption).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

enum PDSupplierWords {
    static func kinds(_ supplier: Record) -> String {
        let kinds = supplier.strings("kinds").map { PDBuyerWords.label(ModuleCatalog.pdSupplierKinds, $0) }
        return kinds.isEmpty ? "Supplier" : kinds.joined(separator: ", ")
    }

    static func speed(_ supplier: Record) -> String {
        var parts: [String] = []
        if let hours = supplier.number("avg_turnaround_hours", places: 0) { parts.append("\(hours) h turnaround") }
        if let onTime = supplier.number("on_time_pct", places: 0) { parts.append("\(onTime)% on time") }
        parts.append("\(supplier.int("jobs_measured") ?? 0) jobs measured")
        if let miles = supplier.number("radius_miles", places: 0) { parts.append("covers \(miles) miles") }
        if let source = supplier.string("source"), source != "manual" {
            parts.append(source == "sra" ? "from the SRA register" : "from an AI web search")
        }
        return parts.joined(separator: " · ")
    }
}

/// One supplier (`GET /suppliers/{id}`): contact, what they do, how fast they are, where they work;
/// edit everything (`PUT`, the CRM company's name and contact too) or delete it.
struct PDSupplierDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var supplier: Record?
    @State private var loadError: APIError?
    @State private var editing = false
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let loadError, supplier == nil { InlineErrorRow(error: loadError) { Task { await load() } } }
            if let supplier {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(supplier.string("name") ?? "Supplier").font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                        Text(PDSupplierWords.kinds(supplier)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    if let phone = supplier.string("phone") { PhoneLinkRow(name: "Call", phone: phone) }
                    if let email = supplier.string("email") { EmailLinkRow(email: email) }
                    if let website = supplier.string("website") { CopyableRow(label: "Website", value: website) }
                    DetailRow(label: "Active", value: supplier.bool("active") == false ? "No" : "Yes")
                    if let ref = supplier.string("register_ref") { DetailRow(label: "SRA number", value: ref) }
                }
                Section("How fast they are") {
                    PDFigureRow(label: "Average turnaround", value: supplier.number("avg_turnaround_hours", places: 0).map { "\($0) hours" })
                    PDFigureRow(label: "On time", value: supplier.number("on_time_pct", places: 0).map { "\($0)%" })
                    PDFigureRow(label: "Jobs measured", value: supplier.string("jobs_measured") ?? "0")
                    PDFigureRow(label: "Rating", value: supplier.number("rating").map { "\($0) of 5" })
                }
                Section("Where") {
                    DetailRow(label: "Address", value: [supplier.string("address_line1"), supplier.string("city"),
                                                        supplier.string("postal_code")].compactMap { $0 }.joined(separator: ", ").trimmedOrNil)
                    PDFigureRow(label: "Covers", value: supplier.number("radius_miles", places: 0).map { "\($0) miles" })
                    if supplier.string("base_lat") == nil {
                        Text("No base set, so “Book the nearest” can’t measure distance to them.").font(.wsFootnote)
                    }
                }
                Section("Booking") {
                    DetailRow(label: "Book by", value: supplier.string("booking_method").map {
                        PDBuyerWords.label(ModuleCatalog.pdBookingMethods, $0)
                    })
                    if let notes = supplier.string("notes") { Text(notes).font(.wsBody) }
                }
                if session.propertyDeals?.can(.delete, .suppliers) ?? false {
                    Section {
                        DeleteButton(title: "Delete supplier",
                                     message: "The supplier record is removed; the CRM company stays.") { await delete() }
                    }
                }
            }
        }
        .overlay { if supplier == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("Supplier")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if session.propertyDeals?.can(.update, .suppliers) ?? false {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.disabled(supplier == nil)
                        .accessibilityIdentifier("pd.supplier.edit")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $editing) {
            if let supplier {
                PDSupplierFormSheet(supplier: supplier) { _ in notice = "Supplier saved."; Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            supplier = try await services.pdRaw.record("/suppliers/\(uuid)")
            loadError = nil
        } catch {
            if supplier == nil { loadError = error.asAPIError }
        }
    }

    private func delete() async -> Bool {
        do {
            try await services.pdRaw.send(.delete, "/suppliers/\(uuid)")
            return true
        } catch {
            actionError = error.asAPIError
            return false
        }
    }
}

extension ModuleCatalog {
    static let pdSupplierKinds = [
        Choice("epc_assessor", "EPC assessor"), Choice("surveyor"), Choice("solicitor"), Choice("conveyancer"), Choice("broker"),
        Choice("bridging_lender", "Bridging lender"), Choice("builder"), Choice("estate_agent", "Estate agent"),
        Choice("letting_agent", "Letting agent"), Choice("auction_house", "Auction house"),
        Choice("managing_agent", "Managing agent"), Choice("searches_provider", "Searches provider"),
        Choice("freeholder"), Choice("council"),
    ]

    static let pdBookingMethods = [Choice("email"), Choice("phone"), Choice("link", "Booking link"), Choice("api", "Online (API)")]
}

/// Add a supplier (`POST /suppliers`, which creates the CRM company) or change one (`PUT`, only what
/// changed): name and contact, what they do (any number of kinds), where they work, how to book,
/// rating, notes and whether they're active.
struct PDSupplierFormSheet: View {
    let supplier: Record?
    let onSaved: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var original: [String: String] = [:]
    @State private var kinds: Set<String> = ["epc_assessor"]
    @State private var originalKinds: Set<String> = []
    @State private var base = ""
    @State private var saving = false
    @State private var error: APIError?
    @State private var prepared = false

    static let fields = ["name", "email", "phone", "website", "address_line1", "city", "postal_code", "radius_miles",
                         "booking_method", "rating", "notes", "active"]
    static let numbers: Set<String> = ["radius_miles", "rating"]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Company name (needed)", text: binding("name")).accessibilityIdentifier("pd.supplierForm.name")
                    TextField("Email (booking requests go here)", text: binding("email")).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Phone", text: binding("phone")).keyboardType(.phonePad)
                    TextField("Website", text: binding("website")).keyboardType(.URL).textInputAutocapitalization(.never)
                    Toggle("Active", isOn: Binding(get: { values["active"] != "false" }, set: { values["active"] = $0 ? "true" : "false" }))
                }
                Section("What they do") { PDMultiChoice(choices: ModuleCatalog.pdSupplierKinds, selected: $kinds) }
                Section {
                    TextField("Address", text: binding("address_line1"))
                    TextField("Town", text: binding("city"))
                    TextField("Postcode", text: binding("postal_code")).textInputAutocapitalization(.characters)
                    TextField("Base: town, postcode or lat,lng", text: $base)
                    TextField("Covers (miles)", text: binding("radius_miles")).keyboardType(.numberPad)
                } header: {
                    Text("Where they work")
                } footer: {
                    Text("The base is used by “Book the nearest”. A town or postcode is placed on the map by your phone.")
                }
                Section {
                    Picker("Book by", selection: binding("booking_method")) {
                        Text("Not said").tag("")
                        ForEach(ModuleCatalog.pdBookingMethods) { Text($0.label).tag($0.value) }
                    }
                    TextField("Rating (0 to 5)", text: binding("rating")).keyboardType(.decimalPad)
                    TextField("Notes", text: binding("notes"), axis: .vertical).lineLimit(2...6)
                }
            }
            .navigationTitle(supplier == nil ? "Add a supplier" : "Edit supplier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(supplier == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(saving || (values["name"] ?? "").trimmedOrNil == nil || kinds.isEmpty)
                        .accessibilityIdentifier("pd.supplierForm.save")
                }
            }
            .onAppear(perform: prepare)
            .interactiveDismissDisabled(saving)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        guard let supplier else { values = ["active": "true"]; return }
        values = Self.values(of: supplier)
        original = values
        kinds = Set(supplier.strings("kinds"))
        originalKinds = kinds
        if let lat = supplier.string("base_lat"), let lng = supplier.string("base_lng") { base = "\(lat),\(lng)" }
    }

    static func values(of supplier: Record) -> [String: String] {
        var values: [String: String] = [:]
        for key in fields { values[key] = supplier.string(key) ?? "" }
        values["active"] = supplier.bool("active") == false ? "false" : "true"
        return values
    }

    /// The save body: a new supplier gets everything filled in; an edit only what changed. Kinds
    /// always go as a list; a cleared number is sent as "" (the server clears it).
    static func body(values: [String: String], original: [String: String], kinds: Set<String>, kindsChanged: Bool,
                     base: (Double, Double)?, baseChanged: Bool, isNew: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        for key in fields where isNew || values[key] != original[key] {
            let text = (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "active" { body[key] = .bool(text != "false"); continue }
            if numbers.contains(key) {
                if let number = JSONValue.number(text: text) { body[key] = number } else if !isNew { body[key] = .string("") }
            } else if !text.isEmpty {
                body[key] = .string(text)
            } else if !isNew, key != "name", key != "booking_method" {
                body[key] = .string("")
            }
        }
        if isNew || kindsChanged { body["kinds"] = .array(kinds.sorted().map(JSONValue.string)) }
        if baseChanged {
            if let base { body["base_lat"] = .number(base.0); body["base_lng"] = .number(base.1) }
            else if !isNew { body["base_lat"] = .string(""); body["base_lng"] = .string("") }
        }
        return body
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let originalBase = supplier.flatMap { s in s.string("base_lat").flatMap { lat in s.string("base_lng").map { "\(lat),\($0)" } } } ?? ""
        let baseChanged = base.trimmingCharacters(in: .whitespaces) != originalBase
        var point: (Double, Double)?
        if baseChanged, let place = base.trimmedOrNil {
            guard let found = await PDNewBuyerSheet.locate(place) else {
                error = ResourceService.problem(422, "Couldn’t find “\(place)”. Try a town, a postcode or lat,lng.")
                return
            }
            point = (found.latitude, found.longitude)
        }
        let body = Self.body(values: values, original: original, kinds: kinds, kindsChanged: kinds != originalKinds,
                             base: point, baseChanged: baseChanged, isNew: supplier == nil)
        do {
            if let supplier {
                if !body.isEmpty { try await services.pdRaw.send(.put, "/suppliers/\(supplier.id)", body) }
            } else {
                try await services.pdRaw.send(.post, "/suppliers", body, idempotent: true)
            }
            onSaved((values["name"] ?? "").trimmingCharacters(in: .whitespaces))
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// Pick a deal and a service; the nearest active suppliers are listed (`POST /suppliers/nearest`),
/// then a booking task the booking agent can work on is added to the deal.
struct PDBookNearestSheet: View {
    let onDone: (String) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var deals: [Record] = []
    @State private var deal = ""
    @State private var kind = "epc_assessor"
    @State private var rows: [Record]?
    @State private var working = false
    @State private var error: APIError?

    static let taskTitles = ["epc_assessor": "Book an EPC assessor", "surveyor": "Book survey or lender valuation"]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    Picker("Deal", selection: $deal) {
                        Text("Choose…").tag("")
                        ForEach(deals) { Text($0.string("name") ?? "Deal").tag($0.id) }
                    }
                    .accessibilityIdentifier("pd.bookNearest.deal")
                    Picker("Service", selection: $kind) {
                        ForEach(ModuleCatalog.pdSupplierKinds) { Text($0.label).tag($0.value) }
                    }
                    Button("Find the nearest", systemImage: "location.magnifyingglass") { Task { await find() } }
                        .disabled(working || propertyUuid == nil)
                        .accessibilityIdentifier("pd.bookNearest.find")
                } footer: {
                    if !deal.isEmpty, propertyUuid == nil { Text("This deal has no property yet, so distances can’t be worked out.") }
                }
                if let rows {
                    Section("Nearest") {
                        if rows.isEmpty { Text("No active \(Formatters.humanize(kind).lowercased()) in your suppliers.") }
                        ForEach(rows, id: \.self) { row in
                            HStack {
                                Text(row.string("name") ?? "Supplier")
                                Spacer()
                                Text(Self.detail(row)).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Book the nearest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create booking task") { Task { await createTask() } }
                        .disabled(working || deal.isEmpty || (rows ?? []).isEmpty)
                        .accessibilityIdentifier("pd.bookNearest.create")
                }
            }
            .task { deals = (try? await services.pdRaw.rows("/deals", ["per_page": "100", "status": "active"])) ?? [] }
            .onChange(of: deal) { _, _ in rows = nil }
            .onChange(of: kind) { _, _ in rows = nil }
        }
    }

    private var propertyUuid: String? { deals.first { $0.id == deal }?.string("property_uuid") }

    static func detail(_ row: Record) -> String {
        var parts = [row.decimal("distance_miles").map { "\($0.formatted(.number.precision(.fractionLength(1)))) mi" } ?? "no base set"]
        if let onTime = row.number("on_time_pct", places: 0) { parts.append("\(onTime)% on time") }
        return parts.joined(separator: " · ")
    }

    private func find() async {
        guard let property = propertyUuid else { return }
        working = true
        defer { working = false }
        do {
            rows = PDRaw.rows(try await services.pdRaw.send(.post, "/suppliers/nearest", [
                "kind": .string(kind), "property_uuid": .string(property), "limit": .number(5),
            ]) ?? .array([]), idKeys: ["supplier_uuid"])
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    private func createTask() async {
        working = true
        defer { working = false }
        do {
            try await services.pdRaw.send(.post, "/tasks", Self.taskBody(deal: deal, property: propertyUuid, kind: kind), idempotent: true)
            onDone("Booking task added to the deal. Open it and choose “Let AI do it” to ask for slots.")
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }

    static func taskBody(deal: String, property: String?, kind: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "deal_uuid": .string(deal), "title": .string(taskTitles[kind] ?? "Book \(Formatters.humanize(kind).lowercased())"),
            "agent_eligible": .bool(true), "agent_key": .string("booking_agent"), "approval_rule": .string("any_operator"),
            "blocking": .bool(true),
        ]
        body["property_uuid"] = property.map(JSONValue.string)
        return body
    }
}
