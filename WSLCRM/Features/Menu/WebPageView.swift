import SwiftUI
import WebKit

/// A web dashboard page inside the app, already signed in as this person in this workspace. Used
/// for every module the app has no screen of its own for, so the phone offers all of the web.
struct WebPageView: View {
    let route: WebPageRoute
    @Environment(SessionStore.self) private var session
    @State private var phase: Phase = .loading
    @State private var isLoading = true
    @State private var reload = 0
    @State private var download: DownloadedFile?
    /// When the page last had to be signed back in: once a minute at most, so a page that keeps
    /// refusing can't loop.
    @State private var lastSignIn: Date?

    enum Phase: Equatable {
        case loading
        case ready(WebSession, URL)
        case failed(String)
    }

    var body: some View {
        content
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { reload += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(!isReady)
                        .accessibilityIdentifier("web.reload")
                }
            }
            .task { await start(forceRefresh: false) }
            .sheet(item: $download) { file in ShareSheet(items: [file.url]) }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Opening \(route.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open \(route.title)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await start(forceRefresh: true) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("web.retry")
            }
        case .ready(let webSession, let url):
            DashboardWebView(session: webSession, url: url, reload: reload,
                             isLoading: $isLoading,
                             onSignInPage: { Task { await signInAgain() } },
                             onDownloaded: { download = DownloadedFile(url: $0) },
                             onFailed: { phase = .failed($0) })
                .overlay {
                    if isLoading { ProgressView().controlSize(.large) }
                }
                .accessibilityIdentifier("web.page")
        }
    }

    private var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private func start(forceRefresh: Bool) async {
        if case .ready = phase, !forceRefresh { return }
        phase = .loading
        do {
            guard let webSession = try await session.webSession(forceRefresh: forceRefresh) else {
                phase = .failed("This server has no web dashboard linked to it, so this page can't open in the app.")
                return
            }
            guard let url = webSession.url(for: route) else {
                phase = .failed("The page address isn't valid.")
                return
            }
            isLoading = true
            phase = .ready(webSession, url)
        } catch {
            phase = .failed(error.asAPIError.localizedDescription)
        }
    }

    /// The dashboard turned the page away (its token ran out or was refused): get a fresh one and
    /// open the page again.
    private func signInAgain() async {
        if let lastSignIn, Date().timeIntervalSince(lastSignIn) < 60 {
            phase = .failed("This page keeps asking you to sign in. Try again, or sign out and back in.")
            return
        }
        lastSignIn = Date()
        await start(forceRefresh: true)
    }
}

private struct DownloadedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The share sheet, for files a page downloads (exports, PDFs).
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The WKWebView itself. Each page gets its own private, in-memory storage, written by the
/// sign-in script and thrown away when the page closes: nothing about the session is kept on disk
/// and no other workspace's state can leak in.
private struct DashboardWebView: UIViewRepresentable {
    let session: WebSession
    let url: URL
    let reload: Int
    @Binding var isLoading: Bool
    let onSignInPage: () -> Void
    let onDownloaded: (URL) -> Void
    let onFailed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Pinch-to-zoom stays available (accessibility) even though the dashboard turns off the
        // zoom-on-tap that iPhones do for small text boxes — the same as Safari.
        configuration.ignoresViewportScaleLimits = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // The navigation stack owns the back swipe.
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.observeAddress(of: webView)
        context.coordinator.load(session: session, url: url, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.session != session || coordinator.target != url {
            coordinator.load(session: session, url: url, in: webView)
        } else if coordinator.reload != reload {
            coordinator.reload = reload
            webView.reload()
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        coordinator.addressObservation = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: DashboardWebView
        var session: WebSession?
        var target: URL?
        var reload = 0
        var addressObservation: NSKeyValueObservation?
        private var downloads: [ObjectIdentifier: URL] = [:]

        init(parent: DashboardWebView) {
            self.parent = parent
            self.reload = parent.reload
        }

        func load(session: WebSession, url: URL, in webView: WKWebView) {
            self.session = session
            self.target = url
            let scripts = webView.configuration.userContentController
            scripts.removeAllUserScripts()
            scripts.addUserScript(WKUserScript(source: session.bootstrapScript, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true))
            webView.load(URLRequest(url: url))
        }

        /// The dashboard also moves to its sign-in screen without a page load (client-side
        /// routing), which no navigation callback sees — the address does change.
        func observeAddress(of webView: WKWebView) {
            addressObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = webView.url, let session = self.session,
                          WebNavigation.decide(url, dashboard: session.dashboard, isMainFrame: true) == .signInAgain
                    else { return }
                    webView.stopLoading()
                    self.parent.onSignInPage()
                }
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let session else { return decisionHandler(.cancel) }
            if action.shouldPerformDownload { return decisionHandler(.download) }
            let isMainFrame = action.targetFrame?.isMainFrame ?? true
            switch WebNavigation.decide(action.request.url, dashboard: session.dashboard, isMainFrame: isMainFrame) {
            case .allow:
                decisionHandler(.allow)
            case .signInAgain:
                decisionHandler(.cancel)
                parent.onSignInPage()
            case .openOutside:
                decisionHandler(.cancel)
                if let url = action.request.url { UIApplication.shared.open(url) }
            case .block:
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            parent.isLoading = false
            let error = error as NSError
            // A cancelled load (we cancelled it, or a newer load replaced it) or a load that
            // became a download isn't a failure.
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain", error.code == 102 { return }
            parent.onFailed(error.localizedDescription)
        }

        /// `target="_blank"` and `window.open`: the dashboard's own pages open here, others outside.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let session, let url = action.request.url else { return nil }
            switch WebNavigation.decide(url, dashboard: session.dashboard, isMainFrame: true) {
            case .allow: webView.load(action.request)
            case .openOutside: UIApplication.shared.open(url)
            case .signInAgain: parent.onSignInPage()
            case .block: break
            }
            return nil
        }

        // MARK: Downloads

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
            let destination = folder.appendingPathComponent(name)
            downloads[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
            parent.onDownloaded(file)
        }

        /// A failed download leaves the page as it is; the person can tap it again.
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloads.removeValue(forKey: ObjectIdentifier(download))
        }
    }
}
