import Foundation
import SwiftUI

/// Calls for Payroll and My pay (`lapis/routes/payroll.lua`). Every route reads a JSON body and answers
/// `{success, data}`; errors are `{success: false, error}`. The app never works out pay: every figure comes
/// from the server's engine.
///
/// RBAC (`payroll.lua`): `payroll.read|create|update|delete` for staff screens, `payroll_approve.approve` to
/// approve, reopen and build the FPS. My pay (`/me…`) needs only membership of the workspace.
struct PayrollAPI: Sendable {
    static let base = "/api/v2/payroll"
    let api: TaxAPI

    init(client: APIClient) { api = TaxAPI(client: client) }

    // MARK: Staff

    func overview() async throws -> Record { try await api.get("\(Self.base)/overview").payload.record }

    func employers() async throws -> [Record] { try await api.get("\(Self.base)/employers").payload.recordList }

    /// One employer with its pay schedules.
    func employer(_ uuid: String) async throws -> Record {
        try await api.get("\(Self.base)/employers/\(uuid)").payload.record
    }

    /// Adds (`POST /employers`, which also makes its pay schedule) or changes (`PUT /employers/{uuid}`) an employer.
    @discardableResult
    func saveEmployer(_ uuid: String?, _ body: [String: JSONValue]) async throws -> Record {
        if let uuid { return try await api.json(.put, "\(Self.base)/employers/\(uuid)", body).payload.record }
        return try await api.json(.post, "\(Self.base)/employers", body).payload.record
    }

    /// Pay days for an employer that has none yet (`POST /employers/{uuid}/schedules`).
    func addSchedule(employer: String, frequency: String, firstPayDate: String) async throws {
        try await api.json(.post, "\(Self.base)/employers/\(employer)/schedules",
                           ["name": .string("Main payroll"), "frequency": .string(frequency),
                            "first_pay_date": .string(firstPayDate)])
    }

    func employees(employer: String, search: String = "") async throws -> [Record] {
        try await api.get("\(Self.base)/employers/\(employer)/employees", query: ["search": search.trimmedOrNil])
            .payload.recordList
    }

    @discardableResult
    func saveEmployee(employer: String, uuid: String?, _ body: [String: JSONValue]) async throws -> Record {
        if let uuid { return try await api.json(.put, "\(Self.base)/employees/\(uuid)", body).payload.record }
        return try await api.json(.post, "\(Self.base)/employers/\(employer)/employees", body).payload.record
    }

    /// The full NI number (`{nino}`) or bank details (`{sort_code, account_number, name}`). Audited by the server.
    func reveal(employee: String, field: String) async throws -> Record {
        try await api.json(.post, "\(Self.base)/employees/\(employee)/reveal", ["field": .string(field)]).payload.record
    }

    /// One employer's runs, or every run in the workspace (latest 100).
    func runs(employer: String? = nil) async throws -> [Record] {
        let path = employer.map { "\(Self.base)/employers/\($0)/runs" } ?? "\(Self.base)/runs"
        return try await api.get(path).payload.recordList
    }

    /// The next period's draft run, with a line for each active employee.
    func startRun(employer: String) async throws -> Record {
        try await api.json(.post, "\(Self.base)/employers/\(employer)/runs").payload.record
    }

    /// A run with its `lines`.
    func run(_ uuid: String) async throws -> Record { try await api.get("\(Self.base)/runs/\(uuid)").payload.record }

    func saveLine(run: String, line: String, elements: [PayElementDraft]) async throws {
        try await api.json(.put, "\(Self.base)/runs/\(run)/lines/\(line)", PayElementDraft.body(elements))
    }

    /// calculate, approve (`{confirm: true}`), reopen, paid or close.
    @discardableResult
    func perform(_ action: PayrollRunAction, run: String) async throws -> Record {
        if action == .delete {
            try await api.delete("\(Self.base)/runs/\(run)")
            return Record([:])
        }
        let body: [String: JSONValue] = action == .approve ? ["confirm": .bool(true)] : [:]
        return try await api.json(.post, "\(Self.base)/runs/\(run)/\(action.path)", body).payload.record
    }

