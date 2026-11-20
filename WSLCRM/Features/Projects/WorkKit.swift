import SwiftUI

// Small shared pieces for the project, task and timesheet screens.

// MARK: - Colours the server stores as hex

extension Color {
    /// `#RRGGBB` (or `RRGGBB`) as the API stores project, column, label and epic colours.
    init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

enum WorkPalette {
    /// The web's project colours.
    static let projects = ["#ef4444", "#f97316", "#f59e0b", "#eab308", "#84cc16", "#22c55e", "#10b981", "#14b8a6",
                           "#06b6d4", "#0ea5e9", "#3b82f6", "#6366f1", "#8b5cf6", "#a855f7", "#d946ef", "#ec4899",
                           "#f43f5e", "#6b7280", "#78716c", "#71717a"]
    /// The web's label and column colours.
    static let labels = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#3b82f6", "#8b5cf6", "#ec4899",
                         "#6b7280", "#1f2937"]
    /// The web's epic colours.
    static let epics = ["#7C3AED", "#2563EB", "#059669", "#D97706", "#DC2626", "#DB2777", "#0891B2", "#4B5563"]

    static func name(_ hex: String) -> String {
        let names = ["#ef4444": "Red", "#f97316": "Orange", "#f59e0b": "Amber", "#eab308": "Yellow", "#84cc16": "Lime",
                     "#22c55e": "Green", "#10b981": "Emerald", "#14b8a6": "Teal", "#06b6d4": "Cyan", "#0ea5e9": "Sky",
                     "#3b82f6": "Blue", "#6366f1": "Indigo", "#8b5cf6": "Violet", "#a855f7": "Purple",
                     "#d946ef": "Fuchsia", "#ec4899": "Pink", "#f43f5e": "Rose", "#6b7280": "Grey", "#78716c": "Stone",
                     "#71717a": "Zinc", "#1f2937": "Charcoal", "#7c3aed": "Violet", "#2563eb": "Blue",
                     "#059669": "Green", "#d97706": "Amber", "#dc2626": "Red", "#db2777": "Pink", "#0891b2": "Cyan",
                     "#4b5563": "Grey"]
        return names[hex.lowercased()] ?? hex
    }
}

