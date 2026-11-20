import SwiftUI

/// The accountant's queue (`/dashboard/tax/filing-requests`, RBAC `tax_filing_requests`): returns customers
/// asked the workspace to file. Download the tax sheet, file it with HMRC-recognised software, then record
/// HMRC's reference here (`/api/v2/tax/filing/queue…`).
struct TaxFilingRequestsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var tab = "open"
    @State private var items: LoadState<[Record]> = .idle
    @State private var counts: Record = Record([:])
    @State private var opened: Record?

    static let tabs: [(status: String, label: String)] = [
        ("open", "Open"), ("submitted", "New"), ("needs_info", "Waiting on customer"), ("filed", "Filed"),
        ("rejected", "Returned"), ("all", "All"),
    ]

    static let labels: [String: (String, Tone)] = [
        "submitted": ("New", .info), "reviewing": ("Reviewing", .progress), "needs_info": ("Waiting on customer", .warning),
        "filing": ("Filing", .progress), "filed": ("Filed", .success), "rejected": ("Returned", .danger),
        "cancelled": ("Cancelled", .neutral),
    ]

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $tab) {
                    ForEach(Self.tabs, id: \.status) { t in Text("\(t.label) (\(count(t.status)))").tag(t.status) }
                }
                .accessibilityIdentifier("tax.filingRequests.tab")
            } footer: {
                Text("Returns customers asked us to file. Download the tax sheet, file it on My Tax Digital (or other "
                     + "HMRC-recognised software), then record HMRC’s reference.")
            }
            switch items {
            case .loaded(let rows):
                if rows.isEmpty { Section { TaxEmptyRow(title: "Nothing here.", systemImage: "tray") } }
                Section {
                    ForEach(rows) { row in
                        Button { opened = row } label: { QueueRow(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tax.filingRequest.\(row.id)")
                    }
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle("Filing requests")
        .task(id: tab) { await load() }
        .refreshable { await load() }
        .sheet(item: $opened) { row in
            NavigationStack { FilingRequestDetailView(uuid: row.id) { Task { await load() } } }
        }
    }

    private func count(_ status: String) -> Int {
        switch status {
        case "open": return ["submitted", "reviewing", "needs_info", "filing"].reduce(0) { $0 + (counts.int($1) ?? 0) }
        case "all": return counts.fields.keys.reduce(0) { $0 + (counts.int($1) ?? 0) }
        default: return counts.int(status) ?? 0
        }
    }

    private func load() async {
        do {
            let json = try await makeTaxAPI(services, user: session.user)
                .get("/api/v2/tax/filing/queue", query: ["status": tab, "perPage": "200"])
            items = .loaded(json["data"]?.recordList ?? [])
            counts = json["meta"]?.record.object("counts") ?? Record([:])
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            items = .failed(apiError)
        }
    }
}

private struct QueueRow: View {
    let row: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.string("customer.name") ?? "—").font(.wsHeadline)
                Spacer()
                Text(row.moneyOrDash("our_total_due")).font(.wsSubheadline.monospacedDigit())
            }
            Text([row.string("customer.email"), row.string("tax_year").map { "Tax year \($0)" },
                  row.day("created_at").map { "received \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            HStack {
                let label = TaxFilingRequestsView.labels[row.string("status") ?? ""] ?? (Formatters.humanize(row.string("status")), .neutral)
                StatusBadge(text: label.0, systemImage: "circle.fill", tone: label.1)
                if let unreviewed = row.int("unreviewed"), unreviewed > 0 {
                    Text("\(unreviewed) to review").font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One request: the customer's approved figures, SA103F boxes, and the moves the accountant can make.
struct FilingRequestDetailView: View {
    let uuid: String
    let changed: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var detail: LoadState<Record> = .idle
    @State private var notice: TaxNotice?
    @State private var action: String?
    @State private var message = ""
    @State private var reference = ""
    @State private var hmrcTotal = ""
    @State private var varianceNote = ""
    @State private var busy = false

    var body: some View {
        List {
            if let notice { Section { TaxNoticeView(notice: notice) { self.notice = nil } } }
            switch detail {
            case .loaded(let d): content(d)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { ProgressView(); Text("Loading…") } }
            }
        }
        .navigationTitle(detail.value.map { "\($0.string("customer.name") ?? $0.string("customer.email") ?? "Request") — \($0.string("tax_year") ?? "")" } ?? "Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: Binding(get: { action.map { IdentifiedString(value: $0) } }, set: { action = $0?.value })) { item in
            NavigationStack { actionForm(item.value) }
        }
    }

    @ViewBuilder
    private func content(_ d: Record) -> some View {
        let status = d.string("status") ?? ""
        Section {
            let label = TaxFilingRequestsView.labels[status] ?? (Formatters.humanize(status), .neutral)
            StatusBadge(text: label.0, systemImage: "circle.fill", tone: label.1)
            DetailRow(label: "Email", value: d.string("customer.email"))
            DetailRow(label: "NINO ending", value: d.string("customer.nino_last4") ?? "—")
            DetailRow(label: "Approved", value: d.day("declared_at"))
            if let unreviewed = d.int("totals.unreviewed"), unreviewed > 0 {
                TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                    Text("\(unreviewed) transaction\(unreviewed == 1 ? " was" : "s were") still flagged for review when the "
                         + "customer sent this — check them on the Transactions sheet (or ask the customer).")
                }
            }
            if let other = d.decimal("totals.other_money_in"), other > 0 {
                TaxCallout(tone: .warning, systemImage: "exclamationmark.triangle") {
                    Text("\(TaxMoney.text(other)) of money in is unsorted or sits in an expense category — counted as income. "
                         + "Confirm before filing.")
                }
            }
        }
        Section("Calculation") {
            let s = d.object("summary") ?? Record([:])
            TaxAmountRow(label: "Income", value: s.money("income"))
            TaxAmountRow(label: "Allowable expenses", value: s.money("expenses"))
            TaxAmountRow(label: "Profit", value: s.money("profit"))
            TaxAmountRow(label: "Personal allowance", value: s.money("personal_allowance"))
            TaxAmountRow(label: "Income Tax", value: s.money("income_tax"))
            TaxAmountRow(label: "Class 4 NIC", value: s.money("class4_nic"))
            TaxAmountRow(label: "Total tax and NICs", value: s.money("total_tax_and_nic"), bold: true)
            TaxAmountRow(label: "Due by 31 Jan (incl. payment on account)", value: s.money("total_due_31_jan"))
        }
        let boxes = d.records("boxes")
        if !boxes.isEmpty {
            Section("SA103F boxes") {
                ForEach(boxes) { box in
                    HStack {
                        Text(box.string("box") ?? "").font(.wsBody.monospacedDigit().bold()).frame(width: 36, alignment: .leading)
                        Text(box.string("item") ?? "").font(.wsBody)
                        Spacer()
                        Text(box.money("amount")).font(.wsBody.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        Section {
            Text("1. Download the tax sheet — it holds exactly the figures the customer approved.")
            Text("2. File it on My Tax Digital (or other HMRC-recognised software) using the Boxes sheet.")
            Text("3. Come back and record HMRC’s reference with “Mark as filed”.")
            TaxDownloadButton(title: "Download the tax sheet (.xlsx)") {
                let name = (d.string("customer.name") ?? "").replacingOccurrences(of: #"[^\w]+"#, with: "-",
                                                                                   options: .regularExpression)
                let url = try await api.download("/api/v2/tax/filing/queue/\(uuid)/export",
                                                  fallbackName: "tax-calculation-\(d.string("tax_year") ?? "")-\(name).xlsx")
                await load()
                return url
            }
        } header: {
            Text("How to file this return")
        }
        .font(.wsFootnote)
        if status == "filed" {
            Section {
                Text("Filed \(d.day("filed_at") ?? "") — reference \(d.string("hmrc_reference") ?? "")").textSelection(.enabled)
                if d.decimal("hmrc_total_due") != nil { TaxAmountRow(label: "HMRC’s total", value: d.money("hmrc_total_due")) }
                if let note = d.string("variance_note") { Text("Note: \(note)").font(.wsFootnote) }
            }
        }
        let next = d.array("next").compactMap(\.stringValue)
        if !next.isEmpty && session.allows(.update, "tax_filing_requests") {
            Section("What next") {
                ForEach(next, id: \.self) { status in
                    switch status {
                    case "reviewing":
                        Button(d.string("status") == "needs_info" ? "Resume review" : "Start review") {
                            Task { await update(["status": .string("reviewing")]) }
                        }
                    case "filing":
                        Button("I’m filing it now") { Task { await update(["status": .string("filing")]) } }
                    case "filed":
                        Button("Mark as filed") { action = "filed" }
                    case "needs_info":
                        Button("Ask the customer") { action = "needs_info" }
                    case "rejected":
                        Button("Return to customer", role: .destructive) { action = "rejected" }
                    default:
                        EmptyView()
                    }
                }
            }
            .disabled(busy)
        }
        let timeline = d.records("timeline")
        if !timeline.isEmpty {
            Section("History") {
                ForEach(Array(timeline.reversed().enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.historyLabel(entry)).font(.wsBody)
                        if let text = entry.string("text") { Text("“\(text)”").font(.wsFootnote).foregroundStyle(.secondaryText) }
                        Text(entry.string("at").flatMap { Formatters.dateTime(APIDate.parse($0)) } ?? "").font(.wsCaption)
                            .foregroundStyle(.secondaryText)
                    }
                }
            }
        }
    }

    static func historyLabel(_ entry: Record) -> String {
        switch entry.string("type") {
        case "export": return "Tax sheet downloaded"
        case "reply": return "Customer replied"
        default:
            let who = entry.string("by") == "customer" ? "Customer" : "Accountant"
            return "\(who) → \(TaxFilingRequestsView.labels[entry.string("status") ?? ""]?.0 ?? Formatters.humanize(entry.string("status")))"
        }
    }

    @ViewBuilder
    private func actionForm(_ kind: String) -> some View {
        let ours = detail.value?.decimal("our_total_due") ?? 0
        let theirs = Decimal(string: hmrcTotal.replacingOccurrences(of: ",", with: ""))
        let differs = theirs.map { abs($0 - ours) > 1 } ?? false
        Form {
            if let notice, notice.kind == .error { Section { TaxNoticeView(notice: notice) } }
            switch kind {
            case "filed":
                TextField("HMRC submission reference", text: $reference)
                    .onChange(of: reference) { _, v in if v.count > 100 { reference = String(v.prefix(100)) } }
                    .accessibilityIdentifier("tax.filingRequest.reference")
                TextField("HMRC’s total tax and NICs (optional) — ours: \(TaxMoney.text(ours))", text: $hmrcTotal)
                    .keyboardType(.decimalPad)
                if differs {
                    Section("HMRC differs from ours by \(TaxMoney.text(abs((theirs ?? 0) - ours))) — explain why") {
                        TextField("Why it differs", text: $varianceNote, axis: .vertical).lineLimit(3...6)
                    }
                }
            case "needs_info":
                Section("What do you need from the customer?") {
                    TextField("Your question", text: $message, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("tax.filingRequest.message")
                }
            default:
                Section("Why is it being returned? What should they fix?") {
                    TextField("Your reason", text: $message, axis: .vertical).lineLimit(3...8)
                }
            }
        }
        .navigationTitle(kind == "filed" ? "Mark as filed" : kind == "needs_info" ? "Ask the customer" : "Return to customer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { action = nil } }
            ToolbarItem(placement: .confirmationAction) {
                Button(kind == "filed" ? "Confirm filed" : kind == "needs_info" ? "Send question" : "Return") {
                    Task {
                        var body: [String: JSONValue] = ["status": .string(kind)]
                        if kind == "filed" {
                            body["hmrc_reference"] = .string(reference.trimmingCharacters(in: .whitespaces))
                            if !hmrcTotal.isEmpty { body["hmrc_total_due"] = .string(hmrcTotal) }
                            if differs { body["variance_note"] = .string(varianceNote) }
                        } else {
                            body["message"] = .string(message.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        if await update(body) { action = nil }
                    }
                }
                .disabled(busy || (kind == "filed"
                    ? reference.trimmingCharacters(in: .whitespaces).isEmpty || (differs && varianceNote.isEmpty)
                    : message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("tax.filingRequest.submit")
            }
        }
    }

    private var api: TaxAPI { makeTaxAPI(services, user: session.user) }

    private func load() async {
        do {
            detail = .loaded(try await api.get("/api/v2/tax/filing/queue/\(uuid)").payload.record)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            detail = .failed(apiError)
        }
    }

    @discardableResult
    private func update(_ body: [String: JSONValue]) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await api.json(.post, "/api/v2/tax/filing/queue/\(uuid)/status", body)
            notice = .success("Request updated — the customer has been told.")
            message = ""
            await load()
            changed()
            return true
        } catch {
            notice = .error(error)
            return false
        }
    }
}

/// A string usable with `.sheet(item:)`.
struct IdentifiedString: Identifiable, Hashable {
    let value: String
    var id: String { value }
}