    /// Builds the run's Full Payment Submission (not sent to HMRC) and saves the XML for the share sheet.
    func buildFPS(run: Record) async throws -> URL {
        let fps = try await api.json(.post, "\(Self.base)/runs/\(run.id)/fps").payload.record
        let name = "FPS-\(run.string("tax_year") ?? "")-\(run.string("period_number") ?? "").xml"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("payroll", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data((fps.string("xml") ?? "").utf8).write(to: url, options: .atomic)
        return url
    }

    // MARK: Payslips (staff: any line; `mine`: the signed-in person's own published ones)

    func payslip(line: String, mine: Bool) async throws -> Record {
        try await api.get(Self.payslipPath(line: line, mine: mine)).payload.record
    }

    func payslipPDF(line: String, mine: Bool) async throws -> URL {
        try await api.download(Self.payslipPath(line: line, mine: mine) + ".pdf", fallbackName: "payslip.pdf")
    }

    static func payslipPath(line: String, mine: Bool) -> String {
        mine ? "\(base)/me/payslips/\(line)" : "\(base)/payslips/\(line)"
    }

    // MARK: My pay

    /// One entry per employment linked to the signed-in login: tax code, NI letter, masked NINO and bank, YTD.
    func me() async throws -> [Record] { try await api.get("\(Self.base)/me").payload.recordList }

    func myPayslips() async throws -> [Record] { try await api.get("\(Self.base)/me/payslips").payload.recordList }
}

extension View {
    @MainActor
    func payrollAPI(_ services: Services) -> PayrollAPI { PayrollAPI(client: services.client) }
}

/// What the signed-in person may do in Payroll, exactly as `payroll.lua` checks it (owners and admins pass).
struct PayrollRights: Equatable, Sendable {
    var create = false, update = false, delete = false, approve = false

    @MainActor
    init(_ session: SessionStore) {
        create = session.allows(.create, "payroll")
        update = session.allows(.update, "payroll")
        delete = session.allows(.delete, "payroll")
        approve = session.allows(.approve, "payroll_approve")
    }

    /// Setting pay days saves the employer (`PUT`, update) and adds its schedule (`POST …/schedules`, create).
    var setPayDays: Bool { create && update }

    init(create: Bool = false, update: Bool = false, delete: Bool = false, approve: Bool = false) {
        self.create = create
        self.update = update
        self.delete = delete
        self.approve = approve
    }
}

// MARK: - Pay runs

/// Pay run statuses in plain words (draft → calculated → approved → paid → closed).
enum PayrollRunStatus {
    static func label(_ status: String?) -> String {
        switch status {
        case "draft": "Draft"
        case "calculated": "Ready to approve"
        case "approved": "Approved"
        case "submitted": "Sent to HMRC"
        case "paid": "Paid"
        case "closed": "Closed"
        default: Formatters.humanize(status)
        }
    }

    static func tone(_ status: String?) -> Tone {
        switch status {
        case "draft": .neutral
        case "calculated": .warning
        case "approved", "submitted": .info
        case "paid", "closed": .success
        default: .neutral
        }
    }

    static func symbol(_ status: String?) -> String {
        switch status {
        case "draft": "pencil"
        case "calculated": "hourglass"
        case "approved", "submitted": "checkmark.seal"
        case "paid", "closed": "checkmark.circle.fill"
        default: "circle"
        }
    }

    /// What to do next, for someone running payroll for the first time.
    static func nextStep(_ status: String?, errors: Int = 0) -> String {
        switch status {
        case "draft":
            "Check each person’s pay (tap a name to change it), then tap Calculate. Nothing is worked out until you do."
        case "calculated" where errors > 0:
            "\(errors) \(errors == 1 ? "person has" : "people have") a problem. Tap their name to see why, fix it, then calculate again."
        case "calculated":
            "Check the figures, then approve the run. Approving publishes payslips to your staff."
        case "approved", "submitted":
            "Pay your staff from your bank, then tap Mark as paid. Payslips are ready to view and share."
        case "paid":
            "Close the run once you’ve finished with it. A closed run can’t be changed."
        case "closed":
            "This pay run is finished."
        default:
            ""
        }
    }
}

/// The buttons on a pay run, and when each one is offered.
enum PayrollRunAction: String, CaseIterable, Identifiable, Sendable {
    case calculate, approve, paid, fps, reopen, close, delete

    var id: String { rawValue }
    var path: String { rawValue }

    var title: String {
        switch self {
        case .calculate: "Calculate"
        case .approve: "Approve"
        case .paid: "Mark as paid"
        case .fps: "Build the FPS file for HMRC"
        case .reopen: "Take back approval"
        case .close: "Close the run"
        case .delete: "Delete this pay run"
        }
    }

    var systemImage: String {
        switch self {
        case .calculate: "function"
        case .approve: "checkmark.seal"
        case .paid: "banknote"
        case .fps: "doc.badge.arrow.up"
        case .reopen: "arrow.uturn.backward"
        case .close: "lock"
        case .delete: "trash"
        }
    }

