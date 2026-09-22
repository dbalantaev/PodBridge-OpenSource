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
    private struct AuthStateResponse: Decodable {
        let authDisabled: Bool
        let passwordSet: Bool
        let authed: Bool
    }
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

    func authState() async throws -> (authDisabled: Bool, passwordSet: Bool, authed: Bool) {
        let data = try await responseData(for: URLRequest(url: endpoint("api/auth/state")))
        let state = try JSONDecoder().decode(AuthStateResponse.self, from: data)
        return (state.authDisabled, state.passwordSet, state.authed)
    }

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
            throw ALACarteError.server("ALACarte rejected the sign-in request.")
        }
        guard captureSessionCookie(from: response) || captureSessionCookieFromStorage() else {
            throw ALACarteError.server("Signed in, but ALACarte did not provide a session cookie.")
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

    func validateCompatibilityIfAvailable() async throws {
        do {
            try await validateCompatibility()
        } catch ALACarteError.endpointNotFound {
            // Servers released before this endpoint expose the same login/library/export API.
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
            if let separator = sessionCookieHeader.firstIndex(of: "=") {
                let token = sessionCookieHeader[sessionCookieHeader.index(after: separator)...]
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
        }
    }

    private func captureSessionCookieFromStorage() -> Bool {
        guard let storage = session.configuration.httpCookieStorage else { return false }
        let cookies = storage.cookies(for: baseURL) ?? []
        guard let cookie = cookies.first(where: {
            $0.name == "alacarte_session" || $0.name == "__Host-alacarte_session"
        }) else { return false }
        let pair = "\(cookie.name)=\(cookie.value)"
        sessionCookieHeader = pair
        ALACarteSessionKeychain.save(pair, server: baseURL)
        return true
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
            let serverMessage: String? = body.flatMap { data in
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            }
            switch http.statusCode {
            case 400:
                throw ALACarteError.server(serverMessage ?? "ALACarte rejected the request.")
            case 401:
                throw ALACarteError.server(
                    serverMessage == "invalid credentials"
                        ? "Incorrect ALACarte username or password."
                        : (serverMessage ?? "Your ALACarte session has expired. Sign in again.")
                )
            case 403:
                throw ALACarteError.server(serverMessage ?? "ALACarte denied this request.")
            case 404:
                throw ALACarteError.endpointNotFound
            case 409:
                throw ALACarteError.server(serverMessage ?? "ALACarte authentication is not ready for this request.")
            case 429:
                let retry = http.value(forHTTPHeaderField: "Retry-After")
                    .map { " Try again in \($0) seconds." } ?? ""
                throw ALACarteError.server("Too many sign-in attempts.\(retry)")
            default:
                throw ALACarteError.server(serverMessage ?? "ALACarte returned HTTP \(http.statusCode).")
            }
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
    case endpointNotFound
    case incompatibleRunningServer(String)
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
        case .endpointNotFound:
            return "The requested ALACarte API endpoint was not found."
        case .incompatibleRunningServer(let address):
            return "ALACarte is reachable at \(address), but the running server does not contain the PodBridge API. Restart the PodBridge-compatible ALACarte server, then try again."
        case .server(let message):
            return message
        }
    }
}

struct ALACarteBrowserView: View {
    private enum ConnectionMode: String, CaseIterable, Identifiable {
        case automatic = "Auto"
        case local = "Local"
        case internet = "Internet"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    // serverURL is kept only to migrate settings from the previous single-address UI.
    @AppStorage("alacarte.serverURL") private var legacyServerAddress = ""
    @AppStorage("alacarte.localServerURL") private var localServerAddress = ""
    @AppStorage("alacarte.internetServerURL") private var internetServerAddress = ""
    @AppStorage("alacarte.connectionMode") private var connectionMode = ConnectionMode.automatic.rawValue
    @AppStorage("alacarte.username") private var username = ""
    @State private var password = ""
    @State private var client: ALACarteClient?
    @State private var items: [ALACarteLibraryItem] = []
    @State private var searchText = ""
    @State private var connecting = false
    @State private var errorMessage: String?
    @State private var selectedItemIDs: Set<String> = []
    @State private var showingWebInterface = false
    @State private var refreshingLibrary = false
    @State private var libraryTab = 0
    @State private var showingWriteProgress = false
    @State private var confirmingWrite = false

    private var selectedMode: ConnectionMode {
        ConnectionMode(rawValue: connectionMode) ?? .automatic
    }

