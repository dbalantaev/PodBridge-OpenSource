// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// A parsed music track record from an iPod `iTunesDB`.
///
/// The model contains both user-visible metadata and the internal identifiers
/// required to preserve links between track, playlist, album, and artist records.
struct ClassicTrack: Identifiable, Sendable, Equatable {
    var id: UInt32
    var databaseID: UInt64
    var title: String
    var artist: String
    var album: String
    var genre: String
    var fileType: String
    var ipodPath: String
    var byteCount: UInt32
    var durationMS: UInt32
    var trackNumber: UInt32
    var year: UInt32
    var bitrate: UInt32
    var sampleRate: UInt32
    var dateAdded: UInt32
    var albumID: UInt32 = 0
    var artistID: UInt32 = 0
    var artworkImageID: UInt32 = 0
    var artworkByteCount: UInt32 = 0
    var artworkData: Data? = nil
    var sourceURL: URL?
    var sortTitle: String = ""
    var sortArtist: String = ""
    var sortAlbum: String = ""
    var sortAlbumArtist: String = ""
    var albumArtist: String = ""
    var compilation: Bool = false
    /// Source-release identity (normally the embedded UPC). It is used while importing
    /// and repairing a library, but is intentionally not written to iTunesDB.
    var sourceAlbumID: String = ""
}

/// A playlist and its ordered track identifiers as represented in `iTunesDB`.
struct ClassicPlaylist: Sendable, Equatable {
    var name: String
    var trackIDs: [UInt32]
}

/// The parsed library view used by the sync and editing pipelines.
struct ClassicLibrary: Sendable, Equatable {
    var name: String
    var tracks: [ClassicTrack]
    var playlists: [ClassicPlaylist]
}

/// Parser, editor, and serializer for the binary iPod Classic `iTunesDB` format.
///
/// This type is deliberately independent of file-system access. Callers provide
/// database bytes and a device signing key; transactional writes belong to
/// `IPodSyncEngine`.
enum ClassicDatabase {
    // MARK: - Diagnostics and edit results

    /// Integrity facts collected while inspecting an iTunesDB candidate.
    struct Diagnostics: Sendable {
        let playlists: Int
        let masterPlaylistFound: Bool
        let masterPlaylistMembers: Int
        let playlistSectionTypes: [UInt32]
        let playlistSectionsConsistent: Bool
        let sortIndexesValid: Bool
        let jumpTablesValid: Bool
        let hash58Valid: Bool
    }

    /// Integrity facts for one track record in an iTunesDB candidate.
    struct TrackDiagnostics: Sendable {
        let id: UInt32
        let path: String
        let marker: String
        let type1: UInt8
        let type2: UInt8
        let sizePrimary: UInt32
        let sizeRepeated: UInt32
        let rootLibraryIDValid: Bool
        let databaseIDsMatch: Bool
        let masterMembershipValid: Bool
        let headerValid: Bool

        var isValid: Bool {
            rootLibraryIDValid && databaseIDsMatch && masterMembershipValid && headerValid
        }
    }

    /// A playlist to append during a merge, with members resolved after import.
    struct PendingPlaylist: Sendable {
        enum Member: Sendable, Equatable {
            case existingTrackID(UInt32)
            case additionIndex(Int)
        }

        let name: String
        let members: [Member]

        init(name: String, additionIndices: [Int]) {
            self.name = name
            self.members = additionIndices.map(Member.additionIndex)
        }

        init(name: String, members: [Member]) {
            self.name = name
            self.members = members
        }
    }

    /// Output of a database merge, including diagnostics for newly added tracks.
    struct MergeResult: Sendable {
        let data: Data
        let library: ClassicLibrary
        let addedTrackDiagnostics: [TrackDiagnostics]
    }

    /// Output of removing one track from a parsed library.
    struct RemovalResult: Sendable {
        let data: Data
        let library: ClassicLibrary
        let removedTrack: ClassicTrack
    }

    /// Output of removing several tracks in one database rewrite.
    struct BatchRemovalResult: Sendable {
        let data: Data
        let library: ClassicLibrary
        let removedTracks: [ClassicTrack]
    }

    /// Metadata fields accepted by the track editor.
    struct TrackMetadataUpdate: Sendable, Equatable {
        let title: String
        let artist: String
        let album: String
        let genre: String
        let year: UInt32
        let trackNumber: UInt32

        let albumArtist: String
        let compilation: Bool

        init(
            title: String,
            artist: String,
            album: String,
            genre: String,
            year: UInt32,
            trackNumber: UInt32,
            albumArtist: String = "",
            compilation: Bool = false
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.genre = genre
            self.year = year
            self.trackNumber = trackNumber
            self.albumArtist = albumArtist
            self.compilation = compilation
        }
    }

    /// Album-wide artist normalization requested by the Cover Flow repair UI.
    struct AlbumArtistNormalizationUpdate: Sendable, Equatable {
        let trackIDs: [UInt32]
        let album: String
        let artist: String
        let compilation: Bool?

        init(
            trackIDs: [UInt32],
            album: String,
            artist: String,
            compilation: Bool? = nil
        ) {
            self.trackIDs = trackIDs
            self.album = album
            self.artist = artist
            self.compilation = compilation
        }
    }

    /// Serialized database and parsed library returned by an edit operation.
    struct EditResult: Sendable {
        let data: Data
        let library: ClassicLibrary
    }

    /// Track IDs whose artwork records were added or replaced.
    struct ArtworkUpdateResult: Sendable {
        let data: Data
        let library: ClassicLibrary
        let updatedTracks: [ClassicTrack]
    }

    // MARK: - High-level transformations

    /// Merges imported tracks and playlists into an existing signed database.
    static func merge(
        existing: Data,
        additions: [ClassicTrack],
        pendingPlaylists: [PendingPlaylist] = [],
        firewireID: Data
    ) throws -> MergeResult {
        var library = try parse(existing)
        let highestID = library.tracks.map(\.id).max() ?? 0
        var ids = Set(library.tracks.map(\.id))
        let recentIDs = library.tracks.suffix(32).map(\.id)
        let usesAppleOddIDSequence = recentIDs.count >= 2 && zip(recentIDs, recentIDs.dropFirst()).allSatisfy { $1 == $0 &+ 2 }
        let idIncrement: UInt32 = usesAppleOddIDSequence ? 2 : 1
        var nextID = highestID &+ idIncrement
        var databaseIDs = Set(library.tracks.map(\.databaseID))
        var prepared: [ClassicTrack] = []
        var albumIDs: [String: UInt32] = [:]
        var artistIDs: [String: UInt32] = [:]
        for track in library.tracks {
            if track.albumID != 0 { albumIDs["\(albumGroupingArtist(track))\u{0}\(track.album)"] = track.albumID }
            if track.artistID != 0 { artistIDs[track.artist] = track.artistID }
        }
        var nextAlbumID = (albumIDs.values.max() ?? 0) + 1
        var nextArtistID = (artistIDs.values.max() ?? 0) + 1
        var nextArtworkID = (library.tracks.map(\.artworkImageID).max() ?? 0) + 1
        var newAlbums: [ClassicTrack] = []
        var newArtists: [ClassicTrack] = []
        for var track in additions {
            while nextID == 0 || ids.contains(nextID) { nextID &+= idIncrement }
            var nextDatabaseID: UInt64
            repeat { nextDatabaseID = UInt64.random(in: 1...UInt64.max) } while databaseIDs.contains(nextDatabaseID)
            track.id = nextID; track.databaseID = nextDatabaseID
            ids.insert(nextID)
            databaseIDs.insert(nextDatabaseID)
            let albumKey = "\(albumGroupingArtist(track))\u{0}\(track.album)"
            if let albumID = albumIDs[albumKey] { track.albumID = albumID }
            else { track.albumID = nextAlbumID; albumIDs[albumKey] = nextAlbumID; nextAlbumID += 1; newAlbums.append(track) }
            if let artistID = artistIDs[track.artist] { track.artistID = artistID }
            else { track.artistID = nextArtistID; artistIDs[track.artist] = nextArtistID; nextArtistID += 1; newArtists.append(track) }
            if let artwork = track.artworkData, !artwork.isEmpty {
                track.artworkImageID = nextArtworkID
                track.artworkByteCount = UInt32(clamping: artwork.count)
                nextArtworkID += 1
            }
            prepared.append(track)
            nextID &+= idIncrement
        }
        library.tracks.append(contentsOf: prepared)
        var usedPlaylistNames = Set(library.playlists.map { $0.name.lowercased() })
        var appendedPlaylists: [ClassicPlaylist] = []
        let existingTrackIDs = Set(library.tracks.dropLast(prepared.count).map(\.id))
        for pending in pendingPlaylists {
            let ids = pending.members.compactMap { member -> UInt32? in
                switch member {
                case .existingTrackID(let id):
                    return existingTrackIDs.contains(id) ? id : nil
                case .additionIndex(let index):
                    return prepared.indices.contains(index) ? prepared[index].id : nil
                }
            }
            guard !ids.isEmpty else { continue }
            var name = pending.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { name = "Imported Playlist" }
            if usedPlaylistNames.contains(name.lowercased()) {
                var suffix = 2
                let base = name
                repeat { name = "\(base) (\(suffix))"; suffix += 1 } while usedPlaylistNames.contains(name.lowercased())
            }
            usedPlaylistNames.insert(name.lowercased())
            appendedPlaylists.append(ClassicPlaylist(name: name, trackIDs: ids))
        }
        library.playlists.append(contentsOf: appendedPlaylists)

        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        guard let trackRange = sections.first(where: { $0.type == 1 })?.range else {
            throw PodBridgeError.invalidDatabase
        }
        let playlistSections = sections.filter { $0.type == 2 || $0.type == 3 }
        guard !playlistSections.isEmpty else { throw PodBridgeError.invalidDatabase }
        let rootLibraryID = try existing.littleUInt64(at: 0x24)
        let newTrackSection = try mergedTrackSection(
            existing,
            range: trackRange,
            additions: prepared,
            rootLibraryID: rootLibraryID
        )
        var newPlaylistSections: [UInt32: Data] = [:]
        for section in playlistSections {
            newPlaylistSections[section.type] = try mergedPlaylistSection(
                existing,
                range: section.range,
                additions: prepared,
                tracks: library.tracks,
                appendedPlaylists: appendedPlaylists
            )
        }
        let albumRange = sections.first(where: { $0.type == 4 })?.range
        let artistRange = sections.first(where: { $0.type == 8 })?.range
        let newAlbumSection = try albumRange.map { try mergedEntitySection(existing, range: $0, additions: newAlbums.map(albumRecord)) }
        let newArtistSection = try artistRange.map { try mergedEntitySection(existing, range: $0, additions: newArtists.map(artistRecord)) }

        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.range == trackRange { output.append(newTrackSection) }
            else if let replacement = newPlaylistSections[section.type], section.type == 2 || section.type == 3 {
                output.append(replacement)
            }
            else if section.range == albumRange, let newAlbumSection { output.append(newAlbumSection) }
            else if section.range == artistRange, let newArtistSection { output.append(newArtistSection) }
            else { output.append(existing[section.range]) }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        let addedTrackDiagnostics = try prepared.map { try inspectTrack(signed, expected: $0) }
        guard verified.tracks.count == library.tracks.count,
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == library.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.hash58Valid,
              addedTrackDiagnostics.allSatisfy(\.isValid),
              Set(verified.tracks.prefix(library.tracks.count - prepared.count).map(\.id)) == Set(library.tracks.dropLast(prepared.count).map(\.id)) else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return MergeResult(data: signed, library: library, addedTrackDiagnostics: addedTrackDiagnostics)
    }

