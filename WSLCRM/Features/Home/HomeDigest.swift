import SwiftUI

// MARK: - What needs the person today

/// One thing on Home's "Needs you today": a count from one of the person's own modules, and where
/// tapping it goes.
struct HomeSignal: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let count: Int
    let systemImage: String
    let tone: Tone
    /// The work hub it belongs to (opens that tab when it has one).
    let hub: NavigationPolicy.Home?
    /// The server menu key of the screen it opens (`NativeModules`).
    let menuKey: String
}

/// Reads what needs the person across the modules in their own menu. Every source is optional:
/// one failing (or switched off for the workspace) never hides the others.
@MainActor
@Observable
final class HomeDigest {
    private(set) var signals: [HomeSignal] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// Work per hub, for ordering the person's work areas.
    private(set) var activity: [NavigationPolicy.Home: Int] = [:]

    /// The modules Home can summarise for this person (nothing to load means no "Today" section).
    static func sources(session: SessionStore) -> Set<Source> {
        let menu = session.permissions.menuKeys
        var sources: Set<Source> = []
        if menu.contains("shop") { sources.insert(.shop) }
        if menu.contains("crm_leads") { sources.insert(.leads) }
        if menu.contains("my_tasks") || menu.contains(AppMenu.projectsKey) { sources.insert(.tasks) }
        if menu.contains("invoices") { sources.insert(.invoices) }
        if menu.contains("field_service_jobs") || menu.contains("field_service_visits") { sources.insert(.fieldService) }
        if session.propertyDeals != nil { sources.insert(.deals) }
        if session.propertyPA != nil { sources.insert(.pa) }
        return sources
    }

    enum Source: Hashable, Sendable { case shop, leads, tasks, invoices, fieldService, deals, pa }

