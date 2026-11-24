import SwiftUI
import CoreLocation

/// Rows a list has already loaded, so the next screen shows them at once while it refreshes
/// (the buyer directory has names the single-profile route doesn't).
@MainActor
enum PDSeeds {
    static var records: [String: Record] = [:]

    static func keep(_ rows: [Record]) {
        for row in rows { records[row.id] = row }
    }
}

enum PDBuyerWords {
    static let entityTypes = [Choice("person"), Choice("ltd_spv", "Limited company (SPV)"), Choice("overseas_company", "Overseas company"),
                              Choice("pension_ssas_sipp", "Pension (SSAS or SIPP)"), Choice("trust_family_office", "Trust or family office")]
    static let funding = [Choice("cash"), Choice("mortgage"), Choice("bridging"), Choice("cash_then_refinance", "Cash, then refinance")]
    static let refurb = [Choice("none"), Choice("light"), Choice("medium"), Choice("heavy")]
    static let proofOfFunds = [Choice("none", "None yet"), Choice("requested"), Choice("received"), Choice("verified"), Choice("expired")]
    static let strategies = [Choice("btl", "Buy to let"), Choice("brr", "Buy, refurbish, refinance"), Choice("flip", "Flip"),
                             Choice("hmo", "HMO"), Choice("blocks", "Blocks"), Choice("semi_commercial", "Semi-commercial"),
                             Choice("commercial", "Commercial"), Choice("tenanted", "Tenanted")]
    /// Codes the matcher understands: its own checks plus the known issues on a property.
    static let dealBreakers = [
        Choice("leasehold", "Leasehold"), Choice("short_lease", "Short lease (under 85 years)"), Choice("tenanted", "Tenanted"),
        Choice("sitting_tenant", "Sitting tenant"), Choice("high_flood_risk", "High flood risk"), Choice("epc_f_g", "EPC F or G"),
        Choice("spray_foam", "Spray foam insulation"), Choice("non_standard_construction", "Non-standard construction"),
        Choice("knotweed", "Japanese knotweed"), Choice("subsidence", "Subsidence"), Choice("shale_floors", "Shale floors"),
        Choice("cladding", "Cladding"),
    ]

    static func label(_ choices: [Choice], _ value: String?) -> String {
        guard let value else { return "—" }
        return choices.first { $0.value == value }?.label ?? Formatters.humanize(value)
    }

    static func pofTone(_ status: String?) -> Tone {
        switch status {
        case "verified": .success
        case "received": .warning
        case "requested": .info
        case "expired": .danger
        default: .neutral
        }
    }
}

// MARK: - Buyers

/// Investors and cash buyers (`GET /buyer-profiles/directory`): who they are, proof of funds and
/// budget. Search by name or email, filter by proof of funds, add a buyer.
struct PDBuyersView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        PDBuyersList(raw: services.pdRaw, canCreate: PDWriteGates.canAddBuyerPerson(session.propertyDeals, session.permissions)
                        || PDWriteGates.canAddBuyerCompany(session.propertyDeals, session.permissions))
    }
}

@MainActor
private final class PDBuyersSource {
    let raw: PDRaw
    var pof = ""
    init(raw: PDRaw) { self.raw = raw }

    func fetch(search: String, page: Int) async throws -> Page<Record> {
        let result = try await raw.page("/buyer-profiles/directory", ["q": search.trimmedOrNil, "pof_status": pof.trimmedOrNil],
                                        page: page, perPage: 50)
        PDSeeds.keep(result.items)
        return result
    }
}

private struct PDBuyersList: View {
    let canCreate: Bool
    @State private var source: PDBuyersSource
    @State private var model: PagedListModel<Record>
    @State private var pof = ""
    @State private var adding = false
    @State private var notice: String?
    @State private var appeared = false

