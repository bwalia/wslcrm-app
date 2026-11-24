import SwiftUI
import MapKit

/// The deal finder (`GET /map`): drop a search pin, choose a radius (5–50 miles) and layers; your
/// properties, deals, seller leads, buyers' holdings, suppliers and market data appear as coloured
/// pins. Tap one for its card (comparables, matching buyers, "Create a deal"). Or search the
/// Companies House index and create a lead from a company. Saved searches feed the daily deal scout.
struct PDMapView: View {
    /// Where to start ("lat,lng", from a deal's "Show on map"); nil starts at the newest deal.
    let start: CLLocationCoordinate2D?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var center = CLLocationCoordinate2D(latitude: 53.96, longitude: -1.08)
    @State private var position: MapCameraPosition = .automatic
    @State private var radius: Double = 25
    @State private var layers: Set<String> = ["properties", "deals", "sold_prices", "listings"]
    @State private var base = "deals"
    @State private var companyQuery = ""
    @State private var result: Record?
    @State private var companies: Record?
    @State private var selected: Record?
    @State private var loading = false
    @State private var loadError: APIError?
    @State private var notice: String?
    @State private var actionError: APIError?
    @State private var started = false
    @State private var createdDeal: PDDealRoute?
    @State private var createdLead: PDLeadRoute?

    init(start: CLLocationCoordinate2D? = nil) {
        self.start = start
    }