    func load(session: SessionStore, services: Services) async {
        let sources = Self.sources(session: session)
        guard !sources.isEmpty else {
            signals = []
            hasLoaded = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        let isEngineer = session.policy.isEngineerRole

        async let shop = sources.contains(.shop) ? try? await services.shop.dashboard() : nil
        async let steps = sources.contains(.leads) ? try? await services.leads.mySteps() : nil
        async let tasks = sources.contains(.tasks) ? try? await services.kanban.myTasks(page: 1, perPage: 50) : nil
        async let overdueInvoices = sources.contains(.invoices)
            ? try? await services.invoices.invoices(search: "", status: .overdue, page: 1, perPage: 1) : nil
        async let fieldService = sources.contains(.fieldService) ? try? await services.fieldService.stats() : nil
        async let deals = sources.contains(.deals) ? try? await services.propertyDeals.today().value : nil
        async let pa = sources.contains(.pa) ? try? await services.propertyPA.briefing().value : nil

        let digest = await Self.signals(shop: shop, steps: steps, tasks: tasks?.items, overdueInvoices: overdueInvoices?.total,
                                        fieldService: fieldService, deals: deals, pa: pa, isEngineer: isEngineer)
        signals = digest.signals
        activity = digest.activity
        hasLoaded = true
        HomePreferences.shared.record(activity: digest.activity)
    }

    /// Turns each module's summary into signals (kept apart so it can be unit-tested).
    nonisolated static func signals(shop: ShopKPIs?, steps: LeadMySteps?, tasks: [KanbanTask]?, overdueInvoices: Int?,
                                    fieldService: FieldServiceStats?, deals: PDToday?, pa: PAServerBriefing?,
                                    isEngineer: Bool, now: Date = Date(), calendar: Calendar = .current)
        -> (signals: [HomeSignal], activity: [NavigationPolicy.Home: Int]) {
        var signals: [HomeSignal] = []
        var activity: [NavigationPolicy.Home: Int] = [:]
        func add(_ id: String, _ title: String, _ count: Int, _ symbol: String, _ tone: Tone,
                 hub: NavigationPolicy.Home?, key: String) {
            guard count > 0 else { return }
            signals.append(HomeSignal(id: id, title: title, count: count, systemImage: symbol, tone: tone, hub: hub, menuKey: key))
            if let hub { activity[hub, default: 0] += count }
        }

        if let shop {
            add("shop.payment", "Orders waiting for payment", shop.pendingPayment, "creditcard", .warning, hub: .shop, key: "shop")
            add("shop.fulfil", "Orders to send", shop.awaitingFulfilment, "shippingbox", .progress, hub: .shop, key: "shop")
            add("shop.quotes", "Open quotes", shop.openQuotes, "doc.text", .info, hub: .shop, key: "shop")
            add("shop.stock", "Products low on stock", shop.lowStockCount, "cube.box", .warning, hub: .shop, key: "shop")
        }
        if let steps {
            add("leads.overdue", "Lead follow-ups overdue", steps.overdue.count, "exclamationmark.triangle", .danger,
                hub: .leads, key: "crm_leads")
            add("leads.today", "Lead follow-ups today", steps.today.count, "phone", .info, hub: .leads, key: "crm_leads")
            let meetings = steps.meetings.filter { $0.startsAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
            add("leads.meetings", "Meetings today", meetings.count, "calendar", .info, hub: .leads, key: "crm_leads")
            if steps.isManager {
                add("leads.unassigned", "Leads with no owner", steps.unassigned, "person.crop.circle.badge.questionmark",
                    .warning, hub: .leads, key: "crm_leads")
            }
        }
        if let tasks {
            let open = tasks.filter { $0.completedAt == nil && $0.status != .completed && $0.status != .cancelled }
            let startOfToday = calendar.startOfDay(for: now)
            let overdue = open.filter { ($0.dueDate ?? .distantFuture) < startOfToday }.count
            let today = open.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false }.count
            add("tasks.overdue", "Tasks overdue", overdue, "exclamationmark.circle", .danger, hub: .tasks, key: "my_tasks")
            add("tasks.today", "Tasks due today", today, "checklist", .info, hub: .tasks, key: "my_tasks")
        }
        if let overdueInvoices {
            add("invoices.overdue", "Invoices overdue", overdueInvoices, "doc.text.magnifyingglass", .danger, hub: nil, key: "invoices")
        }
        if let fieldService {
            let hub: NavigationPolicy.Home = isEngineer ? .myWork : .fieldService
            add("fs.visits", "Visits today", fieldService.visitsToday, "calendar", .info, hub: hub,
                key: isEngineer ? "field_service_visits" : "field_service_jobs")
            add("fs.overdue", "Jobs overdue", fieldService.overdueJobs, "exclamationmark.triangle", .danger, hub: .fieldService,
                key: "field_service_jobs")
            add("fs.onsite", "Engineers on site now", fieldService.engineersOnSite, "mappin.and.ellipse", .success,
                hub: .fieldService, key: "field_service_jobs")
        }
        if let deals {
            add("deals.overdue", "Deal tasks overdue", deals.counts.overdue ?? 0, "exclamationmark.triangle", .danger,
                hub: .propertyDeals, key: "plugin:property_deals:today")
            add("deals.today", "Deal tasks today", deals.counts.dueToday ?? 0, "house.and.flag", .info,
                hub: .propertyDeals, key: "plugin:property_deals:today")
            add("deals.approvals", "Approvals waiting", deals.approvalsWaitingCount ?? deals.approvalsWaiting.count,
                "checkmark.seal", .warning, hub: .propertyDeals, key: "plugin:property_deals:approvals")
        }
        if let pa {
            add("pa.handoffs", "Handed to you", pa.handoffsForMe.count, "arrow.right.circle", .warning,
                hub: .propertyPA, key: "plugin:property_pa:today")
            add("pa.events", "Coming up", pa.eventsSoon.count, "calendar", .info, hub: .propertyPA,
                key: "plugin:property_pa:today")
            add("pa.opportunities", "Opportunities to act on", pa.opportunities.count, "sparkles", .progress,
                hub: .propertyPA, key: "plugin:property_pa:today")
        }
        return (signals, activity)
    }
}

// MARK: - The person's work areas, in their order

/// Per person and workspace: how much work each hub had last time (orders the work areas by what
/// actually needs them) and the order they chose themselves in "Edit Home".
@MainActor
@Observable
final class HomePreferences {
    static let shared = HomePreferences()

