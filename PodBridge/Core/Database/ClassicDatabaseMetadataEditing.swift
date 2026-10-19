// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev
import Foundation
extension ClassicDatabase {
    private struct TrackMetadataEditPlan {
        let original: ClassicTrack, updated: ClassicTrack
        let library: ClassicLibrary
    }
    static func editingTrackMetadata(
        existing: Data,
        trackID: UInt32,
        update: TrackMetadataUpdate,
        firewireID: Data
    ) throws -> EditResult {
        let originalLibrary = try parse(existing)
        let plan = try trackMetadataEditPlan(trackID: trackID, update: update, library: originalLibrary)
        let signed = try editedTrackMetadataDatabase(existing, plan: plan, firewireID: firewireID)
        return try verifiedTrackMetadataEdit(signed, expected: plan.library, firewireID: firewireID)
    }
    private static func trackMetadataEditPlan(
        trackID: UInt32,
        update: TrackMetadataUpdate,
        library: ClassicLibrary
    ) throws -> TrackMetadataEditPlan {
        guard let index = library.tracks.firstIndex(where: { $0.id == trackID }) else { throw PodBridgeError.trackNotFound }
        let original = library.tracks[index]
        let otherTracks = library.tracks.enumerated().filter { $0.offset != index }.map(\.element)
        let updated = try updatedTrackMetadata(original, update: update, library: library, otherTracks: otherTracks)
        var expected = library; expected.tracks[index] = updated
        return TrackMetadataEditPlan(original: original, updated: updated, library: expected)
    }
    private static func updatedTrackMetadata(
        _ original: ClassicTrack,
        update: TrackMetadataUpdate,
        library: ClassicLibrary,
        otherTracks: [ClassicTrack]
    ) throws -> ClassicTrack {
        let title = update.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = update.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = update.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty else { throw PodBridgeError.invalidMetadata }
        var track = original
        track.title = title
        track.artist = artist
        track.album = album
        track.genre = update.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        track.year = update.year
        track.trackNumber = update.trackNumber
        track.albumArtist = update.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        track.compilation = update.compilation
        applySortValues(to: &track)
        track.albumID = resolvedAlbumID(for: track, original: original, library: library, otherTracks: otherTracks)
        track.artistID = resolvedArtistID(for: track, original: original, library: library, otherTracks: otherTracks)
        return track
    }
    private static func applySortValues(to track: inout ClassicTrack) {
        track.sortTitle = ""
        let artistSort = articleIndependentSortValue(track.artist)
        track.sortArtist = artistSort == track.artist ? "" : artistSort
        let albumSort = articleIndependentSortValue(track.album)
        track.sortAlbum = albumSort == track.album ? "" : albumSort
        let albumArtistSort = articleIndependentSortValue(track.albumArtist)
        track.sortAlbumArtist = albumArtistSort == track.albumArtist ? "" : albumArtistSort
    }
    private static func resolvedAlbumID(
        for track: ClassicTrack,
        original: ClassicTrack,
        library: ClassicLibrary,
        otherTracks: [ClassicTrack]
    ) -> UInt32 {
        let groupingArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        if let match = otherTracks.first(where: {
            ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) == groupingArtist
                && $0.album == track.album && $0.albumID != 0
        }) { return match.albumID }
        if albumGroupingArtist(original) == albumGroupingArtist(track),
           original.album == track.album,
           original.albumID != 0 {
            return original.albumID
        }
        let next = (library.tracks.map(\.albumID).max() ?? 0) &+ 1
        return next == 0 ? 1 : next
    }
    private static func resolvedArtistID(
        for track: ClassicTrack,
        original: ClassicTrack,
        library: ClassicLibrary,
        otherTracks: [ClassicTrack]
    ) -> UInt32 {
        if let match = otherTracks.first(where: { $0.artist == track.artist && $0.artistID != 0 }) {
            return match.artistID
        }
        if original.artist == track.artist, original.artistID != 0 { return original.artistID }
        let next = (library.tracks.map(\.artistID).max() ?? 0) &+ 1
        return next == 0 ? 1 : next
    }
    private static func editedTrackMetadataDatabase(
        _ existing: Data,
        plan: TrackMetadataEditPlan,
        firewireID: Data
    ) throws -> Data {
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            output.append(try editedTrackMetadataSection(existing, section: section, plan: plan))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return try Hash58.sign(output, firewireID: firewireID)
    }
    private static func editedTrackMetadataSection(
        _ data: Data,
        section: TopLevelSection,
        plan: TrackMetadataEditPlan
    ) throws -> Data {
        switch section.type {
        case 1:
            return try trackSectionEditing(data, range: section.range, track: plan.updated)
        case 2, 3:
            return try playlistSectionResorting(data, range: section.range, tracks: plan.library.tracks)
        case 4:
            return try albumSectionEditing(
                data,
                range: section.range,
                originalTrack: plan.original,
                updatedTrack: plan.updated,
                allTracks: plan.library.tracks
            )
        case 8:
            return try artistSectionEditing(
                data,
                range: section.range,
                originalTrack: plan.original,
                updatedTrack: plan.updated,
                allTracks: plan.library.tracks
            )
        default:
            return Data(data[section.range])
        }
    }
    private static func verifiedTrackMetadataEdit(
        _ data: Data,
        expected: ClassicLibrary,
        firewireID: Data
    ) throws -> EditResult {
        let verified = try parse(data)
        let diagnostics = try inspect(data, firewireID: firewireID)
        guard verified.tracks == expected.tracks,
              verified.playlists == expected.playlists,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: data, library: verified)
    }
    static func editingAlbumMetadata(
        existing: Data,
        trackIDs: [UInt32],
        album: String,
        albumArtist: String? = nil,
        artist: String? = nil,
        genre: String? = nil,
        year: UInt32? = nil,
        compilation: Bool? = nil,
        expandMatchingAlbums: Bool = true,
        firewireID: Data
    ) throws -> EditResult {
        let library = try parse(existing)
        let request = try AlbumMetadataRequest(
            trackIDs: trackIDs,
            album: album,
            albumArtist: albumArtist,
            artist: artist,
            genre: genre,
            year: year,
            compilation: compilation,
            expandMatchingAlbums: expandMatchingAlbums
        )
        let plan = try albumMetadataEditPlan(request, library: library)
        let signed = try editedAlbumMetadataDatabase(existing, plan: plan, firewireID: firewireID)
        return try verifiedAlbumMetadataEdit(signed, expected: plan.library, firewireID: firewireID)
    }
    private struct AlbumMetadataRequest {
        let trackIDs: Set<UInt32>
        let album: String, albumArtist: String?, artist: String?, genre: String?
        let year: UInt32?, compilation: Bool?, expandMatchingAlbums: Bool
        init(
            trackIDs: [UInt32],
            album: String,
            albumArtist: String?,
            artist: String?,
            genre: String?,
            year: UInt32?,
            compilation: Bool?,
            expandMatchingAlbums: Bool
        ) throws {
            self.trackIDs = Set(trackIDs)
            self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
            self.albumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.artist = artist
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            self.genre = genre?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.year = year
            self.compilation = compilation
            self.expandMatchingAlbums = expandMatchingAlbums
            guard !self.trackIDs.isEmpty, !self.album.isEmpty,
                  compilation != true || !(self.albumArtist ?? "").isEmpty else {
                throw PodBridgeError.invalidMetadata
            }
        }
    }
    private struct AlbumMetadataEditPlan {
        let library: ClassicLibrary, tracksByID: [UInt32: ClassicTrack]
        let albumPlan: EntityMergePlan, artistPlan: EntityMergePlan?
    }
    private static func albumMetadataEditPlan(
        _ request: AlbumMetadataRequest,
        library: ClassicLibrary
    ) throws -> AlbumMetadataEditPlan {
        let requested = library.tracks.filter { request.trackIDs.contains($0.id) }
        guard requested.count == request.trackIDs.count, let first = requested.first else {
            throw PodBridgeError.trackNotFound
        }
        let selected = albumMetadataSelectedTracks(request, requested: requested, first: first, library: library)
        let tracksByID = albumMetadataUpdates(request, selected: selected, first: first, library: library)
        let expected = libraryApplyingMetadataUpdates(tracksByID, to: library)
        guard let representative = expected.tracks.first(where: { $0.id == first.id }) else { throw PodBridgeError.trackNotFound }
        return AlbumMetadataEditPlan(
            library: expected,
            tracksByID: tracksByID,
            albumPlan: entityMergePlan(
                selected, representative: representative, expected: expected, isAlbum: true
            ),
            artistPlan: request.artist.map { _ in
                entityMergePlan(selected, representative: representative, expected: expected, isAlbum: false)
            }
        )
    }
    private static func albumMetadataSelectedTracks(
        _ request: AlbumMetadataRequest,
        requested: [ClassicTrack],
        first: ClassicTrack,
        library: ClassicLibrary
    ) -> [ClassicTrack] {
        guard request.expandMatchingAlbums else { return requested }
        let sourceMatches = library.tracks.filter {
            albumIdentityMatches($0, album: first.album, groupingArtist: albumGroupingArtist(first))
        }
        guard let destinationArtist = deterministicAlbumArtist(request, requested: requested) else {
            return sourceMatches
        }
        let destinationMatches = library.tracks.filter {
            albumIdentityMatches($0, album: request.album, groupingArtist: destinationArtist)
        }
        let IDs = Set(sourceMatches.map(\.id)).union(destinationMatches.map(\.id)).union(request.trackIDs)
        return library.tracks.filter { IDs.contains($0.id) }
    }
    private static func deterministicAlbumArtist(
        _ request: AlbumMetadataRequest,
        requested: [ClassicTrack]
    ) -> String? {
        if let artist = request.albumArtist, !artist.isEmpty { return artist }
        let artists = Set(requested.map(\.artist))
        return artists.count == 1 ? artists.first : nil
    }
    private static func albumMetadataUpdates(
        _ request: AlbumMetadataRequest,
        selected: [ClassicTrack],
        first: ClassicTrack,
        library: ClassicLibrary
    ) -> [UInt32: ClassicTrack] {
        let albumID = first.albumID == 0 ? nextMetadataID(library.tracks.map(\.albumID)) : first.albumID
        let artistID = request.artist.map { metadataArtistID($0, library: library) }
        return Dictionary(uniqueKeysWithValues: selected.map { original in
            (original.id, updatedAlbumMetadataTrack(
                original, request: request, albumID: albumID, artistID: artistID
            ))
        })
    }
    private static func updatedAlbumMetadataTrack(
        _ original: ClassicTrack,
        request: AlbumMetadataRequest,
        albumID: UInt32,
        artistID: UInt32?
    ) -> ClassicTrack {
        var track = original
        track.album = request.album
        if let albumArtist = request.albumArtist { track.albumArtist = albumArtist }
        if let artist = request.artist, let artistID {
            track.artist = artist
            track.artistID = artistID
            let sort = articleIndependentSortValue(artist)
            track.sortArtist = sort == artist ? "" : sort
        }
        if let genre = request.genre { track.genre = genre }
        if let year = request.year { track.year = year }
        if let compilation = request.compilation { track.compilation = compilation }
        track.albumID = albumID
        let albumSort = articleIndependentSortValue(request.album)
        track.sortAlbum = albumSort == request.album ? "" : albumSort
        let artistSort = articleIndependentSortValue(track.albumArtist)
        track.sortAlbumArtist = artistSort == track.albumArtist ? "" : artistSort
        return track
    }
    private static func metadataArtistID(_ artist: String, library: ClassicLibrary) -> UInt32 {
        if let track = library.tracks.first(where: {
            $0.artistID != 0 && $0.artist.caseInsensitiveCompare(artist) == .orderedSame
        }) { return track.artistID }
        return nextMetadataID(library.tracks.map(\.artistID))
    }
    private static func nextMetadataID(_ identifiers: [UInt32]) -> UInt32 {
        let next = (identifiers.max() ?? 0) &+ 1
        return next == 0 ? 1 : next
    }
    private static func libraryApplyingMetadataUpdates(
        _ updates: [UInt32: ClassicTrack],
        to library: ClassicLibrary
    ) -> ClassicLibrary {
        var expected = library
        for index in expected.tracks.indices {
            if let track = updates[expected.tracks[index].id] { expected.tracks[index] = track }
        }
        return expected
    }
    private static func entityMergePlan(
        _ selected: [ClassicTrack],
        representative: ClassicTrack,
        expected: ClassicLibrary,
        isAlbum: Bool
    ) -> EntityMergePlan {
        let oldIDs = Set(selected.map { isAlbum ? $0.albumID : $0.artistID }.filter { $0 != 0 })
        let targetID = isAlbum ? representative.albumID : representative.artistID
        let orphaned = oldIDs.filter { identifier in
            identifier != targetID && !expected.tracks.contains {
                (isAlbum ? $0.albumID : $0.artistID) == identifier
            }
        }
        return EntityMergePlan(
            listTag: isAlbum ? "mhla" : "mhli",
            recordTag: isAlbum ? "mhia" : "mhii",
            targetID: targetID,
            orphanedIDs: orphaned,
            replacement: isAlbum ? albumRecord(representative) : artistRecord(representative)
        )
    }
    private static func editedAlbumMetadataDatabase(
        _ existing: Data,
        plan: AlbumMetadataEditPlan,
        firewireID: Data
    ) throws -> Data {
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            output.append(try editedAlbumMetadataSection(existing, section: section, plan: plan))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return try Hash58.sign(output, firewireID: firewireID)
    }
    private static func editedAlbumMetadataSection(
        _ data: Data,
        section: TopLevelSection,
        plan: AlbumMetadataEditPlan
    ) throws -> Data {
        switch section.type {
        case 1:
            return try trackSectionEditing(data, range: section.range, tracksByID: plan.tracksByID)
        case 2, 3:
            return try playlistSectionResorting(data, range: section.range, tracks: plan.library.tracks)
        case 4:
            return try entitySectionMergingRecords(data, range: section.range, plan: plan.albumPlan)
        case 8:
            guard let artistPlan = plan.artistPlan else { return Data(data[section.range]) }
            return try entitySectionMergingRecords(data, range: section.range, plan: artistPlan)
        default:
            return Data(data[section.range])
        }
    }
    private static func verifiedAlbumMetadataEdit(
        _ data: Data,
        expected: ClassicLibrary,
        firewireID: Data
    ) throws -> EditResult {
        let verified = try parse(data)
        let diagnostics = try inspect(data, firewireID: firewireID)
        guard verified == expected,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: data, library: verified)
    }
}
