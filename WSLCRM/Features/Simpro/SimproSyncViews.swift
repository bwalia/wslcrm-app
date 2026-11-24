import SwiftUI

/// Simpro sync (`/api/v2/field-service/simpro`): the connection, how many records of each kind are
/// in Simpro or waiting to go, the audit trail of every pull and push, and — for people allowed to
/// run a sync (`simpro_sync.manage`, by default only the Owner role) — Test, Pull and Push.
struct SimproSyncStatusView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status: LoadState<SimproStatus> = .idle
    @State private var log: [SimproLogEntry] = []
    @State private var logTotal = 0
    @State private var logPage = 1
    @State private var logHasMore = false
    @State private var logError: APIError?
    @State private var logStatus = ""
    @State private var running: SimproRun?
    @State private var confirmingPush: SimproRun?
    @State private var lastRun: String?
    @State private var actionError: APIError?

    private var canRun: Bool { SimproAccess.canRunSync(session.permissions) }

    var body: some View {
        List {
            switch status {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let status):
                if let lastRun {
                    Section {
                        Label(lastRun, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tone.success.textColor)
                            .accessibilityIdentifier("simpro.lastRun")
                    }
                }
                if let actionError {
                    Section { InlineErrorRow(error: actionError) }
                }
                connectionSection(status)
                if canRun, let connection = status.connection {
                    actionsSection(connection)
                }
                recordsSection(status)
                logSection
            }
        }
        .navigationTitle("Simpro sync")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { logFilter }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .confirmationDialog("Send changes to Simpro?", isPresented: .init(get: { confirmingPush != nil },
                                                                           set: { if !$0 { confirmingPush = nil } }),
                            titleVisibility: .visible, presenting: confirmingPush) { run in
            Button("Push \(run.scopeLabel.lowercased())") { Task { await perform(run) } }
        } message: { _ in
            Text("Simpro is the customer's system of record. Records changed here are written to it.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func connectionSection(_ status: SimproStatus) -> some View {
        Section {
            if let connection = status.connection {
                LabeledContent("Build") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(connection.name ?? "Simpro")
                        if let url = connection.baseUrl {
                            Text(url).font(.wsCaption.monospaced()).foregroundStyle(.secondaryText)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
                LabeledContent("Mode") {
                    StatusBadge(text: Self.modeLabel(connection.mode), systemImage: Self.modeSymbol(connection.mode),
                                tone: Self.modeTone(connection.mode))
                }
                if let company = connection.companyId {
                    LabeledContent("Company ID", value: company)
                }
                LabeledContent("Pull / push",
                               value: "\(connection.pullEnabled == false ? "Off" : "On") / \(connection.pushEnabled == true ? "On" : "Off")")
                LabeledContent("Last pull", value: SimproDates.display(connection.lastPullAt, withTime: true))
                LabeledContent("Last push", value: SimproDates.display(connection.lastPushAt, withTime: true))
                if let error = connection.lastError, !error.isEmpty {
                    Label("Last run had problems: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.wsFootnote)
                        .foregroundStyle(Tone.warning.textColor)
                }
            } else {
                Text("No Simpro connection is set up for this workspace yet.").foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Connection")
        } footer: {
            if status.connection?.mode == "mock" {
                Text("Practice build: it answers like Simpro's API but is served by OpsAPI, so nothing reaches a real "
                     + "Simpro account.")
            } else {
                Text("Simpro is the system of record. OpsAPI pulls customers, sites, assets and jobs from it and pushes "
                     + "back what changes here.")
            }
        }
    }

    @ViewBuilder
    private func actionsSection(_ connection: SimproStatus.Connection) -> some View {
        let pullOn = connection.pullEnabled != false
        let pushOn = connection.pushEnabled == true
        Section {
            Button {
                Task { await perform(SimproRun(kind: .test)) }
            } label: {
                runLabel("Test the connection", systemImage: "bolt.horizontal.circle", kind: .test)
            }
            .disabled(running != nil)
            .accessibilityIdentifier("simpro.test")

            Menu {
                Button("Everything") { Task { await perform(SimproRun(kind: .pull)) } }
                ForEach(SimproEntities.all.filter(\.pulls), id: \.key) { entity in
                    Button(entity.label) { Task { await perform(SimproRun(kind: .pull, entity: entity.key)) } }
                }
            } label: {
                runLabel("Pull from Simpro", systemImage: "arrow.down.to.line", kind: .pull)
            }
            .disabled(running != nil || !pullOn)
            .accessibilityIdentifier("simpro.pull")

            Menu {
                Button("Everything waiting") { confirmingPush = SimproRun(kind: .push) }
                ForEach(SimproEntities.all.filter(\.pushes), id: \.key) { entity in
                    Button(entity.label) { confirmingPush = SimproRun(kind: .push, entity: entity.key) }
                }
            } label: {
                runLabel("Push to Simpro", systemImage: "arrow.up.to.line", kind: .push)
            }
            .disabled(running != nil || !pushOn)
            .accessibilityIdentifier("simpro.push")
        } header: {
            Text("Run a sync")
        } footer: {
            if !pullOn && !pushOn {
                Text("Pulling and pushing are both switched off on this connection.")
            } else if !pushOn {
                Text("Pushing is switched off on this connection, so nothing is written to Simpro.")
            } else if !pullOn {
                Text("Pulling is switched off on this connection.")
            } else {
                Text("A pull brings Simpro's latest records here; a push sends what changed here (up to 100 at a time).")
            }
        }
    }

    private func runLabel(_ title: String, systemImage: String, kind: SimproRun.Kind) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if running?.kind == kind { ProgressView() }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func recordsSection(_ status: SimproStatus) -> some View {
        Section("Records") {
            ForEach(SimproEntities.all, id: \.key) { entity in
                if let counts = status.counts[entity.key] {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entity.label).font(.wsHeadline)
                            Spacer()
                            Text("\(counts.total)").font(.wsHeadline.monospacedDigit())
                        }
                        Text("\(counts.synced) in Simpro · \(counts.pending) to push · \(counts.errored) errors · "
                             + "\(counts.localOnly) only here")
                            .font(.wsSubheadline).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    @ViewBuilder
    private var logSection: some View {
        Section {
            if log.isEmpty && logError == nil {
                Text(logStatus.isEmpty ? "Nothing has been synced yet." : "No \(Self.logLabel(logStatus).lowercased()) in the log.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(log) { entry in
                SimproLogRow(entry: entry)
            }
            if let logError {
                InlineErrorRow(error: logError) { Task { await loadLog(reset: log.isEmpty) } }
            }
            if logHasMore {
                Button("Show more") { Task { await loadLog(reset: false) } }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("simpro.log.more")
            }
        } header: {
            Text("Sync log (\(logTotal))")
        }
    }

    private var logFilter: some View {
        Menu {
            Picker("Outcome", selection: Binding(get: { logStatus }, set: { value in
                logStatus = value
                Task { await loadLog(reset: true) }
            })) {
                Text("All outcomes").tag("")
                ForEach(["ok", "conflict", "error", "skipped"], id: \.self) { Text(Self.logLabel($0)).tag($0) }
            }
        } label: {
            Label("Filter the log", systemImage: logStatus.isEmpty ? "line.3.horizontal.decrease.circle"
                                                                   : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityIdentifier("simpro.log.filter")
    }

    // MARK: Work

    private func load() async {
        if status.value == nil { status = .loading }
        do {
            status = .loaded(try await services.simpro.simproStatus())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if status.value == nil { status = .failed(apiError) } else { actionError = apiError }
        }
        await loadLog(reset: true)
    }

    private func loadLog(reset: Bool) async {
        let page = reset ? 1 : logPage + 1
        do {
            let result = try await services.simpro.simproLog(status: logStatus.isEmpty ? nil : logStatus, page: page)
            log = reset ? result.items : log + result.items.filter { entry in !log.contains { $0.uuid == entry.uuid } }
            logPage = result.page
            logTotal = result.total
            logHasMore = result.hasMore
            logError = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            logError = apiError
        }
    }

    private func perform(_ run: SimproRun) async {
        running = run
        defer { running = nil }
        do {
            switch run.kind {
            case .test:
                let info = try await services.simpro.testSimpro()
                lastRun = "Connected to \(info.company ?? info.baseUrl ?? "Simpro")."
            case .pull:
                let result = try await services.simpro.pullSimpro(entities: run.entity)
                lastRun = "Pulled \(run.scopeLabel.lowercased()) — \(result.summary)."
            case .push:
                let result = try await services.simpro.pushSimpro(entities: run.entity)
                lastRun = "Pushed \(run.scopeLabel.lowercased()) — \(result.summary)."
            }
            actionError = nil
            await load()
        } catch {
            actionError = error.asAPIError
            lastRun = nil
        }
    }

    // MARK: Words

    static func modeLabel(_ mode: String?) -> String {
        switch mode {
        case "live": "Live"
        case "sandbox": "Sandbox"
        default: "Practice (mock)"
        }
    }

    static func modeSymbol(_ mode: String?) -> String {
        switch mode {
        case "live": "dot.radiowaves.left.and.right"
        case "sandbox": "testtube.2"
        default: "theatermasks"
        }
    }

    static func modeTone(_ mode: String?) -> Tone {
        switch mode {
        case "live": .success
        case "sandbox": .info
        default: .progress
        }
    }

    static func logLabel(_ status: String) -> String {
        switch status {
        case "ok": "Done"
        case "conflict": "Conflicts"
        case "error": "Errors"
        case "skipped": "Skipped"
        default: Formatters.humanize(status)
        }
    }
}

/// A sync the person started: test, pull or push, for everything or one kind of record.
struct SimproRun: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case test, pull, push }
    let kind: Kind
    var entity: String?
    var id: String { "\(kind)-\(entity ?? "all")" }

    var scopeLabel: String { entity.map(SimproEntities.label) ?? "Everything" }
}

/// One line of the sync log: when, which way, what, and how it went.
struct SimproLogRow: View {
    let entry: SimproLogEntry

    static let statusStyle = StatusStyle(tones: ["ok": .success, "conflict": .warning, "error": .danger,
                                                 "skipped": .neutral],
                                         labels: ["ok": "Done", "conflict": "Conflict", "error": "Error",
                                                  "skipped": "Skipped"])

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label("\(entry.direction == "push" ? "Push" : "Pull") · \(SimproEntities.label(entry.entityType))",
                      systemImage: entry.direction == "push" ? "arrow.up.to.line" : "arrow.down.to.line")
                    .font(.wsHeadline)
                Spacer()
                StatusBadge(text: Self.statusStyle.label(for: entry.status),
                            systemImage: Self.statusStyle.symbol(for: entry.status),
                            tone: Self.statusStyle.tone(for: entry.status))
            }
            Text([SimproDates.display(entry.createdAt, withTime: true), entry.operation.map { Formatters.humanize($0) },
                  entry.simproId.map { "Simpro ID \($0)" }].compactMap { $0 }.joined(separator: " · "))
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
            if let detail = entry.detail {
                Text(detail).font(.wsFootnote).foregroundStyle(entry.status == "error" ? Tone.danger.textColor : .secondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
