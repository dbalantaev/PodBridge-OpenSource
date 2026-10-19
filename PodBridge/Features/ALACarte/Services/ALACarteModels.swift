// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import Security

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

struct ALACarteAuthState: Sendable {
    let authDisabled: Bool
    let passwordSet: Bool
    let authed: Bool
}

enum ALACarteSessionKeychain {
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
            kSecAttrAccount as String: server.absoluteString
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
