import AudioToolbox
import Foundation
import Observation
import UIKit

// MARK: - Events

/// `message:new` — someone posted to a channel or direct message the person belongs to.
struct ChatSocketMessage: Decodable, Sendable {
    let channelUuid: String
    let namespaceId: Int?
    let channelName: String?
    let channelType: String?
    let message: ChatMessage

    enum CodingKeys: String, CodingKey { case channelUuid, namespaceId, channelName, channelType, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelUuid = try c.decode(String.self, forKey: .channelUuid)
        namespaceId = c.decodeFlexibleInt(forKey: .namespaceId)
        channelName = c.decodeFlexibleString(forKey: .channelName)
        channelType = c.decodeFlexibleString(forKey: .channelType)
        message = try c.decode(ChatMessage.self, forKey: .message)
    }
}

/// `reaction:update` — a message's whole new reaction set.
struct ChatSocketReaction: Decodable, Sendable {
    let channelUuid: String
    let namespaceId: Int?
    let messageUuid: String
    let reactions: [ChatReaction]

    enum CodingKeys: String, CodingKey { case channelUuid, namespaceId, messageUuid, reactions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelUuid = try c.decode(String.self, forKey: .channelUuid)
        namespaceId = c.decodeFlexibleInt(forKey: .namespaceId)
        messageUuid = try c.decode(String.self, forKey: .messageUuid)
        reactions = c.decodeLossyArray(ChatReaction.self, forKey: .reactions)
    }
}

/// `agent:done` — a background assistant run finished (`routes/chat-agent.lua`).
struct ChatSocketAgentDone: Decodable, Sendable {
    let runUuid: String?
    let namespaceId: Int?
    /// done | error
    let status: String
    let reply: String?
    /// The page scope (`general` = the chat page's assistant) and the page it was asked on.
    let scope: String?
    let path: String?

    enum CodingKeys: String, CodingKey { case runUuid, namespaceId, status, reply, scope, path }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runUuid = c.decodeFlexibleString(forKey: .runUuid)
        namespaceId = c.decodeFlexibleInt(forKey: .namespaceId)
        status = c.decodeFlexibleString(forKey: .status) ?? "done"
        reply = c.decodeFlexibleString(forKey: .reply)
        scope = c.decodeFlexibleString(forKey: .scope)
        path = c.decodeFlexibleString(forKey: .path)?.trimmedOrNil
    }
}

/// What the chat hub (`lib/chat-ws.lua`, `/api/chat/ws`) pushes: `{ "type": …, "data": … }`.
enum ChatSocketEvent: Sendable {
    case connected
    case pong
    case message(ChatSocketMessage)
    case reaction(ChatSocketReaction)
    case agentDone(ChatSocketAgentDone)
    /// Not from the server: the app came back or the socket (re)connected — catch up now.
    case resync

    var namespaceId: Int? {
        switch self {
        case .message(let m): m.namespaceId
        case .reaction(let r): r.namespaceId
        case .agentDone(let a): a.namespaceId
        default: nil
        }
    }

    /// Whether an event belongs to the workspace on screen (events for the person's other
    /// workspaces arrive on the same per-user socket and are left alone, as on the web).
    func belongs(to workspaceId: Int?) -> Bool {
        guard let event = namespaceId, let workspaceId else { return true }
        return event == workspaceId
    }

    static func parse(_ text: String) -> ChatSocketEvent? {
        let data = Data(text.utf8)
        let decoder = JSONDecoder.opsAPI()
        guard let frame = try? decoder.decode(Frame.self, from: data) else { return nil }
        switch frame.type {
        case "connected": return .connected
        case "pong": return .pong
        case "message:new": return (try? decoder.decode(Payload<ChatSocketMessage>.self, from: data)).map { .message($0.data) }
        case "reaction:update": return (try? decoder.decode(Payload<ChatSocketReaction>.self, from: data)).map { .reaction($0.data) }
        case "agent:done": return (try? decoder.decode(Payload<ChatSocketAgentDone>.self, from: data)).map { .agentDone($0.data) }
        default: return nil
        }
    }

    private struct Frame: Decodable { let type: String }
    private struct Payload<T: Decodable>: Decodable { let data: T }
}

// MARK: - Alerts

