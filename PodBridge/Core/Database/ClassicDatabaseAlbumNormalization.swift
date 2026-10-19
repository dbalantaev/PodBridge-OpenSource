// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    private struct AlbumNormalizationState {
        var claimedIDs = Set<UInt32>()
        var nextAlbumID: UInt32

        mutating func apply(
            _ update: AlbumArtistNormalizationUpdate,
            in library: ClassicLibrary,
            updates: inout [UInt32: ClassicTrack]
        ) throws {
            let requested = Set(update.trackIDs)
            let album = update.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = update.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty, !album.isEmpty, !artist.isEmpty,
                  requested.isSubset(of: Set(library.tracks.map(\.id))),
                  claimedIDs.isDisjoint(with: requested) else {
                throw PodBridgeError.invalidMetadata
            }
            claimedIDs.formUnion(requested)
            let selected = library.tracks.filter { requested.contains($0.id) }
            let existingID = selected.first {
                $0.album.caseInsensitiveCompare(album) == .orderedSame && $0.albumID != 0
            }?.albumID ?? selected.first { $0.albumID != 0 }?.albumID
            let albumID = existingID ?? nextAlbumID
            if existingID == nil {
                nextAlbumID &+= 1
                if nextAlbumID == 0 { nextAlbumID = 1 }
            }
            for var track in selected {
                track.album = album
                track.albumArtist = artist
                track.compilation = update.compilation ?? track.compilation
                track.albumID = albumID
                let albumSort = ClassicDatabase.articleIndependentSortValue(album)
                track.sortAlbum = albumSort == album ? "" : albumSort
                let artistSort = ClassicDatabase.articleIndependentSortValue(artist)
                track.sortAlbumArtist = artistSort == artist ? "" : artistSort
                updates[track.id] = track
            }
        }
    }

    static func normalizingAlbumArtists(
        existing: Data,
        updates: [AlbumArtistNormalizationUpdate],
        firewireID: Data
    ) throws -> EditResult {
        guard !updates.isEmpty else {
            return EditResult(data: existing, library: try parse(existing))
        }
        let originalLibrary = try parse(existing)
        let updatedByID = try normalizedAlbumTracks(updates, in: originalLibrary)
        let expectedLibrary = libraryApplying(updatedByID, to: originalLibrary)

        return try rebuildingNormalizedDatabase(
            existing: existing,
            updatedByID: updatedByID,
            expectedLibrary: expectedLibrary,
            firewireID: firewireID
        )
    }

    private static func rebuildingNormalizedDatabase(
        existing: Data,
        updatedByID: [UInt32: ClassicTrack],
        expectedLibrary: ClassicLibrary,
        firewireID: Data
    ) throws -> EditResult {
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            switch section.type {
            case 1:
                output.append(try trackSectionEditing(existing, range: section.range, tracksByID: updatedByID))
            case 2, 3:
                output.append(try playlistSectionResorting(
                    existing,
                    range: section.range,
                    tracks: expectedLibrary.tracks
                ))
            case 4:
                output.append(try albumSectionRebuilding(
                    existing,
                    range: section.range,
                    tracks: expectedLibrary.tracks
                ))
            default:
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        return try verifiedNormalizedEdit(signed, expectedLibrary: expectedLibrary, firewireID: firewireID)
    }

    private static func verifiedNormalizedEdit(
        _ data: Data,
        expectedLibrary: ClassicLibrary,
        firewireID: Data
    ) throws -> EditResult {
        let verified = try parse(data)
        let diagnostics = try inspect(data, firewireID: firewireID)
        let libraryMatches = verified == expectedLibrary
        guard libraryMatches,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            AppLogger.database(
                "Atomic album normalization verification failed "
                    + "model=\(libraryMatches) "
                    + "difference=\(normalizationDifferenceSummary(expected: expectedLibrary, actual: verified)) "
                    + "master=\(diagnostics.primaryPlaylistFound) "
                    + "members=\(diagnostics.primaryPlaylistMembers)/\(verified.tracks.count) "
                    + "playlistCopies=\(diagnostics.playlistSectionsConsistent) "
                    + "sortIndexes=\(diagnostics.sortIndexesValid) "
                    + "jumpTables=\(diagnostics.jumpTablesValid) "
                    + "hash58=\(diagnostics.hash58Valid)",
                level: .error
            )
            throw PodBridgeError.databaseVerificationFailed
        }
        return EditResult(data: data, library: verified)
    }

    private static func normalizedAlbumTracks(
        _ normalizationUpdates: [AlbumArtistNormalizationUpdate],
        in library: ClassicLibrary
    ) throws -> [UInt32: ClassicTrack] {
        var state = AlbumNormalizationState(
            nextAlbumID: nextAvailableAlbumID(in: library)
        )
        var updates: [UInt32: ClassicTrack] = [:]
        for update in normalizationUpdates {
            try state.apply(update, in: library, updates: &updates)
        }
        return updates
    }

    private static func nextAvailableAlbumID(in library: ClassicLibrary) -> UInt32 {
        let next = (library.tracks.map(\.albumID).max() ?? 0) &+ 1
        return next == 0 ? 1 : next
    }

    private static func libraryApplying(
        _ updates: [UInt32: ClassicTrack],
        to library: ClassicLibrary
    ) -> ClassicLibrary {
        var updatedLibrary = library
        for index in updatedLibrary.tracks.indices {
            if let track = updates[updatedLibrary.tracks[index].id] {
                updatedLibrary.tracks[index] = track
            }
        }
        return updatedLibrary
    }

    private static func normalizationDifferenceSummary(
        expected: ClassicLibrary,
        actual: ClassicLibrary
    ) -> String {
        if expected.name != actual.name { return "library-name" }
        if expected.tracks.count != actual.tracks.count {
            return "track-count-\(expected.tracks.count)-\(actual.tracks.count)"
        }
        if expected.playlists != actual.playlists { return "playlists" }
        guard let pair = zip(expected.tracks, actual.tracks).first(where: { $0 != $1 }) else {
            return "unknown"
        }
        let expectedTrack = pair.0
        let actualTrack = pair.1
        let fields = trackDifferenceFields(expected: expectedTrack, actual: actualTrack)
        return "track-id-\(expectedTrack.id)-fields-\(fields.joined(separator: ","))"
    }

    private static func trackDifferenceFields(expected: ClassicTrack, actual: ClassicTrack) -> [String] {
        [
            ("id", expected.id != actual.id),
            ("databaseID", expected.databaseID != actual.databaseID),
            ("title", expected.title != actual.title),
            ("artist", expected.artist != actual.artist),
            ("album", expected.album != actual.album),
            ("genre", expected.genre != actual.genre),
            ("fileType", expected.fileType != actual.fileType),
            ("ipodPath", expected.ipodPath != actual.ipodPath),
            ("byteCount", expected.byteCount != actual.byteCount),
            ("durationMS", expected.durationMS != actual.durationMS),
            ("trackNumber", expected.trackNumber != actual.trackNumber),
            ("year", expected.year != actual.year),
            ("bitrate", expected.bitrate != actual.bitrate),
            ("sampleRate", expected.sampleRate != actual.sampleRate),
            ("dateAdded", expected.dateAdded != actual.dateAdded),
            ("albumID", expected.albumID != actual.albumID),
            ("artistID", expected.artistID != actual.artistID),
            ("artworkImageID", expected.artworkImageID != actual.artworkImageID),
            ("artworkByteCount", expected.artworkByteCount != actual.artworkByteCount),
            ("artworkData", expected.artworkData != actual.artworkData),
            ("sourceURL", expected.sourceURL != actual.sourceURL),
            ("sortTitle", expected.sortTitle != actual.sortTitle),
            ("sortArtist", expected.sortArtist != actual.sortArtist),
            ("sortAlbum", expected.sortAlbum != actual.sortAlbum),
            ("sortAlbumArtist", expected.sortAlbumArtist != actual.sortAlbumArtist),
            ("albumArtist", expected.albumArtist != actual.albumArtist),
            ("compilation", expected.compilation != actual.compilation),
            ("sourceAlbumID", expected.sourceAlbumID != actual.sourceAlbumID)
        ].compactMap { $0.1 ? $0.0 : nil }
    }

    static func albumIdentityMatches(
        _ track: ClassicTrack,
        album: String,
        groupingArtist: String
    ) -> Bool {
        track.album.caseInsensitiveCompare(album) == .orderedSame
            && albumGroupingArtist(track).caseInsensitiveCompare(groupingArtist) == .orderedSame
    }

    private static func albumSectionRebuilding(
        _ data: Data,
        range: Range<Int>,
        tracks: [ClassicTrack]
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == "mhla" else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        guard listOffset + listHeader <= source.count else { throw PodBridgeError.invalidDatabase }
        var representatives: [ClassicTrack] = []
        var seenIDs = Set<UInt32>()
        var seenFallbacks = Set<String>()
        for track in tracks {
            if track.albumID != 0 {
                if seenIDs.insert(track.albumID).inserted { representatives.append(track) }
            } else {
                let key = "\(albumGroupingArtist(track))\u{0}\(track.album)"
                if seenFallbacks.insert(key).inserted { representatives.append(track) }
            }
        }
        var output = Data(source.prefix(listOffset + listHeader))
        for track in representatives { output.append(albumRecord(track)) }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(UInt32(representatives.count), at: listOffset + 8)
        return output
    }
}
