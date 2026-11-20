import SwiftUI
import UIKit

// MARK: - What happened after an action

/// The line under the navigation bar that says what an action did (or why it failed).
struct AINotice: Equatable, Sendable {
    var text: String
    var isError = false

    static func done(_ text: String) -> AINotice { AINotice(text: text) }
    static func failed(_ error: Error) -> AINotice { AINotice(text: AIErrors.message(error), isError: true) }
}

extension View {
    /// Shows `notice` above the content; tapping it clears it.
    func aiNotice(_ notice: Binding<AINotice?>) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if let current = notice.wrappedValue {
                Button {
                    notice.wrappedValue = nil
                } label: {
                    Label(current.text, systemImage: current.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.wsSubheadline)
                        .foregroundStyle(current.isError ? Tone.danger.textColor : Tone.success.textColor)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("airunner.notice")
                .accessibilityHint("Double tap to dismiss")
            }
        }
    }
}

enum AIErrors {
    /// A message a person can act on, as the web's `aiError`.
    static func message(_ error: Error) -> String {
        let api = error.asAPIError
        if case .forbidden(let e) = api, e.message.range(of: "use this runner", options: .caseInsensitive) != nil {
            return "You can't use this runner. Choose another one, or ask an AI-run manager to give you access to it "
                + "(Runners → Access)."
        }
        if isSwitchedOff(api) { return "\(AIFormat.product) is switched off for this workspace." }
        return api.localizedDescription
    }

    /// Every plugin route answers 404 (`PLUGIN_DISABLED`, or no route) when the plugin is off here.
    static func isSwitchedOff(_ error: APIError) -> Bool {
        guard case .notFound(let e) = error else { return false }
        return e.code == "PLUGIN_DISABLED" || e.rawBody.contains("PLUGIN_DISABLED")
            || e.message.range(of: "turned off", options: .caseInsensitive) != nil
    }
}

/// A screen's failure: the plugin switched off, no access, or what went wrong with a retry.
struct AILoadFailure: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        if AIErrors.isSwitchedOff(error) {
            ContentUnavailableView {
                Label("\(AIFormat.product) is switched off", systemImage: "power")
            } description: {
                Text("A workspace admin switches it on under Workspace → Plugins.")
            } actions: {
                Button("Try again", action: retry).buttonStyle(.bordered)
            }
        } else if case .forbidden = error {
            AINoAccess()
        } else {
            ErrorStateView(error: error, retry: retry)
        }
    }
}

/// The page needs an AI Runs role the person doesn't have.
struct AINoAccess: View {
    var what = "this page"

    var body: some View {
        ContentUnavailableView {
            Label("No access", systemImage: "lock")
        } description: {
            Text("You don't have access to \(what). Ask a workspace admin for an \(AIFormat.product) role.")
        }
        .accessibilityIdentifier("airunner.noAccess")
    }
}

extension PermissionSet {
    /// Any grant at all on an AI Runs module (the web's `canAccess`).
    func aiAny(_ module: String) -> Bool {
        isAdmin || isOwner || !(grants[module] ?? []).isEmpty
    }

    func ai(_ action: Action, _ module: String) -> Bool { can(action, moduleName: module) }

    /// The overview numbers are for AI-run, runner and approval managers.
    var aiSeesOverview: Bool {
        ai(.manage, "ai_runs") || ai(.manage, "ai_runners") || ai(.manage, "ai_runs_approvals")
    }
}

// MARK: - Pieces

/// A status pill for a run, a runner or a request.
struct AIStatusBadge: View {
    let value: String
    var style: StatusStyle = AIRunStatus.style

    var body: some View {
        StatusBadge(text: style.label(for: value), systemImage: style.symbol(for: value), tone: style.tone(for: value))
    }
}

/// Text to paste somewhere else (a token, a config file, a command) with Copy and Share.
struct AICopyBlock: View {
    let text: String
    let what: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 16) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                } label: {
                    Label(copied ? "\(what) copied" : "Copy \(what.lowercased())",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("airunner.copy.\(what.lowercased())")
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
            }
            .font(.wsSubheadline)
        }
        .padding(.vertical, 4)
    }
}

