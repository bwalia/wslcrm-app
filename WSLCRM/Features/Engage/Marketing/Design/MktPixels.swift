import Charts
import SwiftUI

/// Website pixels: a small script on the business's website that links visits and sales back to the
/// campaign that sent the visitor (`/pixels`). Reading needs Marketing analytics; changes need
/// Marketing settings (update), as the server checks.
struct MktPixelsView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var state: LoadState<[MktPixel]> = .idle
    @State private var creating = false
    @State private var notice: EngageNotice?
    @State private var opened: MktPixel?

    private var canWrite: Bool { session.permissions.can(.update, moduleName: Marketing.RBAC.settings) }

    var body: some View {
        List {
            switch state {
            case .loaded(let pixels) where pixels.isEmpty:
                MktPixelIntro(canCreate: canWrite) { creating = true }
            case .loaded(let pixels):
                Section {
                    ForEach(pixels) { pixel in
                        NavigationLink {
                            MktPixelDetailView(pixel: pixel) { _ in Task { await load() } }
                        } label: {
                            MktPixelRow(pixel: pixel)
                        }
                        .accessibilityIdentifier("mkt.pixel.\(pixel.uuid)")
                    }
                } footer: {
                    Text("Each pixel is the snippet for one website. Open one to install it, watch events arrive, "
                         + "see results, or change it.")
                }
            case .failed(let error):
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            default:
                EmptyView()
            }
        }
        .overlay { if state.value == nil, state.error == nil { SkeletonList() } }
        .safeAreaInset(edge: .top, spacing: 0) { EngageNoticeBar(notice: notice) }
        .navigationTitle("Pixels & attribution")
        .toolbar {
            if canWrite {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New pixel", systemImage: "plus") }
                        .accessibilityIdentifier("mkt.pixels.new")
                }
            }
        }
        .navigationDestination(item: $opened) { pixel in
            MktPixelDetailView(pixel: pixel, firstNotice: "Pixel created. Copy the snippet below into your website, "
                               + "then check Live events.") { _ in Task { await load() } }
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                MktPixelNewForm { created in
                    Task {
                        await load()
                        if let created { opened = created } else { notice = .done("Pixel created.") }
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await services.marketingDesign.pixels())
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if state.value == nil { state = .failed(apiError) } else { notice = .failed(apiError) }
        }
    }
}

