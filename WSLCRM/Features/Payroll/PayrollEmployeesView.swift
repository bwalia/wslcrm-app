import SwiftUI

/// An employer's employees (`GET /api/v2/payroll/employers/{uuid}/employees?search=`): search, add and change.
/// NI numbers and bank details stay masked; showing one in full needs `payroll.update` and is recorded.
struct PayrollEmployeesView: View {
    let employer: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var rows: LoadState<[Record]> = .idle
    @State private var search = ""
    @State private var notice: TaxNotice?
    @State private var adding = false
    @State private var open: Record?

    var body: some View {
        let rights = PayrollRights(session)
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch rows {
            case .loaded(let list):
                if list.isEmpty {
                    TaxEmptyRow(title: search.isEmpty ? "No employees yet" : "No one matches “\(search)”",
                                message: search.isEmpty && rights.create ? "Tap + to add the first person you pay." : nil,
                                systemImage: "person.2")
                }
                ForEach(list) { e in
                    Button { open = e } label: { PayrollEmployeeRow(employee: e) }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("payroll.employee.\(e.id)")
                }
            case .failed(let error): InlineErrorRow(error: error) { Task { await load() } }
            default: HStack { ProgressView(); Text("Loading employees…") }
            }
        }
        .navigationTitle("Employees")
        .searchable(text: $search, prompt: "Name or payroll ID")
        .toolbar {
            if rights.create {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Add employee", systemImage: "plus") }
                        .accessibilityIdentifier("payroll.addEmployee")
                }
            }
        }
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .wsRefreshable { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack {
                PayrollEmployeeFormView(employer: employer, employee: nil) { notice = .success($0); Task { await load() } }
            }
        }
        .sheet(item: $open) { e in
            NavigationStack {
                PayrollEmployeeFormView(employer: employer, employee: e) { notice = .success($0); Task { await load() } }
            }
        }
    }

    private func load() async {
        do {
            rows = .loaded(try await payrollAPI(services).employees(employer: employer, search: search))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            rows = .failed(apiError)
        }
    }
}

