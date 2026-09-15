// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import Security
import SwiftUI
import WebKit

struct ALACarteLibraryItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case album, song, playlist }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let relativePath: String
    let trackCount: Int
}

enum ALACarteServerAddress {
    static func parse(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw ALACarteError.invalidServerURL
        }
        components.scheme = scheme
        if components.path == "/" { components.path = "" }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw ALACarteError.invalidServerURL }
        return url
    }
}

final class ALACarteClient: @unchecked Sendable {
    private struct LoginResponse: Decodable { let ok: Bool }
    private struct VersionResponse: Decodable {
        let apiVersion: Int
        let audioExtensions: [String]
    }
    private struct LibraryResponse: Decodable {
        struct Album: Decodable {
            let id: String
            let artistName: String
            let albumName: String
            let relPath: String
            let trackCount: Int
        }
        struct Song: Decodable {
            let id: String
            let artistName: String
            let songName: String
            let relPath: String
        }
        struct Playlist: Decodable {
            let id: String
            let relPath: String
            let playlistName: String
            let trackCount: Int
        }
        let albums: [Album]
        let singles: [Song]
        let playlists: [Playlist]
    }
    private struct ExportManifest: Decodable {
        struct File: Decodable { let path: String; let byteCount: Int64 }
        let name: String
        let files: [File]
    }

    let baseURL: URL
    private let session: URLSession
    private var sessionCookieHeader: String?