struct MktPixelRow: View {
    let pixel: MktPixel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pixel.name).font(.wsHeadline)
            StatusBadge(text: pixel.statusLabel, systemImage: pixel.isActive ? "dot.radiowaves.left.and.right" : "pause.circle",
                        tone: pixel.statusTone)
            Text("\(pixel.events24h.formatted()) events in the last 24 hours")
                .font(.wsSubheadline).foregroundStyle(.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What a pixel does, before there is one.
private struct MktPixelIntro: View {
    let canCreate: Bool
    let create: () -> Void

    private let steps = [
        ("Email click", "Someone clicks a link in your campaign; the link carries a private code."),
        ("Website visit", "The pixel on your website reads the code and links the visit to that person and campaign."),
        ("Sale or sign-up", "When they buy or sign up, your website tells the pixel what happened and its value."),
        ("Money per campaign", "Your marketing reports show the sales each campaign brought in."),
    ]

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("See which emails bring in sales", systemImage: "scope").font(.wsHeadline)
                Text("A tracking pixel is a small script you add to your website. It connects what happens on your site "
                     + "to the campaign that sent the visitor, so you see which emails drive sales, not only opens and clicks.")
                    .font(.wsSubheadline).foregroundStyle(.secondaryText)
            }
            .padding(.vertical, 4)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(index + 1): \(step.0)").font(.wsSubheadline.weight(.semibold))
                    Text(step.1).font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
            Text("Privacy first: your own website’s cookies only, and visitors who ask not to be tracked (Global Privacy "
                 + "Control or Do Not Track) are counted without cookies.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if canCreate {
                Button(action: create) { Label("Create your first pixel", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mkt.pixels.createFirst")
            } else {
                Text("Ask someone who can change marketing settings to create one.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        }
    }
}

/// A new pixel: its name, the websites it accepts events from, and the attribution window.
private struct MktPixelNewForm: View {
    let created: (MktPixel?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.services) private var services
    @State private var name = ""
    @State private var domains = ""
    @State private var window = "30"
    @State private var problem: String?
    @State private var error: APIError?
    @State private var saving = false

    var body: some View {
        Form {
            if let error { Section { InlineErrorRow(error: error) } }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Tone.danger.textColor) }
            }
            Section("Name") {
                TextField("e.g. Main website", text: $name)
                    .accessibilityIdentifier("mkt.pixel.name")
            }
            Section {
                TextField("example.com, shop.example.com", text: $domains, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("mkt.pixel.domains")
            } header: {
                Text("Allowed websites (optional)")
            } footer: {
                Text("Separate them with commas or new lines. Leave empty to accept any website.")
            }
            Section {
                TextField("30", text: $window)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("mkt.pixel.window")
            } header: {
                Text("Attribution window (days)")
            } footer: {
                Text("How long after an email click a sale still counts for that campaign (1 to 90 days).")
            }
        }
        .navigationTitle("New pixel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Creating…" : "Create pixel") { Task { await save() } }
                    .disabled(saving)
                    .accessibilityIdentifier("mkt.pixel.create")
            }
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { problem = "Give the pixel a name."; return }
        if let issue = MktPixel.windowProblem(window) { problem = issue; return }
        problem = nil
        saving = true
        defer { saving = false }
        do {
            let pixel = try await services.marketingDesign.createPixel(name: trimmed, domains: MktPixel.parseDomains(domains),
                                                                       windowDays: Int(window.trimmingCharacters(in: .whitespaces)) ?? 30)
            created(pixel)
            dismiss()
        } catch {
            self.error = error.asAPIError
        }
    }
}

// MARK: - One pixel

struct MktPixelDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case install, live, performance, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .install: "Install"
            case .live: "Live"
            case .performance: "Results"
            case .settings: "Settings"
            }
        }
    }

    let onChanged: (MktPixel?) -> Void
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var pixel: MktPixel
    @State private var tab: Tab = .install
    @State private var notice: EngageNotice?

    init(pixel: MktPixel, firstNotice: String? = nil, onChanged: @escaping (MktPixel?) -> Void) {
        self.onChanged = onChanged
        _pixel = State(initialValue: pixel)
        _notice = State(initialValue: firstNotice.map { .done($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(text: pixel.statusLabel, systemImage: pixel.isActive ? "dot.radiowaves.left.and.right" : "pause.circle",
                            tone: pixel.statusTone)
                Text(summary).font(.wsFootnote).foregroundStyle(.secondaryText)
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mkt.pixel.tabs")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            EngageNoticeBar(notice: notice)
            switch tab {
            case .install: MktPixelInstallTab(pixel: pixel)
            case .live: MktPixelLiveTab(pixel: pixel) { Task { await refresh() } }
            case .performance: MktPixelPerformanceTab(pixel: pixel)
            case .settings:
                MktPixelSettingsTab(pixel: pixel) { updated in
                    pixel = updated
                    onChanged(updated)
                } deleted: {
                    onChanged(nil)
                    dismiss()
                }
            }
        }
        .navigationTitle(pixel.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tab) { _, _ in notice = nil }
    }

    private var summary: String {
        let last = pixel.lastEventAt.flatMap { Formatters.relative(APIDate.parse($0)) } ?? "never"
        return "Last event \(last) · \(pixel.conversions30d.formatted()) sales or sign-ups in 30 days · "
            + "\(pixel.attributionWindowDays)-day window"
    }

    private func refresh() async {
        if let fresh = try? await services.engage.get(Marketing.path("/pixels/\(pixel.uuid)")).engageRecord {
            pixel = MktPixel(record: fresh)
            onChanged(pixel)
        }
    }
}

/// Code to copy, with a Copy and a Share button.
struct MktPixelCode: View {
    let title: String
    let code: String
    var copyLabel = "Copy"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.wsSubheadline.weight(.semibold))
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : copyLabel, systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("mkt.code.copy.\(title)")
                ShareLink(item: code) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Share \(title)")
            }
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("\(title) code")
        }
        .padding(.vertical, 4)
    }
}

