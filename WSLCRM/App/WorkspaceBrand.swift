import Foundation
import Observation
import SwiftUI
import UIKit
import WebKit

/// The business a person works for, as the app shows it: name, logo and report letterhead.
///
/// One build serves every business. The house brand (Workstation) is the default, and a
/// workspace that has a logo on the server (`namespaces.logo_url`, set from the web
/// dashboard's workspace settings) replaces it once someone signs in to it. The phone keeps
/// that brand, so DBS staff see DBS at the next sign-in and after every app update, and
/// Workstation staff keep Workstation. Nothing about a business is compiled into the app.
///
/// The home-screen icon and the name under it are part of the app bundle and iOS can't fetch
/// them from a server, so they are always Workstation's.
struct WorkspaceBrand: Codable, Equatable, Sendable {
    var workspaceUuid: String
    var name: String
    /// Where the logo comes from (absolute; a dashboard-relative path is resolved first).
    var logoSource: URL
    /// The rendered logo on this phone, under `BrandStore.directory`.
    var logoFileName: String?
    var company: Company?

    /// `namespaces.settings.company`: the letterhead printed on reports.
    struct Company: Codable, Equatable, Sendable {
        var displayName: String?
        var legalName: String?
        var companyNumber: String?
        var vatNumber: String?
        var address: String?
        var phone: String?
        var email: String?
        var strapline: String?
    }

    /// The house brand with this business's identity laid over it.
    func applied(to house: Brand, logoFile: URL?) -> Brand {
        var brand = house
        let name = company?.displayName?.nonBlank ?? self.name
        brand.name = name
        brand.logoFile = logoFile
        brand.company = ReportCompany(
            name: name,
            legalName: company?.legalName?.nonBlank,
            strapline: company?.strapline?.nonBlank,
            address: company?.address?.nonBlank,
            phone: company?.phone?.nonBlank,
            email: company?.email?.nonBlank,
            companyNumber: company?.companyNumber?.nonBlank,
            vatNumber: company?.vatNumber?.nonBlank)
        return brand
    }

    /// `logo_url` as stored: absolute, or a path on the web dashboard (`/brands/dbs-ltd.svg`).
    static func logoURL(_ raw: String?, dashboard: URL?) -> URL? {
        guard let raw = raw?.nonBlank else { return nil }
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            return url
        }
        guard raw.hasPrefix("/"), let dashboard else { return nil }
        return URL(string: raw, relativeTo: dashboard)?.absoluteURL
    }
}

private extension String {
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Keeps `Brand.current` in step with the signed-in workspace and remembers it on the phone.
@MainActor
@Observable
final class BrandStore {
    static let shared = BrandStore()

    private(set) var brand: Brand

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let house: Brand
    @ObservationIgnored private let fetchLogo: @Sendable (URL) async throws -> Data
    @ObservationIgnored private var saved: WorkspaceBrand?

    static let defaultsKey = "workspaceBrand"

    init(defaults: UserDefaults = .standard,
         directory: URL = BrandStore.defaultDirectory(),
         house: Brand = .house,
         fetchLogo: @escaping @Sendable (URL) async throws -> Data = BrandStore.download) {
        self.defaults = defaults
        self.directory = directory
        self.house = house
        self.fetchLogo = fetchLogo
        saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(WorkspaceBrand.self, from: $0) }
        brand = house
        if let saved, let file = file(for: saved) {
            brand = saved.applied(to: house, logoFile: file)
        } else {
            saved = nil
        }
        Brand.setCurrent(brand)
    }

