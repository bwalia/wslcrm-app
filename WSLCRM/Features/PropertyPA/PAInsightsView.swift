import SwiftUI

/// PA insights (managers): is the PA helping over the last 30 days (capture accuracy, grounded
/// answers, speed, follow-through, handoffs), the go-live checklist, the integrations (import email,
/// sync GoHighLevel now), and the AI change history: every change the PA made with its source,
/// model, prompt version and who confirmed it.
struct PAInsightsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var metrics: LoadState<PAMetrics> = .idle
    @State private var status: LoadState<PAStatus> = .idle
    @State private var audit: LoadState<[PAAuditRow]> = .idle
    @State private var running: String?
    @State private var notice: String?
    @State private var actionError: APIError?

    var body: some View {
        Group {
            if session.permissions.paIsManager {
                content
            } else {
                ContentUnavailableView {
                    Label("For managers", systemImage: "lock")
                } description: {
                    Text("PA insights are for managers (PA knowledge: manage). Ask a workspace admin if you need them.")
                }
            }
        }
        .navigationTitle("PA insights")
    }

    private var content: some View {
        List {
            if let notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor)
                        .accessibilityIdentifier("pa.insights.notice")
                }
            }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            metricsSection
            checklistSection
            integrationsSection
            auditSection
        }
        .wsRefreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .accessibilityIdentifier("pa.insights.refresh")
            }
        }
    }

    // MARK: Numbers

    @ViewBuilder
    private var metricsSection: some View {
        Section {
            switch metrics {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let m):
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 150), spacing: 10)],
                          spacing: 10) {
                    ForEach(Self.tiles(m), id: \.title) { tile in
                        PAInsightTile(tile: tile)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Is the PA helping? Last 30 days")
        }
    }

    struct Tile: Hashable {
        var title: String
        var value: String
        var hint: String?
        var tone: Tone = .brand
        var systemImage: String
    }

    /// The web's eight numbers, in its order and words.
    static func tiles(_ m: PAMetrics) -> [Tile] {
        let c = m.capture, a = m.answers, f = m.followThrough, h = m.handoffs
        let overdue = f?.nextActionsOverdue ?? 0
        let quiet = f?.opportunitiesGoneQuiet ?? 0
        return [
            Tile(title: "Notes captured", value: "\(c?.captures ?? 0)",
                 hint: "\(c?.proposals ?? 0) changes proposed, \(c?.waiting ?? 0) waiting", systemImage: "square.and.pencil"),
            Tile(title: "Accepted as proposed", value: PAText.percent(c?.acceptedAsProposed),
                 hint: "corrected \(PAText.percent(c?.correctionRate)) · rejected \(PAText.percent(c?.rejectionRate))",
                 systemImage: "checkmark.circle"),
            Tile(title: "Answers grounded", value: PAText.percent(a?.groundedRate),
                 hint: "\(a?.withheld ?? 0) withheld · \(a?.failed ?? 0) failed", tone: (a?.withheld ?? 0) > 0 ? .warning : .brand,
                 systemImage: "quote.bubble"),
            Tile(title: "PA answer time", value: PAText.seconds(a?.p50Seconds),
                 hint: "90% within \(PAText.seconds(a?.p90Seconds))", systemImage: "timer"),
            Tile(title: "Next actions overdue", value: "\(overdue)",
                 hint: "\(f?.nextActionsOpen ?? 0) open · \(f?.nextActionsDone ?? 0) done", tone: overdue > 0 ? .danger : .success,
                 systemImage: "exclamationmark.triangle"),
            Tile(title: "Gone quiet (14 days+)", value: "\(quiet)", tone: quiet > 0 ? .warning : .brand,
                 systemImage: "moon.zzz"),
            Tile(title: "Handoffs", value: "\(h?.total ?? 0)",
                 hint: "\(h?.waiting ?? 0) waiting · reply in \(PAText.seconds(h?.medianSecondsToReply))",
                 systemImage: "person.badge.shield.checkmark"),
            Tile(title: "Time to confirm", value: PAText.seconds(c?.medianSecondsToConfirm),
                 hint: "From proposal to decision", systemImage: "hourglass"),
        ]
    }

    // MARK: Checklist

    @ViewBuilder
    private var checklistSection: some View {
        Section {
            switch status {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let s):
                ForEach(s.checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.ok == true ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(check.ok == true ? Tone.success.textColor
                                             : (check.optional == true ? .secondaryText : Tone.danger.textColor))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.text ?? Formatters.humanize(check.key))
                            if check.ok != true, let fix = check.fix {
                                Text("\(fix)\(check.optional == true ? " (optional)" : "")")
                                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(check.ok == true ? "Done" : "Not done"): \(check.text ?? check.key)")
                }
            }
        } header: {
            HStack {
                Text("Go-live checklist")
                Spacer()
                if let ready = status.value?.ready {
                    Text(ready ? "Ready" : "Not ready")
                        .foregroundStyle(ready ? Tone.success.textColor : Tone.warning.textColor)
                }
            }
        }
    }

    // MARK: Integrations

    private var integrationsSection: some View {
        Section {
            if session.permissions.pa(.create, "records") {
                Button { Task { await importMail() } } label: {
                    HStack {
                        Label("Import email now", systemImage: "envelope.arrow.triangle.branch")
                        if running == "mail" { Spacer(); ProgressView() }
                    }
                }
                .disabled(running != nil)
                .accessibilityIdentifier("pa.insights.importMail")
            }
            Button { Task { await syncGHL() } } label: {
                HStack {
                    Label("Sync GoHighLevel now", systemImage: "person.2.badge.gearshape")
                    if running == "ghl" { Spacer(); ProgressView() }
                }
            }
            .disabled(running != nil)
            .accessibilityIdentifier("pa.insights.syncGHL")
        } header: {
            Text("Integrations")
        } footer: {
            Text("Inbound email from people you work with goes onto their timeline every 5 minutes; GoHighLevel contacts are pulled every hour.")
        }
    }

    // MARK: AI change history

    @ViewBuilder
    private var auditSection: some View {
        Section {
            switch audit {
            case .idle, .loading:
                SkeletonRow()
            case .failed(let error):
                InlineErrorRow(error: error) { Task { await load() } }
            case .loaded(let rows) where rows.isEmpty:
                Text("No AI changes yet.").foregroundStyle(.secondaryText)
            case .loaded(let rows):
                ForEach(rows) { row in PAAuditRowView(row: row) }
            }
        } header: {
            Text("AI change history")
        } footer: {
            Text("Every change the PA made: where it came from, the model and prompt version, and who confirmed it. The latest 50.")
        }
    }

    // MARK: Work

    private func load() async {
        let api = services.propertyPA
        async let m = api.metrics(days: 30)
        async let s = api.status()
        async let a = api.audit(perPage: 50)
        if metrics.value == nil { metrics = .loading }
        do { metrics = .loaded(try await m) } catch { if !isCancel(error) { metrics = .failed(error.asAPIError) } }
        do { status = .loaded(try await s) } catch { if !isCancel(error) { status = .failed(error.asAPIError) } }
        do { audit = .loaded(try await a) } catch { if !isCancel(error) { audit = .failed(error.asAPIError) } }
    }

    private func isCancel(_ error: Error) -> Bool {
        if case .cancelled = error.asAPIError { return true }
        return false
    }

    private func importMail() async {
        running = "mail"
        defer { running = nil }
        do {
            let result = try await services.propertyPA.importMail()
            let n = result.imported ?? 0
            notice = "\(n) email\(n == 1 ? "" : "s") added to timelines (\(result.considered ?? 0) looked at)."
            actionError = nil
            audit = .loaded((try? await services.propertyPA.audit(perPage: 50)) ?? audit.value ?? [])
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }

    private func syncGHL() async {
        running = "ghl"
        defer { running = nil }
        do {
            let result = try await services.propertyPA.syncGoHighLevel()
            var text = "GoHighLevel sync started. New contacts appear within a few minutes."
            if result.queued == false { text = "A GoHighLevel sync is already on its way. New contacts appear within a few minutes." }
            if let last = result.lastRunAt { text += " Last run \(Formatters.relative(last) ?? "")." }
            notice = text
            actionError = nil
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }
}

private struct PAInsightTile: View {
    let tile: PAInsightsView.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: tile.systemImage)
                .foregroundStyle(tile.tone.textColor)
                .accessibilityHidden(true)
            Text(tile.value).font(.wsTitle2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(tile.title).font(.wsFootnote.weight(.semibold))
            if let hint = tile.hint { Text(hint).font(.wsCaption).foregroundStyle(.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tile.tone.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One AI change: what, its value, when, the model and prompt, and who confirmed it.
struct PAAuditRowView: View {
    let row: PAAuditRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.fieldLabel).font(.wsSubheadline.weight(.semibold))
                Spacer()
                Text(row.superseded == true ? "Replaced" : "Current").font(.wsCaption).foregroundStyle(.secondaryText)
            }
            HStack(spacing: 6) {
                Text(PAText.value(row.value, field: row.field)).font(.wsBody).lineLimit(3)
                if row.isInferred == true {
                    Text("INFERRED").font(.wsCaption2.weight(.bold)).foregroundStyle(Tone.warning.textColor)
                }
            }
            Text([Formatters.dateTime(row.createdAt),
                  row.model.map { m in row.promptVersion.map { "\(m) · \($0)" } ?? m }].compactMap { $0 }.joined(separator: " · "))
                .font(.wsCaption).foregroundStyle(.secondaryText)
            if let name = row.confirmedByName {
                Text("Confirmed by \(name)").font(.wsCaption).foregroundStyle(Tone.success.textColor)
            } else {
                Text("Not confirmed").font(.wsCaption).foregroundStyle(Tone.warning.textColor)
            }
        }
        .padding(.vertical, 2)
        .opacity(row.superseded == true ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }
}
