import SwiftUI

/// The tabs of the app: Home (the dashboard), up to three work hubs, and Apps (everything else).
enum AppTab: Hashable {
    case home
    case hub(NavigationPolicy.Home)
    case apps
}

/// How a work hub presents itself: on its tab, and on Home's "Your work" cards.
extension NavigationPolicy.Home {
    var title: String {
        switch self {
        case .propertyPA: "PA"
        case .myWork: "My Work"
        case .fieldService: "Field Service"
        case .propertyDeals: "Deals"
        case .leads: "Leads"
        case .tasks: "Tasks"
        case .shop: "Shop"
        case .ai: "AI"
        case .projects: "Projects"
        case .more: "Apps"
        }
    }

    /// The longer name on Home's cards.
    var longTitle: String {
        switch self {
        case .propertyPA: "Your PA"
        case .propertyDeals: "Property deals"
        case .tasks: "My tasks"
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .propertyPA: "sparkles"
        case .myWork: "person.badge.clock"
        case .fieldService: "wrench.and.screwdriver"
        case .propertyDeals: "house.and.flag"
        case .leads: "person.crop.circle.badge.plus"
        case .tasks: "checklist"
        case .shop: "storefront"
        case .ai: "bubble.left.and.text.bubble.right"
        case .projects: "rectangle.split.3x1"
        case .more: "square.grid.2x2"
        }
    }

    /// One line on what the hub is for, in the person's terms.
    var tagline: String {
        switch self {
        case .propertyPA: "Who to call today, and why — planned for you."
        case .myWork: "Today's visits, check-ins and job sheets."
        case .fieldService: "Requests, jobs and engineers on site."
        case .propertyDeals: "Today's deal tasks, approvals and captures."
        case .leads: "New enquiries and follow-ups."
        case .tasks: "Cards assigned to you across every project."
        case .shop: "Orders, quotes, stock and suppliers."
        case .ai: "Ask anything about your workspace."
        case .projects: "Boards, sprints and cards."
        case .more: "Everything in your workspace."
        }
    }

    var color: Color {
        switch self {
        case .propertyPA: Palette.tileColors[1]
        case .myWork: Palette.tileColors[2]
        case .fieldService: Palette.tileColors[3]
        case .propertyDeals: Palette.tileColors[0]
        case .leads: Palette.tileColors[5]
        case .tasks: Palette.tileColors[4]
        case .shop: Palette.tileColors[6]
        case .ai, .projects, .more: Palette.tileColors[7]
        }
    }

    /// The hub's first screen.
    @MainActor @ViewBuilder
    var rootView: some View {
        switch self {
        case .propertyPA: PATodayView()
        case .myWork: MyWorkView()
        case .fieldService: FieldServiceHubView()
        case .propertyDeals: PDTodayView()
        case .leads: LeadsHomeView()
        case .tasks: MyTasksView()
        case .shop: ShopHomeView()
        case .ai, .projects, .more: EmptyView()
        }
    }
}

/// The AI Navigator over the app: a sheet with its own Done, so it is clearly a place you visit
/// and leave, rather than the app turning into a web page.
struct AssistantSheet: View {
    let route: WebPageRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPageView(route: route)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("assistant.done")
                    }
                }
        }
    }
}
