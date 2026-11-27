import SwiftUI

// MARK: - What the palette lists

/// One line in the ⌘K search: a record the server found (`GET /api/v2/search`, `RecordSearchModel`), a page of the
/// person's menu, a recent search, or "Ask AI about …". Records come first, grouped by kind, then pages, then the
/// assistant, as on the web (`opsapi-dashboard/components/layout/GlobalSearch.tsx`).
struct CommandPaletteItem: Identifiable, Equatable {
    enum Action: Equatable {
        case record(RecordSearchTarget)
        case page(AppCatalog.Entry)
        case ask(String)
        /// A recent search: puts it back in the field.
        case recent(String)
    }

    let id: String
    let section: String
    let title: String
    let subtitle: String?
    let systemImage: String
    var color: Color = .secondary
    let action: Action

    /// Records, then pages, then the assistant. With nothing typed: recent searches, then every page.
    static func build(query raw: String, records: [RecordSearchGroup], catalog: AppCatalog, menu: AppMenu,
                      recents: [String], canAsk: Bool) -> [CommandPaletteItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = catalog.nativeEntries
        guard !query.isEmpty else {
            return recents.map {
                CommandPaletteItem(id: "recent:\($0)", section: "Recent searches", title: $0, subtitle: nil,
                                   systemImage: "clock.arrow.circlepath", action: .recent($0))
            } + entries.map(page)
        }
        var items: [CommandPaletteItem] = []
        if query.count >= RecordSearchModel.minimumLength {
            for group in records {
                for hit in group.items {
                    // Only what opens natively: a row that leads nowhere is a dead end.
                    guard let target = RecordSearchTarget.resolve(hit.path, menu: menu) else { continue }
                    items.append(CommandPaletteItem(id: "record:\(group.key):\(hit.id)", section: group.label, title: hit.title,
                                                    subtitle: hit.subtitle.map(Self.plainMoney), systemImage: symbol(group.key),
                                                    color: .accentColor, action: .record(target)))
                }
            }
        }
        let q = query.lowercased()
        // Best match first; equal matches keep the menu's order.
        items += entries.enumerated()
            .map { (entry: $0.element, score: score(q, name: $0.element.name, key: $0.element.key), order: $0.offset) }
            .filter { $0.score > 0 }
            .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
            .map { page($0.entry) }
        if canAsk {
            items.append(CommandPaletteItem(id: "ask", section: "Ask AI", title: "Ask AI about “\(query)”",
                                            subtitle: "The assistant can look things up and do the work, with your permissions",
                                            systemImage: "sparkles", color: .accentColor, action: .ask(query)))
        }
        return items
    }

    private static func page(_ entry: AppCatalog.Entry) -> CommandPaletteItem {
        CommandPaletteItem(id: "page:\(entry.key)", section: "Pages", title: entry.name, subtitle: nil,
                           systemImage: entry.systemImage, color: entry.color, action: .page(entry))
    }

    /// How well a page matches (0 = not at all), as the web ranks its menu: the name exactly, then its start,
    /// anywhere in it, the module's key, then the letters in order.
    static func score(_ q: String, name: String, key: String) -> Int {
        let name = name.lowercased()
        if name == q { return 100 }
        if name.hasPrefix(q) { return 80 }
        if name.contains(q) { return 60 }
        if key.lowercased().contains(q) { return 40 }
        var rest = Substring(q)
        for character in name where character == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty ? 10 : 0
    }

    /// The server writes amounts as "GBP 120.00"; the app shows pounds as £.
    static func plainMoney(_ text: String) -> String {
        text.replacingOccurrences(of: "GBP ", with: "£")
    }

    /// A symbol for each kind of record (`lib/global-search.lua`'s provider keys).
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "deals": "tag"
        case "customers": "person.2"
        case "leads": "person.crop.circle.badge.plus"
        case "crm_accounts": "building.2"
        case "crm_contacts": "person.crop.square"
        case "crm_deals": "briefcase"
        case "invoices": "doc.text"
        case "shop_orders", "store_orders": "cart"
        case "shop_quotes": "doc.text.magnifyingglass"
        case "shop_products": "shippingbox"
        case "shop_suppliers": "truck.box"
        case "purchase_orders": "shippingbox.and.arrow.backward"
        case "purchase_invoices": "doc.plaintext"
        case "employees": "person.crop.circle"
        case "projects": "rectangle.split.3x1"
        default: "magnifyingglass"
        }
    }
}

/// The person's last few searches on this device, newest first (per person, so a shared Mac doesn't mix them).
enum RecentSearches {
    static let limit = 6

    static func load(user: String?, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(user)) ?? []
    }

    static func add(_ query: String, user: String?, defaults: UserDefaults = .standard) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= RecordSearchModel.minimumLength else { return }
        let rest = load(user: user, defaults: defaults).filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        defaults.set(Array(([query] + rest).prefix(limit)), forKey: key(user))
    }

    static func clear(user: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(user))
    }

    private static func key(_ user: String?) -> String { "commandPalette.recent.\(user ?? "anyone")" }
}

// MARK: - The palette

