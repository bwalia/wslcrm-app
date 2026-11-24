import SwiftUI

/// Shop analytics (menu key `shop_analytics`, dashboard /dashboard/shop/analytics): sales, checkout, carts, quotes,
/// the AI advisor and the "What do I need?" survey, for a period compared with the one before, with CSV exports.
/// Figures come from the server only (queries/ShopAnalyticsQueries.lua); RBAC `shop_analytics` read.
struct ShopAnalyticsView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var query = ShopAnalyticsQuery()
    @State private var preset: Int? = 30
    @State private var customFrom = Calendar.ukCalendar.date(byAdding: .day, value: -29, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var customProblem: String?
    @State private var state: LoadState<ShopAnalyticsReport> = .idle
    @State private var loading = false
    @State private var refreshError: APIError?
    @State private var metric: ShopTrendMetric = .revenue
    @State private var survey: LoadState<ShopSurveyReport> = .idle
    @State private var exporting: ShopAnalyticsExport?
    @State private var exported: ShopExportedFile?
    @State private var exportError: APIError?

    var body: some View {
        Group {
            if session.permissions.can(.read, .shopAnalytics) {
                content
            } else {
                ContentUnavailableView("No access to shop analytics",
                                       systemImage: "lock",
                                       description: Text("Ask the workspace owner for the Shop analytics permission (read)."))
            }
        }
        .navigationTitle("Shop analytics")
    }

    private var content: some View {
        List {
            periodSection
            if let report = state.value {
                reportSections(report)
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            } else {
                Section { ProgressView("Working out the figures…").frame(maxWidth: .infinity) }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { exportMenu }
        }
        .task(id: query) { await load() }
        .wsRefreshable { await load() }
        .sheet(item: $exported) { file in ShopExportSheet(file: file) }
        .alert("Export failed", isPresented: .init(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") {}
        } message: {
            Text(exportError?.errorDescription ?? "")
        }
    }

    // MARK: Period

    private var periodSection: some View {
        Section {
            Picker("Period", selection: $preset) {
                ForEach(ShopAnalyticsQuery.presets, id: \.days) { item in Text(item.label).tag(Int?.some(item.days)) }
                Text("Custom").tag(Int?.none)
            }
            .pickerStyle(.segmented)
            .onChange(of: preset) { _, value in
                if let value { query = ShopAnalyticsQuery(days: value, bucket: query.bucket) }
            }
            .accessibilityIdentifier("analytics.period")
            if preset == nil {
                DatePicker("From", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                    .accessibilityIdentifier("analytics.from")
                DatePicker("To", selection: $customTo, in: ...Date.now, displayedComponents: .date)
                    .accessibilityIdentifier("analytics.to")
                Button("Show this period") { applyCustom() }
                    .accessibilityIdentifier("analytics.applyCustom")
                if let customProblem {
                    Label(customProblem, systemImage: "exclamationmark.triangle").font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
            Picker("Group by", selection: $query.bucket) {
                Text("Automatic").tag(ShopAnalyticsBucket?.none)
                ForEach(ShopAnalyticsBucket.allCases, id: \.self) { Text($0.label).tag(ShopAnalyticsBucket?.some($0)) }
            }
            .accessibilityIdentifier("analytics.bucket")
        } footer: {
            if let report = state.value {
                Text("\(ShopAnalyticsFormat.longDate(report.window.from)) – \(ShopAnalyticsFormat.longDate(report.window.to)) "
                     + "(\(report.window.days) days, UK time), compared with "
                     + "\(ShopAnalyticsFormat.longDate(report.window.previous.from)) – \(ShopAnalyticsFormat.longDate(report.window.previous.to)).")
            }
        }
    }

    private func applyCustom() {
        let result = ShopAnalyticsQuery.custom(from: customFrom, to: customTo)
        customProblem = result.problem
        if var next = result.query {
            next.bucket = query.bucket
            query = next
        }
    }

    // MARK: Report

    @ViewBuilder
    private func reportSections(_ r: ShopAnalyticsReport) -> some View {
        let ch = r.changes ?? ShopAnalyticsChanges()
        let cur = r.currency
        if let refreshError {
            Section { InlineErrorRow(error: refreshError) { Task { await load() } } }
        }
        Section {
            LazyVGrid(columns: .tiles(sizeClass), spacing: 10) {
                ShopKPITile(label: "Revenue", value: ShopAnalyticsFormat.pounds(r.sales.revenueMinor), change: ch.revenueMinor,
                            sub: "\(ShopAnalyticsFormat.pounds(r.sales.netRevenueMinor)) after refunds",
                            systemImage: "sterlingsign.circle", hint: "Inc VAT and shipping, orders paid in the period")
                ShopKPITile(label: "Paid orders", value: ShopAnalyticsFormat.count(r.sales.orders), change: ch.orders,
                            sub: r.sales.refundedOrders > 0 ? "\(ShopAnalyticsFormat.count(r.sales.refundedOrders)) refunded" : nil,
                            systemImage: "receipt")
                ShopKPITile(label: "Average order", value: ShopAnalyticsFormat.pounds(r.sales.aovMinor), change: ch.aovMinor,
                            sub: "inc VAT", systemImage: "creditcard")
                ShopKPITile(label: "Customers", value: ShopAnalyticsFormat.count(r.sales.customers), change: ch.customers,
                            sub: "\(ShopAnalyticsFormat.count(r.sales.newCustomers)) new · "
                                + "\(ShopAnalyticsFormat.count(r.sales.returningCustomers)) returning",
                            systemImage: "person.2", hint: "Distinct buyer emails with a paid order in the period")
                ShopKPITile(label: "Checkout → paid", value: ShopAnalyticsFormat.percent(r.checkout.paidRate),
                            sub: "\(ShopAnalyticsFormat.count(r.checkout.paid)) of \(ShopAnalyticsFormat.count(r.checkout.started)) checkouts",
                            systemImage: "cart")
                ShopKPITile(label: "Abandoned carts", value: ShopAnalyticsFormat.count(r.carts.abandoned), change: ch.abandoned,
                            lowerIsBetter: true,
                            sub: "\(ShopAnalyticsFormat.pounds(r.carts.abandonedValueMinor)) ex VAT left behind",
                            systemImage: "basket",
                            hint: "Items in the cart, never paid, untouched for \(r.carts.abandonAfterHours) hours")
                ShopKPITile(label: "Quotes", value: ShopAnalyticsFormat.count(r.quotes.created), change: ch.quotes,
                            sub: "\(ShopAnalyticsFormat.percent(r.quotes.conversionRate)) became orders", systemImage: "doc.text")
                ShopKPITile(label: "AI chats completed", value: ShopAnalyticsFormat.count(r.chat.completed),
                            change: ch.chatCompleted,
                            sub: "\(ShopAnalyticsFormat.percent(r.chat.completionRate)) of \(ShopAnalyticsFormat.count(r.chat.chats)) chats",
                            systemImage: "sparkles",
                            hint: "The AI replied and the chat led to saved contact details, a quote, an add-to-cart or an order")
            }
            .opacity(loading ? 0.6 : 1)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        Section {
            Picker("Show", selection: $metric) {
                ForEach(ShopTrendMetric.allCases) { Text($0.label).tag($0) }
            }
            .accessibilityIdentifier("analytics.metric")
            ShopTrendChart(series: r.series, bucket: r.window.bucket, metric: metric)
        } header: {
            Text("Trend")
        } footer: {
            let total = r.series.reduce(0) { $0 + $1.value(metric) }
            Text("\(metric.isMoney ? ShopAnalyticsFormat.money(total, currency: cur) : ShopAnalyticsFormat.count(total)) "
                 + "\(metric.label.lowercased()) · per \(r.window.bucket.rawValue)\(metric == .revenue ? " · inc VAT" : "")")
        }

        Section {
            ShopFunnelView(steps: [
                .init(label: "Carts with items", value: r.carts.withItems),
                .init(label: "Reached checkout", value: r.carts.reachedCheckout),
                .init(label: "Paid", value: r.carts.converted),
            ])
            ShopStatGrid(stats: [
                ShopStatCell(label: "Cart conversion", value: ShopAnalyticsFormat.percent(r.carts.conversionRate),
                             hint: "Paid carts ÷ carts with items"),
                ShopStatCell(label: "Abandonment", value: ShopAnalyticsFormat.percent(r.carts.abandonmentRate),
                             hint: "Abandoned ÷ (abandoned + paid); carts still open are left out"),
                ShopStatCell(label: "Still open", value: ShopAnalyticsFormat.count(r.carts.open),
                             hint: "Touched in the last \(r.carts.abandonAfterHours) hours"),
                ShopStatCell(label: "Failed payments", value: ShopAnalyticsFormat.count(r.checkout.paymentFailed)),
            ])
        } header: {
            Text("Cart to order")
        } footer: {
            Text("Carts created in the period. \(ShopAnalyticsFormat.count(r.checkout.fromQuote)) checkout"
                 + "\(r.checkout.fromQuote == 1 ? "" : "s") started from a quote rather than a cart.")
        }

        Section("Sales breakdown") {
            ShopBreakdownRow(label: "Revenue (inc VAT)", value: ShopAnalyticsFormat.money(r.sales.revenueMinor, currency: cur))
            ShopBreakdownRow(label: "VAT", value: ShopAnalyticsFormat.money(r.sales.vatMinor, currency: cur), muted: true)
            ShopBreakdownRow(label: "Shipping", value: ShopAnalyticsFormat.money(r.sales.shippingMinor, currency: cur), muted: true)
            ShopBreakdownRow(label: "Revenue ex VAT", value: ShopAnalyticsFormat.money(r.sales.revenueExVatMinor, currency: cur))
            ShopBreakdownRow(label: "Refunds", value: "−\(ShopAnalyticsFormat.money(r.sales.refundsMinor, currency: cur))")
            ShopBreakdownRow(label: "Net revenue", value: ShopAnalyticsFormat.money(r.sales.netRevenueMinor, currency: cur), strong: true)
            if r.sales.tradeDiscountMinor > 0 || r.sales.creditUsedMinor > 0 {
                ShopBreakdownRow(label: "Trade discount given",
                                 value: ShopAnalyticsFormat.money(r.sales.tradeDiscountMinor, currency: cur), muted: true)
                ShopBreakdownRow(label: "Credit used", value: ShopAnalyticsFormat.money(r.sales.creditUsedMinor, currency: cur), muted: true)
            }
            if let trade = r.trade {
                ShopStatGrid(stats: [
                    ShopStatCell(label: "Trade joins", value: ShopAnalyticsFormat.count(trade.joins)),
                    ShopStatCell(label: "Cancelled", value: ShopAnalyticsFormat.count(trade.cancellations)),
                    ShopStatCell(label: "Active now", value: ShopAnalyticsFormat.count(trade.activeNow)),
                ])
            }
        }

        Section {
            ShopFunnelView(steps: [
                .init(label: "Chats", value: r.chat.chats, note: "Sessions where the visitor typed at least one message"),
                .init(label: "AI replied", value: r.chat.aiReplied),
                .init(label: "Completed", value: r.chat.completed,
                      note: "Led to saved contact details, a quote, an add-to-cart or an order"),
            ])
            ShopStatGrid(stats: [
                ShopStatCell(label: "Contact saved", value: ShopAnalyticsFormat.count(r.chat.contactSaved)),
                ShopStatCell(label: "Quotes", value: ShopAnalyticsFormat.count(r.chat.quotes)),
                ShopStatCell(label: "Added to cart", value: ShopAnalyticsFormat.count(r.chat.addedToCart)),
                ShopStatCell(label: "Orders", value: ShopAnalyticsFormat.count(r.chat.orders)),
                ShopStatCell(label: "Chat revenue", value: ShopAnalyticsFormat.pounds(r.chat.revenueMinor),
                             hint: "Paid orders on carts the chat was attached to"),
                ShopStatCell(label: "No reply", value: ShopAnalyticsFormat.count(r.chat.noReply),
                             hint: "The AI returned nothing (timeout or provider error)"),
            ])
        } header: {
            Text("AI advisor")
        } footer: {
            Text((r.chat.avgUserMessages.map { String(format: "%.1f visitor messages per chat · ", $0) } ?? "")
                 + "\(ShopAnalyticsFormat.count(r.chat.memberChats)) from signed-in Trade members")
        }

        Section("What the AI did") {
            ShopBarList(rows: r.chatTools.prefix(8).map { .init(id: $0.name, label: $0.label, value: $0.chats, extra: "chats") },
                        empty: "No tools used in this period")
        }
        if !r.chatCountries.isEmpty {
            Section("Chats by country") {
                ShopBarList(rows: r.chatCountries.prefix(5).map { .init(id: $0.id, label: $0.name, value: $0.chats) }, empty: "")
            }
        }

        Section {
            if r.topProducts.isEmpty {
                Text("No paid orders in this period").font(.wsSubheadline).foregroundStyle(.secondary)
            }
            ForEach(r.topProducts) { product in
                ShopTopProductRow(product: product, totalExVat: r.sales.revenueExVatMinor, currency: cur)
            }
        } header: {
            Text("Top products")
        } footer: {
            Text("Fully refunded orders are left out.")
        }

        Section {
            ShopBarList(rows: r.basketAdds.prefix(6).map {
                .init(id: $0.productUuid, label: $0.name, value: $0.adds,
                      extra: "\(ShopAnalyticsFormat.count($0.carts)) \($0.carts == 1 ? "cart" : "carts")")
            }, empty: "Nothing added to a basket")
        } header: {
            Text("Most added to basket")
        } footer: {
            if !r.basketAddsComplete {
                Text("Basket adds are kept for 30 days, so this covers only the last 30 days of the period.")
            }
        }

        Section("Quotes") {
            ShopBreakdownRow(label: "From the cart", value: ShopAnalyticsFormat.count(r.quotes.bySource.cart))
            ShopBreakdownRow(label: "From the AI advisor", value: ShopAnalyticsFormat.count(r.quotes.bySource.chat))
            ShopBreakdownRow(label: "Raised by staff", value: ShopAnalyticsFormat.count(r.quotes.bySource.admin))
            ShopBreakdownRow(label: "Quoted value (inc VAT)", value: ShopAnalyticsFormat.money(r.quotes.valueMinor, currency: cur),
                             strong: true)
            ShopBreakdownRow(label: "Won", value: "\(ShopAnalyticsFormat.count(r.quotes.converted)) · "
                             + ShopAnalyticsFormat.money(r.quotes.convertedValueMinor, currency: cur))
            ShopBreakdownRow(label: "Viewed by the customer", value: ShopAnalyticsFormat.count(r.quotes.viewed), muted: true)
            ShopBreakdownRow(label: "Expired", value: ShopAnalyticsFormat.count(r.quotes.expired), muted: true)
        }

        ShopSurveySections(state: survey) { Task { await loadSurvey() } }

        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Visitor analytics are off").font(.wsHeadline)
                    Text("Unique and returning visitors, page views, traffic sources and devices need a privacy and cookie "
                         + "decision first. Until it is signed off, the shop collects no visitor data and sets no analytics cookies.")
                        .font(.wsSubheadline).foregroundStyle(.secondary)
                    Text("Everything on this page comes from orders, carts, quotes and chats the shop already keeps.")
                        .font(.wsCaption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "eye.slash")
            }
        }

        Section {
            DisclosureGroup("How these are measured") {
                ForEach(definitions(r), id: \.0) { term, text in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(term).font(.wsSubheadline.weight(.semibold))
                        Text(text).font(.wsSubheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("analytics.definitions")
        } footer: {
            Text("Generated \(generatedText(r.generatedAt)) UK time")
        }
    }

    private func definitions(_ r: ShopAnalyticsReport) -> [(String, String)] {
        [
            ("Period", "UK calendar days (\(r.window.timezone)), \(ShopAnalyticsFormat.longDate(r.window.from)) to "
             + "\(ShopAnalyticsFormat.longDate(r.window.to)) inclusive, compared with the \(r.window.days) days before."),
            ("Revenue", "Order totals inc VAT and shipping, for orders paid in the period (by payment date), including orders refunded later."),
            ("Net revenue", "Revenue minus money refunded on those orders."),
            ("Customers", "Distinct buyer emails. New means their first paid order falls in the period."),
            ("Checkout", "A checkout creates an order. Repeat attempts on the same cart or quote count once."),
            ("Abandoned cart", "Has items, was never paid for, and has not been touched for \(r.carts.abandonAfterHours) hours."),
            ("Completed chat", "The AI replied and the chat led to saved contact details, a quote, an add-to-cart or an order."),
            ("Chat revenue", "Paid orders placed on a cart the chat was attached to."),
        ]
    }

    private func generatedText(_ raw: String) -> String {
        guard let date = APIDate.parse(raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: Export

    private var exportMenu: some View {
        Menu {
            ForEach(ShopAnalyticsExport.allCases) { report in
                Button(report.label) { Task { await export(report) } }
            }
        } label: {
            if exporting != nil { ProgressView() } else { Label("Export CSV", systemImage: "square.and.arrow.up") }
        }
        .disabled(state.value == nil || exporting != nil)
        .accessibilityIdentifier("analytics.export")
    }

    private func export(_ report: ShopAnalyticsExport) async {
        exporting = report
        defer { exporting = nil }
        do {
            let url = try await services.shop.analyticsExport(report, query: query)
            exported = ShopExportedFile(url: url, title: report.label)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            exportError = apiError
        }
    }

    // MARK: Loading

    private func load() async {
        loading = true
        defer { loading = false }
        async let surveyTask: Void = loadSurvey()
        do {
            let report = try await services.shop.analytics(query)
            state = .loaded(report)
            refreshError = nil
            // Keep the custom pickers on the window the server actually used.
            if let from = CalendarDay(string: report.window.from) { customFrom = from.date() }
            if let to = CalendarDay(string: report.window.to) { customTo = to.date() }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { _ = await surveyTask; return }
            if state.value == nil { state = .failed(apiError) } else { refreshError = apiError }
        }
        _ = await surveyTask
    }

    private func loadSurvey() async {
        if survey.value == nil { survey = .loading }
        do {
            survey = .loaded(try await services.shop.analyticsSurvey(query))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            survey = .failed(apiError)
        }
    }
}

/// One top product: units, orders, revenue ex VAT and its share of the period's revenue.
private struct ShopTopProductRow: View {
    let product: ShopAnalyticsTopProduct
    let totalExVat: Int
    let currency: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.name ?? "Unknown product").font(.wsSubheadline.weight(.medium)).lineLimit(2)
                Text([product.sku, "\(ShopAnalyticsFormat.count(product.units)) units", "\(ShopAnalyticsFormat.count(product.orders)) orders"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsCaption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ShopAnalyticsFormat.money(product.revenueExVatMinor, currency: currency))
                    .font(.wsSubheadline.weight(.semibold).monospacedDigit())
                if totalExVat > 0 {
                    Text(ShopAnalyticsFormat.percent(Double(product.revenueExVatMinor) / Double(totalExVat), places: 0))
                        .font(.wsCaption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A file the app saved, ready to share (CSV exports).
struct ShopExportedFile: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: URL { url }
}

/// "Your CSV is ready": share it to Files, Mail, Numbers… or close.
struct ShopExportSheet: View {
    let file: ShopExportedFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "tablecells").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                Text("\(file.title) is ready").font(.wsTitle3)
                Text(file.url.lastPathComponent).font(.wsFootnote.monospaced()).foregroundStyle(.secondary)
                Text("Save it to Files, or send it to Numbers, Excel or an email.")
                    .font(.wsSubheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink(item: file.url) {
                    Label("Share or save the CSV", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.large())
                .accessibilityIdentifier("analytics.shareCSV")
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
