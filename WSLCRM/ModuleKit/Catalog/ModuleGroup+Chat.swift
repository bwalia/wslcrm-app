import SwiftUI

/// Screen ids of the chat area (`NativeScreenRoute`).
enum ChatScreens {
    /// "AI Navigator" (`/dashboard/chat`): the assistant, channels and direct messages.
    static let home = "chat.home"
    /// The AI assistant on its own. Add `?path=/dashboard/…` for a page's assistant
    /// (`ChatAssistantRoute.screenID(path:)`), so any area can offer "Ask AI" natively.
    static let assistant = "chat.assistant"
}

/// Chat and the AI assistant. Everything here is hand-built (a messenger can't be described as a
/// list of records): `Features/Chat/`.
extension ModuleGroup {
    static let chat = ModuleGroup(
        id: "chat",
        screens: [AppMenu.aiChatKey: ChatScreens.home],
        screen: { id in
            if id == ChatScreens.home { return AnyView(ChatHomeView()) }
            if let route = ChatAssistantRoute(screenID: id) { return AnyView(ChatAssistantView(route: route)) }
            return nil
        })
}
