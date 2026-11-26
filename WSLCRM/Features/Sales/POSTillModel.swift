import SwiftUI

/// The till's state: the store, its products, the sale being rung up, today's takings, the last receipt.
@MainActor
@Observable
final class POSTillModel {
    var stores: LoadState<[Store]> = .idle
    var storeUuid: String = "" {
        didSet {
            guard storeUuid != oldValue else { return }
            UserDefaults.standard.set(storeUuid, forKey: Self.storeKey)
        }
    }
    var catalogue: LoadState<POSCatalogue> = .idle
    var summary: POSSummary?
    var cart = POSCart()
    var search = ""
    var category = ""
    var inStockOnly = false
    /// A short message under the search box (scan results, stock limits).
    var notice: String?
    var error: APIError?
    var saving = false
    var receipt: POSReceipt?
    /// Kept until a sale succeeds, so a retried "Complete sale" never makes two sales.
    private(set) var saleKey = UUID().uuidString

    static let storeKey = "pos.store"
    private let api: SalesAPI

    init(api: SalesAPI) {
        self.api = api
        storeUuid = UserDefaults.standard.string(forKey: Self.storeKey) ?? ""
    }

    var currency: String { catalogue.value?.store.currency ?? Formatters.defaultCurrency }
    var products: [POSProduct] { catalogue.value?.products ?? [] }

    var storeName: String? {
        catalogue.value?.store.name ?? stores.value?.first { $0.uuid == storeUuid }?.name
    }

    /// The tiles shown: category, in stock only, then the search over name, SKU, barcode and variations.
    var shown: [POSProduct] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        return products.filter { p in
            if !category.isEmpty && p.category != category { return false }
            if inStockOnly && !p.available { return false }
            guard !term.isEmpty else { return true }
            return p.name.lowercased().contains(term) || (p.sku?.lowercased().contains(term) ?? false)
                || (p.barcode?.lowercased().contains(term) ?? false)
                || p.variants.contains { ($0.sku?.lowercased().contains(term) ?? false) || $0.title.lowercased().contains(term) }
        }
    }

    // MARK: Loading

    func loadStores() async {
        if stores.value == nil { stores = .loading }
        do {
            let list = try await api.stores()
            stores = .loaded(list)
            if !list.contains(where: { $0.uuid == storeUuid }) {
                storeUuid = list.count == 1 ? list[0].uuid : ""
            }
            if !storeUuid.isEmpty { await loadStore() }
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            stores = .failed(apiError)
        }
    }

    func choose(store uuid: String) async {
        guard uuid != storeUuid else { return }
        storeUuid = uuid
        cart.lines = []
        category = ""
        catalogue = .idle
        summary = nil
        await loadStore()
    }

    func loadStore() async {
        guard !storeUuid.isEmpty else { return }
        async let summaryTask: Void = loadSummary()
        await loadCatalogue()
        await summaryTask
    }

    func loadCatalogue() async {
        guard !storeUuid.isEmpty else { return }
        if catalogue.value == nil { catalogue = .loading }
        do {
            let loaded = try await api.catalogue(storeUuid: storeUuid)
            catalogue = .loaded(loaded)
            cart.taxRate = loaded.store.taxRate
        } catch {
            let apiError = error.asAPIError
            if case .cancelled = apiError { return }
            if catalogue.value == nil { catalogue = .failed(apiError) } else { self.error = apiError }
        }
    }

    /// Today's takings need `orders.read`; without it the till still sells.
    func loadSummary() async {
        guard !storeUuid.isEmpty else { return }
        summary = try? await api.summary(storeUuid: storeUuid)
    }

    // MARK: Selling

    /// A tap on a tile: one more, or (with variations) the caller asks which one.
    /// Returns the product to choose a variation for.
    func tap(_ product: POSProduct) -> POSProduct? {
        guard product.available else { return nil }
        if !product.variants.isEmpty { return product }
        if cart.add(product, nil) { notice = nil }
        return nil
    }

    /// A scanned code or the search box's return key. Returns a product whose variation must be chosen.
    func enter(_ code: String) -> POSProduct? {
        guard code.trimmedOrNil != nil else { return nil }
        let result = cart.scan(code, in: products)
        switch result {
        case .added:
            search = ""
            notice = nil
            return nil
        case .choose(let product):
            search = ""
            return product
        case .notFound:
            let matches = shown
            if matches.count == 1 {
                search = ""
                return tap(matches[0])
            }
            notice = POSCart.message(result)
            return nil
        default:
            notice = POSCart.message(result)
            return nil
        }
    }

    func complete() async {
        guard cart.problem == nil, !storeUuid.isEmpty, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let sold = try await api.sell(cart.body(storeUuid: storeUuid), idempotencyKey: saleKey)
            receipt = sold
            error = nil
            cart.reset()
            saleKey = UUID().uuidString
            await loadSummary()
            await loadCatalogue()
        } catch {
            self.error = error.asAPIError
            // Stock may have changed at another till.
            await loadCatalogue()
        }
    }

    func reopenReceipt(_ uuid: String) async {
        do {
            receipt = try await api.receipt(uuid)
        } catch {
            self.error = error.asAPIError
        }
    }
}
