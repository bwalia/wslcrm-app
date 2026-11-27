import SwiftUI

// What a customer has bought from the workspace's apps (Billing & Entitlements): subscriptions, one-off
// purchases, access granted by hand and licence keys, each filtered with `?customer=<uuid>`
// (routes/billing-subscriptions.lua, RBAC subscriptions.read; routes/billing-licenses.lua, licenses.read).
// Selling, upgrading, granting and licences are done in Billing, opened from here.

struct CustomerBilling: Equatable, Sendable {
    var subscriptions: [Record] = []
    var purchases: [Record] = []
    var grants: [Record] = []
    var licences: [Record] = []
    var canSeeSales = false
    var canSeeLicences = false

    var isEmpty: Bool { subscriptions.isEmpty && purchases.isEmpty && grants.isEmpty && licences.isEmpty }

    /// The lists the person may read, for one customer. Quietly empty on any error (an older server, no apps).
    @MainActor
    static func load(services: Services, session: SessionStore, customerUuid: String) async -> CustomerBilling {
        var out = CustomerBilling()
        out.canSeeSales = session.permissions.can(.read, moduleName: "subscriptions")
        out.canSeeLicences = session.permissions.can(.read, moduleName: "licenses")
        let billing = services.billing
        let query: [String: String?] = ["customer": customerUuid]
        func rows(_ path: String) async -> [Record] {
            (try? await billing.page(path, query: query, page: 1, perPage: 50).items) ?? []
        }
        if out.canSeeSales {
            out.subscriptions = await rows("/api/v2/subscriptions")
            out.purchases = await rows("/api/v2/subscriptions/purchases")
            out.grants = await rows("/api/v2/subscriptions/grants").filter { $0.string("revoked_at") == nil }
        }
        if out.canSeeLicences { out.licences = await rows("/api/v2/licenses") }
        return out
    }

    /// "Acme CRM · Pro".
    static func product(_ row: Record) -> String {
        [row.string("app_name"), row.string("plan_name")].compactMap { $0?.trimmedOrNil }.joined(separator: " · ")
            .trimmedOrNil ?? "App"
    }
}

/// Loaded by the customer page (a section that shows nothing can't load itself).
struct CustomerBillingSection: View {
    let billing: CustomerBilling

    var body: some View {
        if billing.canSeeSales || billing.canSeeLicences {
            DetailSection {
                if billing.isEmpty {
                    Text("No subscriptions, purchases, access or licences for this customer yet.")
                        .font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                ForEach(billing.subscriptions) { row in
                    line(CustomerBilling.product(row), "Subscription",
                         [Formatters.humanize(row.string("status")),
                          row.date("current_period_end").flatMap { Formatters.day($0) }.map { "renews \($0)" }])
                }
                ForEach(billing.purchases) { row in
                    line(CustomerBilling.product(row), "Bought",
                         [row.decimal("amount").flatMap { Formatters.money($0, currency: row.string("currency") ?? Formatters.defaultCurrency) },
                          Formatters.humanize(row.string("status")),
                          row.date("access_until").flatMap { Formatters.day($0) }.map { "until \($0)" }])
                }
                ForEach(billing.grants) { row in
                    line(CustomerBilling.product(row), "Given access",
                         [row.string("reason"), row.date("expires_at").flatMap { Formatters.day($0) }.map { "until \($0)" }])
                }
                ForEach(billing.licences) { row in
                    line(CustomerBilling.product(row), "Licence",
                         ["\(row.string("key_prefix") ?? "")-•••••", Formatters.humanize(row.string("status"))])
                }
                if billing.canSeeSales {
                    NavigationLink { BillingSubscriptionsView() } label: {
                        Label("Sell, upgrade or give access", systemImage: "creditcard")
                    }
                }
                if billing.canSeeLicences {
                    NavigationLink { BillingLicencesView() } label: {
                        Label("Licence keys", systemImage: "key")
                    }
                }
            } header: {
                DetailSectionTitle("Apps and licences", systemImage: "app.badge")
            } footer: {
                Text("Choose this customer there to sell a plan, move them to another plan, give access or issue a licence.")
            }
        }
    }

    private func line(_ title: String, _ kind: String, _ parts: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.wsHeadline)
            Text(([kind] + parts.compactMap { $0?.trimmedOrNil }).joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}
