import Foundation

/// The signed-in user (`user` in `/auth/2fa/verify` and `/auth/me`).
struct CurrentUser: Codable, Hashable, Sendable {
    let uuid: String
    var email: String
    var username: String?
    var firstName: String
    var lastName: String
    /// Platform (global) roles, e.g. `administrative`. Not namespace roles.
    var platformRoles: [String]

    var displayName: String {
        let full = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? email : full
    }

    var initials: String {
        let letters = [firstName.first, lastName.first].compactMap { $0 }
        return letters.isEmpty ? String(email.prefix(1)).uppercased() : String(letters).uppercased()
    }

    var isPlatformAdmin: Bool { platformRoles.contains("administrative") }

    enum CodingKeys: String, CodingKey { case uuid, email, username, firstName, lastName, roles, platformRoles }

    private struct Role: Decodable { let roleName: String?; let name: String? }

    init(uuid: String, email: String, username: String? = nil, firstName: String, lastName: String, platformRoles: [String] = []) {
        self.uuid = uuid
        self.email = email
        self.username = username
        self.firstName = firstName
        self.lastName = lastName
        self.platformRoles = platformRoles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        firstName = (try? c.decodeIfPresent(String.self, forKey: .firstName)) ?? ""
        lastName = (try? c.decodeIfPresent(String.self, forKey: .lastName)) ?? ""
        if let stored = try? c.decodeIfPresent([String].self, forKey: .platformRoles) {
            platformRoles = stored
        } else {
            platformRoles = c.decodeLossyArray(Role.self, forKey: .roles).compactMap { $0.roleName ?? $0.name }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encode(firstName, forKey: .firstName)
        try c.encode(lastName, forKey: .lastName)
        try c.encode(platformRoles, forKey: .platformRoles)
    }
}

/// A namespace (tenant) the user belongs to. Addressed by `uuid` in `X-Namespace-Id`.
struct Workspace: Codable, Hashable, Identifiable, Sendable {
    let uuid: String
    var id: String { uuid }
    var name: String
    var slug: String?
    var logoUrl: String?
    var isOwner: Bool

    enum CodingKeys: String, CodingKey { case uuid, name, slug, logoUrl, isOwner }

    init(uuid: String, name: String, slug: String? = nil, logoUrl: String? = nil, isOwner: Bool = false) {
        self.uuid = uuid
        self.name = name
        self.slug = slug
        self.logoUrl = logoUrl
        self.isOwner = isOwner
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        slug = try? c.decodeIfPresent(String.self, forKey: .slug)
        logoUrl = try? c.decodeIfPresent(String.self, forKey: .logoUrl)
        isOwner = c.decodeFlexibleBool(forKey: .isOwner) ?? false
    }
}

/// Pending second factor after a successful password check.
struct TwoFactorChallenge: Hashable, Sendable {
    let sessionToken: String
    let email: String?
    let startedAt: Date

    /// The session token expires five minutes after login; resending does not extend it.
    static let lifetime: TimeInterval = 300

    var expiresAt: Date { startedAt.addingTimeInterval(Self.lifetime) }
}

// MARK: - Wire types

/// `POST /auth/login` (form-encoded) → always the 2FA branch.
struct LoginResponse: Decodable, Sendable {
    let requires2fa: Bool?
    let sessionToken: String?
    let email: String?
    let message: String?
    /// Present only if a deployment ever disables mandatory 2FA.
    let token: String?
    let refreshToken: String?
}

/// `POST /auth/2fa/verify` → tokens, user and memberships.
struct VerifyTwoFactorResponse: Decodable, Sendable {
    let user: CurrentUser
    let token: String
    let refreshToken: String?
    let hasPin: Bool?
    let namespaces: [Workspace]
    let currentNamespace: Workspace?

    enum CodingKeys: String, CodingKey { case user, token, refreshToken, hasPin, namespaces, currentNamespace }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(CurrentUser.self, forKey: .user)
        token = try c.decode(String.self, forKey: .token)
        refreshToken = try? c.decodeIfPresent(String.self, forKey: .refreshToken)
        hasPin = c.decodeFlexibleBool(forKey: .hasPin)
        namespaces = c.decodeLossyArray(Workspace.self, forKey: .namespaces)
        currentNamespace = try? c.decodeIfPresent(Workspace.self, forKey: .currentNamespace)
    }
}

/// `GET /auth/me` → `{ user, namespaces, current_namespace }` (no envelope).
struct MeResponse: Decodable, Sendable {
    let user: CurrentUser
    let namespaces: [Workspace]
    let currentNamespace: Workspace?

    enum CodingKeys: String, CodingKey { case user, namespaces, currentNamespace }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(CurrentUser.self, forKey: .user)
        namespaces = c.decodeLossyArray(Workspace.self, forKey: .namespaces)
        currentNamespace = try? c.decodeIfPresent(Workspace.self, forKey: .currentNamespace)
    }
}

/// `POST /api/v2/user/namespaces/:uuid/switch` → a JWT scoped to that namespace.
struct SwitchNamespaceResponse: Decodable, Sendable {
    let token: String?
}

/// `{ module: [actions] }`, tolerant of `[]` (empty tables encode as arrays) and of a
/// JSON-encoded string (role permissions are stored as TEXT).
struct PermissionGrants: Decodable, Sendable, Equatable {
    let grants: [String: Set<String>]

    init(_ grants: [String: Set<String>]) { self.grants = grants }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: LossyArray<String>].self) {
            grants = dict.mapValues { Set($0.elements) }
        } else if let text = try? container.decode(String.self),
                  let data = text.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            grants = dict.mapValues(Set.init)
        } else {
            grants = [:]
        }
    }
}

/// `GET /api/v2/user/menu` — backend-driven navigation and the caller's permissions.
struct MenuResponse: Decodable, Sendable {
    let menu: [MenuItem]
    let namespace: MenuNamespace?
    let permissions: PermissionGrants
    let isAdmin: Bool

    struct MenuItem: Decodable, Sendable, Hashable {
        let key: String
        let name: String?
        let module: String?
        let priority: Int?
    }

    struct MenuNamespace: Decodable, Sendable {
        let uuid: String?
        let isOwner: Bool?
    }

    enum CodingKeys: String, CodingKey { case menu, namespace, permissions, isAdmin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menu = c.decodeLossyArray(MenuItem.self, forKey: .menu)
        namespace = try? c.decodeIfPresent(MenuNamespace.self, forKey: .namespace)
        permissions = (try? c.decodeIfPresent(PermissionGrants.self, forKey: .permissions)) ?? PermissionGrants([:])
        isAdmin = c.decodeFlexibleBool(forKey: .isAdmin) ?? false
    }
}