/// A list of short values (globs, tool names, statuses, patterns) inside a Form: each one a row that
/// swipes away, then a field that adds what was typed. `check` says why a value can't be added.
struct AITagsSection: View {
    let title: String
    @Binding var values: [String]
    var placeholder = ""
    var help: String?
    var monospaced = true
    var check: ((String) -> String?)?
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                HStack {
                    Text(value).font(monospaced ? .system(.body, design: .monospaced) : .wsBody)
                    Spacer()
                    Button {
                        values.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondaryText)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(value)")
                }
            }
            HStack {
                TextField(placeholder.isEmpty ? "Add" : placeholder, text: $draft)
                    .font(monospaced ? .system(.body, design: .monospaced) : .wsBody)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .accessibilityLabel("Add to \(title)")
                Button("Add", action: add)
                    .disabled(draft.trimmedOrNil == nil)
                    .buttonStyle(.borderless)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.wsFootnote)
                    .foregroundStyle(Tone.danger.textColor)
            }
        } header: {
            Text(title)
        } footer: {
            if let help { Text(help) }
        }
    }

    private func add() {
        guard let value = draft.trimmedOrNil else { return }
        if let reason = check?(value) { problem = reason; return }
        problem = nil
        if !values.contains(value) { values.append(value) }
        draft = ""
    }
}

/// A row that opens a checklist of choices (people, projects, runners) and shows how many are picked.
struct AIChecklistRow: View {
    let title: String
    let choices: [AIChoice]
    @Binding var picked: [String]
    var loading = false
    var failure: String?
    var help: String?

    var body: some View {
        NavigationLink {
            AIChecklist(title: title, choices: choices, picked: $picked, loading: loading, failure: failure, help: help)
        } label: {
            LabeledContent(title) {
                Text(picked.isEmpty ? "None" : "\(picked.count) picked").foregroundStyle(.secondaryText)
            }
        }
        .accessibilityIdentifier("airunner.checklist.\(title.lowercased())")
    }
}

struct AIChecklist: View {
    let title: String
    let choices: [AIChoice]
    @Binding var picked: [String]
    var loading = false
    var failure: String?
    var help: String?
    @State private var search = ""

