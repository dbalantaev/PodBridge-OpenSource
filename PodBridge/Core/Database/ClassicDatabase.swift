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
    /// Rating stored by iPod firmware on a 0...100 scale (20 points per star).
    var rating: UInt8 = 0
    var playCount: UInt32 = 0
    var skipCount: UInt32 = 0
    /// Seconds since 1904-01-01, as stored in iTunesDB.
    var lastPlayed: UInt32 = 0
    /// Seconds since 1904-01-01, as stored in iTunesDB.
    var lastSkipped: UInt32 = 0
    var albumID: UInt32 = 0
    var artistID: UInt32 = 0
    var artworkImageID: UInt32 = 0
    var artworkByteCount: UInt32 = 0
    var artworkData: Data?
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

    enum PendingPlaylistMember: Sendable, Equatable {
        case existingTrackID(UInt32)
        case additionIndex(Int)
    }

    /// A playlist to append during a merge, with members resolved after import.
    struct PendingPlaylist: Sendable {
        let name: String
        let members: [PendingPlaylistMember]

        init(name: String, additionIndices: [Int]) {
            self.name = name
            self.members = additionIndices.map(PendingPlaylistMember.additionIndex)
        }

        init(name: String, members: [PendingPlaylistMember]) {
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

}
