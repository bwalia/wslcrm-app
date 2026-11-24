import SwiftUI

/// VIP (Trade) members (dashboard /dashboard/shop/members): the headline numbers, every member with their fee and
/// status, a member's details and their CRM lead, and recording a fee paid by invoice (RBAC `shop`).
/// Rows are the `shop.members` descriptor's records (GET /membership/members).
struct ShopMembersView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[Record]> = .idle
    @State private var search = ""
    @State private var status = ""
    @State private var recordingInvoice = false
    @State private var notice: String?
    @State private var actionError: APIError?

    private var descriptor: ResourceDescriptor { ModuleCatalog.shopMembers }
    private var invoiceAction: ActionSpec? { descriptor.listActions.first { $0.id == "invoiced" } }

    var body: some View {
        List {
            if let rows = state.value {
                let stats = ShopMemberStats(rows)
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        StatTile(title: "VIP members", value: "\(stats.live) · \(stats.founding) founding", systemImage: "crown")
                        StatTile(title: "New this week", value: "\(stats.newThisWeek)", systemImage: "sparkles")
                        StatTile(title: "Fees a month (ex VAT)", value: ShopMoney.format(stats.monthlyNetMinor) ?? "—",
                                 systemImage: "sterlingsign.circle")
                        StatTile(title: "Payment overdue", value: "\(stats.overdue)", systemImage: "exclamationmark.triangle")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if let notice {
                    Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
                }
                if let actionError {
                    Section { InlineErrorRow(error: actionError) }
                }
                Section {
                    if rows.isEmpty {
                        ContentUnavailableView(status.isEmpty && search.isEmpty ? "No VIP members yet" : "No members match",
                                               systemImage: "crown",
                                               description: Text("Customers who pay for Trade (VIP) membership appear here. "
                                                                 + "Their Trade discount applies to basket orders automatically."))
                    }
                    ForEach(rows) { record in
                        NavigationLink { ShopMemberDetailView(record: record) } label: { ShopMemberRow(record: record) }
                    }
                } footer: {
                    Text("Customers who pay for Trade (VIP) membership. Their Trade discount applies to basket orders automatically.")
                }
            } else if let error = state.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .searchable(text: $search, prompt: "Email, name or company")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: search) { _, value in if value.isEmpty { Task { await load() } } }
        .navigationTitle("VIP members")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: $status) {
                        Text("All statuses").tag("")
                        Text("Active").tag("active")
                        Text("Payment overdue").tag("past_due")
                        Text("Cancelled").tag("canceled")
                        Text("Expired").tag("expired")
                    }
                } label: {
                    Label("Status", systemImage: status.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityIdentifier("shop.members.status")
            }
            if let invoiceAction, session.permissions.allows(invoiceAction.action, invoiceAction.module ?? descriptor.permissions.module) {
                ToolbarItem(placement: .primaryAction) {
                    Button { recordingInvoice = true } label: { Label(invoiceAction.title, systemImage: invoiceAction.systemImage) }
                        .accessibilityIdentifier("shop.members.invoiced")
                }
            }
        }
        .task(id: status) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $recordingInvoice) {
            if let invoiceAction {
                NavigationStack {
                    ActionInputForm(action: invoiceAction) { inputs in
                        do {
                            _ = try await services.resources.run(invoiceAction, on: Record([:]), inputs: inputs)
                            notice = invoiceAction.done
                            actionError = nil
                            await load()
                            return true
                        } catch {
                            actionError = error.asAPIError
                            return false
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let query = status.isEmpty ? [:] : ["status": status]
            let page = try await services.resources.page(descriptor, search: search, page: 1, query: query)
            state = .loaded(page.items)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { actionError = apiError }
        }
    }
}

/// The dashboard's member figures: members in force (active or payment overdue).
struct ShopMemberStats: Equatable {
    var live = 0
    var founding = 0
    var newThisWeek = 0
    /// Yearly fees spread per month, ex VAT.
    var monthlyNetMinor = 0
    var overdue = 0

    init(_ rows: [Record], now: Date = .now) {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        for row in rows where ShopMemberStats.inForce(row) {
            live += 1
            if row.string("tier") == "founding" { founding += 1 }
            if let joined = row.date("joined_at"), joined >= weekAgo { newThisWeek += 1 }
            let net = row.int("net_minor") ?? 0
            monthlyNetMinor += row.string("billing_interval") == "year" ? Int((Double(net) / 12).rounded()) : net
            if row.string("status") == "past_due" { overdue += 1 }
        }
    }

    static func inForce(_ row: Record) -> Bool { ["active", "past_due"].contains(row.string("status") ?? "") }

    /// Joined in the last `days` days.
    static func isNew(_ row: Record, days: Int = 14, now: Date = .now) -> Bool {
        guard let joined = row.date("joined_at") else { return false }
        return joined >= now.addingTimeInterval(-Double(days) * 86_400)
    }
}

struct ShopMemberRow: View {
    let record: Record
    var highlightNew = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.string("name") ?? record.string("email") ?? "Member").font(.wsHeadline).lineLimit(1)
                    if highlightNew, ShopMemberStats.isNew(record) {
                        StatusBadge(text: "New", systemImage: "sparkles", tone: .warning)
                    }
                }
                Text([record.string("company"), record.string("name") == nil ? nil : record.string("email"), record.string("phone")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
                Text([record.string("billing_interval") == "year" ? "Yearly" : "Monthly",
                      record.string("tier") == "founding" ? "Founding" : "Standard",
                      Formatters.day(record.date("joined_at")).map { "joined \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.wsCaption).foregroundStyle(.secondaryText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let status = record.string("status") {
                    StatusBadge(text: ModuleCatalog.memberStatus.label(for: status), systemImage: ModuleCatalog.memberStatus.symbol(for: status),
                                tone: ModuleCatalog.memberStatus.tone(for: status))
                }
                Text("\(ShopMoney.format(record.int("net_minor")) ?? "—") + VAT").font(.wsCaption.monospacedDigit())
                if record.bool("cancel_at_period_end") == true, ShopMemberStats.inForce(record) {
                    Text("Cancels at period end").font(.wsCaption2).foregroundStyle(Tone.warning.textColor)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One member: who they are, their membership and fees, and their CRM lead.
struct ShopMemberDetailView: View {
    let record: Record
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            ForEach(ModuleCatalog.shopMembers.detail) { section in
                Section(section.title ?? "") {
                    ForEach(section.fields.filter { FieldFormatter.text(record, $0) != nil }) { field in
                        FieldValueRow(field: field, record: record)
                    }
                }
            }
            Section("Paid") {
                ForEach(Self.payment.filter { FieldFormatter.text(record, $0) != nil }) { field in
                    FieldValueRow(field: field, record: record)
                }
                if record.bool("cancel_at_period_end") == true {
                    Label("Cancels at the end of the period", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(Tone.warning.textColor)
                }
            }
            if let lead = record.string("lead_uuid"), session.shopPolicy.canOpenLeads {
                Section {
                    NavigationLink { LeadDetailView(leadUuid: lead) } label: {
                        Label("Open their lead", systemImage: "person.crop.circle.badge.plus")
                    }
                    .accessibilityIdentifier("shop.member.lead")
                } footer: {
                    Text("Name, company and phone come from the customer’s CRM lead.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.string("name") ?? record.string("email") ?? "Member")
        .navigationBarTitleDisplayMode(.inline)
    }

    static let payment: [FieldSpec] = [
        FieldSpec("paid_by", "Paid by", .choice([Choice("card", "Card"), Choice("invoice", "Invoice")])),
        FieldSpec("invoice_ref", "Invoice number"),
        FieldSpec("offer_version", "Offer"),
    ]
}

/// The shop home's card: the newest VIP members, anyone who joined in the last two weeks called out.
/// The home screen loads the rows (members in force) so no `.task` sits on a Section inside its List.
struct ShopVipMembersSection: View {
    let rows: [Record]

    var body: some View {
        if !rows.isEmpty {
            let fresh = rows.filter { ShopMemberStats.isNew($0) }
            Section {
                if !fresh.isEmpty {
                    Label("\(fresh.count == 1 ? "1 new VIP" : "\(fresh.count) new VIPs") in the last 14 days. Give them a call.",
                          systemImage: "crown.fill")
                        .font(.wsSubheadline.weight(.medium))
                        .foregroundStyle(Tone.warning.textColor)
                }
                ForEach(rows.prefix(5)) { record in
                    NavigationLink { ShopMemberDetailView(record: record) } label: { ShopMemberRow(record: record, highlightNew: true) }
                }
                NavigationLink { ShopMembersView() } label: { Text("All \(rows.count) members") }
                    .accessibilityIdentifier("shop.home.allMembers")
            } header: {
                Text("VIP members (\(rows.count))")
            }
        }
    }
}
