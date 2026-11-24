import SwiftUI

/// One pay run (`GET /api/v2/payroll/runs/{uuid}`): its totals, the next step in plain words, the buttons the
/// person's rights and the run's status allow, and a line per employee (tap to see the figures, change the pay
/// or open the payslip).
struct PayrollRunView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var run: LoadState<Record> = .idle
    @State private var notice: TaxNotice?
    @State private var busy: PayrollRunAction?
    @State private var asking: PayrollRunAction?
    @State private var approving = false
    @State private var openLine: Record?
    @State private var fps: URL?

    var body: some View {
        let rights = PayrollRights(session)
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch run {
            case .loaded(let r): content(r, rights: rights)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading the pay run…") } }
            }
        }
        .navigationTitle(run.value.flatMap {
            PayslipView.period($0.string("tax_year"), $0.string("period_number"),
                               monthly: $0.string("schedule.frequency") == "monthly")
        } ?? "Pay run")
        .task { await load() }
        .wsRefreshable { await load() }
        .confirmationDialog(asking?.confirm?.title ?? "", isPresented: Binding(
            get: { asking != nil }, set: { if !$0 { asking = nil } }), titleVisibility: .visible, presenting: asking) { action in
            Button(action.title, role: action == .delete ? .destructive : nil) { Task { await perform(action) } }
        } message: { action in
            Text(action.confirm?.message ?? "")
        }
        .sheet(isPresented: $approving) {
            if let r = run.value {
                NavigationStack { PayrollApproveSheet(run: r) { Task { await perform(.approve) } } }
            }
        }
        .sheet(item: $openLine) { line in
            NavigationStack {
                PayrollLineSheet(run: run.value ?? Record([:]), line: line,
                                 canEdit: rights.update && PayrollRunAction.linesEditable(run.value?.string("status"))) {
                    notice = .success($0)
                    openLine = nil
                    Task { await load() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ r: Record, rights: PayrollRights) -> some View {
        let status = r.string("status")
        let lines = r.records("lines")
        let errors = lines.filter { $0.string("error") != nil }.count
        Section {
            HStack {
                PayrollStatusBadge(status: status)
                Spacer()
                if let day = r.day("pay_date") { Text("Pay day \(day)").font(.wsFootnote).foregroundStyle(.secondaryText) }
            }
            Text(PayrollRunStatus.nextStep(status, errors: errors)).font(.wsSubheadline)
        } header: {
            Text(r.string("employer.name") ?? "Pay run")
        }
        if status != "draft" {
            Section("Totals") {
                TaxAmountRow(label: "Gross pay", value: r.money("totals.gross_pay"))
                TaxAmountRow(label: "Net pay to staff", value: r.money("totals.net_pay"), bold: true)
                TaxAmountRow(label: "Cost to the employer", value: r.money("totals.employer_cost"))
                if (r.decimal("totals.employment_allowance") ?? 0) > 0 {
                    TaxAmountRow(label: "Employment Allowance used", value: r.money("totals.employment_allowance"))
                }
                TaxAmountRow(label: "Owed to HMRC", value: r.money("totals.hmrc_liability"), bold: true, tone: .warning)
            }
        }
        let actions = PayrollRunAction.available(status: status, rights: rights)
        if !actions.isEmpty {
            Section {
                ForEach(actions) { action in
                    Button(role: action == .delete ? .destructive : nil) { tap(action) } label: {
                        HStack {
                            Label(action.title, systemImage: action.systemImage)
                            if busy == action { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy != nil || (action == .approve && errors > 0))
                    .fontWeight(action.isPrimary ? .semibold : .regular)
                    .accessibilityIdentifier("payroll.run.\(action.rawValue)")
                }
            } footer: {
                if status == "calculated", !rights.approve {
                    Text("Someone with permission to approve payroll needs to approve this run.")
                }
            }
        } else if status != "closed" {
            Section { Text("You can look at this run but not change it.").foregroundStyle(.secondaryText) }
        }
        if let fps {
            Section {
                ShareLink(item: fps) { Label("Share \(fps.lastPathComponent)", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("This app doesn’t send it to HMRC yet: send it with HMRC’s Basic PAYE Tools or your payroll software.")
            }
        }
        Section {
            if lines.isEmpty {
                Text("No employees are on this pay schedule. Add employees to the employer, then start a new run.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(lines) { line in
                Button { openLine = line } label: { PayrollLineRow(line: line) }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("payroll.line.\(line.id)")
            }
        } header: {
            Text("People in this run")
        }
    }

    private func tap(_ action: PayrollRunAction) {
        if action == .approve { approving = true } else if action.confirm != nil { asking = action } else {
            Task { await perform(action) }
        }
    }

    private func load() async {
        do {
            run = .loaded(try await payrollAPI(services).run(uuid))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            run = .failed(apiError)
        }
    }

    private func perform(_ action: PayrollRunAction) async {
        guard let r = run.value else { return }
        busy = action
        defer { busy = nil }
        let api = payrollAPI(services)
        do {
            switch action {
            case .fps:
                fps = try await api.buildFPS(run: r)
                notice = .success(action.done)
            case .delete:
                try await api.perform(.delete, run: uuid)
                dismiss()
                return
            default:
                let result = try await api.perform(action, run: uuid)
                let errors = result.int("errors") ?? 0
                if action == .calculate, errors > 0 {
                    notice = .warning("Calculated, but \(errors) \(errors == 1 ? "person has" : "people have") a problem. "
                                      + "Tap their name to see why.")
                } else if let note = result.string("journal.note") {
                    notice = .success("\(action.done) \(note)")
                } else {
                    notice = .success(action.done)
                }
            }
            await load()
        } catch {
            notice = .error(error)
        }
    }
}

/// An employee's line in a run: name, tax code, net pay, and any problem.
struct PayrollLineRow: View {
    let line: Record

    var body: some View {
        let warnings = line.array("result.warnings").count
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(line)).font(.wsBody)
                Text("Tax code \(line.string("result.tax_code") ?? line.string("employee.tax_code") ?? "—") · NI "
                     + (line.string("result.ni_category") ?? line.string("employee.ni_category") ?? "—"))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if line.string("error") != nil {
                    Label("Problem: tap to see why", systemImage: "xmark.octagon.fill")
                        .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                } else if warnings > 0 {
                    Label(warnings == 1 ? "1 thing to check" : "\(warnings) things to check",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            }
            Spacer()
            if line.object("result") != nil {
                Text(line.money("net_pay")).font(.wsBody.monospacedDigit().weight(.semibold))
            } else {
                Text("Not worked out yet").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    nonisolated static func name(_ line: Record) -> String {
        "\(line.string("employee.first_name") ?? "") \(line.string("employee.last_name") ?? "")"
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One person's line: the figures and how they were worked out, the pay entered, and the payslip.
struct PayrollLineSheet: View {
    let run: Record
    let line: Record
    let canEdit: Bool
    let saved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let error = line.string("error") {
                Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Tone.danger.textColor) }
            }
            let warnings = line.records("result.warnings")
            if !warnings.isEmpty {
                Section {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                        Label(w.string("message") ?? "Check this line.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Tone.warning.textColor)
                    }
                }
            }
            if let r = line.object("result") {
                Section("This pay period") {
                    TaxAmountRow(label: "Gross pay", value: r.money("gross_pay"))
                    TaxAmountRow(label: "Income Tax", value: r.money("tax"))
                    TaxAmountRow(label: "National Insurance", value: r.money("ni_employee"))
                    let loans = (r.decimal("student_loan") ?? 0) + (r.decimal("postgraduate_loan") ?? 0)
                    if loans > 0 { TaxAmountRow(label: "Student loans", value: TaxMoney.text(loans)) }
                    TaxAmountRow(label: "Pension", value: r.money(r.string("pension_basis") == "relief_at_source"
                                                                   ? "pension_employee_net" : "pension_employee"))
                    TaxAmountRow(label: "Net pay", value: r.money("net_pay"), bold: true, tone: .success)
                }
                Section("The employer also pays") {
                    TaxAmountRow(label: "Employer National Insurance", value: r.money("ni_employer"))
                    TaxAmountRow(label: "Employer pension", value: r.money("pension_employer"))
                    TaxAmountRow(label: "Total cost", value: r.money("employer_cost"), bold: true)
                }
            } else {
                Section { Text("Calculate the run to see the tax, National Insurance and net pay.") }
            }
            Section("Pay entered") {
                let entered = line.records("inputs.elements").map(PayElementDraft.init)
                if entered.isEmpty { Text("No pay entered for this run yet.").foregroundStyle(.secondaryText) }
                ForEach(Array(entered.enumerated()), id: \.offset) { _, e in
                    LabeledContent {
                        Text(e.usesHoursAndRate ? "\(e.hours) h × \(Self.pounds(e.rate))" : Self.pounds(e.amount))
                            .monospacedDigit()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(e.name.isEmpty ? PayElementDraft.kindLabel(e.kind) : e.name)
                            Text(PayElementDraft.kindLabel(e.kind)).font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                }
                if canEdit {
                    NavigationLink {
                        PayrollLineEditor(run: run.id, line: line, saved: saved)
                    } label: {
                        Label("Change pay for this run", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("payroll.line.edit")
                }
            }
            if line.string("published_at") != nil {
                Section {
                    NavigationLink {
                        PayslipView(line: line.id, mine: false)
                    } label: {
                        Label("Open the payslip", systemImage: "doc.text")
                    }
                }
            }
            let explanation = line.array("result.explanation").compactMap(\.stringValue)
            if !explanation.isEmpty {
                Section {
                    DisclosureGroup("How this was worked out") {
                        ForEach(Array(explanation.enumerated()), id: \.offset) { _, text in Text(text).font(.wsFootnote) }
                    }
                }
            }
        }
        .navigationTitle(PayrollLineRow.name(line))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private static func pounds(_ text: String) -> String {
        PayElementDraft.number(text).map { TaxMoney.text(Decimal($0)) } ?? "—"
    }
}

/// Change one person's pay for this run (`PUT /runs/{uuid}/lines/{line} {elements}`). The run goes back to draft.
struct PayrollLineEditor: View {
    let run: String
    let line: Record
    let saved: (String) -> Void
    @Environment(\.services) private var services
    @State private var drafts: [PayElementDraft] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Enter an amount, or hours and a rate. Tax, National Insurance, loans and pension are worked out "
                     + "when you calculate.").font(.wsFootnote)
            }
            ForEach($drafts) { $d in
                Section {
                    Picker("Type", selection: $d.kind) {
                        ForEach(PayElementDraft.kinds, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    TextField("Description, e.g. Overtime", text: $d.name)
                    HStack {
                        TextField("Hours", text: $d.hours).keyboardType(.decimalPad)
                        TextField("Rate (£)", text: $d.rate).keyboardType(.decimalPad)
                    }
                    if d.usesHoursAndRate, let h = PayElementDraft.number(d.hours), let r = PayElementDraft.number(d.rate) {
                        LabeledContent("Amount", value: TaxMoney.text(Decimal(h * r)))
                    } else {
                        TextField("Amount (£)", text: $d.amount).keyboardType(.decimalPad)
                            .accessibilityIdentifier("payroll.element.amount")
                    }
                    if drafts.count > 1 {
                        Button("Remove this line", role: .destructive) { drafts.removeAll { $0.id == d.id } }
                    }
                }
            }
            Section {
                Button("Add a line", systemImage: "plus") { drafts.append(PayElementDraft()) }
                if let error { Text(error).foregroundStyle(Tone.danger.textColor) } else if let problem = PayElementDraft.problem(drafts) {
                    Text(problem).foregroundStyle(.secondaryText)
                }
            }
        }
        .navigationTitle("Change pay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(busy || PayElementDraft.problem(drafts) != nil)
                    .accessibilityIdentifier("payroll.line.save")
            }
        }
        .onAppear { if drafts.isEmpty { drafts = PayElementDraft.drafts(for: line) } }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await payrollAPI(services).saveLine(run: run, line: line.id, elements: drafts)
            saved("Saved. Calculate the run again before approving.")
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }
}

/// Approve a calculated run: the totals, a tick to confirm, then `POST /runs/{uuid}/approve {confirm: true}`.
struct PayrollApproveSheet: View {
    let run: Record
    let approve: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        Form {
            Section {
                Text("Approving publishes payslips to your staff and posts the payroll journal to your books. "
                     + "Check the totals first.").font(.wsSubheadline)
            }
            Section {
                TaxAmountRow(label: "Employees", value: "\(run.int("totals.employees") ?? 0)")
                TaxAmountRow(label: "Gross pay", value: run.money("totals.gross_pay"))
                TaxAmountRow(label: "Net pay to staff", value: run.money("totals.net_pay"), bold: true)
                TaxAmountRow(label: "Cost to the employer", value: run.money("totals.employer_cost"))
                TaxAmountRow(label: "Pension (employee and employer)", value: TaxMoney.text(
                    (run.decimal("totals.pension_employee") ?? 0) + (run.decimal("totals.pension_employer") ?? 0)))
                TaxAmountRow(label: "Employment Allowance used", value: run.money("totals.employment_allowance"))
                TaxAmountRow(label: "Owed to HMRC", value: run.money("totals.hmrc_liability"), bold: true)
            }
            if let warnings = run.int("totals.warnings"), warnings > 0 {
                Section {
                    TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                        Text(warnings == 1 ? "One line has something to check. Look at it before approving."
                             : "\(warnings) lines have something to check. Look at them before approving.")
                    }
                }
            }
            Section {
                TaxCheckbox(isOn: $confirmed, text: "I’ve checked these figures and approve paying them.",
                            identifier: "payroll.approve.confirm")
            }
        }
        .navigationTitle("Approve this pay run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Approve") { dismiss(); approve() }.disabled(!confirmed)
                    .accessibilityIdentifier("payroll.approve.send")
            }
        }
    }
}
