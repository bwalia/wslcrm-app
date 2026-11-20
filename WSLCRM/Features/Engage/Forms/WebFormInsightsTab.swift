import Charts
import SwiftUI

/// The Insights tab: how the form performs (views → starts → responses per day, where people stop, where
/// responses come from) and what people answered (exact counts, plus an AI summary on demand).
struct WebFormInsightsTab: View {
    let form: WebFormDetail
    @Environment(\.services) private var services
    @State private var days = 30
    @State private var state: LoadState<WebFormAnalytics> = .idle
    @State private var summary: WebFormResponseSummary?
    @State private var summarising = false
    @State private var notice: EngageNotice?

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                    Text("Last year").tag(365)
                }
                .accessibilityIdentifier("forms.insights.period")
            }
            if let notice { Section { EngageNoticeBar(notice: notice) } }
            switch state {
            case .loaded(let data): performance(data)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            answers
        }
        .task(id: days) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func performance(_ data: WebFormAnalytics) -> some View {
        Section {
            EngageMetricGrid(metrics: [
                .init(title: "Views", value: data.views.formatted(), systemImage: "eye"),
                .init(title: data.completion.map { "Started · \(EngageFormat.percent($0, alreadyPercent: true)) finished" }
                        ?? "Started", value: data.starts.formatted(), systemImage: "hand.tap"),
                .init(title: data.conversion.map { "Responses · \(EngageFormat.percent($0, alreadyPercent: true)) of views" }
                        ?? "Responses", value: data.responses.formatted(), systemImage: "paperplane", tone: .success),
                .init(title: "Time to fill in (average)", value: data.averageSeconds.map { "\(Int($0)) s" } ?? "—",
                      systemImage: "timer", tone: .info),
            ])
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            .listRowBackground(Color.clear)
        }
        Section("Per day") {
            Chart {
                ForEach(data.series) { day in
                    if let date = day.date {
                        AreaMark(x: .value("Day", date, unit: .day), y: .value("Views", day.views),
                                 series: .value("What", "Views"))
                            .foregroundStyle(by: .value("What", "Views"))
                            .opacity(0.35)
                        AreaMark(x: .value("Day", date, unit: .day), y: .value("Responses", day.responses),
                                 series: .value("What", "Responses"))
                            .foregroundStyle(by: .value("What", "Responses"))
                            .opacity(0.6)
                    }
                }
            }
            .chartForegroundStyleScale(["Views": Color.gray, "Responses": Color.accentColor])
            .frame(height: 220)
            .accessibilityLabel("Views and responses per day")
        }
        Section("Where people stop") {
            if data.funnel.count > 1 || data.starts > 0 {
                let maximum = max(1, data.funnel.map(\.reached).max() ?? 1)
                ForEach(data.funnel, id: \.step) { step in
                    WebFormBar(label: "Step \(step.step)", value: step.reached, maximum: maximum)
                }
                WebFormBar(label: "Sent", value: data.responses, maximum: maximum)
            } else {
                Text("No visits yet.").foregroundStyle(.secondaryText)
            }
        }
        Section("Where responses come from") {
            if data.sources.isEmpty {
                Text("No responses yet.").foregroundStyle(.secondaryText)
            } else {
                let maximum = max(1, data.sources.map(\.responses).max() ?? 1)
                ForEach(data.sources, id: \.source) { source in
                    WebFormBar(label: source.source, value: source.responses, maximum: maximum)
                }
            }
        }
    }

    private var answers: some View {
        Section {
            HStack {
                Button {
                    Task { await summarise(numbersOnly: false) }
                } label: {
                    HStack { if summarising { ProgressView() }; Label(summary == nil ? "Summarise with AI" : "Summarise again",
                                                                      systemImage: "sparkles") }
                }
                .disabled(summarising)
                .accessibilityIdentifier("forms.insights.summarise")
                Spacer()
                Button("Counts only") { Task { await summarise(numbersOnly: true) } }
                    .buttonStyle(.borderless)
                    .disabled(summarising)
            }
            if let summary {
                if let text = summary.summary {
                    RichTextView(markdown: text)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                } else if let error = summary.summaryError {
                    Label(error, systemImage: "info.circle").foregroundStyle(Tone.warning.textColor)
                }
                ForEach(summary.questions.filter { !$0.counts.isEmpty || $0.average != nil }) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.label).font(.wsHeadline)
                        if let average = question.average {
                            Text("Average \(Self.number(average)) (from \(Self.number(question.min)) to "
                                 + "\(Self.number(question.max)), \(question.answered) answers)")
                                .font(.wsSubheadline).foregroundStyle(.secondaryText)
                        }
                        let maximum = max(1, question.counts.map(\.count).max() ?? 1)
                        ForEach(question.counts, id: \.label) { row in
                            WebFormBar(label: row.label, value: row.count, maximum: maximum)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: { Text("What people said") } footer: {
            Text("Counts are exact; the summary is written by AI from the latest 500 responses, without contact details.")
        }
    }

    static func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.webForms.analytics(form.uuid, days: days))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }

    private func summarise(numbersOnly: Bool) async {
        summarising = true
        defer { summarising = false }
        do {
            summary = try await services.webForms.summary(form.uuid, numbersOnly: numbersOnly)
            notice = nil
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

/// A labelled bar (counts, funnel steps, sources).
struct WebFormBar: View {
    let label: String
    let value: Int
    let maximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.wsSubheadline).lineLimit(2)
                Spacer()
                Text(value.formatted()).font(.wsSubheadline.weight(.semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(value) / CGFloat(max(1, maximum)))
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}