    init(raw: PDRaw, canCreate: Bool) {
        self.canCreate = canCreate
        let source = PDBuyersSource(raw: raw)
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in try await source.fetch(search: search, page: page) })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search buyers by name or email", emptyTitle: "No buyers yet",
                  emptySystemImage: "person.2", emptyDescription: "Add a buyer profile to start matching homes.",
                  emptyActionTitle: "New buyer", emptyAction: canCreate ? { adding = true } : nil) { buyer in
            NavigationLink(value: NativeScreenRoute("pd.buyer", buyer.id)) { PDBuyerRow(buyer: buyer) }
                .accessibilityIdentifier("pd.buyers.row.\(buyer.id)")
        }
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: nil) }
        .navigationTitle("Buyers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Proof of funds", selection: $pof) {
                        Text("Any proof of funds").tag("")
                        ForEach(PDBuyerWords.proofOfFunds) { Text($0.label).tag($0.value) }
                    }
                } label: {
                    Label("Filter", systemImage: pof.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("pd.buyers.filter")
            }
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("New buyer", systemImage: "plus") }
                        .accessibilityIdentifier("pd.buyers.new")
                }
            }
        }
        .onChange(of: pof) { _, value in
            source.pof = value
            Task { await model.load() }
        }
        .onAppear {
            if appeared { Task { await model.load() } }
            appeared = true
        }
        .sheet(isPresented: $adding) {
            PDNewBuyerSheet { notice = "Buyer added. Their matches are being scored."; Task { await model.load() } }
        }
    }
}

