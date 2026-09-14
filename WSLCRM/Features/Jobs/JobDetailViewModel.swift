import Foundation
import Observation

/// Shared by the job detail and phase detail screens.
@MainActor
@Observable
final class JobDetailViewModel {
    /// Asks the user to confirm a `force: true` retry after the server's 422.
    struct ForcePrompt: Identifiable, Equatable {
        enum Target: Equatable {
            case job(JobStatus)
            case phase(phaseUuid: String, status: PhaseStatus, signoffName: String?, notes: String?)
        }

        let id = UUID()
        let target: Target
        let message: String
    }

    /// A phase that needs a customer sign-off name before it can complete.
    struct SignoffPrompt: Identifiable, Equatable {
        var id: String { phaseUuid }
        let phaseUuid: String
        let phaseName: String
        let force: Bool
        let notes: String?
    }

    struct PhaseDisplay {
        var phase: JobPhase
        var hasPendingWrites: Bool
        var hasFailedWrites: Bool
        /// Checklist indices whose tick state is waiting to sync.
        var pendingChecklistIndices: Set<Int>
    }

    let jobUuid: String
    private(set) var state: LoadState<JobDetail> = .idle
    private(set) var cachedAt: Date?
    private(set) var busyKey: String?
    var actionError: APIError?
    var forcePrompt: ForcePrompt?
    var signoffPrompt: SignoffPrompt?
    var infoMessage: String?

    private let api: FieldServiceAPI
    private let sync: SyncCenter
    private let session: SessionStore

    init(jobUuid: String, api: FieldServiceAPI, sync: SyncCenter, session: SessionStore) {
        self.jobUuid = jobUuid
        self.api = api
        self.sync = sync
        self.session = session
    }

    var detail: JobDetail? { state.value }
    var policy: FieldServicePolicy { session.policy }

    // MARK: Loading

    func load() async {
        if detail == nil { state = .loading }
        do {
            let fetched = try await api.job(jobUuid)
            state = .loaded(fetched.value)
            cachedAt = fetched.cachedAt
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if detail == nil {
                state = .failed(apiError)
            } else {
                actionError = apiError
            }
        }
    }

    // MARK: Optimistic overlay

    func display(_ phase: JobPhase) -> PhaseDisplay {
        var result = PhaseDisplay(phase: phase, hasPendingWrites: false, hasFailedWrites: false, pendingChecklistIndices: [])
        for mutation in sync.pending(for: phase.uuid) {
            result.hasPendingWrites = true
            if mutation.isFailed { result.hasFailedWrites = true }
            switch mutation.kind {
            case .checklistToggle:
                if let index = mutation.hints["index"].flatMap(Int.init), result.phase.checklist.indices.contains(index) {
                    result.phase.checklist[index].done = mutation.hints["done"] == "true"
                    result.pendingChecklistIndices.insert(index)
                }
            case .phaseStatus:
                if let status = mutation.hints["status"] {
                    result.phase.status = PhaseStatus(api: status)
                }
            default:
                break
            }
        }
        return result
    }

    var displayedPhases: [PhaseDisplay] {
        (detail?.sortedPhases ?? []).map(display)
    }

    func phase(_ uuid: String) -> PhaseDisplay? {
        detail?.phases.first { $0.uuid == uuid }.map(display)
    }

    func isBusy(_ key: String) -> Bool { busyKey == key }

    // MARK: Job status

    func changeJobStatus(to status: JobStatus, reason: String? = nil, force: Bool = false) async {
        guard busyKey == nil else { return }
        busyKey = "job-status"
        defer { busyKey = nil }
        do {
            let updated = try await api.setJobStatus(jobUuid, body: JobStatusChangeBody(status: status.rawValue,
                                                                                         reason: reason, force: force ? true : nil))
            state = .loaded(updated)
            cachedAt = nil
        } catch {
            let apiError = error.asAPIError
            if case .validation(let server) = apiError, server.suggestsForce, !force {
                forcePrompt = ForcePrompt(target: .job(status), message: server.message)
            } else {
                actionError = apiError
            }
        }
    }

    // MARK: Phase status

