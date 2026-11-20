import Foundation
import UIKit

/// HMRC's fraud-prevention signals for a mobile app (connection method `MOBILE_APP_VIA_SERVER`).
///
/// HMRC's Making Tax Digital APIs need headers describing the device a request came from. The app
/// talks to OpsAPI, and OpsAPI talks to HMRC, so the app sends what only the device knows as
/// `X-Gov-Client-*` request headers and the server turns them into HMRC's `Gov-Client-*` headers
/// (`lapis/helper/hmrc.lua` `build_fraud_headers`), adding the public IP, port and its own vendor
/// headers. Only real values are sent — HMRC penalises made-up ones.
///
/// What OpsAPI reads today: Device-ID, Timezone, Screens, Window-Size and User-IDs. It also falls back
/// to the request's `User-Agent` for the user agent. `Connection-Method` and `User-Agent` (HMRC's
/// mobile format: os-family, os-version, device-manufacturer, device-model) are sent as well so the
/// server can report a mobile connection once it reads them; until then it labels every connection
/// `WEB_APP_VIA_SERVER` (see the module report). No `Browser-JS-User-Agent` is sent: there is no
/// browser or JavaScript in a native app.
enum HMRCFraudSignals {
    static let connectionMethod = "MOBILE_APP_VIA_SERVER"
    private static let deviceIDKey = "hmrc_device_id"

    /// The headers for an HMRC-bound call.
    @MainActor
    static func headers(userID: String?, defaults: UserDefaults = .standard) -> [String: String] {
        let window = keyWindow()
        let screen = window?.windowScene?.screen ?? UIScreen.main
        let size = window?.bounds.size ?? screen.bounds.size
        var headers: [String: String] = [
            "X-Gov-Client-Connection-Method": connectionMethod,
            "X-Gov-Client-Device-ID": deviceID(defaults),
            "X-Gov-Client-Timezone": timezone(),
            "X-Gov-Client-Screens": screens(width: screen.nativeBounds.width / screen.nativeScale,
                                            height: screen.nativeBounds.height / screen.nativeScale,
                                            scale: screen.scale),
            "X-Gov-Client-Window-Size": windowSize(width: size.width, height: size.height),
            "X-Gov-Client-User-Agent": userAgent(osVersion: UIDevice.current.systemVersion, model: deviceModel()),
        ]
        if let userID, !userID.isEmpty {
            headers["X-Gov-Client-User-IDs"] = "opsapi=\(encode(userID))"
        }
        return headers
    }

    /// A random id made once per installation and kept, so HMRC sees the same device every time.
    static func deviceID(_ defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: deviceIDKey), UUID(uuidString: existing) != nil { return existing }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    /// HMRC's `UTC±HH:MM`.
    static func timezone(_ zone: TimeZone = .current, at date: Date = Date()) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", sign, minutes / 60, minutes % 60)
    }

    /// HMRC's `width=&height=&scaling-factor=&colour-depth=` (points, as a browser reports CSS pixels).
    static func screens(width: CGFloat, height: CGFloat, scale: CGFloat) -> String {
        "width=\(Int(width.rounded()))&height=\(Int(height.rounded()))&scaling-factor=\(number(scale))&colour-depth=24"
    }

    static func windowSize(width: CGFloat, height: CGFloat) -> String {
        "width=\(Int(width.rounded()))&height=\(Int(height.rounded()))"
    }

    /// HMRC's mobile user agent: `os-family=iOS&os-version=…&device-manufacturer=Apple&device-model=…`.
    static func userAgent(osVersion: String, model: String) -> String {
        "os-family=iOS&os-version=\(encode(osVersion))&device-manufacturer=Apple&device-model=\(encode(model))"
    }

    /// The hardware model (`iPhone15,2`), or the simulated one on the simulator.
    static func deviceModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? UIDevice.current.model : model
    }

    /// Percent-encodes a value inside HMRC's `key=value&…` headers.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func number(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    @MainActor
    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
