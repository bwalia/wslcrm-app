import SwiftUI

struct PhaseDetailView: View {
    @Bindable var model: JobDetailViewModel
    let phaseUuid: String
    @State private var notes = ""

    var body: some View {
        Group {
            if let detail = model.detail, let display = model.phase(phaseUuid) {
                content(detail: detail, display: display)
            } else {
                ContentUnavailableView("Phase not found", systemImage: "questionmark.folder",
                                       description: Text("It may have been removed. Pull to refresh the job."))
            }
        }
        .navigationTitle(model.phase(phaseUuid)?.phase.name ?? "Phase")
        .navigationBarTitleDisplayMode(.inline)
        .jobActionPrompts(model: model)
    }

    private func content(detail: JobDetail, display: JobDetailViewModel.PhaseDisplay) -> some View {
        let phase = display.phase
        let policy = model.policy
        let canTick = policy.canTickChecklist(in: detail)
        let targets = policy.allowedPhaseTargets(phase, in: detail)

        return List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        phase.status.badge
                            .accessibilityIdentifier("phase.status")
                        if display.hasPendingWrites { PendingSyncBadge(failed: display.hasFailedWrites) }
                    }
                    if let description = phase.description, !description.isEmpty {
                        Text(description).foregroundStyle(.secondary)
                    }
                    if phase.requiresSignoff {
                        if let name = phase.signoffName, let at = phase.signedOffAt {
                            Label("Signed off by \(name), \(Formatters.dateTime(at) ?? "")", systemImage: "signature")
                                .foregroundStyle(Tone.success.color)
                        } else {
                            Label("Customer sign-off required to complete", systemImage: "signature")
                                .foregroundStyle(Tone.warning.color)
                        }
                    }
                    if let completedBy = phase.completedByName, let at = phase.completedAt {
                        Label("\(phase.status == .skipped ? "Skipped" : "Completed") by \(completedBy), \(Formatters.dateTime(at) ?? "")",
                              systemImage: "person.fill.checkmark")
                            .font(.subheadline)
                    }
                    if !detail.job.status.isOpen {
                        Label("This job is \(detail.job.status.label.lowercased()). Reopen it to make changes.",
                              systemImage: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if !phase.checklist.isEmpty {
                Section {
                    ForEach(Array(phase.checklist.enumerated()), id: \.offset) { index, item in
                        ChecklistRow(item: item, isPending: display.pendingChecklistIndices.contains(index), isEnabled: canTick) {
                            Task { await model.toggleChecklistItem(phase: phase, index: index) }
                        }
                        .accessibilityIdentifier("phase.checklist.\(index)")
                    }
                } header: {
                    Text("Checklist · \(phase.checklist.count - phase.uncheckedCount) of \(phase.checklist.count) done")
                } footer: {
                    if !canTick {
                        Text("Only engineers booked on this job or dispatchers can tick items.")
                    }
                }
            }

            if !targets.isEmpty {
                Section("Update phase") {
                    if targets.contains(.completed) || targets.contains(.blocked) {
                        TextField("Notes (optional)", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                            .accessibilityIdentifier("phase.notes")
                    }
                    ForEach(orderedTargets(targets), id: \.self) { target in
                        Button {
                            let noteText = notes
                            Task {
                                await model.setPhaseStatus(phase, to: target, notes: noteText)
                                if model.actionError == nil, model.forcePrompt == nil, model.signoffPrompt == nil { notes = "" }
                            }
                        } label: {
                            if model.isBusy("phase-\(phase.uuid)") {
                                ProgressView()
                            } else {
                                Label(target.actionTitle, systemImage: target.systemImage)
                            }
                        }
                        .buttonStyle(.large(target.tone == .neutral ? .info : target.tone, prominent: target == .completed))
                        .disabled(model.busyKey != nil)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("phase.action.\(target.rawValue)")
                    }
                }
            }

            Section("Details") {
                DetailRow(label: "Estimated", value: Formatters.hours(phase.estimatedHours))
                DetailRow(label: "Logged", value: phase.loggedHours > 0 ? Formatters.hours(phase.loggedHours) : nil)
                DetailRow(label: "Visits", value: phase.visitCount > 0 ? String(phase.visitCount) : nil)
                DetailRow(label: "Started", value: Formatters.dateTime(phase.startedAt))
                if let existing = phase.notes, !existing.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.caption).foregroundStyle(.secondary)
                        Text(existing)
                    }
                }
            }
        }
        .refreshable { await model.load() }
    }

    private func orderedTargets(_ targets: [PhaseStatus]) -> [PhaseStatus] {
        let order: [PhaseStatus] = [.completed, .inProgress, .blocked, .skipped, .pending]
        return targets.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
    }
}

/// A full-width checklist row: 56pt+ tap target, icon + text state, VoiceOver toggle semantics.
struct ChecklistRow: View {
    let item: ChecklistItem
    let isPending: Bool
    let isEnabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 30))
                    .foregroundStyle(item.done ? Tone.success.color : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.label)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .strikethrough(item.done, color: .secondary)
                        .multilineTextAlignment(.leading)
                    if isPending {
                        Label("Waiting to sync", systemImage: "icloud.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Tone.progress.color)
                    } else if item.done, let at = item.doneAt {
                        Text("Done \(Formatters.dateTime(at) ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.done ? "Done" : "Not done")
        .accessibilityHint(isEnabled ? "Double tap to \(item.done ? "untick" : "tick")" : "")
        .accessibilityAddTraits(.isButton)
    }
}
