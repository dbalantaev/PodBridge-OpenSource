// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Value types returned by iPod library operations.
///
/// Keeping these contracts separate from the mutation pipeline makes call sites
/// discoverable without mixing data definitions with rollback implementation.
extension IPodSyncEngine {
    struct ExportResult: Sendable {
        let folderURL: URL
        let copiedTracks: Int
        let copiedBytes: UInt64
    }

    struct LibraryImportResult: Sendable {
        let library: ClassicLibrary
        let restoredTracks: Int
        let restoredPlaylists: Int
        let backupURL: URL
    }

    struct DeletionProgress: Sendable {
        let stage: String
        let completed: Int
        let total: Int
    }

    enum ExportError: LocalizedError {
        case missingAudio(String)
        case unsafeAudioPath
        case destinationIsIPod
        case copyVerificationFailed
        case metadataRewriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAudio(let title):
                "The audio file for \(title) is missing from the iPod. Nothing was exported."
            case .unsafeAudioPath: "An iPod track has an invalid audio path. Nothing was exported."
            case .destinationIsIPod: "Choose a folder on the iPhone or in iCloud Drive, outside the iPod."
            case .copyVerificationFailed:
                "An exported audio file failed verification. The incomplete export was removed."
            case .metadataRewriteFailed(let filename):
                "PodBridge could not restore metadata in \(filename). The incomplete export was removed."
            }
        }
    }

    /// Deterministic failure points used by the local virtual-iPod tests.
    enum TestFailurePoint: Sendable, Equatable {
        case afterArtworkApply
        case afterDatabaseReplacement
        case beforeAudioDelete
    }

    struct Backup: Identifiable, Sendable {
        let url: URL
        let trackCount: Int

        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    /// Summary returned after a successful music import.
    struct Result: Sendable {
        let added: Int
        let total: Int
        let playlistsAdded: Int
        let coversAdded: Int
        let exactDuplicatesReused: Int
        let metadataDuplicatesReused: Int
        let backupURL: URL
    }

    /// Local audio/database backup that can restore one deleted track.
    struct DeletionBackup: Identifiable, Sendable {
        let folderURL: URL
        let trackID: UInt32
        let title: String
        let artist: String
        let byteCount: UInt32
        let createdAt: Date
        let deviceIdentifier: String

        var id: String { folderURL.path }
    }

    /// Summary returned after a permanent track deletion.
    struct DeletionResult: Sendable {
        let deletedTrack: ClassicTrack
        let remainingTracks: Int
        let freedBytes: UInt32
        let backup: DeletionBackup
    }

    /// Parsed library and backup produced by a metadata or playlist edit.
    struct LibraryEditResult: Sendable {
        let library: ClassicLibrary
        let backupURL: URL
    }

    /// Result of checking or repairing the device-specific database signature.
    struct SignatureRepairResult: Sendable {
        let library: ClassicLibrary
        let backupURL: URL?
        let databaseChanged: Bool
    }

    /// Counts the album groups that would change during normalization.
    struct AlbumArtistRepairPreview: Sendable, Equatable {
        let albums: Int
        let tracks: Int
    }

    /// Result returned after album-artist normalization.
    struct AlbumArtistRepairResult: Sendable {
        let library: ClassicLibrary
        let repairedAlbums: Int
        let repairedTracks: Int
        let backupURL: URL?
    }

    enum AlbumArtistRepairStage: Sendable, Equatable {
        case scanningFiles
        case analyzingAlbums
        case updatingDatabase
    }

    /// Progress reported while scanning and normalizing album metadata.
    struct AlbumArtistRepairProgress: Sendable, Equatable {
        let stage: AlbumArtistRepairStage
        let completedTracks: Int
        let totalTracks: Int
        let albumsFound: Int
        let estimatedSecondsRemaining: Int?

        var fractionCompleted: Double {
            switch stage {
            case .scanningFiles:
                guard totalTracks > 0 else { return 0 }
                return min(0.85, 0.85 * Double(completedTracks) / Double(totalTracks))
            case .analyzingAlbums: return 0.9
            case .updatingDatabase: return 0.96
            }
        }
    }

    /// Summary for a batch deletion where individual file failures are counted.
    struct PermanentDeletionResult: Sendable {
        let removedTracks: [ClassicTrack]
        let remainingTracks: Int
        let freedBytes: UInt64
        let failedFileDeletions: Int
    }

    /// Metadata values applied to every track in an album group.
    struct AlbumMetadataUpdate: Sendable {
        let album: String
        let albumArtist: String
        let songArtist: String?
        let genre: String
        let year: UInt32
        let compilation: Bool

        init(
            album: String,
            albumArtist: String,
            songArtist: String? = nil,
            genre: String,
            year: UInt32,
            compilation: Bool
        ) {
            self.album = album
            self.albumArtist = albumArtist
            self.songArtist = songArtist
            self.genre = genre
            self.year = year
            self.compilation = compilation
        }
    }

    /// Progress reported while searching the network for missing artwork.
    struct ArtworkSearchProgress: Sendable {
        let completedItems: Int
        let totalItems: Int
        let matchedItems: Int
        let tracksPrepared: Int
    }

    /// Summary returned after applying network artwork matches.
    struct ArtworkSearchResult: Sendable {
        let searchedItems: Int
        let matchedItems: Int
        let updatedTracks: Int
        let failedLookups: Int
        let backupURL: URL?
    }

    /// Summary returned after restoring embedded artwork into the iPod caches.
    struct EmbeddedArtworkResult: Sendable {
        let library: ClassicLibrary
        let restoredTracks: Int
        let tracksWithoutEmbeddedArtwork: Int
        let backupURL: URL?
    }

}