    func setPhaseStatus(_ phase: JobPhase, to target: PhaseStatus, signoffName: String? = nil,
                        force: Bool = false, notes: String? = nil) async {
        guard let context = session.mutationContext, busyKey == nil else { return }
        let current = display(phase).phase

        if target == .completed {
            // Prompt for sign-off up front; `force` never bypasses it on the server.
            if current.needsSignoff && (signoffName?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) {
                signoffPrompt = SignoffPrompt(phaseUuid: phase.uuid, phaseName: phase.name, force: force, notes: notes)
                return
            }
            // Offline we can't get the server's 422, so check the checklist locally.
            if !force, !sync.isOnlineForWrites, current.uncheckedCount > 0 {
                forcePrompt = ForcePrompt(
                    target: .phase(phaseUuid: phase.uuid, status: target, signoffName: signoffName, notes: notes),
                    message: "\(current.uncheckedCount) checklist item(s) not ticked.")
                return
            }
        }

        busyKey = "phase-\(phase.uuid)"
        defer { busyKey = nil }
        let body = PhaseStatusChangeBody(status: target.rawValue,
                                         signoffName: signoffName?.trimmingCharacters(in: .whitespaces),
                                         force: force ? true : nil,
                                         notes: notes?.isEmpty == false ? notes : nil)
        let mutation = FieldServiceAPI.Mutations.phaseStatus(phase: phase, body: body, jobUuid: jobUuid, context: context)
        do {
            switch try await sync.perform(mutation) {
            case .sent(let data):
                if let envelope = try? JSONDecoder.opsAPI().decode(Envelope.Standard<JobPhase>.self, from: data) {
                    replace(envelope.data)
                }
                // Phase changes can move the job itself (auto-start) and its roll-ups.
                await load()
            case .queued:
                infoMessage = "Saved on this device. It will sync when you're back online."
            }
        } catch {
            let apiError = error.asAPIError
            guard case .validation(let server) = apiError else {
                actionError = apiError
                return
            }
            let message = server.message.lowercased()
            if message.contains("signoff") || message.contains("sign-off") {
                signoffPrompt = SignoffPrompt(phaseUuid: phase.uuid, phaseName: phase.name, force: force, notes: notes)
            } else if server.suggestsForce && !force {
                forcePrompt = ForcePrompt(
                    target: .phase(phaseUuid: phase.uuid, status: target, signoffName: signoffName, notes: notes),
                    message: server.message)
            } else {
                actionError = apiError
            }
        }
    }

    func confirmForce(_ prompt: ForcePrompt) async {
        forcePrompt = nil
        switch prompt.target {
        case .job(let status):
            await changeJobStatus(to: status, force: true)
        case .phase(let uuid, let status, let signoffName, let notes):
            guard let phase = detail?.phases.first(where: { $0.uuid == uuid }) else { return }
            await setPhaseStatus(phase, to: status, signoffName: signoffName, force: true, notes: notes)
        }
    }

    func submitSignoff(_ prompt: SignoffPrompt, name: String) async {
        signoffPrompt = nil
        guard let phase = detail?.phases.first(where: { $0.uuid == prompt.phaseUuid }) else { return }
        await setPhaseStatus(phase, to: .completed, signoffName: name, force: prompt.force, notes: prompt.notes)
    }

    // MARK: Checklist

    func toggleChecklistItem(phase: JobPhase, index: Int) async {
        guard let context = session.mutationContext else { return }
        let current = display(phase).phase
        guard current.checklist.indices.contains(index) else { return }
        let newValue = !current.checklist[index].done

        // Optimistic: reflect immediately, then reconcile with the server's phase.
        mutateLocalPhase(phase.uuid) { $0.checklist[index].done = newValue }

        let mutation = FieldServiceAPI.Mutations.checklist(phase: phase, index: index, done: newValue,
                                                           jobUuid: jobUuid, context: context)
        do {
            if case .sent(let data) = try await sync.perform(mutation),
               let envelope = try? JSONDecoder.opsAPI().decode(Envelope.Standard<JobPhase>.self, from: data) {
                replace(envelope.data)
            }
        } catch {
            mutateLocalPhase(phase.uuid) { $0.checklist[index].done = !newValue }
            actionError = error.asAPIError
        }
    }

    // MARK: Reorder

    func movePhases(from source: IndexSet, to destination: Int) async {
        guard var detail else { return }
        var ordered = detail.sortedPhases
        let previous = ordered
        ordered.move(fromOffsets: source, toOffset: destination)
        for (offset, _) in ordered.enumerated() { ordered[offset].sortOrder = offset + 1 }
        detail.phases = ordered
        state = .loaded(detail)

        do {
            let phases = try await api.reorderPhases(jobUuid: jobUuid, order: ordered.map(\.uuid))
            if !phases.isEmpty {
                detail.phases = phases
                state = .loaded(detail)
            }
        } catch {
            detail.phases = previous
            state = .loaded(detail)
            actionError = error.asAPIError
        }
    }

    // MARK: Items

    func setApproval(_ item: JobItem, approve: Bool) async {
        busyKey = "item-\(item.uuid)"
        defer { busyKey = nil }
        do {
            let updated = try await api.setItemApproval(itemUuid: item.uuid, approve: approve)
            guard var detail, let index = detail.items.firstIndex(where: { $0.uuid == item.uuid }) else { return }
            detail.items[index] = updated
            state = .loaded(detail)
        } catch {
            actionError = error.asAPIError
        }
    }

    // MARK: Helpers

    private func replace(_ phase: JobPhase) {
        guard var detail, let index = detail.phases.firstIndex(where: { $0.uuid == phase.uuid }) else { return }
        detail.phases[index] = phase
        state = .loaded(detail)
    }

    private func mutateLocalPhase(_ uuid: String, _ change: (inout JobPhase) -> Void) {
        guard var detail, let index = detail.phases.firstIndex(where: { $0.uuid == uuid }) else { return }
        change(&detail.phases[index])
        state = .loaded(detail)
    }
}