/// A row of colour circles; the chosen one carries a tick so it isn't told by colour alone.
struct ColorSwatchPicker: View {
    let colors: [String]
    @Binding var selection: String
    var identifier = "color"

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(colors, id: \.self) { hex in
                    Button {
                        selection = hex
                    } label: {
                        Circle()
                            .fill(Color(hexString: hex) ?? .gray)
                            .frame(width: 34, height: 34)
                            .overlay {
                                if selection.lowercased() == hex.lowercased() {
                                    Image(systemName: "checkmark").font(.wsCaption.weight(.bold)).foregroundStyle(.white)
                                }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(WorkPalette.name(hex))
                    .accessibilityAddTraits(selection.lowercased() == hex.lowercased() ? [.isSelected] : [])
                    .accessibilityIdentifier("\(identifier).\(hex)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// A coloured chip with its name (labels, epics).
struct TagChip: View {
    let name: String
    let color: String?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Circle().fill(Color(hexString: color) ?? .secondary).frame(width: 8, height: 8)
            Text(name).lineLimit(1)
        }
        .font(.wsCaption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((Color(hexString: color) ?? .secondary).opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// Initials in a circle.
struct InitialsAvatar: View {
    let text: String
    var size: CGFloat = 26

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.tile(for: text), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Saying what happened

/// A short line confirming what just happened, shown at the bottom and read out by VoiceOver.
struct WorkNotice: Equatable, Identifiable {
    let id = UUID()
    let text: String
    var isError = false

    static func done(_ text: String) -> WorkNotice { WorkNotice(text: text) }
    static func failed(_ text: String) -> WorkNotice { WorkNotice(text: text, isError: true) }
}

private struct WorkNoticeOverlay: ViewModifier {
    @Binding var notice: WorkNotice?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let notice {
                Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.wsSubheadline.weight(.semibold))
                    .foregroundStyle(notice.isError ? Tone.danger.textColor : Tone.success.textColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder((notice.isError ? Tone.danger : Tone.success).color.opacity(0.4)))
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("work.notice")
                    .onTapGesture { self.notice = nil }
                    .task(id: notice.id) {
                        AccessibilityNotification.Announcement(notice.text).post()
                        try? await Task.sleep(for: .seconds(notice.isError ? 6 : 3))
                        withAnimation { if self.notice?.id == notice.id { self.notice = nil } }
                    }
            }
        }
        .animation(.default, value: notice)
    }
}

extension View {
    /// Shows `notice` briefly at the bottom of the screen.
    func workNotice(_ notice: Binding<WorkNotice?>) -> some View {
        modifier(WorkNoticeOverlay(notice: notice))
    }
}

// MARK: - Who may do what in a project

/// The server's project rules (`KanbanProjectQueries.isEditor/isAdmin/isOwner`): a project role, or
/// being the workspace owner, a platform admin, or holding `projects.manage`.
struct ProjectAccess: Sendable, Equatable {
    var role: KanbanMemberRole?
    var workspacePrivileged: Bool
    var canDeleteProjects: Bool

    static let none = ProjectAccess(role: nil, workspacePrivileged: false, canDeleteProjects: false)

    @MainActor
    init(project: KanbanProject?, session: SessionStore) {
        let permissions = session.permissions
        role = project?.role
        workspacePrivileged = permissions.isOwner || permissions.isAdmin
            || (session.user?.isPlatformAdmin ?? false)
            || (permissions.grants["projects"]?.contains("manage") ?? false)
        canDeleteProjects = permissions.can(.delete, .projects)
    }

    init(role: KanbanMemberRole?, workspacePrivileged: Bool, canDeleteProjects: Bool) {
        self.role = role
        self.workspacePrivileged = workspacePrivileged
        self.canDeleteProjects = canDeleteProjects
    }

    /// Create, move, edit and delete cards; comments, checklists, attachments, sprints' cards.
    var canEdit: Bool { workspacePrivileged || [.owner, .admin, .member].contains(role) }
    /// Boards, columns, labels, epics, sprints, members and project settings.
    var canAdmin: Bool { workspacePrivileged || [.owner, .admin].contains(role) }
    /// Only the project's owner may delete (archive) it — workspace rights don't count here.
    var canDeleteProject: Bool { role == .owner && canDeleteProjects }
    /// Anything to show at all.
    var canRead: Bool { workspacePrivileged || role != nil }
}

// MARK: - Dates

extension Date {
    /// "12 Nov" or "12 Nov 2027" when it isn't this year.
    var shortDay: String {
        let sameYear = Calendar.current.isDate(self, equalTo: Date(), toGranularity: .year)
        return formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Asking before, and asking for a word

/// A destructive or important step waiting for the person to confirm it.
struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    var message: String?
    let button: String
    var destructive = true
    let action: @MainActor () async -> Void
}

/// A single line of text the person is asked for (a checklist's name, a subtask's title…).
struct PendingPrompt: Identifiable {
    let id = UUID()
    let title: String
    var message: String?
    let placeholder: String
    let button: String
    var initial = ""
    let action: @MainActor (String) async -> Void
}

private struct ConfirmationModifier: ViewModifier {
    @Binding var pending: PendingConfirmation?

    func body(content: Content) -> some View {
        content.confirmationDialog(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { item in
            Button(item.button, role: item.destructive ? .destructive : nil) { Task { await item.action() } }
        } message: { item in
            if let message = item.message { Text(message) }
        }
    }
}

private struct PromptModifier: ViewModifier {
    @Binding var pending: PendingPrompt?
    @State private var text = ""

    func body(content: Content) -> some View {
        content.alert(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { item in
            TextField(item.placeholder, text: $text)
                .accessibilityIdentifier("work.prompt.field")
            Button("Cancel", role: .cancel) {}
            Button(item.button) {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                Task { await item.action(value) }
            }
        } message: { item in
            if let message = item.message { Text(message) }
        }
        .onChange(of: pending?.id) { _, _ in text = pending?.initial ?? "" }
    }
}

extension View {
    func workConfirmation(_ pending: Binding<PendingConfirmation?>) -> some View {
        modifier(ConfirmationModifier(pending: pending))
    }

    func workPrompt(_ pending: Binding<PendingPrompt?>) -> some View {
        modifier(PromptModifier(pending: pending))
    }
}

// MARK: - Opening files natively

/// Downloads a file to the phone so Quick Look can show it (no browser involved).
enum FileFetcher {
    static func download(_ link: String, named name: String, base: URL?) async throws -> URL {
        guard let url = URL(string: link, relativeTo: link.hasPrefix("/") ? base : nil)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { throw URLError(.badURL) }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.fileDoesNotExist)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var filename = name.replacingOccurrences(of: "/", with: "-")
        if (filename as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty {
            filename += ".\(url.pathExtension)"
        }
        let destination = folder.appendingPathComponent(filename)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
