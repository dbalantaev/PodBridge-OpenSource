// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Coordinates irreversible library deletion after activating a verified database.
///
/// Database rollback remains possible until activation is verified. Audio removal
/// starts only afterward and reports individual cleanup failures to the caller.
extension IPodSyncEngine {
    private enum PermanentDeletionSelection: Sendable {
        case tracks([UInt32])
        case playlist(Int)
        case library

        var removesPlaylist: Bool {
            if case .playlist = self { return true }
            return false
        }

        var clearsLibrary: Bool {
            if case .library = self { return true }
            return false
        }
    }

    private struct PermanentDeletionEnvironment {
        let manager: FileManager
        let store: LocalIPodVolumeStore
        let itunesURL: URL
        let temporaryDatabaseURL: URL
        let originalDatabase: Data
        let firewireID: Data
        let playCountsURL: URL
        let hasPlayCounts: Bool
    }

    private struct AudioCleanupResult {
        let freedBytes: UInt64
        let failedFileDeletions: Int
    }

    static func deleteTracksPermanently(
        ids: [UInt32],
        root: URL,
        progress: (@Sendable (DeletionProgress) async -> Void)? = nil
    ) async throws -> PermanentDeletionResult {
        try await performPermanentDeletion(selection: .tracks(ids), root: root, progress: progress)
    }

    static func clearLibrary(
        root: URL,
        progress: @escaping @Sendable (DeletionProgress) async -> Void
    ) async throws -> PermanentDeletionResult {
        try await performPermanentDeletion(selection: .library, root: root, progress: progress)
    }

    static func deletePlaylistAndTracks(index: Int, root: URL) async throws -> PermanentDeletionResult {
        try await performPermanentDeletion(selection: .playlist(index), root: root)
    }

    private static func performPermanentDeletion(
        selection: PermanentDeletionSelection,
        root: URL,
        progress: (@Sendable (DeletionProgress) async -> Void)? = nil
    ) async throws -> PermanentDeletionResult {
        try await Task.detached(priority: .userInitiated) {
            try await deletePermanentlySynchronously(selection: selection, root: root, progress: progress)
        }.value
    }

    private static func deletePermanentlySynchronously(
        selection: PermanentDeletionSelection,
        root: URL,
        progress: (@Sendable (DeletionProgress) async -> Void)?
    ) async throws -> PermanentDeletionResult {
        try Task.checkCancellation()
        let environment = try preparePermanentDeletion(root: root)
        let database = try databaseApplyingPlayCounts(environment: environment)
        await progress?(DeletionProgress(stage: "Preparing the iPod library", completed: 0, total: 0))
        let removal = try makePermanentRemoval(
            selection: selection,
            database: database,
            firewireID: environment.firewireID
        )
        let files = removal.removedTracks.compactMap { track -> (ClassicTrack, URL)? in
            guard let url = trackURL(path: track.ipodPath, root: root) else { return nil }
            return (track, url)
        }
        try activatePermanentDeletion(removal, environment: environment)
        let cleanup = await removePermanentAudioFiles(
            files,
            missingFileCount: removal.removedTracks.count - files.count,
            manager: environment.manager,
            progress: progress
        )
        logPermanentDeletion(selection: selection, removal: removal, cleanup: cleanup)
        return PermanentDeletionResult(
            removedTracks: removal.removedTracks,
            remainingTracks: removal.library.tracks.count,
            freedBytes: cleanup.freedBytes,
            failedFileDeletions: cleanup.failedFileDeletions
        )
    }

