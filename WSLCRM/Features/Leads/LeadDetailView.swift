import SwiftUI

/// One lead: who they are, what to do next, what the AI thinks, meetings and history — and every
/// action a person working leads takes from a phone. The server decides who may do what
/// (`lead.permissions`); the buttons follow it.
struct LeadDetailView: View {
    let leadUuid: String
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<Lead> = .idle
    @State private var timeline: [LeadTimelineItem] = []
    @State private var sheet: Sheet?
    @State private var busy = false
    @State private var actionError: APIError?
    @State private var notice: String?
    @State private var markingLost = false
    @State private var lostReason = ""

    enum Sheet: Identifiable {
        case edit, call, step, meeting, nurture, convert, assign
        var id: Self { self }
    }

    var body: some View {
        Group {
            switch state {
            case .idle, .loading: SkeletonList(rows: 4)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let lead): content(lead)
            }
        }
        .navigationTitle("Lead")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            if let lead = state.value, canWork(lead), session.permissions.can(.update, .crmLeads) {
                ToolbarItem(placement: .topBarTrailing) { Button("Edit") { sheet = .edit } }
            }
        }
        .sheet(item: $sheet) { sheet in
            if let lead = state.value { sheetView(sheet, lead) }
        }
        .alert("Mark as lost", isPresented: $markingLost) {
            TextField("Why? (optional)", text: $lostReason)
            Button("Mark lost", role: .destructive) {
                let reason = lostReason.trimmingCharacters(in: .whitespaces)
                Task { await act { try await services.leads.move(leadUuid, LeadStageBody(stage: "lost", reason: reason.isEmpty ? nil : reason)) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Content

    private func content(_ lead: Lead) -> some View {
        List {
            header(lead)
            if let phone = lead.phone { Section { PhoneLinkRow(name: "Call \(lead.firstName)", phone: phone) } }
            if let email = lead.email { Section { EmailLinkRow(email: email) } }
            if let notice { Section { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.textColor) } }
            if let actionError { Section { InlineErrorRow(error: actionError) } }
            if lead.isOpen, canWork(lead) { nextStep(lead) }
            ai(lead)
            meetings(lead)
            if canWork(lead) { manage(lead) }
            details(lead)
            if !timeline.isEmpty { history }
            if canWork(lead), session.permissions.can(.delete, .crmLeads) {
                Section {
                    DeleteButton(title: "Delete lead", message: "This removes the lead and its history.") {
                        do {
                            try await services.leads.delete(lead.uuid)
                            return true
                        } catch {
                            actionError = error.asAPIError
                            return false
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .disabled(busy)
    }

    private func header(_ lead: Lead) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(lead.displayName).font(.title2.bold())
                if let line = [lead.jobTitle, lead.companyName].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(line).foregroundStyle(.secondaryText)
                }
                HStack {
                    StatusBadge(text: lead.stageLabel, systemImage: lead.stage.systemImage, tone: lead.stage.tone)
                    if let score = lead.aiScore {
                        StatusBadge(text: "Score \(score)", systemImage: "sparkles", tone: score >= 70 ? .success : .neutral)
                    }
                }
                if let value = lead.estimatedValue, value > 0, let text = Formatters.money(value, currency: lead.currency ?? LeadsAPI.defaultCurrency) {
                    Text(text).font(.title3.monospacedDigit())
                }
                Text(lead.ownerName.map { "Owner: \($0)" } ?? "Not assigned yet")
                    .font(.subheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
            if lead.stage == .converted, let deal = lead.convertedDealUuid {
                NavigationLink { CRMDealDetailView(dealUuid: deal) } label: {
                    Label("Open the deal\(lead.convertedDealName.map { ": \($0)" } ?? "")", systemImage: "briefcase.fill")
                }
            }
            if lead.stage == .lost, let reason = lead.lostReason { DetailRow(label: "Lost", value: reason) }
            if lead.stage == .nurture, let until = lead.nurtureUntil { DetailRow(label: "Comes back on", value: until) }
        }
    }

    private func nextStep(_ lead: Lead) -> some View {
        Section("Next step") {
            if let due = lead.nextActionAt {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lead.nextActionNote ?? LeadStepType.label(for: lead.nextActionType)).font(.headline)
                        Text("\(Formatters.day(due) ?? "") \(Formatters.time(due) ?? "")")
                            .font(.subheadline)
                            .foregroundStyle(lead.isOverdue ? Tone.danger.textColor : Color.secondaryText)
                    }
                } icon: {
                    Image(systemName: lead.isOverdue ? "exclamationmark.circle.fill" : "clock")
                        .foregroundStyle(lead.isOverdue ? Tone.danger.color : Tone.brand.color)
                }
            } else {
                Text("Nothing planned. Plan the next step so this lead doesn't go cold.")
                    .font(.subheadline).foregroundStyle(.secondaryText)
            }
            Button { sheet = .call } label: { Label("Log a call", systemImage: "phone.badge.checkmark") }
                .buttonStyle(.large(.brand))
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("lead.logCall")
            HStack {
                Button { sheet = .step } label: { Label("Plan a step", systemImage: "calendar.badge.clock") }
                Spacer()
                Button { sheet = .meeting } label: { Label("Book a meeting", systemImage: "video") }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            Text("\(lead.contactAttempts) call\(lead.contactAttempts == 1 ? "" : "s") so far")
                .font(.caption).foregroundStyle(.secondaryText)
        }
    }

    @ViewBuilder
    private func ai(_ lead: Lead) -> some View {
        let analysis = lead.analysis
        Section("AI") {
            if analysis?.isRunning == true || lead.aiStatus == "pending" || lead.aiStatus == "running" {
                Label("The AI is reading this lead…", systemImage: "hourglass").foregroundStyle(.secondaryText)
            } else if let result = analysis?.result {
                if let summary = result.summary { Text(summary) }
                if let wants = result.wants { DetailRow(label: "They want", value: wants) }
                if let action = result.nextBestAction, let label = action.label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggested: \(label)").font(.headline)
                        if let reason = action.reason { Text(reason).font(.subheadline).foregroundStyle(.secondaryText) }
                    }
                }
                if let low = result.valueLow, let high = result.valueHigh,
                   let l = Formatters.money(low, currency: lead.currency ?? LeadsAPI.defaultCurrency), let h = Formatters.money(high, currency: lead.currency ?? LeadsAPI.defaultCurrency) {
                    DetailRow(label: "Deal size", value: "\(l) – \(h)")
                }
                if !result.questions.isEmpty {
                    DisclosureGroup("Questions to ask (\(result.questions.count))") {
                        ForEach(result.questions, id: \.self) { Text("• \($0)").font(.subheadline) }
                    }
                }
            } else if let error = analysis?.error {
                Text("The AI couldn't read this lead: \(error)").font(.subheadline).foregroundStyle(.secondaryText)
            } else {
                Text("No AI analysis yet.").font(.subheadline).foregroundStyle(.secondaryText)
            }
            if canWork(lead) {
                Button {
                    Task {
                        await act(notice: "The AI is reading the lead again. Pull down to refresh in a minute.") {
                            try await services.leads.analyse(lead.uuid)
                            return try await services.leads.lead(lead.uuid)
                        }
                    }
                } label: { Label("Run the AI again", systemImage: "sparkles") }
                .frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder
    private func meetings(_ lead: Lead) -> some View {
        if !lead.meetings.isEmpty {
            Section("Meetings") {
                ForEach(lead.meetings) { meeting in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.subject).font(.headline)
                        Text([Formatters.day(meeting.startsAt), Formatters.time(meeting.startsAt), "\(meeting.durationMinutes) min",
                              meeting.typeLabel].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondaryText)
                        if let place = meeting.location { Text(place).font(.subheadline) }
                        if let link = meeting.meetingUrl, let url = URL(string: link) {
                            Link(destination: url) { Label("Join", systemImage: "video.fill") }.frame(minHeight: 44)
                        }
                        Text(meetingStatus(meeting)).font(.caption).foregroundStyle(.secondaryText)
                        if meeting.isPlanned, canWork(lead) {
                            HStack {
                                if (meeting.startsAt ?? .distantFuture) < Date().addingTimeInterval(15 * 60) {
                                    Button("It happened") { Task { await meetingAction { try await services.leads.meetingOutcome(meeting.uuid, held: true) } } }
                                    Button("They didn't come") { Task { await meetingAction { try await services.leads.meetingOutcome(meeting.uuid, held: false) } } }
                                }
                                Spacer()
                                Button("Cancel", role: .destructive) { Task { await meetingAction { try await services.leads.cancelMeeting(meeting.uuid) } } }
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func meetingStatus(_ meeting: LeadMeeting) -> String {
        switch meeting.status {
        case "completed": meeting.outcome == "no_show" ? "They didn't come" : "It happened"
        case "cancelled": "Cancelled"
        default:
            if let error = meeting.inviteError { "Invite not sent yet: \(error)" } else if meeting.inviteSent { "Invite sent" } else { "No invite sent" }
        }
    }

    private func manage(_ lead: Lead) -> some View {
        Section("Move it on") {
            if lead.isOpen {
                Menu {
                    ForEach(LeadStage.open.filter { $0 != lead.stage }, id: \.self) { stage in
                        Button(stage.label) { Task { await act { try await services.leads.move(lead.uuid, LeadStageBody(stage: stage.rawValue)) } } }
                    }
                } label: {
                    Label("Move to stage…", systemImage: "arrow.right.circle").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                if lead.permissions?.canConvert ?? session.permissions.can(.create, .crmDeals) {
                    Button { sheet = .convert } label: { Label("Convert to a deal", systemImage: "briefcase.fill") }
                        .buttonStyle(.large(.success, prominent: false))
                        .listRowSeparator(.hidden)
                }
                Button { sheet = .nurture } label: { Label("Nurture: come back later", systemImage: "leaf") }
                    .frame(minHeight: 44)
                Button(role: .destructive) { lostReason = ""; markingLost = true } label: { Label("Mark lost", systemImage: "xmark.circle") }
                    .frame(minHeight: 44)
            } else if lead.stage != .converted {
                Button { Task { await act { try await services.leads.move(lead.uuid, LeadStageBody(stage: "new")) } } } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
                .frame(minHeight: 44)
            }
            if lead.permissions?.canAssignAny == true {
                Button { sheet = .assign } label: { Label(lead.ownerName == nil ? "Assign" : "Change owner", systemImage: "person.crop.circle.badge.plus") }
                    .frame(minHeight: 44)
            } else if lead.ownerUserUuid == nil, let me = session.user?.uuid {
                Button { Task { await act { try await services.leads.assign(lead.uuid, to: me) } } } label: {
                    Label("Take this lead", systemImage: "hand.raised")
                }
                .frame(minHeight: 44)
            }
        }
    }

    private func details(_ lead: Lead) -> some View {
        Section("Details") {
            DetailRow(label: "Source", value: lead.source.map(Formatters.humanize))
            DetailRow(label: "Came in", value: Formatters.day(lead.createdAt))
            DetailRow(label: "First contact", value: Formatters.day(lead.firstContactedAt))
            DetailRow(label: "Expected close", value: lead.expectedCloseDate)
            DetailRow(label: "Priority", value: lead.priority.map(Formatters.humanize))
            ForEach(lead.qualification.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                DetailRow(label: Formatters.humanize(item.key), value: item.value)
            }
            if let notes = lead.notes {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Their message").font(.caption).foregroundStyle(.secondaryText)
                    Text(notes).textSelection(.enabled)
                }
            }
        }
    }

    private var history: some View {
        Section("History") {
            ForEach(timeline.prefix(30)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        if let outcome = item.outcomeLabel { Text(outcome).font(.caption).foregroundStyle(.secondaryText) }
                    }
                    Text([Formatters.relative(item.at), item.by].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondaryText)
                    if let detail = item.detail { Text(detail).font(.subheadline) }
                }
            }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: Sheet, _ lead: Lead) -> some View {
        switch sheet {
        case .edit:
            LeadForm(lead: lead) { body in
                let updated = try await services.leads.update(lead.uuid, body)
                await reload(updated)
                return updated
            }
        case .call:
            LogCallSheet(lead: lead) { body in await reload(try await services.leads.logCall(lead.uuid, body)) }
        case .step:
            PlanStepSheet { body in await reload(try await services.leads.planStep(lead.uuid, body)) }
        case .meeting:
            BookMeetingSheet(lead: lead) { body in
                _ = try await services.leads.bookMeeting(lead.uuid, body)
                await reload(try await services.leads.lead(lead.uuid))
            }
        case .nurture:
            NurtureSheet { until in await reload(try await services.leads.move(lead.uuid, LeadStageBody(stage: "nurture", nurtureUntil: until))) }
        case .convert:
            ConvertSheet(lead: lead) { body in
                _ = try await services.leads.convert(lead.uuid, body)
                await reload(try await services.leads.lead(lead.uuid))
            }
        case .assign:
            AssignSheet(current: lead.ownerUserUuid) { owner in await reload(try await services.leads.assign(lead.uuid, to: owner)) }
        }
    }

    // MARK: Actions

    private func canWork(_ lead: Lead) -> Bool { lead.permissions?.canWork ?? session.permissions.can(.update, .crmLeads) }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let lead = try await services.leads.lead(leadUuid)
            state = .loaded(lead)
            timeline = (try? await services.leads.timeline(leadUuid)) ?? timeline
        } catch {
            if state.value == nil { state = .failed(error.asAPIError) }
        }
    }

    private func reload(_ lead: Lead) async {
        // Writes return the lead without its analysis/meetings; fetch the full one.
        let full = (try? await services.leads.lead(lead.uuid)) ?? lead
        state = .loaded(full)
        actionError = nil
        timeline = (try? await services.leads.timeline(lead.uuid)) ?? timeline
    }

    private func act(notice message: String? = nil, _ work: @escaping () async throws -> Lead) async {
        busy = true
        defer { busy = false }
        do {
            await reload(try await work())
            notice = message
        } catch {
            actionError = error.asAPIError
            notice = nil
        }
    }

    private func meetingAction(_ work: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            await load()
            actionError = nil
        } catch {
            actionError = error.asAPIError
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
