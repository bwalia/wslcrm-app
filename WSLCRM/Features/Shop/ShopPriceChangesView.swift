import SwiftUI

/// Price changes (`GET /api/v2/shop/admin/price-changes`): opens on the ones waiting for a decision, and
/// each waiting row swipes to use the new price or keep the current one (`POST …/{uuid}/approve|reject`,
/// shop.update; the server only decides pending ones). Rows open the kit's detail screen.
struct ShopPriceChangesView: View {
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session
    @State private var status = "pending"
    @State private var box = StatusBox()
    @State private var notice: String?
    @State private var error: APIError?

    private let descriptor = ModuleCatalog.shopPriceChanges

    @MainActor
    final class StatusBox { var status = "pending" }

    /// The filter's choices, the waiting ones first ("" = every price change).
    static let choices: [Choice] = [Choice("pending", "Waiting for you"), Choice("blocked_below_cost", "Below cost"),
                                    Choice("approved", "Approved"), Choice("applied", "Applied"),
                                    Choice("rejected", "Kept the old price"), Choice("superseded", "Replaced"),
                                    Choice("", "All")]

    var body: some View {
        ModelHost(make: { [resources = services.resources, box, descriptor] in
            PagedListModel<Record> { search, page in
                try await resources.page(descriptor, search: search, page: page,
                                         query: box.status.isEmpty ? [:] : ["status": box.status])
            }
        }) { model in
            PagedList(model: model, emptyTitle: status == "pending" ? "Nothing waiting" : "No price changes",
                      emptySystemImage: descriptor.systemImage,
                      emptyDescription: status == "pending"
                          ? "When a supplier's prices move, the new selling prices wait here for you to use or keep."
                          : "None match this filter.") { record in
                NavigationLink(value: ResourceRoute(descriptorID: descriptor.id, recordID: record.id, seed: record)) {
                    RecordRow(record: record, list: descriptor.list)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if canDecide(record) {
                        Button("Use new price", systemImage: "checkmark.circle") { Task { await decide(record, approve: true, model) } }
                            .tint(.green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canDecide(record) {
                        Button("Keep price", systemImage: "xmark.circle") { Task { await decide(record, approve: false, model) } }
                            .tint(.orange)
                    }
                }
                .accessibilityIdentifier("priceChange.row.\(record.id)")
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show", selection: $status) {
                        ForEach(Self.choices) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("priceChanges.show")
                    if let error {
                        InlineErrorRow(error: error)
                    } else if let notice {
                        Label(notice, systemImage: "checkmark.circle.fill").font(.wsSubheadline)
                            .foregroundStyle(Tone.success.textColor)
                    } else if status == "pending" && session.shopPolicy.canUpdate {
                        Text("Swipe right to use the new price, left to keep the current one.")
                            .font(.wsFootnote).foregroundStyle(.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 6)
                .background(.bar)
            }
            .onChange(of: status) { _, value in
                box.status = value
                Task { await model.load() }
            }
        }
        .navigationTitle(descriptor.title)
    }

    private func canDecide(_ record: Record) -> Bool {
        session.shopPolicy.canUpdate && record.string("status") == "pending"
    }

    private func decide(_ record: Record, approve: Bool, _ model: PagedListModel<Record>) async {
        guard let action = descriptor.actions.first(where: { $0.id == (approve ? "approve" : "reject") }) else { return }
        do {
            _ = try await services.resources.run(action, on: record, inputs: [:])
            error = nil
            let name = record.string("product_name") ?? "the product"
            notice = approve ? "New price in use for \(name)." : "Kept the current price for \(name)."
            if status == "pending" { model.remove(id: record.id) } else { await model.load() }
        } catch {
            notice = nil
            self.error = error.asAPIError
            await model.load()
        }
    }
}
