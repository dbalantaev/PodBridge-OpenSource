// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import WebKit

struct ALACarteWebInterfaceView: View {
    @Environment(\.dismiss) private var dismiss
    let serverURL: URL
    let sessionCookieHeader: String?
    let didClose: () -> Void

    var body: some View {
        NavigationView {
            ALACarteWebPage(
                serverURL: serverURL,
                sessionCookieHeader: sessionCookieHeader
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("ALACarte")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        didClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ALACarteWebPage: UIViewRepresentable {
    let serverURL: URL
    let sessionCookieHeader: String?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        let request = authenticatedEntryRequest()
        let load = { _ = webView.load(request) }
        if let cookie = makeSessionCookie() {
            configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { load() }
        } else {
            load()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private func makeSessionCookie() -> HTTPCookie? {
        guard let sessionCookieHeader, sessionCookieHeader.contains("=") else { return nil }
        let secure = serverURL.scheme == "https" ? "; Secure" : ""
        let header = "\(sessionCookieHeader); Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict\(secure)"
        return HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header],
            for: serverURL
        ).first
    }

    private func authenticatedEntryRequest() -> URLRequest {
        guard let sessionCookieHeader,
              let separator = sessionCookieHeader.firstIndex(of: "=") else {
            return URLRequest(url: serverURL)
        }
        let token = sessionCookieHeader[sessionCookieHeader.index(after: separator)...]
        let entryURL = serverURL.appendingPathComponent("api/auth/webview-session")
        var request = URLRequest(url: entryURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}
