import SwiftUI

/// Selling: the till (Point of Sale), shop analytics, delivery and every sales order in one list.
/// Hand-built screens live in Features/Sales (till, sales orders, delivery) and Features/Shop (analytics,
/// the new-quote builder); the shop's described lists are in `ModuleGroup.shop`.
extension ModuleGroup {
    static let sales = ModuleGroup(
        id: "sales",
        screens: [
            "pos": SalesScreen.pos,
            "shop_analytics": SalesScreen.shopAnalytics,
            "delivery": SalesScreen.delivery,
        ],
        screen: { id in
            switch id {
            case SalesScreen.pos: AnyView(POSTillView())
            case SalesScreen.shopAnalytics: AnyView(ShopAnalyticsView())
            case SalesScreen.delivery: AnyView(DeliveryHomeView())
            case SalesScreen.orders: AnyView(SalesOrdersView())
            case SalesScreen.newQuote: AnyView(ShopQuoteBuilderView())
            default: nil
            }
        })
}

/// The sales group's hand-built screen ids (`NavigationLink(value: NativeScreenRoute(SalesScreen.pos))`).
enum SalesScreen {
    static let pos = "sales.pos"
    static let shopAnalytics = "sales.shop_analytics"
    static let delivery = "sales.delivery"
    static let orders = "sales.orders"
    static let newQuote = "sales.new_quote"
    static let all = [pos, shopAnalytics, delivery, orders, newQuote]
}
