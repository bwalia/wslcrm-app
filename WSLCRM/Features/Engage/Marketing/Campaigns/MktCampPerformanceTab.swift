import Charts
import SwiftUI

/// The Results tab: how many got it, opened, clicked and bought; the funnel; engagement hour by
/// hour; the A/B versions and which is winning; the most clicked links; robots left out; replies.
struct MktCampPerformanceSections: View {
    @Bindable var model: MktCampDetailModel

    var body: some View {
        if model.status.hasNoSendsYet {
            Section {
                ContentUnavailableView("No sends yet", systemImage: "chart.bar",
                                       description: Text("Results appear here once the campaign starts sending."))
            }
        } else if let data = model.analytics {
            refreshSection
            kpis(data)
            funnel(data)
            timeline(data)
            variants(data)
            links(data)
            robotsAndReplies(data)
        } else if let error = model.analyticsError {
            Section { InlineErrorRow(error: error) { Task { await model.loadAnalytics() } } }
        } else {
            Section { HStack { ProgressView(); Text("Loading results…").foregroundStyle(.secondaryText) } }
        }
    }

    private var refreshSection: some View {
        Section {
            Button { Task { await model.loadAnalytics() } } label: { Label("Refresh results", systemImage: "arrow.clockwise") }
                .accessibilityIdentifier("mkt.results.refresh")
        } footer: {
            Text((model.status == .sending ? "Updates by itself every 15 seconds while sending. " : "")
                 + (model.analyticsUpdated.map { "Updated \(Formatters.time($0) ?? "")." } ?? ""))
        }
    }

    private func kpis(_ data: MktCampAnalytics) -> some View {
        let currency = data.currency
        let bounce = data.number("rates.bounce_rate")
        let conversions = data.number("conversions.conversions") ?? 0
        return Section {
            MktCampTileGrid(tiles: [
                MktCampTile(label: "Sent", value: MktCampFormat.int(data.number("deliveries.sent")),
                            hint: "\(MktCampFormat.int(data.number("deliveries.queued"))) waiting · "
                                + "\(MktCampFormat.int(data.number("deliveries.skipped"))) skipped"),
                MktCampTile(label: "Opened (estimate)", value: MktCampFormat.pct(data.number("rates.open_rate")),
                            hint: "Robots left out"),
                MktCampTile(label: "Clicked", value: MktCampFormat.pct(data.number("rates.click_rate")),
                            hint: "\(MktCampFormat.int(data.number("deliveries.clicked"))) people clicked"),
                MktCampTile(label: "Clicked after opening", value: MktCampFormat.pct(data.number("rates.click_to_open_rate")),
                            hint: "Clicks ÷ estimated opens"),
                MktCampTile(label: "Sales and sign-ups", value: MktCampFormat.int(conversions),
                            hint: "\(MktCampFormat.int(data.number("conversions.converters"))) people · "
                                + MktCampFormat.pct(data.number("rates.conversion_rate")),
                            tone: conversions > 0 ? .success : nil),
                MktCampTile(label: "Revenue", value: MktCampFormat.money(data.number("conversions.revenue"), currency: currency),
                            hint: "Credited to the last link clicked"),
                MktCampTile(label: "Revenue per person",
                            value: MktCampFormat.money(data.number("rates.revenue_per_recipient"), currency: currency)),
                MktCampTile(label: "Bounced", value: MktCampFormat.pct(bounce),
                            hint: "\(MktCampFormat.int(data.number("deliveries.bounced"))) bounced · "
                                + "\(MktCampFormat.int(data.number("deliveries.failed"))) failed",
                            tone: (bounce ?? 0) >= 5 ? .danger : nil),
            ])
        } header: {
            Text("Key numbers")
        }
    }