private struct PDBuyerRow: View {
    let buyer: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(buyer.string("name") ?? PDBuyerWords.label(PDBuyerWords.entityTypes, buyer.string("entity_type"))).font(.wsHeadline)
            if let email = buyer.string("email") { Text(email).font(.wsSubheadline).foregroundStyle(.secondaryText) }
            HStack(spacing: 8) {
                StatusBadge(text: "Proof of funds: \(PDBuyerWords.label(PDBuyerWords.proofOfFunds, buyer.string("pof_status") ?? "none"))",
                            systemImage: "banknote", tone: PDBuyerWords.pofTone(buyer.string("pof_status")))
                if let max = buyer.pounds("price_max") { Text("up to \(max)").font(.wsCaption).foregroundStyle(.secondaryText) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One buyer

/// A buyer profile: what they want, proof of funds (update it), Companies House check for a
/// company buyer, and the homes that match them (re-score, send a deal pack).
struct PDBuyerDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var buyer: Record?
    @State private var loadError: APIError?
    @State private var matches: [Record] = []
    @State private var pofStatus = "none"
    @State private var pofExpires: Date?
    @State private var companyNumber = ""
    @State private var check: Record?
    @State private var working = false
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        List {
            if let loadError, buyer == nil { InlineErrorRow(error: loadError) { Task { await load() } } }
            if let buyer { content(buyer) }
        }
        .overlay { if buyer == nil, loadError == nil { SkeletonList() } }
        .navigationTitle("Buyer")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { PDNoticeBar(notice: notice, error: actionError) }
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private var canUpdate: Bool { session.propertyDeals?.can(.update, .buyers) ?? false }

    @ViewBuilder
    private func content(_ buyer: Record) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(buyer.string("name") ?? PDBuyerWords.label(PDBuyerWords.entityTypes, buyer.string("entity_type")))
                    .font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                Text([PDBuyerWords.label(PDBuyerWords.entityTypes, buyer.string("entity_type")),
                      PDBuyerWords.label(PDBuyerWords.funding, buyer.string("funding_route")), Self.budget(buyer)]
                    .joined(separator: " · ")).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
            if let email = buyer.string("email") { EmailLinkRow(email: email) }
        }
        Section("What they want") {
            DetailRow(label: "Strategies", value: buyer.strings("strategies").map { PDBuyerWords.label(PDBuyerWords.strategies, $0) }
                .joined(separator: ", ").trimmedOrNil ?? "—")
            PDFigureRow(label: "Minimum yield", value: buyer.number("min_yield_pct").map { "\($0)%" })
            PDFigureRow(label: "Minimum discount", value: buyer.number("min_discount_pct").map { "\($0)%" })
            DetailRow(label: "Refurb appetite", value: PDBuyerWords.label(PDBuyerWords.refurb, buyer.string("refurb_appetite")))
            let breakers = buyer.strings("deal_breakers")
            if !breakers.isEmpty {
                Label("Deal-breakers: \(breakers.map { PDBuyerWords.label(PDBuyerWords.dealBreakers, $0) }.joined(separator: ", "))",
                      systemImage: "xmark.octagon").foregroundStyle(Tone.danger.textColor)
            }
            if let notes = buyer.string("notes") { Text(notes).font(.wsBody) }
        }
        Section {
            if canUpdate {
                Picker("Proof of funds", selection: $pofStatus) {
                    ForEach(PDBuyerWords.proofOfFunds) { Text($0.label).tag($0.value) }
                }
                .accessibilityIdentifier("pd.buyer.pof")
                PDOptionalDayPicker(label: "Expires", date: $pofExpires)
                Button("Save proof of funds") { Task { await savePof() } }
                    .disabled(working)
                    .accessibilityIdentifier("pd.buyer.pof.save")
            } else {
                DetailRow(label: "Proof of funds", value: PDBuyerWords.label(PDBuyerWords.proofOfFunds, buyer.string("pof_status") ?? "none"))
                DetailRow(label: "Expires", value: PDDates.day(buyer.string("pof_expires_on")) ?? "—")
            }
        } header: {
            Text("Proof of funds")
        }
        if let type = buyer.string("entity_type"), type != "person" {
            Section {
                if canUpdate {
                    TextField("Company number", text: $companyNumber).textInputAutocapitalization(.characters)
                        .accessibilityIdentifier("pd.buyer.companyNumber")
                    Button("Check now", systemImage: "building.2") { Task { await checkCompany() } }
                        .disabled(working || companyNumber.trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.buyer.companyCheck")
                }
                if let check {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(check.string("name") ?? "Company") · \(Formatters.humanize(check.string("status")))").font(.wsHeadline)
                        Text("Directors: \(check.records("officers").compactMap { $0.string("name") }.joined(separator: "; ").trimmedOrNil ?? "—")")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        let flags = check.strings("flags")
                        if flags.isEmpty {
                            Label("No flags", systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor)
                        } else {
                            Label("Flags: \(flags.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Tone.warning.textColor)
                        }
                        if let at = Formatters.dateTime(check.date("checked_at")) { Text("Checked \(at)").font(.wsCaption) }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Companies House")
            }
        }
        Section {
            if matches.isEmpty { Text("No matches yet.").foregroundStyle(.secondaryText) }
            ForEach(matches) { match in
                PDMatchRow(match: match, showProperty: true, canSend: canUpdate) { message, error in
                    notice = message
                    actionError = error
                    Task { await loadMatches() }
                }
            }
        } header: {
            HStack {
                Text("Matching homes")
                Spacer()
                if canUpdate {
                    Button("Re-score") { Task { await rescore() } }
                        .font(.wsCaption).textCase(nil)
                        .accessibilityIdentifier("pd.buyer.rescore")
                }
            }
        }
    }

    static func budget(_ buyer: Record) -> String {
        let max = buyer.pounds("price_max") ?? "—"
        if let min = buyer.pounds("price_min") { return "\(min)–\(max)" }
        return "up to \(max)"
    }

    private func load() async {
        if buyer == nil, let seed = PDSeeds.records[uuid] { apply(seed) }
        do {
            let fresh = try await services.pdRaw.record("/buyer-profiles/\(uuid)")
            // The single profile has no name: keep the directory's.
            var fields = fresh.fields
            for key in ["name", "email"] where fields[key] == nil { fields[key] = PDSeeds.records[uuid]?.fields[key] ?? buyer?.fields[key] }
            apply(Record(fields))
            loadError = nil
        } catch {
            if buyer == nil { loadError = error.asAPIError }
        }
        await loadMatches()
    }

    private func apply(_ record: Record) {
        buyer = record
        pofStatus = record.string("pof_status") ?? "none"
        pofExpires = record.string("pof_expires_on").flatMap(CalendarDay.init(string:))?.date()
        if companyNumber.isEmpty { companyNumber = record.string("company_number") ?? "" }
        if check == nil { check = record.object("company_check") ?? PDMatchRow.breakdownLike(record["company_check"]) }
    }

    private func loadMatches() async {
        matches = (try? await services.pdRaw.rows("/buyer-profiles/\(uuid)/matches")) ?? matches
    }

    private func savePof() async {
        working = true
        defer { working = false }
        do {
            try await services.pdRaw.send(.put, "/buyer-profiles/\(uuid)", Self.pofBody(status: pofStatus, expires: pofExpires))
            notice = "Proof of funds saved."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
        }
    }

    static func pofBody(status: String, expires: Date?) -> [String: JSONValue] {
        ["pof_status": .string(status), "pof_expires_on": expires.map { .string(PDStartRenovationSheet.day($0)) } ?? .null]
    }

    private func checkCompany() async {
        working = true
        defer { working = false }
        do {
            check = PDRaw.record(try await services.pdRaw.send(.post, "/buyer-profiles/\(uuid)/company-check",
                                                               ["company_number": .string(companyNumber.trimmingCharacters(in: .whitespaces))]))
            notice = "Checked with Companies House."
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }

    private func rescore() async {
        do {
            try await services.pdRaw.send(.post, "/matches/recompute", ["buyer_profile_uuid": .string(uuid)])
            notice = "Matches re-scored."
            actionError = nil
            await loadMatches()
        } catch {
            actionError = error.asAPIError
        }
    }
}

extension PDMatchRow {
    /// A JSON object that may have been sent as text.
    static func breakdownLike(_ value: JSONValue?) -> Record? {
        guard case .string(let text)? = value, let data = text.data(using: .utf8),
              let json = try? ResourceService.decode(data), case .object(let fields) = json else { return nil }
        return Record(fields)
    }
}

// MARK: - New buyer

/// Creates the CRM contact (or company) and the buyer profile on it, as the web's "New buyer". The
/// area is found first (a town or postcode, on the phone), so a typo never leaves a contact
/// without a profile.
struct PDNewBuyerSheet: View {
    let onCreated: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var entity = "person"
    @State private var name = ""
    @State private var email = ""
    @State private var funding = "cash"
    @State private var priceMin = ""
    @State private var priceMax = ""
    @State private var minYield = ""
    @State private var refurb = ""
    @State private var area = ""
    @State private var miles = ""
    @State private var strategies: Set<String> = ["btl"]
    @State private var breakers: Set<String> = []
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    Picker("Buyer is", selection: $entity) {
                        ForEach(entityChoices) { Text($0.label).tag($0.value) }
                    }
                    TextField(entity == "person" ? "Full name (needed)" : "Company name (needed)", text: $name)
                        .accessibilityIdentifier("pd.newBuyer.name")
                    TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Money") {
                    Picker("Funding", selection: $funding) {
                        ForEach(PDBuyerWords.funding) { Text($0.label).tag($0.value) }
                    }
                    TextField("Budget from (£)", text: $priceMin).keyboardType(.decimalPad)
                    TextField("Budget to (£)", text: $priceMax).keyboardType(.decimalPad)
                    TextField("Minimum yield (%)", text: $minYield).keyboardType(.decimalPad)
                    Picker("Refurb appetite", selection: $refurb) {
                        Text("Not said").tag("")
                        ForEach(PDBuyerWords.refurb) { Text($0.label).tag($0.value) }
                    }
                }
                Section {
                    TextField("Town or postcode, e.g. York, LS1, YO1 7HH", text: $area)
                    TextField("Radius (miles, 10 if empty)", text: $miles).keyboardType(.numberPad)
                } header: {
                    Text("Where")
                } footer: {
                    Text("Homes within this distance score higher for area.")
                }
                Section("Strategies") { PDMultiChoice(choices: PDBuyerWords.strategies, selected: $strategies) }
                Section("Deal-breakers") { PDMultiChoice(choices: PDBuyerWords.dealBreakers, selected: $breakers) }
            }
            .onAppear {
                if !entityChoices.contains(where: { $0.value == entity }), let first = entityChoices.first { entity = first.value }
            }
            .navigationTitle("New buyer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(saving || name.trimmedOrNil == nil)
                        .accessibilityIdentifier("pd.newBuyer.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    /// A person is saved as a CRM contact, a company as a CRM account: offer only what the role can create.
    private var entityChoices: [Choice] {
        let person = PDWriteGates.canAddBuyerPerson(session.propertyDeals, session.permissions)
        let company = PDWriteGates.canAddBuyerCompany(session.propertyDeals, session.permissions)
        return PDBuyerWords.entityTypes.filter { $0.value == "person" ? person : company }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        var centre: CLLocationCoordinate2D?
        if let place = area.trimmedOrNil {
            centre = await Self.locate(place)
            if centre == nil {
                error = ResourceService.problem(422, "Couldn’t find “\(place)”. Try a town name or a postcode such as LS1 or YO1 7HH.")
                return
            }
        }
        let raw = services.pdRaw
        do {
            var owner: [String: JSONValue] = [:]
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if entity == "person" {
                let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
                var contact: [String: JSONValue] = ["first_name": .string(parts.first ?? trimmed)]
                contact["last_name"] = parts.count > 1 ? .string(parts[1]) : nil
                contact["email"] = .text(email)
                let created = PDRaw.record(try await raw.send(.post, "/api/v2/crm/contacts", contact, idempotent: true))
                guard let uuid = created?.string("uuid") else { throw ResourceService.problem(422, "The contact couldn’t be created.") }
                owner["contact_uuid"] = .string(uuid)
            } else {
                var account: [String: JSONValue] = ["name": .string(trimmed)]
                account["email"] = .text(email)
                let created = PDRaw.record(try await raw.send(.post, "/api/v2/crm/accounts", account, idempotent: true))
                guard let uuid = created?.string("uuid") else { throw ResourceService.problem(422, "The company couldn’t be created.") }
                owner["account_uuid"] = .string(uuid)
            }
            let body = owner.merging(Self.profileBody(entity: entity, funding: funding, priceMin: priceMin, priceMax: priceMax,
                                                      minYield: minYield, refurb: refurb, strategies: strategies,
                                                      breakers: breakers, centre: centre.map { ($0.latitude, $0.longitude) },
                                                      miles: miles)) { a, _ in a }
            try await raw.send(.post, "/buyer-profiles", body, idempotent: true)
            onCreated()
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }

    static func profileBody(entity: String, funding: String, priceMin: String, priceMax: String, minYield: String,
                            refurb: String, strategies: Set<String>, breakers: Set<String>,
                            centre: (Double, Double)?, miles: String) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["entity_type": .string(entity), "funding_route": .string(funding),
                                         "strategies": .array(strategies.sorted().map(JSONValue.string)),
                                         "deal_breakers": .array(breakers.sorted().map(JSONValue.string))]
        body["price_min"] = .number(text: priceMin)
        body["price_max"] = .number(text: priceMax)
        body["min_yield_pct"] = .number(text: minYield)
        body["refurb_appetite"] = refurb.isEmpty ? nil : .string(refurb)
        if let centre {
            body["areas"] = .array([.object(["type": .string("radius"), "lat": .number(centre.0), "lng": .number(centre.1),
                                             "miles": .number(Double(miles.trimmingCharacters(in: .whitespaces)) ?? 10)])])
        } else {
            body["areas"] = .array([])
        }
        return body
    }

    /// A UK town or postcode → its centre, with the phone's own geocoder.
    nonisolated static func locate(_ place: String) async -> CLLocationCoordinate2D? {
        let text = place.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lng = Double(parts[1]) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        let geocoder = CLGeocoder()
        guard let placemarks = try? await geocoder.geocodeAddressString("\(text), United Kingdom") else { return nil }
        return placemarks.first?.location?.coordinate
    }
}

/// Tick any number of fixed options.
struct PDMultiChoice: View {
    let choices: [Choice]
    @Binding var selected: Set<String>

    var body: some View {
        ForEach(choices) { choice in
            Button {
                if selected.contains(choice.value) { selected.remove(choice.value) } else { selected.insert(choice.value) }
            } label: {
                HStack {
                    Text(choice.label).foregroundStyle(.primary)
                    Spacer()
                    if selected.contains(choice.value) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .frame(minHeight: 44)
            .accessibilityAddTraits(selected.contains(choice.value) ? .isSelected : [])
            .accessibilityIdentifier("pd.choice.\(choice.value)")
        }
    }
}