    /// Asked before the action runs (approve has its own sheet). nil: no question.
    var confirm: (title: String, message: String)? {
        switch self {
        case .paid: ("Mark this run as paid?", "Do this once the money has left your bank.")
        case .reopen: ("Take back the approval?",
                       "Payslips are hidden from your staff until you approve the run again.")
        case .close: ("Close this pay run?", "A closed run can’t be changed.")
        case .delete: ("Delete this pay run?", "Its lines are deleted too. You can start it again afterwards.")
        default: nil
        }
    }

    var done: String {
        switch self {
        case .calculate: "Calculated. Check the figures, then approve."
        case .approve: "Approved. Payslips are published to your staff."
        case .paid: "Marked as paid. Close the run when you’re finished with it."
        case .fps: "FPS file built. It hasn’t been sent to HMRC."
        case .reopen: "Approval taken back. Make your changes, calculate, then approve again."
        case .close: "Pay run closed."
        case .delete: "Pay run deleted."
        }
    }

    var isPrimary: Bool { [.calculate, .approve, .paid, .close].contains(self) }

    /// The server's rules (`PayrollQueries`): which status allows what, and which grant it needs.
    static func available(status: String?, rights: PayrollRights) -> [PayrollRunAction] {
        var out: [PayrollRunAction] = []
        switch status {
        case "draft", "calculated":
            if rights.update { out.append(.calculate) }
            if status == "calculated", rights.approve { out.append(.approve) }
            if rights.delete { out.append(.delete) }
        case "approved", "submitted":
            if rights.update { out.append(.paid) }
            if rights.approve { out.append(.fps) }
            if status == "approved", rights.approve { out.append(.reopen) }
        case "paid":
            if rights.update { out.append(.close) }
            if rights.approve { out.append(.fps) }
        case "closed":
            if rights.approve { out.append(.fps) }
        default:
            break
        }
        return out
    }

    /// Lines can be changed only on draft or calculated runs.
    static func linesEditable(_ status: String?) -> Bool { status == "draft" || status == "calculated" }
}

/// One pay element on a run line, as typed: `{kind, name, amount}` or `{kind, name, hours, rate}`.
struct PayElementDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var code: String?
    var kind = "earning"
    var name = ""
    var hours = ""
    var rate = ""
    var amount = ""

    static let kinds: [(value: String, label: String)] = [
        ("earning", "Pay (salary, overtime, bonus)"),
        ("statutory", "Statutory pay (sick, maternity…)"),
        ("bik", "Benefit taxed through payroll"),
        ("salary_sacrifice", "Salary sacrifice"),
        ("deduction", "Deduction after tax"),
        ("expense", "Expenses paid back (not taxed)"),
    ]

    static func kindLabel(_ kind: String?) -> String { kinds.first { $0.value == kind }?.label ?? Formatters.humanize(kind) }

    init(code: String? = nil, kind: String = "earning", name: String = "", hours: String = "", rate: String = "",
         amount: String = "") {
        self.code = code
        self.kind = kind
        self.name = name
        self.hours = hours
        self.rate = rate
        self.amount = amount
    }

    init(_ element: Record) {
        self.init(code: element.string("code"), kind: element.string("kind") ?? "earning", name: element.string("name") ?? "",
                  hours: element.string("hours") ?? "", rate: element.string("rate") ?? "", amount: element.string("amount") ?? "")
    }

    /// A line's elements from `inputs.elements`; a run line with none starts with basic pay.
    static func drafts(for line: Record) -> [PayElementDraft] {
        let existing = line.records("inputs.elements").map(PayElementDraft.init)
        return existing.isEmpty ? [PayElementDraft(code: "BASIC", name: "Basic pay")] : existing
    }

    static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "£", with: "")
            .trimmingCharacters(in: .whitespaces))
    }

    var isBlank: Bool { name.trimmedOrNil == nil && hours.trimmedOrNil == nil && rate.trimmedOrNil == nil && amount.trimmedOrNil == nil }

    /// Hours × rate when both are given: the server works the amount out the same way.
    var usesHoursAndRate: Bool { Self.number(hours) != nil && Self.number(rate) != nil }

    var json: JSONValue? {
        var o: [String: JSONValue] = ["kind": .string(kind), "name": .string(name.trimmingCharacters(in: .whitespaces))]
        if let code { o["code"] = .string(code) }
        if let h = Self.number(hours) { o["hours"] = .number(h) }
        if usesHoursAndRate, let r = Self.number(rate) {
            o["rate"] = .number(r)
            return .object(o)
        }
        guard let a = Self.number(amount) else { return nil }
        o["amount"] = .number(a)
        return .object(o)
    }

    /// nil when every filled-in element can be saved.
    static func problem(_ elements: [PayElementDraft]) -> String? {
        let filled = elements.filter { !$0.isBlank }
        if filled.isEmpty { return "Add at least one line of pay." }
        if filled.contains(where: { $0.json == nil }) { return "Each line needs an amount, or hours and a rate." }
        return nil
    }

    /// `PUT /runs/{uuid}/lines/{line}` body. Blank elements are left out.
    static func body(_ elements: [PayElementDraft]) -> [String: JSONValue] {
        ["elements": .array(elements.filter { !$0.isBlank }.compactMap(\.json))]
    }
}

