import SwiftUI

/// Payroll (`/dashboard/payroll`): employers, pay runs in progress and what is owed to HMRC.
/// A beginner's month: open the employer → start the next pay run → check each person → calculate → approve →
/// pay staff and mark the run paid → payslips.
struct PayrollHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var overview: LoadState<Record> = .idle
    @State private var notice: TaxNotice?
    @State private var adding = false

    var body: some View {
        let rights = PayrollRights(session)
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch overview {
            case .loaded(let o): content(o, rights: rights)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading payroll…") } }
            }
        }
        .navigationTitle("Payroll")
        .toolbar {
            if rights.create {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add employer", systemImage: "plus") }
                        .accessibilityIdentifier("payroll.addEmployer")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack { PayrollEmployerFormView(employer: nil) { notice = .success($0); Task { await load() } } }
        }
    }

    @ViewBuilder
    private func content(_ o: Record, rights: PayrollRights) -> some View {
        let employers = o.records("employers")
        let open = o.records("open_runs")
        if o.bool("rti_live") != true {
            Section {
                TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                    Text("Sending to HMRC (RTI) isn’t switched on yet. Pay runs, payslips and the FPS file are made "
                         + "here; send the FPS with HMRC’s Basic PAYE Tools or your current payroll software.")
                }
            }
        }
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                MetricCard(title: "Employers", value: "\(employers.count)", systemImage: "building.2", tone: .info)
                MetricCard(title: "Pay runs in progress", value: "\(open.count)", systemImage: "hourglass", tone: .warning)
                MetricCard(title: "Owed to HMRC (recent runs)", value: o.money("hmrc_liability_recent"),
                           systemImage: "building.columns", tone: .danger)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        Section {
            if open.isEmpty { Text("Nothing waiting. Open an employer to start the next pay run.").foregroundStyle(.secondaryText) }
            ForEach(open) { run in
                NavigationLink(value: NativeScreenRoute(PayrollScreens.run(run.id))) { PayrollRunRow(run: run) }
            }
            NavigationLink("See all pay runs", value: NativeScreenRoute(PayrollScreens.runs))
                .accessibilityIdentifier("payroll.allRuns")
        } header: { Text("Pay runs in progress") }
        Section {
            if employers.isEmpty {
                TaxEmptyRow(title: "No employers yet",
                            message: rights.create ? "Add the business whose staff you pay to get started."
                                : "Ask an owner or admin to add the business whose staff you pay.",
                            systemImage: "building.2")
                if rights.create { Button("Add an employer", systemImage: "plus") { adding = true } }
            }
            ForEach(employers) { e in
                NavigationLink(value: NativeScreenRoute(PayrollScreens.employer(e.id))) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.string("name") ?? "Employer").font(.wsBody)
                        Text("\(e.string("paye_reference") ?? "No PAYE reference yet") · \(Self.people(e.int("employee_count") ?? 0))")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .accessibilityIdentifier("payroll.employer.\(e.id)")
            }
        } header: { Text("Employers") }
        Section {
            Text("1. Open the employer and start the next pay run.\n2. Check each person’s pay.\n3. Calculate.\n"
                 + "4. Approve: payslips are published.\n5. Pay your staff, then mark the run as paid.")
                .font(.wsFootnote)
        } header: { Text("How a pay run works") }
    }

    static func people(_ count: Int) -> String { count == 1 ? "1 employee" : "\(count) employees" }

    private func load() async {
        do {
            overview = .loaded(try await payrollAPI(services).overview())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            overview = .failed(apiError)
        }
    }
}

