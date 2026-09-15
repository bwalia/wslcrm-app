import SwiftUI

struct VisitSummaryRow: View {
    let visit: Visit
    var showsJob = true
    var pending = false
    var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let start = visit.scheduledStart {
                    Text(timeRange(start: start, end: visit.scheduledEnd))
                        .font(.headline.monospacedDigit())
                }
                Spacer()
                visit.status.badge
            }
            if showsJob {
                Text("\(visit.jobNumber) · \(visit.jobTitle)")
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
            } else if let engineer = visit.engineerName {
                Label(engineer, systemImage: "person.fill").font(.subheadline)
            }
            if showsJob, let customer = visit.customerName {
                Label(customer, systemImage: "person").font(.subheadline)
            }
            if let address = visit.fullAddress {
                Label(address, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let phase = visit.phaseName {
                Label(phase, systemImage: "list.bullet.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if pending { PendingSyncBadge(failed: failed) }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func timeRange(start: Date, end: Date?) -> String {
        let startText = start.formatted(date: .omitted, time: .shortened)
        guard let end else { return startText }
        return "\(startText) – \(end.formatted(date: .omitted, time: .shortened))"
    }
}
