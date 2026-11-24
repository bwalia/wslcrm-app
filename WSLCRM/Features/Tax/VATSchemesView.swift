import SwiftUI
import UniformTypeIdentifiers

/// "Other VAT schemes" on the VAT screen (the web's `VatSchemesPanel`): partial exemption's annual adjustment,
/// the capital goods scheme, VAT groups, e-invoices (Peppol UBL) and the EC Sales List. Each opens on tap.
struct VATSchemesSections: View {
    let context: VATContext
    let registration: Record
    let period: VATPeriod?
    let changed: () -> Void

    var body: some View {
        Section {
            Text("Only if they apply to you. The margin scheme for second-hand goods is a VAT code: code that stock "
                 + "“Margin scheme”.").font(.wsFootnote)
            if registration.bool("partially_exempt") == true {
                NavigationLink("Partial exemption: the annual adjustment") {
                    VATPartialExemptionView(context: context, period: period, changed: changed)
                }
            }
            NavigationLink("Capital goods scheme") { VATCapitalGoodsView(context: context, period: period, changed: changed) }
            if context.isWorkspace {
                NavigationLink("VAT group") { VATGroupView(context: context) }
            }
            NavigationLink("E-invoices (Peppol)") { VATEInvoiceView(context: context) }
            if context.isWorkspace {
                NavigationLink("EC Sales List (Northern Ireland)") { VATECSalesListView(context: context, period: period) }
            }
        } header: {
            Text("Other VAT schemes")
        }
    }
}