    private var hasServerAddressForSelectedMode: Bool {
        switch selectedMode {
        case .automatic:
            !localServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !internetServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local:
            !localServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .internet:
            !internetServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var filteredItems: [ALACarteLibraryItem] {
        let kinds: [ALACarteLibraryItem.Kind?] = [nil, .album, .song, .playlist]
        let kind = kinds[libraryTab]
        return items.filter { item in
            (kind == nil || item.kind == kind) &&
            (searchText.isEmpty ||
            item.title.localizedCaseInsensitiveContains(searchText)
                || item.subtitle.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var selectedItems: [ALACarteLibraryItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectedTrackCount: Int { selectedItems.reduce(0) { $0 + $1.trackCount } }

    var body: some View {
        NavigationView {
            List {
                if client == nil {
                    Section {
                        Picker("Connection", selection: $connectionMode) {
                            ForEach(ConnectionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("http://server.local:7373", text: $localServerAddress)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("https://music.example.com", text: $internetServerAddress)
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
                        .disabled(connecting || !hasServerAddressForSelectedMode || username.isEmpty || password.isEmpty)
                    } header: {
                        Text("Your ALACarte server")
                    } footer: {
                        Text("Auto tries the local address first, then the internet address if the local server cannot be reached. The password is not saved; the signed-in session is stored in Keychain.")
                    }
                } else {
                    Section {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(client?.baseURL.host ?? "ALACarte")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button { showingWebInterface = true } label: {
                            Label("Open server", systemImage: "globe")
                        }
                        Button { refreshLibrary() } label: {
                            Label(refreshingLibrary ? "Refreshing…" : "Refresh downloaded music", systemImage: "arrow.clockwise")
                        }
                        .disabled(refreshingLibrary || model.isCopying)
                    } footer: {
                        Text("When you close the server, PodBridge refreshes this list automatically.")
                    }
                    Section {
                        Picker("Type", selection: $libraryTab) {
                            Text("All").tag(0); Text("Albums").tag(1); Text("Songs").tag(2); Text("Playlists").tag(3)
                        }
                        .pickerStyle(.segmented)
                        Text("\(items.count) available · \(selectedItemIDs.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(filteredItems) { item in
                            Button { toggle(item) } label: { libraryRow(item) }
                                .disabled(model.isCopying)
                        }
                    } header: {
                        Text("Downloaded music")
                    } footer: {
                        Text("Only music already downloaded on your server appears here.")
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
            .safeAreaInset(edge: .bottom) {
                if !selectedItemIDs.isEmpty, client != nil {
                    writeBar
                }
            }
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
        .task {
            migrateLegacyServerAddress()
            await restoreSavedSession()
        }
        .sheet(isPresented: $showingWebInterface) {
            if let client {
                ALACarteWebInterfaceView(
                    serverURL: client.baseURL,
                    sessionCookieHeader: client.webSessionCookieHeader,
                    didClose: { refreshLibrary() }
                )
            }
        }
        .fullScreenCover(isPresented: $showingWriteProgress) {
            ALACarteWriteProgressView(model: model) {
                showingWriteProgress = false
                selectedItemIDs.removeAll()
                refreshLibrary()
            }
        }
        .confirmationDialog(
            "Write music to iPod?",
            isPresented: $confirmingWrite,
            titleVisibility: .visible
        ) {
            Button("Write \(selectedTrackCount) tracks to iPod") {
                guard let client else { return }
                showingWriteProgress = true
                model.importFromALACarte(client: client, items: selectedItems)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedItemIDs.count) selected items · \(selectedTrackCount) tracks. PodBridge will back up the iPod library before writing.")
        }
    }

    private func connect() {
        connecting = true
        errorMessage = nil
        Task {
            do {
                let newClient = try await connectToFirstReachableServer()
                client = newClient.client
                items = newClient.items
                password = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            connecting = false
        }
    }

    private func toggle(_ item: ALACarteLibraryItem) {
        if selectedItemIDs.contains(item.id) { selectedItemIDs.remove(item.id) }
        else { selectedItemIDs.insert(item.id) }
    }

    private func libraryRow(_ item: ALACarteLibraryItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(item.kind))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).foregroundStyle(.primary).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selectedItemIDs.contains(item.id) ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, 4)
    }

    private var writeBar: some View {
        VStack(spacing: 8) {
            Button {
                confirmingWrite = true
            } label: {
                VStack(spacing: 2) {
                    Text("Write \(selectedItemIDs.count) selected to iPod")
                        .font(.headline)
                    Text("\(selectedTrackCount) tracks")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isCopying || model.destinationFolder == nil || model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID)
            if model.destinationFolder == nil || model.destinationDeviceProfile == nil {
                Text("Connect an iPod and choose its model before writing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func refreshLibrary() {
        guard let client, !refreshingLibrary, !model.isCopying else { return }
        refreshingLibrary = true
        errorMessage = nil
        Task {
            defer { refreshingLibrary = false }
            do {
                let refreshed = try await client.library()
                items = refreshed
                selectedItemIDs.formIntersection(Set(refreshed.map(\.id)))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func restoreSavedSession() async {
        guard client == nil, !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            let urls = try serverURLsForSelectedMode()
            for (index, url) in urls.enumerated() {
                do {
                    let savedClient = ALACarteClient(baseURL: url, requestTimeout: 10)
                    guard savedClient.hasSavedSession else { continue }
                    do {
                        let state = try await savedClient.authState()
                        guard state.authDisabled || state.authed else { continue }
                    } catch ALACarteError.endpointNotFound {
                        // Older servers validate the session when their library is requested.
                    }
                    try await savedClient.validateCompatibilityIfAvailable()
                    let savedItems = try await savedClient.library()
                    client = savedClient
                    items = savedItems
                    errorMessage = nil
                    return
                } catch {
                    guard selectedMode == .automatic,
                          index < urls.count - 1,
                          shouldTryNextServer(after: error) else { throw error }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // A temporary network failure is not a logout; keep the saved cookie.
            errorMessage = error.localizedDescription
        }
    }

    private func migrateLegacyServerAddress() {
        guard localServerAddress.isEmpty, !legacyServerAddress.isEmpty else { return }
        localServerAddress = legacyServerAddress
    }

    private func serverURLsForSelectedMode() throws -> [URL] {
        let rawAddresses: [String]
        switch selectedMode {
        case .automatic:
            rawAddresses = [localServerAddress, internetServerAddress]
        case .local:
            rawAddresses = [localServerAddress]
        case .internet:
            rawAddresses = [internetServerAddress]
        }
        let parsed = try rawAddresses
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(ALACarteServerAddress.parse)
        guard !parsed.isEmpty else { throw ALACarteError.invalidServerURL }
        return parsed.reduce(into: []) { result, url in
            if !result.contains(url) { result.append(url) }
        }
    }

    private func connectToFirstReachableServer() async throws -> (client: ALACarteClient, items: [ALACarteLibraryItem]) {
        let urls = try serverURLsForSelectedMode()
        var lastError: Error?
        for (index, url) in urls.enumerated() {
            do {
                let candidate = ALACarteClient(baseURL: url)
                try await candidate.login(username: username, password: password)
                try await candidate.validateCompatibilityIfAvailable()
                let candidateItems = try await candidate.library()
                return (candidate, candidateItems)
            } catch {
                lastError = error
                guard selectedMode == .automatic,
                      index < urls.count - 1,
                      shouldTryNextServer(after: error) else { throw error }
            }
        }
        throw lastError ?? ALACarteError.invalidServerURL
    }

    private func shouldTryNextServer(after error: Error) -> Bool {
        if case ALACarteError.endpointNotFound = error {
            return true
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
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

private struct ALACarteWriteProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let finished: () -> Void
    @State private var completion: TransferCompletion?

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer()
                if let completion {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(.green)
                    Text("Music Added").font(.largeTitle.bold())
                    Text("\(completion.addedTracks) songs added to \(completion.destinationName).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !completion.playlists.isEmpty {
                        Text(completion.playlists.map(\.name).joined(separator: " · "))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    Button("Done") {
                        finished()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                    Text("Adding Music").font(.title2.bold())
                    Text(status)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("\(model.copiedCount) tracks written to iPod")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Label("Keep PodBridge open and do not disconnect the iPod.", systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel", role: .destructive) { model.cancelCopy() }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(28)
            .navigationTitle("ALACarte")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(completion == nil && model.isCopying)
        .onChange(of: model.isCopying) { copying in
            guard !copying, let result = model.transferCompletion else { return }
            completion = result
        }
    }

    private var status: String {
        model.alacarteStatus ?? "Preparing transfer…"
    }

    private var progress: Double? {
        guard model.isCopying else { return nil }
        let words = status.split(separator: " ")
        guard let ofIndex = words.firstIndex(of: "of"),
              ofIndex > words.startIndex,
              ofIndex + 1 < words.endIndex,
              let current = Double(words[ofIndex - 1]),
              let total = Double(words[ofIndex + 1]), total > 0 else { return nil }
        return min(1, current / total)
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
