import XCTest
@testable import WSLCRM

/// Payroll and My pay (`lapis/routes/payroll.lua`, `queries/PayrollQueries.lua`, `lib/payroll/payslip.lua`):
/// the menu keys open native screens, the screens read the server's real response shapes, and every write
/// sends the body the server reads.
final class PayrollModuleTests: XCTestCase {
    private func client(_ handler: @escaping StubURLProtocol.Handler) async -> APIClient {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "access", refreshToken: "refresh"))
        let client = APIClient(baseURL: URL(string: "https://api.test")!, session: StubURLProtocol.session(handler: handler),
                               tokenStore: store)
        await client.setNamespace("ns-1")
        return client
    }

    private static func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())
    }

    // MARK: My pay

    @MainActor
    func testMyPayOpensANativeScreen() {
        guard case .native(let route)? = NativeModules.destination(forKey: "my_pay") else {
            return XCTFail("my_pay has no native screen")
        }
        XCTAssertNotNil(ModuleCatalog.screen(route.id))
        XCTAssertNotNil(ModuleCatalog.screen(PayrollScreens.myPayslip("line-1")))
        XCTAssertNil(ModuleCatalog.screen("payroll.my_payslip"), "a payslip needs its line")
        XCTAssertTrue(NativeModules.serverKeys.contains("my_pay"))
    }

    /// `Q.my_summary`: one entry per linked employment; `ytd` is the latest `payroll_ytd.data`.
    func testMyPayReadsTheSummaryAndPayslips() async throws {
        let client = await client { request in
            switch request.url?.path {
            case "/api/v2/payroll/me":
                return .json(200, """
                {"success":true,"data":[{"employer":"Acme Ltd","tax_code":"1257L","ni_category":"A","payroll_id":"E001",
                "nino":"QQ •• •• •• C","bank":"•••• 5678","tax_year":"2026-27","ytd":{"taxable_pay":16666.64,"tax":2049.6,
                "ni_employee":665.12,"ni_employer":1720.4,"student_loan":0,"postgraduate_loan":0}}]}
                """)
            case "/api/v2/payroll/me/payslips":
                return .json(200, """
                {"success":true,"data":[{"uuid":"line-8","pay_date":"2026-11-28","tax_year":"2026-27","period":8,
                "employer":"Acme Ltd","gross_pay":2278.69,"net_pay":1939.35,"tax":256.2,"ni":83.14}]}
                """)
            default:
                XCTFail("unexpected \(request.url?.path ?? "")")
                return .json(404, "{}")
            }
        }
        let api = PayrollAPI(client: client)
        let jobs = try await api.me()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].string("employer"), "Acme Ltd")
        XCTAssertEqual(jobs[0].money("ytd.taxable_pay"), "£16,666.64")
        XCTAssertEqual(jobs[0].money("ytd.tax"), "£2,049.60")
        XCTAssertEqual(jobs[0].money("ytd.ni_employee"), "£665.12")
        XCTAssertEqual(jobs[0].string("bank"), "•••• 5678")

        let slips = try await api.myPayslips()
        XCTAssertEqual(slips.map(\.id), ["line-8"])
        XCTAssertEqual(PayslipView.period(slips[0].string("tax_year"), slips[0].string("period")), "2026/27, period 8")
        XCTAssertEqual(slips[0].money("net_pay"), "£1,939.35")
    }

    /// No payroll record linked: the server answers an empty list (`[]`, or lua-cjson's `{}`).
    func testNoLinkedRecordIsAnEmptyList() async throws {
        let client = await client { request in
            .json(200, request.url?.path == "/api/v2/payroll/me" ? #"{"success":true,"data":{}}"# : #"{"success":true,"data":[]}"#)
        }
        let api = PayrollAPI(client: client)
        let jobs = try await api.me()
        let slips = try await api.myPayslips()
        XCTAssertTrue(jobs.isEmpty)
        XCTAssertTrue(slips.isEmpty)
        XCTAssertTrue(MyPayView.notLinked.contains("Ask your employer to add your email address"))
    }

    /// `Payslip.build`: one model for the screen and the PDF.
    func testPayslipReadsTheServersModel() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/payroll/me/payslips/line-8")
            return .json(200, """
            {"success":true,"data":{"employer":{"name":"Acme Ltd","paye_reference":"123/AB45678"},
            "employee":{"name":"Jane Smith","payroll_id":"E001","nino":"QQ •• •• •• C","tax_code":"1257L","ni_category":"A"},
            "period":{"tax_year":"2026-27","number":8,"pay_date":"2026-11-28","frequency":"monthly"},
            "payments":[{"label":"Basic pay","amount":2083.33},{"label":"Overtime","amount":195.36,"hours":16,"rate":12.21}],
            "deductions":[{"label":"Income Tax","amount":256.2},{"label":"National Insurance","amount":83.14}],
            "gross_pay":2278.69,"total_deductions":339.34,"net_pay":1939.35,
            "employer_contributions":{"ni":220.1,"pension":61.2},"ytd":{"taxable_pay":16666.64,"tax":2049.6,"ni_employee":665.12},
            "explanation":["Tax code 1257L: £1,047.50 tax-free this month."],"employer_name":"Acme Ltd"}}
            """)
        }
        let slip = try await PayrollAPI(client: client).payslip(line: "line-8", mine: true)
        let payments = slip.records("payments")
        XCTAssertEqual(payments.map(PayslipView.paymentLabel), ["Basic pay", "Overtime (16 hrs × £12.21)"])
        XCTAssertEqual(slip.records("deductions").count, 2)
        XCTAssertEqual(slip.money("net_pay"), "£1,939.35")
        XCTAssertEqual(slip.money("employer_contributions.ni"), "£220.10")
        XCTAssertEqual(PayslipView.period(slip.string("period.tax_year"), slip.string("period.number"), monthly: true),
                       "2026/27, month 8")
        XCTAssertEqual(slip.array("explanation").compactMap(\.stringValue).count, 1)
    }

    func testPayslipPDFKeepsTheServersFileName() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/payroll/me/payslips/line-8.pdf")
            return StubURLProtocol.Response(status: 200, body: Data("%PDF-1.4".utf8), headers: [
                "Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"payslip-2026-27-8.pdf\""])
        }
        let url = try await PayrollAPI(client: client).payslipPDF(line: "line-8", mine: true)
        XCTAssertEqual(url.lastPathComponent, "payslip-2026-27-8.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF-1.4".utf8))
        XCTAssertEqual(PayrollAPI.payslipPath(line: "l-1", mine: false), "/api/v2/payroll/payslips/l-1")
    }

    // MARK: Payroll (staff)

    @MainActor
    func testPayrollOpensANativeScreenAndItsInnerScreensResolve() {
        guard case .native(let route)? = NativeModules.destination(forKey: "payroll") else {
            return XCTFail("payroll has no native screen")
        }
        XCTAssertNotNil(ModuleCatalog.screen(route.id))
        for id in [PayrollScreens.runs, PayrollScreens.employer("e-1"), PayrollScreens.employees("e-1"),
                   PayrollScreens.run("r-1"), PayrollScreens.payslip("l-1")] {
            XCTAssertNotNil(ModuleCatalog.screen(id), id)
        }
        XCTAssertNil(ModuleCatalog.screen("payroll.run"), "a run needs its uuid")
        XCTAssertTrue(NativeModules.serverKeys.contains("payroll"))
    }

    /// `Q.overview`: employers (with counts and latest run), open runs and the recent HMRC liability.
    func testOverviewParses() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/payroll/overview")
            return .json(200, """
            {"success":true,"data":{"employers":[{"uuid":"e-1","name":"Acme Ltd","paye_reference":"123/AB45678",
            "employment_allowance":true,"default_pension":{"basis":"net_pay","employee_pct":0.05,"employer_pct":0.03,
            "earnings_basis":"qualifying"},"status":"active","employee_count":3,
            "latest_run":{"uuid":"r-1","status":"calculated","pay_date":"2026-11-28","period_number":8,"tax_year":"2026-27"}}],
            "open_runs":[{"uuid":"r-1","status":"calculated","pay_date":"2026-11-28","period_number":8,"tax_year":"2026-27",
            "employer":"Acme Ltd","totals":{"net_pay":5817.75,"hmrc_liability":2100.5}}],"hmrc_liability_recent":1980.12,
            "rti_live":false}}
            """)
        }
        let o = try await PayrollAPI(client: client).overview()
        XCTAssertEqual(o.records("employers").map(\.id), ["e-1"])
        XCTAssertEqual(o.records("open_runs").first?.money("totals.net_pay"), "£5,817.75")
        XCTAssertEqual(o.money("hmrc_liability_recent"), "£1,980.12")
        XCTAssertEqual(o.bool("rti_live"), false)
        let form = PayrollEmployerForm(o.records("employers")[0])
        XCTAssertEqual(form.employeePct, "5", "fractions are shown as percentages")
        XCTAssertEqual(form.employerPct, "3")
        XCTAssertTrue(form.employmentAllowance)
    }

    /// `POST /employers`: name, references, frequency + first_pay_date (makes the schedule), pension as fractions.
    func testNewEmployerBody() throws {
        var form = PayrollEmployerForm()
        XCTAssertNotNil(form.problem, "a name is needed")
        form.name = " Acme Ltd "
        form.payeReference = "123/ab45678"
        form.firstPayDate = Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 28))!
        form.employeePct = "5"
        form.employerPct = "3.5"
        XCTAssertNil(form.problem)
        let body = form.body(withSchedule: true)
        XCTAssertEqual(body["name"], .string("Acme Ltd"))
        XCTAssertEqual(body["paye_reference"], .string("123/AB45678"))
        XCTAssertNil(body["accounts_office_reference"], "blank is left out of a new employer")
        XCTAssertEqual(body["frequency"], .string("monthly"))
        XCTAssertEqual(body["first_pay_date"], .string("2026-04-28"))
        XCTAssertEqual(body["employment_allowance"], .bool(false))
        XCTAssertEqual(body["default_pension"]?["basis"], .string("net_pay"))
        XCTAssertEqual(body["default_pension"]?["employee_pct"], .number(0.05))
        XCTAssertEqual(body["default_pension"]?["employer_pct"], .number(0.035))
        XCTAssertEqual(body["default_pension"]?["earnings_basis"], .string("qualifying"))

        form.pensionBasis = "none"
        let change = form.body(withSchedule: false)
        XCTAssertEqual(change["default_pension"], .object(["basis": .string("none")]))
        XCTAssertNil(change["frequency"], "the server ignores pay days on a change")
        XCTAssertEqual(change["accounts_office_reference"], .string(""), "a change can clear a reference")
    }

    func testEmployerWritesGoWhereTheServerReadsThem() async throws {
        let client = await client { request in
            let json = try Self.body(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/payroll/employers"):
                XCTAssertEqual(json["name"], .string("Acme Ltd"))
                return .json(201, #"{"success":true,"data":{"uuid":"e-1","name":"Acme Ltd"}}"#)
            case ("PUT", "/api/v2/payroll/employers/e-1"):
                return .json(200, #"{"success":true,"data":{"uuid":"e-1","name":"Acme"}}"#)
            case ("POST", "/api/v2/payroll/employers/e-1/schedules"):
                XCTAssertEqual(json["frequency"], .string("weekly"))
                XCTAssertEqual(json["first_pay_date"], .string("2026-12-04"))
                return .json(201, #"{"success":true,"data":{"uuid":"s-1","frequency":"weekly"}}"#)
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return .json(404, "{}")
            }
        }
        let api = PayrollAPI(client: client)
        let added = try await api.saveEmployer(nil, ["name": .string("Acme Ltd")])
        let changed = try await api.saveEmployer("e-1", ["name": .string("Acme")])
        XCTAssertEqual(added.id, "e-1")
        XCTAssertEqual(changed.string("name"), "Acme")
        try await api.addSchedule(employer: "e-1", frequency: "weekly", firstPayDate: "2026-12-04")
    }

    /// `employee_json`: the NINO and bank come back as hints only.
    func testEmployeesParseAndTheFormKeepsTheMaskedNINO() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/payroll/employers/e-1/employees")
            XCTAssertEqual(request.url?.query, "search=smi")
            return .json(200, """
            {"success":true,"data":[{"uuid":"p-1","payroll_id":"E001","first_name":"Jane","last_name":"Smith",
            "email":"jane@acme.test","nino":"QQ •• •• •• C","date_of_birth":"1990-05-01","gender":"F","start_date":"2024-01-08",
            "starter_declaration":"B","tax_code":"1257L","ni_category":"A","student_loan_plan":"plan2","pg_loan":false,
            "director":false,"pay_basis":"salary","annual_salary":30000,"contracted_hours":160,"pension":{},
            "bank":"•••• 5678","status":"active","linked_user":true}]}
            """)
        }
        let rows = try await PayrollAPI(client: client).employees(employer: "e-1", search: " smi ")
        XCTAssertEqual(rows.map(\.id), ["p-1"])
        XCTAssertEqual(PayrollEmployeeRow.pay(rows[0]), "£30,000.00 a year")
        let form = PayrollEmployeeForm(rows[0])
        XCTAssertEqual(form.ninoHint, "QQ •• •• •• C")
        XCTAssertEqual(form.nino, "", "the hint is never sent back as a number")
        XCTAssertEqual(form.studentLoan, "plan2")
        XCTAssertEqual(form.hours, "160")
        let body = form.body(isNew: false)
        XCTAssertNil(body["nino"])
        XCTAssertEqual(body["date_of_birth"], .string("1990-05-01"))
        XCTAssertEqual(body["annual_salary"], .number(30000))
        XCTAssertEqual(body["starter_declaration"], .string("B"))
    }

    /// `POST /employers/{uuid}/employees` (blanks left out) and `PUT /employees/{uuid}` (blanks clear).
    func testEmployeeBodies() throws {
        var form = PayrollEmployeeForm()
        XCTAssertNotNil(form.problem)
        form.firstName = "Sam"
        form.lastName = "Jones"
        form.nino = "qq 12 34 56 c"
        form.taxCode = "1257l"
        form.payBasis = "hourly"
        form.hourlyRate = "12.21"
        form.hours = "20"
        form.starter = "A"
        XCTAssertNil(form.problem)
        let body = form.body(isNew: true)
        XCTAssertEqual(body["first_name"], .string("Sam"))
        XCTAssertEqual(body["nino"], .string("QQ123456C"))
        XCTAssertEqual(body["tax_code"], .string("1257L"))
        XCTAssertEqual(body["hourly_rate"], .number(12.21))
        XCTAssertNil(body["annual_salary"])
        XCTAssertEqual(body["contracted_hours"], .number(20))
        XCTAssertEqual(body["student_loan_plan"], .string("none"))
        XCTAssertEqual(body["starter_declaration"], .string("A"))
        XCTAssertEqual(body["pay_basis"], .string("hourly"))
        XCTAssertNil(body["email"], "blank is left out of a new employee")
        XCTAssertNil(body["date_of_birth"])

        form.nino = ""
        form.hours = ""
        let change = form.body(isNew: false)
        XCTAssertNil(change["nino"], "blank keeps the stored NI number")
        XCTAssertEqual(change["email"], .string(""))
        XCTAssertEqual(change["date_of_birth"], .string(""))
        XCTAssertEqual(change["contracted_hours"], .null)

        form.hourlyRate = "twelve"
        XCTAssertEqual(form.problem, "The hourly rate must be a number.")
    }

    func testEmployeeWritesAndReveal() async throws {
        let client = await client { request in
            let json = try Self.body(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/payroll/employers/e-1/employees"):
                return .json(201, #"{"success":true,"data":{"uuid":"p-2","first_name":"Sam"}}"#)
            case ("PUT", "/api/v2/payroll/employees/p-2"):
                return .json(200, #"{"success":true,"data":{"uuid":"p-2","first_name":"Samuel"}}"#)
            case ("POST", "/api/v2/payroll/employees/p-2/reveal"):
                XCTAssertEqual(json, .object(["field": .string("nino")]))
                return .json(200, #"{"success":true,"data":{"nino":"QQ123456C"}}"#)
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return .json(404, "{}")
            }
        }
        let api = PayrollAPI(client: client)
        let added = try await api.saveEmployee(employer: "e-1", uuid: nil, ["first_name": .string("Sam")])
        let changed = try await api.saveEmployee(employer: "e-1", uuid: "p-2", [:])
        let shown = try await api.reveal(employee: "p-2", field: "nino")
        XCTAssertEqual(added.id, "p-2")
        XCTAssertEqual(changed.string("first_name"), "Samuel")
        XCTAssertEqual(shown.string("nino"), "QQ123456C")
    }

    // MARK: Pay runs

    /// `GET /runs/{uuid}`: `run_json` + `lines` (`line_json`), as after calculating.
    static let calculatedRun = """
    {"success":true,"data":{"uuid":"r-1","tax_year":"2026-27","period_number":8,"pay_date":"2026-11-28",
    "status":"calculated","totals":{"employees":2,"gross_pay":4500,"tax":520.4,"ni_employee":180.2,"ni_employer":410.3,
    "student_loan":0,"postgraduate_loan":0,"pension_employee":120,"pension_employer":72,"net_pay":3679.4,
    "employer_cost":4982.3,"errors":1,"warnings":1,"employment_allowance":410.3,"hmrc_liability":700.6},
    "schedule":{"name":"Main payroll","frequency":"monthly"},"employer":{"name":"Acme Ltd","uuid":"e-1"},
    "lines":[{"uuid":"l-1","employee":{"uuid":"p-1","first_name":"Jane","last_name":"Smith","payroll_id":"E001",
    "tax_code":"1257L","ni_category":"A"},"inputs":{"elements":[{"code":"BASIC","name":"Basic pay","kind":"earning",
    "amount":2500,"hours":160}]},"result":{"tax_code":"1257L","gross_pay":2500,"tax":290.2,"ni_category":"A",
    "ni_employee":100.1,"ni_employer":230.2,"student_loan":0,"postgraduate_loan":0,"pension_employee":75,
    "pension_employee_net":0,"pension_employer":45,"pension_basis":"net_pay","net_pay":2034.7,"employer_cost":2775.2,
    "warnings":[{"code":"BIG_CHANGE","message":"Net pay changed by more than 10%."}],"explanation":["Tax code 1257L."],
    "ytd":{}},"error":null,"gross_pay":2500,"tax":290.2,"ni_employee":100.1,"ni_employer":230.2,"student_loan":0,
    "pension_employee":75,"pension_employer":45,"net_pay":2034.7,"employer_cost":2775.2},
    {"uuid":"l-2","employee":{"uuid":"p-2","first_name":"Sam","last_name":"Jones","tax_code":"BR","ni_category":"A"},
    "inputs":{"elements":[]},"error":"Net pay would be -£20.00.","gross_pay":0,"net_pay":0}],"rti_live":false}}
    """

    func testARunAndItsLinesParse() async throws {
        let client = await client { request in
            XCTAssertEqual(request.url?.path, "/api/v2/payroll/runs/r-1")
            return .json(200, Self.calculatedRun)
        }
        let run = try await PayrollAPI(client: client).run("r-1")
        XCTAssertEqual(run.id, "r-1")
        XCTAssertEqual(run.string("employer.name"), "Acme Ltd")
        XCTAssertEqual(run.money("totals.hmrc_liability"), "£700.60")
        let lines = run.records("lines")
        XCTAssertEqual(lines.map(\.id), ["l-1", "l-2"])
        XCTAssertEqual(PayrollLineRow.name(lines[0]), "Jane Smith")
        XCTAssertEqual(lines[0].records("result.warnings").count, 1)
        XCTAssertEqual(lines[0].money("net_pay"), "£2,034.70")
        XCTAssertNotNil(lines[1].string("error"))
        XCTAssertNil(lines[1].object("result"), "an errored line has no result yet")
        let drafts = PayElementDraft.drafts(for: lines[0])
        XCTAssertEqual(drafts.map(\.code), ["BASIC"])
        XCTAssertEqual(drafts[0].amount, "2500")
        XCTAssertEqual(drafts[0].hours, "160")
        XCTAssertEqual(PayElementDraft.drafts(for: lines[1]).map(\.name), ["Basic pay"], "an empty line starts with basic pay")
        XCTAssertTrue(PayrollRunStatus.nextStep("calculated", errors: 1).contains("1 person has a problem"))
    }

    /// `Q.update_line`: each element needs `kind` and an amount, or hours and a rate (the server multiplies).
    func testLineElementsBody() throws {
        var basic = PayElementDraft(code: "BASIC", name: "Basic pay", hours: "160", amount: "2,500")
        let overtime = PayElementDraft(kind: "earning", name: "Overtime", hours: "10", rate: "18.5", amount: "999")
        let blank = PayElementDraft()
        XCTAssertNil(PayElementDraft.problem([basic, overtime, blank]))
        let body = PayElementDraft.body([basic, overtime, blank])
        guard case .array(let elements)? = body["elements"] else { return XCTFail("elements is a list") }
        XCTAssertEqual(elements.count, 2, "a blank line is left out")
        XCTAssertEqual(elements[0], .object(["code": .string("BASIC"), "kind": .string("earning"), "name": .string("Basic pay"),
                                             "hours": .number(160), "amount": .number(2500)]))
        XCTAssertEqual(elements[1], .object(["kind": .string("earning"), "name": .string("Overtime"), "hours": .number(10),
                                             "rate": .number(18.5)]), "hours × rate: the server works out the amount")
        basic.amount = ""
        XCTAssertEqual(PayElementDraft.problem([basic]), "Each line needs an amount, or hours and a rate.")
        XCTAssertEqual(PayElementDraft.problem([blank]), "Add at least one line of pay.")
        XCTAssertEqual(PayElementDraft.kinds.map(\.value),
                       ["earning", "statutory", "bik", "salary_sacrifice", "deduction", "expense"], "the server's ELEMENT_KINDS")
    }

    /// The buttons follow `PayrollQueries`' status rules and `payroll.lua`'s grants.
    func testRunActionsFollowStatusAndRights() {
        let all = PayrollRights(create: true, update: true, delete: true, approve: true)
        XCTAssertEqual(PayrollRunAction.available(status: "draft", rights: all), [.calculate, .delete])
        XCTAssertEqual(PayrollRunAction.available(status: "calculated", rights: all), [.calculate, .approve, .delete])
        XCTAssertEqual(PayrollRunAction.available(status: "approved", rights: all), [.paid, .fps, .reopen])
        XCTAssertEqual(PayrollRunAction.available(status: "submitted", rights: all), [.paid, .fps])
        XCTAssertEqual(PayrollRunAction.available(status: "paid", rights: all), [.close, .fps])
        XCTAssertEqual(PayrollRunAction.available(status: "closed", rights: all), [.fps])
        let clerk = PayrollRights(create: true, update: true)
        XCTAssertEqual(PayrollRunAction.available(status: "calculated", rights: clerk), [.calculate],
                       "approving needs payroll_approve.approve")
        XCTAssertEqual(PayrollRunAction.available(status: "approved", rights: clerk), [.paid])
        XCTAssertEqual(PayrollRunAction.available(status: "draft", rights: PayrollRights()), [], "read only")
        XCTAssertTrue(PayrollRunAction.linesEditable("calculated"))
        XCTAssertFalse(PayrollRunAction.linesEditable("approved"))
        XCTAssertEqual(PayrollRunStatus.label("calculated"), "Ready to approve")
        XCTAssertNotNil(PayrollRunAction.delete.confirm)
        XCTAssertNil(PayrollRunAction.calculate.confirm)
    }

    /// start → calculate → approve `{confirm: true}` → paid → close, the FPS file and delete.
    func testRunActionsCallTheServer() async throws {
        let client = await client { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/payroll/employers/e-1/runs"):
                return .json(201, #"{"success":true,"data":{"uuid":"r-2","status":"draft","period_number":9}}"#)
            case ("POST", "/api/v2/payroll/runs/r-2/calculate"):
                return .json(200, #"{"success":true,"data":{"employees":2,"errors":0,"net_pay":3679.4}}"#)
            case ("POST", "/api/v2/payroll/runs/r-2/approve"):
                XCTAssertEqual(try Self.body(request), .object(["confirm": .bool(true)]))
                return .json(200, #"{"success":true,"data":{"status":"approved","journal":{"debits":10,"credits":10}}}"#)
            case ("POST", "/api/v2/payroll/runs/r-2/paid"), ("POST", "/api/v2/payroll/runs/r-2/close"),
                 ("POST", "/api/v2/payroll/runs/r-2/reopen"):
                return .json(200, #"{"success":true,"data":{"status":"paid"}}"#)
            case ("POST", "/api/v2/payroll/runs/r-2/fps"):
                return .json(201, #"{"success":true,"data":{"uuid":"s-1","kind":"FPS","status":"built","xml":"<IRenvelope/>","live":false}}"#)
            case ("PUT", "/api/v2/payroll/runs/r-2/lines/l-1"):
                XCTAssertEqual(try Self.body(request)["elements"]?.list.count, 1)
                return .json(200, #"{"success":true,"data":true}"#)
            case ("DELETE", "/api/v2/payroll/runs/r-2"):
                return .json(200, #"{"success":true,"data":true}"#)
            default:
                XCTFail("unexpected \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return .json(404, "{}")
            }
        }
        let api = PayrollAPI(client: client)
        let started = try await api.startRun(employer: "e-1")
        XCTAssertEqual(started.id, "r-2")
        try await api.saveLine(run: "r-2", line: "l-1", elements: [PayElementDraft(name: "Basic pay", amount: "100")])
        let totals = try await api.perform(.calculate, run: "r-2")
        let approved = try await api.perform(.approve, run: "r-2")
        XCTAssertEqual(totals.int("errors"), 0)
        XCTAssertEqual(approved.string("status"), "approved")
        try await api.perform(.reopen, run: "r-2")
        try await api.perform(.paid, run: "r-2")
        try await api.perform(.close, run: "r-2")
        let fps = try await api.buildFPS(run: Record(["uuid": .string("r-2"), "tax_year": .string("2026-27"),
                                                      "period_number": .number(9)]))
        XCTAssertEqual(fps.lastPathComponent, "FPS-2026-27-9.xml")
        XCTAssertEqual(try String(contentsOf: fps, encoding: .utf8), "<IRenvelope/>")
        try await api.perform(.delete, run: "r-2")
    }

    func testRunListsReadEitherEmployerShape() async throws {
        let client = await client { request in
            XCTAssertTrue(["/api/v2/payroll/runs", "/api/v2/payroll/employers/e-1/runs"].contains(request.url?.path ?? ""))
            return .json(200, """
            {"success":true,"data":[{"uuid":"r-1","tax_year":"2026-27","period_number":8,"pay_date":"2026-11-28",
            "status":"paid","totals":{"net_pay":3679.4},"schedule":{"name":"Main payroll","frequency":"monthly"},
            "employer":{"name":"Acme Ltd","uuid":"e-1"}}]}
            """)
        }
        let api = PayrollAPI(client: client)
        let all = try await api.runs()
        let mine = try await api.runs(employer: "e-1")
        XCTAssertEqual(all.map(\.id), ["r-1"])
        XCTAssertEqual(mine.first?.string("employer.name"), "Acme Ltd")
    }
}