/// Install: the snippet and the code for sales, sign-ups, identifying people and consent.
private struct MktPixelInstallTab: View {
    let pixel: MktPixel
    @Environment(\.services) private var services
    @State private var state: LoadState<Record> = .idle

    var body: some View {
        List {
            switch state {
            case .loaded(let snippet): sections(snippet)
            case .failed(let error): Section { InlineErrorRow(error: error) { Task { await load() } } }
            default: Section { HStack { Spacer(); ProgressView("Loading the snippet…"); Spacer() } }
            }
        }
        .task(id: pixel.publicKey) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func sections(_ snippet: Record) -> some View {
        Section {
            MktPixelCode(title: "Install snippet", code: snippet.string("html") ?? "", copyLabel: "Copy snippet")
            Text("Google Tag Manager: make a Custom HTML tag, paste the snippet, and set it to fire on All Pages.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            LabeledContent("Public key") {
                Text(snippet.string("public_key") ?? pixel.publicKey).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            if !pixel.allowedDomains.isEmpty {
                Text("Accepts events only from: \(pixel.allowedDomains.joined(separator: ", "))")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
            }
        } header: {
            Text("1. Paste this before </head> on every page")
        }
        Section {
            Text("Sales count for the campaign that brought the visitor within \(pixel.attributionWindowDays) days. "
                 + "Sending order_id stops the same order being counted twice.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let purchase = snippet.string("examples.purchase") { MktPixelCode(title: "Purchase", code: purchase) }
            if let lead = snippet.string("examples.lead") { MktPixelCode(title: "Lead", code: lead) }
        } header: {
            Text("2. Track sales and sign-ups")
        }
        Section {
            Text("People you identify are matched to your CRM contacts, so their earlier visits count too.")
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let identify = snippet.string("examples.identify") { MktPixelCode(title: "Identify", code: identify) }
        } header: {
            Text("3. Optionally, identify people after they log in or sign up")
        }
        Section {
            if let consent = snippet.string("examples.consent") { MktPixelCode(title: "Consent", code: consent) }
        } header: {
            Text("4. Respect consent: mkt('consent', false) or true")
        }
        Section("What the pixel does by itself") {
            ForEach([
                "Honours Global Privacy Control and Do Not Track by going cookieless: events are counted but not linked across visits.",
                "Uses your own website’s cookies only, never third-party tracking.",
                "Reads the _mkt code from campaign email links, then removes it from the address bar.",
                "Counts page changes in single-page apps (history changes and back/forward) as page views.",
                "Sends events from data-mkt-event attributes on things people click.",
            ], id: \.self) { line in
                Label(line, systemImage: "checkmark").font(.wsFootnote)
            }
        }
        if let declarative = snippet.string("examples.declarative") {
            Section {
                Text("Add data-mkt-event (and optional JSON data-mkt-props) to anything people click.")
                    .font(.wsFootnote).foregroundStyle(.secondaryText)
                MktPixelCode(title: "Event without code", code: declarative)
            } header: {
                Text("Tracking without writing code")
            }
        }
        let endpoints = [("Script", snippet.string("script_url")), ("Events API", snippet.string("events_url")),
                         ("Pixel picture", snippet.string("gif_url"))].compactMap { item in item.1.map { (item.0, $0) } }
        if !endpoints.isEmpty {
            Section {
                if snippet.string("gif_url") != nil {
                    Text("The snippet already counts page views when JavaScript is off. For email-safe or server-side "
                         + "tracking, request the picture address with &e=<event_name> added.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                }
                ForEach(endpoints, id: \.0) { name, value in CopyableRow(label: name, value: value) }
            } header: {
                Text("Addresses")
            }
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            guard let snippet = try await services.marketingDesign.snippet(pixel.uuid) else {
                throw ResourceService.problem(404, "The install snippet isn’t available.")
            }
            state = .loaded(snippet)
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            state = .failed(apiError)
        }
    }
}

/// Live events: new ones appear every few seconds while the tab is open.
private struct MktPixelLiveTab: View {
    let pixel: MktPixel
    let onActivity: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var events: [MktPixelEvent] = []
    @State private var loaded = false
    @State private var paused = false
    @State private var filter: MktPixelEvent.Filter = .all
    @State private var notice: EngageNotice?
    @State private var sending = false

    private var visible: [MktPixelEvent] { events.filter { $0.matches(filter) } }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { !paused }, set: { paused = !$0 })) {
                    Label(paused ? "Paused" : "Live: refreshing every 3 seconds",
                          systemImage: paused ? "pause.circle" : "dot.radiowaves.left.and.right")
                }
                .accessibilityIdentifier("mkt.live.toggle")
                Picker("Show", selection: $filter) {
                    ForEach(MktPixelEvent.Filter.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("mkt.live.filter")
                if session.permissions.can(.update, moduleName: Marketing.RBAC.settings) {
                    Button { Task { await sendTest() } } label: {
                        Label(sending ? "Sending…" : "Send a test event", systemImage: "paperplane")
                    }
                    .disabled(sending || !pixel.isActive)
                    .accessibilityIdentifier("mkt.live.test")
                }
                if !pixel.isActive {
                    Text("This pixel is paused: new events are turned away until you switch it back on in Settings.")
                        .font(.wsFootnote).foregroundStyle(Tone.warning.textColor)
                }
            }
            EngageNoticeBar(notice: notice)
            Section {
                if !loaded {
                    HStack { Spacer(); ProgressView("Loading events…"); Spacer() }
                } else if visible.isEmpty {
                    Text(events.isEmpty ? "No events yet. Put the snippet on your website and open a page, or send a test event."
                                        : "No events match this filter.")
                        .foregroundStyle(.secondaryText)
                } else {
                    ForEach(visible) { event in MktPixelEventRow(event: event) }
                }
            } footer: {
                if events.count >= 200 { Text("Showing the latest 200 events.") }
            }
        }
        .task(id: paused) {
            guard !paused else { return }
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func poll() async {
        do {
            let incoming = try await services.marketingDesign.events(pixel.uuid, afterID: events.map(\.id).max() ?? 0)
            events = MktPixelEvent.merge(events, incoming)
            if case .failed = notice { notice = nil }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            notice = .failed(apiError)
        }
        loaded = true
    }

    private func sendTest() async {
        sending = true
        defer { sending = false }
        do {
            try await services.marketingDesign.testEvent(pixel.uuid)
            notice = .done("Test event sent. It appears below within a few seconds.")
            await poll()
            onActivity()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }
}

private struct MktPixelEventRow: View {
    let event: MktPixelEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(event.name).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Spacer()
                if let time = event.createdAt.flatMap({ Formatters.time(APIDate.parse($0)) }) {
                    Text(time).font(.wsCaption).foregroundStyle(.secondaryText)
                }
            }
            HStack(spacing: 6) {
                if event.isConversion {
                    Pill(text: "Sale or sign-up" + (event.value.map { " · " + EngageFormat.money($0, currency: event.currency) } ?? ""),
                         systemImage: "sterlingsign.circle", foreground: Tone.success.textColor,
                         background: Tone.success.color.opacity(0.14))
                }
                if event.isTest { Pill(text: "Test", systemImage: "flask") }
                if event.isBot { Pill(text: "Bot", systemImage: "cpu") }
                if let contact = event.contactName { Pill(text: contact, systemImage: "person") }
            }
            if let campaign = event.campaignUUID {
                NavigationLink(value: EngageArea.route(Marketing.Screen.campaign, campaign)) {
                    Label("Campaign: \(event.campaignName ?? "open it")", systemImage: "megaphone").font(.wsFootnote)
                }
            }
            if let path = MktPixelEvent.path(event.url) {
                Text(path).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(1)
            }
            let extras = [
                event.utmSource.map { "utm: " + [$0, event.utmMedium, event.utmCampaign].compactMap { $0 }.joined(separator: " / ") },
                event.orderID.map { "order: \($0)" },
                MktPixelEvent.path(event.referrer).map { "came from: \($0)" },
            ].compactMap { $0 }
            if !extras.isEmpty {
                Text(extras.joined(separator: " · ")).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Results: totals, daily activity, top events and pages, forwarding to ad platforms.
private struct MktPixelPerformanceTab: View {
    let pixel: MktPixel
    @Environment(\.services) private var services
    @State private var days = 30
    @State private var stats: Record?
    @State private var error: APIError?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("mkt.performance.days")
                if loading { ProgressView() }
            }
            if let error { Section { InlineErrorRow(error: error) { Task { await load() } } } }
            if let stats { content(stats) }
        }
        .task(id: days) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func content(_ stats: Record) -> some View {
        Section {
            EngageMetricGrid(metrics: [
                .init(title: "Events (\(count(stats.double("totals.bot_events"))) from bots)",
                      value: count(stats.double("totals.events")), systemImage: "waveform.path.ecg"),
                .init(title: "Visitors (\(count(stats.double("totals.identified"))) known)",
                      value: count(stats.double("totals.visitors")), systemImage: "person.2"),
                .init(title: "Sales and sign-ups (\(count(stats.double("totals.attributed_events"))) events from campaigns)",
                      value: count(stats.double("totals.conversions")), systemImage: "cart", tone: .success),
                .init(title: "Money from tracked sales", value: EngageFormat.money(stats.double("totals.revenue")),
                      systemImage: "sterlingsign.circle", tone: .success),
            ])
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        Section("Daily activity") {
            let daily = MktPixelDay.rows(stats)
            if daily.isEmpty {
                Text("No events in this period.").foregroundStyle(.secondaryText)
            } else {
                Chart {
                    ForEach(daily) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Page views", day.pageViews))
                            .foregroundStyle(by: .value("Measure", "Page views"))
                        LineMark(x: .value("Day", day.date, unit: .day), y: .value("Count", day.visitors))
                            .foregroundStyle(by: .value("Measure", "Visitors"))
                        LineMark(x: .value("Day", day.date, unit: .day), y: .value("Count", day.conversions))
                            .foregroundStyle(by: .value("Measure", "Sales and sign-ups"))
                    }
                }
                .frame(height: 220)
                .accessibilityLabel("Daily page views, visitors and sales over \(days) days")
            }
        }
        Section("Top events") {
            let rows = stats.records("top_events")
            if rows.isEmpty { Text("None yet.").foregroundStyle(.secondaryText) }
            ForEach(rows) { row in
                LabeledContent(row.string("event_name") ?? "event", value: count(row.double("n")))
            }
        }
        Section("Top pages") {
            let rows = stats.records("top_pages")
            if rows.isEmpty { Text("None yet.").foregroundStyle(.secondaryText) }
            ForEach(rows) { row in
                LabeledContent(row.string("page") ?? "(unknown)", value: count(row.double("n")))
            }
        }
        Section {
            let rows = stats.records("forwards")
            if rows.isEmpty {
                Text("Nothing forwarded. Set up Meta Conversions API or Google Analytics 4 in Marketing settings.")
                    .foregroundStyle(.secondaryText)
            }
            ForEach(rows) { row in
                LabeledContent("\(MktPixelForwarding.destination(row.string("destination"))) · \(MktPixelForwarding.status(row.string("status")))",
                               value: count(row.double("n")))
            }
        } header: {
            Text("Sent on to ad platforms")
        } footer: {
            Text("Sales passed to ad platforms from the server in the last \(days) days.")
        }
    }

    private func count(_ value: Double?) -> String { EngageFormat.count(value ?? 0) }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            stats = try await services.marketingDesign.stats(pixel.uuid, days: days)
            error = nil
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            self.error = apiError  // the last figures stay on screen
        }
    }
}

/// One day of a pixel's activity, for the chart.
struct MktPixelDay: Identifiable, Hashable {
    let date: Date
    let pageViews: Int
    let visitors: Int
    let conversions: Int
    var id: Date { date }

    static func rows(_ stats: Record) -> [MktPixelDay] {
        stats.records("daily").compactMap { row in
            guard let day = row.string("day").flatMap({ CalendarDay(string: String($0.prefix(10))) }) else { return nil }
            return MktPixelDay(date: day.date(), pageViews: row.int("page_views") ?? 0, visitors: row.int("visitors") ?? 0,
                               conversions: row.int("conversions") ?? 0)
        }
    }
}

/// Forwarding to ad platforms, in plain words.
enum MktPixelForwarding {
    static func destination(_ value: String?) -> String {
        switch value {
        case "meta": "Meta Conversions API"
        case "ga4": "Google Analytics 4"
        case "error": "Error"
        default: Formatters.humanize(value)
        }
    }

    static func status(_ value: String?) -> String {
        switch value {
        case "sent": "Sent"
        case "failed": "Failed"
        case "dry_run": "Test mode (not sent)"
        default: Formatters.humanize(value)
        }
    }

    static func tone(_ value: String?) -> Tone {
        switch value {
        case "sent": .success
        case "failed": .danger
        case "dry_run": .warning
        default: .neutral
        }
    }
}

/// Settings: name, websites, window, on/off; rotate the key; delete; recent forwards.
private struct MktPixelSettingsTab: View {
    let pixel: MktPixel
    let updated: (MktPixel) -> Void
    let deleted: () -> Void
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var name: String
    @State private var domains: String
    @State private var window: String
    @State private var active: Bool
    @State private var busy = false
    @State private var notice: EngageNotice?
    @State private var forwards: LoadState<[Record]> = .idle
    @State private var confirmingRotate = false
    @State private var confirmingDelete = false

    init(pixel: MktPixel, updated: @escaping (MktPixel) -> Void, deleted: @escaping () -> Void) {
        self.pixel = pixel
        self.updated = updated
        self.deleted = deleted
        _name = State(initialValue: pixel.name)
        _domains = State(initialValue: pixel.allowedDomains.joined(separator: "\n"))
        _window = State(initialValue: String(pixel.attributionWindowDays))
        _active = State(initialValue: pixel.isActive)
    }

    private var canWrite: Bool { session.permissions.can(.update, moduleName: Marketing.RBAC.settings) }

    var body: some View {
        Form {
            EngageNoticeBar(notice: notice)
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("mkt.pixelSettings.name")
                TextField("example.com", text: $domains, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("mkt.pixelSettings.domains")
                LabeledContent("Attribution window (days)") {
                    TextField("30", text: $window).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("mkt.pixelSettings.window")
                }
                Toggle("On: accept events from this pixel", isOn: $active)
                    .accessibilityIdentifier("mkt.pixelSettings.active")
                if canWrite {
                    Button { Task { await save() } } label: { Label("Save settings", systemImage: "square.and.arrow.down") }
                        .disabled(busy)
                        .accessibilityIdentifier("mkt.pixelSettings.save")
                }
            } header: {
                Text("General")
            } footer: {
                Text("Allowed websites: one per line or separated by commas; events from other websites are turned "
                     + "away. Leave empty to accept any. The window is how long after an email click a sale still "
                     + "counts for that campaign (1 to 90 days).")
            }
            .disabled(!canWrite)
            Section {
                LabeledContent("Public key") {
                    Text(pixel.publicKey).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                }
                if canWrite {
                    Button { confirmingRotate = true } label: { Label("Change the key", systemImage: "key") }
                        .disabled(busy)
                        .accessibilityIdentifier("mkt.pixelSettings.rotate")
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete pixel", systemImage: "trash") }
                        .disabled(busy)
                        .accessibilityIdentifier("mkt.pixelSettings.delete")
                }
            } header: {
                Text("Key")
            } footer: {
                Text("Change the key if the snippet was copied somewhere it shouldn’t be: the old snippet stops working.")
            }
            Section {
                switch forwards {
                case .loaded(let rows) where rows.isEmpty:
                    Text("Nothing forwarded yet.").foregroundStyle(.secondaryText)
                case .loaded(let rows):
                    ForEach(rows) { row in MktForwardRow(row: row) }
                case .failed(let error):
                    InlineErrorRow(error: error) { Task { await loadForwards() } }
                default:
                    ProgressView()
                }
                NavigationLink(value: NativeScreenRoute(Marketing.Screen.settings)) {
                    Label("Marketing settings (ad platform details)", systemImage: "gearshape")
                }
            } header: {
                Text("Sent on to ad platforms")
            } footer: {
                Text("Sales can be passed from the server to the Meta Conversions API and Google Analytics 4, which ad "
                     + "blockers can’t stop. Recent ones from all pixels:")
            }
        }
        .task { await loadForwards() }
        .confirmationDialog("Change the key for “\(pixel.name)”?", isPresented: $confirmingRotate, titleVisibility: .visible) {
            Button("Change the key", role: .destructive) { Task { await rotate() } }
        } message: {
            Text("The current snippet stops working straight away. You must paste the new snippet on every website that uses this pixel.")
        }
        .confirmationDialog("Delete pixel “\(pixel.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete pixel", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Tracking stops on every website using it and its event history is removed. This can’t be undone.")
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { notice = .info("Give the pixel a name."); return }
        if let issue = MktPixel.windowProblem(window) { notice = .info(issue); return }
        busy = true
        defer { busy = false }
        do {
            let result = try await services.marketingDesign.updatePixel(
                pixel.uuid, name: trimmed, domains: MktPixel.parseDomains(domains),
                windowDays: Int(window.trimmingCharacters(in: .whitespaces)) ?? 30, active: active)
            if let result { updated(result) }
            notice = .done("Settings saved.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func rotate() async {
        busy = true
        defer { busy = false }
        do {
            if let result = try await services.marketingDesign.rotateKey(pixel.uuid) { updated(result) }
            notice = .done("Key changed. Copy the new snippet from Install and paste it on your website.")
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func delete() async {
        busy = true
        defer { busy = false }
        do {
            try await services.marketingDesign.deletePixel(pixel.uuid)
            deleted()
        } catch {
            notice = .failed(error.asAPIError)
        }
    }

    private func loadForwards() async {
        do {
            forwards = .loaded(try await services.marketingDesign.forwards(limit: 25))
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            forwards = .failed(apiError)
        }
    }
}

private struct MktForwardRow: View {
    let row: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(MktPixelForwarding.destination(row.string("destination"))).font(.wsSubheadline.weight(.semibold))
                Spacer()
                let status = MktPixelForwarding.status(row.string("status")) + (row.int("http_status").map { " (\($0))" } ?? "")
                Text(status).font(.wsFootnote).foregroundStyle(MktPixelForwarding.tone(row.string("status")).textColor)
            }
            Text([row.string("event_name"), EngageFormat.dateTime(row.string("created_at"))].compactMap { $0 }
                .joined(separator: " · "))
                .font(.wsFootnote).foregroundStyle(.secondaryText)
            if let response = row.string("response") {
                Text(response).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondaryText).lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
