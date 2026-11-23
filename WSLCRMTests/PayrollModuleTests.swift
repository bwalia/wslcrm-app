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

    private func body(_ request: URLRequest) throws -> JSONValue {
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
}
