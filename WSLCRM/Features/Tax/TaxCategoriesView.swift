import SwiftUI

/// Tax categories (`/dashboard/tax/categories`): the shared ones (read only) and this workspace's own.
/// The list is filtered on the phone, like the web; a category opens the module kit's detail and form
/// (`ModuleCatalog.taxCategories`), which save through `POST/PUT/DELETE /api/v2/tax/categories`.
struct TaxCategoriesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var categories = TaxCategoryStore()
    @State private var loaded = false
    @State private var search = ""
    @State private var type = ""
    @State private var creating = false
    @State private var hasAppeared = false

    var body: some View {
        List {
            if let error = categories.error {
                Section { InlineErrorRow(error: error) { Task { await load() } } }
            }
            Section {
                Picker("Type", selection: $type) {
                    Text("All").tag("")
                    Text("Income").tag("income")
                    Text("Expense").tag("expense")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("tax.categories.type")
            }
            if loaded, rows.isEmpty, categories.error == nil {
                Section {
                    TaxEmptyRow(title: search.isEmpty ? "No categories found" : "No results",
                                message: search.isEmpty ? "Add your own category with +." : "Nothing matches “\(search)”.",
                                systemImage: "tag")
                }
            }
            Section {
                ForEach(rows) { category in
                    NavigationLink(value: ResourceRoute(descriptorID: ModuleCatalog.taxCategories.id,
                                                        recordID: category.id, seed: category)) {
                        CategoryRow(category: category)
                    }
                    .accessibilityIdentifier("tax.category.\(category.string("key") ?? category.id)")
                }
            } footer: {
                if !rows.isEmpty {
                    Text("Shared categories are the same for everyone and can’t be changed. Your own can be edited or deleted.")
                }
            }
        }
        .overlay { if !loaded { SkeletonList() } }
        .searchable(text: $search, prompt: "Search categories")
        .navigationTitle("Categories")
        .toolbar {
            if session.allows(.create, "tax_categories") {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Label("New category", systemImage: "plus") }
                        .accessibilityIdentifier("tax.categories.new")
                }
            }
        }
        .task { await load() }
        .wsRefreshable { await load() }
        .onAppear {
            if hasAppeared { Task { await load() } }
            hasAppeared = true
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ResourceFormView(descriptor: ModuleCatalog.taxCategories, existing: nil) { _ in Task { await load() } }
            }
        }
    }

    private var rows: [Record] {
        let term = search.lowercased()
        return categories.all.filter { category in
            (type.isEmpty || category.string("category_type")?.lowercased() == type)
                && (term.isEmpty || (category.string("name") ?? "").lowercased().contains(term)
                    || (category.string("description") ?? "").lowercased().contains(term))
        }
    }

    private func load() async {
        await categories.load(makeTaxAPI(services, user: session.user))
        loaded = true
    }
}

private struct CategoryRow: View {
    let category: Record

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(category.string("name") ?? "Category").font(.wsHeadline)
                if category.bool("is_global") == true { Pill(text: "Shared", systemImage: "lock.fill") }
            }
            HStack(spacing: 8) {
                let income = category.string("category_type") == "income"
                StatusBadge(text: income ? "Income" : "Expense", systemImage: income ? "arrow.down.left" : "arrow.up.right",
                            tone: income ? .success : .danger)
                if category.bool("is_deductible") == true { Pill(text: "Allowable", systemImage: "checkmark") }
                if category.bool("non_business") == true { Pill(text: "Not on the return") }
            }
            if let description = category.string("description") {
                Text(description).font(.wsFootnote).foregroundStyle(.secondaryText).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
