import SwiftUI

/// One mailing list: who is in it, adding people (or a smart list's rules), writing them an email,
/// renaming and deleting it. Mirrors the right-hand side of the web's Marketing → Lists page.
struct MktListDetailView: View {
    let listUUID: String
    /// Told the list's name after it was deleted (the screen closes itself).
    var onDeleted: ((String) -> Void)?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var list: MktListSummary?
    @State private var members: [MktListMember] = []
    @State private var total = 0
    @State private var membersState: LoadState<Void> = .idle
    @State private var loadError: APIError?
    @State private var search = ""
    @State private var notice: EngageNotice?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var confirmRegular = false
    @State private var addingPeople = false
    @State private var addingSMS = false
    @State private var busy = false
    @State private var removing: String?
    @State private var campaign: NativeScreenRoute?

    init(listUUID: String, seed: MktListSummary? = nil, onDeleted: ((String) -> Void)? = nil) {
        self.listUUID = listUUID
        self.onDeleted = onDeleted
        _list = State(initialValue: seed)
    }

    private var api: MktAudienceAPI { MktAudienceAPI(services) }
    private func can(_ action: Action, _ module: String = Marketing.RBAC.lists) -> Bool {
        session.permissions.can(action, moduleName: module)
    }

    private var shownMembers: [MktListMember] { members.filter { $0.matches(search) } }

