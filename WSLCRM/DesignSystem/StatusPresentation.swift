import SwiftUI

// Every status has a label, an SF Symbol and a tone, so status is never conveyed by colour alone.

extension JobStatus {
    var label: String {
        switch self {
        case .draft: "Draft"
        case .scheduled: "Scheduled"
        case .inProgress: "In progress"
        case .onHold: "On hold"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil.circle"
        case .scheduled: "calendar.circle"
        case .inProgress: "play.circle.fill"
        case .onHold: "pause.circle.fill"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .draft, .unknown: .neutral
        case .scheduled: .info
        case .inProgress: .progress
        case .onHold: .warning
        case .completed: .success
        case .cancelled: .danger
        }
    }

    /// Verb for an action button that moves a job *to* this status.
    var actionTitle: String {
        switch self {
        case .draft: "Move back to draft"
        case .scheduled: "Mark scheduled"
        case .inProgress: "Start job"
        case .onHold: "Put on hold"
        case .completed: "Complete job"
        case .cancelled: "Cancel job"
        case .unknown: "Change status"
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

extension JobPriority {
    var label: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .urgent: "Urgent"
        case .unknown: "—"
        }
    }

    var systemImage: String {
        switch self {
        case .low: "arrow.down"
        case .normal: "equal"
        case .high: "arrow.up"
        case .urgent: "exclamationmark.2"
        case .unknown: "minus"
        }
    }

    var tone: Tone {
        switch self {
        case .urgent: .danger
        case .high: .warning
        default: .neutral
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

extension PhaseStatus {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .skipped: "Skipped"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "circle.dashed"
        case .inProgress: "play.circle.fill"
        case .blocked: "hand.raised.fill"
        case .completed: "checkmark.circle.fill"
        case .skipped: "arrow.uturn.forward.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .pending, .unknown: .neutral
        case .inProgress: .progress
        case .blocked: .danger
        case .completed: .success
        case .skipped: .warning
        }
    }

    var actionTitle: String {
        switch self {
        case .pending: "Reset to pending"
        case .inProgress: "Start phase"
        case .blocked: "Mark blocked"
        case .completed: "Complete phase"
        case .skipped: "Skip phase"
        case .unknown: "Change status"
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

extension VisitStatus {
    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .enRoute: "On the way"
        case .onSite: "On site"
        case .completed: "Completed"
        case .noAccess: "No access"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .scheduled: "calendar"
        case .enRoute: "car.fill"
        case .onSite: "mappin.and.ellipse"
        case .completed: "checkmark.circle.fill"
        case .noAccess: "door.left.hand.closed"
        case .cancelled: "xmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .scheduled, .unknown: .info
        case .enRoute: .progress
        case .onSite: .warning
        case .completed: .success
        case .noAccess, .cancelled: .danger
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

extension ServiceRequestStatus {
    var label: String {
        switch self {
        case .new: "New"
        case .triaged: "Triaged"
        case .assigned: "Assigned"
        case .inProgress: "In progress"
        case .onHold: "On hold"
        case .resolved: "Resolved"
        case .closed: "Closed"
        case .rejected: "Rejected"
        case .duplicate: "Duplicate"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .new: "sparkle"
        case .triaged: "line.3.horizontal.decrease.circle"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .inProgress: "play.circle.fill"
        case .onHold: "pause.circle.fill"
        case .resolved: "checkmark.seal.fill"
        case .closed: "lock.fill"
        case .rejected: "xmark.octagon.fill"
        case .duplicate: "square.on.square"
        case .unknown: "questionmark.circle"
        }
    }

    var tone: Tone {
        switch self {
        case .new: .info
        case .triaged, .assigned: .progress
        case .inProgress: .progress
        case .onHold: .warning
        case .resolved, .closed: .success
        case .rejected, .duplicate: .neutral
        case .unknown: .neutral
        }
    }

    var actionTitle: String {
        switch self {
        case .inProgress: "Start work"
        case .resolved: "Mark resolved"
        case .closed: "Close"
        default: "Mark \(label.lowercased())"
        }
    }

    var badge: StatusBadge { StatusBadge(text: label, systemImage: systemImage, tone: tone) }
}

extension ItemApprovalStatus {
    var badge: StatusBadge {
        switch self {
        case .pending: StatusBadge(text: "Awaiting approval", systemImage: "hourglass", tone: .warning)
        case .approved: StatusBadge(text: "Approved", systemImage: "checkmark.seal.fill", tone: .success)
        case .rejected: StatusBadge(text: "Rejected", systemImage: "xmark.seal.fill", tone: .danger)
        case .unknown: StatusBadge(text: "Unknown", systemImage: "questionmark.circle", tone: .neutral)
        }
    }
}

/// "Pending sync" marker for optimistic offline state.
struct PendingSyncBadge: View {
    var failed = false

    var body: some View {
        StatusBadge(text: failed ? "Sync failed" : "Waiting to sync",
                    systemImage: failed ? "exclamationmark.icloud.fill" : "icloud.and.arrow.up",
                    tone: failed ? .danger : .progress)
    }
}

/// Shown when content came from the offline cache.
struct CachedDataNotice: View {
    let savedAt: Date

    var body: some View {
        Label("Offline copy from \(savedAt.formatted(.relative(presentation: .named)))", systemImage: "externaldrive.badge.icloud")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Tone.warning.color)
            .accessibilityIdentifier("cachedDataNotice")
    }
}