/// A heads-up inside the chat screens about a conversation that isn't open (the web's toast).
struct ChatAlert: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case channel(uuid: String, name: String?, type: String?)
        case assistant(path: String?)
    }

    let id = UUID()
    let title: String
    let body: String
    let target: Target

    static func == (a: ChatAlert, b: ChatAlert) -> Bool { a.id == b.id }
}

/// The person's chat alert choices on this phone (the web keeps the same two per browser).
enum ChatAlertPrefs {
    static let bannersKey = "chat.alerts.banners"
    static let soundKey = "chat.alerts.sound"

    static var banners: Bool {
        get { UserDefaults.standard.object(forKey: bannersKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: bannersKey) }
    }

    static var sound: Bool {
        get { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }
}

// MARK: - Hub

/// The one chat WebSocket for the app, shared by every chat screen.
///
/// Same protocol as the web (`hooks/useWebSocket` + `useChatSocket`): connect to
/// `wss://<api>/api/chat/ws?token=<jwt>`, the server greets with `connected`, pushes
/// `message:new` / `reaction:update` / `agent:done`, and answers `{"type":"ping"}` with `pong`.
/// One socket per person serves every conversation and workspace.
///
/// It is held only while a chat screen is on screen (plus a short grace period, so moving between
/// chat screens never drops it), closed in the background, and reconnects with exponential backoff.
/// Screens keep polling as a fallback, quickly while the socket is down and slowly while it's live.
@MainActor
@Observable
final class ChatHub {
    static let shared = ChatHub()

    enum Status: Equatable {
        /// Not connected and not trying (no chat screen open, or the app is in the background).
        case off
        case connecting
        case live
        /// Lost or refused; trying again. Screens poll quickly meanwhile.
        case retrying
    }

    private(set) var status: Status = .off
    /// The latest heads-up for the chat screens to show.
    private(set) var alert: ChatAlert?

    /// What's on screen: a channel uuid, or `assistant:<path>` — kept quiet for alerts.
    @ObservationIgnored var viewing: String?
    /// The workspace on screen (numeric namespace id), for alerts.
    @ObservationIgnored var workspaceId: Int?

    @ObservationIgnored private var client: APIClient?
    @ObservationIgnored private var userUuid: String?
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var presence: Task<Void, Never>?
    @ObservationIgnored private var stopper: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var lastFrameAt = Date()
    @ObservationIgnored private var handlers: [UUID: @MainActor (ChatSocketEvent) -> Void] = [:]
    @ObservationIgnored private var inBackground = false
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// How long the socket outlives the last chat screen, so pushing and popping keeps it.
    static let graceSeconds: Double = 30
    static let pingSeconds: Double = 25
    /// No frame at all (not even a pong) for this long means the link is dead.
    static let staleSeconds: Double = 70