// MARK: - Employers

struct PayrollEmployerForm: Equatable, Sendable {
    var name = ""
    var payeReference = ""
    var accountsOfficeReference = ""
    var frequency = "monthly"
    var firstPayDate = Date()
    var employmentAllowance = false
    var pensionBasis = "net_pay"
    var employeePct = "5"
    var employerPct = "3"

    static let frequencies = [("monthly", "Monthly"), ("weekly", "Weekly"), ("fortnightly", "Every 2 weeks"),
                              ("four_weekly", "Every 4 weeks")]
    static let pensionBases = [("net_pay", "Net pay arrangement"), ("relief_at_source", "Relief at source"),
                               ("salary_sacrifice", "Salary sacrifice"), ("none", "No pension scheme yet")]

    static func frequencyLabel(_ value: String?) -> String {
        frequencies.first { $0.0 == value }?.1 ?? Formatters.humanize(value)
    }

    init() {}

    /// An existing employer. Pension percentages are stored as fractions (0.05) and shown as 5.
    init(_ employer: Record) {
        name = employer.string("name") ?? ""
        payeReference = employer.string("paye_reference") ?? ""
        accountsOfficeReference = employer.string("accounts_office_reference") ?? ""
        employmentAllowance = employer.bool("employment_allowance") ?? false
        pensionBasis = employer.string("default_pension.basis") ?? "none"
        func percent(_ key: String, _ fallback: String) -> String {
            guard let fraction = employer.decimal("default_pension.\(key)") else { return fallback }
            return (fraction * 100).formatted(.number.precision(.fractionLength(0...2)).grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX")))
        }
        employeePct = percent("employee_pct", "5")
        employerPct = percent("employer_pct", "3")
        if let schedule = employer.records("schedules").first {
            frequency = schedule.string("frequency") ?? frequency
        }
    }

    var problem: String? {
        if name.trimmedOrNil == nil { return "Add the business name." }
        if pensionBasis != "none", PayElementDraft.number(employeePct) == nil || PayElementDraft.number(employerPct) == nil {
            return "Pension percentages must be numbers."
        }
        return nil
    }

    /// `POST /employers` (with its pay schedule) or `PUT /employers/{uuid}` (`withSchedule` false: the server
    /// ignores pay days on a change).
    func body(withSchedule: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespaces)),
            "employment_allowance": .bool(employmentAllowance),
            "default_pension": pension,
        ]
        let paye = payeReference.trimmingCharacters(in: .whitespaces).uppercased()
        let office = accountsOfficeReference.trimmingCharacters(in: .whitespaces).uppercased()
        if !paye.isEmpty || !withSchedule { body["paye_reference"] = .string(paye) }
        if !office.isEmpty || !withSchedule { body["accounts_office_reference"] = .string(office) }
        if withSchedule {
            body["frequency"] = .string(frequency)
            body["first_pay_date"] = .string(CalendarDay(date: firstPayDate).isoString)
        }
        return body
    }

    private var pension: JSONValue {
        guard pensionBasis != "none" else { return .object(["basis": .string("none")]) }
        return .object([
            "basis": .string(pensionBasis),
            "employee_pct": .number((PayElementDraft.number(employeePct) ?? 0) / 100),
            "employer_pct": .number((PayElementDraft.number(employerPct) ?? 0) / 100),
            "earnings_basis": .string("qualifying"),
        ])
    }
}

// MARK: - Employees

struct PayrollEmployeeForm: Equatable, Sendable {
    var firstName = ""
    var lastName = ""
    var email = ""
    var payrollID = ""
    /// Typed only to set or change it; the server sends back a masked hint (`ninoHint`).
    var nino = ""
    var ninoHint: String?
    var dateOfBirth: Date?
    var gender = ""
    var startDate: Date?
    var taxCode = "1257L"
    var niCategory = "A"
    var starter = ""
    var payBasis = "salary"
    var annualSalary = ""
    var hourlyRate = ""
    var hours = ""
    var studentLoan = "none"
    var pgLoan = false
    var director = false