    /// Removes one track and all of its playlist memberships.
    static func removingTrack(existing: Data, trackID: UInt32, firewireID: Data) throws -> RemovalResult {
        let originalLibrary = try parse(existing)
        guard let removedIndex = originalLibrary.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw PodBridgeError.trackNotFound
        }
        let removedTrack = originalLibrary.tracks[removedIndex]
        var expectedLibrary = originalLibrary
        expectedLibrary.tracks.remove(at: removedIndex)
        expectedLibrary.playlists = expectedLibrary.playlists.map { playlist in
            ClassicPlaylist(name: playlist.name, trackIDs: playlist.trackIDs.filter { $0 != trackID })
        }

        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        guard sections.contains(where: { $0.type == 1 }),
              sections.contains(where: { $0.type == 2 || $0.type == 3 }) else {
            throw PodBridgeError.invalidDatabase
        }
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 1 {
                output.append(try trackSectionRemoving(existing, range: section.range, trackID: trackID))
            } else if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionRemoving(
                    existing,
                    range: section.range,
                    trackID: trackID,
                    removedTrackIndex: removedIndex,
                    remainingTracks: expectedLibrary.tracks
                ))
            } else if section.type == 4,
                      removedTrack.albumID != 0,
                      !expectedLibrary.tracks.contains(where: { $0.albumID == removedTrack.albumID }) {
                output.append(try entitySectionRemoving(
                    existing,
                    range: section.range,
                    listTag: "mhla",
                    recordTag: "mhia",
                    entityID: removedTrack.albumID
                ))
            } else if section.type == 8,
                      removedTrack.artistID != 0,
                      !expectedLibrary.tracks.contains(where: { $0.artistID == removedTrack.artistID }) {
                output.append(try entitySectionRemoving(
                    existing,
                    range: section.range,
                    listTag: "mhli",
                    recordTag: "mhii",
                    entityID: removedTrack.artistID
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified.tracks.map(\.id) == expectedLibrary.tracks.map(\.id),
              verified.playlists == expectedLibrary.playlists,
              !verified.tracks.contains(where: { $0.id == trackID }),
              verified.playlists.allSatisfy({ !$0.trackIDs.contains(trackID) }),
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == expectedLibrary.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return RemovalResult(data: signed, library: verified, removedTrack: removedTrack)
    }

    /// Removes several tracks while rebuilding indexes and playlist sections once.
    static func removingTracks(existing: Data, trackIDs: [UInt32], firewireID: Data) throws -> BatchRemovalResult {
        let uniqueIDs = Array(Set(trackIDs))
        guard !uniqueIDs.isEmpty else { throw PodBridgeError.trackNotFound }
        let originalLibrary = try parse(existing)
        let requested = Set(uniqueIDs)
        let removedTracks = originalLibrary.tracks.filter { requested.contains($0.id) }
        guard removedTracks.count == requested.count else { throw PodBridgeError.trackNotFound }
        var data = existing
        var library = originalLibrary
        for track in removedTracks {
            let result = try removingTrack(existing: data, trackID: track.id, firewireID: firewireID)
            data = result.data
            library = result.library
        }
        return BatchRemovalResult(data: data, library: library, removedTracks: removedTracks)
    }

    /// Updates one track's display metadata and rebuilds dependent indexes.
    static func editingTrackMetadata(
        existing: Data,
        trackID: UInt32,
        update: TrackMetadataUpdate,
        firewireID: Data
    ) throws -> EditResult {
        let title = update.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = update.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = update.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty else { throw PodBridgeError.invalidMetadata }
        let originalLibrary = try parse(existing)
        guard let trackIndex = originalLibrary.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw PodBridgeError.trackNotFound
        }
        let originalTrack = originalLibrary.tracks[trackIndex]
        var updatedTrack = originalTrack
        updatedTrack.title = title
        updatedTrack.artist = artist
        updatedTrack.album = album
        updatedTrack.genre = update.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedTrack.year = update.year
        updatedTrack.trackNumber = update.trackNumber
        updatedTrack.albumArtist = update.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedTrack.compilation = update.compilation
        updatedTrack.sortTitle = ""
        updatedTrack.sortArtist = articleIndependentSortValue(artist) == artist ? "" : articleIndependentSortValue(artist)
        updatedTrack.sortAlbum = articleIndependentSortValue(album) == album ? "" : articleIndependentSortValue(album)
        let albumArtistSort = articleIndependentSortValue(updatedTrack.albumArtist)
        updatedTrack.sortAlbumArtist = albumArtistSort == updatedTrack.albumArtist ? "" : albumArtistSort

        let otherTracks = originalLibrary.tracks.enumerated().filter { $0.offset != trackIndex }.map(\.element)
        let updatedAlbumGroupingArtist = updatedTrack.albumArtist.isEmpty ? artist : updatedTrack.albumArtist
        if let existingAlbum = otherTracks.first(where: {
            ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist) == updatedAlbumGroupingArtist
                && $0.album == album && $0.albumID != 0
        }) {
            updatedTrack.albumID = existingAlbum.albumID
        } else if albumGroupingArtist(originalTrack) == albumGroupingArtist(updatedTrack),
                  originalTrack.album == album,
                  originalTrack.albumID != 0 {
            updatedTrack.albumID = originalTrack.albumID
        } else {
            updatedTrack.albumID = (originalLibrary.tracks.map(\.albumID).max() ?? 0) &+ 1
            if updatedTrack.albumID == 0 { updatedTrack.albumID = 1 }
        }
        if let existingArtist = otherTracks.first(where: { $0.artist == artist && $0.artistID != 0 }) {
            updatedTrack.artistID = existingArtist.artistID
        } else if originalTrack.artist == artist, originalTrack.artistID != 0 {
            updatedTrack.artistID = originalTrack.artistID
        } else {
            updatedTrack.artistID = (originalLibrary.tracks.map(\.artistID).max() ?? 0) &+ 1
            if updatedTrack.artistID == 0 { updatedTrack.artistID = 1 }
        }

        var expectedLibrary = originalLibrary
        expectedLibrary.tracks[trackIndex] = updatedTrack
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            switch section.type {
            case 1:
                output.append(try trackSectionEditing(existing, range: section.range, track: updatedTrack))
            case 2, 3:
                output.append(try playlistSectionResorting(existing, range: section.range, tracks: expectedLibrary.tracks))
            case 4:
                output.append(try albumSectionEditing(
                    existing,
                    range: section.range,
                    originalTrack: originalTrack,
                    updatedTrack: updatedTrack,
                    allTracks: expectedLibrary.tracks
                ))
            case 8:
                output.append(try artistSectionEditing(
                    existing,
                    range: section.range,
                    originalTrack: originalTrack,
                    updatedTrack: updatedTrack,
                    allTracks: expectedLibrary.tracks
                ))
            default:
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified.tracks == expectedLibrary.tracks,
              verified.playlists == expectedLibrary.playlists,
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Applies a metadata update consistently to every track in an album group.
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
        let requested = Set(trackIDs)
        let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumArtist = albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard !requested.isEmpty, !album.isEmpty,
              compilation != true || !(albumArtist ?? "").isEmpty else { throw PodBridgeError.invalidMetadata }
        let originalLibrary = try parse(existing)
        let requestedTracks = originalLibrary.tracks.filter { requested.contains($0.id) }
        guard requestedTracks.count == requested.count, let firstOriginal = requestedTracks.first else {
            throw PodBridgeError.trackNotFound
        }

        // The same visible album can exist more than once in older or repeatedly imported
        // libraries, with a different internal albumID for every copy. Editing only the
        // tapped ID leaves the old card behind in Cover Flow. Treat exact source matches as
        // one logical album and also absorb an existing card that already has the requested
        // destination metadata.
        let sourceAlbum = firstOriginal.album
        let sourceGroupingArtist = albumGroupingArtist(firstOriginal)
        var selectedIDs = requested
        if expandMatchingAlbums {
            selectedIDs.formUnion(originalLibrary.tracks.filter {
                albumIdentityMatches(
                    $0,
                    album: sourceAlbum,
                    groupingArtist: sourceGroupingArtist
                )
            }.map(\.id))
        }
        let deterministicDestinationArtist: String? = {
            if let albumArtist, !albumArtist.isEmpty { return albumArtist }
            let artists = Set(requestedTracks.map(\.artist))
            return artists.count == 1 ? artists.first : nil
        }()
        if expandMatchingAlbums, let deterministicDestinationArtist {
            selectedIDs.formUnion(originalLibrary.tracks.compactMap { track in
                albumIdentityMatches(
                    track,
                    album: album,
                    groupingArtist: deterministicDestinationArtist
                ) ? track.id : nil
            })
        }
        let selected = originalLibrary.tracks.filter { selectedIDs.contains($0.id) }

        // An album shown by the library UI is one logical entity. Keeping its ID lets us
        // update hundreds of tracks and its entity record in one verified database pass.
        // Matching duplicate album IDs are collapsed into this ID below.
        let albumID = firstOriginal.albumID != 0
            ? firstOriginal.albumID
            : ((originalLibrary.tracks.map(\.albumID).max() ?? 0) &+ 1)
        let artistID: UInt32? = artist.map { requestedArtist in
            if let existing = originalLibrary.tracks.first(where: {
                $0.artistID != 0
                    && $0.artist.caseInsensitiveCompare(requestedArtist) == .orderedSame
            }) {
                return existing.artistID
            }
            let next = (originalLibrary.tracks.map(\.artistID).max() ?? 0) &+ 1
            return next == 0 ? 1 : next
        }
        var updatedByID: [UInt32: ClassicTrack] = [:]
        for original in selected {
            var track = original
            track.album = album
            if let albumArtist { track.albumArtist = albumArtist }
            if let artist, let artistID {
                track.artist = artist
                track.artistID = artistID
                track.sortArtist = articleIndependentSortValue(artist) == artist
                    ? ""
                    : articleIndependentSortValue(artist)
            }
            if let genre { track.genre = genre.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let year { track.year = year }
            if let compilation { track.compilation = compilation }
            track.albumID = albumID == 0 ? 1 : albumID
            track.sortAlbum = articleIndependentSortValue(album) == album ? "" : articleIndependentSortValue(album)
            let albumArtistSort = articleIndependentSortValue(track.albumArtist)
            track.sortAlbumArtist = albumArtistSort == track.albumArtist ? "" : albumArtistSort
            updatedByID[track.id] = track
        }
        var expectedLibrary = originalLibrary
        for index in expectedLibrary.tracks.indices {
            if let updated = updatedByID[expectedLibrary.tracks[index].id] {
                expectedLibrary.tracks[index] = updated
            }
        }
        guard let representative = expectedLibrary.tracks.first(where: { $0.id == firstOriginal.id }) else {
            throw PodBridgeError.trackNotFound
        }
        let selectedOriginalAlbumIDs = Set(selected.map(\.albumID).filter { $0 != 0 })
        let orphanedAlbumIDs = selectedOriginalAlbumIDs.filter { oldID in
            oldID != representative.albumID
                && !expectedLibrary.tracks.contains(where: { $0.albumID == oldID })
        }
        let selectedOriginalArtistIDs = Set(selected.map(\.artistID).filter { $0 != 0 })
        let orphanedArtistIDs = selectedOriginalArtistIDs.filter { oldID in
            oldID != representative.artistID
                && !expectedLibrary.tracks.contains(where: { $0.artistID == oldID })
        }

        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            switch section.type {
            case 1:
                output.append(try trackSectionEditing(existing, range: section.range, tracksByID: updatedByID))
            case 2, 3:
                output.append(try playlistSectionResorting(existing, range: section.range, tracks: expectedLibrary.tracks))
            case 4:
                output.append(try entitySectionMergingRecords(
                    existing,
                    range: section.range,
                    listTag: "mhla",
                    recordTag: "mhia",
                    targetID: representative.albumID,
                    orphanedIDs: orphanedAlbumIDs,
                    replacement: albumRecord(representative)
                ))
            case 8 where artist != nil:
                output.append(try entitySectionMergingRecords(
                    existing,
                    range: section.range,
                    listTag: "mhli",
                    recordTag: "mhii",
                    targetID: representative.artistID,
                    orphanedIDs: orphanedArtistIDs,
                    replacement: artistRecord(representative)
                ))
            default:
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified == expectedLibrary,
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Normalizes album-artist and compilation tags for selected album groups.
    static func normalizingAlbumArtists(
        existing: Data,
        updates: [AlbumArtistNormalizationUpdate],
        firewireID: Data
    ) throws -> EditResult {
        guard !updates.isEmpty else {
            return EditResult(data: existing, library: try parse(existing))
        }
        let originalLibrary = try parse(existing)
        let validIDs = Set(originalLibrary.tracks.map(\.id))
        var claimedIDs = Set<UInt32>()
        var updatedByID: [UInt32: ClassicTrack] = [:]
        var nextAlbumID = (originalLibrary.tracks.map(\.albumID).max() ?? 0) &+ 1
        if nextAlbumID == 0 { nextAlbumID = 1 }

        for update in updates {
            let requested = Set(update.trackIDs)
            let album = update.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = update.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty, !album.isEmpty, !artist.isEmpty,
                  requested.isSubset(of: validIDs),
                  claimedIDs.isDisjoint(with: requested) else {
                throw PodBridgeError.invalidMetadata
            }
            claimedIDs.formUnion(requested)
            let selected = originalLibrary.tracks.filter { requested.contains($0.id) }
            let preferredExistingID = selected.first(where: {
                $0.album.caseInsensitiveCompare(album) == .orderedSame && $0.albumID != 0
            })?.albumID ?? selected.first(where: { $0.albumID != 0 })?.albumID
            let albumID = preferredExistingID ?? nextAlbumID
            if preferredExistingID == nil {
                nextAlbumID &+= 1
                if nextAlbumID == 0 { nextAlbumID = 1 }
            }
            for var track in selected {
                track.album = album
                track.albumArtist = artist
                if let compilation = update.compilation {
                    track.compilation = compilation
                }
                track.albumID = albumID
                let albumSort = articleIndependentSortValue(album)
                track.sortAlbum = albumSort == album ? "" : albumSort
                let albumArtistSort = articleIndependentSortValue(artist)
                track.sortAlbumArtist = albumArtistSort == artist ? "" : albumArtistSort
                updatedByID[track.id] = track
            }
        }

        var expectedLibrary = originalLibrary
        for index in expectedLibrary.tracks.indices {
            if let updated = updatedByID[expectedLibrary.tracks[index].id] {
                expectedLibrary.tracks[index] = updated
            }
        }
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            switch section.type {
            case 1:
                output.append(try trackSectionEditing(existing, range: section.range, tracksByID: updatedByID))
            case 2, 3:
                output.append(try playlistSectionResorting(existing, range: section.range, tracks: expectedLibrary.tracks))
            case 4:
                output.append(try albumSectionRebuilding(existing, range: section.range, tracks: expectedLibrary.tracks))
            default:
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        let libraryMatches = verified == expectedLibrary
        guard libraryMatches,
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            AppLogger.database(
                "Atomic album normalization verification failed "
                    + "model=\(libraryMatches) "
                    + "difference=\(normalizationDifferenceSummary(expected: expectedLibrary, actual: verified)) "
                    + "master=\(diagnostics.masterPlaylistFound) "
                    + "members=\(diagnostics.masterPlaylistMembers)/\(verified.tracks.count) "
                    + "playlistCopies=\(diagnostics.playlistSectionsConsistent) "
                    + "sortIndexes=\(diagnostics.sortIndexesValid) "
                    + "jumpTables=\(diagnostics.jumpTablesValid) "
                    + "hash58=\(diagnostics.hash58Valid)",
                level: .error
            )
            throw PodBridgeError.databaseVerificationFailed
        }
        return EditResult(data: signed, library: verified)
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
        var fields: [String] = []
        if expectedTrack.id != actualTrack.id { fields.append("id") }
        if expectedTrack.databaseID != actualTrack.databaseID { fields.append("databaseID") }
        if expectedTrack.title != actualTrack.title { fields.append("title") }
        if expectedTrack.artist != actualTrack.artist { fields.append("artist") }
        if expectedTrack.album != actualTrack.album { fields.append("album") }
        if expectedTrack.genre != actualTrack.genre { fields.append("genre") }
        if expectedTrack.fileType != actualTrack.fileType { fields.append("fileType") }
        if expectedTrack.ipodPath != actualTrack.ipodPath { fields.append("ipodPath") }
        if expectedTrack.byteCount != actualTrack.byteCount { fields.append("byteCount") }
        if expectedTrack.durationMS != actualTrack.durationMS { fields.append("durationMS") }
        if expectedTrack.trackNumber != actualTrack.trackNumber { fields.append("trackNumber") }
        if expectedTrack.year != actualTrack.year { fields.append("year") }
        if expectedTrack.bitrate != actualTrack.bitrate { fields.append("bitrate") }
        if expectedTrack.sampleRate != actualTrack.sampleRate { fields.append("sampleRate") }
        if expectedTrack.dateAdded != actualTrack.dateAdded { fields.append("dateAdded") }
        if expectedTrack.albumID != actualTrack.albumID { fields.append("albumID") }
        if expectedTrack.artistID != actualTrack.artistID { fields.append("artistID") }
        if expectedTrack.artworkImageID != actualTrack.artworkImageID { fields.append("artworkImageID") }
        if expectedTrack.artworkByteCount != actualTrack.artworkByteCount { fields.append("artworkByteCount") }
        if expectedTrack.artworkData != actualTrack.artworkData { fields.append("artworkData") }
        if expectedTrack.sourceURL != actualTrack.sourceURL { fields.append("sourceURL") }
        if expectedTrack.sortTitle != actualTrack.sortTitle { fields.append("sortTitle") }
        if expectedTrack.sortArtist != actualTrack.sortArtist { fields.append("sortArtist") }
        if expectedTrack.sortAlbum != actualTrack.sortAlbum { fields.append("sortAlbum") }
        if expectedTrack.sortAlbumArtist != actualTrack.sortAlbumArtist { fields.append("sortAlbumArtist") }
        if expectedTrack.albumArtist != actualTrack.albumArtist { fields.append("albumArtist") }
        if expectedTrack.compilation != actualTrack.compilation { fields.append("compilation") }
        if expectedTrack.sourceAlbumID != actualTrack.sourceAlbumID { fields.append("sourceAlbumID") }
        return "track-id-\(expectedTrack.id)-fields-\(fields.joined(separator: ","))"
    }

    private static func albumIdentityMatches(
        _ track: ClassicTrack,
        album: String,
        groupingArtist: String
    ) -> Bool {
        track.album.caseInsensitiveCompare(album) == .orderedSame
            && albumGroupingArtist(track).caseInsensitiveCompare(groupingArtist) == .orderedSame
    }

    /// Appends a user playlist without changing the source audio records.
    static func addingPlaylist(
        existing: Data,
        name: String,
        trackIDs: [UInt32],
        firewireID: Data
    ) throws -> EditResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !trackIDs.isEmpty else { throw PodBridgeError.invalidMetadata }
        let library = try parse(existing)
        guard !library.playlists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw PodBridgeError.duplicatePlaylistName
        }
        let validIDs = Set(library.tracks.map(\.id))
        guard trackIDs.allSatisfy(validIDs.contains) else { throw PodBridgeError.trackNotFound }
        let merged = try merge(
            existing: existing,
            additions: [],
            pendingPlaylists: [PendingPlaylist(
                name: name,
                members: trackIDs.map(PendingPlaylist.Member.existingTrackID)
            )],
            firewireID: firewireID
        )
        return EditResult(data: merged.data, library: merged.library)
    }

    /// Renames a playlist and, when applicable, its generated compilation album.
    static func renamingPlaylist(
        existing: Data,
        playlistIndex: Int,
        newName: String,
        firewireID: Data
    ) throws -> EditResult {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PodBridgeError.invalidMetadata }
        var expectedLibrary = try parse(existing)
        guard expectedLibrary.playlists.indices.contains(playlistIndex) else { throw PodBridgeError.playlistNotFound }
        guard !expectedLibrary.playlists.enumerated().contains(where: {
            $0.offset != playlistIndex && $0.element.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw PodBridgeError.duplicatePlaylistName }
        expectedLibrary.playlists[playlistIndex].name = name
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionRenaming(
                    existing,
                    range: section.range,
                    playlistIndex: playlistIndex,
                    name: name
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified == expectedLibrary,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Removes a playlist while retaining all referenced tracks.
    static func removingPlaylist(
        existing: Data,
        playlistIndex: Int,
        firewireID: Data
    ) throws -> EditResult {
        var expectedLibrary = try parse(existing)
        guard expectedLibrary.playlists.indices.contains(playlistIndex) else {
            throw PodBridgeError.playlistNotFound
        }
        expectedLibrary.playlists.remove(at: playlistIndex)
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionRemovingPlaylist(
                    existing,
                    range: section.range,
                    playlistIndex: playlistIndex
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified == expectedLibrary,
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Adds or replaces artwork references for selected tracks.
    static func addingArtwork(
        existing: Data,
        artworkByTrackID: [UInt32: Data],
        firewireID: Data
    ) throws -> ArtworkUpdateResult {
        guard !artworkByTrackID.isEmpty else { throw PodBridgeError.invalidArtwork }
        let originalLibrary = try parse(existing)
        let requestedIDs = Set(artworkByTrackID.keys)
        guard requestedIDs.isSubset(of: Set(originalLibrary.tracks.map(\.id))) else {
            throw PodBridgeError.trackNotFound
        }
        var nextArtworkID = (originalLibrary.tracks.map(\.artworkImageID).max() ?? 0) &+ 1
        if nextArtworkID == 0 { nextArtworkID = 1 }
        var updatedByID: [UInt32: ClassicTrack] = [:]
        for originalTrack in originalLibrary.tracks where requestedIDs.contains(originalTrack.id) {
            guard let artwork = artworkByTrackID[originalTrack.id],
                  !artwork.isEmpty else { continue }
            var track = originalTrack
            track.artworkImageID = nextArtworkID
            track.artworkByteCount = UInt32(clamping: artwork.count)
            track.artworkData = artwork
            updatedByID[track.id] = track
            nextArtworkID &+= 1
            if nextArtworkID == 0 { nextArtworkID = 1 }
        }
        guard !updatedByID.isEmpty else { throw PodBridgeError.invalidArtwork }

        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 1 {
                output.append(try trackSectionEditing(existing, range: section.range, tracksByID: updatedByID))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        let updatedTracks = originalLibrary.tracks.compactMap { updatedByID[$0.id] }
        let audits = try updatedTracks.map { try inspectTrack(signed, expected: $0) }
        guard diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid,
              audits.allSatisfy(\.isValid),
              updatedTracks.allSatisfy({ expected in
                  verified.tracks.first(where: { $0.id == expected.id })?.artworkImageID == expected.artworkImageID
              }) else { throw PodBridgeError.databaseVerificationFailed }
        return ArtworkUpdateResult(data: signed, library: verified, updatedTracks: updatedTracks)
    }

    // MARK: - Parsing and diagnostics

    /// Parses the track and playlist model from an iTunesDB byte buffer.
    static func parse(_ data: Data) throws -> ClassicLibrary {
        guard data.ascii(at: 0, length: 4) == "mhbd" else { throw PodBridgeError.invalidDatabase }
        let headerLength = Int(try data.littleUInt32(at: 4))
        guard headerLength >= 0x6c, headerLength <= data.count else { throw PodBridgeError.invalidDatabase }

        var tracks: [ClassicTrack] = []
        var typeTwoPlaylistRecords: [ParsedPlaylist] = []
        var typeThreePlaylistRecords: [ParsedPlaylist] = []
        var cursor = headerLength
        while cursor + 16 <= data.count, data.ascii(at: cursor, length: 4) == "mhsd" {
            let sectionLength = Int(try data.littleUInt32(at: cursor + 8))
            let sectionType = try data.littleUInt32(at: cursor + 12)
            guard sectionLength > 0, cursor + sectionLength <= data.count else { throw PodBridgeError.invalidDatabase }
            if sectionType == 1 {
                tracks = try parseTracks(data, section: cursor..<(cursor + sectionLength))
            } else if sectionType == 2 {
                typeTwoPlaylistRecords = try parsePlaylistRecords(data, section: cursor..<(cursor + sectionLength))
            } else if sectionType == 3 {
                typeThreePlaylistRecords = try parsePlaylistRecords(data, section: cursor..<(cursor + sectionLength))
            }
            cursor += sectionLength
        }
        guard !tracks.isEmpty || data.count < 1_024 * 1_024 else { throw PodBridgeError.invalidDatabase }
        // Classic firmware and libgpod prefer the type-3 playlist copy when it exists.
        // Reading type 2 first hid stale type-3 master playlists from verification.
        let playlistRecords = typeThreePlaylistRecords.isEmpty ? typeTwoPlaylistRecords : typeThreePlaylistRecords
        let master = playlistRecords.first(where: \.isMaster)
        return ClassicLibrary(
            name: master?.playlist.name ?? "iPod",
            tracks: tracks,
            playlists: playlistRecords.filter { !$0.isMaster }.map(\.playlist)
        )
    }

    /// Validates structural invariants and the device-specific database hash.
    static func inspect(_ data: Data, firewireID: Data) throws -> Diagnostics {
        let headerLength = Int(try data.littleUInt32(at: 4))
        let sections = try topLevelSections(data, start: headerLength)
        let playlistSections = sections.filter { $0.type == 2 || $0.type == 3 }
        var recordsByType: [UInt32: [ParsedPlaylist]] = [:]
        var auditsByType: [UInt32: (Bool, Bool)] = [:]
        for section in playlistSections {
            recordsByType[section.type] = try parsePlaylistRecords(data, section: section.range)
            auditsByType[section.type] = try masterIndexAudit(data, section: section.range)
        }
        let primaryType: UInt32? = recordsByType[3] == nil ? (recordsByType[2] == nil ? nil : 2) : 3
        let records = primaryType.flatMap { recordsByType[$0] } ?? []
        let master = records.first(where: \.isMaster)
        let masterIDs = playlistSections.compactMap { section in
            recordsByType[section.type]?.first(where: \.isMaster)?.playlist.trackIDs
        }
        let sectionsConsistent = !masterIDs.isEmpty && masterIDs.dropFirst().allSatisfy { $0 == masterIDs.first }
        let indexAudits = playlistSections.compactMap { auditsByType[$0.type] }
        return Diagnostics(
            playlists: records.filter { !$0.isMaster }.count,
            masterPlaylistFound: master != nil,
            masterPlaylistMembers: master?.playlist.trackIDs.count ?? 0,
            playlistSectionTypes: playlistSections.map(\.type),
            playlistSectionsConsistent: sectionsConsistent,
            sortIndexesValid: !indexAudits.isEmpty && indexAudits.allSatisfy { $0.0 },
            jumpTablesValid: !indexAudits.isEmpty && indexAudits.allSatisfy { $0.1 },
            hash58Valid: try Hash58.verify(data, firewireID: firewireID)
        )
    }

    /// Audits one serialized track against the expected imported record.
    static func inspectTrack(_ data: Data, expected track: ClassicTrack) throws -> TrackDiagnostics {
        let headerLength = Int(try data.littleUInt32(at: 4))
        let sections = try topLevelSections(data, start: headerLength)
        guard let trackSection = sections.first(where: { $0.type == 1 }) else {
            throw PodBridgeError.invalidDatabase
        }
        let sectionHeader = Int(try data.littleUInt32(at: trackSection.range.lowerBound + 4))
        let list = trackSection.range.lowerBound + sectionHeader
        guard data.ascii(at: list, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        var cursor = list + Int(try data.littleUInt32(at: list + 4))
        var recordOffset: Int?
        var recordEnd = 0
        while cursor + 16 <= trackSection.range.upperBound, data.ascii(at: cursor, length: 4) == "mhit" {
            let total = Int(try data.littleUInt32(at: cursor + 8))
            guard total > 0, cursor + total <= trackSection.range.upperBound else { throw PodBridgeError.invalidDatabase }
            if try data.littleUInt32(at: cursor + 0x10) == track.id {
                recordOffset = cursor
                recordEnd = cursor + total
                break
            }
            cursor += total
        }
        guard let recordOffset else { throw PodBridgeError.databaseVerificationFailed }

        let recordHeader = Int(try data.littleUInt32(at: recordOffset + 4))
        guard recordHeader >= 0x248 else { throw PodBridgeError.databaseVerificationFailed }
        var strings: [UInt32: String] = [:]
        var child = recordOffset + recordHeader
        while child + 40 <= recordEnd, data.ascii(at: child, length: 4) == "mhod" {
            let length = Int(try data.littleUInt32(at: child + 8))
            let type = try data.littleUInt32(at: child + 12)
            guard length >= 40, child + length <= recordEnd else { throw PodBridgeError.invalidDatabase }
            let stringLength = min(Int(try data.littleUInt32(at: child + 28)), length - 40)
            strings[type] = String(data: data[(child + 40)..<(child + 40 + stringLength)], encoding: .utf16LittleEndian)
            child += length
        }

        let format = trackFormat(track)
        let marker = data.ascii(at: recordOffset + 0x18, length: 4) ?? ""
        let type1 = data[recordOffset + 0x1c]
        let type2 = data[recordOffset + 0x1d]
        let compilation = data[recordOffset + 0x1e] != 0
        let sizePrimary = try data.littleUInt32(at: recordOffset + 0x24)
        let sizeRepeated = try data.littleUInt32(at: recordOffset + 0x12c)
        let dbid = try data.littleUInt64(at: recordOffset + 0x70)
        let dbid2 = try data.littleUInt64(at: recordOffset + 0xa8)
        let rootLibraryID = try data.littleUInt64(at: 0x24)
        let trackRootLibraryID = try data.littleUInt64(at: recordOffset + 0x124)
        let masterLists = sections.filter { $0.type == 2 || $0.type == 3 }.compactMap { section -> [UInt32]? in
            try? parsePlaylistRecords(data, section: section.range).first(where: \.isMaster)?.playlist.trackIDs
        }
        let memberValid = !masterLists.isEmpty && masterLists.allSatisfy { ids in
            ids.filter { $0 == track.id }.count == 1
        }
        let artworkLink = try data.littleUInt32(at: recordOffset + 0x160)
        let artworkCount = try data.littleUInt16(at: recordOffset + 0x7c)
        let artworkValid: Bool
        if track.artworkImageID == 0 {
            artworkValid = data[recordOffset + 0xa4] == 2 && artworkLink == 0
        } else {
            artworkValid = data[recordOffset + 0xa4] == 1
                && artworkCount == 1
                && artworkLink == track.artworkImageID
        }
        let visible = try data.littleUInt32(at: recordOffset + 0x14)
        let duration = try data.littleUInt32(at: recordOffset + 0x28)
        let sampleRatePacked = try data.littleUInt32(at: recordOffset + 0x3c)
        let sampleRateFloat = try data.littleUInt32(at: recordOffset + 0x88)
        let mediaType = try data.littleUInt32(at: recordOffset + 0xd0)
        let albumID = try data.littleUInt32(at: recordOffset + 0x120)
        let reserved130 = try data.littleUInt32(at: recordOffset + 0x130)
        let magic = try data.littleUInt64(at: recordOffset + 0x134)
        let unknown168 = try data.littleUInt32(at: recordOffset + 0x168)
        let artistID = try data.littleUInt32(at: recordOffset + 0x1e0)
        let headerValid = visible == 1
            && marker == format.marker
            && type1 == format.type1
            && type2 == format.type2
            && compilation == track.compilation
            && sizePrimary == track.byteCount
            && sizeRepeated == track.byteCount
            && duration == track.durationMS
            && sampleRatePacked == track.sampleRate << 16
            && sampleRateFloat == Float(track.sampleRate).bitPattern
            && mediaType == 1
            && albumID == track.albumID
            && reserved130 == 0
            && magic != 0
            && unknown168 == 1
            && artistID == track.artistID
            && strings[1] == track.title
            && strings[2] == track.ipodPath
            && (strings[22] ?? "") == track.albumArtist
            && artworkValid
        return TrackDiagnostics(
            id: track.id,
            path: strings[2] ?? "",
            marker: marker,
            type1: type1,
            type2: type2,
            sizePrimary: sizePrimary,
            sizeRepeated: sizeRepeated,
            rootLibraryIDValid: trackRootLibraryID == rootLibraryID && rootLibraryID != 0,
            databaseIDsMatch: dbid == track.databaseID && dbid2 == track.databaseID && dbid != 0,
            masterMembershipValid: memberValid,
            headerValid: headerValid
        )
    }

    private static func masterIndexAudit(_ data: Data, section: Range<Int>) throws -> (Bool, Bool) {
        let sectionHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + sectionHeader
        guard data.ascii(at: list, length: 4) == "mhlp" else { return (false, false) }
        var playlist = list + Int(try data.littleUInt32(at: list + 4))
        while playlist + 24 <= section.upperBound, data.ascii(at: playlist, length: 4) == "mhyp" {
            let header = Int(try data.littleUInt32(at: playlist + 4))
            let total = Int(try data.littleUInt32(at: playlist + 8))
            guard total >= header, playlist + total <= section.upperBound else { throw PodBridgeError.invalidDatabase }
            if try data.littleUInt32(at: playlist + 20) != 0 {
                let members = try data.littleUInt32(at: playlist + 16)
                var child = playlist + header
                var sortCounts: [UInt32] = []
                var jumpCounts: [UInt32] = []
                while child + 16 <= playlist + total, data.ascii(at: child, length: 4) == "mhod" {
                    let length = Int(try data.littleUInt32(at: child + 8))
                    guard length > 0, child + length <= playlist + total else { throw PodBridgeError.invalidDatabase }
                    let type = try data.littleUInt32(at: child + 12)
                    if type == 52, length >= 32 {
                        sortCounts.append(try data.littleUInt32(at: child + 28))
                    } else if type == 53, length >= 40 {
                        let entries = Int(try data.littleUInt32(at: child + 28))
                        guard 40 + entries * 12 <= length else { throw PodBridgeError.invalidDatabase }
                        var sum: UInt32 = 0
                        for index in 0..<entries { sum += try data.littleUInt32(at: child + 48 + index * 12) }
                        jumpCounts.append(sum)
                    }
                    child += length
                }
                return (
                    !sortCounts.isEmpty && sortCounts.allSatisfy { $0 == members },
                    !jumpCounts.isEmpty && jumpCounts.allSatisfy { $0 == members }
                )
            }
            playlist += total
        }
        return (false, false)
    }

    // MARK: - Serialization and device identity

    /// Serializes a complete library and signs it for the selected device.
    static func build(library: ClassicLibrary, firewireID: Data, databaseID: UInt64) throws -> Data {
        guard firewireID.isEmpty || firewireID.count == 8 else { throw PodBridgeError.missingFirewireID }
        var root = BinaryWriter()
        root.tag("mhbd")
        root.u32(244)
        root.u32(0)
        root.u32(1)
        root.u32(0x30)
        root.u32(5)
        root.u64(databaseID)
        root.u16(2)
        root.u16(0)
        root.u64(databaseID ^ 0x504F_4442_5249_4447)
        root.u32(0)
        root.u16(0)
        root.zeros(20)
        root.u16(0x6e65)
        root.u64(databaseID)
        root.u32(0)
        root.u32(0)
        root.zeros(20)
        root.zeros(244 - root.count)

        let rootLibraryID = databaseID ^ 0x504F_4442_5249_4447
        root.bytes(trackSection(library.tracks, rootLibraryID: rootLibraryID))
        root.bytes(playlistSection(library, type: 3))
        root.bytes(playlistSection(library, type: 2))
        root.bytes(albumSection(library.tracks))
        root.bytes(artistSection(library.tracks))
        root.patchU32(UInt32(root.count), at: 8)
        return try Hash58.sign(root.data, firewireID: firewireID)
    }

    /// Reads and validates the 16-hex-digit FireWire ID from iPod metadata.
    static func firewireID(at root: URL) throws -> Data {
        let sysInfo = root.appendingPathComponent("iPod_Control/Device/SysInfo")
        if let text = try? String(contentsOf: sysInfo, encoding: .utf8),
           let value = text.split(whereSeparator: \.isNewline).first(where: {
               $0.lowercased().hasPrefix("firewireguid:")
           }), let colon = value.firstIndex(of: ":"),
           let id = decodeFirewireID(String(value[value.index(after: colon)...])) {
            cacheFirewireID(id, root: root)
            return id
        }

        let extended = root.appendingPathComponent("iPod_Control/Device/SysInfoExtended")
        if let plistData = try? Data(contentsOf: extended),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            for key in ["FireWireGUID", "FirewireGuid", "FirewireGUID"] {
                if let value = plist[key] as? String, let id = decodeFirewireID(value) {
                    cacheFirewireID(id, root: root)
                    return id
                }
            }
        }
        let cache = UserDefaults.standard.dictionary(forKey: "PodBridge.cachedFirewireIDs") as? [String: String]
        if let value = cache?[root.lastPathComponent], let id = decodeFirewireID(value) {
            AppLogger.database("Using cached FireWire GUID for destination=\(root.lastPathComponent)", level: .info)
            return id
        }
        throw PodBridgeError.missingFirewireID
    }

    private static func cacheFirewireID(_ id: Data, root: URL) {
        let key = "PodBridge.cachedFirewireIDs"
        var cache = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        cache[root.lastPathComponent] = id.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(cache, forKey: key)
    }

    /// Stores a validated FireWire ID in the destination's SysInfo file.
    static func storeFirewireID(_ value: String, root: URL) throws {
        guard let id = decodeFirewireID(value) else { throw PodBridgeError.invalidFirewireID }
        cacheFirewireID(id, root: root)
        let sysInfo = root.appendingPathComponent("iPod_Control/Device/SysInfo")
        let existing = (try? String(contentsOf: sysInfo, encoding: .utf8)) ?? ""
        let preservedLines = existing.split(whereSeparator: \.isNewline).filter {
            !$0.lowercased().hasPrefix("firewireguid:")
        }.map(String.init)
        let hexID = id.map { String(format: "%02x", $0) }.joined()
        let updated = (preservedLines + ["FirewireGuid: 0x\(hexID)"]).joined(separator: "\n") + "\n"
        do {
            try updated.write(to: sysInfo, atomically: true, encoding: .utf8)
            AppLogger.database("Persisted FireWire GUID in SysInfo", level: .info)
        } catch {
            // The local cache still lets this iPhone write safely when a file
            // provider does not allow updating SysInfo itself.
            AppLogger.database("Could not persist FireWire GUID in SysInfo error=\(error.localizedDescription)", level: .error)
        }
    }

    private static func decodeFirewireID(_ value: String) -> Data? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard hex.count == 16 else { return nil }
        var result = Data()
        var index = hex.startIndex
        for _ in 0..<8 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    /// Re-signs an existing database without changing its parsed library.
    static func resigning(existing: Data, firewireID: Data) throws -> EditResult {
        let library = try parse(existing)
        let signed = try Hash58.sign(existing, firewireID: firewireID)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard try parse(signed) == library,
              diagnostics.masterPlaylistFound,
              diagnostics.masterPlaylistMembers == library.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return EditResult(data: signed, library: library)
    }

    private static func parseTracks(_ data: Data, section: Range<Int>) throws -> [ClassicTrack] {
        let mhsdHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + mhsdHeader
        guard data.ascii(at: list, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        var cursor = list + Int(try data.littleUInt32(at: list + 4))
        var tracks: [ClassicTrack] = []
        while cursor + 16 <= section.upperBound, data.ascii(at: cursor, length: 4) == "mhit" {
            let header = Int(try data.littleUInt32(at: cursor + 4))
            let total = Int(try data.littleUInt32(at: cursor + 8))
            guard header >= 156, total >= header, cursor + total <= section.upperBound else { throw PodBridgeError.invalidDatabase }
            var strings: [UInt32: String] = [:]
            var child = cursor + header
            while child + 40 <= cursor + total, data.ascii(at: child, length: 4) == "mhod" {
                let length = Int(try data.littleUInt32(at: child + 8))
                let type = try data.littleUInt32(at: child + 12)
                guard length >= 24, child + length <= cursor + total else { throw PodBridgeError.invalidDatabase }
                if length >= 40 {
                    let stringLength = min(Int(try data.littleUInt32(at: child + 28)), length - 40)
                    strings[type] = String(data: data[(child + 40)..<(child + 40 + stringLength)], encoding: .utf16LittleEndian)
                }
                child += length
            }
            tracks.append(ClassicTrack(
                id: try data.littleUInt32(at: cursor + 0x10),
                databaseID: try data.littleUInt64(at: cursor + 0x70),
                title: strings[1] ?? "Unknown Track",
                artist: strings[4] ?? "Unknown Artist",
                album: strings[3] ?? "Unknown Album",
                genre: strings[5] ?? "",
                fileType: strings[6] ?? "AAC audio file",
                ipodPath: strings[2] ?? "",
                byteCount: try data.littleUInt32(at: cursor + 0x24),
                durationMS: try data.littleUInt32(at: cursor + 0x28),
                trackNumber: try data.littleUInt32(at: cursor + 0x2c),
                year: try data.littleUInt32(at: cursor + 0x34),
                bitrate: try data.littleUInt32(at: cursor + 0x38),
                sampleRate: try data.littleUInt32(at: cursor + 0x3c) >> 16,
                dateAdded: try data.littleUInt32(at: cursor + 0x68),
                albumID: header >= 0x124 ? try data.littleUInt32(at: cursor + 0x120) : 0,
                artistID: header >= 0x1e4 ? try data.littleUInt32(at: cursor + 0x1e0) : 0,
                artworkImageID: header >= 0x164 ? try data.littleUInt32(at: cursor + 0x160) : 0,
                artworkByteCount: header >= 0x84 ? try data.littleUInt32(at: cursor + 0x80) : 0,
                artworkData: nil,
                sourceURL: nil,
                sortTitle: strings[27] ?? "",
                sortArtist: strings[23] ?? "",
                sortAlbum: strings[28] ?? "",
                sortAlbumArtist: strings[29] ?? "",
                albumArtist: strings[22] ?? "",
                compilation: data[cursor + 0x1e] != 0
            ))
            cursor += total
        }
        return tracks
    }

    private struct TopLevelSection {
        let type: UInt32
        let range: Range<Int>
    }

    private static func topLevelSections(_ data: Data, start: Int) throws -> [TopLevelSection] {
        var sections: [TopLevelSection] = []
        var cursor = start
        while cursor + 16 <= data.count, data.ascii(at: cursor, length: 4) == "mhsd" {
            let length = Int(try data.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= data.count else { throw PodBridgeError.invalidDatabase }
            sections.append(TopLevelSection(type: try data.littleUInt32(at: cursor + 12), range: cursor..<(cursor + length)))
            cursor += length
        }
        guard cursor == data.count else { throw PodBridgeError.invalidDatabase }
        return sections
    }

    private static func trackSectionRemoving(_ data: Data, range: Range<Int>, trackID: UInt32) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var removed = 0
        while cursor + 16 <= source.count, source.ascii(at: cursor, length: 4) == "mhit" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if try source.littleUInt32(at: cursor + 0x10) == trackID {
                removed += 1
            } else {
                output.append(source[cursor..<(cursor + length)])
            }
            cursor += length
        }
        guard removed == 1, cursor == source.count else { throw PodBridgeError.invalidDatabase }
        let oldCount = try source.littleUInt32(at: listOffset + 8)
        guard oldCount > 0 else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldCount - 1, at: listOffset + 8)
        return output
    }

    private static func trackSectionEditing(_ data: Data, range: Range<Int>, track: ClassicTrack) throws -> Data {
        try trackSectionEditing(data, range: range, tracksByID: [track.id: track])
    }

    private static func trackSectionEditing(
        _ data: Data,
        range: Range<Int>,
        tracksByID: [UInt32: ClassicTrack]
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var edited = Set<UInt32>()
        while cursor + 16 <= source.count, source.ascii(at: cursor, length: 4) == "mhit" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            let trackID = try record.littleUInt32(at: 0x10)
            if let track = tracksByID[trackID] {
                output.append(try trackRecordEditing(record, track: track))
                edited.insert(trackID)
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, edited == Set(tracksByID.keys) else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func trackRecordEditing(_ source: Data, track: ClassicTrack) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        guard header >= 0x1e4, header <= source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        try output.setLittleUInt32(track.trackNumber, at: 0x2c)
        try output.setLittleUInt32(track.year, at: 0x34)
        try output.setLittleUInt32(track.albumID, at: 0x120)
        try output.setLittleUInt32(track.artistID, at: 0x1e0)
        output[0x1e] = track.compilation ? 1 : 0
        if track.artworkImageID != 0 {
            try output.setLittleUInt16(1, at: 0x7c)
            try output.setLittleUInt32(track.artworkByteCount, at: 0x80)
            output[0xa4] = 1
            try output.setLittleUInt32(track.artworkImageID, at: 0x160)
        }
        let desired: [UInt32: String] = [
            1: track.title,
            4: track.artist,
            3: track.album,
            5: track.genre,
            27: track.sortTitle,
            23: track.sortArtist,
            28: track.sortAlbum,
            29: track.sortAlbumArtist,
            22: track.albumArtist
        ]
        var handled = Set<UInt32>()
        var childCount: UInt32 = 0
        var cursor = header
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod",
               let type = try? child.littleUInt32(at: 12),
               let value = desired[type] {
                if handled.insert(type).inserted, !value.isEmpty {
                    output.append(stringObject(type: type, value: value))
                    childCount += 1
                }
            } else {
                output.append(child)
                childCount += 1
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        for type in desired.keys.sorted() where !handled.contains(type) {
            if let value = desired[type], !value.isEmpty {
                output.append(stringObject(type: type, value: value))
                childCount += 1
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(childCount, at: 12)
        return output
    }

    private static func playlistSectionResorting(_ data: Data, range: Range<Int>, tracks: [ClassicTrack]) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var masterFound = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            if try record.littleUInt32(at: 20) != 0 {
                guard !masterFound else { throw PodBridgeError.invalidDatabase }
                output.append(try masterPlaylistRecordResorting(record, tracks: tracks))
                masterFound = true
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, masterFound else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func masterPlaylistRecordResorting(_ source: Data, tracks: [ClassicTrack]) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        var output = Data(source.prefix(header))
        var cursor = header
        var orders: [UInt32: [Int]] = [:]
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod", length >= 72, try child.littleUInt32(at: 12) == 52 {
                let type = try child.littleUInt32(at: 24)
                let order = try resortedOrder(child, sortType: type, tracks: tracks)
                orders[type] = order
                output.append(try updatedSortIndex(child, order: order))
            } else if child.ascii(at: 0, length: 4) == "mhod", length >= 40, try child.littleUInt32(at: 12) == 53 {
                let type = try child.littleUInt32(at: 24)
                let order = orders[type] ?? Array(tracks.indices)
                output.append(jumpTableObject(type: type, order: order, tracks: tracks) {
                    jumpValue($0, sortType: type)
                })
            } else {
                output.append(child)
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func resortedOrder(_ source: Data, sortType: UInt32, tracks: [ClassicTrack]) throws -> [Int] {
        let count = Int(try source.littleUInt32(at: 28))
        guard count == tracks.count, 72 + count * 4 <= source.count else { throw PodBridgeError.invalidDatabase }
        if [UInt32(3), 4, 5, 7].contains(sortType) {
            return tracks.enumerated().sorted {
                compareTracks($0.element, $1.element, sortType: sortType) == .orderedAscending
            }.map(\.offset)
        }
        var order: [Int] = []
        for offset in 0..<count {
            let index = Int(try source.littleUInt32(at: 72 + offset * 4))
            guard tracks.indices.contains(index) else { throw PodBridgeError.invalidDatabase }
            order.append(index)
        }
        guard Set(order).count == tracks.count else { throw PodBridgeError.invalidDatabase }
        return order
    }

    private static func playlistSectionRenaming(
        _ data: Data,
        range: Range<Int>,
        playlistIndex: Int,
        name: String
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var userIndex = 0
        var renamed = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            if try record.littleUInt32(at: 20) == 0 {
                if userIndex == playlistIndex {
                    output.append(try playlistRecordRenaming(record, name: name))
                    renamed = true
                } else {
                    output.append(record)
                }
                userIndex += 1
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, renamed else { throw PodBridgeError.playlistNotFound }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func playlistSectionRemovingPlaylist(
        _ data: Data,
        range: Range<Int>,
        playlistIndex: Int
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var userIndex = 0
        var removed = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else {
                throw PodBridgeError.invalidDatabase
            }
            let isMaster = try source.littleUInt32(at: cursor + 20) != 0
            if !isMaster, userIndex == playlistIndex {
                removed = true
            } else {
                output.append(source[cursor..<(cursor + length)])
            }
            if !isMaster { userIndex += 1 }
            cursor += length
        }
        guard cursor == source.count, removed else { throw PodBridgeError.playlistNotFound }
        let oldCount = try source.littleUInt32(at: listOffset + 8)
        guard oldCount > 1 else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldCount - 1, at: listOffset + 8)
        return output
    }

    private static func playlistRecordRenaming(_ source: Data, name: String) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        var output = Data(source.prefix(header))
        var cursor = header
        var replaced = false
        var childCount = try source.littleUInt32(at: 12)
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if !replaced,
               child.ascii(at: 0, length: 4) == "mhod",
               try child.littleUInt32(at: 12) == 1 {
                output.append(stringObject(type: 1, value: name))
                replaced = true
            } else {
                output.append(child)
            }
            cursor += length
        }
        if !replaced {
            output.append(stringObject(type: 1, value: name))
            childCount += 1
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(childCount, at: 12)
        return output
    }

    private static func albumSectionEditing(
        _ data: Data,
        range: Range<Int>,
        originalTrack: ClassicTrack,
        updatedTrack: ClassicTrack,
        allTracks: [ClassicTrack]
    ) throws -> Data {
        try entitySectionEditing(
            data,
            range: range,
            listTag: "mhla",
            recordTag: "mhia",
            oldID: originalTrack.albumID,
            newID: updatedTrack.albumID,
            oldStillUsed: allTracks.contains { $0.id != updatedTrack.id && $0.albumID == originalTrack.albumID },
            newRecord: albumRecord(updatedTrack)
        )
    }

    private static func artistSectionEditing(
        _ data: Data,
        range: Range<Int>,
        originalTrack: ClassicTrack,
        updatedTrack: ClassicTrack,
        allTracks: [ClassicTrack]
    ) throws -> Data {
        try entitySectionEditing(
            data,
            range: range,
            listTag: "mhli",
            recordTag: "mhii",
            oldID: originalTrack.artistID,
            newID: updatedTrack.artistID,
            oldStillUsed: allTracks.contains { $0.id != updatedTrack.id && $0.artistID == originalTrack.artistID },
            newRecord: artistRecord(updatedTrack)
        )
    }

    private static func entitySectionEditing(
        _ data: Data,
        range: Range<Int>,
        listTag: String,
        recordTag: String,
        oldID: UInt32,
        newID: UInt32,
        oldStillUsed: Bool,
        newRecord: Data
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == listTag else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var count: UInt32 = 0
        var newFound = false
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let id = try source.littleUInt32(at: cursor + 16)
            if id == oldID, oldID != newID, !oldStillUsed {
                // Drop the entity that became orphaned after the edit.
            } else {
                output.append(source[cursor..<(cursor + length)])
                count += 1
                if id == newID { newFound = true }
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        if !newFound {
            output.append(newRecord)
            count += 1
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(count, at: listOffset + 8)
        return output
    }

    private static func entitySectionReplacingRecord(
        _ data: Data,
        range: Range<Int>,
        listTag: String,
        recordTag: String,
        entityID: UInt32,
        replacement: Data
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == listTag else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var replaced = false
        var outputCount: UInt32 = 0
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if try source.littleUInt32(at: cursor + 16) == entityID {
                // Some older libraries contain duplicate entity records with the same ID.
                // Replace the logical entity once and discard the duplicate copies.
                if !replaced {
                    output.append(replacement)
                    outputCount += 1
                    replaced = true
                }
            } else {
                output.append(source[cursor..<(cursor + length)])
                outputCount += 1
            }
            cursor += length
        }
        guard cursor == source.count, replaced else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(outputCount, at: listOffset + 8)
        return output
    }

    private static func entitySectionMergingRecords(
        _ data: Data,
        range: Range<Int>,
        listTag: String,
        recordTag: String,
        targetID: UInt32,
        orphanedIDs: Set<UInt32>,
        replacement: Data
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == listTag else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var insertedReplacement = false
        var outputCount: UInt32 = 0
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else {
                throw PodBridgeError.invalidDatabase
            }
            let id = try source.littleUInt32(at: cursor + 16)
            if id == targetID {
                if !insertedReplacement {
                    output.append(replacement)
                    outputCount += 1
                    insertedReplacement = true
                }
            } else if orphanedIDs.contains(id) {
                // Every track that used this duplicate ID now points at targetID, so the
                // obsolete entity must not remain as a ghost album or artist card.
            } else {
                output.append(source[cursor..<(cursor + length)])
                outputCount += 1
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        if !insertedReplacement {
            output.append(replacement)
            outputCount += 1
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(outputCount, at: listOffset + 8)
        return output
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

    private static func entitySectionRemoving(
        _ data: Data,
        range: Range<Int>,
        listTag: String,
        recordTag: String,
        entityID: UInt32
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: sectionHeader, length: 4) == listTag else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: sectionHeader + 4))
        var cursor = sectionHeader + listHeader
        var output = Data(source.prefix(cursor))
        var removed: UInt32 = 0
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if try source.littleUInt32(at: cursor + 16) == entityID {
                removed += 1
            } else {
                output.append(source[cursor..<(cursor + length)])
            }
            cursor += length
        }
        guard cursor == source.count, removed == 1 else { throw PodBridgeError.invalidDatabase }
        let oldCount = try source.littleUInt32(at: sectionHeader + 8)
        guard oldCount >= removed else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldCount - removed, at: sectionHeader + 8)
        return output
    }

    private static func playlistSectionRemoving(
        _ data: Data,
        range: Range<Int>,
        trackID: UInt32,
        removedTrackIndex: Int,
        remainingTracks: [ClassicTrack]
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var masterFound = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            let isMaster = try record.littleUInt32(at: 20) != 0
            if isMaster {
                guard !masterFound else { throw PodBridgeError.invalidDatabase }
                masterFound = true
            }
            output.append(try playlistRecordRemoving(
                record,
                trackID: trackID,
                removedTrackIndex: removedTrackIndex,
                remainingTracks: remainingTracks,
                isMaster: isMaster
            ))
            cursor += length
        }
        guard masterFound, cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func playlistRecordRemoving(
        _ source: Data,
        trackID: UInt32,
        removedTrackIndex: Int,
        remainingTracks: [ClassicTrack],
        isMaster: Bool
    ) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        let total = Int(try source.littleUInt32(at: 8))
        guard header >= 24, total == source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        var cursor = header
        var removedMembers: UInt32 = 0
        var nextMemberOrder = 0
        var sortOrders: [UInt32: [Int]] = [:]
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            var child = Data(source[cursor..<(cursor + length)])
            let tag = child.ascii(at: 0, length: 4)
            if tag == "mhip", length >= 28 {
                if try child.littleUInt32(at: 24) == trackID {
                    removedMembers += 1
                } else {
                    child = try playlistItem(child, settingOrder: nextMemberOrder)
                    output.append(child)
                    nextMemberOrder += 1
                }
            } else if isMaster, tag == "mhod", length >= 72, try child.littleUInt32(at: 12) == 52 {
                let sortType = try child.littleUInt32(at: 24)
                let order = try sortOrderRemoving(child, removedTrackIndex: removedTrackIndex, remainingTrackCount: remainingTracks.count)
                sortOrders[sortType] = order
                output.append(try updatedSortIndex(child, order: order))
            } else if isMaster, tag == "mhod", length >= 40, try child.littleUInt32(at: 12) == 53 {
                let sortType = try child.littleUInt32(at: 24)
                let order = sortOrders[sortType] ?? Array(remainingTracks.indices)
                output.append(jumpTableObject(
                    type: sortType,
                    order: order,
                    tracks: remainingTracks,
                    key: { jumpValue($0, sortType: sortType) }
                ))
            } else {
                output.append(child)
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        if isMaster {
            guard removedMembers == 1 else { throw PodBridgeError.databaseVerificationFailed }
        }
        let oldMembers = try source.littleUInt32(at: 16)
        guard removedMembers <= oldMembers else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldMembers - removedMembers, at: 16)
        return output
    }

    private static func sortOrderRemoving(
        _ source: Data,
        removedTrackIndex: Int,
        remainingTrackCount: Int
    ) throws -> [Int] {
        let storedCount = Int(try source.littleUInt32(at: 28))
        guard storedCount == remainingTrackCount + 1,
              removedTrackIndex >= 0, removedTrackIndex < storedCount,
              72 + storedCount * 4 <= source.count else { throw PodBridgeError.invalidDatabase }
        var order: [Int] = []
        for offset in 0..<storedCount {
            let index = Int(try source.littleUInt32(at: 72 + offset * 4))
            guard index >= 0, index < storedCount else { throw PodBridgeError.invalidDatabase }
            if index == removedTrackIndex { continue }
            order.append(index > removedTrackIndex ? index - 1 : index)
        }
        guard order.count == remainingTrackCount, Set(order).count == remainingTrackCount else {
            throw PodBridgeError.invalidDatabase
        }
        return order
    }

    private static func playlistItem(_ source: Data, settingOrder order: Int) throws -> Data {
        var output = source
        let header = Int(try output.littleUInt32(at: 4))
        var cursor = header
        while cursor + 28 <= output.count {
            let length = Int(try output.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= output.count else { throw PodBridgeError.invalidDatabase }
            if output.ascii(at: cursor, length: 4) == "mhod",
               try output.littleUInt32(at: cursor + 12) == 100 {
                try output.setLittleUInt32(UInt32(order), at: cursor + 24)
                return output
            }
            cursor += length
        }
        return output
    }

    private static func mergedTrackSection(
        _ data: Data,
        range: Range<Int>,
        additions: [ClassicTrack],
        rootLibraryID: UInt64
    ) throws -> Data {
        var section = Data(data[range])
        let sectionHeader = Int(try section.littleUInt32(at: 4))
        guard section.ascii(at: sectionHeader, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        let oldCount = try section.littleUInt32(at: sectionHeader + 8)
        for track in additions { section.append(trackRecord(track, rootLibraryID: rootLibraryID)) }
        try section.setLittleUInt32(UInt32(section.count), at: 8)
        try section.setLittleUInt32(oldCount + UInt32(additions.count), at: sectionHeader + 8)
        return section
    }

    private static func mergedPlaylistSection(
        _ data: Data,
        range: Range<Int>,
        additions: [ClassicTrack],
        tracks: [ClassicTrack],
        appendedPlaylists: [ClassicPlaylist]
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var records: [Data] = []
        var masterFound = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let master = try source.littleUInt32(at: cursor + 20) != 0
            let record = Data(source[cursor..<(cursor + length)])
            if master {
                guard !masterFound else { throw PodBridgeError.invalidDatabase }
                records.append(try mergedMasterPlaylistRecord(record, additions: additions, tracks: tracks))
                masterFound = true
            } else {
                records.append(record)
            }
            cursor += length
        }
        guard masterFound else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(listOffset + listHeader))
        records.forEach { output.append($0) }
        appendedPlaylists.forEach {
            output.append(playlistRecord(name: $0.name, ids: $0.trackIDs, master: false, tracks: []))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(UInt32(records.count + appendedPlaylists.count), at: listOffset + 8)
        return output
    }

    private static func mergedMasterPlaylistRecord(
        _ source: Data,
        additions: [ClassicTrack],
        tracks: [ClassicTrack]
    ) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        let total = Int(try source.littleUInt32(at: 8))
        guard header >= 24, total == source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        var cursor = header
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod",
               length >= 72,
               try child.littleUInt32(at: 12) == 52 {
                let sortType = try child.littleUInt32(at: 24)
                let order = try mergedSortOrder(
                    child,
                    sortType: sortType,
                    additions: additions,
                    tracks: tracks
                )
                output.append(try updatedSortIndex(child, order: order))
            } else if child.ascii(at: 0, length: 4) == "mhod",
                      length >= 40,
                      try child.littleUInt32(at: 12) == 53 {
                output.append(try updatedJumpTable(child, additions: additions, tracks: tracks))
            } else {
                output.append(child)
            }
            cursor += length
        }
        let oldMembers = try source.littleUInt32(at: 16)
        for (offset, track) in additions.enumerated() {
            output.append(playlistItem(order: Int(oldMembers) + offset, trackID: track.id))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldMembers + UInt32(additions.count), at: 16)
        return output
    }

    private static func updatedSortIndex(_ source: Data, order: [Int]) throws -> Data {
        var updated = Data(source.prefix(72))
        for index in order {
            var value = UInt32(index).littleEndian
            withUnsafeBytes(of: &value) { updated.append(contentsOf: $0) }
        }
        try updated.setLittleUInt32(UInt32(updated.count), at: 8)
        try updated.setLittleUInt32(UInt32(order.count), at: 28)
        return updated
    }

    private static func mergedSortOrder(
        _ source: Data,
        sortType: UInt32,
        additions: [ClassicTrack],
        tracks: [ClassicTrack]
    ) throws -> [Int] {
        let oldTrackCount = tracks.count - additions.count
        let storedCount = Int(try source.littleUInt32(at: 28))
        guard oldTrackCount >= 0,
              storedCount == oldTrackCount,
              72 + storedCount * 4 <= source.count else {
            throw PodBridgeError.invalidDatabase
        }
        var order: [Int] = []
        for offset in 0..<storedCount {
            let index = Int(try source.littleUInt32(at: 72 + offset * 4))
            guard index >= 0, index < oldTrackCount else { throw PodBridgeError.invalidDatabase }
            order.append(index)
        }
        guard Set(order).count == oldTrackCount else { throw PodBridgeError.invalidDatabase }

        let knownAppleSort = [UInt32(3), 4, 5, 7].contains(sortType)
        for newIndex in oldTrackCount..<tracks.count {
            guard knownAppleSort else {
                order.append(newIndex)
                continue
            }
            let insertion = order.firstIndex { existingIndex in
                compareTracks(tracks[newIndex], tracks[existingIndex], sortType: sortType) == .orderedAscending
            } ?? order.endIndex
            order.insert(newIndex, at: insertion)
        }
        return order
    }

    private static func compareTracks(_ lhs: ClassicTrack, _ rhs: ClassicTrack, sortType: UInt32) -> ComparisonResult {
        let lhsStrings = sortComponents(lhs, sortType: sortType)
        let rhsStrings = sortComponents(rhs, sortType: sortType)
        for (left, right) in zip(lhsStrings, rhsStrings) {
            let comparison = compareAppleStrings(left, right)
            if comparison != .orderedSame { return comparison }
        }
        if [UInt32(4), 5, 7].contains(sortType), lhs.trackNumber != rhs.trackNumber {
            return lhs.trackNumber < rhs.trackNumber ? .orderedAscending : .orderedDescending
        }
        return compareAppleStrings(effectiveTitle(lhs), effectiveTitle(rhs))
    }

    private static func sortComponents(_ track: ClassicTrack, sortType: UInt32) -> [String] {
        switch sortType {
        case 3:
            return [effectiveTitle(track)]
        case 4:
            return [effectiveAlbum(track)]
        case 5:
            return [effectiveArtist(track), effectiveAlbum(track)]
        case 7:
            return [track.genre, effectiveArtist(track), effectiveAlbum(track)]
        default:
            return []
        }
    }

    private static func effectiveTitle(_ track: ClassicTrack) -> String {
        track.sortTitle.isEmpty ? track.title : track.sortTitle
    }

    private static func effectiveAlbum(_ track: ClassicTrack) -> String {
        track.sortAlbum.isEmpty ? articleIndependentSortValue(track.album) : track.sortAlbum
    }

    private static func effectiveArtist(_ track: ClassicTrack) -> String {
        if !track.sortArtist.isEmpty { return track.sortArtist }
        return articleIndependentSortValue(track.artist)
    }

    private static func albumGroupingArtist(_ track: ClassicTrack) -> String {
        track.albumArtist.isEmpty ? track.artist : track.albumArtist
    }

    private static func articleIndependentSortValue(_ value: String) -> String {
        let leadingArticles = ["The ", "An ", "A "]
        for article in leadingArticles where value.range(
            of: article,
            options: [.caseInsensitive, .anchored],
            range: value.startIndex..<value.endIndex,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil {
            return String(value.dropFirst(article.count))
        }
        return value
    }

    private static func compareAppleStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsCategory = appleSortCategory(lhs)
        let rhsCategory = appleSortCategory(rhs)
        if lhsCategory != rhsCategory {
            // Apple Classic order observed in the original database:
            // alphabetic buckets, then the numeric bucket, then empty/no-letter values.
            return lhsCategory < rhsCategory ? .orderedAscending : .orderedDescending
        }
        return lhs.localizedCaseInsensitiveCompare(rhs)
    }

    private static func appleSortCategory(_ value: String) -> Int {
        guard let first = firstAlphanumeric(value) else { return 2 }
        return first.isNumber ? 1 : 0
    }

    private static func firstAlphanumeric(_ value: String) -> Character? {
        value.first { $0.isLetter || $0.isNumber }
    }

    private struct JumpEntry {
        var letter: UInt16
        var reserved: UInt16
        var start: UInt32
        var count: UInt32
    }

    private static func updatedJumpTable(_ source: Data, additions: [ClassicTrack], tracks: [ClassicTrack]) throws -> Data {
        let sortType = try source.littleUInt32(at: 24)
        let entryCount = Int(try source.littleUInt32(at: 28))
        guard 40 + entryCount * 12 <= source.count else { throw PodBridgeError.invalidDatabase }
        var entries: [JumpEntry] = []
        for index in 0..<entryCount {
            let offset = 40 + index * 12
            entries.append(JumpEntry(
                letter: try source.littleUInt16(at: offset),
                reserved: try source.littleUInt16(at: offset + 2),
                start: try source.littleUInt32(at: offset + 4),
                count: try source.littleUInt32(at: offset + 8)
            ))
        }
        if entries.isEmpty, !tracks.isEmpty {
            let sorted = tracks.sorted {
                jumpValue($0, sortType: sortType).localizedCaseInsensitiveCompare(jumpValue($1, sortType: sortType)) == .orderedAscending
            }
            for track in sorted {
                let letter = jumpLetter(jumpValue(track, sortType: sortType))
                if let last = entries.indices.last, entries[last].letter == letter {
                    entries[last].count += 1
                } else {
                    entries.append(JumpEntry(letter: letter, reserved: 0, start: 0, count: 1))
                }
            }
        } else {
        for track in additions {
            let letter = jumpLetter(jumpValue(track, sortType: sortType))
            if let index = entries.firstIndex(where: { $0.letter == letter }) {
                entries[index].count += 1
            } else {
                let insertion = entries.firstIndex {
                    jumpBucketRank($0.letter) > jumpBucketRank(letter)
                } ?? entries.endIndex
                entries.insert(JumpEntry(letter: letter, reserved: 0, start: 0, count: 1), at: insertion)
            }
        }
        }
        var runningStart: UInt32 = 0
        var updated = Data(source.prefix(40))
        for var entry in entries {
            entry.start = runningStart
            var letter = entry.letter.littleEndian
            var reserved = entry.reserved.littleEndian
            var start = entry.start.littleEndian
            var count = entry.count.littleEndian
            withUnsafeBytes(of: &letter) { updated.append(contentsOf: $0) }
            withUnsafeBytes(of: &reserved) { updated.append(contentsOf: $0) }
            withUnsafeBytes(of: &start) { updated.append(contentsOf: $0) }
            withUnsafeBytes(of: &count) { updated.append(contentsOf: $0) }
            runningStart += entry.count
        }
        try updated.setLittleUInt32(UInt32(updated.count), at: 8)
        try updated.setLittleUInt32(UInt32(entries.count), at: 28)
        return updated
    }

    private static func jumpBucketRank(_ letter: UInt16) -> Int {
        if letter >= 65, letter <= 90 { return Int(letter - 65) }
        if letter == 48 { return 26 }
        return 27
    }

    private static func jumpValue(_ track: ClassicTrack, sortType: UInt32) -> String {
        switch sortType {
        case 3: effectiveTitle(track)
        case 4: effectiveAlbum(track)
        case 5: effectiveArtist(track)
        case 7: track.genre
        case 18: ""
        default: ""
        }
    }

    private static func jumpLetter(_ value: String) -> UInt16 {
        guard let character = firstAlphanumeric(value),
              let scalar = String(character).uppercased().unicodeScalars.first else { return 0 }
        if character.isNumber { return 48 }
        if scalar.value >= 65, scalar.value <= 90 { return UInt16(scalar.value) }
        // The Apple-generated database groups Cyrillic/non-Latin alphabetic
        // values before Latin A while exposing only A-Z/0 jump buckets.
        return 65
    }

    private static func mergedEntitySection(_ data: Data, range: Range<Int>, additions: [Data]) throws -> Data {
        var section = Data(data[range])
        let sectionHeader = Int(try section.littleUInt32(at: 4))
        guard sectionHeader + 12 <= section.count else { throw PodBridgeError.invalidDatabase }
        let oldCount = try section.littleUInt32(at: sectionHeader + 8)
        additions.forEach { section.append($0) }
        try section.setLittleUInt32(UInt32(section.count), at: 8)
        try section.setLittleUInt32(oldCount + UInt32(additions.count), at: sectionHeader + 8)
        return section
    }

    private struct ParsedPlaylist {
        let playlist: ClassicPlaylist
        let isMaster: Bool
    }

    private static func parsePlaylistRecords(_ data: Data, section: Range<Int>) throws -> [ParsedPlaylist] {
        let sectionHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + sectionHeader
        guard data.ascii(at: list, length: 4) == "mhlp" else { return [] }
        var cursor = list + Int(try data.littleUInt32(at: list + 4))
        var result: [ParsedPlaylist] = []
        while cursor + 20 <= section.upperBound, data.ascii(at: cursor, length: 4) == "mhyp" {
            let header = Int(try data.littleUInt32(at: cursor + 4))
            let total = Int(try data.littleUInt32(at: cursor + 8))
            guard total >= header, cursor + total <= section.upperBound else { throw PodBridgeError.invalidDatabase }
            var name = "Playlist"
            var ids: [UInt32] = []
            var child = cursor + header
            while child + 16 <= cursor + total {
                let tag = data.ascii(at: child, length: 4)
                let length = Int(try data.littleUInt32(at: child + 8))
                guard length > 0, child + length <= cursor + total else { break }
                if tag == "mhod", try data.littleUInt32(at: child + 12) == 1, length >= 40 {
                    let stringLength = min(Int(try data.littleUInt32(at: child + 28)), length - 40)
                    name = String(data: data[(child + 40)..<(child + 40 + stringLength)], encoding: .utf16LittleEndian) ?? name
                } else if tag == "mhip", length >= 28 {
                    ids.append(try data.littleUInt32(at: child + 24))
                }
                child += length
            }
            let isMaster: Bool
            if header >= 24 {
                isMaster = try data.littleUInt32(at: cursor + 20) != 0
            } else {
                isMaster = false
            }
            result.append(ParsedPlaylist(playlist: ClassicPlaylist(name: name, trackIDs: ids), isMaster: isMaster))
            cursor += total
        }
        return result
    }

    private static func trackSection(_ tracks: [ClassicTrack], rootLibraryID: UInt64) -> Data {
        var body = BinaryWriter()
        body.tag("mhlt"); body.u32(92); body.u32(UInt32(tracks.count)); body.zeros(80)
        for track in tracks { body.bytes(trackRecord(track, rootLibraryID: rootLibraryID)) }
        return section(type: 1, body: body.data)
    }

    private static func trackRecord(_ track: ClassicTrack, rootLibraryID: UInt64) -> Data {
        var writer = BinaryWriter()
        // Build a clean libgpod-compatible header. Copying the first old track's
        // header leaked MP3 flags into AAC tracks when the first library item was MP3.
        writer.tag("mhit"); writer.u32(0x248); writer.u32(0); writer.u32(0)
        writer.zeros(0x248 - 16)
        writer.patchU32(track.id, at: 0x10)
        writer.patchU32(1, at: 0x14)
        let format = trackFormat(track)
        writer.patchBytes(Data(format.marker.utf8), at: 0x18)
        writer.patchBytes(Data([format.type1, format.type2, track.compilation ? 1 : 0, 0]), at: 0x1c)
        writer.patchU32(track.dateAdded, at: 0x20)
        writer.patchU32(track.byteCount, at: 0x24)
        writer.patchU32(track.durationMS, at: 0x28)
        writer.patchU32(track.trackNumber, at: 0x2c)
        writer.patchU32(0, at: 0x30)
        writer.patchU32(track.year, at: 0x34)
        writer.patchU32(track.bitrate, at: 0x38)
        writer.patchU32(track.sampleRate << 16, at: 0x3c)
        writer.patchU32(track.dateAdded, at: 0x68)
        var dbid = BinaryWriter(); dbid.u64(track.databaseID)
        writer.patchBytes(dbid.data, at: 0x70)
        writer.patchU16(format.compressed ? 0xffff : 0, at: 0x7e)
        writer.patchU32(Float(track.sampleRate).bitPattern, at: 0x88)
        writer.patchU16(format.unknown144, at: 0x90)
        writer.patchBytes(Data([track.artworkImageID == 0 ? 2 : 1, 0, 0, 0]), at: 0xa4)
        writer.patchBytes(dbid.data, at: 0xa8)
        writer.patchBytes(Data([0, 0, 2, 0]), at: 0xb0)
        writer.patchU32(1, at: 0xd0)
        writer.patchU32(track.albumID, at: 0x120)
        var rootID = BinaryWriter(); rootID.u64(rootLibraryID)
        writer.patchBytes(rootID.data, at: 0x124)
        // iTunesDB stores the file size twice. This used to be written four bytes
        // late at 0x130, leaving the firmware-facing copy at 0x12c as zero.
        writer.patchU32(track.byteCount, at: 0x12c)
        writer.patchU32(0, at: 0x130)
        var magic = BinaryWriter(); magic.u64(0x0000_8080_8080_8080)
        writer.patchBytes(magic.data, at: 0x134)
        writer.patchU32(1, at: 0x168)
        writer.patchU32(track.artistID, at: 0x1e0)
        if track.artworkImageID != 0 {
            writer.patchU16(1, at: 0x7c)
            writer.patchU32(track.artworkByteCount, at: 0x80)
            writer.patchU32(track.artworkImageID, at: 0x160)
        }
        let strings: [(UInt32, String)] = [
            (1, track.title), (4, track.artist), (3, track.album), (5, track.genre),
            (6, track.fileType), (2, track.ipodPath), (27, track.sortTitle),
            (23, track.sortArtist), (28, track.sortAlbum), (29, track.sortAlbumArtist),
            (22, track.albumArtist)
        ].filter { !$0.1.isEmpty }
        for item in strings { writer.bytes(stringObject(type: item.0, value: item.1)) }
        writer.patchU32(UInt32(writer.count), at: 8)
        writer.patchU32(UInt32(strings.count), at: 12)
        return writer.data
    }

    private struct TrackFormat {
        let marker: String
        let type1: UInt8
        let type2: UInt8
        let compressed: Bool
        let unknown144: UInt16
    }

    private static func trackFormat(_ track: ClassicTrack) -> TrackFormat {
        let ext = track.ipodPath.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        let upper = String(ext.uppercased().prefix(4)).padding(toLength: 4, withPad: " ", startingAt: 0)
        let marker = String(upper.reversed())
        let description = track.fileType.lowercased()
        if ext == "mp3" {
            return TrackFormat(marker: marker, type1: 0, type2: 1, compressed: true, unknown144: 0x000c)
        }
        if description.contains("lossless") {
            return TrackFormat(marker: marker, type1: 0, type2: 0, compressed: true, unknown144: 0x003c)
        }
        if ["m4a", "m4b", "aac"].contains(ext) {
            return TrackFormat(marker: marker, type1: 1, type2: 0, compressed: true, unknown144: 0x0033)
        }
        return TrackFormat(marker: marker, type1: 0, type2: 0, compressed: false, unknown144: 0)
    }

    private static func playlistSection(_ library: ClassicLibrary, type: UInt32) -> Data {
        var list = BinaryWriter()
        list.tag("mhlp"); list.u32(92); list.u32(UInt32(library.playlists.count + 1)); list.zeros(80)
        list.bytes(playlistRecord(name: library.name, ids: library.tracks.map(\.id), master: true, tracks: library.tracks))
        for playlist in library.playlists {
            list.bytes(playlistRecord(name: playlist.name, ids: playlist.trackIDs, master: false, tracks: []))
        }
        return section(type: type, body: list.data)
    }

    private static func albumSection(_ tracks: [ClassicTrack]) -> Data {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert("\(albumGroupingArtist($0))\u{0}\($0.album)").inserted }
        var list = BinaryWriter()
        list.tag("mhla"); list.u32(92); list.u32(UInt32(unique.count)); list.zeros(80)
        unique.forEach { list.bytes(albumRecord($0)) }
        return section(type: 4, body: list.data)
    }

    private static func artistSection(_ tracks: [ClassicTrack]) -> Data {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.artist).inserted }
        var list = BinaryWriter()
        list.tag("mhli"); list.u32(92); list.u32(UInt32(unique.count)); list.zeros(80)
        unique.forEach { list.bytes(artistRecord($0)) }
        return section(type: 8, body: list.data)
    }

    private static func playlistRecord(name: String, ids: [UInt32], master: Bool, tracks: [ClassicTrack]) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhyp"); writer.u32(108); writer.u32(0); writer.u32(0)
        writer.u32(UInt32(ids.count)); writer.u32(master ? 1 : 0); writer.u32(AudioMetadataReader.macTime(Date()))
        writer.u64(UInt64.random(in: 1...UInt64.max)); writer.u32(0); writer.u16(1); writer.u16(0)
        writer.u32(master ? 10 : 1); writer.zeros(60)
        var children = 0
        writer.bytes(stringObject(type: 1, value: name)); children += 1
        if master {
            let indexTypes: [UInt32] = [3, 4, 5, 7, 18]
            for type in indexTypes {
                let order = type == 18
                    ? Array(tracks.indices)
                    : tracks.enumerated().sorted {
                        compareTracks($0.element, $1.element, sortType: type) == .orderedAscending
                    }.map(\.offset)
                writer.bytes(indexObject(type: type, order: order)); children += 1
                writer.bytes(jumpTableObject(
                    type: type,
                    order: order,
                    tracks: tracks,
                    key: { jumpValue($0, sortType: type) }
                )); children += 1
            }
        }
        for (offset, id) in ids.enumerated() { writer.bytes(playlistItem(order: offset, trackID: id)) }
        writer.patchU32(UInt32(writer.count), at: 8)
        writer.patchU32(UInt32(children), at: 12)
        return writer.data
    }

    private static func playlistItem(order: Int, trackID: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhip"); writer.u32(76); writer.u32(120); writer.u32(1)
        writer.u32(0); writer.u32(0); writer.u32(trackID)
        writer.u32(0); writer.u32(0); writer.zeros(40)
        writer.tag("mhod"); writer.u32(24); writer.u32(44); writer.u32(100); writer.zeros(8)
        writer.u32(UInt32(order)); writer.zeros(16)
        return writer.data
    }

    private static func indexObject(type: UInt32, order: [Int]) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhod"); writer.u32(24); writer.u32(UInt32(72 + order.count * 4)); writer.u32(52); writer.zeros(8)
        writer.u32(type); writer.u32(UInt32(order.count)); writer.zeros(40)
        for index in order { writer.u32(UInt32(index)) }
        return writer.data
    }

    private static func jumpTableObject(
        type: UInt32,
        order: [Int],
        tracks: [ClassicTrack],
        key: (ClassicTrack) -> String
    ) -> Data {
        var groups: [(letter: UInt16, start: UInt32, count: UInt32)] = []
        for (position, trackIndex) in order.enumerated() {
            let letter = jumpLetter(key(tracks[trackIndex]))
            if let last = groups.indices.last, groups[last].letter == letter {
                groups[last].count += 1
            } else {
                groups.append((letter, UInt32(position), 1))
            }
        }
        var writer = BinaryWriter()
        writer.tag("mhod"); writer.u32(24); writer.u32(UInt32(40 + groups.count * 12)); writer.u32(53); writer.zeros(8)
        writer.u32(type); writer.u32(UInt32(groups.count)); writer.zeros(8)
        for group in groups {
            writer.u16(group.letter); writer.u16(0); writer.u32(group.start); writer.u32(group.count)
        }
        return writer.data
    }

    private static func albumRecord(_ track: ClassicTrack) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhia"); writer.u32(88); writer.u32(0); writer.u32(2); writer.u32(track.albumID)
        writer.u64(track.databaseID); writer.u32(2); writer.zeros(56)
        writer.bytes(stringObject(type: 200, value: track.album))
        writer.bytes(stringObject(type: 201, value: albumGroupingArtist(track)))
        writer.patchU32(UInt32(writer.count), at: 8)
        return writer.data
    }

    private static func artistRecord(_ track: ClassicTrack) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhii"); writer.u32(80); writer.u32(0); writer.u32(1); writer.u32(track.artistID)
        writer.u64(track.databaseID); writer.u32(2); writer.zeros(48)
        writer.bytes(stringObject(type: 300, value: track.artist))
        writer.patchU32(UInt32(writer.count), at: 8)
        return writer.data
    }

    private static func stringObject(type: UInt32, value: String) -> Data {
        let text = value.data(using: .utf16LittleEndian) ?? Data()
        var writer = BinaryWriter()
        writer.tag("mhod"); writer.u32(24); writer.u32(UInt32(40 + text.count)); writer.u32(type); writer.zeros(8)
        writer.u32(1); writer.u32(UInt32(text.count)); writer.u32(1); writer.u32(0); writer.bytes(text)
        return writer.data
    }

    private static func section(type: UInt32, body: Data) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhsd"); writer.u32(96); writer.u32(UInt32(96 + body.count)); writer.u32(type); writer.zeros(80); writer.bytes(body)
        return writer.data
    }
}
