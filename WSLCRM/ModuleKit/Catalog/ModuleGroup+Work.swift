import SwiftUI

/// Projects, my tasks, timesheets and the review queue.
///
/// Their menu keys (`projects`, `my_tasks`, `timesheets`) are the app's original screens
/// (`NativeModules.screens`), so this group adds no keys of its own: it owns the screens those
/// pages lead to — project settings, sprints, epics, analytics, labels, AI runs — opened with
/// `NavigationLink(value: WorkScreen.….route)`.
extension ModuleGroup {
    static let work = ModuleGroup(
        id: "work",
        screen: { id in WorkScreen(id: id)?.view })
}

/// A hand-built work screen and its parameters, carried in a `NativeScreenRoute` id
/// (`work.sprints?project=…`), so no shared navigation code has to know these screens.
enum WorkScreen: Hashable, Sendable {
    /// Opening a project from the list: its board when it has one, else its summary.
    case projectHome(project: String)
    case projectSettings(project: String)
    case labels(project: String)
    case sprints(project: String, sprint: String?)
    case epics(project: String)
    case epic(uuid: String, project: String)
    case analytics(project: String)
    case aiRun(uuid: String)
    /// The web terminal work log of one card.
    case workLog(task: String)
    case waiting

    var route: NativeScreenRoute {
        var components = URLComponents()
        let kind: String
        var items: [String: String?] = [:]
        switch self {
        case .projectHome(let project): kind = "project"; items["project"] = project
        case .projectSettings(let project): kind = "settings"; items["project"] = project
        case .labels(let project): kind = "labels"; items["project"] = project
        case .sprints(let project, let sprint): kind = "sprints"; items["project"] = project; items["sprint"] = sprint
        case .epics(let project): kind = "epics"; items["project"] = project
        case .epic(let uuid, let project): kind = "epic"; items["uuid"] = uuid; items["project"] = project
        case .analytics(let project): kind = "analytics"; items["project"] = project
        case .aiRun(let uuid): kind = "airun"; items["uuid"] = uuid
        case .workLog(let task): kind = "worklog"; items["task"] = task
        case .waiting: kind = "waiting"
        }
        components.path = "work.\(kind)"
        let query = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        components.queryItems = query.isEmpty ? nil : query
        return NativeScreenRoute(components.string ?? "work.\(kind)")
    }

    init?(id: String) {
        guard id.hasPrefix("work."), let components = URLComponents(string: id) else { return nil }
        let values = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
        func value(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
        switch components.path {
        case "work.project": guard let p = value("project") else { return nil }; self = .projectHome(project: p)
        case "work.settings": guard let p = value("project") else { return nil }; self = .projectSettings(project: p)
        case "work.labels": guard let p = value("project") else { return nil }; self = .labels(project: p)
        case "work.sprints": guard let p = value("project") else { return nil }; self = .sprints(project: p, sprint: value("sprint"))
        case "work.epics": guard let p = value("project") else { return nil }; self = .epics(project: p)
        case "work.epic":
            guard let u = value("uuid"), let p = value("project") else { return nil }
            self = .epic(uuid: u, project: p)
        case "work.analytics": guard let p = value("project") else { return nil }; self = .analytics(project: p)
        case "work.airun": guard let u = value("uuid") else { return nil }; self = .aiRun(uuid: u)
        case "work.worklog": guard let t = value("task") else { return nil }; self = .workLog(task: t)
        case "work.waiting": self = .waiting
        default: return nil
        }
    }

    @MainActor
    var view: AnyView {
        switch self {
        case .projectHome(let project): AnyView(ProjectEntryView(uuid: project))
        case .projectSettings(let project): AnyView(ProjectSettingsView(projectUuid: project))
        case .labels(let project): AnyView(LabelManagerView(projectUuid: project))
        case .sprints(let project, let sprint): AnyView(SprintsView(projectUuid: project, initialSprint: sprint))
        case .epics(let project): AnyView(EpicsView(projectUuid: project))
        case .epic(let uuid, let project): AnyView(EpicDetailView(uuid: uuid, projectUuid: project))
        case .analytics(let project): AnyView(ProjectAnalyticsView(projectUuid: project))
        case .aiRun(let uuid): AnyView(TaskAIRunDetailView(uuid: uuid))
        case .workLog(let task): AnyView(AIWorkLogView(taskUuid: task))
        case .waiting: AnyView(ReviewQueueView())
        }
    }
}
