import SwiftUI

// MARK: - Activities on a record

/// The activities of one account, contact or deal: the latest few, add one, tick one off, open them all.
/// Rows open the module kit's activity screen (edit, cancel, delete).
struct CRMActivitiesSection: View {
    let relation: CRMRelation
    /// Bumped by the parent when it reloads, so the section refreshes with it.
    var reload: Int = 0
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var rows: [Record] = []
    @State private var total = 0
    @State private var error: APIError?
    @State private var adding = false
    @State private var notice: String?

    private var descriptor: ResourceDescriptor { ModuleCatalog.crmActivities }
    private var canRead: Bool { session.permissions.can(.read, moduleName: "crm_activities") }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: "crm_activities") }
    private var canUpdate: Bool { session.permissions.can(.update, moduleName: "crm_activities") }

    var body: some View {
        if canRead {
            Section {
                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                }
                if let error { InlineErrorRow(error: error) { Task { await load() } } }
                ForEach(rows) { record in
                    NavigationLink(value: ResourceRoute(descriptorID: descriptor.id, recordID: record.id, seed: record)) {
                        RecordRow(record: record, list: descriptor.list)
                    }
                    .swipeActions {
                        if canUpdate, ["pending", "planned"].contains(record.string("status") ?? "") {
                            Button("Done") { Task { await complete(record) } }.tint(.green)
                        }
                    }
                    .accessibilityIdentifier("crm.activity.\(record.id)")
                }
                if rows.isEmpty, error == nil {
                    Text("No calls, emails, meetings or notes yet.").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
                if total > rows.count {
                    NavigationLink(value: ResourceListRoute(descriptor.id, query: relation.query, title: "Activities")) {
                        Label("All \(total) activities", systemImage: "list.bullet")
                    }
                }
                if canCreate {
                    Button("Add an activity", systemImage: "plus.circle") { adding = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("crm.activity.add")
                        .sheet(isPresented: $adding) {
                            CRMActivityQuickForm(relation: relation) { body in
                                try await services.crm.createActivity(body)
                                notice = "“\(body.subject)” added."
                                await load()
                            }
                        }
                }
            } header: {
                Text("Activities").task(id: reload) { await load() }
            }
        }
    }

    private func load() async {
        do {
            let page = try await services.resources.page(descriptor, search: "", page: 1, query: relation.query)
            rows = Array(page.items.prefix(10))
            total = page.total
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func complete(_ record: Record) async {
        do {
            try await services.crm.completeActivity(record.id)
            notice = "“\(record.string("subject") ?? "Activity")” marked as done."
            await load()
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A new call, email, meeting, note or task for one record (`related_type` + `related_uuid`).
struct CRMActivityQuickForm: View {
    let relation: CRMRelation
    let save: (CRMActivityBody) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var type = "call"
    @State private var subject = ""
    @State private var hasDate = true
    @State private var date = Date()
    @State private var minutes = ""
    @State private var description = ""
    @State private var saving = false
    @State private var error: APIError?

    static func body(type: String, subject: String, date: Date?, minutes: String, description: String,
                     relation: CRMRelation) -> CRMActivityBody {
        CRMActivityBody(subject: subject.trimmingCharacters(in: .whitespaces), type: type,
                        description: description.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                        dueDate: date, durationMinutes: Int(minutes.trimmingCharacters(in: .whitespaces)),
                        relatedType: relation.relatedType, relatedUuid: relation.uuid)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $type) {
                        ForEach(ModuleCatalog.activityTypes) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Subject (needed)", text: $subject).accessibilityIdentifier("crm.activityForm.subject")
                    Toggle("Has a date", isOn: $hasDate)
                    if hasDate {
                        DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    }
                    TextField("Minutes (optional)", text: $minutes).keyboardType(.numberPad)
                }
                Section("Notes") {
                    TextField("What happened or needs doing", text: $description, axis: .vertical).lineLimit(3...8)
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("New activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        error = nil
                        let body = Self.body(type: type, subject: subject, date: hasDate ? date : nil, minutes: minutes,
                                             description: description, relation: relation)
                        Task {
                            defer { saving = false }
                            do {
                                try await save(body)
                                dismiss()
                            } catch {
                                self.error = error.asAPIError
                            }
                        }
                    }
                    .disabled(subject.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                    .accessibilityIdentifier("crm.activityForm.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

// MARK: - Referrals

/// One referral and what can happen next: the partner accepted or declined, won or lost it, then the
/// commission is invoiced. Each answer changes it on the server (`/api/v2/crm/referrals/:uuid/...`).
struct ReferralRow: View {
    let referral: Referral
    let canWork: Bool
    /// Told what happened, then the parent reloads.
    let onChange: (String) async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var askingWonValue = false
    @State private var wonValue = ""
    @State private var askingTax = false
    @State private var taxRate = "20"
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(referral.partnerName).font(.wsHeadline)
                Spacer()
                StatusBadge(text: referral.statusLabel,
                            systemImage: ModuleCatalog.referralStatus.symbol(for: referral.status),
                            tone: ModuleCatalog.referralStatus.tone(for: referral.status))
            }
            if let line = summary.nonEmpty {
                Text(line).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            if let notes = referral.partnerNotes { Text("They said: \(notes)").font(.wsSubheadline) }
            if let error { InlineErrorRow(error: error) }
            if canWork { actions }
            if let invoice = referral.invoiceUuid, session.permissions.can(.read, .invoices) {
                NavigationLink { InvoiceDetailView(invoiceUuid: invoice) } label: {
                    Label("Open the commission invoice\(referral.invoiceNumber.map { " \($0)" } ?? "")", systemImage: "doc.text")
                }
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
        .disabled(busy)
        .alert("\(referral.partnerName) won it", isPresented: $askingWonValue) {
            TextField("Final deal value", text: $wonValue).keyboardType(.decimalPad)
            Button("Save") { Task { await move("won", value: Decimal(string: wonValue.replacingOccurrences(of: ",", with: ""))) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The final value works out your commission.")
        }
        .alert("Invoice \(referral.partnerName) for the commission", isPresented: $askingTax) {
            TextField("VAT rate %", text: $taxRate).keyboardType(.decimalPad)
            Button("Create invoice") { Task { await invoice() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A draft invoice is made for the commission. Use 0 if you don't charge VAT.")
        }
        .accessibilityIdentifier("referral.\(referral.uuid)")
    }

    private var summary: String {
        [referral.dealName,
         referral.commissionAmount.flatMap { Formatters.money($0, currency: referral.money) }.map { "commission \($0)" },
         referral.invoiceNumber.map { "invoice \($0)" },
         Formatters.day(referral.sentAt ?? referral.createdAt).map { "sent \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        switch referral.status {
        case "sent":
            HStack {
                Button("They accepted") { Task { await move("accepted") } }
                Button("They declined") { Task { await move("declined") } }
                Spacer()
                Button("Send again") { Task { await resend() } }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        case "accepted":
            HStack {
                Button("They won it") {
                    wonValue = referral.dealValue.map { "\($0)" } ?? ""
                    askingWonValue = true
                }
                Spacer()
                Button("They lost it") { Task { await move("lost") } }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        case "won" where referral.invoiceUuid == nil:
            Button("Invoice the commission", systemImage: "doc.badge.plus") { askingTax = true }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        default:
            EmptyView()
        }
    }

    private func move(_ status: String, value: Decimal? = nil) async {
        busy = true
        defer { busy = false }
        do {
            let updated = try await services.crm.moveReferral(referral.uuid, ReferralStatusBody(status: status, dealValue: value))
            error = nil
            await onChange("\(updated.partnerName): \(updated.statusLabel.lowercased()).")
        } catch {
            self.error = error.asAPIError
        }
    }

    private func resend() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await services.crm.resendReferral(referral.uuid)
            error = nil
            await onChange("Sent to \(referral.partnerName) again.")
        } catch {
            self.error = error.asAPIError
        }
    }

    private func invoice() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await services.crm.invoiceReferral(referral.uuid,
                                                        taxRate: Decimal(string: taxRate.replacingOccurrences(of: ",", with: ".")) ?? 0)
            error = nil
            await onChange("Commission invoice created as a draft. Open it below to send it.")
        } catch {
            self.error = error.asAPIError
        }
    }
}

/// A partner the AI thinks could fulfil a lead (from the analysis).
struct PartnerSuggestion: Hashable, Sendable {
    let partnerUuid: String
    let partnerName: String
    let fit: Int?
    let reason: String?
}

/// "Pass to a partner": pick the partner (AI suggestions first), the value and the commission, a message,
/// and whether the customer's details may be shared (only with their consent).
struct ReferSheet: View {
    enum Subject: Hashable { case lead(String), deal(String) }

    let subject: Subject
    let dealValue: Decimal?
    let currency: String?
    let suggestions: [PartnerSuggestion]
    var preselect: String?
    let onDone: (Referral) async -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var partners: LoadState<[Partner]> = .idle
    @State private var addingPartner = false
    @State private var partnerUuid: String?
    @State private var value: String
    @State private var kind = "percent"
    @State private var rate = ""
    @State private var message = ""
    @State private var share = false
    @State private var consent = false
    @State private var saving = false
    @State private var error: APIError?

    init(subject: Subject, dealValue: Decimal?, currency: String?, suggestions: [PartnerSuggestion],
         preselect: String? = nil, onDone: @escaping (Referral) async -> Void) {
        self.subject = subject
        self.dealValue = dealValue
        self.currency = currency
        self.suggestions = suggestions
        self.preselect = preselect
        self.onDone = onDone
        _value = State(initialValue: dealValue.map { "\($0)" } ?? "")
    }

    /// What the referral earns: a percentage of the value, or a fixed fee.
    static func commission(kind: String, rate: Decimal?, value: Decimal?) -> Decimal {
        guard let rate else { return 0 }
        if kind == "fixed" { return rate }
        return (value ?? 0) * rate / 100
    }

    static func body(subject: Subject, partnerUuid: String, value: String, kind: String, rate: String, message: String,
                     share: Bool, consent: Bool, aiReason: String?) -> ReferBody {
        var leadUuid: String?
        var dealUuid: String?
        switch subject {
        case .lead(let uuid): leadUuid = uuid
        case .deal(let uuid): dealUuid = uuid
        }
        return ReferBody(leadUuid: leadUuid, dealUuid: dealUuid, partnerUuid: partnerUuid,
                         dealValue: Decimal(string: value.replacingOccurrences(of: ",", with: "")),
                         commissionType: kind, commissionValue: Decimal(string: rate.replacingOccurrences(of: ",", with: "")),
                         message: message.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty, shareContact: share,
                         consentConfirmed: share ? consent : nil, aiReason: aiReason)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch partners {
                case .idle, .loading:
                    Section { SkeletonRow() }
                case _ where !session.permissions.can(.read, .crmAccounts):
                    Section {
                        ContentUnavailableView("You can't see partners", systemImage: "lock",
                                               description: Text("Partners are kept with your accounts. Ask a workspace admin "
                                                                 + "to let you see accounts, then pass work on from here."))
                    }
                case .failed(let error):
                    Section { InlineErrorRow(error: error) { Task { await load() } } }
                case .loaded(let list) where list.isEmpty:
                    Section {
                        ContentUnavailableView("No partners yet", systemImage: "person.2",
                                               description: Text(session.permissions.can(.create, .crmAccounts)
                                                                 ? "Add a company you pass work to. You can then send them this one."
                                                                 : "Ask a workspace admin to add the companies you pass work to."))
                        if session.permissions.can(.create, .crmAccounts) {
                            Button { addingPartner = true } label: { Label("Add a partner", systemImage: "plus.circle.fill") }
                                .buttonStyle(.large(.brand))
                                .accessibilityIdentifier("refer.addPartner")
                        }
                    }
                case .loaded(let list):
                    Section("Partner") {
                        ForEach(ordered(list)) { partner in
                            Button { choose(partner) } label: {
                                HStack(alignment: .top) {
                                    Image(systemName: partnerUuid == partner.uuid ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(partnerUuid == partner.uuid ? Color.accentColor : .secondaryText)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(partner.name).font(.wsHeadline).foregroundStyle(.primary)
                                            if let fit = suggestion(partner)?.fit {
                                                StatusBadge(text: "AI fit \(fit)", systemImage: "sparkles", tone: .brand)
                                            }
                                        }
                                        Text(partner.offering ?? partner.categories.joined(separator: ", ").nonEmpty ?? "No description")
                                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                                        if let reason = suggestion(partner)?.reason {
                                            Text(reason).font(.wsCaption).foregroundStyle(.secondaryText)
                                        }
                                    }
                                }
                            }
                            .accessibilityAddTraits(partnerUuid == partner.uuid ? .isSelected : [])
                            .accessibilityIdentifier("refer.partner.\(partner.uuid)")
                        }
                    }
                    Section {
                        TextField("Deal value", text: $value).keyboardType(.decimalPad)
                        Picker("Commission", selection: $kind) {
                            Text("% of the deal").tag("percent")
                            Text("Fixed fee").tag("fixed")
                        }
                        TextField(kind == "percent" ? "Percent" : "Amount", text: $rate).keyboardType(.decimalPad)
                    } footer: {
                        Text("Your commission: \(Formatters.money(commission, currency: currency ?? "GBP") ?? "")")
                    }
                    Section("Message to the partner (optional)") {
                        TextField("What they should know", text: $message, axis: .vertical).lineLimit(2...6)
                    }
                    Section {
                        Toggle("Share the customer's name and contact details", isOn: $share)
                        if share {
                            Toggle("The customer agreed to us sharing their details with this partner", isOn: $consent)
                        }
                    } footer: {
                        Text(share ? "Only share with the customer's agreement."
                             : "The partner sees what is wanted and its size, not who it's for. You introduce them once they accept.")
                    }
                }
                if let error { Section { InlineErrorRow(error: error) } }
            }
            .navigationTitle("Pass to a partner")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(isPresented: $addingPartner) {
                NavigationStack {
                    ResourceFormView(descriptor: ModuleCatalog.crmPartners, existing: nil) { saved in
                        Task { await load(select: saved?.string("uuid")) }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(partnerUuid == nil || (share && !consent) || saving)
                        .accessibilityIdentifier("refer.send")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var commission: Decimal {
        Self.commission(kind: kind, rate: Decimal(string: rate.replacingOccurrences(of: ",", with: "")),
                        value: Decimal(string: value.replacingOccurrences(of: ",", with: "")))
    }

    private func suggestion(_ partner: Partner) -> PartnerSuggestion? {
        suggestions.first { $0.partnerUuid == partner.uuid }
    }

    private func ordered(_ list: [Partner]) -> [Partner] {
        list.sorted { (suggestion($0)?.fit ?? -1) > (suggestion($1)?.fit ?? -1) }
    }

    private func choose(_ partner: Partner) {
        partnerUuid = partner.uuid
        kind = partner.commissionType
        rate = "\(partner.commissionValue)"
    }

    private func load(select added: String? = nil) async {
        guard session.permissions.can(.read, .crmAccounts) else { partners = .loaded([]); return }
        if partners.value == nil { partners = .loading }
        do {
            let list = try await services.crm.partners()
            partners = .loaded(list)
            if let wanted = added ?? preselect, let partner = list.first(where: { $0.uuid == wanted }) { choose(partner) }
        } catch {
            partners = .failed(error.asAPIError)
        }
    }

    private func send() {
        guard let partnerUuid else { return }
        saving = true
        error = nil
        let body = Self.body(subject: subject, partnerUuid: partnerUuid, value: value, kind: kind, rate: rate, message: message,
                             share: share, consent: consent, aiReason: suggestions.first { $0.partnerUuid == partnerUuid }?.reason)
        Task {
            defer { saving = false }
            do {
                let referral = try await services.crm.refer(body)
                await onDone(referral)
                dismiss()
            } catch {
                self.error = error.asAPIError
            }
        }
    }
}

// MARK: - Partners and referrals

/// The partners page: the directory (module kit) and every referral, with what to do next on each.
struct PartnersHubView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var partners: [Partner] = []
    @State private var partnersError: APIError?
    @State private var referrals: LoadState<[Referral]> = .idle
    @State private var status = ""
    @State private var notice: String?

    private let statuses: [(String, String)] = [
        ("", "All"), ("sent", "Waiting for the partner"), ("accepted", "Accepted"), ("won", "Won — invoice the commission"),
        ("commission_invoiced", "Commission invoiced"), ("commission_paid", "Commission paid"), ("declined", "Declined"),
    ]

    var body: some View {
        List {
            Section {
                NavigationLink(value: ResourceListRoute(ModuleCatalog.crmPartners.id)) {
                    LabeledContent {
                        Text("\(partners.count)").monospacedDigit()
                    } label: {
                        Label("Partner directory", systemImage: "person.2.badge.gearshape")
                    }
                }
                .accessibilityIdentifier("partners.directory")
                LabeledContent("Commission received",
                               value: Formatters.money(partners.reduce(0) { $0 + $1.commissionPaid }, currency: "GBP") ?? "")
                if let partnersError {
                    InlineErrorRow(error: partnersError) { Task { await load() } }
                }
            } footer: {
                Text("Companies you pass work to. They fulfil it; you earn the commission.")
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if session.permissions.can(.read, .crmDeals) {
                Section {
                    Picker("Show", selection: $status) {
                        ForEach(statuses, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .accessibilityIdentifier("partners.status")
                    switch referrals {
                    case .idle, .loading:
                        SkeletonRow()
                    case .failed(let error):
                        InlineErrorRow(error: error) { Task { await load() } }
                    case .loaded(let list):
                        if list.isEmpty {
                            Text(status.isEmpty ? "No referrals yet. Use “Pass to a partner” on a lead or a deal."
                                                : "No referrals with this status.")
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                        ForEach(list) { referral in
                            ReferralRow(referral: referral, canWork: session.canUpdate(.crmDeals)) { message in
                                notice = message
                                await load()
                            }
                            if let lead = referral.leadUuid, session.permissions.can(.read, .crmLeads) {
                                NavigationLink { LeadDetailView(leadUuid: lead) } label: {
                                    Label("Open the lead", systemImage: "person.crop.circle.badge.plus").font(.wsSubheadline)
                                }
                            } else if let deal = referral.dealUuid {
                                NavigationLink { CRMDealDetailView(dealUuid: deal) } label: {
                                    Label("Open the deal", systemImage: "briefcase").font(.wsSubheadline)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Referrals")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Partners")
        .task(id: status) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            partners = try await services.crm.partners(includeInactive: true)
            partnersError = nil
        } catch {
            partnersError = error.asAPIError
        }
        guard session.permissions.can(.read, .crmDeals) else { return }
        if referrals.value == nil { referrals = .loading }
        do {
            referrals = .loaded(try await services.crm.referrals(status: status.nonEmpty))
        } catch {
            if referrals.value == nil { referrals = .failed(error.asAPIError) }
        }
    }
}
