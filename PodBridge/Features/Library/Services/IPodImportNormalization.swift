// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import AVFoundation
import CryptoKit
import Foundation

extension IPodSyncEngine {
    struct AlbumArtistNormalizationPlan: Sendable {
        let album: String
        let artist: String
        let indices: [Int]
        let compilation: Bool?

        init(
            album: String,
            artist: String,
            indices: [Int],
            compilation: Bool? = nil
        ) {
            self.album = album
            self.artist = artist
            self.indices = indices
            self.compilation = compilation
        }
    }

    struct AlbumArtistEditPlan: Sendable {
        let album: String
        let artist: String
        let compilation: Bool?
        let trackIDs: [UInt32]
    }

    private struct AlbumCandidate {
        let indices: [Int]
        let canonicalTitle: String
        let artistKeys: Set<String>
        let releaseIDs: Set<String>
        let trackDurationsByTitle: [String: [UInt32]]
        let compilation: Bool
        let likelySingle: Bool
    }

    static func preparedTracksForImport(
        incoming: [ClassicTrack],
        existing: [ClassicTrack],
        playlists: [SourcePlaylist]
    ) -> [ClassicTrack] {
        // Import must be non-destructive: retain the metadata embedded in each
        // source file and leave existing iPod records untouched. Users can make
        // intentional metadata and artwork changes in the library editor.
        _ = existing
        _ = playlists
        return incoming
    }

    static func importedAlbumNamesByFileIndex(
        fileCount: Int,
        playlists: [SourcePlaylist]
    ) -> [Int: String] {
        var names: [Int: String] = [:]
        for playlist in playlists {
            let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for index in playlist.fileIndices where index >= 0 && index < fileCount {
                // One database track can belong to several playlists but only one album.
                // The source playlist order makes the first imported collection canonical.
                if names[index] == nil { names[index] = name }
            }
        }
        return names
    }

    private static func compilationTrack(_ source: ClassicTrack, albumName: String) -> ClassicTrack {
        var track = source
        track.album = albumName
        track.albumArtist = "Various Artists"
        track.compilation = true
        track.sourceAlbumID = ""
        let albumSort = articleIndependentSortValue(albumName)
        track.sortAlbum = albumSort == albumName ? "" : albumSort
        track.sortAlbumArtist = ""
        return track
    }

