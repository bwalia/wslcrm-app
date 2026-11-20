import AuthenticationServices
import Foundation
import UIKit

/// Connecting to HMRC: the ONE step where the app shows a page it didn't draw.
///
/// HMRC requires that a taxpayer signs in on HMRC's own sign-in page (Government Gateway) and gives
/// permission there; no app may collect those credentials. Apple's system sign-in sheet
/// (`ASWebAuthenticationSession`, the sheet used for "Sign in with …" everywhere) shows HMRC's page
/// for that one step and closes itself when HMRC sends the person back. It is not a web view inside
/// the app: no embedded browser view, no in-app Safari sheet, nothing of the web dashboard. Everything
/// before and after this step is native.
///
/// How the person comes back: `GET /auth/hmrc/initiate?redirect_url=wslcrm://hmrc&source=…` signs that
/// address into the OAuth `state`; after HMRC, OpsAPI's callback redirects to
/// `wslcrm://hmrc/<settings|file|vat>?hmrc_connected=true` (or `?hmrc_error=<code>`), which this
/// sheet catches. The server needed no change for this.
@MainActor
final class HMRCSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The app's URL scheme (Info.plist `CFBundleURLSchemes`).
    nonisolated static let callbackScheme = "wslcrm"
    /// Sent as `redirect_url`; the callback appends `/settings`, `/file` or `/vat`.
    nonisolated static let returnAddress = "wslcrm://hmrc"

    enum Outcome: Equatable, Sendable {
        case connected
        /// HMRC or OpsAPI said no (`access_denied`, `invalid_state`, `token_exchange_failed`…).
        case failed(String)
        /// The person closed the sheet.
        case cancelled
    }

    private var session: ASWebAuthenticationSession?

    /// Opens HMRC's sign-in page and waits for the person to finish or close it.
    func start(_ authURL: URL) async -> Outcome {
        await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: Self.callbackScheme) { url, error in
                if let url {
                    continuation.resume(returning: Self.outcome(of: url))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: .cancelled)
                } else {
                    continuation.resume(returning: .failed("unknown"))
                }
            }
            session.presentationContextProvider = self
            // No cookies shared with Safari: the Government Gateway sign-in doesn't linger on the phone.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { continuation.resume(returning: .failed("unknown")) }
        }
    }

    /// Reads `wslcrm://hmrc/settings?hmrc_connected=true` / `?hmrc_error=access_denied`.
    nonisolated static func outcome(of url: URL) -> Outcome {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if items.contains(where: { $0.name == "hmrc_connected" && $0.value == "true" }) { return .connected }
        if let code = items.first(where: { $0.name == "hmrc_error" })?.value, !code.isEmpty { return .failed(code) }
        return .failed("missing_params")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

/// Plain words for an HMRC connection that didn't work (the web's File My Tax wording).
enum HMRCConnectMessage {
    static func text(for code: String) -> String {
        switch code {
        case "access_denied":
            "You didn’t give permission on the HMRC page, so we couldn’t connect. Try again and choose "
                + "“Give permission” (or “Grant authority”) at the end."
        case "invalid_state":
            "The HMRC sign-in took too long. Please try again — it only takes a minute."
        case "missing_params":
            "We didn’t get an answer back from HMRC. Please try again."
        case "token_exchange_failed":
            "HMRC didn’t accept the connection just now. Please wait a minute and try again."
        case "token_store_failed":
            "We couldn’t save your HMRC connection. Please try again; if it keeps happening, contact us."
        case "server_misconfigured":
            "Connecting to HMRC isn’t switched on for this workspace yet. Please contact us, or choose "
                + "“Our accountant files it”."
        default:
            "Something went wrong connecting to HMRC. Please try again."
        }
    }
}

extension TaxAPI {
    /// Asks OpsAPI for HMRC's sign-in address, opens it, and reports how it went.
    /// `source`: "settings", "file" or "vat"; `purpose`: nil (Income Tax), "vat" or "vat_agent".
    @MainActor
    func connectHMRC(source: String, purpose: String? = nil, signIn: HMRCSignIn) async throws -> HMRCSignIn.Outcome {
        let response = try await get("/auth/hmrc/initiate", query: [
            "source": source, "purpose": purpose, "redirect_url": HMRCSignIn.returnAddress,
        ], namespace: false)
        guard let raw = response["auth_url"]?.stringValue, let url = URL(string: raw) else {
            throw ResourceService.problem(422, "HMRC’s sign-in page couldn’t be opened. Please try again.")
        }
        return await signIn.start(url)
    }
}
