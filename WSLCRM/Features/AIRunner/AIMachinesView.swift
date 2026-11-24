import SwiftUI

/// Machines (`ai_runners.manage`): the web terminals people work in, then every runner with its status,
/// agent profiles (health and plan usage) and every session it last reported — runs it manages (open the
/// run) and sessions started by hand (open their task once tracking made one). Refreshes every 15 seconds.
struct AIMachinesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var runners: [AIRunner] = []
    @State private var sessions: LoadState<Page<Record>> = .idle
    @State private var terminals: [Record]?
    @State private var terminalsError: APIError?
    @State private var runnerUuid = ""
    @State private var busyOnly = false
    @State private var page = 1
    @State private var connecting = false
    @State private var secret: AITerminalSecret?
    @State private var notice: AINotice?

    private var api: AIRunnerAPI { AIRunnerAPI(client: services.client) }

    var body: some View {
        Group {
            if session.permissions.ai(.manage, "ai_runners") { list } else { AINoAccess() }
        }
        .navigationTitle("Machines")
        .aiNotice($notice)
    }

    private var list: some View {
        List {
            terminalsSection
            Section("Show") {
                Picker("Runner", selection: $runnerUuid) {
                    Text("All runners").tag("")
                    ForEach(machines, id: \.uuid) { Text($0.name).tag($0.uuid) }
                }
                .accessibilityIdentifier("airunner.machines.runner")
                Toggle("Busy only", isOn: $busyOnly).accessibilityIdentifier("airunner.machines.busy")
            }
            switch sessions {
            case .idle, .loading:
                ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
            case .failed(let error):
                Section { AILoadFailure(error: error) { Task { await load() } } }
            case .loaded(let result):
                let shown = runnerUuid.isEmpty ? machines : machines.filter { $0.uuid == runnerUuid }
                if shown.isEmpty {
                    Section {
                        ContentUnavailableView("No runners yet", systemImage: "desktopcomputer",
                                               description: Text("Register one under Runners & sources, then start PromptPilot on that machine."))
                        NavigationLink(value: NativeScreenRoute("airunner.runners")) {
                            Label("Runners & sources", systemImage: "server.rack")
                        }
                    }
                }
                ForEach(shown) { machine in
                    let rows = result.items.filter { $0.string("runner.uuid") == machine.uuid }
                    Section {
                        machineHeader(machine)
                        if rows.isEmpty {
                            Text(result.totalPages > 1 ? "None on this page." : busyOnly ? "No busy sessions." : "No sessions reported.")
                                .foregroundStyle(.secondaryText)
                        }
                        ForEach(rows, id: \.id) { AISessionRow(session: $0) }
                    }
                }
                if result.totalPages > 1 {
                    Section { AIPager(page: result.page, totalPages: result.totalPages) { page = $0 } }
                }
            }
        }
        .onChange(of: runnerUuid) { page = 1 }
        .onChange(of: busyOnly) { page = 1 }
        .wsRefreshable { await load() }
        .task(id: "\(runnerUuid)|\(busyOnly)|\(page)") {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .sheet(isPresented: $connecting) {
            NavigationStack {
                AITerminalEditSheet(terminal: nil) { _, secret in
                    if let secret { self.secret = secret }
                    Task { await load() }
                }
            }
        }
        .sheet(item: $secret) { shown in NavigationStack { AITerminalSecretSheet(shown: shown) } }
    }

    /// A section per registered runner, plus any runner only the sessions name (revoked since, say).
    private var machines: [AIRunner] {
        var list = runners
        for s in sessions.value?.items ?? [] {
            if let uuid = s.string("runner.uuid"), !list.contains(where: { $0.uuid == uuid }) {
                list.append(AIRunner(Record(["uuid": .string(uuid), "name": .string(s.string("runner.name") ?? "Runner"),
                                             "status": .string(s.string("runner.status") ?? "offline")])))
            }
        }
        return list
    }

    private func machineHeader(_ m: AIRunner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.name).font(.wsHeadline)
                Spacer()
                AIStatusBadge(value: m.status, style: AIRunner.statusStyle)
            }
            Text("\(m.machineLine.map { "\($0) · " } ?? "")last heartbeat \(AIFormat.ago(m.lastHeartbeat))")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            ForEach(m.profiles.map(AIProfile.init(record:))) { AIProfileRow(profile: $0) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var terminalsSection: some View {
        Section {
            if let terminalsError {
                InlineErrorRow(error: terminalsError) { Task { await load() } }
            } else if let terminals {
                if terminals.isEmpty { Text("No web terminal connected yet.").foregroundStyle(.secondaryText) }
                ForEach(terminals, id: \.id) { t in
                    NavigationLink(value: NativeScreenRoute("airunner.terminal", t.string("uuid") ?? t.id)) {
                        AITerminalRow(terminal: t)
                    }
                    .accessibilityIdentifier("airunner.terminal.\(t.id)")
                }
            } else {
                SkeletonRow()
            }
            Button { connecting = true } label: { Label("Connect a terminal", systemImage: "plus") }
                .accessibilityIdentifier("airunner.terminals.connect")
        } header: {
            Text("Web terminals")
        } footer: {
            Text("Where people work on a task themselves: Start with AI opens the task's folder there and starts their agent.")
        }
    }

    private func load() async {
        let api = self.api
        async let runnersTask = api.runners()
        async let terminalsTask = api.terminals()
        do {
            sessions = .loaded(try await api.sessions(runnerUuid: runnerUuid.aiNonEmpty, busy: busyOnly, page: page))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if sessions.value == nil { sessions = .failed(apiError) }
        }
        if let list = try? await runnersTask { runners = list }
        do {
            terminals = try await terminalsTask
            terminalsError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if terminals == nil { terminalsError = apiError }
        }
    }
}
