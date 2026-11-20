import Foundation

/// `/auth/*` and the user/namespace endpoints.
struct AuthAPI: Sendable {
    let client: APIClient
    /// Names the sign-in code email ("Your <name> Verification Code"): the build's brand, so a
    /// white-label build (Config/Brand-*.xcconfig) doesn't send its users Workstation's name.
    static var appName: String { Brand.current.name }

    /// Step 1. Form-encoded — the server does not parse JSON on this route.
    func login(identifier: String, password: String) async throws -> LoginResponse {
        let endpoint = Endpoint(.post, "/auth/login", requiresAuth: false, requiresNamespace: false)
            .withForm([("identifier", identifier), ("password", password), ("app_name", Self.appName)])
        return try await client.send(endpoint)
    }

    /// Step 2. `code` must be a JSON string (leading zeros matter; a number causes a 500).
    func verifyTwoFactor(sessionToken: String, code: String) async throws -> VerifyTwoFactorResponse {
        let body = VerifyBody(sessionToken: sessionToken, code: code)
        return try await client.send(Endpoint.post("/auth/2fa/verify", json: body).publicAPI)
    }

    func resendTwoFactorCode(sessionToken: String) async throws {
        let body = ResendBody(sessionToken: sessionToken, appName: Self.appName)
        try await client.sendDiscardingBody(Endpoint.post("/auth/2fa/resend", json: body).publicAPI)
    }

    func forgotPassword(email: String) async throws {
        try await client.sendDiscardingBody(Endpoint.post("/auth/forgot-password", json: ["email": email]).publicAPI)
    }

    /// Revokes the refresh token server-side. Always succeeds from the server's point of view.
    func logout(refreshToken: String?) async {
        guard let refreshToken else { return }
        _ = try? await client.sendRaw(Endpoint.post("/auth/logout", json: ["refresh_token": refreshToken]).publicAPI)
    }

    /// `GET /auth/me` — returns the raw bytes too so the session can be restored offline.
    func me() async throws -> (MeResponse, Data) {
        var endpoint = Endpoint.get("/auth/me")
        endpoint.requiresNamespace = false
        let (data, _) = try await client.sendRaw(endpoint)
        return (try decode(MeResponse.self, data, endpoint), data)
    }

    /// `GET /api/v2/user/menu` for the currently selected namespace.
    func menu() async throws -> (MenuResponse, Data) {
        let endpoint = Endpoint.get("/api/v2/user/menu")
        let (data, _) = try await client.sendRaw(endpoint)
        return (try decode(MenuResponse.self, data, endpoint), data)
    }

    /// Records the workspace as last-active and returns a JWT scoped to it.
    func switchNamespace(uuid: String) async throws -> SwitchNamespaceResponse {
        var endpoint = Endpoint(.post, "/api/v2/user/namespaces/\(uuid)/switch")
        endpoint.requiresNamespace = false
        return try await client.send(endpoint)
    }

    /// `GET /api/v2/user/namespaces`: each workspace's logo and letterhead (`settings.company`).
    func workspaceBrands() async throws -> [WorkspaceBrandDetails] {
        var endpoint = Endpoint.get("/api/v2/user/namespaces")
        endpoint.requiresNamespace = false
        let (data, _) = try await client.sendRaw(endpoint)
        return try decode(WorkspaceBrandList.self, data, endpoint).data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ endpoint: Endpoint) throws -> T {
        do {
            return try JSONDecoder.opsAPI().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(endpoint: endpoint.summary, description: String(describing: error),
                                    body: NetworkLogger.redactedBody(data))
        }
    }

    private struct VerifyBody: Encodable, Sendable {
        let sessionToken: String
        let code: String
    }

    private struct ResendBody: Encodable, Sendable {
        let sessionToken: String
        let appName: String
    }
}


/// The branding part of a namespace from `GET /api/v2/user/namespaces`.
struct WorkspaceBrandDetails: Decodable, Sendable {
    let uuid: String
    let name: String?
    let logoUrl: String?
    let company: WorkspaceBrand.Company?

    private enum CodingKeys: String, CodingKey { case uuid, name, logoUrl, settings }
    private enum SettingsKeys: String, CodingKey { case company }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        logoUrl = try? c.decodeIfPresent(String.self, forKey: .logoUrl)
        // `settings` is free-form JSON (sometimes still a string); only `company` matters here.
        company = (try? c.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings))
            .flatMap { try? $0.decodeIfPresent(WorkspaceBrand.Company.self, forKey: .company) }
    }
}

private struct WorkspaceBrandList: Decodable {
    let data: [WorkspaceBrandDetails]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = c.decodeLossyArray(WorkspaceBrandDetails.self, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey { case data }
}