struct PayrollEmployeeRow: View {
    let employee: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(employee.string("first_name") ?? "") \(employee.string("last_name") ?? "")").font(.wsBody)
                Text([employee.string("payroll_id"), "tax code \(employee.string("tax_code") ?? "—")",
                      "NI \(employee.string("ni_category") ?? "—")"].compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                if employee.bool("linked_user") == true {
                    Label("Sees their payslips in My pay", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.wsFootnote).foregroundStyle(Tone.success.textColor)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Self.pay(employee)).font(.wsFootnote.monospacedDigit())
                if employee.bool("director") == true { Text("Director").font(.wsCaption).foregroundStyle(Tone.info.textColor) }
                if let status = employee.string("status"), status != "active" {
                    Text(Formatters.humanize(status)).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "£30,000.00 a year" or "£12.21 an hour".
    nonisolated static func pay(_ e: Record) -> String {
        if e.string("pay_basis") == "hourly" { return e.decimal("hourly_rate").map { "\(TaxMoney.text($0)) an hour" } ?? "Hourly" }
        return e.decimal("annual_salary").map { "\(TaxMoney.text($0)) a year" } ?? "No salary set"
    }
}

/// Add or change an employee. Opening an existing one without `payroll.update` shows it read only.
struct PayrollEmployeeFormView: View {
    let employer: String
    let employee: Record?
    let done: (String) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var form = PayrollEmployeeForm()
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var revealed: [String: String] = [:]

    var body: some View {
        let rights = PayrollRights(session)
        let canSave = employee == nil ? rights.create : rights.update
        Form {
            if let employee, employee.string("nino") != nil || employee.string("bank") != nil {
                Section {
                    masked("NI number", field: "nino", hint: employee.string("nino"), canReveal: rights.update)
                    masked("Bank", field: "bank", hint: employee.string("bank"), canReveal: rights.update)
                } header: {
                    Text("Private details")
                } footer: {
                    Text(rights.update ? "Showing a number in full is recorded. It hides again after 30 seconds."
                         : "Only people who can change payroll can show these in full.")
                }
            }
            Group {
                Section {
                    TextField("First name", text: $form.firstName).accessibilityIdentifier("payroll.employee.first")
                    TextField("Last name", text: $form.lastName).accessibilityIdentifier("payroll.employee.last")
                    TextField("Email", text: $form.email).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Payroll ID (optional)", text: $form.payrollID)
                } footer: {
                    Text("Their email links their own login, so they can see their payslips in My pay.")
                }
                Section {
                    TextField(form.ninoHint.map { "NI number (blank keeps \($0))" } ?? "NI number, e.g. QQ123456C",
                              text: $form.nino)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    PayrollDateRow(label: "Date of birth", date: $form.dateOfBirth, suggested: Self.day(1990, 1, 1))
                    Picker("Gender (as HMRC records it)", selection: $form.gender) {
                        Text("Not set").tag("")
                        Text("Female").tag("F")
                        Text("Male").tag("M")
                    }
                    PayrollDateRow(label: "Start date", date: $form.startDate, suggested: Date())
                } header: {
                    Text("Personal")
                } footer: {
                    Text("HMRC needs the NI number, date of birth and gender in the FPS file.")
                }
                Section("Tax and National Insurance") {
                    LabeledContent("Tax code") {
                        TextField("1257L", text: $form.taxCode).multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    Picker("NI category", selection: $form.niCategory) {
                        ForEach(PayrollEmployeeForm.niCategories, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Starter statement", selection: $form.starter) {
                        ForEach(PayrollEmployeeForm.starters, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Student loan", selection: $form.studentLoan) {
                        ForEach(PayrollEmployeeForm.studentLoans, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("Postgraduate loan", isOn: $form.pgLoan)
                    Toggle("Company director (NI worked out yearly)", isOn: $form.director)
                }
                Section {
                    Picker("Paid", selection: $form.payBasis) {
                        Text("A yearly salary").tag("salary")
                        Text("By the hour").tag("hourly")
                    }
                    .pickerStyle(.segmented)
                    if form.payBasis == "hourly" {
                        LabeledContent("Hourly rate (£)") {
                            TextField("12.21", text: $form.hourlyRate).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    } else {
                        LabeledContent("Yearly salary (£)") {
                            TextField("30000", text: $form.annualSalary).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("payroll.employee.salary")
                        }
                    }
                    LabeledContent("Hours each pay period") {
                        TextField("Optional", text: $form.hours).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Pay")
                } footer: {
                    Text("Each new pay run fills in this pay. You can change it for one run without changing it here.")
                }
            }
            .disabled(!canSave)
            if let error {
                Section { Text(error).foregroundStyle(Tone.danger.textColor) }
            } else if !canSave {
                Section { Text("You can look but not change this. Ask an owner or admin for permission to change payroll.") }
            } else if let problem = form.problem {
                Section { Text(problem).foregroundStyle(.secondaryText) }
            }
        }
        .navigationTitle(employee == nil ? "Add an employee" : "\(form.firstName) \(form.lastName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(canSave ? "Cancel" : "Done") { dismiss() } }
            if canSave {
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : employee == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(busy || form.problem != nil)
                        .accessibilityIdentifier("payroll.employee.save")
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let employee { form = PayrollEmployeeForm(employee) }
        }
    }

    @ViewBuilder
    private func masked(_ label: String, field: String, hint: String?, canReveal: Bool) -> some View {
        if let hint {
            LabeledContent(label) {
                HStack {
                    Text(revealed[field] ?? hint).font(.wsBody.monospaced()).textSelection(.enabled)
                    if canReveal {
                        Button(revealed[field] == nil ? "Show" : "Hide") { Task { await toggle(field) } }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("payroll.reveal.\(field)")
                    }
                }
            }
        }
    }

    private func toggle(_ field: String) async {
        if revealed[field] != nil { revealed[field] = nil; return }
        guard let employee else { return }
        do {
            let value = try await payrollAPI(services).reveal(employee: employee.id, field: field)
            revealed[field] = field == "nino" ? value.string("nino")
                : [value.string("sort_code"), value.string("account_number")].compactMap { $0 }.joined(separator: " ")
            try? await Task.sleep(for: .seconds(30))
            revealed[field] = nil
        } catch {
            self.error = "That couldn’t be shown: \(error.asAPIError.plainMessage)"
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            try await payrollAPI(services).saveEmployee(employer: employer, uuid: employee?.id,
                                                        form.body(isNew: employee == nil))
            done(employee == nil ? "\(form.firstName) added. They’ll be on the next pay run." : "Changes saved.")
            dismiss()
        } catch {
            self.error = error.asAPIError.plainMessage
        }
    }

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
    }
}

/// A date that may be left out: "Add date of birth" until one is chosen, with a way to clear it.
private struct PayrollDateRow: View {
    let label: String
    @Binding var date: Date?
    let suggested: Date

    var body: some View {
        if let current = date {
            HStack {
                DatePicker(label, selection: Binding(get: { current }, set: { date = $0 }), displayedComponents: .date)
                Button { date = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear \(label.lowercased())")
            }
        } else {
            Button("Add \(label.lowercased())", systemImage: "calendar.badge.plus") { date = suggested }
        }
    }
}