    /// Ordering used this session: fixed when the session starts, so tabs never jump while in use.
    private(set) var activity: [NavigationPolicy.Home: Int] = [:]
    private(set) var order: [NavigationPolicy.Home]?
    private(set) var hidden: Set<NavigationPolicy.Home> = []
    private var scope: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Loads this person's preferences for this workspace (call when the workspace is chosen).
    func activate(user: String, workspace: String) {
        let key = "home.\(user).\(workspace)"
        guard scope != key else { return }
        scope = key
        activity = Self.decodeActivity(defaults.dictionary(forKey: "\(key).activity"))
        order = (defaults.stringArray(forKey: "\(key).order")).map { $0.compactMap(NavigationPolicy.Home.init(key:)) }
        hidden = Set((defaults.stringArray(forKey: "\(key).hidden") ?? []).compactMap(NavigationPolicy.Home.init(key:)))
    }

    /// Remembers today's work for the next launch. The very first time (nothing remembered yet)
    /// it applies at once, so a new person's work areas are right from the first day.
    func record(activity latest: [NavigationPolicy.Home: Int]) {
        guard let scope else { return }
        let firstTime = defaults.object(forKey: "\(scope).activity") == nil
        defaults.set(Dictionary(uniqueKeysWithValues: latest.map { ($0.key.key, $0.value) }), forKey: "\(scope).activity")
        if firstTime { activity = latest }
    }

    /// The person's own order (visible hubs first, in order) and the hubs they hid.
    func choose(order: [NavigationPolicy.Home], hidden: Set<NavigationPolicy.Home>) {
        guard let scope else { return }
        self.order = order
        self.hidden = hidden
        defaults.set(order.map(\.key), forKey: "\(scope).order")
        defaults.set(hidden.map(\.key), forKey: "\(scope).hidden")
    }

    /// Back to the automatic order (by what needs the person).
    func reset() {
        guard let scope else { return }
        order = nil
        hidden = []
        defaults.removeObject(forKey: "\(scope).order")
        defaults.removeObject(forKey: "\(scope).hidden")
    }

    private static func decodeActivity(_ raw: [String: Any]?) -> [NavigationPolicy.Home: Int] {
        var result: [NavigationPolicy.Home: Int] = [:]
        for (key, value) in raw ?? [:] {
            if let hub = NavigationPolicy.Home(key: key), let count = value as? Int { result[hub] = count }
        }
        return result
    }
}

// MARK: - Edit Home

/// Choose which work areas appear on Home and the tab bar, and in what order.
struct EditHomeSheet: View {
    let available: [NavigationPolicy.Home]
    let current: [NavigationPolicy.Home]
    @Environment(\.dismiss) private var dismiss
    @State private var order: [NavigationPolicy.Home] = []
    @State private var shown: Set<NavigationPolicy.Home> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { hub in
                        Toggle(isOn: Binding(get: { shown.contains(hub) },
                                             set: { on in if on { shown.insert(hub) } else { shown.remove(hub) } })) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hub.longTitle).font(.wsHeadline)
                                    Text(hub.tagline).font(.wsFootnote).foregroundStyle(.secondaryText)
                                }
                            } icon: {
                                AppIconTile(systemImage: hub.systemImage, color: hub.color, size: 32)
                            }
                        }
                        .accessibilityIdentifier("editHome.\(hub.key)")
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Your work areas")
                } footer: {
                    Text("Drag to change the order. The first three are on the tab bar; everything is always in Apps.")
                }
                Section {
                    Button("Order them by what needs me") {
                        HomePreferences.shared.reset()
                        dismiss()
                    }
                    .accessibilityIdentifier("editHome.automatic")
                } footer: {
                    Text("The app puts the area with the most waiting for you first.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        HomePreferences.shared.choose(order: order.filter(shown.contains),
                                                      hidden: Set(order.filter { !shown.contains($0) }))
                        dismiss()
                    }
                    .disabled(shown.isEmpty)
                    .accessibilityIdentifier("editHome.done")
                }
            }
            .onAppear {
                order = current + available.filter { !current.contains($0) }
                shown = Set(current)
            }
        }
    }
}
