import SwiftUI

/// Marketing → Overview: the getting-started steps, results for the last 30 days (once a website
/// pixel exists), campaigns and delivery numbers, the best campaigns, the pixel's state, and the way
/// into every other marketing screen.
struct MktOverviewView: View {
    @Environment(\.services) private var services
    @State private var stats: Record?
    @State private var pixels: [Record]?
    @State private var unattributed: Record?
    @State private var progress: MktCampProgress?
    @State private var testMode = false
    @State private var error: APIError?
    @State private var loaded = false
    @State private var askAI: MktCampAskAIRequest?

    private var api: MktCampAPI { services.marketingCampaigns }
    private var hasPixels: Bool { !(pixels ?? []).isEmpty }

    var body: some View {
        List {
            Section {
                EngageIntro(text: "Emails and texts with permission first, website tracking and sales results.",
                            systemImage: "megaphone")
                NavigationLink(value: NativeScreenRoute(Marketing.Screen.guide)) {
                    Label("Getting started guide", systemImage: "book")
                }
                .accessibilityIdentifier("mkt.overview.guide")
            }
            if testMode { Section { MktCampTestModeBanner() } }
            MktCampJourneySection(progress: progress, askAI: $askAI, full: true)
            if let error { Section { InlineErrorRow(error: error) { Task { await load() } } } }
            if let stats {
                if hasPixels { results(stats) }
                delivery(stats)
                topCampaigns(stats)
                if hasPixels { pixelSection }
            }
            Section("Marketing") {
                navRow(Marketing.Screen.studio, "Studio", "Design emails and texts, with personal details and previews.",
                       "paintpalette")
                navRow(Marketing.Screen.campaigns, "Campaigns", "Write, test, schedule and measure email and text sends.",
                       "paperplane")
                navRow(Marketing.Screen.lists, "Lists", "Groups of contacts who said yes to hearing from you.", "person.2")
                navRow(Marketing.Screen.unsubscribed, "Unsubscribed", "Everyone who asked to stop, and addresses you blocked.",
                       "nosign")
                navRow(Marketing.Screen.conversations, "Replies", "Replies to your campaigns, sorted by what they say.",
                       "bubble.left.and.bubble.right")
                navRow(Marketing.Screen.pixels, "Website pixel", "Track visits and sales on your website.",
                       "dot.radiowaves.left.and.right")
                navRow(Marketing.Screen.settings, "Settings", "Test mode, your address in emails, sending limits.",
                       "gearshape")
            }
        }
        .overlay { if !loaded { SkeletonList() } }
        .navigationTitle("Marketing")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $askAI) { request in
            NavigationStack { MktCampAskAISheet(request: request) { Task { await load() } } }
        }
    }

    private func navRow(_ screen: String, _ title: String, _ detail: String, _ image: String) -> some View {
        NavigationLink(value: NativeScreenRoute(screen)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.wsHeadline)
                    Text(detail).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
            } icon: {
                Image(systemName: image)
            }
        }
        .accessibilityIdentifier("mkt.overview.nav.\(screen)")
    }

    // MARK: Sections

    private func results(_ stats: Record) -> some View {
        let conversions = stats.double("conversions_30d.conversions") ?? 0
        let attributed = stats.double("conversions_30d.attributed") ?? 0
        let share: Double? = conversions > 0 ? attributed / conversions * 100 : nil
        let revenue = stats.double("conversions_30d.revenue") ?? 0
        let pixelCount = Int(stats.double("web.pixels") ?? 0)
        return Section {
            MktCampTileGrid(tiles: [
                MktCampTile(label: "Sales and sign-ups", value: MktCampFormat.int(conversions)),
                MktCampTile(label: "Revenue", value: MktCampFormat.money(revenue), tone: revenue > 0 ? .success : nil),
                MktCampTile(label: "From campaigns", value: share.map { MktCampFormat.pct($0) } ?? "—",
                            hint: "\(MktCampFormat.int(attributed)) of \(MktCampFormat.int(conversions))"),
                MktCampTile(label: "Website visitors (24 h)", value: MktCampFormat.int(stats.double("web.visitors_24h")),
                            hint: "\(MktCampFormat.int(stats.double("web.events_24h"))) events · \(pixelCount) "
                                + "pixel\(pixelCount == 1 ? "" : "s")"),
            ])
            if let unattributed, (unattributed.double("conversions") ?? 0) > 0 {
                Text("\(MktCampFormat.int(unattributed.double("conversions"))) sales worth "
                     + "\(MktCampFormat.money(unattributed.double("revenue"))) had no campaign click before them "
                     + "(direct visits, search or other channels).")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("Results — last 30 days")
        }
    }

    private func delivery(_ stats: Record) -> some View {
        Section {
            MktCampTileGrid(tiles: [
                MktCampTile(label: "Active campaigns", value: MktCampFormat.int(stats.double("campaigns.active")),
                            hint: "\(MktCampFormat.int(stats.double("campaigns.paused"))) paused"),
                MktCampTile(label: "Drafts", value: MktCampFormat.int(stats.double("campaigns.drafts")),
                            hint: "\(MktCampFormat.int(stats.double("campaigns.completed"))) sent"),
                MktCampTile(label: "Accepted", value: MktCampFormat.int(stats.double("deliveries.accepted")),
                            hint: "\(MktCampFormat.int(stats.double("deliveries.delivered"))) confirmed delivered"),
                MktCampTile(label: "Opened (estimate)", value: MktCampFormat.int(stats.double("deliveries.opened_est")),
                            hint: "Robots left out"),
                MktCampTile(label: "Clicked", value: MktCampFormat.int(stats.double("deliveries.clicked"))),
                MktCampTile(label: "Bounced", value: MktCampFormat.int(stats.double("deliveries.bounced")),
                            hint: "\(MktCampFormat.int(stats.double("deliveries.failed"))) failed"),
                MktCampTile(label: "Skipped", value: MktCampFormat.int(stats.double("deliveries.skipped")),
                            hint: "No permission, unsubscribed or over a limit"),
                MktCampTile(label: "Unsubscribed", value: MktCampFormat.int(stats.double("unsubscribed_30d")),
                            hint: "Last 30 days"),
            ])
        } header: {
            Text("Campaigns and delivery")
        } footer: {
            Text("Opens are estimates — mail scanners and privacy services open emails too. Accepted isn’t the same as "
                 + "delivered.")
        }
    }

    private func topCampaigns(_ stats: Record) -> some View {
        let rows = stats.records("top_campaigns").map(MktCampResult.init)
            .sorted { ($0.revenue ?? 0) > ($1.revenue ?? 0) }
            .prefix(8)
        return Section {
            if rows.isEmpty {
                Text("No campaign results yet.").foregroundStyle(.secondaryText)
            }
            ForEach(Array(rows)) { row in
                NavigationLink {
                    MktCampaignDetailView(uuid: row.uuid, seed: nil)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.wsHeadline)
                        if let status = row.status {
                            FieldBadge(field: FieldSpec("status", "Status", .status(MktCampStatus.style)), value: status)
                        }
                        Text(Self.resultLine(row, withSales: hasPixels))
                            .font(.wsFootnote.monospacedDigit()).foregroundStyle(.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("mkt.overview.campaign.\(row.uuid)")
            }
            NavigationLink(value: NativeScreenRoute(Marketing.Screen.campaigns)) {
                Label("All campaigns", systemImage: "list.bullet")
            }
            .accessibilityIdentifier("mkt.overview.allCampaigns")
        } header: {
            Text(hasPixels ? "Best campaigns by revenue" : "Campaign results")
        }
    }

    static func resultLine(_ row: MktCampResult, withSales: Bool) -> String {
        var parts = ["\(MktCampFormat.int(row.sent)) sent", "\(MktCampFormat.pct(row.clickRate)) clicked"]
        if withSales {
            parts.append("\(MktCampFormat.int(row.conversions)) sales")
            parts.append(MktCampFormat.money(row.revenue))
        }
        return parts.joined(separator: " · ")
    }

    private var pixelSection: some View {
        let list = pixels ?? []
        let needsInstall = !list.isEmpty && !list.contains { $0.string("install_status") == "active" }
        return Section {
            ForEach(Array(list.prefix(5)), id: \.id) { pixel in
                let state = Self.pixelState(pixel.string("install_status"))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pixel.string("name") ?? "Pixel").font(.wsHeadline)
                        Label(state.label, systemImage: state.symbol).font(.wsFootnote).foregroundStyle(state.tone.textColor)
                    }
                    Spacer()
                    Text("\(MktCampFormat.int(pixel.double("events_24h"))) events / 24 h")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
            NavigationLink(value: NativeScreenRoute(Marketing.Screen.pixels)) {
                Label(needsInstall ? "Finish installing" : "Manage pixels", systemImage: "arrow.right.circle")
            }
            .accessibilityIdentifier("mkt.overview.pixels")
        } header: {
            Text("Website pixel")
        }
    }

    static func pixelState(_ raw: String?) -> (label: String, symbol: String, tone: Tone) {
        switch raw {
        case "active": ("Receiving events", "checkmark.circle", .success)
        case "stale": ("No events in 24 hours", "exclamationmark.triangle", .danger)
        default: ("Waiting for the first event", "hourglass", .warning)
        }
    }

    private func load() async {
        async let overview = api.overview()
        async let pixelRows = try? api.pixels()
        async let attribution = try? api.attribution(days: 30)
        async let sending = try? api.sending()
        async let steps = api.progress()
        do {
            stats = try await overview
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError {} else { self.error = apiError }
        }
        pixels = await pixelRows ?? []
        unattributed = (await attribution)?.object("unattributed")
        testMode = (await sending)?.bool("dry_run") ?? false
        progress = await steps
        loaded = true
    }
}
