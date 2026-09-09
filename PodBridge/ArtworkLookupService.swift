// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import ImageIO

struct ArtworkLookupService: Sendable {
    struct Candidate: Identifiable, Sendable, Equatable {
        let id: String
        let data: Data
        let title: String
        let artist: String
    }

    struct Match: Sendable {
        let data: Data
        let releaseGroupID: String
        let matchedAlbum: String
        let matchedArtist: String
    }

    private struct SearchResponse: Decodable {
        let releaseGroups: [ReleaseGroup]

        enum CodingKeys: String, CodingKey {
            case releaseGroups = "release-groups"
        }
    }

    private struct ReleaseGroup: Decodable {
        let id: String
        let score: Int
        let title: String
        let artistCredit: [ArtistCredit]

        enum CodingKeys: String, CodingKey {
            case id, score, title
            case artistCredit = "artist-credit"
        }
    }

    private struct ArtistCredit: Decodable {
        let name: String
    }

    private struct CoverResponse: Decodable {
        let images: [CoverImage]
    }

    private struct RecordingSearchResponse: Decodable {
        let recordings: [Recording]
    }

    private struct Recording: Decodable {
        let score: Int
        let title: String
        let artistCredit: [ArtistCredit]
        let releases: [RecordingRelease]

        enum CodingKeys: String, CodingKey {
            case score, title, releases
            case artistCredit = "artist-credit"
        }
    }

    private struct RecordingRelease: Decodable {
        let title: String
        let status: String?
        let date: String?
        let releaseGroup: ReleaseGroupReference?

        enum CodingKeys: String, CodingKey {
            case title, status, date
            case releaseGroup = "release-group"
        }
    }

