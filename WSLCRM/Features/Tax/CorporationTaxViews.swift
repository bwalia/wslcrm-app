import SwiftUI
import UniformTypeIdentifiers

/// Corporation Tax (`/dashboard/corporation-tax`; `lapis/routes/corporation-tax.lua`, RBAC `corporation_tax`):
/// the workspace's companies with their latest period, its status and deadlines; add or change a company; start
/// a period. A period opens the year-end steps (`CTPeriodView`). Every figure comes from the server's engine.
/// Sending the CT600 to HMRC isn't built on the server, so the app prepares the PDFs for the person to file.
enum CT {
    static let base = "/api/v2/corporation-tax"
    static let module = "corporation_tax"

    static func statusLabel(_ status: String?) -> String {
        switch status {
        case "books_locked": "Books locked"
        case "computed": "Tax worked out"
        case "approved": "Approved"
        default: "Books open"
        }
    }

    static func statusTone(_ status: String?) -> Tone {
        switch status {
        case "books_locked": .warning
        case "computed": .info
        case "approved": .success
        default: .neutral
        }
    }

    static func statusSymbol(_ status: String?) -> String {
        switch status {
        case "books_locked": "lock"
        case "computed": "function"
        case "approved": "checkmark.seal"
        default: "book"
        }
    }

    /// "5 Jan 2027 (in 43 days)", "(overdue)" in red, plain when it's far off.
    static func due(_ iso: String?, now: Date = Date(), calendar: Calendar = .current) -> (text: String, tone: Tone)? {
        guard let iso, let day = CalendarDay(string: iso) else { return nil }
        let date = day.date(calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day ?? 0
        let text = Formatters.day(date) ?? iso
        if days < 0 { return ("\(text) (overdue)", .danger) }
        if days <= 60 { return ("\(text) (in \(days) day\(days == 1 ? "" : "s"))", days <= 30 ? .warning : .neutral) }
        return (text, .neutral)
    }

    /// "1 Apr 2025 – 31 Mar 2026".
    static func span(_ period: Record) -> String {
        let start = period.day("start_date") ?? period.string("start_date") ?? "?"
        let end = period.day("end_date") ?? period.string("end_date") ?? "?"
        return "\(start) – \(end)"
    }

    /// "Company 01234567 · 2 associated · Dormant".
    static func companyLine(_ company: Record) -> String {
        var bits = [company.string("company_number").map { "Company \($0)" } ?? "No company number"]
        if let associated = company.int("associated_companies"), associated > 0 { bits.append("\(associated) associated") }
        if company.bool("is_dormant") == true { bits.append("Dormant") }
        return bits.joined(separator: " · ")
    }

    /// An amount typed by a person ("£1,250.50") as the JSON number the server reads; nil when it isn't one.
    static func number(_ text: String) -> JSONValue? {
        let cleaned = text.replacingOccurrences(of: "£", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return .number(NSDecimalNumber(decimal: value).doubleValue)
    }

    /// The server's own words where they help, plain words where they don't.
    static func plain(_ error: Error) -> String {
        let message = error.asAPIError.plainMessage
        if message.contains("no bookkeeping ledger") {
            return "There’s no bookkeeping ledger in this workspace to pull from. Paste or import the trial balance instead."
        }
        if message.hasPrefix("Import or pull the trial balance") { return "Add the trial balance first." }
        if message.hasPrefix("Lock the trial balance") { return "Lock the trial balance first (step 1, Books)." }
        if message.hasPrefix("Compute the period") { return "Work out the tax first (step 5, Computation)." }
        if message.hasPrefix("start_date and end_date") { return "Choose a start date on or before the end date." }
        if message == "name is required" { return "Enter the company’s name." }
        if message == "description is required" { return "Say what it is." }
        if message.hasPrefix("event_date must fall") { return "The date must be inside this period." }
        return message
    }
}

// MARK: - Companies

struct CTCompaniesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var companies: LoadState<[Record]> = .idle
    @State private var notice: TaxNotice?
    @State private var adding = false
    @State private var newPeriodFor: Record?
    @State private var openPeriod: String?

    var body: some View {
        List {
            Section {
                TaxCallout(tone: .info, systemImage: "info.circle") {
                    Text("Work out each company’s Corporation Tax for its year end. A person approves every period.")
                    Text("Sending the return (CT600) to HMRC isn’t built yet: the app prepares the tax computation and "
                         + "accounts as PDFs for you to file with HMRC.")
                }
            }
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch companies {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let rows) where rows.isEmpty:
                Section {
                    TaxEmptyRow(title: "No companies yet",
                                message: canCreate ? "Add a company to start its year end."
                                    : "Nobody has added a company yet. Ask the workspace owner to add one, or to let you "
                                        + "add companies.",
                                systemImage: "building.2")
                    if canCreate {
                        Button("Add a company", systemImage: "plus") { adding = true }
                            .accessibilityIdentifier("ct.companies.addEmpty")
                    }
                }
            case .loaded(let rows):
                ForEach(rows) { company in
                    Section(company.string("name") ?? "Company") { companyRows(for: company) }
                }
            default:
                EmptyView()
            }
            Section {
            } footer: {
                Text("Figures come from the Corporation Tax engine, using rates published on GOV.UK. The AI only suggests "
                     + "adjustments; a person accepts them.")
            }
        }
        .overlay { if companies.value == nil, companies.error == nil { SkeletonList() } }
        .navigationTitle("Corporation Tax")
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add a company", systemImage: "plus") }
                        .accessibilityIdentifier("ct.companies.add")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                CTCompanyForm(company: nil) { saved in
                    notice = .success("\(saved.string("name") ?? "Company") added. Next: start its first period.")
                    Task { await load() }
                }
            }
        }
        .sheet(item: $newPeriodFor) { company in
            NavigationStack {
                CTNewPeriodForm(company: company) { first, message in
                    notice = .success(message)
                    Task { await load() }
                    openPeriod = first
                }
            }
        }
        .navigationDestination(item: $openPeriod) { NativeScreenView(route: NativeScreenRoute("ct.period", $0)) }
    }

    private var canCreate: Bool { session.allows(.create, CT.module) }

    @ViewBuilder
    private func companyRows(for company: Record) -> some View {
        NavigationLink(value: NativeScreenRoute("ct.company", company.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CT.companyLine(company)).font(.wsSubheadline)
                Text("Every period and the company’s details").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityIdentifier("ct.company.\(company.id)")
        if let latest = company.object("latest_period") {
            NavigationLink(value: NativeScreenRoute("ct.period", latest.id)) {
                CTPeriodRow(period: latest, deadlines: company.object("deadlines"))
            }
            .accessibilityIdentifier("ct.latestPeriod.\(latest.id)")
        } else if canCreate {
            Button("Start its first period", systemImage: "calendar.badge.plus") { newPeriodFor = company }
                .accessibilityIdentifier("ct.firstPeriod.\(company.id)")
        } else {
            Text("No periods yet.").font(.wsFootnote).foregroundStyle(.secondaryText)
        }
    }

    private func load() async {
        if companies.value == nil { companies = .loading }
        do {
            companies = .loaded(try await makeTaxAPI(services, user: session.user).records("\(CT.base)/companies"))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            companies = .failed(apiError)
        }
    }
}

