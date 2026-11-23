import SwiftUI

/// Marketing → Lists: every mailing list with how many people are in it, and making a new one.
/// A list opens its own screen (`MktListDetailView`) to add people, write them an email, rename or delete it.
struct MktListsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var lists: [MktListSummary] = []
    @State private var counts: [String: Int] = [:]
    @State private var state: LoadState<Void> = .idle
    @State private var search = ""
    @State private var creating = false
    @State private var opened: MktListSummary?
    @State private var notice: EngageNotice?

    private var api: MktAudienceAPI { MktAudienceAPI(services) }
    private var canCreate: Bool { session.permissions.can(.create, moduleName: Marketing.RBAC.lists) }
    private var canDelete: Bool { session.permissions.can(.delete, moduleName: Marketing.RBAC.lists) }

    private var shown: [MktListSummary] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? lists : lists.filter { $0.name.lowercased().contains(query) }
    }

    private var totalPeople: Int { counts.values.reduce(0, +) }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "A list is a group of people you send emails to. Make a list, add people, then write them an email.")
                MktListSteps(done: [!lists.isEmpty, totalPeople > 0, false])
                NavigationLink {
                    MktGuideView(focus: "make-list")
                } label: {
                    Label("How do lists work?", systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("mkt.lists.help")
            }
            if case .failed(let error) = state, !lists.isEmpty {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            if !lists.isEmpty {
                Section("Your lists (\(lists.count))") {
                    if shown.isEmpty {
                        Text("No list matches “\(search)”.").foregroundStyle(.secondaryText)
                    }
                    ForEach(shown) { list in
                        NavigationLink {
                            MktListDetailView(listUUID: list.uuid, seed: list, onDeleted: deleted)
                        } label: {
                            MktListRow(list: list, count: counts[list.uuid])
                        }
                        .accessibilityIdentifier("mkt.lists.row.\(list.uuid)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { overlay }
        .navigationTitle("Mailing lists")
        .searchable(text: $search, prompt: "Find a list")
        .safeAreaInset(edge: .top, spacing: 0) { MktCampJourneyBar(path: MktCampPages.lists) }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .toolbar {
            if canCreate {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("Make a new list", systemImage: "plus") }
                        .accessibilityIdentifier("mkt.lists.new")
                }
            }
        }
        .refreshable { await load() }
        // Runs again when coming back from a list: it may have been renamed, filled or deleted.
        .task { await load() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                MktListNewForm(existingNames: Set(lists.map { $0.name.lowercased() })) { created in
                    notice = .done("“\(created.name)” is ready — now add people to it.")
                    lists.insert(created, at: 0)
                    counts[created.uuid] = 0
                    opened = created
                }
            }
        }
        .navigationDestination(item: $opened) { list in
            MktListDetailView(listUUID: list.uuid, seed: list, onDeleted: deleted)
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch state {
        case .idle, .loading:
            if lists.isEmpty { SkeletonList() }
        case .failed(let error) where lists.isEmpty:
            ErrorStateView(error: error) { Task { await load() } }
        case .loaded where lists.isEmpty:
            ContentUnavailableView {
                Label("Make your first list", systemImage: "person.3")
            } description: {
                Text("Give it a name you’ll recognise, like “Customers”. Next you add people to it: type their "
                     + "email addresses, upload a spreadsheet, or tick people in your contacts. Then write them an email.")
            } actions: {
                if canCreate {
                    Button("Make a list") { creating = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mkt.lists.first")
                } else {
                    Text("Your role can’t make lists. Ask your workspace owner for access to Marketing lists.")
                        .font(.wsFootnote)
                }
            }
        default:
            EmptyView()
        }
    }

    private func deleted(_ name: String) {
        notice = .done("“\(name)” deleted. The people in it are still in your contacts.")
    }

    private func load() async {
        if lists.isEmpty { state = .loading }
        do {
            async let fetched = api.lists()
            async let fetchedCounts = api.listCounts()
            let (rows, numbers) = try await (fetched, fetchedCounts)
            lists = rows
            counts = numbers
            state = .loaded(())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// One list in the list of lists: its name, how many people, email or text, smart or not.
struct MktListRow: View {
    let list: MktListSummary
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(list.name).font(.wsHeadline).lineLimit(2)
                if list.isSMS {
                    Image(systemName: "message").foregroundStyle(.secondaryText).accessibilityLabel("Text messages")
                }
                if list.isSmart {
                    Image(systemName: "sparkles").foregroundStyle(.secondaryText).accessibilityLabel("Smart list")
                }
            }
            if let count {
                if count == 0 {
                    StatusBadge(text: list.isSmart ? "Empty — nobody matches" : "Empty — add people",
                                systemImage: "exclamationmark.circle", tone: .warning)
                } else {
                    Text(MktAudienceText.people(count)).font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// "Make a list → Add people → Send them an email", the ones done ticked.
struct MktListSteps: View {
    let done: [Bool]
    private let labels = ["Make a list", "Add people to it", "Send them an email"]

    var body: some View {
        let current = done.firstIndex(of: false)
        HStack(alignment: .top, spacing: 8) {
            ForEach(labels.indices, id: \.self) { index in
                let isDone = done.indices.contains(index) && done[index]
                let fill: Color = isDone ? Tone.success.solidColor
                    : (index == current ? Tone.brand.solidColor : Color.secondary.opacity(0.15))
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(fill).frame(width: 30, height: 30)
                        if isDone {
                            Image(systemName: "checkmark").font(.wsCaption.bold()).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.wsCaption.bold())
                                .foregroundStyle(index == current ? Color.white : Color.primary)
                        }
                    }
                    Text(labels[index])
                        .font(index == current ? .wsFootnote.weight(.semibold) : .wsFootnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(index == current ? Color.primary : .secondaryText)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(index + 1): \(labels[index])\(isDone ? ", done" : index == current ? ", do this next" : "")")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Make a new list: a name, and (rarely needed) text messages or a smart list.
struct MktListNewForm: View {
    let existingNames: Set<String>
    let onCreated: (MktListSummary) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var sms = false
    @State private var smart = false
    @State private var moreOptions = false
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("e.g. Customers, Local businesses", text: $name)
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { problem = nil }
                    .accessibilityIdentifier("mkt.lists.new.name")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.wsFootnote).foregroundStyle(Tone.danger.textColor)
                }
            } header: {
                Text("What do you want to call this list?")
            } footer: {
                Text("Give it a name you’ll recognise. You’ll add people to it next.")
            }
            if let error { Section { InlineErrorRow(error: error) } }
            Section {
                DisclosureGroup("More options (most people don’t need these)", isExpanded: $moreOptions) {
                    Toggle("For text messages (SMS) instead of email", isOn: $sms)
                        .accessibilityIdentifier("mkt.lists.new.sms")
                    Toggle(isOn: $smart) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Smart list (advanced)")
                            Text("Fills itself with contacts that match rules you set, e.g. everyone at one company. "
                                 + "You can’t add people to it yourself.")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .accessibilityIdentifier("mkt.lists.new.smart")
                }
            }
        }
        .navigationTitle("New list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create list") { Task { await create() } }
                    .disabled(saving)
                    .accessibilityIdentifier("mkt.lists.new.create")
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { problem = "Type a name for your list first, e.g. “Customers”."; return }
        guard !existingNames.contains(trimmed.lowercased()) else {
            problem = "You already have a list called “\(trimmed)”. Pick another name."
            return
        }
        saving = true
        defer { saving = false }
        do {
            let created = try await MktAudienceAPI(services).createList(name: trimmed, smart: smart, sms: sms)
            onCreated(created)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}
