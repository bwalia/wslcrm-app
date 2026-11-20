import SwiftUI

/// A workspace member who can be put on a renovation board (a builder or site manager).
struct PDTeamMember: Identifiable, Hashable, Sendable {
    let uuid: String
    let name: String
    var id: String { uuid }

    /// `GET /api/v2/namespace/members` rows: `{ uuid, status, user: { uuid, first_name, last_name, email } }`.
    static func from(_ rows: [Record]) -> [PDTeamMember] {
        rows.compactMap { row in
            guard let uuid = row.string("user.uuid") ?? row.string("user_uuid") else { return nil }
            let full = [row.string("user.first_name"), row.string("user.last_name")].compactMap { $0 }.joined(separator: " ")
            return PDTeamMember(uuid: uuid, name: full.trimmedOrNil ?? row.string("user.email") ?? "Team member")
        }
    }
}

extension PDRaw {
    /// Active workspace members (needs `users.read`).
    func activeMembers() async throws -> [PDTeamMember] {
        PDTeamMember.from(try await rows("/api/v2/namespace/members", ["per_page": "100", "status": "active"]))
    }
}

/// Tick the people who work the board. Loads the team; says so plainly if it can't.
struct PDBuilderPicker: View {
    @Binding var selected: Set<String>
    /// Already on the board: shown ticked and not changeable.
    var existing: Set<String> = []
    @Environment(\.services) private var services
    @State private var state: LoadState<[PDTeamMember]> = .idle

    var body: some View {
        switch state {
        case .idle, .loading:
            SkeletonRow().task { await load() }
        case .failed:
            Text("The team couldn’t be loaded (you may not be allowed to see the members list). Ask a workspace admin to add builders to the board.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
        case .loaded(let members):
            if members.isEmpty {
                Text("No active members in this workspace yet.").font(.wsFootnote).foregroundStyle(.secondaryText)
            }
            ForEach(members) { member in
                let already = existing.contains(member.uuid)
                Button {
                    if selected.contains(member.uuid) { selected.remove(member.uuid) } else { selected.insert(member.uuid) }
                } label: {
                    HStack {
                        Text(member.name).foregroundStyle(.primary)
                        Spacer()
                        if already {
                            Text("On the board").font(.wsCaption).foregroundStyle(.secondaryText)
                        } else if selected.contains(member.uuid) {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .frame(minHeight: 44)
                .disabled(already)
                .accessibilityAddTraits(selected.contains(member.uuid) || already ? .isSelected : [])
                .accessibilityIdentifier("pd.builders.member.\(member.uuid)")
            }
        }
    }

    private func load() async {
        do {
            state = .loaded(try await services.pdRaw.activeMembers())
        } catch {
            state = .failed(error.asAPIError)
        }
    }
}

/// Adds builders and site managers to a renovation's board after it was started
/// (`POST /api/v2/kanban/projects/{uuid}/members`, needs `projects.manage` and board admin).
struct PDAddBuildersSheet: View {
    let renovation: PDRenovation
    let onAdded: (Int) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var existing: Set<String> = []
    @State private var saving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { InlineErrorRow(error: error) } }
                Section {
                    PDBuilderPicker(selected: $selected, existing: existing)
                } header: {
                    Text("Builders and site managers")
                } footer: {
                    Text("They can see the board in Projects and work its jobs.")
                }
            }
            .navigationTitle("Add builders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(saving || selected.isEmpty)
                        .accessibilityIdentifier("pd.builders.add")
                }
            }
            .task {
                if let project = renovation.projectUuid,
                   let members = try? await services.kanban.members(projectUuid: project) {
                    existing = Set(members.map(\.userUuid))
                }
            }
        }
    }

    private func save() async {
        guard let project = renovation.projectUuid else {
            error = ResourceService.problem(404, "This renovation has no board.")
            return
        }
        saving = true
        defer { saving = false }
        var added = 0
        for uuid in selected.sorted() {
            do {
                try await services.pdRaw.send(.post, "/api/v2/kanban/projects/\(project)/members",
                                              Self.body(userUuid: uuid))
                added += 1
            } catch {
                self.error = error.asAPIError
                if added > 0 { onAdded(added) }
                return
            }
        }
        onAdded(added)
        dismiss()
    }

    static func body(userUuid: String) -> [String: JSONValue] {
        ["user_uuid": .string(userUuid), "role": .string("member")]
    }
}
