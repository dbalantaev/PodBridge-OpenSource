// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

private struct ALACarteLoginResponse: Decodable {
    let accepted: Bool

    enum CodingKeys: String, CodingKey {
        case accepted = "ok"
    }
}

private struct ALACarteAuthStateResponse: Decodable {
    let authDisabled: Bool
    let passwordSet: Bool
    let authed: Bool
}

private struct ALACarteVersionResponse: Decodable {
    let apiVersion: Int
    let audioExtensions: [String]
}

private struct ALACarteLibraryResponse: Decodable {
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

private struct ALACarteExportManifest: Decodable {
    struct File: Decodable {
        let path: String
        let byteCount: Int64
    }

    let name: String
    let files: [File]
}

/// Thread-safe client for the ALACarte HTTP API.
///
/// `URLSession` supports concurrent requests. The only mutable client state is
/// the current session cookie, which is protected by `sessionCookieLock`.
final class ALACarteClient: @unchecked Sendable {
    let baseURL: URL
    private let session: URLSession
    private let sessionCookieLock = NSLock()
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

    var hasSavedSession: Bool { storedSessionCookie != nil }
    var webSessionCookieHeader: String? { storedSessionCookie }

    func authState() async throws -> ALACarteAuthState {
        let data = try await responseData(for: URLRequest(url: endpoint("api/auth/state")))
        let state = try JSONDecoder().decode(ALACarteAuthStateResponse.self, from: data)
        return ALACarteAuthState(
            authDisabled: state.authDisabled,
            passwordSet: state.passwordSet,
            authed: state.authed
        )
    }

    func forgetSavedSession() {
        storeSessionCookie(nil)
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
        guard try JSONDecoder().decode(ALACarteLoginResponse.self, from: data).accepted else {
            throw ALACarteError.server("ALACarte rejected the sign-in request.")
        }
        guard captureSessionCookie(from: response) || captureSessionCookieFromStorage() else {
            throw ALACarteError.server("Signed in, but ALACarte did not provide a session cookie.")
        }
    }

    func validateCompatibility() async throws {
        let data = try await responseData(for: URLRequest(url: endpoint("api/podbridge/version")))
        let response = try JSONDecoder().decode(ALACarteVersionResponse.self, from: data)
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
        let response = try JSONDecoder().decode(ALACarteLibraryResponse.self, from: data)
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
}

extension ALACarteClient {
    private var storedSessionCookie: String? {
        sessionCookieLock.lock()
        defer { sessionCookieLock.unlock() }
        return sessionCookieHeader
    }

    private func storeSessionCookie(_ value: String?) {
        sessionCookieLock.lock()
        sessionCookieHeader = value
        sessionCookieLock.unlock()
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
        let manifest = try JSONDecoder().decode(ALACarteExportManifest.self, from: manifestData)
        guard !manifest.files.isEmpty, manifest.files.count <= 20_000 else {
            throw PodBridgeError.noMusicFiles
        }
        let audioExtensions = MusicTransferEngine.supportedExtensions
        guard manifest.files.contains(where: {
            audioExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
        }) else {
            throw ALACarteError.noCompatibleAudio
        }
        guard manifest.files.allSatisfy({ $0.byteCount >= 0 && $0.byteCount <= Int64(Int.max) }) else {
            throw ALACarteError.server("The server returned an invalid file size.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodBridge-ALACarte-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try await downloadExportFiles(
                manifest.files,
                to: root,
                supportedAudioExtensions: audioExtensions,
                progress: progress
            )
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func downloadExportFiles(
        _ files: [ALACarteExportManifest.File],
        to root: URL,
        supportedAudioExtensions: Set<String>,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void
    ) async throws {
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let relative = try safeRelativePath(file.path)
            let fileExtension = URL(fileURLWithPath: relative).pathExtension.lowercased()
            guard supportedAudioExtensions.contains(fileExtension)
                    || fileExtension == "m3u"
                    || fileExtension == "m3u8" else {
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
            await progress(index + 1, files.count)
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
        if let sessionCookieHeader = storedSessionCookie {
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
        storeSessionCookie(pair)
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
        storeSessionCookie(pair)
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
