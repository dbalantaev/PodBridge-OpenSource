// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import AVFoundation
import CryptoKit
import Foundation

/// Coordinates transactional changes to an iPod music library.
///
/// The engine owns the high-level pipeline: read and validate the existing
/// database, copy or edit files, create a backup, write database/artwork data,
/// verify the result, and restore the backup on failure. Binary-format details
/// remain in `ClassicDatabase` and `ArtworkDatabase`.
enum IPodSyncEngine {
    /// Deterministic failure points used by the local virtual-iPod tests.
    enum TestFailurePoint: Sendable, Equatable {
        case afterArtworkApply
        case afterDatabaseReplacement
        case beforeAudioDelete
    }

    private static let testFailureLock = NSLock()
    private static var pendingTestFailure: TestFailurePoint?

    /// Installs one single-use failure for a deterministic rollback test.
    static func setTestFailure(_ point: TestFailurePoint?) {
#if DEBUG
        testFailureLock.lock()
        pendingTestFailure = point
        testFailureLock.unlock()
#else
        _ = point
#endif
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

    /// Progress reported while scanning and normalizing album metadata.
    struct AlbumArtistRepairProgress: Sendable, Equatable {
        enum Stage: Sendable, Equatable {
            case scanningFiles
            case analyzingAlbums
            case updatingDatabase
        }

        let stage: Stage
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

    private struct DeletionManifest: Codable {
        let trackID: UInt32
        let title: String
        let artist: String
        let byteCount: UInt32
        let createdAt: Date
        let originalIPodPath: String
        let audioFilename: String
        let audioSHA256: String
        let originalDatabaseSHA256: String
        let deletedDatabaseSHA256: String
        let deviceIdentifier: String
        var completed: Bool
    }

    private struct PlaylistArtworkManifest: Codable {
        var version: Int
        var anchorTrackIDs: [UInt32]
    }

    // MARK: - Destination inspection and recovery

    /// Reads and validates the destination iPod database without modifying it.
    static func inspect(root: URL) throws -> Int {
        let databaseURL = root.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw PodBridgeError.notAnIPod }
        AppLogger.device("iPod preflight found iTunesDB", level: .debug)
        _ = try IPodDeviceProfile.databaseKey(at: root)
        let data = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let count = try ClassicDatabase.parse(data).tracks.count
        AppLogger.device("iPod preflight parsed databaseBytes=\(data.count) tracks=\(count) FirewireGuid=present", level: .info)
        return count
    }

    static func library(root: URL) throws -> ClassicLibrary {
        let databaseURL = root.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw PodBridgeError.notAnIPod }
        return try ClassicDatabase.parse(Data(contentsOf: databaseURL, options: .mappedIfSafe))
    }

    static func repairDatabaseSignature(root: URL) async throws -> SignatureRepairResult {
        try await Task.detached(priority: .userInitiated) {
            let store = LocalIPodVolumeStore(root: root)
            guard FileManager.default.fileExists(atPath: store.databaseURL.path) else { throw PodBridgeError.notAnIPod }
            let original = try store.readDatabase()
            let firewireID = try IPodDeviceProfile.databaseKey(at: root)
            let repaired = try ClassicDatabase.resigning(existing: original, firewireID: firewireID)
            if repaired.data == original {
                return SignatureRepairResult(library: repaired.library, backupURL: nil, databaseChanged: false)
            }
            let transaction = try IPodDatabaseTransaction(
                store: store,
                original: original,
                temporaryName: "iTunesDB.podbridge.signature.tmp",
                afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
            )
            do {
                try transaction.stage(repaired.data)
                try transaction.activate()
                let active = try store.readDatabase()
                let diagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
                guard active == repaired.data,
                      try ClassicDatabase.parse(active) == repaired.library,
                      diagnostics.hash58Valid,
                      diagnostics.masterPlaylistMembers == repaired.library.tracks.count,
                      diagnostics.playlistSectionsConsistent,
                      diagnostics.sortIndexesValid,
                      diagnostics.jumpTablesValid else {
                    throw PodBridgeError.databaseVerificationFailed
                }
                AppLogger.database("iTunesDB signature repaired tracks=\(repaired.library.tracks.count) backup=\(transaction.backupURL.lastPathComponent)", level: .info)
                return SignatureRepairResult(library: repaired.library, backupURL: transaction.backupURL, databaseChanged: true)
            } catch {
                do {
                    try transaction.rollback()
                } catch {
                    AppLogger.database("Signature repair rollback failed error=\(error.localizedDescription)", level: .error)
                    throw PodBridgeError.restoreFailed
                }
                throw error
            }
        }.value
    }