struct VATPartialExemptionView: View {
    let context: VATContext
    let period: VATPeriod?
    let changed: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var from = CalendarDay(year: Calendar.current.component(.year, from: Date()) - 1, month: 4, day: 1).date()
    @State private var to = CalendarDay(year: Calendar.current.component(.year, from: Date()), month: 3, day: 31).date()
    @State private var result: Record?
    @State private var notice: TaxNotice?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                Text("At the end of your VAT year, recover VAT on the whole year’s figures.").font(.wsFootnote)
                DatePicker("Year from", selection: $from, displayedComponents: .date)
                DatePicker("to", selection: $to, displayedComponents: .date)
                Button(busy ? "Working it out…" : "Work out the adjustment") { Task { await work() } }.disabled(busy)
            }
            if let notice { Section { TaxNoticeView(notice: notice) } }
            if let r = result {
                Section {
                    Text("The year’s recovery rate is \(r.string("annual_pct") ?? "0")%"
                         + (r.bool("de_minimis") == true ? " — and you are under the de minimis limits, so all input VAT is recoverable." : "."))
                    let adjustment = r.decimal("adjustment") ?? 0
                    let what = r.string("direction") == "claim" ? "claim \(TaxMoney.text(adjustment)) more"
                        : r.string("direction") == "repay" ? "pay back \(TaxMoney.text(-adjustment))" : "no adjustment"
                    Text("Recoverable for the year \(r.money("should_recover")) · recovered on your returns \(r.money("claimed")) → \(what)")
                    if let note = r.string("note") { Text(note).font(.wsFootnote).foregroundStyle(.secondaryText) }
                    ForEach(r.array("warnings").compactMap(\.stringValue), id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                    }
                    if r.string("direction") != "none", let period, context.allows(.create, session.permissions) {
                        Button("Put it on the \(period.label) return") { Task { await apply(period) } }.disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("Partial exemption")
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }
    private var range: [String: String?] {
        context.query.merging(["year_start": CalendarDay(date: from).isoString, "year_end": CalendarDay(date: to).isoString]) { a, _ in a }
    }

    private func work() async {
        busy = true
        defer { busy = false }
        do { result = try await api.get("/api/v2/vat/partial-exemption/annual", query: range).payload.record } catch { notice = .error(error) }
    }

    private func apply(_ period: VATPeriod) async {
        busy = true
        defer { busy = false }
        do {
            try await api.json(.post, "/api/v2/vat/partial-exemption/annual", [
                "year_start": .string(CalendarDay(date: from).isoString), "year_end": .string(CalendarDay(date: to).isoString),
                "period_start": .string(period.start), "period_end": .string(period.end),
            ], query: context.query)
            notice = .success("Added to the return for \(period.label).")
            changed()
        } catch {
            notice = .error(error)
        }
    }
}

struct VATCapitalGoodsView: View {
    let context: VATContext
    let period: VATPeriod?
    let changed: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var items: [Record] = []
    @State private var notice: TaxNotice?
    @State private var description = ""
    @State private var kind = "building"
    @State private var cost = ""
    @State private var vat = ""
    @State private var use = "100"
    @State private var shortLease = false
    @State private var interval: [String: String] = [:]
    @State private var usePct: [String: String] = [:]
    @State private var deleting: Record?
    @State private var loadError: APIError?

    static let kinds: [Choice] = [
        Choice("building", "Building (£250,000+)"), Choice("land", "Land (£250,000+)"),
        Choice("civil_engineering", "Civil engineering work (£250,000+)"),
        Choice("refurbishment", "Refurbishment / fitting out (£250,000+)"), Choice("ship", "Ship or boat (£50,000+)"),
        Choice("aircraft", "Aircraft (£50,000+)"),
    ]

    var body: some View {
        Form {
            Section {
                Text("Property costing £250,000+ or a ship or aircraft costing £50,000+: adjust the VAT as its use changes.")
                    .font(.wsFootnote)
            }
            if let notice { Section { TaxNoticeView(notice: notice) } }
            if let loadError { Section { InlineErrorRow(error: loadError) { Task { await load() } } } }
            ForEach(items) { item in
                Section {
                    Text("\(item.string("description") ?? "") · \(item.string("kind_label") ?? "") · input VAT \(item.money("input_vat")) · "
                         + "\(item.int("intervals") ?? 0) intervals · first use \(item.string("original_use_pct") ?? "")% taxable"
                         + (item.day("disposed_on").map { " · sold \($0)" } ?? ""))
                    ForEach(item.records("adjustments")) { a in
                        Text((a.int("interval_no").map { "Interval \($0)" } ?? "Sale") + ": \(a.money("vat")) on the "
                             + "\(a.day("period_start") ?? "") to \(a.day("period_end") ?? "") return").font(.wsFootnote)
                    }
                    let next = max(item.records("adjustments").compactMap { $0.int("interval_no") }.max() ?? 1, 1) + 1
                    if item.string("disposed_on") == nil, next <= (item.int("intervals") ?? 0), let period,
                       context.allows(.create, session.permissions) {
                        TextField("Interval", text: Binding(get: { interval[item.id] ?? "\(next)" }, set: { interval[item.id] = $0 }))
                            .keyboardType(.numberPad)
                        TextField("Taxable use %", text: Binding(get: { usePct[item.id] ?? "" }, set: { usePct[item.id] = $0 }))
                            .keyboardType(.decimalPad)
                        Button("Adjust on the \(period.label) return") {
                            Task { await adjust(item, interval: Int(interval[item.id] ?? "\(next)") ?? next, period: period) }
                        }
                        .disabled((usePct[item.id] ?? "").isEmpty)
                    }
                    if item.records("adjustments").isEmpty, context.allows(.delete, session.permissions) {
                        Button("Delete this item", role: .destructive) { deleting = item }
                    }
                }
            }
            if context.allows(.create, session.permissions) {
                Section("Add an item") {
                    TextField("What is it", text: $description)
                    Picker("Kind", selection: $kind) { ForEach(Self.kinds) { Text($0.label).tag($0.value) } }
                    TextField("Cost excluding VAT (£)", text: $cost).keyboardType(.decimalPad)
                    TextField("VAT paid (£)", text: $vat).keyboardType(.decimalPad)
                    TextField("Taxable use when first used (%)", text: $use).keyboardType(.decimalPad)
                    Toggle("Lease under 10 years (5 intervals)", isOn: $shortLease)
                    Button("Add item") { Task { await add() } }.disabled(description.isEmpty || cost.isEmpty)
                }
            } else if items.isEmpty && loadError == nil {
                Section { Text("No items yet. Your role can't add them: ask the workspace owner.").foregroundStyle(.secondaryText) }
            }
        }
        .navigationTitle("Capital goods")
        .task { await load() }
        .confirmationDialog("Delete “\(deleting?.string("description") ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = deleting { Task { await delete(item) } } }
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            items = try await api.get("/api/v2/vat/capital-items", query: context.query).payload.recordList
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func add() async {
        do {
            try await api.json(.post, "/api/v2/vat/capital-items", [
                "description": .string(description), "kind": .string(kind), "cost_ex_vat": .number(Double(cost) ?? 0),
                "input_vat": .number(Double(vat) ?? 0), "original_use_pct": .number(Double(use) ?? 100),
                "short_lease": .bool(shortLease),
            ], query: context.query)
            description = ""; cost = ""; vat = ""
            notice = .success("Item added.")
            await load()
        } catch {
            notice = .error(error)
        }
    }

    private func adjust(_ item: Record, interval: Int, period: VATPeriod) async {
        do {
            try await api.json(.post, "/api/v2/vat/capital-items/\(item.id)/adjust", [
                "interval_no": .number(Double(interval)), "use_pct": .number(Double(usePct[item.id] ?? "") ?? 0),
                "period_start": .string(period.start), "period_end": .string(period.end),
            ], query: context.query)
            notice = .success("Adjustment added to the return.")
            await load()
            changed()
        } catch {
            notice = .error(error)
        }
    }

    private func delete(_ item: Record) async {
        do {
            try await api.delete("/api/v2/vat/capital-items/\(item.id)", query: context.query)
            notice = .success("Item deleted.")
            await load()
        } catch {
            notice = .error(error)
        }
    }
}

struct VATGroupView: View {
    let context: VATContext
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var group: Record?
    @State private var notice: TaxNotice?
    @State private var memberName = ""
    @State private var code = ""
    @State private var confirmLeave = false
    @State private var removing: Record?
    @State private var loadError: APIError?

    /// Inviting and removing members, joining and leaving all need `vat.manage` (`vat.lua`).
    private var canManage: Bool { session.permissions.can(.manage, moduleName: "vat") }

    var body: some View {
        Form {
            Section { Text("Companies under common control filing one VAT return.").font(.wsFootnote) }
            if let notice { Section { TaxNoticeView(notice: notice) } }
            if let loadError {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            } else {
                groupSections
            }
        }
        .navigationTitle("VAT group")
        .task { await load() }
        .confirmationDialog("Leave this VAT group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave group", role: .destructive) { Task { await leave() } }
        } message: { Text("This workspace will file its own VAT returns again. Tell HMRC too (form VAT56).") }
        .confirmationDialog("Remove \(removing?.string("member_name") ?? "this member") from the group?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { m in
            Button("Remove", role: .destructive) { Task { await remove(m) } }
        } message: { _ in Text("Their sales and purchases leave this workspace's VAT return.") }
    }

    @ViewBuilder
    private var groupSections: some View {
        Group {
            if let memberOf = group?.object("member_of") {
                Section {
                    Text("This workspace is in the VAT group \(memberOf.string("group_name") ?? memberOf.string("member_name") ?? "") "
                         + "(VAT \(memberOf.string("group_vrn") ?? "—")). The group’s representative files one return for every member.")
                    if canManage {
                        Button("Leave this group", role: .destructive) { confirmLeave = true }
                    }
                }
            } else {
                Section {
                    Text("This workspace is the representative member: its return includes every member’s sales and purchases, "
                         + "and supplies between members are left out. Register the group with HMRC first (form VAT50/51).")
                        .font(.wsFootnote)
                    ForEach(group?.records("members") ?? []) { m in
                        HStack {
                            Text(m.string("status") == "active" ? "\(m.string("member_name") ?? "") · joined"
                                 : "\(m.string("member_name") ?? "") · waiting — give them this code: \(m.string("invite_code") ?? "")")
                                .textSelection(.enabled)
                            Spacer()
                            if canManage {
                                Button("Remove", role: .destructive) { removing = m }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if canManage {
                        TextField("Member company name (as on its invoices)", text: $memberName)
                        Button("Invite") { Task { await invite() } }.disabled(memberName.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Text("Your role can't change the group: ask the workspace owner.").font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                if canManage {
                    Section("Or join another group with its code") {
                        TextField("32-character code", text: $code).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Join") { Task { await join() } }.disabled(code.trimmingCharacters(in: .whitespaces).count != 32)
                    }
                }
            }
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            group = try await api.get("/api/v2/vat/group", query: context.query).payload.record
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
        }
    }

    private func invite() async {
        do {
            try await api.json(.post, "/api/v2/vat/group/members", ["member_name": .string(memberName)], query: context.query)
            memberName = ""
            notice = .success("Invited. Give them the code shown.")
            await load()
        } catch { notice = .error(error) }
    }

    private func remove(_ m: Record) async {
        do {
            try await api.delete("/api/v2/vat/group/members/\(m.id)", query: context.query)
            notice = .success("\(m.string("member_name") ?? "The member") was removed from the group.")
            await load()
        } catch { notice = .error(error) }
    }

    private func join() async {
        do {
            try await api.json(.post, "/api/v2/vat/group/join", ["code": .string(code.trimmingCharacters(in: .whitespaces))])
            code = ""
            notice = .success("Joined the VAT group.")
            await load()
        } catch { notice = .error(error) }
    }

    private func leave() async {
        do {
            try await api.json(.post, "/api/v2/vat/group/leave")
            notice = .success("Left the VAT group.")
            await load()
        } catch { notice = .error(error) }
    }
}

struct VATEInvoiceView: View {
    let context: VATContext
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var xml: String?
    @State private var fileName: String?
    @State private var result: Record?
    @State private var notice: TaxNotice?
    @State private var picking = false
    @State private var busy = false
    @State private var documents: [Record] = []
    @State private var documentsError: APIError?

    var body: some View {
        Form {
            Section {
                Text("Read a supplier’s e-invoice (UBL XML): check it and record it with its VAT. Mandatory UK e-invoicing is "
                     + "due from April 2029.").font(.wsFootnote)
                Button(fileName ?? "Choose an e-invoice (.xml)", systemImage: "doc.badge.plus") { picking = true }
                Button(busy ? "Checking…" : "Check it") { Task { await send(record: false) } }.disabled(xml == nil || busy)
            }
            if let notice { Section { TaxNoticeView(notice: notice) } }
            if let r = result {
                let data = r.object("data") ?? Record([:])
                Section {
                    Text("\(data.string("supplier.name") ?? "Supplier") · invoice \(data.string("invoice_number") ?? "") · \(data.day("issue_date") ?? "")")
                    Text("Net \(data.money("totals.tax_exclusive")) · VAT \(data.money("totals.tax")) · supplier VAT \(data.string("supplier.vat_id") ?? "—")")
                        .font(.wsFootnote)
                    let check = r.object("check") ?? Record([:])
                    if check.bool("valid") == true {
                        Label("Passes the Peppol BIS 3.0 checks.", systemImage: "checkmark.circle").foregroundStyle(Tone.success.textColor)
                    } else {
                        Text("Doesn’t pass the checks:").foregroundStyle(Tone.warning.textColor)
                    }
                    ForEach(check.records("errors")) { e in Text("• \(e.string("message") ?? "") (\(e.string("rule") ?? ""))").font(.wsFootnote) }
                    ForEach(check.array("warnings").compactMap(\.stringValue), id: \.self) { Text($0).font(.wsFootnote) }
                    ForEach(r.records("purchases")) { p in
                        Text("\(p.string("vat_code") ?? ""): net \(p.money("net")) · VAT \(p.money("vat"))").font(.wsFootnote)
                    }
                    if let note = r.string("note"), !r.array("recorded").isEmpty {
                        Text(note).foregroundStyle(Tone.success.textColor)
                    } else if context.isWorkspace, check.bool("valid") == true, context.allows(.create, session.permissions) {
                        Button(r.bool("duplicate") == true ? "Record it (seen before)" : "Record as purchases") {
                            Task { await send(record: true) }
                        }
                        .disabled(busy)
                    }
                }
            }
            if let documentsError {
                Section { InlineErrorRow(error: documentsError) { Task { await loadDocuments() } } }
            }
            if !documents.isEmpty {
                Section("E-invoices") {
                    ForEach(documents) { d in
                        VStack(alignment: .leading) {
                            Text("\(d.string("party_name") ?? "") · \(d.string("invoice_number") ?? "")")
                            Text("\(d.string("direction") == "in" ? "Received" : "Sent") · \(d.money("total")) · "
                                 + "\(Formatters.humanize(d.string("status"))) · \(d.bool("valid") == true ? "valid" : "has problems")")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
            }
        }
        .navigationTitle("E-invoices")
        .task { await loadDocuments() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.xml]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            xml = try? String(contentsOf: url, encoding: .utf8)
            fileName = url.lastPathComponent
            self.result = nil
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func loadDocuments() async {
        do {
            documents = try await api.get("/api/v2/vat/einvoice/documents", query: context.query).payload.recordList
            documentsError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            documentsError = apiError
        }
    }

    private func send(record: Bool) async {
        guard let xml else { return }
        busy = true
        defer { busy = false }
        do {
            result = try await api.json(.post, "/api/v2/vat/einvoice/import", ["xml": .string(xml), "record": .bool(record)],
                                        query: context.query).payload.record
            if record { notice = .success(result?.string("note") ?? "Recorded.") }
        } catch {
            notice = .error(error)
        }
    }
}

struct VATECSalesListView: View {
    let context: VATContext
    let period: VATPeriod?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var list: LoadState<Record> = .idle

    var body: some View {
        Form {
            Section { Text("Goods sold from Northern Ireland to VAT-registered customers in the EU.").font(.wsFootnote) }
            if let period {
                switch list {
                case .loaded(let r):
                    let rows = r.records("rows")
                    Section(period.label) {
                        if rows.isEmpty { Text("No Northern Ireland goods sold to EU customers in this period.") }
                        ForEach(rows) { row in
                            LabeledContent("\(row.string("country") ?? "") · \(row.string("vat_number") ?? "")",
                                           value: "£\(row.int("value") ?? 0) · indicator \(row.int("indicator") ?? 0)")
                        }
                        if !rows.isEmpty {
                            TaxDownloadButton(title: "Download CSV", systemImage: "tablecells") {
                                try await makeTaxAPI(services, user: session.user).download(
                                    "/api/v2/vat/ec-sales-list", query: context.query.merging(
                                        ["period_start": period.start, "period_end": period.end, "format": "csv"]) { a, _ in a },
                                    fallbackName: "ec-sales-list-\(period.end).csv")
                            }
                        }
                    }
                    let missing = r.records("missing")
                    if !missing.isEmpty {
                        Section("Customers missing an EU VAT number") {
                            ForEach(missing) { m in Text("\(m.string("customer_name") ?? "") · \(m.money("net"))") }
                        }
                    }
                    Section { ForEach(r.array("notes").compactMap(\.stringValue), id: \.self) { Text($0).font(.wsFootnote) } }
                case .failed(let error):
                    Section { InlineErrorRow(error: error) { Task { await load(period) } } }
                default:
                    Section { ProgressView() }
                }
            } else {
                Text("Choose a VAT period on the VAT screen first.")
            }
        }
        .navigationTitle("EC Sales List")
        .task { if let period { await load(period) } }
    }

    private func load(_ period: VATPeriod) async {
        do {
            list = .loaded(try await makeTaxAPI(services, user: session.user).get(
                "/api/v2/vat/ec-sales-list",
                query: context.query.merging(["period_start": period.start, "period_end": period.end]) { a, _ in a }).payload.record)
        } catch {
            list = .failed(error.asAPIError)
        }
    }
}

/// VAT clients (`/dashboard/tax/vat/clients`, RBAC `vat_agent`): an accountant asks clients for authority at HMRC,
/// then works on their VAT.
struct VATClientsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var arn = ""
    @State private var hasArn = false
    @State private var clients: LoadState<[Record]> = .idle
    @State private var vrn = ""
    @State private var regDate: Date?
    @State private var notice: TaxNotice?
    @State private var busy = false
    @State private var signIn = HMRCSignIn()
    @State private var stopping: Record?

    static let statuses: [String: (String, Tone)] = [
        "pending": ("Waiting for the client to accept", .warning), "accepted": ("Accepted — confirming with HMRC", .info),
        "active": ("You can act for this client", .success), "rejected": ("The client declined", .danger),
        "expired": ("Request expired", .neutral), "cancelled": ("Cancelled", .neutral),
        "revoked": ("Authority ended at HMRC", .danger),
    ]

    var body: some View {
        List {
            Section { Text("Act for your clients’ VAT once they authorise you at HMRC.").font(.wsSubheadline) }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            Section("Your agent details") {
                TextField("Agent Reference Number (ARN), e.g. AARN1234567", text: $arn)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .accessibilityIdentifier("tax.vatClients.arn")
                    .disabled(!session.allows(.update, "vat_agent"))
                if session.allows(.update, "vat_agent") {
                    Button("Save") { Task { await act { try await api.json(.put, "/api/v2/vat/agent/profile", ["arn": .string(arn)]) ; notice = .success("Saved.") } } }
                        .disabled(arn.isEmpty || busy)
                }
                Button("Connect to HMRC (agent sign-in)") { Task { await connect() } }
            }
            if hasArn, session.allows(.create, "vat_agent") {
                Section {
                    Text("The client must have added their VAT number in OpsAPI. HMRC sends them a link to accept; their VAT "
                         + "registration date proves you know the business.").font(.wsFootnote)
                    TextField("Client’s VAT number, e.g. GB 123 4567 82", text: $vrn)
                    if let regDate {
                        DatePicker("VAT registration date", selection: Binding(get: { regDate }, set: { self.regDate = $0 }),
                                   displayedComponents: .date)
                        Button("Clear the date") { self.regDate = nil }.font(.wsFootnote)
                    } else {
                        Button("Add the VAT registration date (if not on file)") { regDate = Date() }.font(.wsFootnote)
                    }
                    Button("Send request") { Task { await invite() } }.disabled(vrn.isEmpty || busy)
                        .accessibilityIdentifier("tax.vatClients.invite")
                } header: { Text("Ask a client for authority") }
            }
            switch clients {
            case .loaded(let rows):
                Section("Your clients (\(rows.count))") {
                    if rows.isEmpty { Text("No clients yet.").foregroundStyle(.secondaryText) }
                    ForEach(rows) { c in clientRow(c) }
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { ProgressView() }
            }
        }
        .navigationTitle("VAT clients")
        .task { await load() }
        .wsRefreshable { await load() }
        .confirmationDialog("Stop acting for this client?", isPresented: Binding(get: { stopping != nil },
                                                                              set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible) {
            Button("Stop", role: .destructive) {
                if let c = stopping { Task { await act { try await api.delete("/api/v2/vat/agent/clients/\(c.id)"); notice = .success("Stopped.") } } }
            }
        } message: { Text("A pending request is cancelled at HMRC.") }
    }

    private func clientRow(_ c: Record) -> some View {
        let status = c.string("status") ?? ""
        let label = Self.statuses[status] ?? (Formatters.humanize(status), .neutral)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(c.string("business_name") ?? "Client") · GB \(c.string("client_vrn") ?? "")").font(.wsHeadline)
            StatusBadge(text: label.0, systemImage: "circle.fill", tone: label.1)
            if status == "pending", let raw = c.string("client_action_url"), let url = URL(string: raw) {
                ShareLink(item: url) { Label("Send the HMRC link to your client", systemImage: "square.and.arrow.up") }
                    .font(.wsFootnote)
            }
            HStack {
                if status == "active" {
                    NavigationLink("Open their VAT", value: NativeScreenRoute("tax.vat:client=\(c.id)"))
                        .accessibilityIdentifier("tax.vatClients.open.\(c.id)")
                }
                Spacer()
                if ["pending", "accepted", "active"].contains(status) {
                    Button("Check with HMRC") { Task { await act { try await api.json(.post, "/api/v2/vat/agent/clients/\(c.id)/refresh") } } }
                        .buttonStyle(.borderless)
                    if session.allows(.delete, "vat_agent") {
                        Button("Stop", role: .destructive) { stopping = c }.buttonStyle(.borderless)
                    }
                }
            }
            .font(.wsFootnote)
        }
        .padding(.vertical, 4)
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        if let profile = try? await api.get("/api/v2/vat/agent/profile").payload.record, let value = profile.string("arn") {
            arn = value
            hasArn = true
        }
        do {
            clients = .loaded(try await api.get("/api/v2/vat/agent/clients").payload.recordList)
        } catch {
            clients = .failed(error.asAPIError)
        }
    }

    private func act(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
        } catch {
            let apiError = error.asAPIError
            notice = ["AGENT_SCOPE_MISSING", "NOT_CONNECTED"].contains(apiError.serverCode ?? "")
                ? .error("Connect to HMRC with your agent sign-in first.") : .error(apiError)
        }
        await load()
    }

    private func invite() async {
        await act {
            var body: [String: JSONValue] = ["vrn": .string(vrn)]
            if let regDate { body["vat_registration_date"] = .string(CalendarDay(date: regDate).isoString) }
            try await api.json(.post, "/api/v2/vat/agent/clients", body)
            notice = .success("Request sent. Share the HMRC link with your client.")
        }
    }

    private func connect() async {
        do {
            switch try await api.connectHMRC(source: "vat", purpose: "vat_agent", signIn: signIn) {
            case .connected: notice = .success("Connected to HMRC with your agent sign-in.")
            case .cancelled: notice = .info("Not connected — HMRC’s page was closed.")
            case .failed(let code): notice = .error(HMRCConnectMessage.text(for: code))
            }
        } catch {
            notice = .error(error)
        }
    }
}
