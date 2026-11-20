import SwiftUI

/// PA knowledge: the rules the PA follows. Teach a rule (managers for the company and team, anyone
/// for themselves), approve or reject what's waiting, read the rules in use and their versions,
/// and retire one. Every change is a new version; old ones are kept.
struct PAKnowledgeView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var rules: LoadState<[PAKnowledgeItem]> = .idle
    @State private var pending: [PAPendingKnowledge] = []
    @State private var pendingError: APIError?
    @State private var search = ""
    @State private var notice: String?
    @State private var actionError: APIError?
    @State private var deciding: String?

    // Teach
    @State private var statement = ""
    @State private var title = ""
    @State private var scope = "personal"
    @State private var triggers = ""
    @State private var teaching = false
    @State private var prepared = false

    private var isManager: Bool { session.permissions.paIsManager }

    var body: some View {
        List {
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.knowledge.notice")
                }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            if session.permissions.pa(.create, "knowledge") { teachSection }
            pendingSection
            rulesSection
        }
        .navigationTitle("PA knowledge")
        .searchable(text: $search, prompt: "Search the rules")
        .refreshable { await load() }
        .task(id: search) {
            if rules.value != nil { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .onAppear {
            if !prepared {
                prepared = true
                scope = isManager ? "company" : "personal"
            }
        }
    }

    // MARK: Teach

    private var canApproveNow: Bool { isManager || scope == "personal" }

    private var teachSection: some View {
        Section {
            TextField("An agent's valuation is not the seller's minimum price. Treat it as their anchor.",
                      text: $statement, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityIdentifier("pa.knowledge.statement")
            TextField("Short title (optional)", text: $title)
                .accessibilityIdentifier("pa.knowledge.title")
            Picker("Who it applies to", selection: $scope) {
                Text("The company").tag("company")
                Text("My team").tag("team")
                Text("Just me").tag("personal")
            }
            .accessibilityIdentifier("pa.knowledge.scope")
            TextField("When it applies, e.g. valuation, price", text: $triggers)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("pa.knowledge.triggers")
            HStack {
                Button("Propose") { Task { await teach(approve: false) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pa.knowledge.propose")
                Spacer()
                if canApproveNow {
                    Button("Teach now") { Task { await teach(approve: true) } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("pa.knowledge.teachNow")
                }
            }
            .disabled(statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || teaching)
        } header: {
            Text("Teach the PA a rule")
        } footer: {
            Text("“Teach now” puts it in use straight away: managers for company and team rules, anyone for their own. A proposed rule waits for approval.")
        }
    }

    // MARK: Waiting

    @ViewBuilder
    private var pendingSection: some View {
        if let pendingError {
            Section("Waiting for approval") { InlineErrorRow(error: pendingError) { Task { await load() } } }
        } else if !pending.isEmpty {
            Section("Waiting for approval (\(pending.count))") {
                ForEach(pending) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title ?? Formatters.humanize(item.key)).font(.wsHeadline)
                            Spacer()
                            if item.proposedByAi == true { Pill(text: "From the PA", systemImage: "sparkles") }
                        }
                        Text("v\(item.version ?? 1) · \(PAText.scope(item.scope))").font(.wsCaption).foregroundStyle(.secondaryText)
                        if let rule = item.rule { Text(rule).font(.wsSubheadline) }
                        if !item.triggers.isEmpty {
                            Text("When: \(item.triggers.joined(separator: ", "))").font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                        if isManager || item.scope == "personal" {
                            HStack {
                                Button {
                                    Task { await decide(item, approve: true) }
                                } label: { Label("Approve", systemImage: "checkmark") }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("pa.knowledge.approve.\(item.id)")
                                Button {
                                    Task { await decide(item, approve: false) }
                                } label: { Label("Reject", systemImage: "xmark") }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("pa.knowledge.reject.\(item.id)")
                            }
                            .disabled(deciding != nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: In use

    @ViewBuilder
    private var rulesSection: some View {
        switch rules {
        case .idle, .loading:
            Section { SkeletonRow(); SkeletonRow() }
        case .failed(let error):
            Section { InlineErrorRow(error: error) { Task { await load() } } }
        case .loaded(let items) where items.isEmpty:
            Section {
                ContentUnavailableView(search.isEmpty ? "No rules yet" : "No results", systemImage: "book.closed",
                                       description: Text(search.isEmpty ? "Teach the PA a rule above." : "Nothing matches “\(search)”."))
                    .listRowBackground(Color.clear)
            }
        case .loaded(let items):
            Section("In use (\(items.count))") {
                ForEach(items) { item in
                    NavigationLink(value: NativeScreenRoute("pa.rule", item.uuid)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title ?? Formatters.humanize(item.key)).font(.wsHeadline)
                            Text(item.caption).font(.wsCaption).foregroundStyle(.secondaryText)
                            if let rule = item.rule { Text(rule).font(.wsSubheadline).lineLimit(4) }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("pa.knowledge.rule.\(item.uuid)")
                }
            }
        }
    }

    // MARK: Work

    private func load() async {
        if rules.value == nil { rules = .loading }
        async let waiting = services.propertyPA.pendingKnowledge()
        do {
            rules = .loaded(try await services.propertyPA.knowledge(search: search))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if rules.value == nil { rules = .failed(apiError) }
        }
        do {
            pending = try await waiting
            pendingError = nil
        } catch {
            pendingError = error.asAPIError
        }
    }

    private func teach(approve: Bool) async {
        teaching = true
        defer { teaching = false }
        do {
            let body = PATeachRuleBody(statement: statement.trimmingCharacters(in: .whitespacesAndNewlines),
                                       title: title.trimmedOrNil, scope: scope,
                                       triggers: PATeachRuleBody.triggers(from: triggers), approve: approve && canApproveNow)
            let status = try await services.propertyPA.teachRule(body)
            notice = status == "approved" ? "Taught. The PA uses it from now on." : "Proposed. It's used once it's approved."
            actionError = nil
            statement = ""
            title = ""
            triggers = ""
            await load()
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }

    private func decide(_ item: PAPendingKnowledge, approve: Bool) async {
        deciding = item.id
        defer { deciding = nil }
        do {
            try await services.propertyPA.decideKnowledge(item.uuid, version: item.version ?? 1, approve: approve)
            notice = approve ? "Approved: \(item.title ?? "the rule") is in use." : "Rejected: \(item.title ?? "the rule") won't be used."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }
}

/// One rule: the version in use, every earlier one, and retiring it (history kept).
struct PAKnowledgeDetailView: View {
    let uuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<PAKnowledgeItem> = .idle
    @State private var confirmingRetire = false
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList()
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let item): content(item)
            }
        }
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("Retire this rule?", isPresented: $confirmingRetire, titleVisibility: .visible) {
            Button("Retire", role: .destructive) { Task { await retire() } }
        } message: {
            Text("The PA stops using it. Its versions stay readable.")
        }
    }

    private func content(_ item: PAKnowledgeItem) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title ?? Formatters.humanize(item.key)).font(.wsTitle3.bold()).accessibilityAddTraits(.isHeader)
                    Text(item.caption).font(.wsSubheadline).foregroundStyle(.secondaryText)
                    StatusBadge(text: Formatters.humanize(item.status), systemImage: item.status == "approved" ? "checkmark.seal" : "circle",
                                tone: item.status == "approved" ? .success : .neutral)
                }
                .padding(.vertical, 4)
                if let rule = item.rule { Text(rule).font(.wsBody).textSelection(.enabled) }
                if let rationale = item.rationale {
                    Text("Why: \(rationale)").font(.wsSubheadline).foregroundStyle(.secondaryText)
                }
            }
            if let notice {
                Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            if !item.versions.isEmpty {
                Section("Versions") {
                    ForEach(item.versions) { version in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Version \(version.version ?? 0)").font(.wsHeadline)
                                Spacer()
                                Text(Formatters.humanize(version.status)).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                            if let title = version.title { Text(title).font(.wsSubheadline.weight(.semibold)) }
                            if let rule = version.rule { Text(rule).font(.wsSubheadline) }
                            let when = [version.proposedByAi == true ? "Proposed by the PA" : nil,
                                        version.createdAt.flatMap { Formatters.dateTime($0) }.map { "Proposed \($0)" },
                                        version.approvedAt.flatMap { Formatters.dateTime($0) }.map { "Decided \($0)" }]
                                .compactMap { $0 }
                            if !when.isEmpty {
                                Text(when.joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if item.status != "retired", canRetire(item) {
                Section {
                    Button(role: .destructive) { confirmingRetire = true } label: {
                        Label("Retire this rule", systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("pa.rule.retire")
                }
            }
        }
        .refreshable { await load() }
    }

    /// The server's rule: your own personal rules, or company and team rules as a manager.
    private func canRetire(_ item: PAKnowledgeItem) -> Bool {
        item.scope == "personal" ? item.ownerUserUuid == session.user?.uuid : session.permissions.paIsManager
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do { state = .loaded(try await services.propertyPA.knowledgeItem(uuid)) } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) }
        }
    }

    private func retire() async {
        do {
            try await services.propertyPA.retireKnowledge(uuid)
            notice = "Retired. The PA no longer uses it."
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }
}
