import SwiftUI

/// A shortcut the person pinned to the tab bar: one of their work areas, or any app (server menu key).
/// Home and Apps are always on the tab bar; these fill the three places between them.
enum TabPin: Hashable, Sendable {
    case hub(NavigationPolicy.Home)
    case app(String)

    static let limit = 3

    var storageKey: String {
        switch self {
        case .hub(let hub): "hub:\(hub.key)"
        case .app(let key): "app:\(key)"
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("hub:"), let hub = NavigationPolicy.Home(key: String(storageKey.dropFirst(4))) {
            self = .hub(hub)
        } else if storageKey.hasPrefix("app:") {
            self = .app(String(storageKey.dropFirst(4)))
        } else {
            return nil
        }
    }
}

/// One place on the tab bar between Home and Apps, ready to draw.
struct TabSlot: Identifiable, Hashable {
    let pin: TabPin
    let title: String
    let systemImage: String
    var id: String { pin.storageKey }

    var tab: AppTab {
        switch pin {
        case .hub(let hub): .hub(hub)
        case .app(let key): .app(key)
        }
    }
}

enum TabBarLayout {
    /// The three places between Home and Apps: the person's pins (those still available to them in
    /// this workspace), or — when they pinned nothing — their busiest work areas.
    static func slots(policy: NavigationPolicy, catalog: AppCatalog, pins: [TabPin]?) -> [TabSlot] {
        let entries = Dictionary(catalog.groups.flatMap(\.entries).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        guard let pins, !pins.isEmpty else {
            return policy.tabs.map { TabSlot(pin: .hub($0), title: $0.title, systemImage: $0.systemImage) }
        }
        var slots: [TabSlot] = []
        for pin in pins where slots.count < TabPin.limit {
            switch pin {
            case .hub(let hub) where policy.available.contains(hub):
                slots.append(TabSlot(pin: pin, title: hub.title, systemImage: hub.systemImage))
            case .app(let key):
                if let entry = entries[key], NativeModules.destination(forKey: key) != nil {
                    slots.append(TabSlot(pin: pin, title: shortTitle(entry.name), systemImage: entry.systemImage))
                }
            default:
                continue
            }
        }
        return slots
    }

    /// Tab bar labels are short: "Purchase orders" → "Purchase orders" fits, longer names are cut at a word.
    static func shortTitle(_ name: String) -> String {
        guard name.count > 16 else { return name }
        let words = name.split(separator: " ")
        var title = ""
        for word in words where (title + " " + word).trimmingCharacters(in: .whitespaces).count <= 16 {
            title = (title + " " + word).trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? String(name.prefix(16)) : title
    }
}

/// Opens a work area that has no tab of its own, from Home.
struct HubScreenRoute: Hashable {
    let hub: NavigationPolicy.Home
}

// MARK: - Settings › Tab bar

/// Pin up to three shortcuts between Home and Apps: work areas or any app.
struct TabBarSettingsView: View {
    @Environment(SessionStore.self) private var session
    @State private var pins: [TabPin] = []
    @State private var prepared = false

    var body: some View {
        let policy = NavigationPolicy(session: session)
        let catalog = AppCatalog(menu: session.menu)
        let candidates = Self.candidates(policy: policy, catalog: catalog)
        List {
            Section {
                Label("Home", systemImage: "house").foregroundStyle(.secondaryText)
                if pins.isEmpty {
                    ForEach(TabBarLayout.slots(policy: policy, catalog: catalog, pins: nil)) { slot in
                        Label(slot.title, systemImage: slot.systemImage)
                    }
                    Text("Automatic: your busiest work areas. Pin your own below.")
                        .font(.wsFootnote).foregroundStyle(.secondaryText)
                } else {
                    ForEach(pins, id: \.self) { pin in
                        if let candidate = candidates.first(where: { $0.pin == pin }) {
                            Label(candidate.title, systemImage: candidate.systemImage)
                                .accessibilityIdentifier("tabBar.pinned.\(pin.storageKey)")
                        }
                    }
                    .onMove { pins.move(fromOffsets: $0, toOffset: $1); save() }
                    .onDelete { pins.remove(atOffsets: $0); save() }
                }
                Label("Apps", systemImage: "square.grid.2x2").foregroundStyle(.secondaryText)
            } header: {
                Text("Your tab bar")
            } footer: {
                Text("Home and Apps are always there. Pin up to \(TabPin.limit) shortcuts in between; drag to reorder, swipe to remove.")
            }

            ForEach(Self.sections(candidates), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { candidate in
                        let pinned = pins.contains(candidate.pin)
                        Button {
                            toggle(candidate.pin)
                        } label: {
                            HStack {
                                Label(candidate.title, systemImage: candidate.systemImage).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: pinned ? "pin.fill" : "pin")
                                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
                                    .accessibilityLabel(pinned ? "Pinned" : "Not pinned")
                            }
                        }
                        .frame(minHeight: 44)
                        .disabled(!pinned && pins.count >= TabPin.limit)
                        .accessibilityIdentifier("tabBar.option.\(candidate.pin.storageKey)")
                    }
                }
            }

            if !pins.isEmpty {
                Section {
                    Button("Go back to automatic") {
                        pins = []
                        save()
                    }
                    .accessibilityIdentifier("tabBar.automatic")
                }
            }
        }
        .environment(\.editMode, .constant(pins.isEmpty ? .inactive : .active))
        .navigationTitle("Tab bar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !prepared else { return }
            prepared = true
            pins = HomePreferences.shared.pins ?? []
        }
    }

