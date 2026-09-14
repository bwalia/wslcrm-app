import Foundation
import os

/// The JWT access token and its refresh token.
struct AuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
}

/// Persistence for `AuthTokens`. Production uses the Keychain; tests use memory.
protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens?)
}

struct KeychainTokenStore: TokenStore {
    private let keychain: KeychainStore
    private let account = "auth.tokens"
    private static let log = Logger(subsystem: "uk.co.workstation.wslcrm", category: "auth")

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    func load() -> AuthTokens? {
        do {
            guard let data = try keychain.data(for: account) else { return nil }
            return try JSONDecoder().decode(AuthTokens.self, from: data)
        } catch {
            Self.log.error("Failed to read tokens from Keychain: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func save(_ tokens: AuthTokens?) {
        do {
            if let tokens {
                try keychain.set(try JSONEncoder().encode(tokens), for: account)
            } else {
                try keychain.remove(account)
            }
        } catch {
            Self.log.error("Failed to write tokens to Keychain: \(String(describing: error), privacy: .public)")
        }
    }
}

final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    init(_ tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() -> AuthTokens? {
        lock.withLock { tokens }
    }

    func save(_ tokens: AuthTokens?) {
        lock.withLock { self.tokens = tokens }
    }
}
