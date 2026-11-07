import Foundation
import SwiftUI
import WebKit

/// Each TeraBox account gets its own persistent, isolated WebKit data store (iOS 17+),
/// so multiple TeraBox accounts never share cookies.
enum TeraBoxWebStore {
    @MainActor
    static func store(for account: UUID) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: account)
    }

    @MainActor
    static func removeData(for account: UUID) async {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: account)
        } catch {
            Log.security.notice("could not remove TeraBox web store: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func isTeraBoxDomain(_ domain: String) -> Bool {
        let d = domain.lowercased()
        return d.contains("terabox") || d.contains("1024tera") || d.contains("teraboxapp")
    }
}

/// Shows the official TeraBox website. The user signs in there themselves (password, Google,
/// Apple, etc.). The app never sees the password; once TeraBox sets its session cookie (`ndus`)
/// the session is captured into the Keychain.
struct TeraBoxLoginView: View {
    let accountID: UUID
    let onComplete: (Result<TeraBoxSession, AppError>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var loading = true
    @State private var capturing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green)
                    Text(host.isEmpty ? AppConfig.teraBoxHost : host).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if loading || capturing { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.bar)
                TeraBoxWebView(accountID: accountID, host: $host, loading: $loading, capturing: $capturing) { result in
                    onComplete(result)
                    dismiss()
                }
                Text(L("Sign in on the official TeraBox website. iCloud IPA never sees your password; it stores only the resulting session in the Keychain."))
                    .font(.caption).foregroundStyle(.secondary).padding()
            }
            .navigationTitle(L("Add TeraBox account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { onComplete(.failure(.cancelled)); dismiss() }
                }
            }
        }
    }
}

struct TeraBoxWebView: UIViewRepresentable {
    let accountID: UUID
    @Binding var host: String
    @Binding var loading: Bool
    @Binding var capturing: Bool
    let onCaptured: (Result<TeraBoxSession, AppError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = TeraBoxWebStore.store(for: accountID)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = web
        web.load(URLRequest(url: URL(string: "https://\(AppConfig.teraBoxHost)/main")!))
        context.coordinator.startPolling()
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: TeraBoxWebView
        weak var webView: WKWebView?
        private var timer: Timer?
        private var done = false

        init(_ parent: TeraBoxWebView) { self.parent = parent }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.checkSession() }
            }
        }

        func stopPolling() { timer?.invalidate(); timer = nil }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.loading = true
            parent.host = webView.url?.host ?? ""
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            parent.host = webView.url?.host ?? ""
            Task { await checkSession() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        private func checkSession() async {
            guard !done, let web = webView else { return }
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
            let tera = cookies.filter { TeraBoxWebStore.isTeraBoxDomain($0.domain) }
            guard tera.contains(where: { $0.name == "ndus" && !$0.value.isEmpty }) else { return }
            // Wait until the web app has loaded (jsToken is set by the page after login).
            guard let currentHost = web.url?.host, TeraBoxWebStore.isTeraBoxDomain(currentHost), !web.isLoading else { return }
            done = true
            stopPolling()
            parent.capturing = true
            var dict: [String: String] = [:]
            for c in tera { dict[c.name] = c.value }
            let ua = await evalString(web, "navigator.userAgent") ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
            let js = await evalString(web, "(function(){try{return String(window.jsToken||(window.locals&&window.locals.jsToken)||'')}catch(e){return ''}})()")
            let session = TeraBoxSession(cookies: dict, userAgent: ua, jsToken: js, bdstoken: nil,
                                         host: currentHost.contains("terabox") || currentHost.contains("1024tera") ? currentHost : AppConfig.teraBoxHost,
                                         capturedAt: Date())
            parent.onCaptured(.success(session))
        }

        /// Completion-handler based evaluation (safe when the script returns null/undefined).
        private func evalString(_ web: WKWebView, _ script: String) async -> String? {
            await withCheckedContinuation { cont in
                web.evaluateJavaScript(script) { value, _ in
                    let s = value as? String
                    cont.resume(returning: (s?.isEmpty ?? true) ? nil : s)
                }
            }
        }
    }
}