/// A period: its dates, status and (when given) when to pay and file.
struct CTPeriodRow: View {
    let period: Record
    var deadlines: Record?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(CT.span(period)).font(.wsBody)
                if let pay = CT.due(deadlines?.string("payment")) {
                    Text("Pay by \(pay.text)").font(.wsFootnote).foregroundStyle(pay.tone.textColor)
                }
                if let file = CT.due(deadlines?.string("return_filing")) {
                    Text("File the return by \(file.text)").font(.wsFootnote).foregroundStyle(file.tone.textColor)
                }
                if period.string("status") == "computed" || period.string("status") == "approved",
                   let payable = period.decimal("total_payable") {
                    Text("To pay: \(TaxMoney.text(payable))").font(.wsFootnote.weight(.semibold))
                }
            }
            Spacer()
            StatusBadge(text: CT.statusLabel(period.string("status")), systemImage: CT.statusSymbol(period.string("status")),
                        tone: CT.statusTone(period.string("status")))
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One company

struct CTCompanyView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var company: LoadState<Record> = .idle
    @State private var notice: TaxNotice?
    @State private var editing = false
    @State private var newPeriod = false
    @State private var openPeriod: String?

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch company {
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            case .loaded(let c):
                Section {
                    TaxAmountRow(label: "Company number", value: c.string("company_number") ?? "Not given")
                    TaxAmountRow(label: "Associated companies", value: "\(c.int("associated_companies") ?? 0)")
                    TaxAmountRow(label: "Dormant", value: c.bool("is_dormant") == true ? "Yes (nil return)" : "No")
                } footer: {
                    Text("Associated companies share the small profits limits, so they change the rate of tax.")
                }
                Section {
                    let periods = c.records("periods")
                    if periods.isEmpty {
                        Text("No periods yet.").foregroundStyle(.secondaryText)
                    }
                    ForEach(periods) { period in
                        NavigationLink(value: NativeScreenRoute("ct.period", period.id)) { CTPeriodRow(period: period) }
                    }
                    if canCreate {
                        Button("Start a new period", systemImage: "calendar.badge.plus") { newPeriod = true }
                            .accessibilityIdentifier("ct.company.newPeriod")
                    }
                } header: {
                    Text("Periods")
                } footer: {
                    Text("A period is the company’s year end. Longer than 12 months? It’s split into two Corporation Tax "
                         + "periods, as HMRC requires.")
                }
            default:
                EmptyView()
            }
        }
        .overlay { if company.value == nil, company.error == nil { SkeletonList() } }
        .navigationTitle(company.value?.string("name") ?? "Company")
        .toolbar {
            if session.allows(.update, CT.module), company.value != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editing = true }.accessibilityIdentifier("ct.company.edit")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                CTCompanyForm(company: company.value) { _ in
                    notice = .success("Company details saved.")
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $newPeriod) {
            if let c = company.value {
                NavigationStack {
                    CTNewPeriodForm(company: c) { first, message in
                        notice = .success(message)
                        Task { await load() }
                        openPeriod = first
                    }
                }
            }
        }
        .navigationDestination(item: $openPeriod) { NativeScreenView(route: NativeScreenRoute("ct.period", $0)) }
    }

    private var canCreate: Bool { session.allows(.create, CT.module) }

    private func load() async {
        if company.value == nil { company = .loading }
        do {
            company = .loaded(try await makeTaxAPI(services, user: session.user).record("\(CT.base)/companies/\(uuid)"))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            company = .failed(apiError)
        }
    }
}