    private static func preparePermanentDeletion(root: URL) throws -> PermanentDeletionEnvironment {
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
        let itunesURL = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let diagnostics = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard diagnostics.primaryPlaylistFound,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            throw PodBridgeError.libraryRestoreRequired
        }
        let playCountsURL = itunesURL.appendingPathComponent("Play Counts")
        return PermanentDeletionEnvironment(
            manager: manager,
            store: store,
            itunesURL: itunesURL,
            temporaryDatabaseURL: itunesURL.appendingPathComponent("iTunesDB.podbridge.delete.tmp"),
            originalDatabase: original,
            firewireID: firewireID,
            playCountsURL: playCountsURL,
            hasPlayCounts: manager.fileExists(atPath: playCountsURL.path)
        )
    }

    private static func databaseApplyingPlayCounts(environment: PermanentDeletionEnvironment) throws -> Data {
        guard environment.hasPlayCounts else { return environment.originalDatabase }
        let counts = try Data(contentsOf: environment.playCountsURL, options: .mappedIfSafe)
        guard !counts.isEmpty else { return environment.originalDatabase }
        return try ClassicDatabase.applyingPlayCounts(
            counts,
            to: environment.originalDatabase,
            firewireID: environment.firewireID
        )
    }

    private static func makePermanentRemoval(
        selection: PermanentDeletionSelection,
        database: Data,
        firewireID: Data
    ) throws -> ClassicDatabase.BatchRemovalResult {
        switch selection {
        case .tracks(let ids):
            return try ClassicDatabase.removingTracks(
                existing: database,
                trackIDs: ids,
                firewireID: firewireID
            )
        case .playlist(let index):
            return try makePlaylistRemoval(index: index, database: database, firewireID: firewireID)
        case .library:
            return try ClassicDatabase.clearingLibrary(existing: database, firewireID: firewireID)
        }
    }

    private static func makePlaylistRemoval(
        index: Int,
        database: Data,
        firewireID: Data
    ) throws -> ClassicDatabase.BatchRemovalResult {
        let library = try ClassicDatabase.parse(database)
        guard library.playlists.indices.contains(index) else { throw PodBridgeError.playlistNotFound }
        let trackIDs = importedCompilationTrackIDs(
            playlist: library.playlists[index],
            tracks: library.tracks
        )
        let playlistRemoval = try ClassicDatabase.removingPlaylist(
            existing: database,
            playlistIndex: index,
            firewireID: firewireID
        )
        guard !trackIDs.isEmpty else {
            return ClassicDatabase.BatchRemovalResult(
                data: playlistRemoval.data,
                library: playlistRemoval.library,
                removedTracks: []
            )
        }
        return try ClassicDatabase.removingTracks(
            existing: playlistRemoval.data,
            trackIDs: trackIDs,
            firewireID: firewireID
        )
    }

    private static func activatePermanentDeletion(
        _ removal: ClassicDatabase.BatchRemovalResult,
        environment: PermanentDeletionEnvironment
    ) throws {
        var databaseActivated = false
        do {
            try environment.store.writeVerifiedDatabase(removal.data, to: environment.temporaryDatabaseURL)
            try environment.store.replaceDatabase(with: environment.temporaryDatabaseURL)
            databaseActivated = true
            try failIfInjected(.afterDatabaseReplacement)
            let active = try environment.store.readDatabase()
            let diagnostics = try ClassicDatabase.inspect(active, firewireID: environment.firewireID)
            guard active == removal.data,
                  try ClassicDatabase.parse(active) == removal.library,
                  diagnostics.hash58Valid,
                  diagnostics.playlistSectionsConsistent,
                  diagnostics.primaryPlaylistMembers == removal.library.tracks.count,
                  diagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid else {
                throw PodBridgeError.databaseVerificationFailed
            }
            if environment.hasPlayCounts {
                let archive = environment.itunesURL
                    .appendingPathComponent("Play Counts.podbridge.\(UUID().uuidString).bak")
                try environment.manager.moveItem(at: environment.playCountsURL, to: archive)
            }
        } catch {
            environment.store.removeItem(at: environment.temporaryDatabaseURL)
            if databaseActivated {
                try rollbackPermanentDeletion(environment: environment)
            }
            throw error
        }
    }

    private static func rollbackPermanentDeletion(environment: PermanentDeletionEnvironment) throws {
        do {
            try environment.store.restoreDatabase(environment.originalDatabase)
            guard try environment.store.readDatabase() == environment.originalDatabase else {
                throw PodBridgeError.restoreFailed
            }
        } catch {
            AppLogger.database(
                "Permanent deletion rollback failed error=\(error.localizedDescription)",
                level: .error
            )
            throw PodBridgeError.restoreFailed
        }
    }

    private static func removePermanentAudioFiles(
        _ files: [(ClassicTrack, URL)],
        missingFileCount: Int,
        manager: FileManager,
        progress: (@Sendable (DeletionProgress) async -> Void)?
    ) async -> AudioCleanupResult {
        var freedBytes: UInt64 = 0
        var failed = missingFileCount
        for (index, item) in files.enumerated() {
            let (track, url) = item
            if manager.fileExists(atPath: url.path) {
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
                        "Orphan audio cleanup failed id=\(track.id) "
                            + "path=\(track.ipodPath) error=\(error.localizedDescription)",
                        level: .error
                    )
                }
            }
            await progress?(
                DeletionProgress(stage: "Removing audio files", completed: index + 1, total: files.count)
            )
        }
        return AudioCleanupResult(freedBytes: freedBytes, failedFileDeletions: failed)
    }

    private static func logPermanentDeletion(
        selection: PermanentDeletionSelection,
        removal: ClassicDatabase.BatchRemovalResult,
        cleanup: AudioCleanupResult
    ) {
        AppLogger.database(
            "Permanent deletion completed tracks=\(removal.removedTracks.count) "
                + "playlistRemoved=\(selection.removesPlaylist) clearLibrary=\(selection.clearsLibrary) "
                + "remaining=\(removal.library.tracks.count) freedBytes=\(cleanup.freedBytes) "
                + "failedFileDeletions=\(cleanup.failedFileDeletions) audioBackup=false hash58=valid",
            level: cleanup.failedFileDeletions == 0 ? .info : .error
        )
    }
}