/// Search everything (⌘K): records, pages and the assistant in one box. A floating panel on the Mac, a sheet on
/// iPhone. ↑ ↓ move, Return opens, Escape closes. `choose` is told what was picked; the window opens it natively.
struct CommandPaletteView: View {
    let close: () -> Void
    let choose: (CommandPaletteItem.Action) -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.services) private var services
    @State private var query = ""
    @State private var records = RecordSearchModel()
    @State private var recents: [String] = []
    @State private var active = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let catalog = AppCatalog(menu: session.menu)
        let items = CommandPaletteItem.build(query: query, records: records.groups, catalog: catalog, menu: session.menu,
                                             recents: recents, canAsk: catalog.entry(forKey: AppMenu.aiChatKey) != nil)
        VStack(spacing: 0) {
            field(items)
            Divider()
            results(items)
            if MacSupport.isMac {
                Divider()
                keyHints
            }
        }
        .background(Palette.card)
        .task(id: query) { await records.search(query, api: services.workspace()) }
        .onChange(of: query) { active = 0 }
        .onAppear {
            recents = RecentSearches.load(user: session.user?.uuid)
            // After the panel is on screen, or the focus is lost on the Mac.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .accessibilityIdentifier("palette")
    }

    private func field(_ items: [CommandPaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            TextField("Search customers, leads, invoices, orders, pages…", text: $query)
                .textFieldStyle(.plain)
                .font(.wsTitle3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .focused($fieldFocused)
                .onSubmit { pick(items, at: active) }
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .accessibilityIdentifier("palette.field")
            if records.isSearching {
                ProgressView().controlSize(.small).accessibilityLabel("Searching your records")
            }
            if MacSupport.isMac {
                Text("esc")
                    .font(.wsCaption.weight(.medium))
                    .foregroundStyle(.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.hairline))
                    .accessibilityHidden(true)
            } else {
                Button("Cancel", action: close).accessibilityIdentifier("palette.cancel")
            }
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private func results(_ items: [CommandPaletteItem]) -> some View {
        if items.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let error = records.error {
                            Label("Your records couldn't be searched just now (\(error.plainMessage)). Pages still are.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.wsFootnote)
                                .foregroundStyle(Tone.warning.textColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].section != item.section {
                                sectionHeader(item.section, first: index == 0)
                            }
                            CommandPaletteRow(item: item, isActive: index == active) { pick(items, at: index) }
                                .id(item.id)
                                .onHover { if $0 { active = index } }
                        }
                    }
                    .padding(8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: active) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, first: Bool) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.wsCaption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondaryText)
            Spacer()
            if title == "Recent searches" {
                Button("Clear") {
                    RecentSearches.clear(user: session.user?.uuid)
                    recents = []
                }
                .font(.wsCaption)
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear recent searches")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, first ? 6 : 14)
        .padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.wsTitle2).foregroundStyle(.secondaryText)
            Text(query.trimmingCharacters(in: .whitespaces).count < RecordSearchModel.minimumLength
                 ? "Type two letters or more to search your records."
                 : "Nothing matches “\(query)”.")
                .font(.wsSubheadline)
                .foregroundStyle(.secondaryText)
                .multilineTextAlignment(.center)
            if !query.isEmpty {
                Button("Clear the search") { query = "" }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(24)
    }

    private var keyHints: some View {
        HStack(spacing: 16) {
            hint("↑ ↓", "to move")
            hint("return", "to open")
            hint("esc", "to close")
            Spacer()
            hint("⌘J", "asks AI on Home")
        }
        .font(.wsCaption)
        .foregroundStyle(.secondaryText)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Palette.canvas.opacity(0.6))
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(text)
        }
    }

    private func move(_ step: Int, in items: [CommandPaletteItem]) {
        guard !items.isEmpty else { return }
        active = min(max(active + step, 0), items.count - 1)
    }

    private func pick(_ items: [CommandPaletteItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if case .recent(let text) = item.action {
            query = text
            return
        }
        RecentSearches.add(query, user: session.user?.uuid)
        choose(item.action)
    }
}

/// A line of the palette: an icon tile, the title and what it is; the highlighted one shows Return to open it.
private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentColor : item.color)
                    .frame(width: 30, height: 30)
                    .background((isActive ? Color.accentColor : Color.secondary).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.wsCallout.weight(.medium))
                        .foregroundStyle(Color(.label))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle).font(.wsCaption).foregroundStyle(.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isActive, MacSupport.isMac {
                    Image(systemName: "return")
                        .font(.wsCaption.weight(.semibold))
                        .foregroundStyle(.secondaryText)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(isActive ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("palette.item.\(item.id)")
    }
}

extension View {
    /// The ⌘K search over this window: a centred floating panel on the Mac (click outside or Escape to close), a
    /// sheet on iPhone and iPad.
    func commandPalette(isPresented: Binding<Bool>, choose: @escaping (CommandPaletteItem.Action) -> Void) -> some View {
        modifier(CommandPalettePresenter(isPresented: isPresented, choose: choose))
    }
}

private struct CommandPalettePresenter: ViewModifier {
    @Binding var isPresented: Bool
    let choose: (CommandPaletteItem.Action) -> Void

    func body(content: Content) -> some View {
        if MacSupport.isMac {
            content.overlay {
                if isPresented {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.22)
                            .ignoresSafeArea()
                            .onTapGesture { isPresented = false }
                            .accessibilityLabel("Close the search")
                            .accessibilityAddTraits(.isButton)
                        panel
                            .frame(width: 640, height: 480)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline))
                            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                            .padding(.top, 80)
                            .padding(.horizontal, 24)
                    }
                    .transition(.opacity)
                }
            }
        } else {
            content.sheet(isPresented: $isPresented) {
                panel.presentationDragIndicator(.visible)
            }
        }
    }

    private var panel: some View {
        CommandPaletteView(close: { isPresented = false }) { action in
            isPresented = false
            choose(action)
        }
    }
}