// MARK: - Forms

/// Add a company (`POST /companies`) or change one (`PUT /companies/{uuid}`), JSON.
struct CTCompanyForm: View {
    let company: Record?
    let saved: (Record) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var number: String
    @State private var associated: Int
    @State private var dormant: Bool
    @State private var saving = false
    @State private var error: String?

    init(company: Record?, saved: @escaping (Record) -> Void) {
        self.company = company
        self.saved = saved
        _name = State(initialValue: company?.string("name") ?? "")
        _number = State(initialValue: company?.string("company_number") ?? "")
        _associated = State(initialValue: company?.int("associated_companies") ?? 0)
        _dormant = State(initialValue: company?.bool("is_dormant") ?? false)
    }

    var body: some View {
        Form {
            Section {
                TextField("Company name", text: $name)
                    .textContentType(.organizationName)
                    .accessibilityIdentifier("ct.form.name")
                TextField("Company number (optional)", text: $number)
                    .textInputAutocapitalization(.characters)
                    .accessibilityIdentifier("ct.form.number")
            }
            Section {
                Stepper("Associated companies: \(associated)", value: $associated, in: 0...99)
                    .accessibilityIdentifier("ct.form.associated")
            } footer: {
                Text("Other companies under the same control. They share the limits that decide the rate of tax.")
            }
            Section {
                Toggle("Dormant (didn’t trade)", isOn: $dormant).accessibilityIdentifier("ct.form.dormant")
            } footer: {
                Text("A dormant company files a nil return.")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle(company == nil ? "Add a company" : "Edit company")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("ct.form.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    /// The fields `CorporationTaxQueries.createCompany` / `updateCompany` read.
    static func body(name: String, number: String, associated: Int, dormant: Bool, editing: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["name": .string(name.trimmingCharacters(in: .whitespaces)),
                                         "associated_companies": .number(Double(max(0, associated))),
                                         "is_dormant": .bool(dormant)]
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        // A new company leaves an empty number out; an edit can clear it.
        if !trimmed.isEmpty || editing { body["company_number"] = .string(trimmed) }
        return body
    }

    private func save() async {
        saving = true
        error = nil
        defer { saving = false }
        let api = makeTaxAPI(services, user: session.user)
        let body = Self.body(name: name, number: number, associated: associated, dormant: dormant, editing: company != nil)
        do {
            let result: JSONValue
            if let company {
                result = try await api.json(.put, "\(CT.base)/companies/\(company.id)", body)
            } else {
                result = try await api.json(.post, "\(CT.base)/companies", body)
            }
            saved(result.payload.record)
            dismiss()
        } catch {
            self.error = CT.plain(error)
        }
    }
}

/// Start a period of account (`POST /companies/{uuid}/periods`): dates, and what carries over from last year.
struct CTNewPeriodForm: View {
    let company: Record
    /// The first new period's uuid (to open it), and what to say.
    let created: (String?, String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var losses = ""
    @State private var mainPool = ""
    @State private var specialPool = ""
    @State private var saving = false
    @State private var error: String?

    init(company: Record, created: @escaping (String?, String) -> Void) {
        self.company = company
        self.created = created
        let range = Self.suggestedDates(after: company.object("latest_period")?.string("end_date")
                                        ?? company.records("periods").first?.string("end_date"))
        _start = State(initialValue: range.start)
        _end = State(initialValue: range.end)
    }

    var body: some View {
        Form {
            Section {
                DatePicker("Starts", selection: $start, displayedComponents: .date).accessibilityIdentifier("ct.period.start")
                DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)
                    .accessibilityIdentifier("ct.period.end")
            } header: {
                Text(company.string("name") ?? "Company")
            } footer: {
                Text("The company’s accounting year. Longer than 12 months? It’s split into two Corporation Tax periods, "
                     + "as HMRC requires (18 months at most).")
            }
            Section {
                TextField("Trading losses brought forward (£)", text: $losses).keyboardType(.decimalPad)
                TextField("Main pool brought forward (£)", text: $mainPool).keyboardType(.decimalPad)
                TextField("Special rate pool brought forward (£)", text: $specialPool).keyboardType(.decimalPad)
            } header: {
                Text("From last year (optional)")
            } footer: {
                Text("Leave these empty if this is the company’s first year. They’re on last year’s tax computation.")
            }
            if let error { Section { Text(error).foregroundStyle(Tone.danger.textColor) } }
        }
        .navigationTitle("New period")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Creating…" : "Create") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("ct.period.create")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    /// The day after the last period ends, for a year; or the year to the end of last month.
    static func suggestedDates(after lastEnd: String?, now: Date = Date(),
                               calendar: Calendar = .current) -> (start: Date, end: Date) {
        if let lastEnd, let day = CalendarDay(string: lastEnd),
           let start = calendar.date(byAdding: .day, value: 1, to: day.date(calendar: calendar)),
           let end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start) {
            return (start, end)
        }
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let end = calendar.date(byAdding: .day, value: -1, to: firstOfMonth) ?? now
        let start = calendar.date(byAdding: DateComponents(year: -1, day: 1), to: end) ?? now
        return (start, end)
    }

    /// `{start_date, end_date, trading_losses_bf?, opening_main_pool?, opening_special_pool?}`.
    static func body(start: Date, end: Date, losses: String, mainPool: String, specialPool: String,
                     calendar: Calendar = .current) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["start_date": .string(CalendarDay(date: start, calendar: calendar).isoString),
                                         "end_date": .string(CalendarDay(date: end, calendar: calendar).isoString)]
        if let v = CT.number(losses) { body["trading_losses_bf"] = v }
        if let v = CT.number(mainPool) { body["opening_main_pool"] = v }
        if let v = CT.number(specialPool) { body["opening_special_pool"] = v }
        return body
    }

    private func save() async {
        error = nil
        for (text, label) in [(losses, "losses"), (mainPool, "main pool"), (specialPool, "special rate pool")]
        where !text.trimmingCharacters(in: .whitespaces).isEmpty && CT.number(text) == nil {
            error = "The \(label) amount isn’t a number."
            return
        }
        saving = true
        defer { saving = false }
        do {
            let result = try await makeTaxAPI(services, user: session.user).json(
                .post, "\(CT.base)/companies/\(company.id)/periods",
                Self.body(start: start, end: end, losses: losses, mainPool: mainPool, specialPool: specialPool))
            let ids = result.payload.record.array("periods").compactMap(\.stringValue)
            created(ids.first, ids.count > 1
                    ? "Period created and split into \(ids.count) Corporation Tax periods (12 months at most each)."
                    : "Period created. Next: add its trial balance.")
            dismiss()
        } catch {
            self.error = CT.plain(error)
        }
    }
}