    @ViewBuilder
    private func funnel(_ data: MktCampAnalytics) -> some View {
        let sent = data.number("deliveries.sent") ?? 0
        let top = max(1, data.funnel.map(\.count).max() ?? 1)
        Section {
            if data.funnel.isEmpty || sent == 0 {
                Text("Nothing delivered yet.").foregroundStyle(.secondaryText)
            }
            ForEach(Array(data.funnel.enumerated()), id: \.offset) { index, stage in
                let previous = index > 0 ? data.funnel[index - 1].count : 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text((MktCampAnalytics.stageLabels[stage.stage] ?? Formatters.humanize(stage.stage))
                             + (stage.estimated ? " (estimate)" : ""))
                        Spacer()
                        Text(MktCampFormat.int(stage.count)).monospacedDigit()
                        if index > 0, previous > 0, previous > stage.count {
                            Text("−\(((previous - stage.count) / previous * 100).formatted(.number.precision(.fractionLength(1))))%")
                                .font(.wsCaption).foregroundStyle(.secondaryText)
                        }
                    }
                    .font(.wsSubheadline)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
                                    .frame(width: max(4, proxy.size.width * stage.count / top))
                            }
                    }
                    .frame(height: 10)
                    .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("From sent to sale")
        }
    }

    @ViewBuilder
    private func timeline(_ data: MktCampAnalytics) -> some View {
        Section {
            if data.timeline.isEmpty {
                Text("No opens or clicks recorded yet.").foregroundStyle(.secondaryText)
            } else {
                Chart {
                    ForEach(data.timeline, id: \.hour) { hour in
                        LineMark(x: .value("Hour", hour.hour), y: .value("Count", hour.opens))
                            .foregroundStyle(by: .value("What", "Opens (estimate)"))
                        LineMark(x: .value("Hour", hour.hour), y: .value("Count", hour.clicks))
                            .foregroundStyle(by: .value("What", "Clicks"))
                        LineMark(x: .value("Hour", hour.hour), y: .value("Count", hour.conversions))
                            .foregroundStyle(by: .value("What", "Sales and sign-ups"))
                    }
                }
                .chartLegend(position: .bottom)
                .frame(height: 220)
                .accessibilityLabel("Opens, clicks and sales hour by hour")
            }
        } header: {
            Text("Hour by hour (first 7 days)")
        }
    }

    @ViewBuilder
    private func variants(_ data: MktCampAnalytics) -> some View {
        if !data.variants.isEmpty {
            Section {
                if let winner = data.winner {
                    Label(MktCampAnalytics.winnerText(winner), systemImage: "trophy")
                        .font(.wsSubheadline)
                        .foregroundStyle(winner.significant ? Tone.success.textColor : Tone.info.textColor)
                }
                ForEach(data.variants, id: \.key) { variant in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(variant.key == "_default" ? "Main email" : "Version \(variant.key)").font(.wsHeadline)
                            if data.winner?.variant == variant.key {
                                Image(systemName: "trophy.fill").foregroundStyle(Tone.warning.textColor)
                                    .accessibilityLabel("Ahead")
                            }
                            Spacer()
                            Text("\(MktCampFormat.int(variant.sent)) sent").font(.wsSubheadline).monospacedDigit()
                        }
                        Text("Opened \(MktCampFormat.pct(variant.openRate)) · clicked \(MktCampFormat.pct(variant.clickRate)) · "
                             + "bought \(MktCampFormat.pct(variant.conversionRate)) · \(MktCampFormat.money(variant.revenue, currency: data.currency))")
                            .font(.wsFootnote).foregroundStyle(.secondaryText).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("A/B versions")
            }
        }
    }

    private func links(_ data: MktCampAnalytics) -> some View {
        Section {
            if data.links.isEmpty {
                Text("No clicks counted yet.").foregroundStyle(.secondaryText)
            }
            ForEach(data.links, id: \.url) { link in
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.url).font(.wsSubheadline).lineLimit(2).textSelection(.enabled)
                    Text("\(MktCampFormat.int(link.clicks)) clicks · \(MktCampFormat.int(link.unique)) people")
                        .font(.wsFootnote).foregroundStyle(.secondaryText).monospacedDigit()
                }
            }
        } header: {
            Text("Most clicked links")
        }
    }

    private func robotsAndReplies(_ data: MktCampAnalytics) -> some View {
        Group {
            Section {
                LabeledContent("Opens (people)", value: MktCampFormat.int(data.number("tracking.opens_raw")))
                LabeledContent("Clicks (people)", value: MktCampFormat.int(data.number("tracking.clicks_raw")))
                LabeledContent("Robot opens left out", value: MktCampFormat.int(data.number("tracking.bot_opens")))
                LabeledContent("Robot clicks left out", value: MktCampFormat.int(data.number("tracking.bot_clicks")))
            } header: {
                Text("Robots left out")
            } footer: {
                Text("Mail scanners and privacy services open pictures and links before people do. Those aren’t counted "
                     + "in the numbers above.")
            }
            Section {
                if data.replies.isEmpty {
                    Text("No replies sorted yet.").foregroundStyle(.secondaryText)
                }
                ForEach(Array(data.replies.enumerated()), id: \.offset) { _, reply in
                    LabeledContent(MktReplyStyle.label(reply.classification), value: MktCampFormat.int(reply.count))
                }
            } header: {
                Text("Replies")
            }
        }
    }
}
