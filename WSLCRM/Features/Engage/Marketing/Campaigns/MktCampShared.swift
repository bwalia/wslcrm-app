import SwiftUI

// Pieces the campaign, overview and results screens share: the test-mode banner, the step bar
// ("what to do next"), and "Ask AI to do it" (the workspace's AI assistant, natively).

// MARK: - Test mode

/// Says plainly that nothing is really being sent while test mode is on.
struct MktCampTestModeBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("**Test mode is on.** Emails only pretend to be sent — nobody receives anything, and “sent” "
                     + "numbers here are not real.")
                    .font(.wsSubheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "flask").foregroundStyle(Tone.warning.textColor)
            }
            NavigationLink(value: NativeScreenRoute(Marketing.Screen.settings)) {
                Text("Switch test mode off in Marketing settings").font(.wsSubheadline.weight(.semibold))
            }
            .accessibilityIdentifier("mkt.testMode.settings")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("mkt.testMode.banner")
    }
}

// MARK: - Steps

/// Every step from "Connect email" to "Test & send", ticked from what the workspace has really done,
/// with one button for the next one (and "Ask AI to do it").
struct MktCampJourneySection: View {
    let progress: MktCampProgress?
    @Binding var askAI: MktCampAskAIRequest?
    @Environment(SessionStore.self) private var session
    /// The full checklist (overview) or just the next step (other pages).
    var full = false
    /// The web page this is on (`/dashboard/opsapi-marketing/…`): "Ask AI" works on that page.
    var path = MktCampPages.overview

    var body: some View {
        if let progress {
            let next = MktCampStep.next(for: progress)
            Section {
                if let next {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Getting started: \(MktCampStep.doneCount(progress)) of \(MktCampStep.requiredCount) steps done")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                        ProgressView(value: Double(MktCampStep.doneCount(progress)), total: Double(MktCampStep.requiredCount))
                            .accessibilityLabel("Getting started progress")
                        Text("Next: \(next.title)").font(.wsHeadline)
                        Text(next.why).font(.wsSubheadline).foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    NavigationLink(value: NativeScreenRoute(Marketing.reachable(next.screen, session.permissions))) {
                        Label(next.action, systemImage: "arrow.right.circle.fill").font(.wsHeadline)
                    }
                    .accessibilityIdentifier("mkt.journey.next")
                    Button {
                        askAI = MktCampAskAIRequest(prompt: next.ai, path: path)
                    } label: {
                        Label("Ask AI to do it", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("mkt.journey.ai")
                } else {
                    Label("All set up — write another email or see how they did.", systemImage: "party.popper")
                        .font(.wsSubheadline)
                }
                if full {
                    ForEach(Array(MktCampStep.all.enumerated()), id: \.element.id) { index, step in
                        MktCampStepRow(index: index, step: step, done: step.done(progress), isNext: step == next)
                    }
                }
            } header: {
                Text(full ? "Your checklist" : "Your marketing steps")
            }
        }
    }
}

private struct MktCampStepRow: View {
    let index: Int
    let step: MktCampStep
    let done: Bool
    let isNext: Bool
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationLink(value: NativeScreenRoute(Marketing.reachable(step.screen, session.permissions))) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(done ? Tone.success.solidColor : (isNext ? Tone.brand.solidColor : Color.secondary.opacity(0.2)))
                    if done {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(index + 1)").font(.wsCaption.bold()).foregroundStyle(isNext ? .white : .primary)
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title + (step.optional ? " (optional)" : "")).font(.wsSubheadline.weight(.semibold))
                    Text(step.why).font(.wsFootnote).foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel("\(step.title), \(done ? "done" : (isNext ? "do this next" : "not done yet"))")
        .accessibilityIdentifier("mkt.journey.step.\(index)")
    }
}

/// The dashboard's marketing pages, so "Ask AI" works on the page the person is on.
enum MktCampPages {
    static let overview = "/dashboard/opsapi-marketing/overview"
    static let campaigns = "/dashboard/opsapi-marketing/campaigns"
    static let lists = "/dashboard/opsapi-marketing/lists"
    static let studio = "/dashboard/opsapi-marketing/studio"
    static let unsubscribed = "/dashboard/opsapi-marketing/unsubscribed"
    static let settings = "/dashboard/opsapi-marketing/settings"
}

/// The step bar for screens that aren't a plain List (lists, studio, unsubscribed, settings): the next step,
/// one tap to it, and "Ask AI" on this page. Put it in `.safeAreaInset(edge: .top)`; it loads itself and
/// hides once every step is done.
struct MktCampJourneyBar: View {
    let path: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var progress: MktCampProgress?
    @State private var askAI: MktCampAskAIRequest?

