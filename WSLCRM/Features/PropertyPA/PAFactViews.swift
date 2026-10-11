import SwiftUI

// Routes and the pieces every PA screen shares: facts with their sources, the "unconfirmed
// judgement" label, and stated gaps ("grounded or silent").

struct PATodayRoute: Hashable { var manager = false }
struct PAPrepareRoute: Hashable { let opportunityUuid: String; let title: String }
struct PAHandoffRoute: Hashable { let uuid: String }
struct PACaptureRoute: Hashable { let uuid: String }

/// The badge on anything that's someone's judgement rather than a known fact.
struct PAUnconfirmedBadge: View {
    let by: String?

    var body: some View {
        Text(by.map { "\($0.uppercased())'S JUDGEMENT · UNCONFIRMED" } ?? "JUDGEMENT · UNCONFIRMED")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(Tone.warning.textColor)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Tone.warning.color, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .accessibilityLabel(by.map { "Unconfirmed judgement by \($0)" } ?? "Unconfirmed judgement")
    }
}

/// Opens the app's own screen for a source when it has one; otherwise shows where it came from.
struct PASourceChip: View {
    let source: PASource

    @ViewBuilder
    var body: some View {
        switch (source.type, source.uuid) {
        case ("lead", let uuid?): link(PDLeadRoute(uuid: uuid))
        case ("deal", let uuid?): link(PDDealRoute(uuid: uuid))
        case ("task", let uuid?): link(PDTaskRoute(uuid: uuid))
        default: chip(linked: false)
        }
    }

    private func link(_ route: some Hashable) -> some View {
        NavigationLink(value: route) { chip(linked: true) }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the record")
    }

    private func chip(linked: Bool) -> some View {
        Label(source.label ?? Formatters.humanize(source.type), systemImage: Self.icon(source.type))
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(linked ? Tone.info.textColor : .secondaryText)
            .background(Tone.info.color.opacity(linked ? 0.10 : 0.04), in: Capsule())
            .accessibilityLabel("Source: \(source.label ?? Formatters.humanize(source.type))")
    }

    /// Lead, deal and task have screens in the app; the rest are shown as labels.
    static func opensInApp(_ source: PASource) -> Bool {
        source.uuid != nil && ["lead", "deal", "task"].contains(source.type)
    }

    static func icon(_ type: String) -> String {
        switch type {
        case "lead", "contact": "person"
        case "deal", "opportunity": "house"
        case "task": "checklist"
        case "interaction": "bubble.left.and.bubble.right"
        case "event": "calendar"
        case "offer": "sterlingsign.circle"
        case "document": "doc"
        case "knowledge": "book.closed"
        default: "link"
        }
    }
}

struct PAFactRow: View {
    let fact: PAFact

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fact.text)
                .font(.body)
                .italic(fact.isUnconfirmedJudgement)
            HStack(spacing: 6) {
                if fact.isUnconfirmedJudgement { PAUnconfirmedBadge(by: fact.by) }
                if let source = fact.source { PASourceChip(source: source) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What the PA doesn't know, said out loud.
struct PAGapsSection: View {
    let gaps: [String]

    var body: some View {
        if !gaps.isEmpty {
            Section("Not known yet") {
                ForEach(gaps, id: \.self) { gap in
                    Label(gap, systemImage: "questionmark.circle")
                        .foregroundStyle(.secondaryText)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("pa.gap")
                }
            }
        }
    }
}

/// While a model call runs: what's happening, never a frozen screen.
struct PAWorkingView: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.headline)
            if let detail { Text(detail).font(.footnote).foregroundStyle(.secondaryText).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
    }
}