    static let niCategories: [(String, String)] = [
        ("A", "A – most employees"), ("B", "B – married women’s reduced rate"), ("C", "C – over State Pension age"),
        ("H", "H – apprentice under 25"), ("J", "J – deferred (pays NI in another job)"), ("M", "M – under 21"),
        ("Z", "Z – under 21, deferred"), ("V", "V – veteran’s first civilian job"),
        ("F", "F – freeport"), ("I", "I – freeport, married women’s reduced rate"), ("L", "L – freeport, deferred"),
        ("S", "S – freeport, over State Pension age"), ("N", "N – investment zone"),
        ("E", "E – investment zone, married women’s reduced rate"), ("D", "D – investment zone, deferred"),
        ("K", "K – investment zone, over State Pension age"),
    ]
    static let starters = [("", "They gave me a P45"), ("A", "A – first job since 6 April"), ("B", "B – this is their only job now"),
                           ("C", "C – they have another job or a pension")]
    static let studentLoans = [("none", "None"), ("plan1", "Plan 1"), ("plan2", "Plan 2"), ("plan4", "Plan 4 (Scotland)"),
                               ("plan5", "Plan 5")]

    init() {}

    init(_ e: Record) {
        firstName = e.string("first_name") ?? ""
        lastName = e.string("last_name") ?? ""
        email = e.string("email") ?? ""
        payrollID = e.string("payroll_id") ?? ""
        ninoHint = e.string("nino")
        dateOfBirth = e.string("date_of_birth").flatMap { CalendarDay(string: String($0.prefix(10)))?.date() }
        gender = e.string("gender") ?? ""
        startDate = e.string("start_date").flatMap { CalendarDay(string: String($0.prefix(10)))?.date() }
        taxCode = e.string("tax_code") ?? "1257L"
        niCategory = e.string("ni_category") ?? "A"
        starter = e.string("starter_declaration") ?? ""
        payBasis = e.string("pay_basis") ?? "salary"
        annualSalary = e.string("annual_salary") ?? ""
        hourlyRate = e.string("hourly_rate") ?? ""
        hours = e.string("contracted_hours") ?? ""
        studentLoan = e.string("student_loan_plan") ?? "none"
        pgLoan = e.bool("pg_loan") ?? false
        director = e.bool("director") ?? false
    }

    var problem: String? {
        if firstName.trimmedOrNil == nil || lastName.trimmedOrNil == nil { return "Add their first and last name." }
        if taxCode.trimmedOrNil == nil { return "Add their tax code (1257L for most people)." }
        let pay = payBasis == "hourly" ? hourlyRate : annualSalary
        if pay.trimmedOrNil != nil, PayElementDraft.number(pay) == nil {
            return payBasis == "hourly" ? "The hourly rate must be a number." : "The salary must be a number."
        }
        if hours.trimmedOrNil != nil, PayElementDraft.number(hours) == nil { return "Hours must be a number." }
        return nil
    }

    /// `POST /employers/{uuid}/employees` leaves blanks out; `PUT /employees/{uuid}` sends them as "" so the server
    /// clears them. The NI number is sent only when one is typed.
    func body(isNew: Bool) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        func text(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty || !isNew { body[key] = .string(trimmed) }
        }
        func day(_ key: String, _ value: Date?) {
            if let value { body[key] = .string(CalendarDay(date: value).isoString) } else if !isNew { body[key] = .string("") }
        }
        text("first_name", firstName)
        text("last_name", lastName)
        text("email", email)
        text("payroll_id", payrollID)
        text("gender", gender)
        text("starter_declaration", starter)
        text("tax_code", taxCode.uppercased().replacingOccurrences(of: " ", with: ""))
        day("date_of_birth", dateOfBirth)
        day("start_date", startDate)
        body["ni_category"] = .string(niCategory)
        body["pay_basis"] = .string(payBasis)
        body["student_loan_plan"] = .string(studentLoan)
        body["pg_loan"] = .bool(pgLoan)
        body["director"] = .bool(director)
        let payKey = payBasis == "hourly" ? "hourly_rate" : "annual_salary"
        if let pay = PayElementDraft.number(payBasis == "hourly" ? hourlyRate : annualSalary) {
            body[payKey] = .number(pay)
        } else if !isNew {
            body[payKey] = .null
        }
        if let h = PayElementDraft.number(hours) { body["contracted_hours"] = .number(h) } else if !isNew {
            body["contracted_hours"] = .null
        }
        let typedNINO = nino.uppercased().replacingOccurrences(of: " ", with: "")
        if !typedNINO.isEmpty { body["nino"] = .string(typedNINO) }
        return body
    }
}
