import SwiftUI

/// The deal autopilot (`GET /deals/{id}/research`): pin the home, official data about the area,
/// an AI web search for the area and firms, conveyancers from the SRA register, and quote
/// requests waiting in Approvals. A person picks what to keep: save a firm, ask it for a quote,
/// make a conveyancer our solicitor on the deal.
struct PDDealResearchView: View {
    let dealUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<Record> = .idle
    @State private var deal: Record?
    @State private var parties: [Record] = []
    @State private var starting = false
    @State private var busy: String?
    @State private var addingProperty = false
    @State private var notice: String?
    @State private var actionError: APIError?

    static let areas = [
        Choice("summary", "The area"), Choice("transport", "Transport"), Choice("schools", "Schools"),
        Choice("amenities", "Shops and amenities"), Choice("flood_risk", "Flood risk"), Choice("planning", "Planning nearby"),
        Choice("market", "Prices and sales"),
    ]
    static let steps = ["pin": "Pin the home on the map", "research": "Search the web about the area",
                        "register": "Find conveyancers on the SRA register", "quotes": "Draft quote requests"]
    static let quoteStatus: [String: (String, Tone)] = [
        "pending": ("Waiting for approval", .warning), "approved": ("Approved, sending", .info), "executed": ("Sent", .success),
        "rejected": ("Turned down", .neutral), "cancelled": ("Cancelled", .neutral), "failed": ("Couldn’t send", .danger),
    ]

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ForEach(0..<4, id: \.self) { _ in SkeletonRow() }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let research): content(research)
            }
        }
        .navigationTitle("AI research")
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .toolbar {
            if session.propertyDeals?.can(.create, .ai) ?? false, let research = state.value {
                ToolbarItem(placement: .primaryAction) {
                    Button(research.object("run") == nil ? "Research now" : "Research again", systemImage: "sparkles") {
                        Task { await start() }
                    }
                    .disabled(starting || research.string("run.status") == "running")
                    .accessibilityIdentifier("pd.research.start")
                }
            }
        }
        .task { await load() }
        .task(id: state.value?.string("run.status")) {
            // While a run is going, look again every few seconds.
            guard state.value?.string("run.status") == "running" else { return }
            while !Task.isCancelled, state.value?.string("run.status") == "running" {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
        .refreshable { await load() }
        .sheet(isPresented: $addingProperty) {
            PDAddPropertySheet(dealUuid: dealUuid) { notice = "Property added to the deal."; Task { await load() } }
        }
    }

    @ViewBuilder
    private func content(_ research: Record) -> some View {
        Section {
            Label(Self.runStatus(research.object("run")), systemImage: research.string("run.status") == "running" ? "hourglass" : "sparkles")
                .accessibilityIdentifier("pd.research.status")
            if research.object("property") == nil || research.string("property.lat") == nil {
                if PDWriteGates.canAddPropertyToDeal(session.propertyDeals) {
                    Button("Add the property", systemImage: "house.badge.plus") { addingProperty = true }
                        .accessibilityIdentifier("pd.research.addProperty")
                }
            } else if let lat = research.string("property.lat"), let lng = research.string("property.lng") {
                NavigationLink(value: NativeScreenRoute("pd.map", "\(lat),\(lng)")) {
                    Label("Show on the deal finder map", systemImage: "map")
                }
                .accessibilityIdentifier("pd.research.map")
            }
            if research.bool("gemini") == false, let hint = research.string("gemini_hint") {
                Text(hint).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        let steps = research.records("steps", idKeys: ["key"])
        if !steps.isEmpty {
            Section("Steps") {
                ForEach(steps) { step in
                    let status = step.string("status") ?? ""
                    VStack(alignment: .leading, spacing: 2) {
                        Label(Self.steps[step.id] ?? Formatters.humanize(step.id),
                              systemImage: status == "done" ? "checkmark.circle.fill" : status == "failed" ? "xmark.octagon" : status == "waiting" ? "hourglass" : "minus.circle")
                        if let note = step.string("note") { Text(note).font(.wsCaption).foregroundStyle(.secondaryText) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        if let facts = research.object("facts") { PDAreaFactsSection(facts: facts) }
        let quotes = research.records("quotes")
        if !quotes.isEmpty {
            Section {
                ForEach(quotes) { quote in
                    let status = Self.quoteStatus[quote.string("status") ?? ""] ?? (Formatters.humanize(quote.string("status")), .neutral)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.string("title") ?? "Quote request").font(.wsBody)
                            if let to = quote.string("sent_to") { Text("To \(to)").font(.wsCaption).foregroundStyle(.secondaryText) }
                        }
                        Spacer()
                        StatusBadge(text: status.0, systemImage: "envelope", tone: status.1)
                    }
                }
                NavigationLink(value: PDApprovalsRoute()) { Label("Open Approvals", systemImage: "checkmark.seal") }
            } header: {
                Text("Quote requests")
            }
        }
        if research.object("area") != nil {
            Section {
                ForEach(Self.areas) { area in
                    if let text = research.string("area.\(area.value)") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(area.label).font(.wsSubheadline.weight(.semibold))
                            Text(text).font(.wsBody).textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(research.string("area_source") == "model" ? "From your AI model (no web search)" : "From a web search")
            } footer: {
                let searches = research.strings("searches")
                if !searches.isEmpty { Text("Searched for: \(searches.joined(separator: "; "))") }
            }
        } else if research.bool("web_hidden") == true {
            Section {
                Text("Someone else ran the web search on this deal; its results are only shown to them. Run it again to see your own.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        let nearby = research.records("nearby")
        if !nearby.isEmpty {
            Section("What’s going on nearby") {
                ForEach(nearby) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.string("title") ?? "").font(.wsBody)
                        Text([item.string("kind"), item.string("date"), item.string("where")].compactMap { $0 }.joined(separator: " · "))
                            .font(.wsCaption).foregroundStyle(.secondaryText)
                        if let detail = item.string("detail") { Text(detail).font(.wsCaption) }
                    }
                }
            }
        }
        let firms = research.records("firms", idKeys: ["index"])
        if !firms.isEmpty, let run = research.string("web_run_uuid") ?? research.string("run.uuid") {
            Section("Firms from the web search") {
                ForEach(firms) { firm in firmRow(firm, run: run) }
            }
        }
        let suppliers = research.records("suppliers")
        if !suppliers.isEmpty {
            Section {
                ForEach(suppliers) { supplier in conveyancerRow(supplier, research: research) }
            } header: {
                Text("Conveyancers from the SRA register")
            } footer: {
                if let attribution = research.string("attribution") { Text(attribution) }
            }
        }
        let sources = research.records("sources", idKeys: ["url"])
        if !sources.isEmpty {
            Section("Sources") {
                ForEach(sources) { source in
                    if let url = URL(string: source.id) {
                        Link(destination: url) { Label(source.string("title") ?? source.id, systemImage: "link") }
                    }
                }
            }
        }
    }

    private func firmRow(_ firm: Record, run: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(firm.string("name") ?? "Firm").font(.wsHeadline)
            Text([firm.string("kind").map(Formatters.humanize), firm.string("address"), firm.string("postcode")]
                .compactMap { $0 }.joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
            ForEach(["accreditation", "fees", "notes"], id: \.self) { key in
                if let text = firm.string(key) { Text(text).font(.wsCaption) }
            }
            if let phone = firm.string("phone") { PhoneLinkRow(name: "Call", phone: phone) }
            if let email = firm.string("email") { EmailLinkRow(email: email) }
            HStack {
                if firm.string("saved_supplier_uuid") != nil {
                    Label("In Suppliers", systemImage: "checkmark.circle").font(.wsCaption)
                } else if firm.bool("can_save") == true, session.propertyDeals?.can(.create, .suppliers) ?? false {
                    Button("Save to Suppliers") { Task { await act("save", firm, run: run) } }.buttonStyle(.bordered)
                        .disabled(busy != nil)
                }
                if firm.bool("quote_asked") == true {
                    Label("Quote asked", systemImage: "envelope.badge").font(.wsCaption)
                } else if firm.bool("can_quote") == true, session.propertyDeals?.can(.create, .approvals) ?? true {
                    Button("Ask for a quote") { Task { await act("quote", firm, run: run) } }.buttonStyle(.bordered)
                        .disabled(busy != nil)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func conveyancerRow(_ supplier: Record, research: Record) -> some View {
        let role = deal?.string("deal_type") == "sell" ? "seller_solicitor" : "buyer_solicitor"
        let isOurs = parties.contains { $0.string("role") == role && $0.string("account_uuid") == supplier.string("account_uuid") }
        return VStack(alignment: .leading, spacing: 4) {
            Text(supplier.string("name") ?? "Firm").font(.wsHeadline)
            Text([supplier.string("address_line1"), supplier.string("postal_code"),
                  supplier.decimal("distance_miles").map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) miles" }]
                .compactMap { $0 }.joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
            if let phone = supplier.string("phone") { PhoneLinkRow(name: "Call", phone: phone) }
            if isOurs {
                Label("Our solicitor on this deal", systemImage: "checkmark.seal.fill").foregroundStyle(Tone.success.textColor)
            } else if PDWriteGates.canAppointSolicitor(session.propertyDeals), let account = supplier.string("account_uuid") {
                Button("Make them our solicitor") { Task { await makeSolicitor(account: account, role: role, name: supplier.string("name")) } }
                    .buttonStyle(.bordered)
                    .disabled(busy != nil)
            }
        }
        .padding(.vertical, 4)
    }

    static func runStatus(_ run: Record?) -> String {
        guard let run else { return "Not researched yet." }
        switch run.string("status") {
        case "running": return "Researching… started \(Formatters.dateTime(run.date("started_at")) ?? "just now")"
        case "failed": return "Failed \(Formatters.dateTime(run.date("finished_at")) ?? "")" + (run.string("error").map { ": \($0)" } ?? "")
        default: return "Done \(Formatters.dateTime(run.date("finished_at")) ?? "")"
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let raw = services.pdRaw
            async let research = raw.record("/deals/\(dealUuid)/research")
            async let dealRecord = try? raw.record("/deals/\(dealUuid)")
            async let partyRows = try? raw.rows("/deal-parties", ["deal_uuid": dealUuid, "per_page": "100"])
            state = .loaded(try await research)
            deal = await dealRecord
            parties = await partyRows ?? []
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        do {
            try await services.pdRaw.send(.post, "/deals/\(dealUuid)/research", [:], idempotent: true)
            notice = "Researching this deal… this page updates by itself."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func act(_ what: String, _ firm: Record, run: String) async {
        busy = firm.id
        defer { busy = nil }
        do {
            let answer = PDRaw.record(try await services.pdRaw.send(.post, "/deals/\(dealUuid)/research/firms/\(firm.id)/\(what)",
                                                                     ["run_uuid": .string(run)], idempotent: true))
            let name = firm.string("name") ?? "The firm"
            notice = what == "save"
                ? (answer?.bool("created") == false ? "\(name) was already in Suppliers." : "\(name) added to Suppliers.")
                : "Quote request drafted. It waits in Approvals."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    private func makeSolicitor(account: String, role: String, name: String?) async {
        busy = account
        defer { busy = nil }
        do {
            try await services.pdRaw.send(.post, "/deal-parties", ["deal_uuid": .string(dealUuid), "role": .string(role),
                                                                  "account_uuid": .string(account)], idempotent: true)
            notice = "\(name ?? "They") are now our solicitor on this deal."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }
}

/// Official data near the home (planning, flood, crime, prices), shown to the whole team.
private struct PDAreaFactsSection: View {
    let facts: Record

    var body: some View {
        Section {
            if let district = facts.string("place.district") {
                PDFigureRow(label: "Area", value: [facts.string("place.ward"), district, facts.string("place.region")]
                    .compactMap { $0 }.joined(separator: ", "))
            }
            if facts.object("prices") != nil {
                PDFigureRow(label: "Average price (\(facts.string("prices.area") ?? "area"), \(facts.string("prices.month") ?? ""))",
                            value: facts.pounds("prices.average"))
                if let change = facts.number("prices.annual_change_pct") { PDFigureRow(label: "Change over a year", value: "\(change)%") }
                ForEach(["detached", "semi_detached", "terraced", "flat"], id: \.self) { kind in
                    if let value = facts.pounds("prices.\(kind)") { PDFigureRow(label: Formatters.humanize(kind), value: value) }
                }
            }
            if facts.object("crime") != nil {
                PDFigureRow(label: "Crimes within a mile (\(facts.string("crime.month") ?? "last month"))",
                            value: facts.string("crime.within_1_mile"))
                let top = facts.records("crime.top").prefix(3).compactMap { row in
                    row.string("category").map { "\(Formatters.humanize($0)) \(row.string("count") ?? "")" }
                }
                if !top.isEmpty { Text("Most common: \(top.joined(separator: ", "))").font(.wsCaption).foregroundStyle(.secondaryText) }
            }
            if facts.object("flood") != nil {
                let warnings = facts.records("flood.warnings")
                PDFigureRow(label: "Flood warnings now", value: "\(warnings.count)", tone: warnings.isEmpty ? nil : .danger)
                PDFigureRow(label: "Flood alert areas within 1 km", value: facts.string("flood.alert_areas_within_1km"))
            }
            if facts.object("planning") != nil {
                let atHome = facts.records("planning.at_the_home")
                if atHome.isEmpty {
                    Text("No planning constraints at the home.").font(.wsSubheadline)
                } else {
                    ForEach(atHome) { row in
                        Label(row.string("name") ?? Formatters.humanize(row.string("dataset")), systemImage: "exclamationmark.triangle")
                    }
                }
                PDFigureRow(label: "Listed buildings nearby", value: facts.string("planning.listed_buildings.count"))
                PDFigureRow(label: "Brownfield sites nearby", value: facts.string("planning.brownfield.count"))
            }
        } header: {
            Text("Official data near this home")
        } footer: {
            let sources = facts.strings("sources")
            let missing = facts.strings("missing")
            Text([sources.isEmpty ? nil : "Sources: \(sources.joined(separator: ", ")).",
                  missing.isEmpty ? nil : "Not available: \(missing.joined(separator: ", "))."].compactMap { $0 }.joined(separator: " "))
        }
    }
}

/// A deal with no property yet: `POST /properties` then `PUT /deals/{id}` with it, so the deal can
/// be pinned on the map and researched.
struct PDAddPropertySheet: View {
    let dealUuid: String
    let onAdded: () -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var town = ""
    @State private var postcode = ""
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    TextField("Address (needed)", text: $address).textContentType(.streetAddressLine1)
                    TextField("Town", text: $town).textContentType(.addressCity)
                    TextField("Postcode (needed)", text: $postcode).textInputAutocapitalization(.characters)
                        .textContentType(.postalCode)
                } footer: {
                    Text("A valid UK postcode pins the home on the deal finder map.")
                }
            }
            .navigationTitle("Add the property")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(saving || address.trimmedOrNil == nil || postcode.trimmedOrNil == nil)
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let property = PDRaw.record(try await services.pdRaw.send(.post, "/properties", PDNewDealSheet.propertyBody(
                address: address, postcode: postcode, town: town, tenure: ""), idempotent: true))
            guard let uuid = property?.string("uuid") else {
                throw ResourceService.problem(422, "The property couldn’t be saved. Check the address and postcode.")
            }
            try await services.pdRaw.send(.put, "/deals/\(dealUuid)", ["property_uuid": .string(uuid)])
            onAdded()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
