import Foundation
import LocalAuthentication

/// Face ID / Touch ID unlock for a stored session.
///
/// The Keychain tokens stay readable after first unlock (so offline writes can replay);
/// this gate controls whether the UI reveals the signed-in session.
struct BiometricGate: Sendable {
    enum Kind: Sendable { case none, faceID, touchID, opticID }

    private static let enabledKey = "biometricUnlockEnabled"

    var availableKind: Kind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    var displayName: String {
        switch availableKind {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .none: "Passcode"
        }
    }

    /// Prompts for biometrics, falling back to the device passcode.
    func authenticate(reason: String = "Unlock your session") async -> Bool {
        #if DEBUG
        // UI tests can't present Face ID; `-UITestBiometric pass|fail` stands in for the person.
        if let result = Self.uiTestResult { return result }
        #endif
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    #if DEBUG
    static let uiTestArgument = "-UITestBiometric"

    private static var uiTestResult: Bool? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: uiTestArgument), index + 1 < arguments.count else { return nil }
        return arguments[index + 1] == "pass"
    }
    #endif
}
