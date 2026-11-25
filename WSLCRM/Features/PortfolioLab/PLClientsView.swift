import SwiftUI

/// The filters chosen on screen, read when a page is fetched.
@MainActor
final class PLClientsSource {
    let api: PLAPI
    var filter = PLAPI.ClientFilter()

    init(api: PLAPI) { self.api = api }

    func fetch(search: String, page: Int) async throws -> Page<Record> {
        try await api.contacts(search: search, filter: filter, page: page)
    }
}

/// Joy clients: every enquiry and client, with their journey stage, source, referrer and owner.
/// Search, filter by stage, source or "referrer to confirm", quick add, and open a client.
struct PLClientsView: View {
    @Environment(\.services) private var services

    var body: some View {
        PLClientsContent(api: PLAPI(client: services.client))
    }
}

private struct PLClientsContent: View {
    @Environment(SessionStore.self) private var session
    @State private var source: PLClientsSource
    @State private var model: PagedListModel<Record>
    @State private var filter = PLAPI.ClientFilter()
    @State private var adding = false
    @State private var opened: NativeScreenRoute?
    @State private var notice: String?
    @State private var hasAppeared = false

    init(api: PLAPI) {
        let source = PLClientsSource(api: api)
        _source = State(initialValue: source)
        _model = State(initialValue: PagedListModel { search, page in try await source.fetch(search: search, page: page) })
    }

    var body: some View {
        PagedList(model: model, searchPrompt: "Name, email or phone", emptyTitle: "No clients match",
                  emptySystemImage: "person.2",
                  emptyDescription: "New enquiries from the website, referrals and messages appear here.",
                  route: { client in NativeScreenRoute(PLScreens.client, client.id) }) { client in
            PLClientRow(client: client)
                .accessibilityIdentifier("pl.clients.row.\(client.id)")
        }
        .navigationTitle("Joy clients")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if let notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pl.clients.notice")
                }
                if let total = model.total, model.state.value != nil {
                    Text("\(total) client\(total == 1 ? "" : "s")").foregroundStyle(.secondaryText)
                }
            }
            .font(.wsSubheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, notice == nil && model.total == nil ? 0 : 6)
            .background(.bar)
        }
        .onAppear {
            if hasAppeared { Task { await model.load() } }
            hasAppeared = true
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
            if session.permissions.allows(.create, PLModule.contacts) {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Label("Quick add", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("pl.clients.add")
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                PLQuickAddSheet { merged, contact in
                    notice = merged ? "Already known: merged into the existing client." : "Client added."
                    Task { await model.load() }
                    if let contact { opened = NativeScreenRoute(PLScreens.client, contact) }
                }
            }
        }
        .navigationDestination(item: $opened) { NativeScreenView(route: $0) }
        .onChange(of: filter) { _, chosen in
            source.filter = chosen
            Task { await model.load() }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Stage", selection: $filter.stage) {
                Text("All stages").tag("")
                ForEach(PLText.stages, id: \.self) { Text(PLText.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Source", selection: $filter.source) {
                Text("All sources").tag("")
                ForEach(PLText.sources, id: \.self) { Text(PLText.label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle("Referrer to confirm", isOn: $filter.referrerToConfirm)
        } label: {
            let filtered = filter != PLAPI.ClientFilter()
            Label("Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill"
                                                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityIdentifier("pl.clients.filter")
    }
}

/// One client in the list.
struct PLClientRow: View {
    let client: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(PLClientRow.name(client)).font(.wsHeadline).lineLimit(2)
                Spacer(minLength: 8)
                StatusBadge(text: PLText.label(client.string("stage")), systemImage: "signpost.right",
                            tone: .info)
            }
            if let contact = client.string("email") ?? client.string("phone_e164") {
                Text(contact).font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            let source = [PLText.label(client.string("source")),
                          client.string("referred_by_name").map { "via \($0)" }].compactMap { $0 }
            Text(source.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            if client.bool("referrer_flag_open") == true {
                StatusBadge(text: "Confirm referrer: \(client.string("referrer_mentioned") ?? "named")",
                            systemImage: "exclamationmark.triangle", tone: .warning)
            }
            let more = [[client.string("country_of_residence"), client.string("timezone")].compactMap { $0 }
                            .joined(separator: " "),
                        client.string("funds_on_hand_band"), client.string("owner_name").map { "Owner \($0)" },
                        PLTime.uk(client.string("created_at")).map { "Added \($0)" }]
                .compactMap { $0?.trimmedOrNil }
            if !more.isEmpty {
                Text(more.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    static func name(_ client: Record) -> String {
        let name = [client.string("first_name"), client.string("last_name")].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (client.string("email") ?? client.string("phone_e164") ?? "Unnamed client") : name
    }
}

/// Quick add: a client met on LinkedIn, by phone or on social media.
private struct PLQuickAddSheet: View {
    let added: (_ merged: Bool, _ contact: String?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var form = PLAPI.QuickAdd()
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        Form {
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor) }
            }
            Section {
                TextField("First name", text: $form.firstName).textContentType(.givenName)
                    .accessibilityIdentifier("pl.add.first")
                TextField("Last name", text: $form.lastName).textContentType(.familyName)
                    .accessibilityIdentifier("pl.add.last")
                TextField("Email", text: $form.email).keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pl.add.email")
                TextField("Phone, with country code (+971 50 123 4567)", text: $form.phone).keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .accessibilityIdentifier("pl.add.phone")
            } footer: {
                Text("An email or a phone number is needed. Someone already known is merged, not added twice.")
            }
            Section {
                Picker("Source", selection: $form.source) {
                    ForEach(PLText.quickAddSources) { Text($0.label).tag($0.value) }
                }
                TextField("Handle or profile", text: $form.handle).textInputAutocapitalization(.never)
                    .accessibilityIdentifier("pl.add.handle")
                TextField("What they said", text: $form.message, axis: .vertical).lineLimit(3...8)
                    .accessibilityIdentifier("pl.add.message")
            }
        }
        .navigationTitle("Quick add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("pl.add.save")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let result = try await PLAPI(client: services.client).quickAdd(form)
            added(result.merged, result.contact)
            dismiss()
        } catch {
            problem = PluginProblem.message(error.asAPIError, labels: ["first_name": "First name", "last_name": "Last name",
                                                                       "email": "Email", "phone": "Phone",
                                                                       "source": "Source"])
        }
    }
}