    /// The workspace someone is now working in. A workspace without a logo shows the house brand.
    func update(workspaceUuid: String, name: String, logoURL: URL?, company: WorkspaceBrand.Company?) async {
        guard let logoURL else {
            clear()
            return
        }
        var next = WorkspaceBrand(workspaceUuid: workspaceUuid, name: name, logoSource: logoURL,
                                  logoFileName: nil, company: company)
        // Same logo as last time and still on disk: no download.
        if let saved, saved.workspaceUuid == workspaceUuid, saved.logoSource == logoURL, file(for: saved) != nil {
            next.logoFileName = saved.logoFileName
        } else if let image = await render(logoURL), let data = image.pngData() {
            let fileName = "\(workspaceUuid)-\(abs(logoURL.absoluteString.hashValue)).png"
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)) != nil {
                next.logoFileName = fileName
            }
        } else if let saved, saved.workspaceUuid == workspaceUuid, file(for: saved) != nil {
            // Offline or the logo is briefly unavailable: keep showing the one we have.
            next.logoFileName = saved.logoFileName
        }
        guard next.logoFileName != nil else {
            // A logo that can't be shown is no logo: the house brand, not a blank square.
            clear()
            return
        }
        removeOldLogos(keeping: next.logoFileName)
        persist(next)
    }

    /// Back to the house brand (a workspace without a logo, or a different server).
    func clear() {
        saved = nil
        defaults.removeObject(forKey: Self.defaultsKey)
        removeOldLogos(keeping: nil)
        publish(house)
    }

    private func persist(_ record: WorkspaceBrand) {
        saved = record
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.defaultsKey) }
        publish(record.applied(to: house, logoFile: file(for: record)))
    }

    private func publish(_ next: Brand) {
        Brand.setCurrent(next)
        if brand != next { brand = next }
    }

    private func file(for record: WorkspaceBrand) -> URL? {
        guard let name = record.logoFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func removeOldLogos(keeping: String?) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name != keeping {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func render(_ url: URL) async -> UIImage? {
        guard let data = try? await fetchLogo(url), !data.isEmpty else { return nil }
        if let image = UIImage(data: data) { return image }
        // The web dashboard's logos are often SVG, which UIKit can't decode: let WebKit draw it.
        guard Self.looksLikeSVG(data, url: url) else { return nil }
        return await SVGRasterizer.render(data)
    }

    static func looksLikeSVG(_ data: Data, url: URL) -> Bool {
        if url.pathExtension.lowercased() == "svg" { return true }
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WorkspaceBrand", isDirectory: true)
    }

    @Sendable nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("image/png, image/jpeg, image/svg+xml, image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Cap the size: a logo is a few KB, and this is drawn on every screen.
        guard data.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}

/// Draws an SVG into a bitmap with WebKit (UIKit has no public SVG decoder).
@MainActor
enum SVGRasterizer {
    /// `timeout`: WebKit's first page in a process starts its web content process, which can take
    /// several seconds on a slow device; this runs in the background, so waiting is fine.
    static func render(_ svg: Data, side: CGFloat = 240, timeout: Duration = .seconds(30)) async -> UIImage? {
        let markup = String(decoding: svg, as: UTF8.self)
        guard markup.lowercased().contains("<svg") else { return nil }
        let configuration = WKWebViewConfiguration()
        // Static artwork: no scripts, no network.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: side, height: side), configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(Int(side)),initial-scale=1">
        <style>html,body{margin:0;padding:0;background:transparent;width:100%;height:100%;overflow:hidden}
        svg{display:block;width:100%;height:100%}</style></head><body>\(markup)</body></html>
        """
        let loader = Loader(timeout: timeout)
        view.navigationDelegate = loader
        view.loadHTMLString(html, baseURL: nil)
        guard await loader.finished() else { return nil }
        // WebKit's PDF export draws without the view being on screen (a snapshot needs a window
        // and comes back blank off screen); the vector page is then drawn into a bitmap.
        let pdf = WKPDFConfiguration()
        pdf.rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let data = try? await view.pdf(configuration: pdf),
              let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            // PDF space is bottom-up.
            cg.translateBy(x: 0, y: side)
            cg.scaleBy(x: side / max(box.width, 1), y: -side / max(box.height, 1))
            cg.drawPDFPage(page)
        }
    }

    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var result: Bool?
        private let timeout: Duration

        init(timeout: Duration) { self.timeout = timeout }

        func finished() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: self?.timeout ?? .seconds(30))
                    self?.complete(false)
                }
            }
        }

        private func complete(_ ok: Bool) {
            if result == nil { result = ok }
            continuation?.resume(returning: ok)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            complete(false)
        }
    }
}
