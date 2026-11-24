import SwiftUI

/// The tax area's home (`/dashboard/tax`): the person's numbers and the way into every tax page.
struct TaxHomeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var stats: LoadState<Record> = .idle

    /// The tax pages, in the order a person works through them.
    static let pages: [(key: String, screen: String, title: String, detail: String, image: String)] = [
        ("tax_bank_accounts", "tax.bank_accounts", "Bank accounts", "Add and manage your bank accounts", "building.columns"),
        ("tax_statements", "tax.statements", "Upload statements", "Bank statements as PDF, CSV or a photo", "doc.badge.arrow.up"),
        ("tax_transactions", "tax.transactions", "Transactions", "See and sort your transactions", "arrow.left.arrow.right"),
        ("tax_my_income", "tax.my_income", "My income", "Jobs, property, pensions, savings, dividends", "wallet.pass"),
        ("tax_reports", "tax.reports", "Tax reports", "Categories, HMRC boxes and your tax", "chart.bar"),
        ("tax_file", "tax.file", "File My Tax", "Connect HMRC, check figures, file your return", "building.2"),
        ("tax_agent", "tax.agent", "AI assistant", "Chat it through, step by step", "bubble.left.and.text.bubble.right"),
        ("tax_categories", "tax.categories", "Categories", "Your own categories for transactions", "tag"),
        ("tax_hmrc", "tax.hmrc", "HMRC settings", "Your connection to HMRC", "link"),
        ("tax_vat", "tax.vat", "VAT", "VAT returns with HMRC", "percent"),
        ("tax_vat_clients", "tax.vat_clients", "VAT clients", "Your clients’ VAT returns, as their agent", "person.2"),
        ("corporation_tax", "ct.companies", "Corporation Tax", "Year-end tax for your companies", "building.columns.circle"),
        ("tax_agent_modes", "tax.agent_modes", "AI agent modes", "How much the AI does on its own", "dial.medium"),
        ("tax_filing_requests", "tax.filing_requests", "Filing requests", "Returns customers asked us to file", "tray.full"),
        ("tax_income_types", "tax.income_types", "Income types", "What My Income asks for", "square.stack.3d.up"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = stats.error {
                    InlineErrorRow(error: error) { Task { await load() } }.brandCard()
                }
                let s = stats.value ?? Record([:])
                DashboardSectionHeader("Your figures")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    statLink("Bank accounts", s.int("total_bank_accounts").map(String.init) ?? "0", "building.columns",
                             .brand, screen: "tax.bank_accounts")
                    statLink("Statements", s.int("total_statements").map(String.init) ?? "0", "doc.text", .info,
                             screen: "tax.statements")
                    MetricCard(title: "Total income", value: s.money("total_income"), systemImage: "arrow.down.left",
                               tone: .success)
                    MetricCard(title: "Total expenses", value: s.money("total_expenses"), systemImage: "arrow.up.right",
                               tone: .danger)
                    statLink("Transactions", s.int("total_transactions").map(String.init) ?? "0",
                             "arrow.left.arrow.right", .brand, screen: "tax.transactions")
                    MetricCard(title: "Sorted", value: s.int("classified_transactions").map(String.init) ?? "0",
                               systemImage: "checkmark.circle", tone: .success)
                    statLink("Not sorted yet", s.int("unclassified_transactions").map(String.init) ?? "0",
                             "exclamationmark.circle", .warning, screen: "tax.transactions")
                }
                .redacted(reason: stats.value == nil && stats.error == nil ? .placeholder : [])

                DashboardSectionHeader("Get it done")
                VStack(spacing: 10) {
                    ForEach(visiblePages, id: \.key) { page in
                        NavigationLink(value: NativeScreenRoute(page.screen)) {
                            HStack(spacing: 14) {
                                AppIconTile(systemImage: page.image, color: Palette.tile(for: page.key), size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.title).font(.wsHeadline).foregroundStyle(.primary)
                                    Text(page.detail).font(.wsSubheadline).foregroundStyle(.secondaryText)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondaryText).accessibilityHidden(true)
                            }
                            .brandCard(padding: 12, radius: 16)
                        }
                        .buttonStyle(.pressableCard)
                        .accessibilityIdentifier("tax.home.\(page.key)")
                    }
                }

                DashboardSectionHeader("How it works")
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").font(.wsSubheadline.bold()).frame(minWidth: 20, alignment: .leading)
                            Text(step).font(.wsSubheadline)
                        }
                    }
                }
                .brandCard()
            }
            .padding()
        }
        .brandCanvas()
        .navigationTitle("Tax")
        .task { await load() }
        .refreshable { await load() }
    }

    static let steps = [
        "Add your bank accounts under Bank accounts.",
        "Upload bank statements (PDF, CSV or a photo) under Upload statements.",
        "The AI reads your statements and sorts each transaction.",
        "Check how each one was sorted under Transactions.",
        "Add any other income — a job, rental property, pension, savings or dividends — under My income.",
        "See your tax summary and HMRC boxes under Tax reports.",
        "Open File My Tax: it connects to HMRC, checks your figures and files your Self Assessment.",
    ]

    /// Pages in the person's menu (the server decides what they may open).
    private var visiblePages: [(key: String, screen: String, title: String, detail: String, image: String)] {
        let keys = session.permissions.menuKeys
        guard !keys.isEmpty else { return Self.pages }
        return Self.pages.filter { keys.contains($0.key) }
    }

    private func statLink(_ title: String, _ value: String, _ image: String, _ tone: Tone, screen: String) -> some View {
        NavigationLink(value: NativeScreenRoute(screen)) {
            MetricCard(title: title, value: value, systemImage: image, tone: tone)
        }
        .buttonStyle(.pressableCard)
    }

    private func load() async {
        if stats.value == nil { stats = .loading }
        do {
            let api = makeTaxAPI(services, user: session.user)
            stats = .loaded(try await api.record("/api/v2/tax/dashboard/stats"))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            // The web shows zeros when the numbers can't be loaded; the app says why.
            if stats.value == nil { stats = .failed(apiError) }
        }
    }
}