    /// `"53.9,-1.08"` → a coordinate.
    static func coordinate(_ text: String?) -> CLLocationCoordinate2D? {
        guard let parts = text?.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    static let layerNames: [Choice] = [
        Choice("properties", "My properties"), Choice("deals", "Deals"), Choice("leads", "Seller leads"),
        Choice("holdings", "Buyers’ holdings"), Choice("suppliers", "Suppliers"), Choice("sold_prices", "Sold prices"),
        Choice("epc", "EPC ratings"), Choice("listings", "Listings"), Choice("auction_lots", "Auction lots"),
    ]

    /// The web's layer colours (mapColours.ts).
    static let colours: [String: Color] = [
        "properties": Color(pdHex: 0x6366F1), "deals": Color(pdHex: 0x16A34A), "leads": Color(pdHex: 0x0EA5E9),
        "holdings": Color(pdHex: 0xA855F7), "suppliers": Color(pdHex: 0x92400E), "sold_prices": Color(pdHex: 0x64748B),
        "epc": Color(pdHex: 0xEAB308), "listings": Color(pdHex: 0xF97316), "auction_lots": Color(pdHex: 0xDB2777),
        "company": Color(pdHex: 0x0D9488),
    ]

    var body: some View {
        VStack(spacing: 0) {
            map.frame(minHeight: 280, maxHeight: 380)
            List {
                controls
                if let selected {
                    PDMapSelection(feature: selected, close: { self.selected = nil },
                                   openDeal: { createdDeal = PDDealRoute(uuid: $0) },
                                   openLead: { createdLead = PDLeadRoute(uuid: $0) }) { message, error in
                        notice = message
                        actionError = error
                    }
                } else {
                    Section {
                        Text(base == "companies" ? "Search Companies House, then tap a company pin to see it and create a lead."
                             : "Tap the map to move the search pin. Tap a dot for its details.")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                }
                if base == "deals" {
                    PDSavedSearchesSection(center: center, radius: radius, layers: layers) { lat, lng, miles in
                        center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                        radius = min(50, max(5, miles))
                        moveCamera()
                    } report: { message, error in
                        notice = message
                        actionError = error
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Deal finder")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $createdDeal) { PDDealView(dealUuid: $0.uuid) }
        .navigationDestination(item: $createdLead) { PDLeadView(leadUuid: $0.uuid) }
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError ?? loadError) }
        .task { await begin() }
        .task(id: searchKey) {
            guard started, base == "deals" else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var features: [Record] {
        base == "deals" ? (result?.records("features") ?? []) : companyFeatures
    }

    private var companyFeatures: [Record] {
        (companies?.records("companies", idKeys: ["company_number", "title"]) ?? []).compactMap { company in
            guard company.decimal("lat") != nil, company.decimal("lng") != nil else { return nil }
            var fields = company.fields
            fields["layer"] = .string("company")
            fields["subtitle"] = fields["address_snippet"] ?? fields["postcode"]
            return Record(fields, idKeys: ["company_number", "title"])
        }
    }

    private var searchKey: String {
        "\(center.latitude),\(center.longitude),\(Int(radius)),\(layers.sorted().joined(separator: ","))"
    }

    @ViewBuilder
    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if base == "deals" {
                    MapCircle(center: center, radius: radius * 1609.344)
                        .foregroundStyle(Tone.brand.color.opacity(0.08))
                        .stroke(Tone.brand.color.opacity(0.6), lineWidth: 1.5)
                    Marker("Search pin", systemImage: "scope", coordinate: center).tint(.red)
                }
                ForEach(features) { feature in
                    if let coordinate = Self.point(feature) {
                        Annotation(feature.string("title") ?? "", coordinate: coordinate, anchor: .center) {
                            Button { selected = feature } label: {
                                Circle()
                                    .fill(Self.colours[feature.string("layer") ?? ""] ?? .gray)
                                    .stroke(.white, lineWidth: 2)
                                    .frame(width: selected?.id == feature.id ? 22 : 14, height: selected?.id == feature.id ? 22 : 14)
                                    .shadow(radius: 1)
                            }
                            .accessibilityLabel("\(Formatters.humanize(feature.string("layer"))): \(feature.string("title") ?? "")")
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { point in
                guard base == "deals", let coordinate = proxy.convert(point, from: .local) else { return }
                center = coordinate
                selected = nil
            }
            .accessibilityIdentifier("pd.map.map")
        }
    }

    @ViewBuilder
    private var controls: some View {
        Section {
            Picker("Map shows", selection: $base) {
                Text("My deals").tag("deals")
                Text("Companies House").tag("companies")
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pd.map.base")
            .onChange(of: base) { _, _ in selected = nil }
            if base == "deals" {
                VStack(alignment: .leading) {
                    Text("Radius: \(Int(radius)) miles").font(.wsSubheadline)
                    Slider(value: $radius, in: 5...50, step: 5) { Text("Radius") }
                        .accessibilityValue("\(Int(radius)) miles")
                        .accessibilityIdentifier("pd.map.radius")
                }
                DisclosureGroup("Layers (\(layers.count) shown)") {
                    ForEach(Self.layerNames) { layer in
                        Toggle(isOn: Binding(get: { layers.contains(layer.value) },
                                             set: { on in if on { layers.insert(layer.value) } else { layers.remove(layer.value) } })) {
                            HStack {
                                Circle().fill(Self.colours[layer.value] ?? .gray).frame(width: 10, height: 10).accessibilityHidden(true)
                                Text(layer.label)
                                if let count = result?.int("counts.\(layer.value)") {
                                    Text("(\(count))").foregroundStyle(.secondaryText)
                                }
                            }
                        }
                        .accessibilityIdentifier("pd.map.layer.\(layer.value)")
                    }
                }
                if loading { HStack { ProgressView(); Text("Loading pins…") } }
                if result?.bool("truncated") == true {
                    Text("Showing the nearest 2,000. Use a smaller radius to see the rest.").font(.wsFootnote)
                }
            } else {
                HStack {
                    TextField("Company name or number", text: $companyQuery)
                        .submitLabel(.search)
                        .onSubmit { Task { await searchCompanies() } }
                        .accessibilityIdentifier("pd.map.companyQuery")
                    Button("Search") { Task { await searchCompanies() } }
                        .disabled(companyQuery.trimmedOrNil == nil || loading)
                }
                if let companies {
                    let total = companies.int("total") ?? 0
                    let mapped = companies.int("mapped") ?? 0
                    Text(total == 0 ? "No companies found. Try a different search."
                         : "\(mapped) of \(total) on the map\(total > mapped ? " (others have no UK postcode)" : "").")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
        }
    }

    static func point(_ feature: Record) -> CLLocationCoordinate2D? {
        guard let lat = feature.decimal("lat"), let lng = feature.decimal("lng") else { return nil }
        return CLLocationCoordinate2D(latitude: NSDecimalNumber(decimal: lat).doubleValue,
                                      longitude: NSDecimalNumber(decimal: lng).doubleValue)
    }

    private func begin() async {
        guard !started else { return }
        if let start {
            center = start
        } else if let deals = try? await services.pdRaw.rows("/deals", ["sort": "created", "per_page": "20"]),
                  let first = deals.compactMap(Self.point).first {
            center = first
        }
        moveCamera(zoomedIn: start != nil)
        started = true
        await load()
    }

    private func moveCamera(zoomedIn: Bool = false) {
        let span = zoomedIn ? 3_000.0 : radius * 1609.344 * 2.4
        position = .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            result = try await services.pdRaw.record("/map", Self.query(center: center, radius: radius, layers: layers))
            loadError = nil
            // Arriving from a deal: select its pin.
            if let start, selected == nil {
                selected = result?.records("features").first {
                    guard let p = Self.point($0) else { return false }
                    return abs(p.latitude - start.latitude) + abs(p.longitude - start.longitude) < 1e-4
                }
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    static func query(center: CLLocationCoordinate2D, radius: Double, layers: Set<String>) -> [String: String?] {
        ["lat": String(format: "%.6f", center.latitude), "lng": String(format: "%.6f", center.longitude),
         "radius_miles": String(Int(radius)), "layers": layers.sorted().joined(separator: ",")]
    }

    private func searchCompanies() async {
        guard let query = companyQuery.trimmedOrNil else { return }
        loading = true
        defer { loading = false }
        selected = nil
        do {
            companies = try await services.pdRaw.record("/finder/companies", ["q": query])
            actionError = nil
            if let first = companyFeatures.compactMap(Self.point).first {
                position = .region(MKCoordinateRegion(center: first, latitudinalMeters: 400_000, longitudinalMeters: 400_000))
            }
        } catch {
            actionError = error.asAPIError
        }
    }
}

extension Color {
    /// `0x16A34A` → a colour (the web's map palette).
    init(pdHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The card for a tapped pin: your property (comparables, matching buyers, its deal or "Create a
/// deal"), a supplier, a market record, or a Companies House company ("Create a lead").
private struct PDMapSelection: View {
    let feature: Record
    let close: () -> Void
    let openDeal: (String) -> Void
    let openLead: (String) -> Void
    let report: (String?, APIError?) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var card: Record?
    @State private var working = false

    private var layer: String { feature.string("layer") ?? "" }
    private var isOwn: Bool { layer == "properties" || layer == "deals" }

    var body: some View {
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.string("title") ?? "Pin").font(.wsHeadline)
                    Text([Formatters.humanize(layer), feature.string("subtitle"),
                          feature.decimal("distance_miles").map { "\($0.formatted(.number.precision(.fractionLength(1)))) miles" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill") { close() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondaryText)
            }
            .task(id: feature.id) {
                guard isOwn else { return }
                card = try? await services.pdRaw.record("/properties/\(feature.id)/card")
            }
            if layer == "company" {
                companyRows
            } else if layer == "suppliers" {
                DetailRow(label: "Does", value: feature.strings("kinds").map(Formatters.humanize).joined(separator: ", ").trimmedOrNil ?? "Supplier")
                if let phone = feature.string("phone") { PhoneLinkRow(name: "Call", phone: phone) }
                if let email = feature.string("email") { EmailLinkRow(email: email) }
                if let website = feature.string("website") { CopyableRow(label: "Website", value: website) }
            } else if !isOwn {
                marketRows
            } else if let card {
                ownRows(card)
            } else {
                SkeletonRow()
            }
        }
    }

    @ViewBuilder
    private var marketRows: some View {
        if let price = feature.pounds("price") {
            PDFigureRow(label: "Price", value: price + (feature.pounds("previous_price").map { " (was \($0))" } ?? ""))
        }
        if let day = feature.string("event_date") { DetailRow(label: "Date", value: PDDates.day(day) ?? day) }
        if let epc = feature.string("epc_rating") { DetailRow(label: "EPC", value: epc) }
        if let type = feature.string("property_type") { DetailRow(label: "Type", value: Formatters.humanize(type)) }
        if feature.bool("cash_only") == true { DetailRow(label: "Buyers", value: "Cash only") }
        if let link = feature.string("url"), let url = URL(string: link) {
            Link(destination: url) { Label("The listing", systemImage: "link") }
        }
    }

    @ViewBuilder
    private func ownRows(_ card: Record) -> some View {
        if let deal = card.object("deal") {
            NavigationLink(value: PDDealRoute(uuid: deal.id)) {
                HStack {
                    Label(deal.string("name") ?? "Deal", systemImage: "house")
                    Spacer()
                    (PDHealth(rawValue: deal.string("health") ?? "") ?? .unknown).badge
                }
            }
        }
        PDFigureRow(label: "Gross yield", value: card.number("gross_yield_pct").map { "\($0)%" })
        PDFigureRow(label: "Comparables", value: (card.int("comps.count") ?? 0) > 0
                    ? "\(card.int("comps.count") ?? 0) · median \(card.pounds("comps.median") ?? "—")" : "None yet")
        PDFigureRow(label: "Discount against comparables", value: card.number("discount_vs_comps_pct").map { "\($0)%" })
        let matches = card.records("top_matches")
        if matches.isEmpty {
            Text("No buyer profiles match yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
        }
        ForEach(matches) { match in
            PDMatchRow(match: match, showProperty: false, canSend: session.propertyDeals?.can(.update, .buyers) ?? false) { message, error in
                report(message, error)
            }
        }
        if card.object("deal") == nil, session.propertyDeals?.can(.create, .deals) ?? false {
            Button("Create a deal for this home", systemImage: "plus.circle") { Task { await createDeal() } }
                .disabled(working)
                .accessibilityIdentifier("pd.map.createDeal")
        }
    }

    @ViewBuilder
    private var companyRows: some View {
        if let number = feature.string("company_number") {
            CopyableRow(label: "Company number", value: number)
            if let url = URL(string: "https://find-and-update.company-information.service.gov.uk/company/\(number)") {
                Link(destination: url) { Label("Companies House profile", systemImage: "building.columns") }
            }
        }
        if let status = feature.string("company_status") { DetailRow(label: "Status", value: Formatters.humanize(status)) }
        if let address = feature.string("address_snippet") { DetailRow(label: "Address", value: address) }
        // POST /finder/companies/lead needs property_deals_leads.create.
        if session.propertyDeals?.can(.create, .leads) ?? false {
            Button("Create a lead from this company", systemImage: "person.badge.plus") { Task { await createLead() } }
                .disabled(working)
                .accessibilityIdentifier("pd.map.createLead")
        }
    }

    private func createDeal() async {
        working = true
        defer { working = false }
        do {
            let deal = PDRaw.record(try await services.pdRaw.send(.post, "/deals", ["property_uuid": .string(feature.id),
                                                                                  "deal_type": .string("buy")], idempotent: true))
            report("Deal created.", nil)
            if let uuid = deal?.string("uuid") { openDeal(uuid) }
        } catch {
            report(nil, error.asAPIError)
        }
    }

    private func createLead() async {
        working = true
        defer { working = false }
        var body: [String: JSONValue] = ["title": .string(feature.string("title") ?? "Company")]
        body["company_number"] = feature.string("company_number").map(JSONValue.string)
        body["address_snippet"] = feature.string("address_snippet").map(JSONValue.string)
        do {
            let lead = PDRaw.record(try await services.pdRaw.send(.post, "/finder/companies/lead", body, idempotent: true))
            report("Lead created.", nil)
            if let uuid = lead?.string("uuid") { openLead(uuid) }
        } catch {
            report(nil, error.asAPIError)
        }
    }
}

/// Saved searches (the deal scout re-runs them every morning) and its new alerts.
private struct PDSavedSearchesSection: View {
    let center: CLLocationCoordinate2D
    let radius: Double
    let layers: Set<String>
    let open: (Double, Double, Double) -> Void
    let report: (String?, APIError?) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var confirm: PendingConfirmation?
    @State private var searches: [Record] = []
    @State private var alerts: [Record] = []
    @State private var name = ""

    var body: some View {
        Section {
            if session.propertyDeals?.can(.create, .properties) ?? false {
                HStack {
                    TextField("Name this pin and radius", text: $name).accessibilityIdentifier("pd.map.searchName")
                    Button("Save") { Task { await save() } }.disabled(name.trimmedOrNil == nil)
                }
            }
            if searches.isEmpty { Text("No saved searches yet.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(searches) { search in
                HStack {
                    Button(search.string("name") ?? "Search") {
                        if let lat = search.decimal("lat"), let lng = search.decimal("lng") {
                            open(NSDecimalNumber(decimal: lat).doubleValue, NSDecimalNumber(decimal: lng).doubleValue,
                                 NSDecimalNumber(decimal: search.decimal("radius_miles") ?? 25).doubleValue)
                        }
                    }
                    Spacer()
                    Button("Run", systemImage: "play.circle") { Task { await run(search) } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .accessibilityLabel("Run \(search.string("name") ?? "search") now")
                }
                .swipeActions(allowsFullSwipe: false) {
                    if session.propertyDeals?.can(.delete, .properties) ?? false {
                        Button("Delete", role: .destructive) {
                            confirm = PendingConfirmation(title: "Delete \(search.string("name") ?? "this search")?",
                                                          message: "The deal scout stops running it.",
                                                          button: "Delete search") { await delete(search) }
                        }
                    }
                }
            }
        } header: {
            Text("Saved searches").task { await load() }.workConfirmation($confirm)
        } footer: {
            Text("The deal scout re-runs these every morning and alerts you. Swipe one to delete it.")
        }
        Section {
            if alerts.isEmpty { Text("Nothing new.").font(.wsSubheadline).foregroundStyle(.secondaryText) }
            ForEach(alerts.prefix(20)) { alert in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        StatusBadge(text: Formatters.humanize(alert.string("kind")), systemImage: "bell",
                                    tone: alert.string("kind") == "reduced" ? .success : alert.string("kind") == "new" ? .info : .neutral)
                        Text(alert.string("address") ?? alert.string("postcode") ?? "").font(.wsBody)
                    }
                    Text([alert.string("detail"), alert.string("saved_search_name")].compactMap { $0 }.joined(separator: " · "))
                        .font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            if !alerts.isEmpty {
                Button("Mark all seen") { Task { await markSeen() } }.accessibilityIdentifier("pd.map.alertsSeen")
            }
        } header: {
            Text("New alerts")
        }
    }

    private func load() async {
        let raw = services.pdRaw
        searches = (try? await raw.rows("/saved-searches", ["per_page": "100"])) ?? searches
        alerts = (try? await raw.rows("/scout-alerts", ["unseen": "true"])) ?? alerts
    }

    private func save() async {
        guard let text = name.trimmedOrNil else { return }
        do {
            try await services.pdRaw.send(.post, "/saved-searches", [
                "name": .string(text), "lat": .number(center.latitude), "lng": .number(center.longitude),
                "radius_miles": .number(radius), "filters": .object(["layers": .array(layers.sorted().map(JSONValue.string))]),
            ], idempotent: true)
            name = ""
            report("Search saved. The deal scout will re-run it every morning.", nil)
            await load()
        } catch {
            report(nil, error.asAPIError)
        }
    }

    private func run(_ search: Record) async {
        do {
            let counts = PDRaw.record(try await services.pdRaw.send(.post, "/saved-searches/\(search.id)/run"))
            report("New \(counts?.int("new") ?? 0), reduced \(counts?.int("reduced") ?? 0), stale \(counts?.int("stale") ?? 0), cash only \(counts?.int("cash_only") ?? 0).", nil)
            await load()
        } catch {
            report(nil, error.asAPIError)
        }
    }

    private func delete(_ search: Record) async {
        do {
            try await services.pdRaw.send(.delete, "/saved-searches/\(search.id)")
            report("Saved search deleted. The deal scout stops re-running it.", nil)
            await load()
        } catch {
            report(nil, error.asAPIError)
        }
    }

    private func markSeen() async {
        do {
            try await services.pdRaw.send(.post, "/scout-alerts/seen")
            report("Alerts marked as seen.", nil)
            await load()
        } catch {
            report(nil, error.asAPIError)
        }
    }
}