    static func tracksByReadingEmbeddedAlbumIdentity(
        _ tracks: [ClassicTrack],
        root: URL,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) async -> Void
    ) async -> [ClassicTrack] {
        var result = tracks
        let batchSize = 12
        var identified = 0
        for start in stride(from: 0, to: tracks.count, by: batchSize) {
            let end = min(start + batchSize, tracks.count)
            let values = await withTaskGroup(
                of: (Int, AudioMetadataReader.AlbumIdentity).self,
                returning: [(Int, AudioMetadataReader.AlbumIdentity)].self
            ) { group in
                for index in start..<end {
                    guard let url = trackURL(path: tracks[index].ipodPath, root: root) else { continue }
                    group.addTask {
                        (index, await AudioMetadataReader.albumIdentity(at: url))
                    }
                }
                var output: [(Int, AudioMetadataReader.AlbumIdentity)] = []
                for await value in group { output.append(value) }
                return output
            }
            for (index, identity) in values {
                if !identity.albumArtist.isEmpty {
                    result[index].albumArtist = identity.albumArtist
                }
                if !identity.releaseID.isEmpty {
                    result[index].sourceAlbumID = identity.releaseID
                    identified += 1
                }
            }
            await progress(end, tracks.count)
        }
        AppLogger.database(
            "Embedded album identity scan tracks=\(tracks.count) releaseIDs=\(identified)",
            level: .info
        )
        return result
    }

    static func normalizedAlbumArtistsForImport(
        incoming: [ClassicTrack],
        existing: [ClassicTrack]
    ) -> [ClassicTrack] {
        guard !incoming.isEmpty else { return incoming }
        let existingCount = existing.count
        let combined = existing + incoming
        let plans = albumArtistNormalizationPlans(combined)
        var normalized = incoming
        var changed = 0
        for plan in plans {
            for combinedIndex in plan.indices where combinedIndex >= existingCount {
                let incomingIndex = combinedIndex - existingCount
                guard normalized.indices.contains(incomingIndex) else { continue }
                var track = normalized[incomingIndex]
                guard track.albumArtist != plan.artist else { continue }
                track.albumArtist = plan.artist
                let artistSort = articleIndependentSortValue(plan.artist)
                track.sortAlbumArtist = artistSort == plan.artist ? "" : artistSort
                normalized[incomingIndex] = track
                changed += 1
            }
        }
        if changed > 0 {
            AppLogger.database(
                "Incoming album artists normalized albums=\(plans.count) tracks=\(changed)",
                level: .info
            )
        }
        return normalized
    }

    static func albumArtistNormalizationPlans(
        _ tracks: [ClassicTrack],
        playlists: [ClassicPlaylist] = []
    ) -> [AlbumArtistNormalizationPlan] {
        let playlistPlans = importedPlaylistNormalizationPlans(tracks: tracks, playlists: playlists)
        let claimedPlaylistIndices = Set(playlistPlans.flatMap(\.indices))
        let eligibleIndices = tracks.indices.filter { !claimedPlaylistIndices.contains($0) }
        var plans = playlistPlans
        let albumGroups = consolidatedAlbumCandidateGroups(tracks, indices: eligibleIndices)
        for albumIndices in albumGroups {
            guard let firstIndex = albumIndices.first,
                  !canonicalAlbumKey(tracks[firstIndex].album).isEmpty else { continue }

            let compilationIndices = albumIndices.filter { index in
                tracks[index].compilation && isVariousArtists(tracks[index].albumArtist)
            }
            if let compilationPlan = albumConsolidationPlan(
                tracks: tracks,
                indices: compilationIndices,
                artist: "Various Artists"
            ) {
                plans.append(compilationPlan)
            }
            let artistAlbumIndices = albumIndices.filter { !compilationIndices.contains($0) }
            guard !artistAlbumIndices.isEmpty else { continue }

            let reliableArtistGroups = Dictionary(grouping: artistAlbumIndices.filter { index in
                let artist = tracks[index].albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                return !artist.isEmpty && !isVariousArtists(artist)
            }) { index in
                normalizedArtistCredit(tracks[index].albumArtist)
            }
            var assigned = Set<Int>()
            for indices in reliableArtistGroups.values {
                let artist = preferredAlbumArtist(tracks: tracks, indices: indices)
                let related = artistAlbumIndices.filter { index in
                    guard !assigned.contains(index) else { return false }
                    let albumArtist = tracks[index].albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !albumArtist.isEmpty && !isVariousArtists(albumArtist) {
                        return normalizedArtistCredit(albumArtist) == normalizedArtistCredit(artist)
                    }
                    return creditContainsArtist(
                        normalizedArtistCredit(tracks[index].artist),
                        artist: normalizedArtistCredit(artist)
                    )
                }
                guard !related.isEmpty else { continue }
                assigned.formUnion(related)
                if let plan = albumConsolidationPlan(tracks: tracks, indices: related, artist: artist) {
                    plans.append(plan)
                }
            }
            let remaining = artistAlbumIndices.filter { !assigned.contains($0) }
            if !remaining.isEmpty {
                plans.append(contentsOf: albumArtistNormalizationPlans(
                    tracks: tracks,
                    indices: remaining
                ))
            }
        }
        return plans.sorted {
            let albumOrder = $0.album.localizedStandardCompare($1.album)
            return albumOrder == .orderedSame
                ? $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
                : albumOrder == .orderedAscending
        }
    }

    private static func importedPlaylistNormalizationPlans(
        tracks: [ClassicTrack],
        playlists: [ClassicPlaylist]
    ) -> [AlbumArtistNormalizationPlan] {
        guard !tracks.isEmpty, !playlists.isEmpty else { return [] }
        let indexByID = Dictionary(uniqueKeysWithValues: tracks.indices.map { (tracks[$0].id, $0) })
        var claimed = Set<Int>()
        var plans: [AlbumArtistNormalizationPlan] = []

        for playlist in playlists {
            let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let memberIndices = playlist.trackIDs.compactMap { indexByID[$0] }
            let anchors = memberIndices.filter { index in
                let track = tracks[index]
                return track.compilation
                    && isVariousArtists(track.albumArtist)
                    && track.album.caseInsensitiveCompare(name) == .orderedSame
            }
            guard !anchors.isEmpty else { continue }

            let anchorDates = anchors.map { tracks[$0].dateAdded }.filter { $0 != 0 }
            let earliest = anchorDates.min()
            let latest = anchorDates.max()
            let ownedIndices = memberIndices.filter { index in
                guard !claimed.contains(index) else { return false }
                if anchors.contains(index) { return true }
                let track = tracks[index]
                guard isPodBridgeAudioPath(track.ipodPath),
                      let earliest, let latest, track.dateAdded != 0 else { return false }
                // Metadata for one sync is read as a batch before copying. A narrow
                // cohort around the known compilation members separates those copies
                // from older PodBridge imports that a user later reused in a playlist.
                let tolerance: UInt32 = 10 * 60
                let lowerBound = earliest > tolerance ? earliest - tolerance : 0
                let upperBound = latest > UInt32.max - tolerance ? UInt32.max : latest + tolerance
                return (lowerBound...upperBound).contains(track.dateAdded)
            }
            guard !ownedIndices.isEmpty else { continue }

            let albumIDs = Set(ownedIndices.map { tracks[$0].albumID })
            let needsChange = albumIDs.count > 1 || ownedIndices.contains { index in
                let track = tracks[index]
                return track.album.caseInsensitiveCompare(name) != .orderedSame
                    || !isVariousArtists(track.albumArtist)
                    || !track.compilation
            }
            guard needsChange else { continue }
            claimed.formUnion(ownedIndices)
            plans.append(AlbumArtistNormalizationPlan(
                album: name,
                artist: "Various Artists",
                indices: ownedIndices.sorted(),
                compilation: true
            ))
        }
        return plans
    }

    private static func isPodBridgeAudioPath(_ path: String) -> Bool {
        guard let filename = path.split(separator: ":").last else { return false }
        return filename.uppercased().hasPrefix("PB")
    }

    private static func consolidatedAlbumCandidateGroups(
        _ tracks: [ClassicTrack],
        indices: [Int]
    ) -> [[Int]] {
        let grouped = Dictionary(grouping: indices) { index -> String in
            let track = tracks[index]
            if track.albumID != 0 { return "id:\(track.albumID)" }
            return "metadata:\(canonicalAlbumKey(track.album)):\(normalizedMetadata(track.album))"
        }.values.map { $0.sorted() }
        let candidates = grouped.map { indices -> AlbumCandidate in
            let representative = tracks[indices[0]]
            let reliableAlbumArtists = Set(indices.compactMap { index -> String? in
                let value = tracks[index].albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !isVariousArtists(value) else { return nil }
                return normalizedArtistCredit(value)
            })
            let artistKeys = reliableAlbumArtists.isEmpty
                ? Set(indices.map { normalizedArtistCredit(tracks[$0].artist) }.filter { !$0.isEmpty })
                : reliableAlbumArtists
            let releaseIDs = Set(indices.map { normalizedReleaseID(tracks[$0].sourceAlbumID) }.filter { !$0.isEmpty })
            var trackDurationsByTitle: [String: [UInt32]] = [:]
            for index in indices {
                let title = trackTitleFingerprint(tracks[index])
                if !title.isEmpty {
                    trackDurationsByTitle[title, default: []].append(tracks[index].durationMS)
                }
            }
            let albumTitle = canonicalAlbumKey(representative.album)
            let likelySingle = indices.count == 1
                && normalizedMetadata(representative.title) == albumTitle
            return AlbumCandidate(
                indices: indices,
                canonicalTitle: albumTitle,
                artistKeys: artistKeys,
                releaseIDs: releaseIDs,
                trackDurationsByTitle: trackDurationsByTitle,
                compilation: indices.allSatisfy {
                    tracks[$0].compilation && isVariousArtists(tracks[$0].albumArtist)
                },
                likelySingle: likelySingle
            )
        }
        var parent = Array(candidates.indices)
        func root(_ value: Int) -> Int {
            var current = value
            while parent[current] != current { current = parent[current] }
            return current
        }
        func shouldMerge(_ lhs: AlbumCandidate, _ rhs: AlbumCandidate) -> Bool {
            guard lhs.compilation == rhs.compilation,
                  albumCandidateArtistsAreCompatible(lhs.artistKeys, rhs.artistKeys) else { return false }
            let sameReleaseID = !lhs.releaseIDs.isDisjoint(with: rhs.releaseIDs)
            if sameReleaseID { return true }
            guard !lhs.likelySingle, !rhs.likelySingle else { return false }
            if !lhs.canonicalTitle.isEmpty, lhs.canonicalTitle == rhs.canonicalTitle { return true }
            return trackListsStronglyOverlap(lhs.trackDurationsByTitle, rhs.trackDurationsByTitle)
        }
        if candidates.count > 1 {
            for left in 0..<(candidates.count - 1) {
                for right in (left + 1)..<candidates.count where shouldMerge(candidates[left], candidates[right]) {
                    let leftRoot = root(left)
                    let rightRoot = root(right)
                    if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
                }
            }
        }
        return Dictionary(grouping: candidates.indices, by: root).values.map { candidateIndices in
            candidateIndices.flatMap { candidates[$0].indices }.sorted()
        }
    }

    private static func albumCandidateArtistsAreCompatible(
        _ lhs: Set<String>,
        _ rhs: Set<String>
    ) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.contains { left in
            rhs.contains { right in artistCreditsAreRelated(left, right) }
        }
    }

    private static func trackListsStronglyOverlap(
        _ lhs: [String: [UInt32]],
        _ rhs: [String: [UInt32]]
    ) -> Bool {
        guard lhs.count >= 2, rhs.count >= 2 else { return false }
        let overlap = Set(lhs.keys).intersection(rhs.keys).filter { title in
            guard let leftDurations = lhs[title], let rightDurations = rhs[title] else { return false }
            return leftDurations.contains { left in
                rightDurations.contains { right in
                    left == 0 || right == 0
                        || (left > right ? left - right : right - left) <= 2_500
                }
            }
        }.count
        let smallerCoverage = Double(overlap) / Double(min(lhs.count, rhs.count))
        let largerCoverage = Double(overlap) / Double(max(lhs.count, rhs.count))
        return overlap >= 2 && smallerCoverage >= 0.8 && largerCoverage >= 0.6
    }

    private static func trackTitleFingerprint(_ track: ClassicTrack) -> String {
        var title = track.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        title = title.replacingOccurrences(
            of: "(?i)[\\(\\[][^\\)\\]]*(feat(?:uring)?|ft\\.?|remaster(?:ed)?|version|edit)[^\\)\\]]*[\\)\\]]",
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(of: "&", with: " and ")
        let normalized = normalizedMetadata(title)
        guard !normalized.isEmpty else { return "" }
        return normalized
    }

    static func albumArtistNormalizationPlans(
        tracks: [ClassicTrack],
        indices: [Int]
    ) -> [AlbumArtistNormalizationPlan] {
        guard !indices.isEmpty else { return [] }
        let artistGroups = Dictionary(grouping: indices) { index in
            normalizedArtistCredit(tracks[index].artist)
        }.filter { key, _ in
            !key.isEmpty && key != "unknown artist"
        }
        let artistKeys = artistGroups.keys.sorted()
        if artistKeys.count == 1, let only = artistKeys.first,
           let representativeIndex = artistGroups[only]?.first,
           let plan = albumConsolidationPlan(
               tracks: tracks,
               indices: indices,
               artist: tracks[representativeIndex].albumArtist.isEmpty
                   ? tracks[representativeIndex].artist
                   : tracks[representativeIndex].albumArtist
           ) {
            return [plan]
        }
        guard artistKeys.count > 1 else { return [] }

        let albumArtists = Set(indices.compactMap { index -> String? in
            let value = tracks[index].albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !tracks[index].compilation,
                  !isVariousArtists(value) else { return nil }
            return value
        })
        if albumArtists.count == 1, let albumArtist = albumArtists.first {
            let normalizedAlbumArtist = normalizedArtistCredit(albumArtist)
            if artistKeys.allSatisfy({ creditContainsArtist($0, artist: normalizedAlbumArtist) }) {
                return albumConsolidationPlan(tracks: tracks, indices: indices, artist: albumArtist).map { [$0] } ?? []
            }
        }

        var plans: [AlbumArtistNormalizationPlan] = []
        var remaining = Set(artistKeys)
        while let seed = remaining.sorted().first {
            var component: Set<String> = [seed]
            var frontier = [seed]
            while let current = frontier.popLast() {
                for candidate in remaining where !component.contains(candidate) {
                    if artistCreditsAreRelated(current, candidate) {
                        component.insert(candidate)
                        frontier.append(candidate)
                    }
                }
            }
            remaining.subtract(component)
            guard component.count > 1 else { continue }
            let possibleBases = component.filter { candidate in
                component.allSatisfy { creditContainsArtist($0, artist: candidate) }
            }
            guard let baseKey = possibleBases.sorted(by: {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0 < $1
            }).first,
            let representativeIndex = artistGroups[baseKey]?.first else { continue }
            let componentIndices = component.flatMap { artistGroups[$0] ?? [] }.sorted()
            let artist = tracks[representativeIndex].albumArtist.isEmpty
                ? tracks[representativeIndex].artist
                : tracks[representativeIndex].albumArtist
            if let plan = albumConsolidationPlan(tracks: tracks, indices: componentIndices, artist: artist) {
                plans.append(plan)
            }
        }
        return plans
    }

    private static func albumConsolidationPlan(
        tracks: [ClassicTrack],
        indices: [Int],
        artist: String
    ) -> AlbumArtistNormalizationPlan? {
        guard !indices.isEmpty else { return nil }
        let album = preferredEditionName(tracks: tracks, indices: indices)
        let normalizedArtist = normalizedArtistCredit(artist)
        let albumIDs = Set(indices.map { tracks[$0].albumID })
        let needsChange = indices.contains { index in
            let groupingArtist = tracks[index].albumArtist.isEmpty
                ? tracks[index].artist
                : tracks[index].albumArtist
            return tracks[index].album != album
                || normalizedArtistCredit(groupingArtist) != normalizedArtist
        } || albumIDs.count > 1
        guard needsChange else { return nil }
        return AlbumArtistNormalizationPlan(
            album: album,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            indices: indices.sorted()
        )
    }

    private static func preferredAlbumArtist(tracks: [ClassicTrack], indices: [Int]) -> String {
        let values = indices.map { tracks[$0].albumArtist.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isVariousArtists($0) }
        let counts = Dictionary(grouping: values, by: normalizedArtistCredit)
        return counts.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0[0].localizedStandardCompare($1[0]) == .orderedAscending
        }.first?.first ?? "Various Artists"
    }

    private static func preferredEditionName(tracks: [ClassicTrack], indices: [Int]) -> String {
        let names = Dictionary(grouping: indices.map { tracks[$0].album }, by: { $0 })
        return names.keys.sorted { lhs, rhs in
            let leftRank = editionRank(lhs)
            let rightRank = editionRank(rhs)
            let leftCount = names[lhs]?.count ?? 0
            let rightCount = names[rhs]?.count ?? 0
            if (leftRank > 0) != (rightRank > 0) { return leftRank > 0 }
            if leftCount != rightCount { return leftCount > rightCount }
            if leftRank != rightRank { return leftRank > rightRank }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }.first ?? tracks[indices[0]].album
    }

    private static func canonicalAlbumKey(_ value: String) -> String {
        let marker = "deluxe|expanded|extended|anniversary|special|bonus|complete|collector|remaster|delux|расширенн|делюкс|юбилейн|переиздан|edici[oó]n de lujo|[eé]dition deluxe|edizione deluxe|デラックス|リマスター"
        var folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        folded = folded.replacingOccurrences(of: "&", with: " and ")
        folded = folded.replacingOccurrences(
            of: "(?i)[\\(\\[][^\\)\\]]*(\(marker))[^\\)\\]]*[\\)\\]]",
            with: " ",
            options: .regularExpression
        )
        folded = folded.replacingOccurrences(
            of: "(?i)\\b(deluxe|expanded|extended|anniversary|special|bonus|complete|collector'?s?|remaster(?:ed)?|edition|version|delux|расширенное|расширенная|делюкс|юбилейное|переиздание)\\b|edici[oó]n de lujo|[eé]dition deluxe|edizione deluxe|デラックス|リマスター",
            with: " ",
            options: .regularExpression
        )
        folded = folded.replacingOccurrences(
            of: "(?i)\\b(?:cd|disc|disk|диск)\\s*[0-9ivx]+\\b",
            with: " ",
            options: .regularExpression
        )
        folded = folded.replacingOccurrences(
            of: "(?i)\\b[0-9]+(?:st|nd|rd|th)\\b",
            with: " ",
            options: .regularExpression
        )
        return normalizedMetadata(folded)
    }

    private static func editionRank(_ value: String) -> Int {
        let normalized = normalizedMetadata(value)
        if normalized.contains("deluxe") || normalized.contains("delux")
            || normalized.contains("делюкс") || normalized.contains("デラックス") { return 6 }
        if normalized.contains("expanded") || normalized.contains("extended") { return 5 }
        if normalized.contains("anniversary") || normalized.contains("completeedition") { return 4 }
        if normalized.contains("specialedition") || normalized.contains("collectorsedition") { return 3 }
        if normalized.contains("bonus") { return 2 }
        if normalized.contains("remaster") { return 1 }
        return 0
    }

    private static func normalizedReleaseID(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    static func isVariousArtists(_ value: String) -> Bool {
        ["variousartists", "various", "va"].contains(normalizedMetadata(value))
    }

    private static func artistCreditsAreRelated(_ lhs: String, _ rhs: String) -> Bool {
        creditContainsArtist(lhs, artist: rhs) || creditContainsArtist(rhs, artist: lhs)
    }

    private static func creditContainsArtist(_ credit: String, artist: String) -> Bool {
        if credit == artist { return true }
        guard let range = credit.range(of: artist) else { return false }
        let before = String(credit[..<range.lowerBound])
        let after = String(credit[range.upperBound...])
        let separators = [
            " & ", " and ", " feat ", " feat.", " ft ", " ft.", " featuring ", " with ",
            " x ", " × ", " + ", " / ", ", ", "; ", ",", ";"
        ]
        let beforeIsBoundary = before.isEmpty || separators.contains { before.hasSuffix($0) }
        let afterIsBoundary = after.isEmpty || separators.contains { after.hasPrefix($0) }
        return beforeIsBoundary && afterIsBoundary
    }

    private static func normalizedArtistCredit(_ value: String) -> String {
        var folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        folded = folded.replacingOccurrences(of: "＆", with: "&")
        for symbol in ["&", "+", "/", "×"] {
            folded = folded.replacingOccurrences(of: symbol, with: " \(symbol) ")
        }
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizedMetadata(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func metadataIsSearchable(_ value: String) -> Bool {
        let normalized = normalizedMetadata(value)
        return !normalized.isEmpty
            && !["unknownalbum", "unknownartist", "unknown", "various"].contains(normalized)
    }

    private static func articleIndependentSortValue(_ value: String) -> String {
        for article in ["The ", "An ", "A "] where value.range(
            of: article,
            options: [.anchored, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil {
            return String(value.dropFirst(article.count))
        }
        return value
    }

    static func durationDifference(_ lhs: ClassicTrack, _ rhs: ClassicTrack) -> UInt32 {
        lhs.durationMS > rhs.durationMS ? lhs.durationMS - rhs.durationMS : rhs.durationMS - lhs.durationMS
    }

}