    var body: some View {
        List {
            if let loadError {
                Section { InlineErrorRow(error: loadError) { Task { await load() } } }
            }
            if let list {
                header(list)
                addSection(list)
                peopleSection(list)
                if can(.delete) {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete this list", systemImage: "trash")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("mkt.list.delete")
                    } footer: {
                        Text("The people stay in your contacts — only this list is removed.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if list == nil, loadError == nil { SkeletonList() } }
        .navigationTitle(list?.name ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Find someone in this list")
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar {
            if list != nil, can(.update) || can(.delete) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if can(.update) {
                            Button {
                                newName = list?.name ?? ""
                                renaming = true
                            } label: { Label("Rename", systemImage: "pencil") }
                                .accessibilityIdentifier("mkt.list.rename")
                        }
                        if can(.delete) {
                            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("mkt.list.more")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .alert("Rename this list", isPresented: $renaming) {
            TextField("List name", text: $newName)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The new name is only for you; the people on the list never see it.")
        }
        .confirmationDialog("Delete “\(list?.name ?? "this list")”?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete list", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The people stay in your contacts — only this list is removed. Emails already sent are not affected.")
        }
        .confirmationDialog("Make it a regular list?", isPresented: $confirmRegular, titleVisibility: .visible) {
            Button("Make it a regular list") { Task { await makeRegular() } }
        } message: {
            Text("It stops filling itself from the rules. Anyone in it now stays, and from now on you add people "
                 + "yourself — by typing them, uploading a file or picking from your contacts.")
        }
        .sheet(isPresented: $addingPeople) {
            if let list {
                NavigationStack {
                    MktListAddPeopleView(list: list, memberUUIDs: Set(members.map(\.contactUUID))) { added in
                        notice = .done("\(MktAudienceText.people(added)) added to “\(list.name)”.")
                        Task { await loadMembers() }
                    }
                }
            }
        }
        .sheet(isPresented: $addingSMS) {
            if let list {
                NavigationStack {
                    MktListAddSMSView(list: list) { message in
                        notice = .done(message)
                        Task { await loadMembers() }
                    }
                }
            }
        }
        .navigationDestination(item: $campaign) { route in NativeScreenView(route: route) }
    }

    // MARK: - Sections

    @ViewBuilder
    private func header(_ list: MktListSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(list.name).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                Text(summary(list)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                if let description = list.description {
                    Text(description).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            }
            .padding(.vertical, 4)
            if !list.isSMS && can(.create, Marketing.RBAC.campaigns) {
                Button {
                    Task { await writeEmail(list) }
                } label: {
                    Label("Write an email to them", systemImage: "envelope")
                }
                .disabled(total == 0 || busy)
                .frame(minHeight: 44)
                .accessibilityIdentifier("mkt.list.writeEmail")
            }
            if total == 0, membersState.value != nil, !list.isSMS {
                Text(list.isSmart
                     ? "Nobody matches the rules yet — change the rules below, or make it a regular list and add people yourself."
                     : "Add people below, then you can write them an email.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }

    private func summary(_ list: MktListSummary) -> String {
        var parts: [String] = []
        parts.append(membersState.isLoading && members.isEmpty ? "…" : MktAudienceText.people(total))
        parts.append(list.isSMS ? "Text messages" : "Email")
        if list.isSmart { parts.append("Smart list — fills itself") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func addSection(_ list: MktListSummary) -> some View {
        if list.isSmart {
            Section {
                Text(MktSegmentRule(stored: list.segmentRule).sentence)
                    .font(.wsSubheadline)
                NavigationLink {
                    MktListRulesView(list: list) { count in
                        notice = .done("Saved — \(MktAudienceText.people(count)) in the list.")
                        Task { await load() }
                    }
                } label: {
                    Label(can(.update) ? "Change the rules" : "See the rules", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("mkt.list.rules")
                if can(.update) {
                    Button {
                        Task { await sync(list) }
                    } label: { Label("Update now", systemImage: "arrow.clockwise") }
                        .disabled(busy)
                        .accessibilityIdentifier("mkt.list.sync")
                    Button {
                        confirmRegular = true
                    } label: { Label("Make it a regular list", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("mkt.list.makeRegular")
                }
            } header: {
                Text("Who belongs in this smart list")
            } footer: {
                Text("Contacts that match these rules are put in the list for you, and it updates itself before every "
                     + "email. You can’t add people to a smart list yourself — make it a regular list to do that.")
            }
        } else if can(.update) {
            Section {
                Button {
                    if list.isSMS { addingSMS = true } else { addingPeople = true }
                } label: {
                    Label("Add people to this list", systemImage: "person.crop.circle.badge.plus")
                        .font(.wsHeadline)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("mkt.list.addPeople")
                NavigationLink {
                    MktGuideView(focus: "add-people")
                } label: {
                    Label("How do I add people?", systemImage: "questionmark.circle")
                }
            } footer: {
                Text(list.isSMS ? "Paste their names and mobile numbers."
                     : "Type their email addresses, upload a spreadsheet (Excel, CSV) or PDF, or tick people in your contacts.")
            }
        }
    }

    @ViewBuilder
    private func peopleSection(_ list: MktListSummary) -> some View {
        Section {
            switch membersState {
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await loadMembers() } }
            case .loaded where members.isEmpty:
                ContentUnavailableView {
                    Label("Nobody here yet", systemImage: "person.3")
                } description: {
                    Text(list.isSmart ? "Nobody matches the rules yet. Change the rules, then save them."
                         : "Use “Add people to this list” to type email addresses, upload a file, or pick from your contacts.")
                }
            case .loaded:
                if shownMembers.isEmpty {
                    Text("Nobody matches “\(search)”.").foregroundStyle(.secondaryText)
                }
                ForEach(shownMembers) { member in
                    NavigationLink {
                        MktAudiencePersonView(member: member, list: list) {
                            members.removeAll { $0.contactUUID == member.contactUUID }
                            total = max(0, total - 1)
                        }
                    } label: {
                        MktListMemberRow(member: member, sms: list.isSMS)
                    }
                    .swipeActions {
                        if !list.isSmart, can(.update) {
                            Button("Remove", role: .destructive) { Task { await remove(member, from: list) } }
                                .accessibilityIdentifier("mkt.list.member.remove.\(member.contactUUID)")
                        }
                    }
                }
                if total > members.count {
                    Text("Showing the newest \(members.count.formatted()) of \(total.formatted()).")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            default:
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("People in this list (\(total.formatted()))")
        } footer: {
            if !list.isSmart, can(.update), !members.isEmpty {
                Text("Swipe left on someone to take them off this list. They stay in your contacts.")
            }
        }
    }

    // MARK: - Work

    private func load() async {
        do {
            list = try await api.list(listUUID)
            loadError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            loadError = apiError
            if list == nil { return }
        }
        await loadMembers()
    }

    private func loadMembers() async {
        if members.isEmpty { membersState = .loading }
        do {
            let result = try await api.members(listUUID)
            members = result.members
            total = result.total
            membersState = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            membersState = .failed(apiError)
        }
    }

    private func rename() async {
        guard let list else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { notice = .info("The list needs a name — it wasn’t changed."); return }
        guard name != list.name else { return }
        do {
            try await api.updateList(list.uuid, .object(["name": .string(name)]))
            self.list?.name = name
            notice = .done("List renamed.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        guard let list else { return }
        do {
            try await api.deleteList(list.uuid)
            onDeleted?(list.name)
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func makeRegular() async {
        guard let list else { return }
        do {
            try await api.updateList(list.uuid, .object(["list_type": .string("static")]))
            self.list?.listType = "static"
            notice = .done("It’s now a regular list — add people below.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func sync(_ list: MktListSummary) async {
        busy = true
        defer { busy = false }
        do {
            let count = try await api.syncList(list.uuid)
            notice = .done("Updated — \(MktAudienceText.people(count)) in the list.")
            await loadMembers()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func remove(_ member: MktListMember, from list: MktListSummary) async {
        guard removing == nil else { return }
        removing = member.contactUUID
        defer { removing = nil }
        do {
            try await api.removeMember(list: list.uuid, contact: member.contactUUID)
            members.removeAll { $0.contactUUID == member.contactUUID }
            total = max(0, total - 1)
            notice = .done("\(member.address(sms: list.isSMS) ?? "That person") taken off this list (still in your contacts).")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func writeEmail(_ list: MktListSummary) async {
        busy = true
        defer { busy = false }
        do {
            let started = try await api.startEmail(to: list)
            notice = started.listAttached ? .done("A new email to “\(list.name)” is ready to write.")
                : .info("A new email is ready. Choose “\(list.name)” on its Audience tab.")
            campaign = EngageArea.route(Marketing.Screen.campaign, started.uuid)
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// Someone on a list: name, address, company, when and how they were added.
struct MktListMemberRow: View {
    let member: MktListMember
    let sms: Bool

    var body: some View {
        let address = member.address(sms: sms)
        HStack(spacing: 12) {
            Text(initials)
                .font(.wsCaption.bold())
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name ?? address ?? "—").font(.wsBody).lineLimit(1)
                if member.name != nil, let address {
                    Text(address).font(.wsSubheadline).foregroundStyle(.secondaryText).lineLimit(1)
                }
                let detail: [String] = [member.company, EngageFormat.day(member.addedAt),
                                        member.source.flatMap { MktListMember.sourceLabels[$0] }].compactMap { $0 }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.wsFootnote).foregroundStyle(.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var initials: String {
        let words = (member.name ?? member.address(sms: sms) ?? "?")
            .split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

/// One person on a list: their details, whether they can get marketing, and what can be done for them.
struct MktAudiencePersonView: View {
    let member: MktListMember
    let list: MktListSummary
    let onRemoved: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var subscriptions: [Record] = []
    @State private var suppressions: [Record] = []
    @State private var consentState: LoadState<Void> = .idle
    @State private var notice: EngageNotice?
    @State private var confirmStop = false
    @State private var confirmRemove = false
    @State private var evidence = ""

    private var api: MktAudienceAPI { MktAudienceAPI(services) }
    private var channelWord: String { list.isSMS ? "text messages" : "emails" }

    var body: some View {
        List {
            Section {
                if let name = member.name { DetailRow(label: "Name", value: name) }
                if let email = member.email { EmailLinkRow(email: email) }
                if let phone = member.phone { PhoneLinkRow(name: "Phone", phone: phone) }
                if let company = member.company { DetailRow(label: "Company", value: company) }
                if let added = EngageFormat.day(member.addedAt) { DetailRow(label: "Added", value: added) }
                if let source = member.source.flatMap({ MktListMember.sourceLabels[$0] }) {
                    DetailRow(label: "How", value: source)
                }
            }
            Section {
                switch consentState {
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await loadConsent() } }
                case .loaded:
                    if subscriptions.isEmpty && suppressions.isEmpty {
                        Text("Nothing recorded yet: they can get your marketing while they’re on a list you send to.")
                            .foregroundStyle(.secondaryText)
                    }
                    ForEach(suppressions) { row in
                        MktSuppressionRow(row: row)
                    }
                    ForEach(subscriptions) { row in
                        MktConsentRow(row: row, list: list)
                    }
                default:
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                Text("Can they get your marketing?")
            } footer: {
                Text("Only they can undo an unsubscribe: the unsubscribe page in any of your emails has a "
                     + "“Subscribe again” button.")
            }
            Section {
                if session.permissions.can(.create, moduleName: Marketing.RBAC.consent) {
                    Button(role: .destructive) { confirmStop = true } label: {
                        Label("They asked to stop getting \(channelWord)", systemImage: "hand.raised")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mkt.person.optOut")
                }
                if !list.isSmart, session.permissions.can(.update, moduleName: Marketing.RBAC.lists) {
                    Button(role: .destructive) { confirmRemove = true } label: {
                        Label("Take them off this list", systemImage: "person.badge.minus")
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mkt.person.remove")
                }
            }
        }
        .navigationTitle(member.name ?? member.address(sms: list.isSMS) ?? "Person")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .task { await loadConsent() }
        .refreshable { await loadConsent() }
        .alert("Record that they asked to stop?", isPresented: $confirmStop) {
            TextField("How they asked (optional)", text: $evidence)
            Button("They asked to stop", role: .destructive) { Task { await optOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won’t get any more marketing \(channelWord) from this workspace, from any list. Only they can undo it.")
        }
        .confirmationDialog("Take them off “\(list.name)”?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Take them off", role: .destructive) { Task { await remove() } }
        } message: {
            Text("They stay in your contacts and on your other lists.")
        }
    }

    private func loadConsent() async {
        if consentState.value == nil { consentState = .loading }
        do {
            let result = try await api.consent(contact: member.contactUUID)
            subscriptions = result.subscriptions
            suppressions = result.suppressions
            consentState = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            consentState = .failed(apiError)
        }
    }

    private func optOut() async {
        do {
            try await api.optOut(contact: member.contactUUID, sms: list.isSMS,
                                 address: list.isSMS ? member.phone : member.email, evidence: evidence)
            evidence = ""
            notice = .done("Recorded. They won’t get any more marketing \(channelWord).")
            await loadConsent()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func remove() async {
        do {
            try await api.removeMember(list: list.uuid, contact: member.contactUUID)
            onRemoved()
            dismiss()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// A "never send" record for one person: which channel, and how it happened.
private struct MktSuppressionRow: View {
    let row: Record

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Never sent \(what)").font(.wsBody.weight(.semibold))
                Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } icon: {
            Image(systemName: "nosign").foregroundStyle(Tone.danger.textColor)
        }
        .accessibilityElement(children: .combine)
    }

    private var what: String {
        switch row.string("channel") {
        case "sms": "texts"
        case "email": "emails"
        default: "anything"
        }
    }

    private var detail: String {
        let how = MktUnsubEntry.how(source: row.string("source") ?? "", reason: row.string("reason") ?? "")
        return [how, EngageFormat.day(row.string("created_at"))].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One consent record: subscribed or not, on which channel and list, on what basis.
private struct MktConsentRow: View {
    let row: Record
    let list: MktListSummary

    var body: some View {
        let subscribed = row.string("status") == "subscribed"
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(subscribed)).font(.wsBody.weight(.semibold))
                Text(detail(subscribed)).font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } icon: {
            Image(systemName: subscribed ? "checkmark.seal" : "xmark.seal")
                .foregroundStyle(subscribed ? Tone.success.textColor : Tone.danger.textColor)
        }
        .accessibilityElement(children: .combine)
    }

    private func title(_ subscribed: Bool) -> String {
        let verb = subscribed ? "Agreed to" : "Unsubscribed from"
        let what = row.string("channel") == "sms" ? "texts" : "emails"
        return "\(verb) \(what)\(scope)"
    }

    private func detail(_ subscribed: Bool) -> String {
        let parts: [String?] = [basis, MktAudienceText.consentSource(row.string("source"), subscribed: subscribed),
                                EngageFormat.day(row.string("changed_at"))]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private var scope: String {
        guard let listID = row.int("list_id") else { return "" }
        return listID == list.number ? " (this list)" : " (another list)"
    }

    private var basis: String? {
        switch row.string("legal_basis") {
        case "consent": "They asked for it"
        case "legitimate_interest": "A business contact"
        case nil: nil
        case let other?: Formatters.humanize(other)
        }
    }
}
