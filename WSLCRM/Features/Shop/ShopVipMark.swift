import SwiftUI

/// VIP status for the customer emails on screen, shared across the shop's lists for a minute (as the
/// dashboard's useVipStatus): rows ask for their email, and the asks made together go to the server as
/// one `POST /membership/lookup`. Needs `shop.read`; quietly nothing on any error.
@MainActor @Observable
final class ShopVipCache {
    static let shared = ShopVipCache()

    private(set) var statuses: [String: ShopVipStatus] = [:]
    private var checkedAt: [String: Date] = [:]
    private var queued: Set<String> = []
    private var flushing = false

    static func key(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), email.contains("@") else {
            return nil
        }
        return email
    }

    func status(_ email: String?) -> ShopVipStatus? {
        Self.key(email).flatMap { statuses[$0] }
    }

    func want(_ email: String?, api: ShopAPI) async {
        guard let key = Self.key(email) else { return }
        if let at = checkedAt[key], Date().timeIntervalSince(at) < 60 { return }
        queued.insert(key)
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        // Let the other rows on screen join this lookup.
        try? await Task.sleep(for: .milliseconds(150))
        while !queued.isEmpty {
            let batch = Array(queued.prefix(200))
            queued.subtract(batch)
            let found = await api.vipStatus(emails: batch)
            let now = Date()
            for email in batch {
                checkedAt[email] = now
                statuses[email] = found[email]
            }
        }
    }
}

/// The gold VIP pill beside a customer in a list, when that email belongs to a Trade member.
struct ShopVipMark: View {
    let email: String?
    @Environment(\.services) private var services
    @Environment(SessionStore.self) private var session

    var body: some View {
        ZStack {
            Color.clear.frame(width: 0, height: 0)
            if let vip = ShopVipCache.shared.status(email) { ShopVipBadge(vip: vip) }
        }
        .task(id: email) {
            guard session.permissions.can(.read, .shop) else { return }
            await ShopVipCache.shared.want(email, api: services.shop)
        }
    }
}
