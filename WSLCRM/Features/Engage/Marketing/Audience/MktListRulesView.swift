import SwiftUI

/// A smart list's rules: contacts that match are put in the list for the person, and it updates
/// itself before every email. Count the matches, save the rules (which fills the list), or update now.
struct MktListRulesView: View {
    let list: MktListSummary
    /// Called with how many people are in the list after saving or updating.
    let onSaved: (Int) -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var rule: MktSegmentRule
    @State private var fields: [String] = []
    @State private var ops: [String] = []
    @State private var optionsError: APIError?
    @State private var problem: String?
    @State private var notice: EngageNotice?
    @State private var busy: Busy?
    @State private var matches: (total: Int, sample: [Record])?

    enum Busy { case count, save, sync }

    init(list: MktListSummary, onSaved: @escaping (Int) -> Void) {
        self.list = list
        self.onSaved = onSaved
        _rule = State(initialValue: MktSegmentRule(stored: list.segmentRule))
    }

    private var api: MktAudienceAPI { MktAudienceAPI(services) }
    private var canEdit: Bool { session.permissions.can(.update, moduleName: Marketing.RBAC.lists) }

    var body: some View {
        Form {
            Section {
                EngageIntro(text: "Contacts that match these rules are put in the list for you, and it updates itself "
                            + "before every email.")
            }
            if let optionsError {
                Section { InlineErrorRow(error: optionsError) { Task { await loadOptions() } } }
            }
            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tone.danger.textColor)
                }
            }
            Section {
                Picker("Include contacts that match", selection: $rule.matchAny) {
                    Text("all of the rules").tag(false)
                    Text("any rule").tag(true)
                }
                .disabled(!canEdit)
                .accessibilityIdentifier("mkt.rules.match")
            }
            if rule.conditions.isEmpty {
                Section { Text("No rules yet — press “Add a rule”.").foregroundStyle(.secondaryText) }
            }
            ForEach($rule.conditions) { $condition in
                Section {
                    Picker("Field", selection: $condition.field) {
                        ForEach(fieldChoices(condition.field), id: \.self) { Text(MktSegmentRule.fieldLabel($0)).tag($0) }
                    }
                    .accessibilityIdentifier("mkt.rules.field")
                    Picker("Rule", selection: $condition.op) {
                        ForEach(opChoices(condition.op), id: \.self) { Text(MktSegmentRule.opLabel($0)).tag($0) }
                    }
                    .accessibilityIdentifier("mkt.rules.op")
                    if condition.needsValue {
                        TextField("Value, e.g. Acme Ltd", text: $condition.value)
                            .accessibilityIdentifier("mkt.rules.value")
                    }
                    if canEdit {
                        Button(role: .destructive) {
                            rule.conditions.removeAll { $0.id == condition.id }
                            matches = nil
                        } label: {
                            Label("Remove this rule", systemImage: "minus.circle")
                        }
                    }
                }
                .disabled(!canEdit)
            }
            Section {
                if canEdit {
                    Button {
                        rule.conditions.append(MktSegmentCondition(field: fields.first ?? "email",
                                                                   op: ops.contains("contains") ? "contains" : (ops.first ?? "contains"),
                                                                   value: ""))
                        matches = nil
                    } label: {
                        Label("Add a rule", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("mkt.rules.add")
                }
                Button {
                    Task { await run(.count) }
                } label: {
                    HStack {
                        Label("How many match?", systemImage: "number")
                        if busy == .count { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy != nil)
                .accessibilityIdentifier("mkt.rules.count")
                if let matches {
                    Text("\(MktAudienceText.people(matches.total)) match")
                        .font(.wsHeadline)
                        .accessibilityIdentifier("mkt.rules.matches")
                    ForEach(matches.sample) { contact in
                        let name = [contact.string("first_name"), contact.string("last_name")].compactMap { $0 }
                            .joined(separator: " ")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name.isEmpty ? (contact.string("email") ?? "—") : name)
                            if !name.isEmpty, let email = contact.string("email") {
                                Text(email).font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                }
            } footer: {
                if let matches, matches.total > matches.sample.count, !matches.sample.isEmpty {
                    Text("Showing the first \(matches.sample.count).")
                }
            }
            if canEdit {
                Section {
                    Button {
                        Task { await run(.save) }
                    } label: {
                        HStack {
                            if busy == .save { ProgressView() }
                            Text("Save rules").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("mkt.rules.save")
                    Button {
                        Task { await run(.sync) }
                    } label: {
                        Label("Update now", systemImage: "arrow.clockwise")
                    }
                    .disabled(busy != nil)
                    .accessibilityIdentifier("mkt.rules.sync")
                } footer: {
                    Text("Saving fills the list straight away. “Update now” refills it from the saved rules.")
                }
            } else {
                Section {
                    Text("Your role can see the rules but not change them.").foregroundStyle(.secondaryText)
                }
            }
        }
        .navigationTitle("Smart list rules")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .task { await loadOptions() }
        .onChange(of: rule) { _, _ in problem = nil }
    }

    /// The server's fields, plus the condition's own when it isn't one of them (an older rule).
    private func fieldChoices(_ current: String) -> [String] {
        fields.contains(current) || current.isEmpty ? (fields.isEmpty ? [current] : fields) : [current] + fields
    }

    private func opChoices(_ current: String) -> [String] {
        let known = ops.isEmpty ? Array(MktSegmentRule.opLabels.keys).sorted() : ops
        return known.contains(current) ? known : [current] + known
    }

    private func loadOptions() async {
        do {
            let options = try await api.segmentOptions()
            fields = options.fields
            ops = options.ops
            optionsError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            optionsError = apiError
        }
    }

    private func run(_ kind: Busy) async {
        if kind != .sync, let reason = rule.problem {
            problem = reason
            return
        }
        busy = kind
        defer { busy = nil }
        do {
            switch kind {
            case .count:
                matches = try await api.previewSegment(rule)
                notice = nil
            case .save:
                let count = try await api.saveSegment(list: list.uuid, rule: rule)
                notice = .done("Saved — \(MktAudienceText.people(count)) in the list.")
                onSaved(count)
            case .sync:
                let count = try await api.syncList(list.uuid)
                notice = .done("Updated — \(MktAudienceText.people(count)) in the list.")
                onSaved(count)
            }
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}