    var body: some View {
        Group {
            if let progress, let next = MktCampStep.next(for: progress) {
                HStack(spacing: 10) {
                    NavigationLink(value: NativeScreenRoute(Marketing.reachable(next.screen, session.permissions))) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Step \(MktCampStep.doneCount(progress) + 1) of \(MktCampStep.requiredCount)")
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                            Label("Next: \(next.title)", systemImage: "arrow.right.circle.fill")
                                .font(.wsSubheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("mkt.journeyBar.next")
                    Button { askAI = MktCampAskAIRequest(prompt: next.ai, path: path) } label: {
                        Label("Ask AI to do it", systemImage: "sparkles").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("mkt.journeyBar.ai")
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(.bar)
            }
        }
        .task { progress = await services.marketingCampaigns.progress() }
        .sheet(item: $askAI) { request in
            NavigationStack {
                MktCampAskAISheet(request: request) { Task { progress = await services.marketingCampaigns.progress() } }
            }
        }
    }
}

// MARK: - Ask AI

/// "Ask AI to do it": what to ask and which page the assistant works on (its scope).
struct MktCampAskAIRequest: Identifiable, Hashable {
    let prompt: String
    let path: String
    var id: String { path + prompt }
}

/// The workspace's AI assistant for one marketing page (`/api/chat/agent`, the same conversation
/// the dashboard keeps for that page). It works as the person, with their permissions; deletes wait
/// for them to confirm.
struct MktCampAskAISheet: View {
    let request: MktCampAskAIRequest
    /// Called when the assistant changed something, so the page reloads.
    var onChanged: () -> Void = {}
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: JSONValue?
    @State private var draft = ""
    @State private var error: APIError?
    @State private var sentFirst = false
    @State private var working = false

    private var status: String { conversation?["status"]?.stringValue ?? "idle" }
    private var turns: [Record] { (conversation?["turns"]?.listValue ?? []).compactMap { value in
        if case .object(let o) = value { return Record(o) }
        return nil
    } }
    private var pending: String? { conversation?["pending"]?["summary"]?.stringValue }

    var body: some View {
        List {
            if let error { Section { InlineErrorRow(error: error) } }
            if turns.isEmpty, status != "running" {
                Section {
                    EngageIntro(text: "Ask in your own words. The assistant can make and change things for you in "
                                + "Marketing; it asks before deleting anything.", systemImage: "sparkles")
                }
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                Section {
                    let mine = turn.string("role") == "user"
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mine ? "You" : "Assistant").font(.wsCaption.weight(.semibold)).foregroundStyle(.secondaryText)
                        if mine {
                            Text(turn.string("content") ?? "").font(.wsBody)
                        } else {
                            RichTextView(markdown: turn.string("content") ?? "")
                        }
                        ForEach(Array(turn.records("actions").enumerated()), id: \.offset) { _, action in
                            Label(action.string("label") ?? Formatters.humanize(action.string("name")),
                                  systemImage: action.string("error") == nil ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.wsFootnote).foregroundStyle(.secondaryText)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if status == "running" {
                Section { HStack { ProgressView(); Text("Working on it…").foregroundStyle(.secondaryText) } }
            }
            if let pending {
                Section("Waiting for you") {
                    Text(pending).font(.wsBody)
                    Button(role: .destructive) { Task { await confirm(true) } } label: {
                        Label("Confirm", systemImage: "checkmark")
                    }
                    .disabled(working)
                    .accessibilityIdentifier("mkt.ai.confirm")
                    Button { Task { await confirm(false) } } label: { Label("Cancel", systemImage: "xmark") }
                        .disabled(working)
                        .accessibilityIdentifier("mkt.ai.cancel")
                }
            }
            Section {
                TextField("Ask the assistant…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("mkt.ai.input")
                Button { Task { await send(draft) } } label: { Label("Send", systemImage: "paperplane.fill") }
                    .disabled(draft.trimmedOrNil == nil || status == "running" || working)
                    .accessibilityIdentifier("mkt.ai.send")
            }
        }
        .navigationTitle("Ask AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("New chat") { Task { await reset() } }
                    .disabled(status == "running")
                    .accessibilityIdentifier("mkt.ai.new")
            }
        }
        .task { await start() }
        .task(id: status) {
            // While a turn runs in the background, check on it every two seconds.
            guard status == "running" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
                if status != "running" { break }
            }
        }
    }

    private var client: EngageClient { services.engage }

    private func start() async {
        await refresh()
        guard !sentFirst else { return }
        sentFirst = true
        if status != "running", let prompt = request.prompt.trimmedOrNil { await send(prompt) }
    }

    private func refresh() async {
        do {
            let answer = try await client.get("/api/chat/agent/conversation", query: ["path": request.path])
            let wasRunning = status == "running"
            conversation = answer
            error = nil
            if wasRunning, status != "running", answer["changed"]?.boolValue == true { onChanged() }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError
        }
    }

    private func send(_ text: String) async {
        guard let message = text.trimmedOrNil else { return }
        working = true
        defer { working = false }
        do {
            conversation = try await client.post("/api/chat/agent", .object([
                "message": .string(message), "path": .string(request.path), "local_date": .string(Self.today()),
            ]))
            draft = ""
            error = nil
            if status != "running", conversation?["changed"]?.boolValue == true { onChanged() }
        } catch {
            self.error = error.asAPIError
            if draft.isEmpty { draft = message }
        }
    }

    private func confirm(_ approve: Bool) async {
        working = true
        defer { working = false }
        do {
            conversation = try await client.post("/api/chat/agent/confirm", .object([
                "approve": .bool(approve), "path": .string(request.path), "local_date": .string(Self.today()),
            ]))
            error = nil
            if approve { onChanged() }
        } catch {
            self.error = error.asAPIError
        }
    }

    private func reset() async {
        do {
            var builder = QueryBuilder()
            builder.add("path", request.path)
            try await services.client.sendDiscardingBody(Endpoint.delete("/api/chat/agent/conversation")
                .withQuery(builder.items))
            conversation = nil
            error = nil
        } catch {
            self.error = error.asAPIError
        }
    }

    /// The person's own calendar date, so the assistant's "today" is theirs.
    static func today() -> String { CalendarDay(date: Date()).isoString }
}

private extension Endpoint {
    func withQuery(_ items: [URLQueryItem]) -> Endpoint {
        var copy = self
        copy.query = items
        return copy
    }
}

// MARK: - Small pieces

/// A labelled number with a hint underneath (the web's KPI tiles), for grids inside lists.
struct MktCampTile: View {
    let label: String
    let value: String
    var hint: String?
    var tone: Tone?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.wsCaption).foregroundStyle(.secondaryText)
            Text(value).font(.wsTitle3.monospacedDigit()).foregroundStyle(tone?.textColor ?? .primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let hint { Text(hint).font(.wsCaption2).foregroundStyle(.secondaryText).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct MktCampTileGrid: View {
    let tiles: [MktCampTile]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in tile }
        }
        .padding(.vertical, 4)
    }
}

enum MktCampFormat {
    static func int(_ value: Double?) -> String { EngageFormat.count(value ?? 0) }
    /// The plugin sends rates already as percentages (12.5 = 12.5%).
    static func pct(_ value: Double?) -> String { EngageFormat.percent(value, alreadyPercent: true) }
    static func money(_ value: Double?, currency: String? = nil) -> String {
        EngageFormat.money(value ?? 0, currency: currency ?? Formatters.defaultCurrency)
    }
}
