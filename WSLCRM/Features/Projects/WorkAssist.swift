import SwiftUI

// Pieces the work screens share: the "Ask AI" button and the running-timer bar.

// MARK: - Ask AI

/// The page's AI assistant, as the web's "Ask AI" on the same page: it opens with that page's
/// guide and tools (`/dashboard/projects/<uuid>`, `/dashboard/my-tasks`, `/dashboard/timesheets`).
/// Hidden when the person's menu has no AI chat, so it never leads to a refusal.
struct WorkAskAIButton: View {
    /// The web page this screen matches; the server picks the assistant from it.
    let path: String
    @Environment(SessionStore.self) private var session

    var body: some View {
        if session.permissions.menuKeys.contains(AppMenu.aiChatKey) {
            NavigationLink(value: NativeScreenRoute(ChatAssistantRoute.screenID(path: path))) {
                Label("Ask AI", systemImage: "sparkles")
            }
            .accessibilityHint("Opens the assistant for this page. It can answer questions and make changes for you.")
            .accessibilityIdentifier("work.askAI")
        }
    }

    nonisolated static func project(_ uuid: String) -> String { "/dashboard/projects/\(uuid)" }
    nonisolated static func task(_ uuid: String, project: String?) -> String {
        project.map { "/dashboard/projects/\($0)/tasks/\(uuid)" } ?? "/dashboard/my-tasks"
    }
    nonisolated static let projects = "/dashboard/projects"
    nonisolated static let myTasks = "/dashboard/my-tasks"
    nonisolated static let timesheets = "/dashboard/timesheets"
}

/// Reloads a screen when the person comes back to it (the AI, or another screen, may have
/// changed what it shows). The first appearance is the screen's own first load, so it is skipped.
private struct ReloadOnReturn: ViewModifier {
    let reload: @MainActor () async -> Void
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        content.onAppear {
            if hasAppeared { Task { await reload() } }
            hasAppeared = true
        }
    }
}

extension View {
    /// Reads the screen again whenever it reappears (not on its first appearance).
    func workReloadOnReturn(_ reload: @escaping @MainActor () async -> Void) -> some View {
        modifier(ReloadOnReturn(reload: reload))
    }
}

// MARK: - The running timer

/// The timer that's running for you, wherever you are in your work: the card's name, how long
/// it has run, Stop, and a tap opens the card.
///
/// Put it on any screen inside a NavigationStack that can show a `TaskRoute`:
/// `.safeAreaInset(edge: .bottom) { RunningTimerBar() }` (or `.workRunningTimer()`). It loads
/// itself, reloads whenever it reappears, and hides when nothing is running.
struct RunningTimerBar: View {
    /// Hidden while this card is on screen (its own page shows the timer).
    var hidingTask: String?
    @Environment(\.services) private var services
    @State private var timer: RunningTimer?
    @State private var stopping = false
    @State private var message: WorkNotice?

    /// Posted after a timer starts or stops anywhere in the app, so every bar and card catches up.
    nonisolated static let changed = Notification.Name("work.timer.changed")

    var body: some View {
        ZStack {
            // Always present, so the bar can load itself even while it shows nothing.
            Color.clear.frame(height: 0)
            if let message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.wsSubheadline.weight(.semibold))
                    .foregroundStyle(message.isError ? Tone.danger.textColor : Tone.success.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("work.timerBar.message")
                    .task(id: message.id) {
                        try? await Task.sleep(for: .seconds(message.isError ? 6 : 3))
                        if self.message?.id == message.id { self.message = nil }
                    }
            } else if let timer, let taskUuid = timer.taskUuid, taskUuid != hidingTask {
                bar(timer, taskUuid: taskUuid)
            }
        }
        .animation(.default, value: timer)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: Self.changed)) { _ in Task { await load() } }
    }

    private func bar(_ timer: RunningTimer, taskUuid: String) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: TaskRoute(uuid: taskUuid)) {
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.wsHeadline)
                        .foregroundStyle(Tone.danger.color)
                        .symbolEffect(.pulse)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(timer.taskTitle ?? "A task").font(.wsSubheadline.weight(.semibold)).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Self.elapsedText(timer))
                                .font(.wsCaption.monospacedDigit())
                                .foregroundStyle(.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Timer running on \(timer.taskTitle ?? "a task")")
            .accessibilityHint("Opens the task")
            .accessibilityIdentifier("work.timerBar.open")
            Button("Stop") { Task { await stop() } }
                .buttonStyle(.borderedProminent)
                .tint(Tone.danger.color)
                .disabled(stopping)
                .accessibilityLabel("Stop the timer and log the time")
                .accessibilityIdentifier("work.timerBar.stop")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Tone.danger.color.opacity(0.3)))
        .padding(.horizontal)
        .padding(.bottom, 6)
        .accessibilityIdentifier("work.timerBar")
    }

    /// "Running 0:12:05 · Website" — this run, and where the card lives.
    nonisolated static func elapsedText(_ timer: RunningTimer, now: Date = Date()) -> String {
        let seconds = max(0, timer.startedAt.map { now.timeIntervalSince($0) } ?? timer.elapsed)
        let clock = Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
        return ["Running \(clock)", timer.projectName].compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        timer = (try? await services.kanban.currentTimer()) ?? nil
    }

    private func stop() async {
        stopping = true
        defer { stopping = false }
        do {
            try await services.kanban.stopTimer()
            message = .done("Timer stopped and the time logged.")
            timer = nil
            NotificationCenter.default.post(name: Self.changed, object: nil)
        } catch {
            message = .failed(error.asAPIError.plainMessage)
        }
    }
}

extension View {
    /// The running-timer bar along the bottom of a work screen.
    func workRunningTimer(hiding task: String? = nil) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { RunningTimerBar(hidingTask: task) }
    }
}
