import Charts
import SwiftUI

/// Tax reports (`/dashboard/tax/reports`): categories, HMRC boxes, month by month, and the tax worked out.
///
/// Built on the server's real shapes (the web page reads fields the API doesn't send):
/// `category-breakdown` → `income_categories` / `expense_categories`; `hmrc-boxes` → `boxes`;
/// `monthly-trend` → `data` (net worked out here); `tax-calculation` → `gross_income`, `income_tax_bands`…
/// Tax years are always sent as "2025-26". The year's tax sheet (.xlsx) downloads from here too.
struct TaxReportsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case categories = "Categories", boxes = "HMRC boxes", monthly = "By month", calculation = "Your tax"
        var id: String { rawValue }
    }

    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var year = TaxYear.filing()
    @State private var tab = Tab.categories
    @State private var report: LoadState<Record> = .idle
    @State private var categories = TaxCategoryStore()

    var body: some View {
        List {
            Section {
                TaxYearPicker(year: $year)
                Picker("Report", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tax.reports.tab")
            } footer: {
                Text(TaxYear.span(year))
            }
            switch report {
            case .loaded(let data):
                content(data)
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
            Section {
                TaxDownloadButton(title: "Download the tax sheet (.xlsx)") {
                    try await makeTaxAPI(services, user: session.user).download(
                        "/api/v2/tax/filing/export", query: ["tax_year": year], fallbackName: "tax-calculation-\(year).xlsx")
                }
            } footer: {
                Text("Your figures by HMRC box (SA103F) with the matching Making Tax Digital field, as a spreadsheet.")
            }
            .id(year)
        }
        .navigationTitle("Tax reports")
        .task(id: "\(year)|\(tab.rawValue)") { await load() }
        .task { await categories.load(makeTaxAPI(services, user: session.user)) }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ data: Record) -> some View {
        switch tab {
        case .categories: categoriesReport(data)
        case .boxes: boxesReport(data)
        case .monthly: monthlyReport(data)
        case .calculation: calculationReport(data)
        }
    }

    // MARK: Categories

    @ViewBuilder
    private func categoriesReport(_ data: Record) -> some View {
        let income = data.records("income_categories")
        let expenses = data.records("expense_categories")
        let deductible = expenses.filter { categories.byKey[$0.string("category") ?? ""]?.bool("is_deductible") == true }
            .reduce(Decimal(0)) { $0 + abs($1.decimal("total_amount") ?? 0) }
        Section {
            TaxAmountRow(label: "Total income", value: data.money("total_income"), tone: .success)
            TaxAmountRow(label: "Total expenses", value: data.money("total_expenses"), tone: .danger)
            TaxAmountRow(label: "Allowable expenses", value: TaxMoney.text(deductible))
        }
        if income.isEmpty && expenses.isEmpty {
            Section {
                TaxEmptyRow(title: "No transactions for this tax year",
                            message: "Upload statements and sort your transactions first.", systemImage: "chart.pie")
            }
        }
        categorySection("Income", income, tone: .success)
        categorySection("Expenses", expenses, tone: .danger)
    }

    @ViewBuilder
    private func categorySection(_ title: String, _ rows: [Record], tone: Tone) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    let key = row.string("category")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(categories.name(key) ?? "Uncategorised").font(.wsBody)
                            Spacer()
                            Text(TaxMoney.text(abs(row.decimal("total_amount") ?? 0))).font(.wsBody.monospacedDigit())
                                .foregroundStyle(tone.textColor)
                        }
                        Text("\(row.int("transaction_count") ?? 0) transactions"
                             + (categories.byKey[key ?? ""]?.bool("is_deductible") == true ? " · allowable" : ""))
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: HMRC boxes

    @ViewBuilder
    private func boxesReport(_ data: Record) -> some View {
        let boxes = data.records("boxes")
        if boxes.isEmpty {
            Section {
                TaxEmptyRow(title: "No HMRC boxes yet", message: "Sort your transactions first.", systemImage: "square.grid.3x3")
            }
        } else {
            Section {
                ForEach(boxes) { box in
                    HStack(alignment: .top) {
                        Text(box.string("box") == "unmapped" ? "—" : (box.string("box") ?? ""))
                            .font(.wsBody.monospacedDigit().bold()).frame(width: 36, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(box.string("box_label") ?? "Unmapped").font(.wsBody)
                            Text("\(box.int("transaction_count") ?? 0) transactions").font(.wsFootnote)
                                .foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        Text(TaxMoney.text(abs(box.decimal("total_amount") ?? 0))).font(.wsBody.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("SA103F Self-employment (full) · \(TaxYear.title(year))")
            }
        }
    }

    // MARK: Month by month

    @ViewBuilder
    private func monthlyReport(_ data: Record) -> some View {
        let months = data.records("data")
        if months.isEmpty {
            Section { TaxEmptyRow(title: "No months to show yet", systemImage: "chart.bar") }
        } else {
            Section {
                Chart {
                    ForEach(months) { month in
                        BarMark(x: .value("Month", month.string("month") ?? ""),
                                y: .value("Amount", NSDecimalNumber(decimal: month.decimal("income") ?? 0).doubleValue))
                            .foregroundStyle(by: .value("Kind", "Money in"))
                            .position(by: .value("Kind", "Money in"))
                        BarMark(x: .value("Month", month.string("month") ?? ""),
                                y: .value("Amount", NSDecimalNumber(decimal: abs(month.decimal("expenses") ?? 0)).doubleValue))
                            .foregroundStyle(by: .value("Kind", "Money out"))
                            .position(by: .value("Kind", "Money out"))
                    }
                }
                .chartForegroundStyleScale(["Money in": Color.green, "Money out": Color.red])
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                .frame(height: 220)
                .accessibilityLabel("Money in and out by month")
            } header: {
                Text("The last \(months.count) months")
            }
            Section {
                ForEach(months.reversed()) { month in
                    let income = month.decimal("income") ?? 0
                    let expenses = abs(month.decimal("expenses") ?? 0)
                    let net = income - expenses
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.monthName(month.string("month"))).font(.wsHeadline)
                        HStack {
                            Text("In \(TaxMoney.text(income))").foregroundStyle(Tone.success.textColor)
                            Text("Out \(TaxMoney.text(expenses))").foregroundStyle(Tone.danger.textColor)
                            Spacer()
                            Text("Net \(TaxMoney.signed(net))").bold()
                                .foregroundStyle(net >= 0 ? Tone.success.textColor : Tone.danger.textColor)
                        }
                        .font(.wsFootnote.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Tax worked out

    @ViewBuilder
    private func calculationReport(_ data: Record) -> some View {
        Section {
            TaxAmountRow(label: "Income", value: data.money("gross_income"))
            TaxAmountRow(label: "Allowable expenses", value: data.money("total_expenses"))
            if (data.decimal("additional_income") ?? 0) != 0 {
                TaxAmountRow(label: "Other income (My Income)", value: data.money("additional_income"))
            }
            TaxAmountRow(label: "Profit", value: data.money("trading_profit"))
            TaxAmountRow(label: "Personal allowance", value: data.money("personal_allowance"))
            TaxAmountRow(label: "Taxable income", value: data.money("taxable_income"))
        }
        let bands = data.records("income_tax_bands")
        if !bands.isEmpty {
            Section("Income tax bands") {
                ForEach(bands) { band in
                    let rate = NSDecimalNumber(decimal: band.decimal("rate") ?? 0).doubleValue
                    HStack {
                        VStack(alignment: .leading) {
                            Text(band.string("name") ?? "Band").font(.wsBody)
                            Text("\(Int((rate * 100).rounded()))% on \(TaxMoney.text(band.decimal("taxable_amount")))")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                        Spacer()
                        Text(TaxMoney.text(band.decimal("tax"))).font(.wsBody.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        Section {
            TaxAmountRow(label: "Income tax", value: data.money("income_tax"))
            if (data.decimal("finance_cost_reduction") ?? 0) > 0 {
                TaxAmountRow(label: "Finance-cost reduction (20%)", value: "−" + data.money("finance_cost_reduction"))
            }
            TaxAmountRow(label: "National Insurance (Class 4)", value: data.money("national_insurance"))
            if (data.decimal("class_2_nic") ?? 0) > 0 {
                TaxAmountRow(label: "National Insurance (Class 2)", value: data.money("class_2_nic"))
            }
            TaxAmountRow(label: "Total tax due", value: data.money("total_tax_due"), bold: true)
            if let rate = data.decimal("effective_rate") {
                TaxAmountRow(label: "Effective rate", value: "\(rate.formatted(.number.precision(.fractionLength(0...2))))%")
            }
        } footer: {
            Text("An estimate from your sorted transactions. Always check with a qualified accountant before filing with HMRC. "
                 + "Your personal allowance (\(data.money("personal_allowance"))) is applied automatically.")
        }
    }

    // MARK: Loading

    private func load() async {
        report = .loading
        let api = makeTaxAPI(services, user: session.user)
        do {
            let json: JSONValue
            switch tab {
            case .categories: json = try await api.get("/api/v2/tax/reports/category-breakdown", query: ["tax_year": year])
            case .boxes: json = try await api.get("/api/v2/tax/reports/hmrc-boxes", query: ["tax_year": year])
            case .monthly: json = try await api.get("/api/v2/tax/reports/monthly-trend", query: ["months": "24"])
            case .calculation:
                json = try await api.form(.post, "/api/v2/tax/reports/tax-calculation", [("tax_year", year)])
            }
            // Monthly keeps its rows under `data`; the others are flat.
            report = .loaded(tab == .monthly ? json.record : json.payload.record)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            report = .failed(apiError)
        }
    }

    static func monthName(_ raw: String?) -> String {
        guard let raw, let day = CalendarDay(string: raw + "-01") else { return raw ?? "" }
        return day.date().formatted(.dateTime.month(.wide).year())
    }
}
