import SwiftUI

/// Shop analytics: the "What do I need?" survey funnel, where people stop, what they answer, what they were
/// recommended and the Trade sign-ups it led to (dashboard components/shop/analytics/SurveyPanel.tsx).
struct ShopSurveySections: View {
    let state: LoadState<ShopSurveyReport>
    let retry: () -> Void

    var body: some View {
        if let report = state.value {
            content(report)
        } else if let error = state.error {
            Section("“What do I need?” survey") {
                InlineErrorRow(error: error) { retry() }
            }
        } else {
            Section("“What do I need?” survey") {
                ProgressView("Loading the survey…").frame(maxWidth: .infinity)
            }
        }
    }

    private func tradeStats(_ r: ShopSurveyReport) -> [ShopStatCell] {
        var stats = [
            ShopStatCell(label: "Started from the survey", value: ShopAnalyticsFormat.count(r.applyByPlan.total)),
            ShopStatCell(label: "Yearly / monthly",
                         value: "\(ShopAnalyticsFormat.count(r.applyByPlan.y)) / \(ShopAnalyticsFormat.count(r.applyByPlan.m))"),
        ]
        if let trade = r.tradeSignups {
            stats.append(ShopStatCell(label: "All Trade checkouts", value: ShopAnalyticsFormat.count(trade.checkoutsStarted),
                                      hint: "Every Trade checkout in the period, survey or not"))
            stats.append(ShopStatCell(label: "Joined", value: ShopAnalyticsFormat.count(trade.joined),
                                      hint: "Every Trade join in the period, survey or not"))
        }
        return stats
    }

    @ViewBuilder
    private func content(_ r: ShopSurveyReport) -> some View {
        if r.visitors.isEmpty {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“What do I need?” survey: no visits in this period").font(.wsHeadline)
                        Text("The shop only starts sending survey steps after the privacy sign-off. Until then this stays empty. "
                             + "People who send their build still appear in Leads, with their answers.")
                            .font(.wsSubheadline).foregroundStyle(.secondary)
                        if let trade = r.tradeSignups {
                            Text("Trade in this period: \(ShopAnalyticsFormat.count(trade.checkoutsStarted)) started joining, "
                                 + "\(ShopAnalyticsFormat.count(trade.joined)) joined.")
                                .font(.wsCaption).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "list.clipboard")
                }
            }
        } else {
            Section {
                ShopFunnelView(steps: r.funnel.map { .init(label: ShopSurveyLabels.stage($0.stage), value: $0.visitors) })
            } header: {
                Text("“What do I need?” survey")
            } footer: {
                if !r.complete {
                    Text("Survey steps are kept for \(r.retentionMonths) months, so older parts of this period are missing.")
                }
            }

            if !r.dropoff.isEmpty {
                Section {
                    ForEach(r.dropoff) { step in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let number = step.step {
                                    Text("Step \(number)").font(.wsCaption).foregroundStyle(.secondary)
                                }
                                Text(step.questions.map { ShopSurveyLabels.question($0.question) }.joined(separator: " / "))
                                    .font(.wsSubheadline)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(ShopAnalyticsFormat.count(step.visitors)).font(.wsSubheadline.monospacedDigit())
                                if let lost = step.lostFromPrevious, lost > 0 {
                                    Text("\(ShopAnalyticsFormat.percent(lost)) stopped").font(.wsCaption)
                                        .foregroundStyle(Tone.danger.textColor)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Where people stop")
                } footer: {
                    Text("People who answered each question, and the share who stopped since the step before.")
                }
            }

            Section("Recommended") {
                ShopBarList(rows: r.resultsByProduct.prefix(6).map {
                    .init(id: $0.product, label: ShopSurveyLabels.product($0.product), value: $0.visitors)
                }, empty: "No recommendations shown")
            }

            Section("Trade") {
                ShopStatGrid(stats: tradeStats(r))
            }

            if !r.answers.isEmpty {
                Section {
                    ForEach(r.orderedAnswers) { question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(ShopSurveyLabels.question(question.question)).font(.wsSubheadline.weight(.semibold))
                            ShopBarList(rows: question.answers.prefix(5).map {
                                .init(id: $0.answer, label: ShopSurveyLabels.answer(question.question, $0.answer), value: $0.visitors)
                            }, empty: "No answers")
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("What people answered")
                } footer: {
                    Text("Each person’s final answer, if they went back and changed it.")
                }
            }
        }
    }
}
