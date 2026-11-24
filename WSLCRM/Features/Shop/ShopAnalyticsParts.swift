import Charts
import SwiftUI

// The building blocks of the analytics screen (the dashboard's components/shop/analytics/parts.tsx).

/// A headline figure with its change vs the previous period and a short line under it.
struct ShopKPITile: View {
    let label: String
    let value: String
    var change: Double?
    /// For costs (abandoned carts): down is good news.
    var lowerIsBetter = false
    var sub: String?
    let systemImage: String
    var hint: String?
    @State private var showingHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Label(label, systemImage: systemImage)
                    .font(.wsCaption.weight(.semibold))
                    .foregroundStyle(Color(.label))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let hint {
                    Button { showingHint = true } label: {
                        Image(systemName: "info.circle").font(.wsCaption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("About \(label)")
                    .popover(isPresented: $showingHint) {
                        Text(hint).font(.wsFootnote).padding().frame(idealWidth: 260)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            Text(value)
                .font(.wsTitle2.bold().monospacedDigit())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let text = ShopAnalyticsFormat.change(change) {
                    ShopChangePill(text: text, good: ShopAnalyticsFormat.isGood(change, lowerIsBetter: lowerIsBetter),
                                   up: (change ?? 0) > 0)
                }
                if let sub {
                    Text(sub).font(.wsCaption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint ?? "")
    }
}

/// "+25%" in green (good), red (bad) or grey (flat).
struct ShopChangePill: View {
    let text: String
    let good: Bool?
    let up: Bool

    var body: some View {
        let tone: Tone = good == nil ? .neutral : (good == true ? .success : .danger)
        Label(text, systemImage: good == nil ? "minus" : (up ? "arrow.up.right" : "arrow.down.right"))
            .font(.wsCaption.weight(.semibold).monospacedDigit())
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tone.textColor)
            .background(tone.color.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(text) vs the previous period")
    }
}

/// A small labelled figure (the dashboard's Stat).
struct ShopStatCell: View {
    let label: String
    let value: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.wsCaption).foregroundStyle(.secondary)
            Text(value).font(.wsHeadline.monospacedDigit())
            if let hint {
                Text(hint).font(.wsCaption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Two columns of stat cells.
struct ShopStatGrid: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let stats: [ShopStatCell]

    var body: some View {
        LazyVGrid(columns: .tiles(sizeClass, spacing: 8), spacing: 8) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in stat }
        }
    }
}

/// Steps of a funnel, each bar a share of the first, with the rate from the step before.
struct ShopFunnelView: View {
    struct Step: Hashable {
        let label: String
        let value: Int
        var note: String?
    }

    let steps: [Step]

    var body: some View {
        let top = steps.first?.value ?? 0
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let share = top > 0 ? Double(step.value) / Double(top) : 0
                let previous = index > 0 ? steps[index - 1].value : nil
                let rate = previous.flatMap { $0 > 0 ? Double(step.value) / Double($0) : nil }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(step.label).font(.wsSubheadline.weight(.medium))
                        Spacer()
                        Text(ShopAnalyticsFormat.count(step.value)).font(.wsSubheadline.weight(.semibold).monospacedDigit())
                        if let rate {
                            Text("\(ShopAnalyticsFormat.percent(rate, places: 0)) of previous")
                                .font(.wsCaption).foregroundStyle(.secondary)
                        }
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(Color.accentColor.opacity(1 - Double(index) * 0.18))
                                .frame(width: proxy.size.width * max(share, step.value > 0 ? 0.02 : 0))
                        }
                    }
                    .frame(height: 10)
                    .accessibilityHidden(true)
                    if let note = step.note {
                        Text(note).font(.wsCaption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A ranked list with a bar behind each row (the dashboard's BarList).
struct ShopBarList: View {
    struct Row: Hashable, Identifiable {
        let id: String
        let label: String
        let value: Int
        var extra: String?
    }

    let rows: [Row]
    let empty: String

    var body: some View {
        if rows.isEmpty {
            if !empty.isEmpty {
                Text(empty).font(.wsSubheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            }
        } else {
            let top = max(rows.map(\.value).max() ?? 1, 1)
            VStack(spacing: 6) {
                ForEach(rows) { row in
                    HStack {
                        Text(row.label).font(.wsSubheadline).lineLimit(2)
                        Spacer()
                        Text(ShopAnalyticsFormat.count(row.value)).font(.wsSubheadline.weight(.semibold).monospacedDigit())
                        if let extra = row.extra {
                            Text(extra).font(.wsCaption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(alignment: .leading) {
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: proxy.size.width * Double(row.value) / Double(top))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// A label and a figure on one line (the dashboard's Row in a breakdown).
struct ShopBreakdownRow: View {
    let label: String
    let value: String
    var muted = false
    var strong = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(muted ? .secondary : .primary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(strong ? .semibold : .regular)
                .foregroundStyle(muted ? .secondary : .primary)
        }
        .font(.wsSubheadline)
        .accessibilityElement(children: .combine)
    }
}

/// The trend: revenue as an area, counts as bars, per day, week or month. Touch to read a bucket.
struct ShopTrendChart: View {
    let series: [ShopAnalyticsPoint]
    let bucket: ShopAnalyticsBucket
    let metric: ShopTrendMetric
    @State private var selected: Date?

    private struct Point: Identifiable {
        let date: Date
        let label: String
        let value: Int
        var id: Date { date }
    }

    private var points: [Point] {
        series.compactMap { point in
            guard let day = CalendarDay(string: point.bucket) else { return nil }
            return Point(date: day.date(), label: ShopAnalyticsFormat.bucketLabel(point.bucket, kind: bucket),
                         value: point.value(metric))
        }
    }

    private var unit: Calendar.Component {
        switch bucket {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    var body: some View {
        let points = points
        if points.allSatisfy({ $0.value == 0 }) {
            ContentUnavailableView("No \(metric.label.lowercased()) in this period", systemImage: "chart.bar")
                .frame(height: 220)
        } else {
            let picked = selected.flatMap { date in points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if let picked {
                        Text("\(picked.label): \(format(picked.value)) \(metric.label.lowercased())")
                    } else {
                        Text("Touch the chart to read a \(bucket.rawValue).")
                    }
                }
                .font(.wsCaption).foregroundStyle(.secondary)
                Chart {
                    ForEach(points) { point in
                        if metric.isMoney {
                            AreaMark(x: .value("Period", point.date, unit: unit), y: .value(metric.label, Double(point.value) / 100))
                                .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0)],
                                                                startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Period", point.date, unit: unit), y: .value(metric.label, Double(point.value) / 100))
                                .foregroundStyle(Color.accentColor)
                                .interpolationMethod(.monotone)
                        } else {
                            BarMark(x: .value("Period", point.date, unit: unit), y: .value(metric.label, point.value))
                                .foregroundStyle(Color.accentColor)
                                .cornerRadius(3)
                        }
                    }
                    if let picked {
                        RuleMark(x: .value("Selected", picked.date, unit: unit))
                            .foregroundStyle(Color.secondary.opacity(0.4))
                    }
                }
                .chartXSelection(value: $selected)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if metric.isMoney, let pounds = value.as(Double.self) {
                                Text(ShopAnalyticsFormat.compactPounds(pounds))
                            } else if let count = value.as(Int.self) {
                                Text(count, format: .number)
                            } else if let count = value.as(Double.self) {
                                Text(count, format: .number.precision(.fractionLength(0)))
                            }
                        }
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("\(metric.label) per \(bucket.rawValue)")
            }
        }
    }

    private func format(_ value: Int) -> String {
        metric.isMoney ? ShopAnalyticsFormat.money(value) : ShopAnalyticsFormat.count(value)
    }
}