    init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        })
    }

    // MARK: Holding

    /// A chat screen appeared. Connects (or keeps the connection) for this person.
    func hold(client: APIClient, userUuid: String?, workspaceId: Int?) {
        stopper?.cancel()
        stopper = nil
        holders += 1
        self.workspaceId = workspaceId
        if self.client !== client || self.userUuid != userUuid {
            // Another person or server: never reuse their socket.
            stopNow()
            self.client = client
            self.userUuid = userUuid
        }
        if !inBackground { start() }
    }

    /// A chat screen went away. The socket closes once none is left (after a grace period).
    func release() {
        holders = max(0, holders - 1)
        guard holders == 0, stopper == nil else { return }
        stopper = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.graceSeconds))
            guard !Task.isCancelled, let self, self.holders == 0 else { return }
            self.stopper = nil
            self.stopNow()
        }
    }

    // MARK: Subscribing

    @discardableResult
    func subscribe(_ handler: @escaping @MainActor (ChatSocketEvent) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID?) {
        guard let id else { return }
        handlers[id] = nil
    }

    func dismissAlert() { alert = nil }

    /// How long screens wait between catch-up polls: quickly only while the socket is down.
    func pollInterval(live: Double, fallback: Double) -> Double {
        status == .live ? live : fallback
    }

    // MARK: Connection

    private func start() {
        guard runner == nil, let client else { return }
        runner = Task { [weak self] in await self?.run(client: client) }
        presence = Task { [weak self] in
            let api = ChatAPI(client: client)
            while !Task.isCancelled, self != nil {
                try? await api.setPresence(.online)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func stopNow() {
        let wasRunning = runner != nil
        runner?.cancel()
        runner = nil
        presence?.cancel()
        presence = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .off
        if wasRunning, let client {
            Task { try? await ChatAPI(client: client).setPresence(.offline) }
        }
    }

    private func enterBackground() {
        inBackground = true
        stopNow()
    }

    private func enterForeground() {
        inBackground = false
        guard holders > 0 else { return }
        start()
        emit(.resync)
    }

    private func run(client: APIClient) async {
        var failures = 0
        while !Task.isCancelled {
            status = failures == 0 ? .connecting : .retrying
            var greeted = false
            if let url = await Self.socketURL(client: client) {
                let socket = urlSession.webSocketTask(with: url)
                self.socket = socket
                socket.resume()
                greeted = await listen(socket)
                socket.cancel(with: .goingAway, reason: nil)
                if self.socket === socket { self.socket = nil }
            }
            if Task.isCancelled { break }
            failures = greeted ? 1 : failures + 1
            status = .retrying
            try? await Task.sleep(for: .seconds(Self.backoff(attempt: failures)))
        }
    }

    /// Reads frames until the socket closes or fails. True when the server greeted it.
    private func listen(_ socket: URLSessionWebSocketTask) async -> Bool {
        var greeted = false
        lastFrameAt = Date()
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pingSeconds))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.lastFrameAt) > Self.staleSeconds {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
                do {
                    try await socket.send(.string(#"{"type":"ping"}"#))
                } catch {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { heartbeat.cancel() }
        while !Task.isCancelled {
            guard let frame = try? await socket.receive() else { break }
            lastFrameAt = Date()
            let text: String? = switch frame {
            case .string(let string): string
            case .data(let data): String(data: data, encoding: .utf8)
            @unknown default: nil
            }
            guard let text, let event = ChatSocketEvent.parse(text) else { continue }
            switch event {
            case .connected:
                greeted = true
                status = .live
                // Whatever arrived while the socket was down is fetched now.
                emit(.resync)
            case .pong:
                break
            default:
                noteForAlert(event)
                emit(event)
            }
        }
        return greeted
    }

    private func emit(_ event: ChatSocketEvent) {
        for handler in handlers.values { handler(event) }
    }

    // MARK: Alerts

    private func noteForAlert(_ event: ChatSocketEvent) {
        guard ChatAlertPrefs.banners || ChatAlertPrefs.sound, event.belongs(to: workspaceId) else { return }
        switch event {
        case .message(let m):
            guard m.message.userUuid != userUuid, m.message.parentMessageUuid == nil,
                  viewing != m.channelUuid else { return }
            let from = m.message.senderName
            let title = m.channelType == "direct" || m.channelName == nil ? from : "\(from) in #\(m.channelName ?? "")"
            raise(ChatAlert(title: title, body: m.message.preview,
                            target: .channel(uuid: m.channelUuid, name: m.channelName, type: m.channelType)))
        case .agentDone(let done):
            let path = done.scope == "general" ? nil : done.path
            guard viewing != Self.assistantKey(path: path) else { return }
            let title = done.status == "error" ? "The assistant couldn't finish" : "The assistant has finished"
            let body = ChatMarkdown.plainText(done.reply ?? "")
            raise(ChatAlert(title: title, body: String(body.prefix(140)), target: .assistant(path: path)))
        default:
            break
        }
    }

    private func raise(_ new: ChatAlert) {
        if ChatAlertPrefs.sound { AudioServicesPlaySystemSound(1003) }
        guard ChatAlertPrefs.banners else { return }
        alert = new
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.alert == new { self?.alert = nil }
        }
    }

    static func assistantKey(path: String?) -> String { "assistant:\(path ?? "")" }

    // MARK: Helpers

    /// `https://api…` → `wss://api…/api/chat/ws?token=…` (keeping any base path).
    static func socketURL(base: URL, token: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + "/api/chat/ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        components.fragment = nil
        return components.url
    }

    private static func socketURL(client: APIClient) async -> URL? {
        guard let token = try? await client.socketAccessToken() else { return nil }
        return socketURL(base: await client.currentBaseURL, token: token)
    }

    /// 1, 2, 4, 8, 16, 30, 30… seconds, with a little jitter so phones don't reconnect in step.
    static func backoff(attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> Double {
        let base = min(30, pow(2, Double(max(0, attempt - 1))))
        return base * jitter
    }
}
