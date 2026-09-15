// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import XCTest
@testable import PodBridge

final class ALACarteClientTests: XCTestCase {
    override func tearDown() {
        ALACarteURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testServerAddressAcceptsHTTPAndNormalizesTrailingSlash() throws {
        let url = try ALACarteServerAddress.parse("  http://mac.local:7373/  ")
        XCTAssertEqual(url.absoluteString, "http://mac.local:7373")
    }

    func testServerAddressRejectsCredentialsAndUnsupportedSchemes() {
        XCTAssertThrowsError(try ALACarteServerAddress.parse("ftp://mac.local:7373"))
        XCTAssertThrowsError(try ALACarteServerAddress.parse("http://user:password@mac.local:7373"))
        XCTAssertThrowsError(try ALACarteServerAddress.parse("mac.local:7373"))
    }

    func testLoginCompatibilityAndLibraryUseConfiguredServer() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/auth/login":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://mac.local:7373")
                return Self.response(
                    request,
                    headers: ["Set-Cookie": "alacarte_session=test-session; Path=/; HttpOnly"],
                    json: #"{"ok":true}"#
                )
            case "/api/podbridge/version":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "alacarte_session=test-session")
                return Self.response(request, json: #"{"apiVersion":1,"audioExtensions":["m4a","mp3"]}"#)
            case "/api/library":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "alacarte_session=test-session")
                return Self.response(
                    request,
                    json: #"{"albums":[{"id":"album-1","artistName":"Artist","albumName":"Album","relPath":"Artist/Album","trackCount":2}],"singles":[],"playlists":[]}"#
                )
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(request, statusCode: 404, json: #"{"error":"not found"}"#)
            }
        }

        try await client.login(username: "listener", password: "secret")
        try await client.validateCompatibility()
        let items = try await client.library()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Album")
        XCTAssertEqual(items.first?.relativePath, "Artist/Album")
    }

    func testFLACOnlyExportReturnsActionableCompatibilityError() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/auth/login":
                return Self.response(
                    request,
                    headers: ["Set-Cookie": "alacarte_session=test-session; Path=/; HttpOnly"],
                    json: #"{"ok":true}"#
                )
            case "/api/podbridge/export":
                return Self.response(
                    request,
                    json: #"{"name":"Album","files":[{"path":"Artist/Album/track.flac","byteCount":1234}]}"#
                )
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(request, statusCode: 404, json: #"{"error":"not found"}"#)
            }
        }
        try await client.login(username: "listener", password: "secret")
        let item = ALACarteLibraryItem(
            id: "album:album-1",
            kind: .album,
            title: "Album",
            subtitle: "Artist",
            relativePath: "Artist/Album",
            trackCount: 1
        )

        do {
            _ = try await client.download(item) { _, _ in }
            XCTFail("Expected the FLAC-only export to be rejected")
        } catch ALACarteError.noCompatibleAudio {
            XCTAssertEqual(
                ALACarteError.noCompatibleAudio.localizedDescription,
                "No iPod-compatible audio was returned. Set ALACarte Library output to ALAC instead of FLAC."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> ALACarteClient {
        ALACarteURLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ALACarteURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return ALACarteClient(
            baseURL: URL(string: "http://mac.local:7373")!,
            session: session,
            loadSavedSession: false
        )
    }

    private static func response(
        _ request: URLRequest,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(json.utf8))
    }
}

private final class ALACarteURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
