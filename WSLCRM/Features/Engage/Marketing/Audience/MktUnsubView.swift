import SwiftUI

/// Marketing → Unsubscribed (also the old "Suppressions" menu item): everyone who must never get
/// your marketing — people who unsubscribed, addresses that bounced or complained, and addresses
/// you blocked. Block an address yourself; unblock only the ones you blocked.
struct MktUnsubView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var source: MktUnsubSource
    @State private var model: PagedListModel<MktUnsubEntry>
    @State private var filters: [String: String] = [:]
    @State private var blocking = false
    @State private var unblocking: MktUnsubEntry?
    @State private var notice: EngageNotice?

    init(services: Services) {
        let source = MktUnsubSource(api: MktAudienceAPI(services))
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in
            try await source.fetch(search: search, page: page)
        })
    }

    private var canBlock: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.consent) }
    private var canUnblock: Bool { session.permissions.can(.delete, moduleName: Marketing.RBAC.consent) }

    var body: some View {
        PagedList(model: model, searchPrompt: "Search by email or number",
                  emptyTitle: filters.isEmpty ? "Nobody has unsubscribed yet" : "Nobody like that",
                  emptySystemImage: "hand.raised",
                  emptyDescription: filters.isEmpty
                      ? "When someone presses Unsubscribe in one of your emails, replies STOP to a text, or an address "
                        + "bounces, they appear here and are never sent marketing again."
                      : "Nobody matches these filters. Choose “All” to see everyone.") { entry in
            MktUnsubRow(entry: entry)
                .swipeActions {
                    if entry.canUnblock && canUnblock {
                        Button("Unblock") { unblocking = entry }
                            .tint(.orange)
                            .accessibilityIdentifier("mkt.unsub.unblock.\(entry.uuid)")
                    }
                }
                .contextMenu {
                    if entry.canUnblock && canUnblock {
                        Button { unblocking = entry } label: { Label("Unblock", systemImage: "lock.open") }
                    }
                    Button { UIPasteboard.general.string = entry.address } label: {
                        Label("Copy address", systemImage: "doc.on.doc")
                    }
                }
        }
        .navigationTitle("Unsubscribed")
        .safeAreaInset(edge: .top, spacing: 0) { MktCampJourneyBar(path: MktCampPages.unsubscribed) }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                EngageNoticeBar(notice: notice)
                MktUnsubExplainer(total: model.total)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    MktGuideView(focus: "unsubscribe")
                } label: {
                    Label("How unsubscribing works", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("mkt.unsub.help")
            }
            if canBlock {
                ToolbarItem(placement: .primaryAction) {
                    Button { blocking = true } label: { Label("Block an address", systemImage: "nosign") }
                        .accessibilityIdentifier("mkt.unsub.block")
                }
            }
        }
        .sheet(isPresented: $blocking) {
            NavigationStack {
                MktUnsubBlockForm(api: source.api) { added, address in
                    notice = .done(added ? "Blocked — \(address) won’t get your marketing."
                                   : "\(address) is already here: nothing is sent to it.")
                    Task { await model.load() }
                }
            }
        }
        .confirmationDialog("Unblock \(unblocking?.address ?? "")?", isPresented: Binding(
            get: { unblocking != nil }, set: { if !$0 { unblocking = nil } }), titleVisibility: .visible) {
            if let entry = unblocking {
                Button("Unblock") { Task { await unblock(entry) } }
            }
        } message: {
            Text("They can get your marketing again if they are on a list and have agreed to it.")
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Channel", selection: filterBinding("channel")) {
                Text("All").tag("")
                Text("Email").tag("email")
                Text("Text messages").tag("sms")
            }
            .pickerStyle(.menu)
            Picker("Why", selection: filterBinding("reason")) {
                Text("All").tag("")
                Text("Unsubscribed").tag("unsubscribe")
                Text("Blocked by you").tag("blocked")
                Text("Bounced (address doesn’t exist)").tag("hard_bounce")
                Text("Complained").tag("complaint")
                Text("Replied STOP").tag("stop_keyword")
            }
            .pickerStyle(.menu)
        } label: {
            Label("Filter", systemImage: filters.isEmpty ? "line.3.horizontal.decrease.circle"
                                                         : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("mkt.unsub.filter")
    }

    private func filterBinding(_ key: String) -> Binding<String> {
        Binding(get: { filters[key] ?? "" }, set: { value in
            filters[key] = value.isEmpty ? nil : value
            source.filters = filters
            Task { await model.load() }
        })
    }

    private func unblock(_ entry: MktUnsubEntry) async {
        do {
            try await source.api.unblock(entry.uuid)
            model.remove(id: entry.id)
            notice = .done("Unblocked \(entry.address).")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Builds the unsubscribed list with the environment's services (its list model is made once).
struct MktUnsubScreen: View {
    @Environment(\.services) private var services

    var body: some View {
        MktUnsubView(services: services)
    }
}

/// Fetches pages for the unsubscribed list; the filters chosen on screen are read at fetch time.
@MainActor
final class MktUnsubSource {
    let api: MktAudienceAPI
    var filters: [String: String] = [:]

    init(api: MktAudienceAPI) { self.api = api }

    func fetch(search: String, page: Int) async throws -> Page<MktUnsubEntry> {
        try await api.suppressions(search: search, page: page, filters: filters)
    }
}

/// The plain-words rule at the top of the page.
private struct MktUnsubExplainer: View {
    let total: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing is ever sent to the people here. Only the person can undo their unsubscribe: the "
                 + "unsubscribe page in any of your emails has a “Subscribe again” button. You can block an address "
                 + "yourself, and unblock the ones you blocked.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let total, total > 0 {
                Text("\(total.formatted()) in all").font(.wsFootnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// One address: how it got here, its channel and when.
struct MktUnsubRow: View {
    let entry: MktUnsubEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.address).font(.wsHeadline).lineLimit(1).textSelection(.enabled)
            Text([entry.how, entry.notes].compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(2)
            HStack(spacing: 8) {
                Pill(text: entry.channelLabel,
                     systemImage: entry.channel == "sms" ? "message" : entry.channel == "email" ? "envelope" : "nosign")
                if let when = EngageFormat.day(entry.createdAt) {
                    Text(when).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                if entry.canUnblock {
                    Pill(text: "You can unblock", systemImage: "lock.open")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Block an address: never send to it, whoever it is.
struct MktUnsubBlockForm: View {
    let api: MktAudienceAPI
    let onBlocked: (_ added: Bool, _ address: String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sms = false
    @State private var address = ""
    @State private var notes = ""
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                Picker("What to block", selection: $sms) {
                    Text("Email address").tag(false)
                    Text("Mobile number").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mkt.unsub.block.channel")
                TextField(sms ? "07700 900123" : "name@example.com", text: $address)
                    .keyboardType(sms ? .phonePad : .emailAddress)
                    .textContentType(sms ? .telephoneNumber : .emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.unsub.block.address")
                TextField("Why (optional, only for your team)", text: $notes, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("mkt.unsub.block.notes")
            } footer: {
                Text("Nothing is sent to it again — from any list or email — until you unblock it.")
            }
        }
        .navigationTitle("Block an address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Block") { Task { await block() } }
                    .disabled(saving || address.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("mkt.unsub.block.save")
            }
        }
    }

    private func block() async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let added = try await api.block(address: trimmed, sms: sms, notes: notes)
            onBlocked(added, trimmed)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
