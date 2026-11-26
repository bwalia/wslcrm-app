import SwiftUI

/// "My to-dos": every to-do given to me on a customer or a lead, open ones first by due day.
/// Tick one off here; tap it to open the customer or lead it's on. Reached from Home's panel and from
/// the Customers and Leads screens (screen id `crm.my_todos`, `ModuleGroup+CRM.swift`).
struct MyTodosView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var model = MyTodosModel()

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                SkeletonList(rows: 4)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load(services.recordNotes) } }
            case .loaded(let todos):
                list(todos)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $model.status) {
                ForEach(RecordNotesAPI.TodoStatus.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("myTodos.status")
        }
        .navigationTitle("My to-dos")
        .task(id: model.status) { await model.load(services.recordNotes) }
        .wsRefreshable { await model.load(services.recordNotes) }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.notice = nil
        }
    }

    private func list(_ todos: [RecordNote]) -> some View {
        List {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
            }
            if let error = model.error {
                InlineErrorRow(error: error) { Task { await model.load(services.recordNotes) } }
            }
            if todos.isEmpty {
                ContentUnavailableView {
                    Label(model.status == .done ? "Nothing done yet" : "Nothing to do", systemImage: "checklist")
                } description: {
                    Text(model.status == .done
                         ? "To-dos you tick off on customers and leads show here."
                         : "When someone gives you a to-do on a customer or a lead, it shows here.")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(todos) { todo in
                MyTodoRow(todo: todo, myUUID: session.user?.uuid) {
                    Task { await model.setDone(todo, !todo.done, api: services.recordNotes) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// One of my to-dos: the tick box, the words, which customer or lead it's on, and when it's due.
struct MyTodoRow: View {
    let todo: RecordNote
    let myUUID: String?
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NoteDoneButton(note: todo, toggle: toggle)
            NavigationLink {
                RecordSubjectScreen(subject: todo.subject, fallbackType: todo.subjectType)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let subject = todo.subject {
                        Label(subject.name, systemImage: (subject.type ?? todo.subjectType ?? .customer).systemImage)
                            .font(.wsCaption.weight(.semibold))
                            .foregroundStyle(.secondaryText)
                            .lineLimit(1)
                    }
                    Text(todo.body)
                        .font(.wsBody)
                        .strikethrough(todo.done)
                        .foregroundStyle(todo.done ? Color.secondaryText : Color(.label))
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        if let tag = todo.tag { NoteTagChip(raw: tag) }
                        if let due = todo.dueLabel() {
                            Label(due, systemImage: todo.isOverdue() ? "exclamationmark.circle.fill" : "calendar")
                                .font(.wsCaption.weight(todo.isOverdue() ? .semibold : .regular))
                                .foregroundStyle(todo.isOverdue() ? Tone.danger.textColor : Color.secondaryText)
                        }
                    }
                    Text(byline)
                        .font(.wsCaption)
                        .foregroundStyle(.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("myTodos.row.\(todo.uuid)")
    }

    private var byline: String {
        if todo.done {
            return "Done by \(todo.doneBy?.uuid == myUUID ? "you" : todo.doneBy?.name ?? "someone")"
                + (todo.doneAt.map { " · \(NoteTime.short($0))" } ?? "")
        }
        return "From \(todo.isMine ? "you" : todo.authorName) · \(NoteTime.short(todo.createdAt))"
    }
}

/// The customer or lead a to-do is on.
struct RecordSubjectScreen: View {
    let subject: NoteSubject?
    let fallbackType: RecordNoteSubjectType?

    var body: some View {
        if let subject {
            switch subject.type ?? fallbackType ?? .customer {
            case .customer: CustomerDetailView(customerUuid: subject.uuid)
            case .lead: LeadDetailView(leadUuid: subject.uuid)
            }
        } else {
            ContentUnavailableView("Not found", systemImage: "questionmark.folder",
                                   description: Text("This to-do's customer or lead couldn't be found."))
        }
    }
}

// MARK: - Home

/// Home's "Your to-dos": the open to-dos given to me on customers and leads, overdue in red, ticked off
/// right here. Hidden when there are none.
struct HomeTodosPanel: View {
    let todos: [RecordNote]
    let myUUID: String?
    var error: String?
    let toggle: (RecordNote) -> Void

    private static let limit = 5

    var body: some View {
        DashboardPanel(title: "Your to-dos") {
            let overdue = todos.filter { $0.isOverdue() }.count
            Text(overdue > 0 ? "\(overdue) overdue. Tick them off when they're done."
                 : "On your customers and leads. Tick them off when they're done.")
                .font(.wsFootnote)
                .foregroundStyle(overdue > 0 ? Tone.danger.textColor : Color.secondaryText)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.wsFootnote)
                    .foregroundStyle(Tone.danger.textColor)
                    .padding(.horizontal, 10)
            }
            ForEach(todos.prefix(Self.limit)) { todo in
                HStack(alignment: .top, spacing: 4) {
                    NoteDoneButton(note: todo) { toggle(todo) }
                        .padding(.leading, 14)
                        .padding(.top, 6)
                    NavigationLink {
                        RecordSubjectScreen(subject: todo.subject, fallbackType: todo.subjectType)
                    } label: {
                        row(todo)
                    }
                    .buttonStyle(.panelRow)
                }
                .accessibilityIdentifier("home.todo.\(todo.uuid)")
            }
            NavigationLink(value: NativeScreenRoute(MyTodosScreen.id)) {
                PanelRow(title: todos.count > Self.limit ? "All \(todos.count) to-dos" : "All my to-dos",
                         systemImage: "checklist")
            }
            .buttonStyle(.panelRow)
            .accessibilityIdentifier("home.todos.all")
        }
        .accessibilityIdentifier("home.todos")
    }

    private func row(_ todo: RecordNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.body)
                    .font(.wsSubheadline.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let subject = todo.subject { Text(subject.name).lineLimit(1) }
                    if let due = todo.dueLabel() {
                        Text("· \(due)")
                            .foregroundStyle(todo.isOverdue() ? Tone.danger.textColor : Color.secondaryText)
                            .fontWeight(todo.isOverdue() ? .semibold : .regular)
                    }
                }
                .font(.wsFootnote)
                .foregroundStyle(.secondaryText)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// The My to-dos screen's id in the CRM group (`NativeScreenRoute(MyTodosScreen.id)`).
enum MyTodosScreen {
    static let id = "crm.my_todos"

    /// Shown to people who can read customers or leads (the server only lists those they can see).
    @MainActor
    static func isAvailable(_ session: SessionStore) -> Bool {
        let p = session.permissions
        return (p.menuKeys.contains("customers") && p.can(.read, .customers))
            || (p.menuKeys.contains("crm_leads") && p.can(.read, .crmLeads))
    }
}