    static func customPlaylistArtworkAnchorIDs(root: URL, library: ClassicLibrary) -> Set<UInt32> {
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        let stored = readPlaylistArtworkManifest(root: root).map(\.anchorTrackIDs) ?? []
        let playlistMembers = Set(library.playlists.flatMap(\.trackIDs))
        let tracksByID = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.id, $0) })
        return Set(stored.filter { id in
            guard let track = tracksByID[id] else { return false }
            return playlistMembers.contains(id) && track.artworkImageID != 0
        })
    }

    static func deletionBackups(backupRoot: URL? = nil) -> [DeletionBackup] {
        let manager = FileManager.default
        guard let root = try? resolvedDeletionBackupRoot(override: backupRoot),
              let folders = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return folders.compactMap { folder in
            guard let manifest = try? readDeletionManifest(folder: folder), manifest.completed else { return nil }
            return DeletionBackup(
                folderURL: folder,
                trackID: manifest.trackID,
                title: manifest.title,
                artist: manifest.artist,
                byteCount: manifest.byteCount,
                createdAt: manifest.createdAt,
                deviceIdentifier: manifest.deviceIdentifier
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func recoverInterruptedDeletions(root: URL, backupRoot: URL? = nil) throws {
        let manager = FileManager.default
        let localRoot = try resolvedDeletionBackupRoot(override: backupRoot)
        guard let folders = try? manager.contentsOfDirectory(
            at: localRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let deviceIdentifier = firewireID.hexString
        let databaseURL = root.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        for folder in folders {
            guard let manifest = try? readDeletionManifest(folder: folder),
                  !manifest.completed,
                  manifest.deviceIdentifier == deviceIdentifier else { continue }
            let databaseBackupURL = folder.appendingPathComponent("iTunesDB")
            let audioBackupURL = folder.appendingPathComponent(manifest.audioFilename)
            guard let original = try? Data(contentsOf: databaseBackupURL),
                  Data(SHA256.hash(data: original)).hexString == manifest.originalDatabaseSHA256,
                  let audioDestination = trackURL(path: manifest.originalIPodPath, root: root) else {
                throw PodBridgeError.deletionBackupFailed
            }
            var backupCache: [String: Data] = [:]
            guard (try? sha256(of: audioBackupURL, cache: &backupCache).hexString) == manifest.audioSHA256 else {
                throw PodBridgeError.deletionBackupFailed
            }
            let active = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
            let activeHash = Data(SHA256.hash(data: active)).hexString
            guard activeHash == manifest.originalDatabaseSHA256 || activeHash == manifest.deletedDatabaseSHA256 else {
                AppLogger.database(
                    "Interrupted deletion left untouched id=\(manifest.trackID) because active library changed",
                    level: .error
                )
                continue
            }
            if !manager.fileExists(atPath: audioDestination.path) {
                try manager.createDirectory(at: audioDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: audioBackupURL, to: audioDestination)
            }
            var restoredAudioCache: [String: Data] = [:]
            guard try sha256(of: audioDestination, cache: &restoredAudioCache).hexString == manifest.audioSHA256 else {
                throw PodBridgeError.deletionBackupFailed
            }
            if activeHash == manifest.deletedDatabaseSHA256 {
                try original.write(to: databaseURL, options: .atomic)
                let restored = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
                guard restored == original,
                      try ClassicDatabase.inspect(restored, firewireID: firewireID).hash58Valid else {
                    throw PodBridgeError.databaseVerificationFailed
                }
            }
            try manager.removeItem(at: folder)
            AppLogger.database(
                "Interrupted deletion automatically rolled back id=\(manifest.trackID) title=\(manifest.title)",
                level: .info
            )
        }
    }

    // MARK: - Track and playlist operations

    /// Deletes a track after creating a recoverable database and audio backup.
    static func deleteTrack(
        id: UInt32,
        root: URL,
        backupRoot: URL? = nil
    ) async throws -> DeletionResult {
        try await Task.detached(priority: .userInitiated) {
            try deleteTrackSynchronously(id: id, root: root, backupRoot: backupRoot)
        }.value
    }

    static func restoreDeletion(
        _ backup: DeletionBackup,
        root: URL
    ) async throws -> ClassicLibrary {
        try await Task.detached(priority: .userInitiated) {
            try restoreDeletionSynchronously(backup, root: root)
        }.value
    }

    static func discardDeletionBackup(_ backup: DeletionBackup) throws {
        let manifest = try readDeletionManifest(folder: backup.folderURL)
        guard manifest.completed, manifest.trackID == backup.trackID else {
            throw PodBridgeError.deletionRestoreUnavailable
        }
        try FileManager.default.removeItem(at: backup.folderURL)
        AppLogger.database("Local deleted-track backup discarded id=\(backup.trackID) title=\(backup.title)", level: .info)
    }

    static func editTrackMetadata(
        id: UInt32,
        update: ClassicDatabase.TrackMetadataUpdate,
        root: URL
    ) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try editLibrarySynchronously(root: root, operation: .track(id: id, update: update))
        }.value
    }

    static func renamePlaylist(index: Int, name: String, root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try editLibrarySynchronously(root: root, operation: .playlist(index: index, name: name))
        }.value
    }

    static func createPlaylist(name: String, trackIDs: [UInt32], root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try editLibrarySynchronously(root: root, operation: .createPlaylist(name: name, trackIDs: trackIDs))
        }.value
    }

    static func deletePlaylist(index: Int, root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try editLibrarySynchronously(root: root, operation: .removePlaylist(index: index))
        }.value
    }

    static func editAlbumMetadata(
        trackIDs: [UInt32],
        update: AlbumMetadataUpdate,
        root: URL
    ) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try editLibrarySynchronously(root: root, operation: .album(trackIDs: trackIDs, update: update))
        }.value
    }

    static func albumArtistRepairPreview(
        tracks: [ClassicTrack],
        playlists: [ClassicPlaylist] = []
    ) -> AlbumArtistRepairPreview {
        let plans = albumArtistNormalizationPlans(tracks, playlists: playlists)
        return AlbumArtistRepairPreview(
            albums: plans.count,
            tracks: plans.reduce(0) { $0 + $1.indices.count }
        )
    }

    static func repairAlbumArtists(
        root: URL,
        progress: @escaping @Sendable (AlbumArtistRepairProgress) async -> Void = { _ in }
    ) async throws -> AlbumArtistRepairResult {
        try await Task.detached(priority: .userInitiated) {
            let currentLibrary = try library(root: root)
            let scanStarted = Date()
            await progress(AlbumArtistRepairProgress(
                stage: .scanningFiles,
                completedTracks: 0,
                totalTracks: currentLibrary.tracks.count,
                albumsFound: 0,
                estimatedSecondsRemaining: nil
            ))
            let identifiedTracks = await tracksByReadingEmbeddedAlbumIdentity(
                currentLibrary.tracks,
                root: root
            ) { completed, total in
                let elapsed = Date().timeIntervalSince(scanStarted)
                let remaining: Int? = completed > 0 && completed < total
                    ? Int(ceil(elapsed / Double(completed) * Double(total - completed)))
                    : nil
                await progress(AlbumArtistRepairProgress(
                    stage: .scanningFiles,
                    completedTracks: completed,
                    totalTracks: total,
                    albumsFound: 0,
                    estimatedSecondsRemaining: remaining
                ))
            }
            await progress(AlbumArtistRepairProgress(
                stage: .analyzingAlbums,
                completedTracks: currentLibrary.tracks.count,
                totalTracks: currentLibrary.tracks.count,
                albumsFound: 0,
                estimatedSecondsRemaining: nil
            ))
            let plans = albumArtistNormalizationPlans(
                identifiedTracks,
                playlists: currentLibrary.playlists
            )
            guard !plans.isEmpty else {
                return AlbumArtistRepairResult(
                    library: currentLibrary,
                    repairedAlbums: 0,
                    repairedTracks: 0,
                    backupURL: nil
                )
            }
            let editPlans = plans.map { plan in
                AlbumArtistEditPlan(
                    album: plan.album,
                    artist: plan.artist,
                    compilation: plan.compilation,
                    trackIDs: plan.indices.map { identifiedTracks[$0].id }
                )
            }
            await progress(AlbumArtistRepairProgress(
                stage: .updatingDatabase,
                completedTracks: currentLibrary.tracks.count,
                totalTracks: currentLibrary.tracks.count,
                albumsFound: plans.count,
                estimatedSecondsRemaining: nil
            ))
            let result = try editLibrarySynchronously(
                root: root,
                operation: .normalizeAlbumArtists(editPlans)
            )
            return AlbumArtistRepairResult(
                library: result.library,
                repairedAlbums: plans.count,
                repairedTracks: plans.reduce(0) { $0 + $1.indices.count },
                backupURL: result.backupURL
            )
        }.value
    }

    static func deleteTracksPermanently(ids: [UInt32], root: URL) async throws -> PermanentDeletionResult {
        try await Task.detached(priority: .userInitiated) {
            try deleteTracksPermanentlySynchronously(ids: ids, root: root)
        }.value
    }

    static func deletePlaylistAndTracks(index: Int, root: URL) async throws -> PermanentDeletionResult {
        try await Task.detached(priority: .userInitiated) {
            try deleteTracksPermanentlySynchronously(ids: [], removingPlaylistAt: index, root: root)
        }.value
    }

    static func importedCompilationTrackIDs(
        playlist: ClassicPlaylist,
        tracks: [ClassicTrack]
    ) -> [UInt32] {
        let members = Set(playlist.trackIDs)
        return tracks.compactMap { track in
            guard members.contains(track.id),
                  track.compilation,
                  isVariousArtists(track.albumArtist),
                  track.album.caseInsensitiveCompare(playlist.name) == .orderedSame else {
                return nil
            }
            return track.id
        }
    }

    // MARK: - Artwork operations

    /// Replaces artwork for a playlist while preserving the playlist membership.
    static func setPlaylistArtwork(index: Int, artwork: Data, root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try setPlaylistArtworkSynchronously(index: index, artwork: artwork, root: root)
        }.value
    }

    static func setTrackArtwork(id: UInt32, artwork: Data, root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            let result = try setArtworkSynchronously(trackIDs: [id], artwork: artwork, root: root)
            if result.library.playlists.contains(where: { $0.trackIDs.contains(id) }) {
                try? addPlaylistArtworkAnchors([id], root: root)
            }
            return result
        }.value
    }

    static func setAlbumArtwork(trackIDs: [UInt32], artwork: Data, root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            let result = try setArtworkSynchronously(trackIDs: trackIDs, artwork: artwork, root: root)
            let requested = Set(trackIDs)
            let tracksByID = Dictionary(uniqueKeysWithValues: result.library.tracks.map { ($0.id, $0) })
            if let anchor = result.library.playlists.lazy.compactMap({ playlist in
                playlist.trackIDs.first { id in
                    requested.contains(id) && tracksByID[id]?.compilation == true
                }
            }).first {
                try? addPlaylistArtworkAnchors([anchor], root: root)
            }
            return result
        }.value
    }

    static func restoreEmbeddedArtwork(trackIDs: [UInt32], root: URL) async throws -> EmbeddedArtworkResult {
        let task = Task.detached(priority: .userInitiated) {
            try await restoreEmbeddedArtworkSynchronously(trackIDs: trackIDs, root: root)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func findMissingArtwork(
        root: URL,
        lookup: ArtworkLookupService = ArtworkLookupService(),
        progress: @escaping @Sendable (ArtworkSearchProgress) async -> Void
    ) async throws -> ArtworkSearchResult {
        let task = Task.detached(priority: .userInitiated) {
            try await findMissingArtworkSynchronously(root: root, lookup: lookup, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func replaceSongArtworkFromInternet(
        trackIDs: [UInt32],
        root: URL,
        lookup: ArtworkLookupService = ArtworkLookupService(),
        progress: @escaping @Sendable (ArtworkSearchProgress) async -> Void
    ) async throws -> ArtworkSearchResult {
        let task = Task.detached(priority: .userInitiated) {
            try await replaceSongArtworkFromInternetSynchronously(
                trackIDs: trackIDs,
                root: root,
                lookup: lookup,
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func backups(root: URL) throws -> [Backup] {
        let folder = root.appendingPathComponent("iPod_Control/iTunes/PodBridge Backups", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            let databaseURL = url.appendingPathComponent("iTunesDB")
            guard let data = try? Data(contentsOf: databaseURL),
                  let library = try? ClassicDatabase.parse(data) else { return nil }
            return Backup(url: url, trackCount: library.tracks.count)
        }.sorted { $0.name < $1.name }
    }

    static func restore(backup: Backup, root: URL) throws -> (tracks: Int, removedFiles: Int, safetyBackup: URL) {
        let manager = FileManager.default
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let databaseURL = itunes.appendingPathComponent("iTunesDB")
        let backupDatabaseURL = backup.url.appendingPathComponent("iTunesDB")
        let current = try Data(contentsOf: databaseURL)
        let restored = try Data(contentsOf: backupDatabaseURL)
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let currentLibrary = try ClassicDatabase.parse(current)
        let restoredLibrary = try ClassicDatabase.parse(restored)
        let restoredDiagnostics = try ClassicDatabase.inspect(restored, firewireID: firewireID)
        guard restoredDiagnostics.masterPlaylistFound,
              restoredDiagnostics.masterPlaylistMembers == restoredLibrary.tracks.count,
              restoredDiagnostics.playlistSectionsConsistent,
              restoredDiagnostics.hash58Valid else {
            throw PodBridgeError.databaseVerificationFailed
        }

        let safetyBackup = try createBackup(original: current, in: itunes)
        let artworkURL = root.appendingPathComponent("iPod_Control/Artwork/ArtworkDB")
        let backupArtworkURL = backup.url.appendingPathComponent("ArtworkDB")
        let currentArtwork = try? Data(contentsOf: artworkURL)
        if let currentArtwork {
            try currentArtwork.write(to: safetyBackup.appendingPathComponent("ArtworkDB"), options: .atomic)
        }

        do {
            try restored.write(to: databaseURL, options: .atomic)
            if manager.fileExists(atPath: backupArtworkURL.path) {
                try Data(contentsOf: backupArtworkURL).write(to: artworkURL, options: .atomic)
            }
            let written = try Data(contentsOf: databaseURL)
            guard written == restored,
                  try ClassicDatabase.inspect(written, firewireID: firewireID).hash58Valid else {
                throw PodBridgeError.databaseVerificationFailed
            }
        } catch {
            try? current.write(to: databaseURL, options: .atomic)
            if let currentArtwork { try? currentArtwork.write(to: artworkURL, options: .atomic) }
            throw error
        }

        let restoredIDs = Set(restoredLibrary.tracks.map(\.id))
        let obsoletePaths = currentLibrary.tracks
            .filter { !restoredIDs.contains($0.id) }
            .compactMap { trackURL(path: $0.ipodPath, root: root) }
        var removed = 0
        for url in obsoletePaths where manager.fileExists(atPath: url.path) {
            do {
                try manager.removeItem(at: url)
                removed += 1
            } catch {
                AppLogger.database("Recovery could not remove orphan file=\(url.lastPathComponent) error=\(error.localizedDescription)", level: .error)
            }
        }
        AppLogger.database(
            "Backup restored name=\(backup.name) tracks=\(restoredLibrary.tracks.count) removedOrphanFiles=\(removed) safetyBackup=\(safetyBackup.lastPathComponent) hash58=valid",
            level: .info
        )
        return (restoredLibrary.tracks.count, removed, safetyBackup)
    }

    // MARK: - Import pipeline

    /// Imports source files and playlists through a verified backup/replace pipeline.
    ///
    /// Existing database records are read first. The method copies audio, builds
    /// new track and playlist records, optionally applies artwork, then replaces
    /// the active database only after parsing and integrity checks succeed.
    static func sync(
        files: [MusicFile],
        playlists: [SourcePlaylist] = [],
        root: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> Result {
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
        let control = root.appendingPathComponent("iPod_Control", isDirectory: true)
        let musicRoot = control.appendingPathComponent("Music", isDirectory: true)
        let itunes = store.itunesURL
        guard manager.fileExists(atPath: store.databaseURL.path) else { throw PodBridgeError.notAnIPod }

        let started = Date()
        var stage = "read-existing-database"
        AppLogger.sync("Engine started additions=\(files.count) sourcePlaylists=\(playlists.count)", level: .info)
        let original: Data
        let existingLibrary: ClassicLibrary
        let firewireID: Data
        do {
            original = try store.readDatabase()
            stage = "parse-existing-database"
            existingLibrary = try ClassicDatabase.parse(original)
            stage = "read-firewire-guid"
            firewireID = try IPodDeviceProfile.databaseKey(at: root)
        } catch {
            AppLogger.sync("Engine preflight failed stage=\(stage) error=\(error.localizedDescription)", level: .error)
            throw error
        }
        AppLogger.database(
            "Existing library parsed bytes=\(original.count) tracks=\(existingLibrary.tracks.count) playlists=\(existingLibrary.playlists.count) FirewireGuid=present",
            level: .info
        )
        let beforeDiagnostics = try ClassicDatabase.inspect(original, firewireID: firewireID)
        AppLogger.database(
            "Playlist diagnostics total=\(beforeDiagnostics.playlists) sections=\(beforeDiagnostics.playlistSectionTypes) sectionCopies=\(beforeDiagnostics.playlistSectionsConsistent ? "consistent" : "diverged") master=\(beforeDiagnostics.masterPlaylistFound ? "found" : "missing") masterMembers=\(beforeDiagnostics.masterPlaylistMembers) sortIndexes=\(beforeDiagnostics.sortIndexesValid ? "valid" : "invalid") jumpTables=\(beforeDiagnostics.jumpTablesValid ? "valid" : "invalid") hash58=\(beforeDiagnostics.hash58Valid ? "valid" : "invalid")",
            level: beforeDiagnostics.masterPlaylistFound && beforeDiagnostics.hash58Valid ? .info : .error
        )
        guard beforeDiagnostics.masterPlaylistFound,
              beforeDiagnostics.masterPlaylistMembers == existingLibrary.tracks.count,
              beforeDiagnostics.playlistSectionsConsistent,
              beforeDiagnostics.sortIndexesValid,
              beforeDiagnostics.hash58Valid else {
            AppLogger.database(
                "Existing database copies diverged or failed validation; sync refused before copying audio. Restore a known-good PodBridge backup first.",
                level: .error
            )
            throw PodBridgeError.libraryRestoreRequired
        }
        var additions: [ClassicTrack] = []
        var copiedURLs: [URL] = []
        var appliedArtworkPlan: ArtworkDatabase.Plan?
        var sourceMembers = [ClassicDatabase.PendingPlaylist.Member?](repeating: nil, count: files.count)
        var digestCache: [String: Data] = [:]
        var exactDuplicatesReused = 0
        var metadataDuplicatesReused = 0
        var transaction: IPodDatabaseTransaction?
        let existingDuplicateIndex = makeDuplicateIndex(existingLibrary.tracks)
        let noExistingDuplicates = DuplicateIndex(byByteCount: [:], byMetadata: [:])
        do {
            stage = "read-incoming-metadata"
            var incomingTracks: [ClassicTrack] = []
            incomingTracks.reserveCapacity(files.count)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                let track = try await AudioMetadataReader.read(file)
                incomingTracks.append(track)
                AppLogger.sync(
                    "Track metadata index=\(index + 1)/\(files.count) codec=\(track.fileType) durationMS=\(track.durationMS) bitrateKbps=\(track.bitrate) sampleRate=\(track.sampleRate)",
                    level: .debug
                )
            }
            incomingTracks = preparedTracksForImport(
                incoming: incomingTracks,
                existing: existingLibrary.tracks,
                playlists: playlists
            )
            let importedAlbumNames = importedAlbumNamesByFileIndex(fileCount: files.count, playlists: playlists)

            stage = "copy-audio"
            try manager.createDirectory(at: musicRoot, withIntermediateDirectories: true)
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                AppLogger.sync(
                    "Track begin index=\(index + 1)/\(files.count) file=\(file.name) extension=\(file.sourceURL.pathExtension.lowercased()) bytes=\(file.byteCount)",
                    level: .debug
                )
                var track = incomingTracks[index]
                if importedAlbumNames[index] == nil, let duplicate = duplicateMatch(
                    incoming: track,
                    sourceURL: file.sourceURL,
                    existingIndex: existingDuplicateIndex,
                    additions: additions,
                    root: root,
                    digestCache: &digestCache
                ) {
                    sourceMembers[index] = duplicate.member
                    switch duplicate.kind {
                    case .exact: exactDuplicatesReused += 1
                    case .metadata: metadataDuplicatesReused += 1
                    }
                    AppLogger.sync(
                        "Duplicate reused index=\(index + 1)/\(files.count) match=\(duplicate.kind.rawValue) existingTitle=\(duplicate.matchedTitle) noCopy=true",
                        level: .info
                    )
                    await progress(index + 1)
                    continue
                }
                if importedAlbumNames[index] != nil, let duplicate = duplicateMatch(
                    incoming: track,
                    sourceURL: file.sourceURL,
                    existingIndex: noExistingDuplicates,
                    additions: additions,
                    root: root,
                    digestCache: &digestCache
                ) {
                    sourceMembers[index] = duplicate.member
                    switch duplicate.kind {
                    case .exact: exactDuplicatesReused += 1
                    case .metadata: metadataDuplicatesReused += 1
                    }
                    AppLogger.sync(
                        "Duplicate inside imported playlist reused index=\(index + 1)/\(files.count) match=\(duplicate.kind.rawValue) title=\(duplicate.matchedTitle) noCopy=true",
                        level: .info
                    )
                    await progress(index + 1)
                    continue
                }

                let additionIndex = additions.count
                let folder = musicRoot.appendingPathComponent(String(format: "F%02d", (existingLibrary.tracks.count + additionIndex) % 50), isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let filename = try uniqueFilename(extension: file.sourceURL.pathExtension, folder: folder)
                let destination = folder.appendingPathComponent(filename)
                try manager.copyItem(at: file.sourceURL, to: destination)
                copiedURLs.append(destination)
                if let handle = try? FileHandle(forWritingTo: destination) {
                    try handle.synchronize()
                    try handle.close()
                }
                let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard copiedSize == Int(file.byteCount), copiedSize ?? 0 > 0 else {
                    throw PodBridgeError.audioCopyVerificationFailed
                }
                track.ipodPath = ":iPod_Control:Music:\(folder.lastPathComponent):\(filename)"
                additions.append(track)
                sourceMembers[index] = .additionIndex(additionIndex)
                AppLogger.sync(
                    "Track copied index=\(index + 1)/\(files.count) destination=\(folder.lastPathComponent)/\(filename) artwork=\(track.artworkData != nil)",
                    level: .debug
                )
                await progress(index + 1)
            }

            stage = "merge-itunesdb"
            let pendingPlaylists = playlists.map {
                ClassicDatabase.PendingPlaylist(
                    name: $0.name,
                    members: $0.fileIndices.compactMap { sourceIndex in
                        sourceMembers.indices.contains(sourceIndex) ? sourceMembers[sourceIndex] : nil
                    }
                )
            }
            let merged = try ClassicDatabase.merge(
                existing: original,
                additions: additions,
                pendingPlaylists: pendingPlaylists,
                firewireID: firewireID
            )
            let afterDiagnostics = try ClassicDatabase.inspect(merged.data, firewireID: firewireID)
            AppLogger.database(
                "Database merged outputBytes=\(merged.data.count) totalTracks=\(merged.library.tracks.count) addedPlaylists=\(pendingPlaylists.count) totalPlaylists=\(afterDiagnostics.playlists) sections=\(afterDiagnostics.playlistSectionTypes) sectionCopies=\(afterDiagnostics.playlistSectionsConsistent ? "consistent" : "diverged") master=\(afterDiagnostics.masterPlaylistFound ? "found" : "missing") masterMembersBefore=\(beforeDiagnostics.masterPlaylistMembers) masterMembersAfter=\(afterDiagnostics.masterPlaylistMembers) sortIndexes=\(afterDiagnostics.sortIndexesValid ? "valid" : "invalid") jumpTables=\(afterDiagnostics.jumpTablesValid ? "valid" : "invalid") hash58=\(afterDiagnostics.hash58Valid ? "valid" : "invalid")",
                level: .info
            )
            for audit in merged.addedTrackDiagnostics {
                AppLogger.database(
                    "Track database audit id=\(audit.id) valid=\(audit.isValid) marker=\(audit.marker.debugDescription) type1=\(audit.type1) type2=\(audit.type2) size=\(audit.sizePrimary)/\(audit.sizeRepeated) rootLibraryID=\(audit.rootLibraryIDValid ? "valid" : "invalid") dbids=\(audit.databaseIDsMatch ? "valid" : "invalid") masterCopies=\(audit.masterMembershipValid ? "valid" : "invalid") path=\(audit.path)",
                    level: audit.isValid ? .info : .error
                )
            }
            let mergedAdditions = Array(merged.library.tracks.suffix(additions.count))
            stage = "prepare-artwork"
            let artworkPlan = try ArtworkDatabase.prepare(root: root, tracks: mergedAdditions)
            stage = "create-backup"
            transaction = try IPodDatabaseTransaction(
                store: store,
                original: original,
                temporaryName: "iTunesDB.podbridge.tmp",
                afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
            )
            guard let transaction else { throw PodBridgeError.databaseVerificationFailed }
            let backupFolder = transaction.backupURL
            AppLogger.database("Verified backup created name=\(backupFolder.lastPathComponent)", level: .info)
            if let artworkPlan {
                stage = "apply-artwork"
                try ArtworkDatabase.apply(artworkPlan, backupFolder: backupFolder)
                appliedArtworkPlan = artworkPlan
                try failIfInjected(.afterArtworkApply)
            } else {
                AppLogger.artwork("No embedded artwork to add", level: .debug)
            }
            stage = "write-temporary-database"
            try transaction.stage(merged.data)
            let written = try Data(contentsOf: transaction.temporaryURL)
            guard written == merged.data,
                  try ClassicDatabase.parse(written).tracks.count == existingLibrary.tracks.count + additions.count else {
                throw PodBridgeError.databaseVerificationFailed
            }
            AppLogger.database("Temporary database verified bytes=\(written.count)", level: .info)

            stage = "replace-itunesdb"
            do {
                try transaction.activate()
                if let handle = try? FileHandle(forWritingTo: store.databaseURL) {
                    try handle.synchronize()
                    try handle.close()
                }
                let active = try store.readDatabase()
                let activeDiagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
                let activeTrackAudits = try mergedAdditions.map { try ClassicDatabase.inspectTrack(active, expected: $0) }
                let activeAudioFilesValid = try mergedAdditions.allSatisfy { track in
                    guard let url = trackURL(path: track.ipodPath, root: root),
                          manager.fileExists(atPath: url.path) else { return false }
                    return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(track.byteCount)
                }
                guard active == merged.data,
                      activeDiagnostics.hash58Valid,
                      activeDiagnostics.playlistSectionsConsistent,
                      activeDiagnostics.masterPlaylistMembers == merged.library.tracks.count,
                      activeTrackAudits.allSatisfy(\.isValid),
                      activeAudioFilesValid else {
                    throw PodBridgeError.databaseVerificationFailed
                }
                let companionFiles = (try? manager.contentsOfDirectory(
                    at: itunes,
                    includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsSubdirectoryDescendants]
                ))?.filter { $0.lastPathComponent.hasPrefix("iTunesDB") }.map { url in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                    return "\(url.lastPathComponent):\(size)"
                }.sorted().joined(separator: ",") ?? "unavailable"
                AppLogger.database(
                    "Active iTunesDB replaced and reverified bytes=\(active.count) tracks=\(merged.library.tracks.count) masterCopies=consistent companionFiles=[\(companionFiles)]",
                    level: .info
                )

            } catch {
                AppLogger.database("iTunesDB replacement failed; restoring backup error=\(error.localizedDescription)", level: .error)
                throw error
            }
            let elapsed = Date().timeIntervalSince(started)
            AppLogger.sync(
                "Engine completed elapsedSeconds=\(String(format: "%.2f", elapsed)) added=\(additions.count) exactDuplicatesReused=\(exactDuplicatesReused) metadataDuplicatesReused=\(metadataDuplicatesReused)",
                level: .info
            )
            return Result(
                added: additions.count,
                total: merged.library.tracks.count,
                playlistsAdded: pendingPlaylists.count,
                coversAdded: mergedAdditions.filter { $0.artworkImageID != 0 }.count,
                exactDuplicatesReused: exactDuplicatesReused,
                metadataDuplicatesReused: metadataDuplicatesReused,
                backupURL: backupFolder
            )
        } catch {
            let operationError = error
            AppLogger.sync("Engine failed stage=\(stage) error=\(error.localizedDescription); rollback started", level: .error)
            var restorationFailed = false
            if let transaction {
                do {
                    try transaction.rollback()
                    AppLogger.database("iTunesDB backup restore succeeded", level: .info)
                } catch {
                    restorationFailed = true
                    AppLogger.database("iTunesDB backup restore failed error=\(error.localizedDescription)", level: .error)
                }
            }
            if let appliedArtworkPlan {
                do {
                    try ArtworkDatabase.rollback(appliedArtworkPlan)
                    AppLogger.artwork("Artwork rollback completed", level: .info)
                } catch {
                    restorationFailed = true
                    AppLogger.artwork("Artwork rollback failed error=\(error.localizedDescription)", level: .error)
                }
            }
            for url in copiedURLs {
                do {
                    try manager.removeItem(at: url)
                    if manager.fileExists(atPath: url.path) { restorationFailed = true }
                } catch {
                    restorationFailed = true
                    AppLogger.sync("Copied audio rollback failed path=\(url.path) error=\(error.localizedDescription)", level: .error)
                }
            }
            AppLogger.sync("Removed newly copied audio count=\(copiedURLs.count)", level: .info)
            if restorationFailed { throw PodBridgeError.restoreFailed }
            throw operationError
        }
    }

    private enum LibraryEditOperation: Sendable {
        case track(id: UInt32, update: ClassicDatabase.TrackMetadataUpdate)
        case playlist(index: Int, name: String)
        case createPlaylist(name: String, trackIDs: [UInt32])
        case removePlaylist(index: Int)
        case album(trackIDs: [UInt32], update: AlbumMetadataUpdate)
        case normalizeAlbumArtists([AlbumArtistEditPlan])
    }

    private static func editLibrarySynchronously(
        root: URL,
        operation: LibraryEditOperation
    ) throws -> LibraryEditResult {
        try Task.checkCancellation()
        let store = LocalIPodVolumeStore(root: root)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let before = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard before.masterPlaylistFound,
              before.playlistSectionsConsistent,
              before.sortIndexesValid,
              before.jumpTablesValid,
              before.hash58Valid else { throw PodBridgeError.libraryRestoreRequired }
        let edit: ClassicDatabase.EditResult
        let description: String
        switch operation {
        case let .track(id, update):
            edit = try ClassicDatabase.editingTrackMetadata(
                existing: original,
                trackID: id,
                update: update,
                firewireID: firewireID
            )
            description = "track-metadata id=\(id)"
        case let .playlist(index, name):
            let originalLibrary = try ClassicDatabase.parse(original)
            guard originalLibrary.playlists.indices.contains(index) else { throw PodBridgeError.playlistNotFound }
            let originalPlaylist = originalLibrary.playlists[index]
            let playlistIDs = Set(originalPlaylist.trackIDs)
            let playlistTracks = originalLibrary.tracks.filter { playlistIDs.contains($0.id) }
            let compilationGroups = Dictionary(grouping: playlistTracks.filter(\.compilation), by: \.albumID)
                .filter { $0.key != 0 }
            let linkedCompilation = compilationGroups.max { lhs, rhs in lhs.value.count < rhs.value.count }?.value
            let renamedPlaylist = try ClassicDatabase.renamingPlaylist(
                existing: original,
                playlistIndex: index,
                newName: name,
                firewireID: firewireID
            )
            if let linkedCompilation,
               linkedCompilation.count == playlistTracks.count
                    || linkedCompilation.first?.album.caseInsensitiveCompare(originalPlaylist.name) == .orderedSame {
                edit = try ClassicDatabase.editingAlbumMetadata(
                    existing: renamedPlaylist.data,
                    trackIDs: linkedCompilation.map(\.id),
                    album: name,
                    firewireID: firewireID
                )
                description = "playlist-and-compilation-rename index=\(index) name=\(name) tracks=\(linkedCompilation.count)"
            } else {
                edit = renamedPlaylist
                description = "playlist-rename index=\(index) name=\(name)"
            }
        case let .createPlaylist(name, trackIDs):
            edit = try ClassicDatabase.addingPlaylist(
                existing: original,
                name: name,
                trackIDs: trackIDs,
                firewireID: firewireID
            )
            description = "playlist-create name=\(name) members=\(trackIDs.count)"
        case let .removePlaylist(index):
            edit = try ClassicDatabase.removingPlaylist(
                existing: original,
                playlistIndex: index,
                firewireID: firewireID
            )
            description = "playlist-delete index=\(index) tracksDeleted=false"
        case let .album(trackIDs, update):
            edit = try ClassicDatabase.editingAlbumMetadata(
                existing: original,
                trackIDs: trackIDs,
                album: update.album,
                albumArtist: update.albumArtist,
                artist: update.songArtist,
                genre: update.genre,
                year: update.year,
                compilation: update.compilation,
                firewireID: firewireID
            )
            description = "album-metadata tracks=\(trackIDs.count) album=\(update.album) albumArtist=\(update.albumArtist) songArtist=\(update.songArtist ?? "preserved") compilation=\(update.compilation)"
        case let .normalizeAlbumArtists(plans):
            edit = try ClassicDatabase.normalizingAlbumArtists(
                existing: original,
                updates: plans.map {
                    ClassicDatabase.AlbumArtistNormalizationUpdate(
                        trackIDs: $0.trackIDs,
                        album: $0.album,
                        artist: $0.artist,
                        compilation: $0.compilation
                    )
                },
                firewireID: firewireID
            )
            description = "album-artist-normalization albums=\(plans.count) tracks=\(plans.reduce(0) { $0 + $1.trackIDs.count })"
        }
        let transaction = try IPodDatabaseTransaction(
            store: store,
            original: original,
            temporaryName: "iTunesDB.podbridge.edit.tmp",
            afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
        )
        do {
            try transaction.stage(edit.data)
            try transaction.activate()
            let active = try store.readDatabase()
            let diagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
            guard active == edit.data,
                  try ClassicDatabase.parse(active) == edit.library,
                  diagnostics.hash58Valid,
                  diagnostics.playlistSectionsConsistent,
                  diagnostics.masterPlaylistMembers == edit.library.tracks.count,
                  diagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid else {
                throw PodBridgeError.databaseVerificationFailed
            }
            AppLogger.database(
                "Library edit completed operation=\(description) tracks=\(edit.library.tracks.count) playlists=\(edit.library.playlists.count) backup=\(transaction.backupURL.lastPathComponent) hash58=valid",
                level: .info
            )
            return LibraryEditResult(library: edit.library, backupURL: transaction.backupURL)
        } catch {
            do {
                try transaction.rollback()
            } catch {
                AppLogger.database("Library edit rollback failed operation=\(description) error=\(error.localizedDescription)", level: .error)
                throw PodBridgeError.restoreFailed
            }
            AppLogger.database("Library edit failed operation=\(description) error=\(error.localizedDescription); original database restored", level: .error)
            throw error
        }
    }

    private static func deleteTracksPermanentlySynchronously(
        ids: [UInt32],
        removingPlaylistAt playlistIndex: Int? = nil,
        root: URL
    ) throws -> PermanentDeletionResult {
        try Task.checkCancellation()
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let temporaryDatabase = itunes.appendingPathComponent("iTunesDB.podbridge.delete.tmp")
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let before = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard before.masterPlaylistFound,
              before.playlistSectionsConsistent,
              before.sortIndexesValid,
              before.jumpTablesValid,
              before.hash58Valid else { throw PodBridgeError.libraryRestoreRequired }
        let removal: ClassicDatabase.BatchRemovalResult
        if let playlistIndex {
            let originalLibrary = try ClassicDatabase.parse(original)
            guard originalLibrary.playlists.indices.contains(playlistIndex) else {
                throw PodBridgeError.playlistNotFound
            }
            let playlist = originalLibrary.playlists[playlistIndex]
            let playlistTrackIDs = importedCompilationTrackIDs(
                playlist: playlist,
                tracks: originalLibrary.tracks
            )
            let playlistRemoval = try ClassicDatabase.removingPlaylist(
                existing: original,
                playlistIndex: playlistIndex,
                firewireID: firewireID
            )
            if playlistTrackIDs.isEmpty {
                removal = ClassicDatabase.BatchRemovalResult(
                    data: playlistRemoval.data,
                    library: playlistRemoval.library,
                    removedTracks: []
                )
            } else {
                removal = try ClassicDatabase.removingTracks(
                    existing: playlistRemoval.data,
                    trackIDs: playlistTrackIDs,
                    firewireID: firewireID
                )
            }
        } else {
            removal = try ClassicDatabase.removingTracks(existing: original, trackIDs: ids, firewireID: firewireID)
        }
        let files = removal.removedTracks.compactMap { track -> (ClassicTrack, URL)? in
            guard let url = trackURL(path: track.ipodPath, root: root) else { return nil }
            return (track, url)
        }
        var databaseActivated = false
        do {
            try store.writeVerifiedDatabase(removal.data, to: temporaryDatabase)
            try store.replaceDatabase(with: temporaryDatabase)
            databaseActivated = true
            try failIfInjected(.afterDatabaseReplacement)
            let active = try store.readDatabase()
            let diagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
            guard active == removal.data,
                  try ClassicDatabase.parse(active) == removal.library,
                  diagnostics.hash58Valid,
                  diagnostics.playlistSectionsConsistent,
                  diagnostics.masterPlaylistMembers == removal.library.tracks.count,
                  diagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid else {
                throw PodBridgeError.databaseVerificationFailed
            }
        } catch {
            store.removeItem(at: temporaryDatabase)
            if databaseActivated {
                do {
                    try store.restoreDatabase(original)
                    guard try store.readDatabase() == original else { throw PodBridgeError.restoreFailed }
                } catch {
                    AppLogger.database("Permanent deletion rollback failed error=\(error.localizedDescription)", level: .error)
                    throw PodBridgeError.restoreFailed
                }
            }
            throw error
        }

        var freedBytes: UInt64 = 0
        var failed = removal.removedTracks.count - files.count
        for (track, url) in files {
            if !manager.fileExists(atPath: url.path) { continue }
            do {
                try manager.removeItem(at: url)
                if manager.fileExists(atPath: url.path) {
                    failed += 1
                } else {
                    freedBytes += UInt64(track.byteCount)
                }
            } catch {
                failed += 1
                AppLogger.database(
                    "Orphan audio cleanup failed id=\(track.id) path=\(track.ipodPath) error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
        AppLogger.database(
            "Permanent deletion completed tracks=\(removal.removedTracks.count) playlistRemoved=\(playlistIndex != nil) remaining=\(removal.library.tracks.count) freedBytes=\(freedBytes) failedFileDeletions=\(failed) audioBackup=false hash58=valid",
            level: failed == 0 ? .info : .error
        )
        return PermanentDeletionResult(
            removedTracks: removal.removedTracks,
            remainingTracks: removal.library.tracks.count,
            freedBytes: freedBytes,
            failedFileDeletions: failed
        )
    }

    private struct MissingArtworkAlbum: Sendable {
        let title: String
        let artist: String
        let tracks: [ClassicTrack]
    }

    private struct MissingArtworkSong: Sendable {
        let title: String
        let artist: String
        let tracks: [ClassicTrack]
    }

    private enum ArtworkSearchItem: Sendable {
        case album(MissingArtworkAlbum)
        case song(MissingArtworkSong)
    }

    private static func setPlaylistArtworkSynchronously(
        index: Int,
        artwork: Data,
        root: URL
    ) throws -> LibraryEditResult {
        try ArtworkDatabase.validateSourceArtwork(artwork)
        let store = LocalIPodVolumeStore(root: root)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let library = try ClassicDatabase.parse(original)
        let originalDiagnostics = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard library.playlists.indices.contains(index) else { throw PodBridgeError.playlistNotFound }
        let playlist = library.playlists[index]
        let playlistIDs = Set(playlist.trackIDs)
        let playlistTracks = library.tracks.filter { playlistIDs.contains($0.id) }

        let preferredAlbumID = Dictionary(grouping: playlistTracks.filter(\.compilation), by: \.albumID)
            .filter { $0.key != 0 }
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?.key
        let targetTracks: [ClassicTrack]
        if let preferredAlbumID {
            targetTracks = library.tracks.filter { $0.albumID == preferredAlbumID }
        } else {
            targetTracks = playlistTracks.filter {
                $0.album.caseInsensitiveCompare(playlist.name) == .orderedSame
            }
        }
        guard !targetTracks.isEmpty else { throw PodBridgeError.playlistHasNoCompilationAlbum }

        let artworkByTrackID = Dictionary(uniqueKeysWithValues: targetTracks.map { ($0.id, artwork) })
        let edit = try ClassicDatabase.addingArtwork(
            existing: original,
            artworkByTrackID: artworkByTrackID,
            firewireID: firewireID
        )
        guard let artworkPlan = try ArtworkDatabase.prepare(root: root, tracks: edit.updatedTracks) else {
            throw PodBridgeError.invalidArtwork
        }
        let transaction = try IPodDatabaseTransaction(
            store: store,
            original: original,
            temporaryName: "iTunesDB.podbridge.playlist-artwork.tmp",
            afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
        )
        var artworkApplied = false
        do {
            try ArtworkDatabase.apply(artworkPlan, backupFolder: transaction.backupURL)
            artworkApplied = true
            try failIfInjected(.afterArtworkApply)
            try transaction.stage(edit.data)
            try transaction.activate()
            if let handle = try? FileHandle(forWritingTo: store.databaseURL) {
                try handle.synchronize()
                try handle.close()
            }
            let active = try store.readDatabase()
            let diagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
            guard active == edit.data,
                  try ClassicDatabase.parse(active) == edit.library,
                  diagnostics.hash58Valid,
                  diagnostics.masterPlaylistFound == originalDiagnostics.masterPlaylistFound,
                  diagnostics.masterPlaylistMembers == originalDiagnostics.masterPlaylistMembers,
                  diagnostics.playlistSectionTypes == originalDiagnostics.playlistSectionTypes,
                  diagnostics.playlistSectionsConsistent == originalDiagnostics.playlistSectionsConsistent,
                  diagnostics.sortIndexesValid == originalDiagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid == originalDiagnostics.jumpTablesValid else {
                AppLogger.artwork(
                    "Playlist artwork active verification failed bytes=\(active.count)/\(edit.data.count) "
                        + "hash58=\(diagnostics.hash58Valid) master=\(diagnostics.masterPlaylistFound)/\(originalDiagnostics.masterPlaylistFound) "
                        + "members=\(diagnostics.masterPlaylistMembers)/\(originalDiagnostics.masterPlaylistMembers) "
                        + "sections=\(diagnostics.playlistSectionTypes)/\(originalDiagnostics.playlistSectionTypes) "
                        + "consistent=\(diagnostics.playlistSectionsConsistent)/\(originalDiagnostics.playlistSectionsConsistent) "
                        + "sort=\(diagnostics.sortIndexesValid)/\(originalDiagnostics.sortIndexesValid) "
                        + "jumps=\(diagnostics.jumpTablesValid)/\(originalDiagnostics.jumpTablesValid)",
                    level: .error
                )
                throw PodBridgeError.databaseVerificationFailed
            }
        } catch {
            let operationError = error
            try rollbackDatabaseAndArtwork(
                transaction: transaction,
                artworkPlan: artworkPlan,
                artworkApplied: artworkApplied,
                operation: "Playlist artwork"
            )
            throw operationError
        }

        let targetIDs = Set(targetTracks.map(\.id))
        guard let anchor = playlist.trackIDs.first(where: { targetIDs.contains($0) }) else {
            throw PodBridgeError.playlistHasNoCompilationAlbum
        }
        do {
            try addPlaylistArtworkAnchors([anchor], root: root)
        } catch {
            AppLogger.artwork("Playlist artwork anchor persistence failed id=\(anchor) error=\(error.localizedDescription)", level: .error)
        }
        AppLogger.artwork(
            "Custom playlist artwork applied playlist=\(playlist.name) tracks=\(targetTracks.count) anchor=\(anchor) backup=\(transaction.backupURL.lastPathComponent)",
            level: .info
        )
        return LibraryEditResult(library: edit.library, backupURL: transaction.backupURL)
    }

    private static func setArtworkSynchronously(
        trackIDs: [UInt32],
        artwork: Data,
        root: URL
    ) throws -> LibraryEditResult {
        try ArtworkDatabase.validateSourceArtwork(artwork)
        let requestedIDs = Set(trackIDs)
        guard !requestedIDs.isEmpty else { throw PodBridgeError.trackNotFound }
        return try applyArtworkSynchronously(
            artworkByTrackID: Dictionary(uniqueKeysWithValues: requestedIDs.map { ($0, artwork) }),
            root: root,
            temporaryName: "iTunesDB.podbridge.custom-artwork.tmp",
            logOperation: "Custom artwork"
        )
    }

    private static func restoreEmbeddedArtworkSynchronously(
        trackIDs: [UInt32],
        root: URL
    ) async throws -> EmbeddedArtworkResult {
        let requested = Set(trackIDs)
        guard !requested.isEmpty else { throw PodBridgeError.trackNotFound }
        let originalLibrary = try library(root: root)
        let targets = originalLibrary.tracks.filter { requested.contains($0.id) }
        guard targets.count == requested.count else { throw PodBridgeError.trackNotFound }
        var artworkByTrackID: [UInt32: Data] = [:]
        var missing = 0
        for (index, track) in targets.enumerated() {
            try Task.checkCancellation()
            guard let url = trackURL(path: track.ipodPath, root: root) else {
                missing += 1
                continue
            }
            do {
                let asset = AVURLAsset(url: url)
                let metadata = try await asset.load(.commonMetadata)
                guard let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
                      let data = try await item.load(.dataValue), !data.isEmpty else {
                    missing += 1
                    continue
                }
                try ArtworkDatabase.validateSourceArtwork(data)
                artworkByTrackID[track.id] = data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                missing += 1
                AppLogger.artwork(
                    "Embedded artwork read failed index=\(index + 1)/\(targets.count) id=\(track.id) error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
        guard !artworkByTrackID.isEmpty else {
            return EmbeddedArtworkResult(
                library: originalLibrary,
                restoredTracks: 0,
                tracksWithoutEmbeddedArtwork: missing,
                backupURL: nil
            )
        }
        let edit = try applyArtworkSynchronously(
            artworkByTrackID: artworkByTrackID,
            root: root,
            temporaryName: "iTunesDB.podbridge.embedded-artwork.tmp",
            logOperation: "Embedded artwork restore"
        )
        return EmbeddedArtworkResult(
            library: edit.library,
            restoredTracks: artworkByTrackID.count,
            tracksWithoutEmbeddedArtwork: missing,
            backupURL: edit.backupURL
        )
    }

    private static func applyArtworkSynchronously(
        artworkByTrackID: [UInt32: Data],
        root: URL,
        temporaryName: String,
        logOperation: String
    ) throws -> LibraryEditResult {
        guard !artworkByTrackID.isEmpty else { throw PodBridgeError.invalidArtwork }
        for artwork in artworkByTrackID.values { try ArtworkDatabase.validateSourceArtwork(artwork) }
        let store = LocalIPodVolumeStore(root: root)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let library = try ClassicDatabase.parse(original)
        let originalDiagnostics = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard Set(artworkByTrackID.keys).isSubset(of: Set(library.tracks.map(\.id))) else {
            throw PodBridgeError.trackNotFound
        }
        let edit = try ClassicDatabase.addingArtwork(
            existing: original,
            artworkByTrackID: artworkByTrackID,
            firewireID: firewireID
        )
        guard let artworkPlan = try ArtworkDatabase.prepare(root: root, tracks: edit.updatedTracks) else {
            throw PodBridgeError.invalidArtwork
        }
        let transaction = try IPodDatabaseTransaction(
            store: store,
            original: original,
            temporaryName: temporaryName,
            afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
        )
        var artworkApplied = false
        do {
            try ArtworkDatabase.apply(artworkPlan, backupFolder: transaction.backupURL)
            artworkApplied = true
            try failIfInjected(.afterArtworkApply)
            try transaction.stage(edit.data)
            try transaction.activate()
            if let handle = try? FileHandle(forWritingTo: store.databaseURL) {
                try handle.synchronize()
                try handle.close()
            }
            let active = try store.readDatabase()
            let diagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
            guard active == edit.data,
                  try ClassicDatabase.parse(active) == edit.library,
                  diagnostics.hash58Valid,
                  diagnostics.masterPlaylistFound == originalDiagnostics.masterPlaylistFound,
                  diagnostics.masterPlaylistMembers == originalDiagnostics.masterPlaylistMembers,
                  diagnostics.playlistSectionTypes == originalDiagnostics.playlistSectionTypes,
                  diagnostics.playlistSectionsConsistent == originalDiagnostics.playlistSectionsConsistent,
                  diagnostics.sortIndexesValid == originalDiagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid == originalDiagnostics.jumpTablesValid else {
                AppLogger.artwork(
                    "\(logOperation) active verification failed bytes=\(active.count)/\(edit.data.count) "
                        + "hash58=\(diagnostics.hash58Valid) master=\(diagnostics.masterPlaylistFound)/\(originalDiagnostics.masterPlaylistFound) "
                        + "members=\(diagnostics.masterPlaylistMembers)/\(originalDiagnostics.masterPlaylistMembers) "
                        + "sections=\(diagnostics.playlistSectionTypes)/\(originalDiagnostics.playlistSectionTypes) "
                        + "consistent=\(diagnostics.playlistSectionsConsistent)/\(originalDiagnostics.playlistSectionsConsistent) "
                        + "sort=\(diagnostics.sortIndexesValid)/\(originalDiagnostics.sortIndexesValid) "
                        + "jumps=\(diagnostics.jumpTablesValid)/\(originalDiagnostics.jumpTablesValid)",
                    level: .error
                )
                throw PodBridgeError.databaseVerificationFailed
            }
        } catch {
            let operationError = error
            try rollbackDatabaseAndArtwork(
                transaction: transaction,
                artworkPlan: artworkPlan,
                artworkApplied: artworkApplied,
                operation: logOperation
            )
            throw operationError
        }
        AppLogger.artwork(
            "\(logOperation) applied tracks=\(artworkByTrackID.count) backup=\(transaction.backupURL.lastPathComponent)",
            level: .info
        )
        return LibraryEditResult(library: edit.library, backupURL: transaction.backupURL)
    }

    private static func findMissingArtworkSynchronously(
        root: URL,
        lookup: ArtworkLookupService,
        progress: @escaping @Sendable (ArtworkSearchProgress) async -> Void
    ) async throws -> ArtworkSearchResult {
        try Task.checkCancellation()
        let store = LocalIPodVolumeStore(root: root)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let originalLibrary = try ClassicDatabase.parse(original)
        let before = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard before.masterPlaylistFound,
              before.playlistSectionsConsistent,
              before.sortIndexesValid,
              before.jumpTablesValid,
              before.hash58Valid else { throw PodBridgeError.libraryRestoreRequired }

        let tracksByID = Dictionary(uniqueKeysWithValues: originalLibrary.tracks.map { ($0.id, $0) })
        var playlistCompilationIDs = Set(originalLibrary.tracks.filter(\.compilation).map(\.id))
        for playlist in originalLibrary.playlists {
            for trackID in playlist.trackIDs {
                guard let track = tracksByID[trackID],
                      track.album.caseInsensitiveCompare(playlist.name) == .orderedSame else { continue }
                playlistCompilationIDs.insert(trackID)
            }
        }
        let missingAlbumTracks = originalLibrary.tracks.filter {
            !playlistCompilationIDs.contains($0.id) && $0.artworkImageID == 0
        }
        let grouped = Dictionary(grouping: missingAlbumTracks) { track -> String in
            let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            return "\(normalizedMetadata(artist))\u{0}\(normalizedMetadata(track.album))"
        }
        let albums: [MissingArtworkAlbum] = grouped.values.compactMap { tracks in
            guard let first = tracks.first else { return nil }
            let artist = first.albumArtist.isEmpty ? first.artist : first.albumArtist
            guard metadataIsSearchable(first.album), metadataIsSearchable(artist) else { return nil }
            return MissingArtworkAlbum(title: first.album, artist: artist, tracks: tracks)
        }.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            return artistOrder == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artistOrder == .orderedAscending
        }
        let songGroups = Dictionary(grouping: originalLibrary.tracks.filter {
            playlistCompilationIDs.contains($0.id)
        }) { track in
            "\(normalizedMetadata(track.artist))\u{0}\(normalizedMetadata(track.title))"
        }
        let songs: [MissingArtworkSong] = songGroups.values.compactMap { tracks in
            guard let first = tracks.first,
                  metadataIsSearchable(first.title),
                  metadataIsSearchable(first.artist) else { return nil }
            return MissingArtworkSong(title: first.title, artist: first.artist, tracks: tracks)
        }.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            return artistOrder == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artistOrder == .orderedAscending
        }
        let items = albums.map(ArtworkSearchItem.album) + songs.map(ArtworkSearchItem.song)
        guard !items.isEmpty else {
            return ArtworkSearchResult(
                searchedItems: 0,
                matchedItems: 0,
                updatedTracks: 0,
                failedLookups: 0,
                backupURL: nil
            )
        }

        var artworkByTrackID: [UInt32: Data] = [:]
        var matchedItems = 0
        var failures = 0
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            do {
                let match: ArtworkLookupService.Match?
                let tracks: [ClassicTrack]
                let description: String
                switch item {
                case .album(let album):
                    match = try await lookup.cover(album: album.title, artist: album.artist)
                    tracks = album.tracks
                    description = "album=\(album.title) artist=\(album.artist)"
                case .song(let song):
                    match = try await lookup.cover(track: song.title, artist: song.artist)
                    tracks = song.tracks
                    description = "song=\(song.title) artist=\(song.artist)"
                }
                if let match {
                    matchedItems += 1
                    for track in tracks { artworkByTrackID[track.id] = match.data }
                    AppLogger.artwork("Artwork match \(description) tracks=\(tracks.count) matchedRelease=\(match.matchedAlbum) releaseGroup=\(match.releaseGroupID)", level: .info)
                } else {
                    AppLogger.artwork("Artwork not found \(description)", level: .debug)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                AppLogger.artwork("Artwork lookup failed item=\(index + 1) error=\(error.localizedDescription)", level: .error)
            }
            await progress(ArtworkSearchProgress(
                completedItems: index + 1,
                totalItems: items.count,
                matchedItems: matchedItems,
                tracksPrepared: artworkByTrackID.count
            ))
        }
        guard !artworkByTrackID.isEmpty else {
            return ArtworkSearchResult(
                searchedItems: items.count,
                matchedItems: 0,
                updatedTracks: 0,
                failedLookups: failures,
                backupURL: nil
            )
        }
        try Task.checkCancellation()

        let edit = try ClassicDatabase.addingArtwork(
            existing: original,
            artworkByTrackID: artworkByTrackID,
            firewireID: firewireID
        )
        guard let artworkPlan = try ArtworkDatabase.prepare(root: root, tracks: edit.updatedTracks) else {
            throw PodBridgeError.invalidArtwork
        }
        let transaction = try IPodDatabaseTransaction(
            store: store,
            original: original,
            temporaryName: "iTunesDB.podbridge.artwork.tmp",
            afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
        )
        var artworkApplied = false
        do {
            try ArtworkDatabase.apply(artworkPlan, backupFolder: transaction.backupURL)
            artworkApplied = true
            try failIfInjected(.afterArtworkApply)
            try transaction.stage(edit.data)
            try transaction.activate()
            let active = try store.readDatabase()
            let diagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
            guard active == edit.data,
                  try ClassicDatabase.parse(active) == edit.library,
                  diagnostics.hash58Valid,
                  diagnostics.playlistSectionsConsistent,
                  diagnostics.masterPlaylistMembers == edit.library.tracks.count,
                  diagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid else { throw PodBridgeError.databaseVerificationFailed }
        } catch {
            let operationError = error
            try rollbackDatabaseAndArtwork(
                transaction: transaction,
                artworkPlan: artworkPlan,
                artworkApplied: artworkApplied,
                operation: "Automatic artwork"
            )
            throw operationError
        }
        AppLogger.artwork(
            "Automatic artwork completed searchedItems=\(items.count) matchedItems=\(matchedItems) updatedTracks=\(edit.updatedTracks.count) failedLookups=\(failures) backup=\(transaction.backupURL.lastPathComponent)",
            level: failures == 0 ? .info : .error
        )
        return ArtworkSearchResult(
            searchedItems: items.count,
            matchedItems: matchedItems,
            updatedTracks: edit.updatedTracks.count,
            failedLookups: failures,
            backupURL: transaction.backupURL
        )
    }

    private static func replaceSongArtworkFromInternetSynchronously(
        trackIDs: [UInt32],
        root: URL,
        lookup: ArtworkLookupService,
        progress: @escaping @Sendable (ArtworkSearchProgress) async -> Void
    ) async throws -> ArtworkSearchResult {
        let requested = Set(trackIDs)
        guard !requested.isEmpty else { throw PodBridgeError.trackNotFound }
        let originalLibrary = try library(root: root)
        let targets = originalLibrary.tracks.filter { requested.contains($0.id) }
        guard targets.count == requested.count else { throw PodBridgeError.trackNotFound }

        // Duplicate database entries for the same recording share one lookup, but every
        // selected track is force-updated even when it already has playlist artwork.
        let groups = Dictionary(grouping: targets) {
            "\(normalizedMetadata($0.artist))\u{0}\(normalizedMetadata($0.title))"
        }.values.compactMap { tracks -> MissingArtworkSong? in
            guard let first = tracks.first,
                  metadataIsSearchable(first.title),
                  metadataIsSearchable(first.artist) else { return nil }
            return MissingArtworkSong(title: first.title, artist: first.artist, tracks: tracks)
        }.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            return artistOrder == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artistOrder == .orderedAscending
        }
        guard !groups.isEmpty else {
            return ArtworkSearchResult(searchedItems: 0, matchedItems: 0, updatedTracks: 0, failedLookups: 0, backupURL: nil)
        }

        var artworkByTrackID: [UInt32: Data] = [:]
        var matched = 0
        var failures = 0
        for (index, song) in groups.enumerated() {
            try Task.checkCancellation()
            do {
                if let match = try await lookup.cover(track: song.title, artist: song.artist) {
                    matched += 1
                    for track in song.tracks { artworkByTrackID[track.id] = match.data }
                    AppLogger.artwork(
                        "Forced online artwork match song=\(song.title) artist=\(song.artist) release=\(match.matchedAlbum)",
                        level: .info
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                AppLogger.artwork(
                    "Forced online artwork lookup failed item=\(index + 1) song=\(song.title) error=\(error.localizedDescription)",
                    level: .error
                )
            }
            await progress(ArtworkSearchProgress(
                completedItems: index + 1,
                totalItems: groups.count,
                matchedItems: matched,
                tracksPrepared: artworkByTrackID.count
            ))
        }
        guard !artworkByTrackID.isEmpty else {
            return ArtworkSearchResult(
                searchedItems: groups.count,
                matchedItems: 0,
                updatedTracks: 0,
                failedLookups: failures,
                backupURL: nil
            )
        }
        try Task.checkCancellation()
        let edit = try applyArtworkSynchronously(
            artworkByTrackID: artworkByTrackID,
            root: root,
            temporaryName: "iTunesDB.podbridge.online-artwork.tmp",
            logOperation: "Forced online song artwork"
        )
        return ArtworkSearchResult(
            searchedItems: groups.count,
            matchedItems: matched,
            updatedTracks: artworkByTrackID.count,
            failedLookups: failures,
            backupURL: edit.backupURL
        )
    }

    private static func deleteTrackSynchronously(
        id: UInt32,
        root: URL,
        backupRoot: URL?
    ) throws -> DeletionResult {
        try Task.checkCancellation()
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let before = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard before.masterPlaylistFound,
              before.playlistSectionsConsistent,
              before.sortIndexesValid,
              before.jumpTablesValid,
              before.hash58Valid else { throw PodBridgeError.libraryRestoreRequired }

        let removal = try ClassicDatabase.removingTrack(existing: original, trackID: id, firewireID: firewireID)
        guard let audioURL = trackURL(path: removal.removedTrack.ipodPath, root: root),
              manager.fileExists(atPath: audioURL.path),
              let actualSize = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              actualSize > 0,
              actualSize == Int(removal.removedTrack.byteCount) else {
            throw PodBridgeError.audioCopyVerificationFailed
        }

        let localRoot = try resolvedDeletionBackupRoot(override: backupRoot)
        try manager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        if let capacity = try? localRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity < Int64(actualSize + original.count + 10_000_000) {
            throw PodBridgeError.deletionBackupFailed
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let bundle = localRoot.appendingPathComponent("\(stamp)-track-\(id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        let databaseBackupURL = bundle.appendingPathComponent("iTunesDB")
        let ext = audioURL.pathExtension.lowercased()
        let audioFilename = ext.isEmpty ? "audio" : "audio.\(ext)"
        let audioBackupURL = bundle.appendingPathComponent(audioFilename)
        var transaction: IPodDatabaseTransaction?
        do {
            try original.write(to: databaseBackupURL, options: .atomic)
            try manager.copyItem(at: audioURL, to: audioBackupURL)
            var sourceCache: [String: Data] = [:]
            let sourceDigest = try sha256(of: audioURL, cache: &sourceCache)
            var verificationCache: [String: Data] = [:]
            let backupDigest = try sha256(of: audioBackupURL, cache: &verificationCache)
            guard sourceDigest == backupDigest,
                  try Data(contentsOf: databaseBackupURL) == original,
                  try audioBackupURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == actualSize else {
                throw PodBridgeError.deletionBackupFailed
            }

            var manifest = DeletionManifest(
                trackID: id,
                title: removal.removedTrack.title,
                artist: removal.removedTrack.artist,
                byteCount: removal.removedTrack.byteCount,
                createdAt: Date(),
                originalIPodPath: removal.removedTrack.ipodPath,
                audioFilename: audioFilename,
                audioSHA256: sourceDigest.hexString,
                originalDatabaseSHA256: Data(SHA256.hash(data: original)).hexString,
                deletedDatabaseSHA256: Data(SHA256.hash(data: removal.data)).hexString,
                deviceIdentifier: firewireID.hexString,
                completed: false
            )
            try writeDeletionManifest(manifest, folder: bundle)
            try Task.checkCancellation()

            transaction = try IPodDatabaseTransaction(
                store: store,
                original: original,
                temporaryName: "iTunesDB.podbridge.delete.tmp",
                backupURL: bundle,
                afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
            )
            guard let transaction else { throw PodBridgeError.databaseVerificationFailed }
            try transaction.stage(removal.data)
            try transaction.activate()
            let active = try store.readDatabase()
            let activeDiagnostics = try ClassicDatabase.inspect(active, firewireID: firewireID)
            guard active == removal.data,
                  activeDiagnostics.hash58Valid,
                  activeDiagnostics.playlistSectionsConsistent,
                  activeDiagnostics.masterPlaylistMembers == removal.library.tracks.count,
                  activeDiagnostics.sortIndexesValid,
                  activeDiagnostics.jumpTablesValid else {
                throw PodBridgeError.databaseVerificationFailed
            }

            try failIfInjected(.beforeAudioDelete)
            try manager.removeItem(at: audioURL)
            guard !manager.fileExists(atPath: audioURL.path) else { throw PodBridgeError.audioCopyVerificationFailed }
            manifest.completed = true
            try writeDeletionManifest(manifest, folder: bundle)
            let backup = DeletionBackup(
                folderURL: bundle,
                trackID: id,
                title: removal.removedTrack.title,
                artist: removal.removedTrack.artist,
                byteCount: removal.removedTrack.byteCount,
                createdAt: manifest.createdAt,
                deviceIdentifier: manifest.deviceIdentifier
            )
            AppLogger.database(
                "Track deleted id=\(id) title=\(removal.removedTrack.title) bytesFreed=\(actualSize) remainingTracks=\(removal.library.tracks.count) localBackup=\(bundle.lastPathComponent) hash58=valid",
                level: .info
            )
            return DeletionResult(
                deletedTrack: removal.removedTrack,
                remainingTracks: removal.library.tracks.count,
                freedBytes: UInt32(clamping: actualSize),
                backup: backup
            )
        } catch {
            let operationError = error
            var restorationFailed = false
            let databaseWasActivated = transaction?.databaseActivated == true
            if let transaction {
                do {
                    try transaction.rollback()
                } catch {
                    restorationFailed = true
                    AppLogger.database("Track deletion database rollback failed id=\(id) error=\(error.localizedDescription)", level: .error)
                }
            }
            if databaseWasActivated {
                if !manager.fileExists(atPath: audioURL.path) {
                    do {
                        try manager.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try manager.copyItem(at: audioBackupURL, to: audioURL)
                    } catch {
                        restorationFailed = true
                        AppLogger.database("Track deletion audio rollback failed id=\(id) error=\(error.localizedDescription)", level: .error)
                    }
                }
                if !manager.fileExists(atPath: audioURL.path) { restorationFailed = true }
            }
            if !restorationFailed { try? manager.removeItem(at: bundle) }
            AppLogger.database("Track deletion failed id=\(id) error=\(operationError.localizedDescription); rollback=\(restorationFailed ? "failed" : "completed")", level: .error)
            if restorationFailed { throw PodBridgeError.restoreFailed }
            throw operationError
        }
    }

    private static func restoreDeletionSynchronously(_ backup: DeletionBackup, root: URL) throws -> ClassicLibrary {
        try Task.checkCancellation()
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
        let manifest = try readDeletionManifest(folder: backup.folderURL)
        guard manifest.completed, manifest.trackID == backup.trackID else { throw PodBridgeError.deletionRestoreUnavailable }
        let databaseBackupURL = backup.folderURL.appendingPathComponent("iTunesDB")
        let audioBackupURL = backup.folderURL.appendingPathComponent(manifest.audioFilename)
        let active = try store.readDatabase()
        let original = try Data(contentsOf: databaseBackupURL, options: .mappedIfSafe)
        guard Data(SHA256.hash(data: active)).hexString == manifest.deletedDatabaseSHA256,
              Data(SHA256.hash(data: original)).hexString == manifest.originalDatabaseSHA256 else {
            throw PodBridgeError.deletionRestoreUnavailable
        }
        var cache: [String: Data] = [:]
        guard try sha256(of: audioBackupURL, cache: &cache).hexString == manifest.audioSHA256,
              try audioBackupURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(manifest.byteCount) else {
            throw PodBridgeError.deletionBackupFailed
        }
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        guard firewireID.hexString == manifest.deviceIdentifier else { throw PodBridgeError.deletionRestoreUnavailable }
        let restoredLibrary = try ClassicDatabase.parse(original)
        let restoredDiagnostics = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard restoredLibrary.tracks.contains(where: { $0.id == manifest.trackID }),
              restoredDiagnostics.hash58Valid,
              restoredDiagnostics.playlistSectionsConsistent,
              restoredDiagnostics.masterPlaylistMembers == restoredLibrary.tracks.count else {
            throw PodBridgeError.deletionBackupFailed
        }
        guard let destination = trackURL(path: manifest.originalIPodPath, root: root) else {
            throw PodBridgeError.deletionBackupFailed
        }
        var copiedAudio = false
        var transaction: IPodDatabaseTransaction?
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                var existingCache: [String: Data] = [:]
                guard try sha256(of: destination, cache: &existingCache).hexString == manifest.audioSHA256 else {
                    throw PodBridgeError.deletionRestoreUnavailable
                }
            } else {
                try manager.copyItem(at: audioBackupURL, to: destination)
                copiedAudio = true
            }
            var restoredCache: [String: Data] = [:]
            guard try sha256(of: destination, cache: &restoredCache).hexString == manifest.audioSHA256 else {
                throw PodBridgeError.audioCopyVerificationFailed
            }
            transaction = try IPodDatabaseTransaction(
                store: store,
                original: active,
                temporaryName: "iTunesDB.podbridge.restore-deletion.tmp",
                backupURL: backup.folderURL,
                afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
            )
            guard let transaction else { throw PodBridgeError.databaseVerificationFailed }
            try transaction.stage(original)
            try transaction.activate()
            let written = try store.readDatabase()
            guard written == original,
                  try ClassicDatabase.inspect(written, firewireID: firewireID).hash58Valid else {
                throw PodBridgeError.databaseVerificationFailed
            }
            try? manager.removeItem(at: backup.folderURL)
            AppLogger.database(
                "Deleted track restored id=\(manifest.trackID) title=\(manifest.title) tracks=\(restoredLibrary.tracks.count) localBackupRemoved=true",
                level: .info
            )
            return restoredLibrary
        } catch {
            let operationError = error
            do {
                try transaction?.rollback()
            } catch {
                AppLogger.database("Deleted track database rollback failed id=\(manifest.trackID) error=\(error.localizedDescription); restored audio retained", level: .error)
                throw PodBridgeError.restoreFailed
            }
            if copiedAudio {
                do {
                    try manager.removeItem(at: destination)
                    guard !manager.fileExists(atPath: destination.path) else { throw PodBridgeError.restoreFailed }
                } catch {
                    AppLogger.database("Deleted track audio rollback failed id=\(manifest.trackID) error=\(error.localizedDescription)", level: .error)
                    throw PodBridgeError.restoreFailed
                }
            }
            AppLogger.database("Deleted track restore failed id=\(manifest.trackID) error=\(operationError.localizedDescription)", level: .error)
            throw operationError
        }
    }

    private static func resolvedDeletionBackupRoot(override: URL?) throws -> URL {
        if let override { return override }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PodBridgeError.deletionBackupFailed
        }
        return documents.appendingPathComponent("PodBridge Deleted Tracks", isDirectory: true)
    }

    private static func writeDeletionManifest(_ manifest: DeletionManifest, folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func readDeletionManifest(folder: URL) throws -> DeletionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeletionManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    private static func uniqueFilename(extension sourceExtension: String, folder: URL) throws -> String {
        let ext = sourceExtension.lowercased()
        for _ in 0..<100 {
            let name = "PB" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)) + (ext.isEmpty ? "" : ".\(ext)")
            if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) { return name }
        }
        throw PodBridgeError.cannotCreateTrackFile
    }

    private enum DuplicateKind: String {
        case exact = "sha256"
        case metadata = "metadata-duration"
    }

    private struct DuplicateMatch {
        let member: ClassicDatabase.PendingPlaylist.Member
        let kind: DuplicateKind
        let matchedTitle: String
    }

    private struct DuplicateIndex {
        var byByteCount: [UInt32: [ClassicTrack]]
        var byMetadata: [String: [ClassicTrack]]
    }

    private static func duplicateMatch(
        incoming: ClassicTrack,
        sourceURL: URL,
        existingIndex: DuplicateIndex,
        additions: [ClassicTrack],
        root: URL,
        digestCache: inout [String: Data]
    ) -> DuplicateMatch? {
        let additionFiles: [(index: Int, track: ClassicTrack, url: URL)] = additions.enumerated().compactMap { index, track in
            guard let url = track.sourceURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (index, track, url)
        }

        let exactExistingCandidates: [(track: ClassicTrack, url: URL)] = (existingIndex.byByteCount[incoming.byteCount] ?? []).compactMap { track in
            guard let url = trackURL(path: track.ipodPath, root: root),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (track, url)
        }
        let exactAdditionCandidates = additionFiles.filter { $0.track.byteCount == incoming.byteCount }
        if !exactExistingCandidates.isEmpty || !exactAdditionCandidates.isEmpty,
           let sourceDigest = try? sha256(of: sourceURL, cache: &digestCache) {
            for candidate in exactExistingCandidates {
                if let digest = try? sha256(of: candidate.url, cache: &digestCache), digest == sourceDigest {
                    return DuplicateMatch(
                        member: .existingTrackID(candidate.track.id),
                        kind: .exact,
                        matchedTitle: candidate.track.title
                    )
                }
            }
            for candidate in exactAdditionCandidates {
                if let digest = try? sha256(of: candidate.url, cache: &digestCache), digest == sourceDigest {
                    return DuplicateMatch(
                        member: .additionIndex(candidate.index),
                        kind: .exact,
                        matchedTitle: candidate.track.title
                    )
                }
            }
        }

        let metadataExistingCandidates: [ClassicTrack]
        if let key = metadataIdentity(incoming) {
            metadataExistingCandidates = (existingIndex.byMetadata[key] ?? []).filter { track in
                guard strongMetadataMatch(track, incoming),
                      let url = trackURL(path: track.ipodPath, root: root) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
        } else {
            metadataExistingCandidates = []
        }
        if let candidate = metadataExistingCandidates.min(by: {
            durationDifference($0, incoming) < durationDifference($1, incoming)
        }) {
            return DuplicateMatch(
                member: .existingTrackID(candidate.id),
                kind: .metadata,
                matchedTitle: candidate.title
            )
        }
        if let candidate = additionFiles.filter({ strongMetadataMatch($0.track, incoming) }).min(by: {
            durationDifference($0.track, incoming) < durationDifference($1.track, incoming)
        }) {
            return DuplicateMatch(
                member: .additionIndex(candidate.index),
                kind: .metadata,
                matchedTitle: candidate.track.title
            )
        }
        return nil
    }

    private static func makeDuplicateIndex(_ tracks: [ClassicTrack]) -> DuplicateIndex {
        var byByteCount: [UInt32: [ClassicTrack]] = [:]
        var byMetadata: [String: [ClassicTrack]] = [:]
        for track in tracks {
            byByteCount[track.byteCount, default: []].append(track)
            if let key = metadataIdentity(track) {
                byMetadata[key, default: []].append(track)
            }
        }
        return DuplicateIndex(byByteCount: byByteCount, byMetadata: byMetadata)
    }

    private static func metadataIdentity(_ track: ClassicTrack) -> String? {
        let title = normalizedMetadata(track.title)
        let artist = normalizedMetadata(track.artist)
        let album = normalizedMetadata(track.album)
        guard !title.isEmpty, !artist.isEmpty, !album.isEmpty,
              title != "unknowntrack", artist != "unknownartist", album != "unknownalbum" else { return nil }
        return title + "\u{0}" + artist + "\u{0}" + album
    }

    private static func strongMetadataMatch(_ lhs: ClassicTrack, _ rhs: ClassicTrack) -> Bool {
        let lhsTitle = normalizedMetadata(lhs.title)
        let rhsTitle = normalizedMetadata(rhs.title)
        let lhsArtist = normalizedMetadata(lhs.artist)
        let rhsArtist = normalizedMetadata(rhs.artist)
        let lhsAlbum = normalizedMetadata(lhs.album)
        let rhsAlbum = normalizedMetadata(rhs.album)
        guard !lhsTitle.isEmpty, lhsTitle == rhsTitle,
              !lhsArtist.isEmpty, lhsArtist == rhsArtist,
              !lhsAlbum.isEmpty, lhsAlbum == rhsAlbum,
              lhsTitle != "unknowntrack",
              lhsArtist != "unknownartist",
              lhsAlbum != "unknownalbum",
              lhs.durationMS > 0, rhs.durationMS > 0 else { return false }
        return durationDifference(lhs, rhs) <= 1_500
    }

    private struct AlbumArtistNormalizationPlan: Sendable {
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

    private struct AlbumArtistEditPlan: Sendable {
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

    private static func importedAlbumNamesByFileIndex(
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

    private static func tracksByReadingEmbeddedAlbumIdentity(
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

    private static func albumArtistNormalizationPlans(
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

    private static func albumArtistNormalizationPlans(
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

    private static func isVariousArtists(_ value: String) -> Bool {
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

    private static func normalizedMetadata(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func metadataIsSearchable(_ value: String) -> Bool {
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

    private static func durationDifference(_ lhs: ClassicTrack, _ rhs: ClassicTrack) -> UInt32 {
        lhs.durationMS > rhs.durationMS ? lhs.durationMS - rhs.durationMS : rhs.durationMS - lhs.durationMS
    }

    private static func sha256(of url: URL, cache: inout [String: Data]) throws -> Data {
        let key = url.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = Data(hasher.finalize())
        cache[key] = digest
        return digest
    }

    private static func trackURL(path: String, root: URL) -> URL? {
        let components = path.split(separator: ":").map(String.init)
        guard components.first == "iPod_Control", components.count >= 3 else { return nil }
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }

    private static func rollbackDatabaseAndArtwork(
        transaction: IPodDatabaseTransaction,
        artworkPlan: ArtworkDatabase.Plan,
        artworkApplied: Bool,
        operation: String
    ) throws {
        var restorationFailed = false
        do {
            try transaction.rollback()
        } catch {
            restorationFailed = true
            AppLogger.database("\(operation) database rollback failed error=\(error.localizedDescription)", level: .error)
        }
        if artworkApplied {
            do {
                try ArtworkDatabase.rollback(artworkPlan)
            } catch {
                restorationFailed = true
                AppLogger.artwork("\(operation) artwork rollback failed error=\(error.localizedDescription)", level: .error)
            }
        }
        if restorationFailed { throw PodBridgeError.restoreFailed }
    }

    private static func failIfInjected(_ point: TestFailurePoint) throws {
#if DEBUG
        testFailureLock.lock()
        defer { testFailureLock.unlock() }
        guard pendingTestFailure == point else { return }
        pendingTestFailure = nil
        throw PodBridgeError.databaseVerificationFailed
#else
        _ = point
#endif
    }

    private static func createBackup(original: Data, in itunes: URL) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let parent = itunes.appendingPathComponent("PodBridge Backups", isDirectory: true)
        var folder = parent.appendingPathComponent(stamp, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try original.write(to: folder.appendingPathComponent("iTunesDB"), options: .atomic)
        guard try Data(contentsOf: folder.appendingPathComponent("iTunesDB")) == original else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return folder
    }

    private static func playlistArtworkManifestURL(root: URL) -> URL {
        root.appendingPathComponent("iPod_Control/iTunes/PodBridgePlaylistArtwork.json")
    }

    private static func readPlaylistArtworkManifest(root: URL) -> PlaylistArtworkManifest? {
        let url = playlistArtworkManifestURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PlaylistArtworkManifest.self, from: data),
              manifest.version == 1 else { return nil }
        return manifest
    }

    private static func addPlaylistArtworkAnchors(_ anchors: Set<UInt32>, root: URL) throws {
        var stored = Set(readPlaylistArtworkManifest(root: root)?.anchorTrackIDs ?? [])
        stored.formUnion(anchors)
        let manifest = PlaylistArtworkManifest(version: 1, anchorTrackIDs: stored.sorted())
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: playlistArtworkManifestURL(root: root), options: .atomic)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