    init(
        baseURL: URL,
        requestTimeout: TimeInterval = 60,
        session: URLSession? = nil,
        loadSavedSession: Bool = true
    ) {
        self.baseURL = baseURL
        sessionCookieHeader = loadSavedSession ? ALACarteSessionKeychain.load(server: baseURL) : nil
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            let cookieStorage = HTTPCookieStorage()
            cookieStorage.cookieAcceptPolicy = .always
            configuration.httpCookieStorage = cookieStorage
            configuration.httpShouldSetCookies = true
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = 60 * 60
            self.session = URLSession(configuration: configuration)
        }
    }

    var hasSavedSession: Bool { sessionCookieHeader != nil }
    var webSessionCookieHeader: String? { sessionCookieHeader }

    func forgetSavedSession() {
        sessionCookieHeader = nil
        ALACarteSessionKeychain.delete(server: baseURL)
    }

    func login(username: String, password: String) async throws {
        var request = URLRequest(url: endpoint("api/auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PodBridge/1", forHTTPHeaderField: "X-PodBridge-Client")
        request.setValue(originHeader, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, response) = try await session.data(for: request)
        try validate(response: response, body: data)
        guard try JSONDecoder().decode(LoginResponse.self, from: data).ok else {
            throw URLError(.userAuthenticationRequired)
        }
        guard captureSessionCookie(from: response) else {
            throw ALACarteError.server("ALACarte did not return a session cookie.")
        }
    }

    func validateCompatibility() async throws {
        let data = try await responseData(for: URLRequest(url: endpoint("api/podbridge/version")))
        let response = try JSONDecoder().decode(VersionResponse.self, from: data)
        guard response.apiVersion == 1 else {
            throw ALACarteError.incompatibleServer
        }
        let extensions = Set(response.audioExtensions.map { $0.lowercased() })
        guard extensions.contains("m4a") else {
            throw ALACarteError.incompatibleServer
        }
    }

    func library() async throws -> [ALACarteLibraryItem] {
        let data = try await responseData(for: URLRequest(url: endpoint("api/library")))
        let response = try JSONDecoder().decode(LibraryResponse.self, from: data)
        let albums = response.albums.map {
            ALACarteLibraryItem(
                id: "album:\($0.id)", kind: .album, title: $0.albumName,
                subtitle: "\($0.artistName) · \($0.trackCount) tracks",
                relativePath: $0.relPath, trackCount: $0.trackCount
            )
        }
        let songs = response.singles.map {
            ALACarteLibraryItem(
                id: "song:\($0.id)", kind: .song, title: $0.songName,
                subtitle: $0.artistName, relativePath: $0.relPath, trackCount: 1
            )
        }
        let playlists = response.playlists.map {
            ALACarteLibraryItem(
                id: "playlist:\($0.id)", kind: .playlist, title: $0.playlistName,
                subtitle: "\($0.trackCount) tracks", relativePath: $0.relPath,
                trackCount: $0.trackCount
            )
        }
        return (playlists + albums + songs).sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func download(
        _ item: ALACarteLibraryItem,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void
    ) async throws -> URL {
        var manifestComponents = URLComponents(
            url: endpoint("api/podbridge/export"),
            resolvingAgainstBaseURL: false
        )!
        manifestComponents.queryItems = [URLQueryItem(name: "path", value: item.relativePath)]
        let manifestData = try await responseData(for: URLRequest(url: manifestComponents.url!))
        let manifest = try JSONDecoder().decode(ExportManifest.self, from: manifestData)
        guard !manifest.files.isEmpty, manifest.files.count <= 20_000 else {
            throw PodBridgeError.noMusicFiles
        }
        let audioExtensions = MusicTransferEngine.supportedExtensions
        guard manifest.files.contains(where: { audioExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }) else {
            throw ALACarteError.noCompatibleAudio
        }
        guard manifest.files.allSatisfy({ $0.byteCount >= 0 && $0.byteCount <= Int64(Int.max) }) else {
            throw ALACarteError.server("The server returned an invalid file size.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodBridge-ALACarte-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            for (index, file) in manifest.files.enumerated() {
                try Task.checkCancellation()
                let relative = try safeRelativePath(file.path)
                let fileExtension = URL(fileURLWithPath: relative).pathExtension.lowercased()
                guard audioExtensions.contains(fileExtension) || fileExtension == "m3u" || fileExtension == "m3u8" else {
                    throw ALACarteError.unsupportedFileType(fileExtension)
                }
                var components = URLComponents(
                    url: endpoint("api/podbridge/file"),
                    resolvingAgainstBaseURL: false
                )!
                components.queryItems = [URLQueryItem(name: "path", value: relative)]
                var request = URLRequest(url: components.url!)
                applySessionCookie(to: &request)
                let (temporary, response) = try await session.download(for: request)
                _ = captureSessionCookie(from: response)
                try validate(response: response)
                let destination = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                let actual = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                guard actual == Int(file.byteCount) else {
                    throw PodBridgeError.audioCopyVerificationFailed
                }
                await progress(index + 1, manifest.files.count)
            }
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private var originHeader: String {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url!.absoluteString
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        var authorizedRequest = request
        applySessionCookie(to: &authorizedRequest)
        let (data, response) = try await session.data(for: authorizedRequest)
        _ = captureSessionCookie(from: response)
        try validate(response: response, body: data)
        return data
    }

    private func applySessionCookie(to request: inout URLRequest) {
        if let sessionCookieHeader {
            request.setValue(sessionCookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    @discardableResult
    private func captureSessionCookie(from response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let firstPart = setCookie.split(separator: ";", maxSplits: 1).first else {
            return false
        }
        let pair = String(firstPart).trimmingCharacters(in: .whitespacesAndNewlines)
        guard pair.hasPrefix("alacarte_session=") || pair.hasPrefix("__Host-alacarte_session=") else {
            return false
        }
        sessionCookieHeader = pair
        ALACarteSessionKeychain.save(pair, server: baseURL)
        return true
    }

    private func validate(response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            if let body,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let message = json["error"] as? String {
                throw ALACarteError.server(message)
            }
            throw URLError(
                http.statusCode == 401 ? .userAuthenticationRequired : .badServerResponse
            )
        }
    }

    private func safeRelativePath(_ value: String) throws -> String {
        let portable = value.replacingOccurrences(of: "\\", with: "/")
        let parts = portable.split(separator: "/", omittingEmptySubsequences: false)
        guard !portable.hasPrefix("/"),
              !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ALACarteError.server("The server returned an unsafe library path.")
        }
        return portable
    }
}

private enum ALACarteSessionKeychain {
    private static let service = "com.balantaev.podbridge.ALACarteSession"

    static func load(server: URL) -> String? {
        var query = baseQuery(server: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, server: URL) {
        delete(server: server)
        var query = baseQuery(server: server)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(server: URL) {
        SecItemDelete(baseQuery(server: server) as CFDictionary)
    }

    private static func baseQuery(server: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.absoluteString,
        ]
    }
}

enum ALACarteError: LocalizedError {
    case invalidServerURL
    case incompatibleServer
    case noCompatibleAudio
    case unsupportedFileType(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a complete http:// or https:// address for your ALACarte server."
        case .incompatibleServer:
            return "This server does not provide the PodBridge API. Install the PodBridge-compatible ALACarte fork."
        case .noCompatibleAudio:
            return "No iPod-compatible audio was returned. Set ALACarte Library output to ALAC instead of FLAC."
        case .unsupportedFileType(let type):
            return "The server returned an unsupported .\(type) file. Set ALACarte Library output to ALAC."
        case .server(let message):
            return message
        }
    }
}

struct ALACarteBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    @AppStorage("alacarte.serverURL") private var serverAddress = ""
    @AppStorage("alacarte.username") private var username = ""
    @State private var password = ""
    @State private var client: ALACarteClient?
    @State private var items: [ALACarteLibraryItem] = []
    @State private var searchText = ""
    @State private var connecting = false
    @State private var errorMessage: String?
    @State private var selectedItemIDs: Set<String> = []
    @State private var showingWebInterface = false

    private var filteredItems: [ALACarteLibraryItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.subtitle.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if client == nil {
                    Section {
                        TextField("http://server.local:7373", text: $serverAddress)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        Button(connecting ? "Connecting…" : "Connect", systemImage: "network") {
                            connect()
                        }
                        .disabled(connecting || serverAddress.isEmpty || username.isEmpty || password.isEmpty)
                    } header: {
                        Text("Your ALACarte server")
                    } footer: {
                        Text("Use a server on your home network or an HTTPS address reachable through your private VPN. The password is not saved; the signed-in session is stored in Keychain.")
                    }
                } else {
                    Section {
                        Label(client?.baseURL.host ?? "Connected", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button {
                            showingWebInterface = true
                        } label: {
                            Label("Open full ALACarte interface", systemImage: "globe")
                        }
                    } footer: {
                        Text("Search, queue downloads, and change settings on your own ALACarte server.")
                    }
                    Section {
                        ForEach(filteredItems) { item in
                            Button {
                                if selectedItemIDs.contains(item.id) {
                                    selectedItemIDs.remove(item.id)
                                } else {
                                    selectedItemIDs.insert(item.id)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: icon(item.kind)).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).foregroundStyle(.primary)
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedItemIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                                }
                            }
                            .disabled(model.isCopying)
                        }
                    } header: {
                        Text("Already downloaded")
                    } footer: {
                        Text("PodBridge imports only existing ALAC/M4A files. Download management remains in your server's own interface.")
                    }
                    if !selectedItemIDs.isEmpty {
                        Section {
                            Button {
                                guard let client else { return }
                                let selected = items.filter { selectedItemIDs.contains($0.id) }
                                model.importFromALACarte(client: client, items: selected)
                            } label: {
                                Label("Write \(selectedItemIDs.count) selected to iPod", systemImage: "arrow.down.to.line.compact")
                            }
                            .disabled(
                                model.isCopying
                                    || model.destinationFolder == nil
                                    || model.destinationDeviceProfile == nil
                                    || model.destinationNeedsFirewireID
                            )
                            Button("Clear selection", role: .destructive) {
                                selectedItemIDs.removeAll()
                            }
                            .disabled(model.isCopying)
                        } header: {
                            Text("Import queue")
                        } footer: {
                            if model.destinationFolder == nil {
                                Text("Choose the iPod destination in PodBridge before importing.")
                            }
                        }
                    }
                }
                if let status = model.alacarteStatus {
                    Section { HStack(spacing: 12) { ProgressView(); Text(status) } }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .searchable(text: $searchText, prompt: "Album, playlist, or song")
            .navigationTitle("ALACarte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(model.isCopying)
                }
                if client != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Disconnect") {
                            client?.forgetSavedSession()
                            client = nil
                            items = []
                            selectedItemIDs.removeAll()
                            password = ""
                        }
                        .disabled(model.isCopying)
                    }
                }
            }
        }
        .task { await restoreSavedSession() }
        .sheet(isPresented: $showingWebInterface) {
            if let client {
                ALACarteWebInterfaceView(
                    serverURL: client.baseURL,
                    sessionCookieHeader: client.webSessionCookieHeader
                )
            }
        }
    }

    private func connect() {
        connecting = true
        errorMessage = nil
        Task {
            do {
                let url = try ALACarteServerAddress.parse(serverAddress)
                let newClient = ALACarteClient(baseURL: url)
                try await newClient.login(username: username, password: password)
                try await newClient.validateCompatibility()
                items = try await newClient.library()
                client = newClient
                serverAddress = url.absoluteString
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            connecting = false
        }
    }

    @MainActor
    private func restoreSavedSession() async {
        guard client == nil, !connecting, !serverAddress.isEmpty else { return }
        do {
            let url = try ALACarteServerAddress.parse(serverAddress)
            let savedClient = ALACarteClient(baseURL: url, requestTimeout: 10)
            guard savedClient.hasSavedSession else { return }
            connecting = true
            try await savedClient.validateCompatibility()
            items = try await savedClient.library()
            client = savedClient
        } catch ALACarteError.server(let message) where message == "unauthorized" {
            if let url = try? ALACarteServerAddress.parse(serverAddress) {
                ALACarteClient(baseURL: url).forgetSavedSession()
            }
            errorMessage = "The saved ALACarte session expired. Sign in again."
        } catch {
            errorMessage = error.localizedDescription
        }
        connecting = false
    }

    private func icon(_ kind: ALACarteLibraryItem.Kind) -> String {
        switch kind {
        case .album: "square.stack"
        case .song: "music.note"
        case .playlist: "music.note.list"
        }
    }
}

private struct ALACarteWebInterfaceView: View {
    @Environment(\.dismiss) private var dismiss
    let serverURL: URL
    let sessionCookieHeader: String?

    var body: some View {
        NavigationStack {
            ALACarteWebPage(
                serverURL: serverURL,
                sessionCookieHeader: sessionCookieHeader
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("ALACarte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
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
