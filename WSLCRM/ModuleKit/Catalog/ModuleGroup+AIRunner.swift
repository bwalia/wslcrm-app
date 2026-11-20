import SwiftUI

/// AI Runs (opsapi plugin `projects/ai-runner`): runs on tasks, runners and sources, machines and web
/// terminals, the work log, AI run settings with routing rules and the prompt template, and the platform
/// settings for platform admins. Every page is hand-built (live polling, permission decisions, a terminal
/// replay), under `Features/AIRunner`.
extension ModuleGroup {
    static let aiRunner = ModuleGroup(
        id: "industry.ai_runner",
        screens: [
            "plugin:ai_runner:runs": "airunner.runs",
            "plugin:ai_runner:runners": "airunner.runners",
            "plugin:ai_runner:machines": "airunner.machines",
            "plugin:ai_runner:settings": "airunner.settings",
            "plugin:ai_runner:work-log": "airunner.worklog",
            // The same work log, for people who see everyone's but don't run AI work themselves.
            "plugin:ai_runner:work-log-team": "airunner.worklog",
        ],
        screen: { id in AIRunnerScreens.view(id) })
}

enum AIRunnerScreens {
    /// Screens without a parameter (every one must resolve: `AIRunnerModuleTests`).
    static let fixed = ["airunner.runs", "airunner.runners", "airunner.machines", "airunner.settings", "airunner.settings.runs",
                        "airunner.rules", "airunner.template", "airunner.platform", "airunner.worklog"]
    /// Screens for one record: `<screen>:<uuid>`.
    static let perRecord = ["airunner.run", "airunner.run.log", "airunner.runner", "airunner.terminal",
                            "airunner.terminal.people", "airunner.worklog.session", "airunner.replay"]

    @MainActor
    static func view(_ id: String) -> AnyView? {
        let (screen, parameter) = NativeScreenRoute.parts(id)
        switch (screen, parameter) {
        case ("airunner.runs", nil): return AnyView(AIRunsView())
        case ("airunner.runners", nil): return AnyView(AIRunnersView())
        case ("airunner.machines", nil): return AnyView(AIMachinesView())
        case ("airunner.settings", nil): return AnyView(AISettingsView())
        case ("airunner.settings.runs", nil): return AnyView(AIRunSettingsView())
        case ("airunner.rules", nil): return AnyView(AIRulesView())
        case ("airunner.template", nil): return AnyView(AITemplateView())
        case ("airunner.platform", nil): return AnyView(AIPlatformView())
        case ("airunner.worklog", nil): return AnyView(AIWorkLogView())
        case ("airunner.run", let uuid?): return AnyView(AIRunDetailView(uuid: uuid))
        case ("airunner.run.log", let uuid?): return AnyView(AIRunLogView(uuid: uuid))
        case ("airunner.runner", let uuid?): return AnyView(AIRunnerDetailView(uuid: uuid))
        case ("airunner.terminal", let uuid?): return AnyView(AITerminalDetailView(uuid: uuid))
        case ("airunner.terminal.people", let uuid?): return AnyView(AITerminalPeopleView(uuid: uuid))
        case ("airunner.worklog.session", let uuid?): return AnyView(AIWorkLogSessionView(uuid: uuid))
        case ("airunner.replay", let value?):
            let (uuid, parts) = replayParameter(value)
            return AnyView(AITerminalReplayView(uuid: uuid, parts: parts))
        default: return nil
        }
    }

    /// `<tab uuid>:<part>,<part>` → the tab and its recording parts.
    static func replayParameter(_ value: String) -> (uuid: String, parts: [Int]) {
        let (uuid, list) = NativeScreenRoute.parts(value)
        return (uuid, (list ?? "").split(separator: ",").compactMap { Int($0) })
    }
}