/// A pay run in a list: period, pay day, employer, net pay and status.
struct PayrollRunRow: View {
    let run: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(PayslipView.period(run.string("tax_year"), run.string("period_number"),
                                        monthly: run.string("schedule.frequency") == "monthly") ?? "Pay run")
                    .font(.wsBody)
                Text([run.string("employer.name") ?? run.string("employer"), run.day("pay_date").map { "pay day \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if run.decimal("totals.net_pay") != nil {
                    Text("\(run.money("totals.net_pay")) net").font(.wsFootnote.monospacedDigit())
                }
                PayrollStatusBadge(status: run.string("status"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PayrollStatusBadge: View {
    let status: String?

    var body: some View {
        StatusBadge(text: PayrollRunStatus.label(status), systemImage: PayrollRunStatus.symbol(status),
                    tone: PayrollRunStatus.tone(status))
    }
}

/// Every pay run in the workspace, newest first (`GET /api/v2/payroll/runs`, the latest 100).
struct PayrollRunsView: View {
    @Environment(\.services) private var services
    @State private var runs: LoadState<[Record]> = .idle

    var body: some View {
        List {
            switch runs {
            case .loaded(let list):
                if list.isEmpty {
                    TaxEmptyRow(title: "No pay runs yet", message: "Open an employer to start the first one.",
                                systemImage: "calendar.badge.clock")
                }
                ForEach(list) { run in
                    NavigationLink(value: NativeScreenRoute(PayrollScreens.run(run.id))) { PayrollRunRow(run: run) }
                }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            default: HStack { ProgressView(); Text("Loading pay runs…") }
            }
        }
        .navigationTitle("Pay runs")
        .task { await load() }
        .wsRefreshable { await load() }
    }

    private func load() async {
        do {
            runs = .loaded(try await payrollAPI(services).runs())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            runs = .failed(apiError)
        }
    }
}

// MARK: - One employer

/// An employer: its references, pay days and pension, its people, and its pay runs (start the next one here).
struct PayrollEmployerView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var employer: LoadState<Record> = .idle
    @State private var runs: [Record] = []
    @State private var notice: TaxNotice?
    @State private var editing = false
    @State private var starting = false
    @State private var opened: NativeScreenRoute?

    var body: some View {
        let rights = PayrollRights(session)
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch employer {
            case .loaded(let e): content(e, rights: rights)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle(employer.value?.string("name") ?? "Employer")
        .task { await load() }
        .wsRefreshable { await load() }
        .navigationDestination(item: $opened) { NativeScreenView(route: $0) }
        .sheet(isPresented: $editing) {
            if let e = employer.value {
                NavigationStack { PayrollEmployerFormView(employer: e) { notice = .success($0); Task { await load() } } }
            }
        }
    }

    @ViewBuilder
    private func content(_ e: Record, rights: PayrollRights) -> some View {
        let schedule = e.records("schedules").first
        Section {
            LabeledContent("PAYE reference", value: e.string("paye_reference") ?? "Not added yet")
            LabeledContent("Accounts Office reference", value: e.string("accounts_office_reference") ?? "Not added yet")
            LabeledContent("Pay days", value: schedule.map {
                "\(PayrollEmployerForm.frequencyLabel($0.string("frequency"))), from \($0.day("first_pay_date") ?? "—")"
            } ?? "Not set yet")
            LabeledContent("Workplace pension", value: Self.pension(e))
            LabeledContent("Employment Allowance", value: e.bool("employment_allowance") == true ? "Claimed" : "Not claimed")
            if rights.update {
                Button("Change employer details", systemImage: "pencil") { editing = true }
                    .accessibilityIdentifier("payroll.employer.edit")
            }
        } footer: {
            if e.string("paye_reference") == nil || e.string("accounts_office_reference") == nil {
                Text("Add the PAYE and Accounts Office references (on HMRC’s letter from when you registered as an "
                     + "employer) before building an FPS file.")
            }
        }
        Section("People") {
            NavigationLink(value: NativeScreenRoute(PayrollScreens.employees(uuid))) {
                Label("Employees", systemImage: "person.2")
            }
            .accessibilityIdentifier("payroll.employees")
        }
        Section {
            if schedule == nil {
                if rights.setPayDays {
                    Text("Set this employer’s pay days before starting a pay run.").foregroundStyle(.secondaryText)
                    Button("Set pay days", systemImage: "calendar") { editing = true }
                } else {
                    Text("This employer’s pay days aren’t set yet, so no pay run can start. Ask the workspace owner to set them.")
                        .foregroundStyle(.secondaryText)
                }
            } else if rights.create {
                Button { Task { await start() } } label: {
                    if starting { HStack { ProgressView(); Text("Starting…") } } else {
                        Label("Start the next pay run", systemImage: "play.circle.fill")
                    }
                }
                .disabled(starting)
                .accessibilityIdentifier("payroll.startRun")
            }
            if runs.isEmpty { Text("No pay runs yet.").foregroundStyle(.secondaryText) }
            ForEach(runs) { run in
                NavigationLink(value: NativeScreenRoute(PayrollScreens.run(run.id))) { PayrollRunRow(run: run) }
            }
        } header: {
            Text("Pay runs")
        } footer: {
            if schedule != nil, rights.create {
                Text("A new run has a line for everyone active on the pay schedule, with their usual pay filled in.")
            }
        }
    }

    static func pension(_ e: Record) -> String {
        let basis = e.string("default_pension.basis") ?? "none"
        guard basis != "none" else { return "No scheme yet" }
        let form = PayrollEmployerForm(e)
        let name = PayrollEmployerForm.pensionBases.first { $0.0 == basis }?.1 ?? Formatters.humanize(basis)
        return "\(name): \(form.employeePct)% employee, \(form.employerPct)% employer"
    }

    private func load() async {
        let api = payrollAPI(services)
        do {
            async let e = api.employer(uuid)
            async let r = api.runs(employer: uuid)
            employer = .loaded(try await e)
            runs = (try? await r) ?? []
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            employer = .failed(apiError)
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        do {
            let run = try await payrollAPI(services).startRun(employer: uuid)
            notice = .success("Pay run started. Check each person’s pay, then calculate.")
            await load()
            opened = NativeScreenRoute(PayrollScreens.run(run.id))
        } catch {
            notice = .error(error)
        }
    }
}

/// Add or change an employer. A new employer gets its pay schedule (how often, first payday) at once.
struct PayrollEmployerFormView: View {
    let employer: Record?
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form = PayrollEmployerForm()
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?

    /// A new employer, or one that has no pay days yet, chooses them here (adding them to an existing employer
    /// needs `payroll.create`).
    private var hasPayDays: Bool { !(employer?.records("schedules").isEmpty ?? true) }

    private var setsPayDays: Bool {
        employer.map { $0.records("schedules").isEmpty && PayrollRights(session).create } ?? true
    }

    var body: some View {
        Form {
            Section {
                TextField("Business name", text: $form.name).accessibilityIdentifier("payroll.employer.name")
                TextField("Employer PAYE reference, e.g. 123/AB45678", text: $form.payeReference)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Accounts Office reference, e.g. 123PA00045678", text: $form.accountsOfficeReference)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            } footer: {
                Text("Both references are on the letter HMRC sent when you registered as an employer. You can add them later.")
            }
            Section {
                if setsPayDays {
                    Picker("How often you pay", selection: $form.frequency) {
                        ForEach(PayrollEmployerForm.frequencies, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    DatePicker("First payday", selection: $form.firstPayDate, displayedComponents: .date)
                } else if hasPayDays {
                    LabeledContent("How often you pay", value: PayrollEmployerForm.frequencyLabel(form.frequency))
                } else {
                    Text("Not set yet").foregroundStyle(.secondaryText)
                }
            } header: {
                Text("Pay days")
            } footer: {
                Text(setsPayDays ? "The first pay run is paid on this date; the next ones follow on from it."
                     : hasPayDays ? "Pay days can’t be changed once they’re set."
                     : "Your role can’t set pay days. Ask the workspace owner to set them.")
            }
            Section {
                Picker("Scheme", selection: $form.pensionBasis) {
                    ForEach(PayrollEmployerForm.pensionBases, id: \.0) { Text($0.1).tag($0.0) }
                }
                if form.pensionBasis != "none" {
                    LabeledContent("Employee pays (%)") {
                        TextField("5", text: $form.employeePct).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Employer pays (%)") {
                        TextField("3", text: $form.employerPct).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Workplace pension")
            } footer: {
                Text("Usually 5% from the employee and 3% from the employer, on qualifying earnings.")
            }
            Section {
                Toggle("Claim Employment Allowance", isOn: $form.employmentAllowance)
            } footer: {
                Text("It reduces the employer’s National Insurance bill. Most small employers can claim it.")
            }
            if let error {
                Section { Text(error).foregroundStyle(Tone.danger.textColor) }
            } else if let problem = form.problem {
                Section { Text(problem).foregroundStyle(.secondaryText) }
            }
        }
        .navigationTitle(employer == nil ? "Add an employer" : "Employer details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : employer == nil ? "Add" : "Save") { Task { await save() } }
                    .disabled(busy || form.problem != nil)
                    .accessibilityIdentifier("payroll.employer.save")
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let employer { form = PayrollEmployerForm(employer) }
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        let api = payrollAPI(services)
        do {
            if let employer {
                try await api.saveEmployer(employer.id, form.body(withSchedule: false))
                if setsPayDays {
                    try await api.addSchedule(employer: employer.id, frequency: form.frequency,
                                              firstPayDate: CalendarDay(date: form.firstPayDate).isoString)
                }
                done("Employer details saved.")
            } else {
                try await api.saveEmployer(nil, form.body(withSchedule: true))
                done("Employer added. Open it to add employees.")
            }
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}
