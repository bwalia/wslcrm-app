import SwiftUI

/// Earnings and payments: what you're owed and were paid, the bank account you're paid into,
/// and the academy's membership tiers. Sales are taken by the platform, which keeps its fee.
struct AcademyMonetisationView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<AcademyCreatorAccount> = .idle
    @State private var bank: [String: String] = [:]
    @State private var savingBank = false
    @State private var tier = 1
    @State private var price = ""
    @State private var interval = "month"
    @State private var savingPlan = false
    @State private var notice: EngageNotice?
    @State private var problem: String?

    private var canSaveBank: Bool { session.permissions.can(.update, moduleName: AcademyRBAC.module) }
    /// Membership prices are the academy's own: `PUT /creator/subscription-plan` needs `courses.manage`.
    private var canSetPlans: Bool { session.permissions.can(.manage, moduleName: AcademyRBAC.module) }

    var body: some View {
        List {
            switch state {
            case .loaded(let account):
                Section {
                    EngageIntro(text: "Sales are taken by the platform. It keeps a \(AcademyAPI.number(account.feePct))% "
                        + "fee and pays you the rest into the bank account below.", systemImage: "info.circle")
                }
                earnings(account.earnings)
                bankSection(complete: account.bankDetailsComplete)
                plansSection(account.plans)
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                EmptyView()
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .navigationTitle("Earnings and payments")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .refreshable { await load() }
        .task { await load() }
    }

    private func earnings(_ earnings: AcademyEarnings) -> some View {
        Section("Earnings") {
            EngageMetricGrid(metrics: [
                .init(title: "Owed to you", value: AcademyMoney.text(minor: earnings.owed, currency: earnings.currency),
                      systemImage: "hourglass", tone: .warning),
                .init(title: "Paid to you", value: AcademyMoney.text(minor: earnings.paid, currency: earnings.currency),
                      systemImage: "checkmark.circle", tone: .success),
                .init(title: "Sales", value: earnings.sales.formatted(), systemImage: "cart", tone: .info),
                .init(title: "Earned in total", value: AcademyMoney.text(minor: earnings.totalNet, currency: earnings.currency),
                      systemImage: "sum", tone: .brand),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
        }
    }

    private static let bankLabels: [(key: String, label: String, keyboard: UIKeyboardType)] = [
        ("account_holder_name", "Account holder’s name (needed)", .default),
        ("bank_name", "Bank name", .default),
        ("bank_country", "Country, e.g. GB or US", .default),
        ("account_number", "Account number", .numberPad),
        ("sort_code", "Sort code (UK)", .numbersAndPunctuation),
        ("routing_number", "Routing number (US)", .numberPad),
        ("iban", "IBAN", .default),
        ("swift_bic", "SWIFT / BIC", .default),
        ("payout_email", "Email for payment notices", .emailAddress),
    ]

    private func bankSection(complete: Bool) -> some View {
        Section {
            Group {
                if complete {
                    StatusBadge(text: "Complete", systemImage: "checkmark.circle", tone: .success)
                } else {
                    StatusBadge(text: "Add your details to get paid", systemImage: "exclamationmark.triangle", tone: .warning)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor)
            }
            ForEach(Self.bankLabels, id: \.key) { field in
                TextField(field.label, text: Binding(get: { bank[field.key] ?? "" }, set: { bank[field.key] = $0 }))
                    .keyboardType(field.keyboard)
                    .textInputAutocapitalization(field.key == "account_holder_name" || field.key == "bank_name" ? .words : .never)
                    .autocorrectionDisabled()
                    .disabled(!canSaveBank)
                    .accessibilityIdentifier("academy.bank.\(field.key)")
            }
            if canSaveBank {
                Button { Task { await saveBank() } } label: {
                    Label(savingBank ? "Saving…" : "Save bank details", systemImage: "building.columns")
                }
                .frame(minHeight: 44)
                .disabled(savingBank)
                .accessibilityIdentifier("academy.bank.save")
            }
        } header: { Text("Bank account for payments") } footer: {
            Text("Give an account number (with a sort code in the UK, a routing number in the US) or an IBAN.")
        }
    }

    private func plansSection(_ plans: [AcademyPlan]) -> some View {
        Section {
            if plans.isEmpty {
                Text("No membership tiers yet.").foregroundStyle(.secondaryText)
            }
            ForEach(plans) { plan in
                LabeledContent("Tier \(plan.tier)", value: plan.priceText)
                    .accessibilityIdentifier("academy.plan.\(plan.tier)")
            }
            if canSetPlans {
                Stepper(value: $tier, in: 1...20) { LabeledContent("Tier", value: "\(tier)") }
                    .accessibilityIdentifier("academy.plan.tier")
                LabeledContent("Price") {
                    TextField("e.g. 9.99", text: $price)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("academy.plan.price")
                }
                Picker("Billed", selection: $interval) {
                    Text("Monthly").tag("month")
                    Text("Yearly").tag("year")
                }
                .accessibilityIdentifier("academy.plan.interval")
                Button { Task { await savePlan() } } label: {
                    Label(savingPlan ? "Saving…" : "Save tier \(tier)", systemImage: "square.and.arrow.down")
                }
                .frame(minHeight: 44)
                .disabled(savingPlan)
                .accessibilityIdentifier("academy.plan.save")
            }
        } header: { Text("Membership tiers") } footer: {
            Text(canSetPlans
                 ? "A member can watch every course at their tier and below. Tier 1 is the entry plan. Saving a tier "
                   + "that already exists changes its price (prices are in US dollars)."
                 : "A member can watch every course at their tier and below. Only the academy’s owner sets tier prices.")
        }
    }

    // MARK: Work

    private func load() async {
        do {
            let account = try await services.academy.creatorAccount()
            state = .loaded(account)
            bank = account.bank.values
            if let first = account.plans.first, price.isEmpty {
                price = AcademyMoney.major(first.amount)
                interval = first.interval == "year" ? "year" : "month"
            }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }

    private func saveBank() async {
        problem = AcademyBank.problem(bank)
        guard problem == nil else { return }
        savingBank = true
        defer { savingBank = false }
        do {
            let complete = try await services.academy.saveBank(bank)
            notice = .done(complete ? "Bank details saved. You can now be paid." : "Bank details saved.")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func savePlan() async {
        guard let amount = AcademyMoney.minor(fromTyped: price), amount > 0 else {
            notice = .info("Enter a price above 0, for example 9.99.")
            return
        }
        savingPlan = true
        defer { savingPlan = false }
        do {
            let plan = try await services.academy.savePlan(tier: tier, amountMinor: amount, interval: interval)
            notice = .done("Tier \(plan.tier) saved: \(plan.priceText).")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Platform admins: the platform's cut of every sale, and paying instructors what they're owed.
struct AcademyPayoutsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var feeText = ""
    @State private var savingFee = false
    @State private var payouts: [AcademyPayout] = []
    @State private var state: LoadState<Void> = .idle
    @State private var notice: EngageNotice?
    @State private var overriding: AcademyPayout?
    @State private var overrideText = ""
    @State private var paying: AcademyPayout?
    @State private var reference = ""

    private var isPlatformAdmin: Bool {
        session.permissions.isAdmin || session.user?.platformRoles.contains("administrative") == true
    }

    var body: some View {
        List {
            if !isPlatformAdmin {
                ContentUnavailableView("For platform admins only", systemImage: "lock",
                                       description: Text("Payouts and the platform’s fee are set by the platform’s administrators."))
            } else {
                feeSection
                payoutsSection
            }
        }
        .navigationTitle("Payouts and fee")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .refreshable { await load() }
        .task { if isPlatformAdmin { await load() } }
        .alert("Instructor’s own cut", isPresented: Binding(get: { overriding != nil }, set: { if !$0 { overriding = nil } })) {
            TextField("Leave empty to use the default", text: $overrideText).keyboardType(.decimalPad)
            Button("Save") { if let payout = overriding { Task { await saveOverride(payout) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The platform’s cut, in %, for \(overriding?.instructorName ?? "this instructor"). Leave it empty to use the default.")
        }
        .alert("Mark as paid?", isPresented: Binding(get: { paying != nil }, set: { if !$0 { paying = nil } })) {
            TextField("Bank reference (optional)", text: $reference)
            Button("Mark paid") { if let payout = paying { Task { await markPaid(payout) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let paying {
                Text("Record that you sent \(AcademyMoney.text(minor: paying.owed, currency: paying.currency)) to "
                    + "\(paying.instructorName). Do this after the bank transfer.")
            }
        }
    }

    private var feeSection: some View {
        Section {
            HStack {
                TextField("Cut %", text: $feeText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("academy.fee.default")
                Text("%").foregroundStyle(.secondaryText)
                Button(savingFee ? "Saving…" : "Save") { Task { await saveFee() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(savingFee)
                    .accessibilityIdentifier("academy.fee.save")
            }
        } header: { Text("Platform’s default cut") } footer: {
            Text("Taken from every sale, unless an instructor has their own cut below.")
        }
    }

    private var payoutsSection: some View {
        Section {
            if case .failed(let error) = state {
                InlineErrorRow(error: error) { Task { await load() } }
            } else if state.value != nil, payouts.isEmpty {
                Text("Nothing is owed right now.").foregroundStyle(.secondaryText)
            } else if state.value == nil {
                ProgressView()
            }
            ForEach(payouts) { payout in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payout.instructorName).font(.wsHeadline)
                            if let email = payout.instructorEmail {
                                Text(email).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                        Spacer()
                        Text(AcademyMoney.text(minor: payout.owed, currency: payout.currency))
                            .font(.wsHeadline.monospacedDigit())
                    }
                    Text(payout.sales == 1 ? "1 sale" : "\(payout.sales) sales")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                    if payout.canBePaid, let bank = payout.bank {
                        Text(bank.summary).font(.wsFootnote).textSelection(.enabled)
                    } else {
                        StatusBadge(text: "No bank details yet", systemImage: "exclamationmark.triangle", tone: .warning)
                    }
                    HStack {
                        Button("Set their cut") {
                            overrideText = ""
                            overriding = payout
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("academy.payout.cut.\(payout.userUuid)")
                        Button("Mark paid") {
                            reference = ""
                            paying = payout
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!payout.canBePaid)
                        .accessibilityIdentifier("academy.payout.paid.\(payout.userUuid)")
                    }
                }
                .padding(.vertical, 4)
            }
        } header: { Text("Owed to instructors") } footer: {
            Text("Send the money by bank transfer, then mark it paid. An instructor without bank details can’t be paid yet.")
        }
    }

    private func load() async {
        do {
            async let fee = services.academy.defaultFeePct()
            async let rows = services.academy.payouts()
            feeText = AcademyAPI.number(try await fee)
            payouts = try await rows
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func saveFee() async {
        guard let pct = Double(feeText.replacingOccurrences(of: ",", with: ".")), (0...100).contains(pct) else {
            notice = .info("The cut must be a number from 0 to 100.")
            return
        }
        savingFee = true
        defer { savingFee = false }
        do {
            try await services.academy.setDefaultFeePct(pct)
            notice = .done("Default cut saved: \(AcademyAPI.number(pct))%.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func saveOverride(_ payout: AcademyPayout) async {
        let text = overrideText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        var pct: Double?
        if !text.isEmpty {
            guard let value = Double(text), (0...100).contains(value) else {
                notice = .info("Enter a cut from 0 to 100, or leave it empty for the default.")
                return
            }
            pct = value
        }
        do {
            try await services.academy.setFeeOverride(user: payout.userUuid, pct: pct)
            notice = .done(pct.map { "\(payout.instructorName)’s cut is now \(AcademyAPI.number($0))%." }
                           ?? "\(payout.instructorName) now has the default cut.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func markPaid(_ payout: AcademyPayout) async {
        do {
            let answer = try await services.academy.markPaid(user: payout.userUuid, reference: reference)
            let amount = AcademyMoney.text(minor: answer.amount?.value ?? payout.owed, currency: answer.currency ?? payout.currency)
            notice = .done("Recorded a payment of \(amount) to \(payout.instructorName).")
            await load()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}
