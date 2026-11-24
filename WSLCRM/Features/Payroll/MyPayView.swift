import SwiftUI

/// My pay (`/dashboard/my-pay`): every employee's own tax code, pay so far this tax year and payslips.
/// `GET /api/v2/payroll/me` and `/me/payslips` return only the signed-in person's own published pay; no
/// payroll permission is needed.
struct MyPayView: View {
    struct Pay: Sendable {
        var jobs: [Record]
        var slips: [Record]
    }

    nonisolated static let notLinked = "No payroll record is linked to your login yet. Ask your employer to add your email "
        + "address to your payroll record."

    @Environment(\.services) private var services
    @State private var state: LoadState<Pay> = .idle

    var body: some View {
        List {
            switch state {
            case .loaded(let pay):
                if pay.jobs.isEmpty {
                    Section {
                        TaxEmptyRow(title: "Nothing here yet", message: Self.notLinked,
                                    systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
                ForEach(pay.jobs) { job in jobSection(job) }
                Section {
                    if pay.slips.isEmpty, !pay.jobs.isEmpty {
                        Text("No payslips yet. They appear here when your employer approves a pay run.")
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(pay.slips) { slip in
                        NavigationLink(value: NativeScreenRoute(PayrollScreens.myPayslip(slip.id))) { MyPayslipRow(slip: slip) }
                            .accessibilityIdentifier("mypay.payslip.\(slip.id)")
                    }
                } header: {
                    if !pay.jobs.isEmpty { Text("Payslips") }
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { HStack { ProgressView(); Text("Loading your pay…") } }
            }
        }
        .navigationTitle("My pay")
        .task { await load() }
        .refreshable { await load() }
    }

    private func jobSection(_ job: Record) -> some View {
        Section {
            LabeledContent("Tax code", value: job.string("tax_code") ?? "—")
            if let year = job.string("tax_year") {
                LabeledContent("Tax year", value: year.replacingOccurrences(of: "-", with: "/"))
            }
            TaxAmountRow(label: "Taxable pay so far", value: job.money("ytd.taxable_pay"))
            TaxAmountRow(label: "Income Tax so far", value: job.money("ytd.tax"))
            TaxAmountRow(label: "National Insurance so far", value: job.money("ytd.ni_employee"))
            if (job.decimal("ytd.student_loan") ?? 0) > 0 {
                TaxAmountRow(label: "Student loan so far", value: job.money("ytd.student_loan"))
            }
            if (job.decimal("ytd.postgraduate_loan") ?? 0) > 0 {
                TaxAmountRow(label: "Postgraduate loan so far", value: job.money("ytd.postgraduate_loan"))
            }
            LabeledContent("Paid into", value: job.string("bank") ?? "No bank details on file")
            if let id = job.string("payroll_id") { LabeledContent("Payroll ID", value: id) }
            if let nino = job.string("nino") { LabeledContent("NI number", value: nino) }
        } header: {
            Text(job.string("employer") ?? "Your employer")
        } footer: {
            if job.string("tax_year") == nil { Text("Your figures so far appear after your first payslip.") }
        }
    }

    private func load() async {
        let api = payrollAPI(services)
        do {
            async let jobs = api.me()
            async let slips = api.myPayslips()
            state = .loaded(Pay(jobs: try await jobs, slips: try await slips))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// One of my payslips: pay date, employer and period, gross and net.
struct MyPayslipRow: View {
    let slip: Record

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slip.day("pay_date") ?? "Payslip").font(.wsBody)
                Text([slip.string("employer"), PayslipView.period(slip.string("tax_year"), slip.string("period"))]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(slip.money("net_pay")).font(.wsBody.monospacedDigit().weight(.semibold))
                Text("\(slip.money("gross_pay")) before deductions").font(.wsFootnote.monospacedDigit())
                    .foregroundStyle(.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A payslip, as on paper: payments, deductions, net pay, the year so far and how it was worked out.
/// `mine`: the signed-in employee's own (`/me/payslips/{line}`); otherwise staff (`/payslips/{line}`, `payroll.read`).
/// The PDF is downloaded and opened in Quick Look, which can share or save it.
struct PayslipView: View {
    let line: String
    let mine: Bool
    @Environment(\.services) private var services
    @State private var slip: LoadState<Record> = .idle
    @State private var pdf: URL?
    @State private var downloading = false
    @State private var notice: TaxNotice?

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch slip {
            case .loaded(let s): content(s)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading the payslip…") } }
            }
        }
        .navigationTitle("Payslip")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await openPDF() } } label: {
                    if downloading { ProgressView() } else { Label("PDF", systemImage: "doc.richtext") }
                }
                .disabled(downloading || slip.value == nil)
                .accessibilityLabel("Open the payslip as a PDF to share or save")
                .accessibilityIdentifier("payslip.pdf")
            }
        }
        .quickLookPreview($pdf)
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ s: Record) -> some View {
        Section {
            if let date = s.day("period.pay_date") { LabeledContent("Pay date", value: date) }
            if let period = Self.period(s.string("period.tax_year"), s.string("period.number"),
                                        monthly: s.string("period.frequency") == "monthly") {
                LabeledContent("Period", value: period)
            }
            LabeledContent("Tax code", value: s.string("employee.tax_code") ?? "—")
            LabeledContent("NI category", value: s.string("employee.ni_category") ?? "—")
            if let id = s.string("employee.payroll_id") { LabeledContent("Payroll ID", value: id) }
            if let nino = s.string("employee.nino") { LabeledContent("NI number", value: nino) }
        } header: {
            Text([s.string("employee.name"), s.string("employer.name")].compactMap { $0 }.joined(separator: " · "))
        }
        Section("Payments") {
            ForEach(Array(s.records("payments").enumerated()), id: \.offset) { _, p in
                TaxAmountRow(label: Self.paymentLabel(p), value: p.money("amount"))
            }
            TaxAmountRow(label: "Gross pay", value: s.money("gross_pay"), bold: true)
            if (s.decimal("bik") ?? 0) > 0 {
                TaxAmountRow(label: "Benefits taxed through payroll (not paid)", value: s.money("bik"))
            }
        }
        Section("Deductions") {
            ForEach(Array(s.records("deductions").enumerated()), id: \.offset) { _, d in
                TaxAmountRow(label: d.string("label") ?? "—", value: d.money("amount"))
            }
            TaxAmountRow(label: "Total deductions", value: s.money("total_deductions"), bold: true)
        }
        Section {
            TaxAmountRow(label: "Net pay", value: s.money("net_pay"), bold: true, tone: .success)
        }
        Section("This tax year so far") {
            TaxAmountRow(label: "Taxable pay", value: s.money("ytd.taxable_pay"))
            TaxAmountRow(label: "Income Tax", value: s.money("ytd.tax"))
            TaxAmountRow(label: "National Insurance", value: s.money("ytd.ni_employee"))
        }
        Section("The employer also paid") {
            TaxAmountRow(label: "Employer National Insurance", value: s.money("employer_contributions.ni"))
            TaxAmountRow(label: "Employer pension", value: s.money("employer_contributions.pension"))
        }
        let explanation = s.array("explanation").compactMap(\.stringValue)
        if !explanation.isEmpty {
            Section {
                DisclosureGroup("How this was worked out") {
                    ForEach(Array(explanation.enumerated()), id: \.offset) { _, text in
                        Text(text).font(.wsFootnote)
                    }
                }
            }
        }
    }

    /// "Basic pay (160 hrs × £12.21)" when pay is by the hour.
    nonisolated static func paymentLabel(_ p: Record) -> String {
        let label = p.string("label") ?? "—"
        guard let hours = p.decimal("hours"), let rate = p.decimal("rate") else { return label }
        return "\(label) (\(hours.formatted()) hrs × \(TaxMoney.text(rate)))"
    }

    /// "2026/27, month 8" (monthly) or "2026/27, period 8".
    nonisolated static func period(_ taxYear: String?, _ number: String?, monthly: Bool = false) -> String? {
        guard let taxYear, let number else { return nil }
        return "\(taxYear.replacingOccurrences(of: "-", with: "/")), \(monthly ? "month" : "period") \(number)"
    }

    private func load() async {
        do {
            slip = .loaded(try await payrollAPI(services).payslip(line: line, mine: mine))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            slip = .failed(apiError)
        }
    }

    private func openPDF() async {
        downloading = true
        defer { downloading = false }
        do {
            pdf = try await payrollAPI(services).payslipPDF(line: line, mine: mine)
        } catch {
            notice = .error("The PDF couldn’t be made: \(error.asAPIError.plainMessage)")
        }
    }
}