    private func toggle(_ pin: TabPin) {
        if let index = pins.firstIndex(of: pin) {
            pins.remove(at: index)
        } else if pins.count < TabPin.limit {
            pins.append(pin)
        }
        save()
    }

    private func save() {
        HomePreferences.shared.setPins(pins.isEmpty ? nil : pins)
    }

    struct Candidate: Identifiable, Hashable {
        let pin: TabPin
        let title: String
        let systemImage: String
        let group: String
        var id: String { pin.storageKey }
    }

    /// Work areas first, then every app the person can open.
    static func candidates(policy: NavigationPolicy, catalog: AppCatalog) -> [Candidate] {
        var result = policy.available.map {
            Candidate(pin: .hub($0), title: $0.longTitle, systemImage: $0.systemImage, group: "Work areas")
        }
        for group in catalog.groups {
            for entry in group.entries {
                result.append(Candidate(pin: .app(entry.key), title: entry.name, systemImage: entry.systemImage,
                                        group: group.title))
            }
        }
        return result
    }

    static func sections(_ candidates: [Candidate]) -> [(title: String, items: [Candidate])] {
        var order: [String] = []
        var grouped: [String: [Candidate]] = [:]
        for candidate in candidates {
            if grouped[candidate.group] == nil { order.append(candidate.group) }
            grouped[candidate.group, default: []].append(candidate)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

/// "Pin to tab bar" / "Remove from tab bar", for an app's press-and-hold menu.
struct PinToTabBarButton: View {
    let pin: TabPin
    @Environment(SessionStore.self) private var session

    var body: some View {
        let preferences = HomePreferences.shared
        let current = TabBarLayout.slots(policy: NavigationPolicy(session: session), catalog: AppCatalog(menu: session.menu),
                                         pins: preferences.pins).map(\.pin)
        let pinned = current.contains(pin)
        Button {
            // From automatic, the bar keeps what it shows now and this replaces the last place.
            preferences.togglePin(pin, current: current)
        } label: {
            if pinned {
                Label("Remove from tab bar", systemImage: "pin.slash")
            } else {
                Label(current.count >= TabPin.limit ? "Pin to tab bar (replaces \(lastTitle(current)))" : "Pin to tab bar",
                      systemImage: "pin")
            }
        }
    }

    private func lastTitle(_ current: [TabPin]) -> String {
        guard let last = current.last else { return "the last" }
        switch last {
        case .hub(let hub): return hub.title
        case .app(let key): return AppCatalog(menu: session.menu).entry(forKey: key)?.name ?? "the last"
        }
    }
}