    private struct ReleaseGroupReference: Decodable {
        let id: String
        let primaryType: String?
        let secondaryTypes: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case primaryType = "primary-type"
            case secondaryTypes = "secondary-types"
        }
    }

    private struct CoverImage: Decodable {
        let image: String
        let thumbnails: [String: String]
        let front: Bool
        let approved: Bool
    }

    private static let rateLimiter = MusicBrainzRateLimiter()
    private let session: URLSession
    private let observesRateLimit: Bool

    init(session: URLSession = .shared, observesRateLimit: Bool = true) {
        self.session = session
        self.observesRateLimit = observesRateLimit
    }

    func cover(album: String, artist: String) async throws -> Match? {
        guard let candidate = try await albumCandidates(album: album, artist: artist, limit: 1).first else {
            return nil
        }
        return Match(
            data: candidate.data,
            releaseGroupID: candidate.id,
            matchedAlbum: candidate.title,
            matchedArtist: candidate.artist
        )
    }

    func albumCandidates(album: String, artist: String, limit: Int = 8) async throws -> [Candidate] {
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !album.isEmpty, !artist.isEmpty, limit > 0 else { return [] }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "releasegroup:\(luceneQuoted(album)) AND artist:\(luceneQuoted(artist))"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "8")
        ]
        guard let searchURL = components.url else { return [] }
        if observesRateLimit { try await Self.rateLimiter.waitForTurn() }
        let searchData = try await request(searchURL, acceptedStatuses: [200])
        let response = try JSONDecoder().decode(SearchResponse.self, from: searchData)
        var candidates: [Candidate] = []
        for release in response.releaseGroups where release.score >= 70 {
            try Task.checkCancellation()
            guard normalized(release.title) == normalized(album),
                  artistMatches(artist, credits: release.artistCredit),
                  let imageData = try await coverData(releaseGroupID: release.id) else { continue }
            candidates.append(Candidate(
                id: release.id,
                data: imageData,
                title: release.title,
                artist: release.artistCredit.map(\.name).joined(separator: ", ")
            ))
            if candidates.count == limit { break }
        }
        return candidates
    }

    func cover(track: String, artist: String) async throws -> Match? {
        guard let candidate = try await trackCandidates(track: track, artist: artist, limit: 1).first else {
            return nil
        }
        return Match(
            data: candidate.data,
            releaseGroupID: candidate.id,
            matchedAlbum: candidate.title,
            matchedArtist: candidate.artist
        )
    }

    func trackCandidates(track: String, artist: String, limit: Int = 8) async throws -> [Candidate] {
        let track = track.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !track.isEmpty, !artist.isEmpty, limit > 0 else { return [] }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "recording:\(luceneQuoted(track)) AND artist:\(luceneQuoted(artist))"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let searchURL = components.url else { return [] }
        if observesRateLimit { try await Self.rateLimiter.waitForTurn() }
        let searchData = try await request(searchURL, acceptedStatuses: [200])
        let response = try JSONDecoder().decode(RecordingSearchResponse.self, from: searchData)
        guard let recording = response.recordings.first(where: { candidate in
            candidate.score >= 95
                && normalized(candidate.title) == normalized(track)
                && artistMatches(artist, credits: candidate.artistCredit)
        }) else { return [] }

        let disallowedTypes = Set(["compilation", "dj-mix", "live", "remix"])
        var seen = Set<String>()
        let releases = recording.releases.filter { release in
            guard release.status == nil || release.status?.caseInsensitiveCompare("Official") == .orderedSame,
                  let group = release.releaseGroup,
                  seen.insert(group.id).inserted else { return false }
            let secondary = Set((group.secondaryTypes ?? []).map { $0.lowercased() })
            return secondary.isDisjoint(with: disallowedTypes)
        }.sorted { lhs, rhs in
            let lhsSingle = lhs.releaseGroup?.primaryType?.caseInsensitiveCompare("Single") == .orderedSame
            let rhsSingle = rhs.releaseGroup?.primaryType?.caseInsensitiveCompare("Single") == .orderedSame
            if lhsSingle != rhsSingle { return lhsSingle }
            return (lhs.date ?? "9999") < (rhs.date ?? "9999")
        }
        var candidates: [Candidate] = []
        for release in releases {
            try Task.checkCancellation()
            guard let group = release.releaseGroup,
                  let imageData = try await coverData(releaseGroupID: group.id) else { continue }
            candidates.append(Candidate(
                id: group.id,
                data: imageData,
                title: release.title,
                artist: recording.artistCredit.map(\.name).joined(separator: ", ")
            ))
            if candidates.count == limit { break }
        }
        return candidates
    }

    private func coverData(releaseGroupID: String) async throws -> Data? {
        let metadataURL = URL(string: "https://coverartarchive.org/release-group/\(releaseGroupID)")!
        guard let metadata = try await optionalRequest(metadataURL) else { return nil }
        let covers = try JSONDecoder().decode(CoverResponse.self, from: metadata)
        for front in covers.images where front.front && front.approved {
            for imageURL in preferredImageURLs(front) {
                do {
                    let imageData = try await request(imageURL, acceptedStatuses: [200])
                    guard !imageData.isEmpty,
                          imageData.count <= 15_000_000,
                          CGImageSourceCreateWithData(imageData as CFData, nil) != nil else { continue }
                    return imageData
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Cover Art Archive occasionally returns an obsolete HTTP thumbnail or
                    // a missing rendition. Try the next HTTPS rendition/front image.
                    continue
                }
            }
        }
        return nil
    }

    private func optionalRequest(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private func request(_ url: URL, acceptedStatuses: Set<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              acceptedStatuses.contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    private var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return "PodBridge/\(version) (org.podbridge.app)"
    }

    private func preferredImageURLs(_ image: CoverImage) -> [URL] {
        var urls: [URL] = []
        for key in ["500", "1200", "large"] {
            if let value = image.thumbnails[key], let url = secureURL(value), !urls.contains(url) { urls.append(url) }
        }
        if let url = secureURL(image.image), !urls.contains(url) { urls.append(url) }
        return urls
    }

    private func secureURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        return components.url
    }

    private func artistMatches(_ requested: String, credits: [ArtistCredit]) -> Bool {
        let wanted = normalized(requested)
        let creditNames = credits.map { normalized($0.name) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty, !creditNames.isEmpty else { return false }
        if creditNames.contains(wanted) || creditNames.joined() == wanted { return true }
        let separators = CharacterSet(charactersIn: "&,;/+")
        let primary = requested.components(separatedBy: separators).first.map(normalized) ?? wanted
        return creditNames.contains(primary)
            || (primary.count >= 4 && creditNames.contains { $0.hasPrefix(primary) || primary.hasPrefix($0) })
    }

    private func luceneQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

private actor MusicBrainzRateLimiter {
    private var nextAllowed = Date.distantPast

    func waitForTurn() async throws {
        let delay = nextAllowed.timeIntervalSinceNow
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        nextAllowed = Date().addingTimeInterval(1.1)
    }
}