    var body: some View {
        List {
            if let failure { Text(failure).foregroundStyle(Tone.danger.textColor) }
            if loading && choices.isEmpty { ProgressView() }
            if let help { Text(help).font(.wsFootnote).foregroundStyle(.secondaryText) }
            ForEach(shown) { choice in
                Button {
                    if picked.contains(choice.value) { picked.removeAll { $0 == choice.value } } else { picked.append(choice.value) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.label).foregroundStyle(.primary)
                            if let hint = choice.hint { Text(hint).font(.wsFootnote).foregroundStyle(.secondaryText) }
                        }
                        Spacer()
                        if picked.contains(choice.value) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .accessibilityAddTraits(picked.contains(choice.value) ? .isSelected : [])
            }
            // Picked earlier but no longer offered (a removed person, a project the caller can't see): kept.
            let unknown = picked.filter { id in !choices.contains { $0.value == id } }
            if !unknown.isEmpty, !loading {
                Section("Also picked") {
                    ForEach(unknown, id: \.self) { id in
                        Button(role: .destructive) { picked.removeAll { $0 == id } } label: {
                            Label("Someone or something you can't see — remove", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !picked.isEmpty {
                ToolbarItem(placement: .primaryAction) { Button("Clear") { picked = [] } }
            }
        }
    }

    private var shown: [AIChoice] {
        guard let q = search.trimmedOrNil?.lowercased() else { return choices }
        return choices.filter { $0.label.lowercased().contains(q) || ($0.hint?.lowercased().contains(q) ?? false) }
    }
}

/// The workspace's kanban projects and members, loaded once for a form's pickers.
@MainActor
@Observable
final class AIPickerData {
    var projects: [AIChoice] = []
    var members: [AIChoice] = []
    var projectsLoading = true
    var membersLoading = true
    var projectsFailed = false
    var membersFailed = false

    func load(_ services: Services) async {
        async let projectsTask = services.kanban.projects(search: "", filter: KanbanAPI.ProjectFilter(), page: 1, perPage: 200)
        async let membersTask = AIRunnerAPI(client: services.client).members()
        do {
            projects = try await projectsTask.items.map { AIChoice(value: $0.uuid, label: $0.name) }
        } catch {
            projectsFailed = true
        }
        projectsLoading = false
        do {
            members = try await membersTask
        } catch {
            membersFailed = true
        }
        membersLoading = false
    }

    func projectName(_ uuid: String?) -> String {
        guard let uuid else { return "no project" }
        return projects.first { $0.value == uuid }?.label ?? "a project you can't see"
    }
}

/// A project picker that keeps a saved project the caller can't see rather than losing it.
struct AIProjectPicker: View {
    var label = "Project"
    @Binding var projectUuid: String?
    let data: AIPickerData
    var required = false

    var body: some View {
        Picker(required ? "\(label) (needed)" : label, selection: Binding(
            get: { projectUuid ?? "" }, set: { projectUuid = $0.isEmpty ? nil : $0 })) {
            Text(data.projectsLoading ? "Loading projects…" : "Choose a project").tag("")
            ForEach(data.projects) { Text($0.label).tag($0.value) }
            if let projectUuid, !data.projectsLoading, !data.projects.contains(where: { $0.value == projectUuid }) {
                Text("Current project").tag(projectUuid)
            }
        }
        .accessibilityIdentifier("airunner.project")
    }
}

/// A column of the project's first board, or typed in when the columns can't be read. Empty = the first column.
struct AIColumnPicker: View {
    let projectUuid: String?
    @Binding var column: String?
    var emptyLabel = "First column"
    @Environment(\.services) private var services
    @State private var names: [String] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if names.isEmpty {
                LabeledContent("Column") {
                    TextField(emptyLabel, text: Binding(get: { column ?? "" },
                                                        set: { column = $0.trimmedOrNil == nil ? nil : $0 }))
                        .multilineTextAlignment(.trailing)
                }
            } else {
                Picker("Column", selection: Binding(get: { column ?? "" }, set: { column = $0.isEmpty ? nil : $0 })) {
                    Text(emptyLabel).tag("")
                    ForEach(names, id: \.self) { Text($0).tag($0) }
                    if let column, !names.contains(column) { Text(column).tag(column) }
                }
            }
        }
        .task(id: projectUuid) { await load() }
        .accessibilityIdentifier("airunner.column")
    }

    private func load() async {
        names = []
        guard let projectUuid else { return }
        do {
            guard let board = try await services.kanban.boards(projectUuid: projectUuid).first else { return }
            let full = try await services.kanban.boardWithColumns(board.uuid)
            names = (full.columns ?? []).map(\.name)
        } catch {
            names = []
        }
    }
}

/// A whole number typed into a form, kept as text so an emptied field stays empty until saved.
struct AINumberField: View {
    let label: String
    @Binding var value: String
    var range: ClosedRange<Double>?
    var help: String?
    var decimal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                TextField(range.map { "\(AINumbers.text($0.lowerBound))–\(AINumbers.text($0.upperBound))" } ?? "", text: $value)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(decimal ? .decimalPad : .numberPad)
            } label: {
                Text(label)
            }
            if let help { Text(help).font(.wsFootnote).foregroundStyle(.secondaryText) }
            if let problem { Text(problem).font(.wsFootnote).foregroundStyle(Tone.danger.textColor) }
        }
        .accessibilityIdentifier("airunner.number.\(label)")
    }

    var problem: String? { AINumbers.problem(label, value, range: range, decimal: decimal) }

    static func text(_ n: Double) -> String { AINumbers.text(n) }
}

/// Checks a number typed into a form (kept apart from the views so plain values can use it).
enum AINumbers {
    static func problem(_ label: String, _ value: String, range: ClosedRange<Double>?, decimal: Bool = false) -> String? {
        guard let text = value.trimmedOrNil else { return "\(label) is needed." }
        guard let n = Double(text), decimal || n.rounded() == n else {
            return decimal ? "\(label) must be a number." : "\(label) must be a whole number."
        }
        if let range, !range.contains(n) { return "\(label): \(Self.text(range.lowerBound))–\(Self.text(range.upperBound))." }
        return nil
    }

    static func text(_ n: Double) -> String {
        n.rounded() == n ? Int(n).formatted() : n.formatted()
    }
}
