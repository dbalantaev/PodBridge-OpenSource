// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import CryptoKit
import Foundation

/// Owns interrupted recovery and the recoverable single-track deletion flow.
///
/// The manifest binds audio and both database states to one device. Recovery is
/// allowed only while those hashes still describe the active deletion operation.
extension IPodSyncEngine {

    private struct InterruptedDeletionEnvironment {
        let manager: FileManager
        let root: URL
        let firewireID: Data
        let databaseURL: URL
    }

    private struct TrackDeletionEnvironment {
        let manager: FileManager
        let store: LocalIPodVolumeStore
        let originalDatabase: Data
        let firewireID: Data
        let removal: ClassicDatabase.RemovalResult
        let audioURL: URL
        let audioSize: Int
        let bundleURL: URL
        let databaseBackupURL: URL
        let audioFilename: String
        let audioBackupURL: URL
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
        let environment = InterruptedDeletionEnvironment(
            manager: manager,
            root: root,
            firewireID: firewireID,
            databaseURL: root.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        )
        for folder in folders {
            guard let manifest = try? readDeletionManifest(folder: folder),
                  !manifest.completed,
                  manifest.deviceIdentifier == firewireID.hexString else { continue }
            try recoverInterruptedDeletion(folder: folder, manifest: manifest, environment: environment)
        }
    }

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

    private static func recoverInterruptedDeletion(
        folder: URL,
        manifest: DeletionManifest,
        environment: InterruptedDeletionEnvironment
    ) throws {
        let databaseBackupURL = folder.appendingPathComponent("iTunesDB")
        let audioBackupURL = folder.appendingPathComponent(manifest.audioFilename)
        guard let original = try? Data(contentsOf: databaseBackupURL),
              Data(SHA256.hash(data: original)).hexString == manifest.originalDatabaseSHA256,
              let audioDestination = trackURL(path: manifest.originalIPodPath, root: environment.root) else {
            throw PodBridgeError.deletionBackupFailed
        }
        var backupCache: [String: Data] = [:]
        guard (try? sha256(of: audioBackupURL, cache: &backupCache).hexString) == manifest.audioSHA256 else {
            throw PodBridgeError.deletionBackupFailed
        }
        let active = try Data(contentsOf: environment.databaseURL, options: .mappedIfSafe)
        let activeHash = Data(SHA256.hash(data: active)).hexString
        guard activeHash == manifest.originalDatabaseSHA256
                || activeHash == manifest.deletedDatabaseSHA256 else {
            AppLogger.database(
                "Interrupted deletion left untouched id=\(manifest.trackID) because active library changed",
                level: .error
            )
            return
        }
        if !environment.manager.fileExists(atPath: audioDestination.path) {
            try environment.manager.createDirectory(
                at: audioDestination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try environment.manager.copyItem(at: audioBackupURL, to: audioDestination)
        }
        var restoredAudioCache: [String: Data] = [:]
        guard try sha256(of: audioDestination, cache: &restoredAudioCache).hexString
                == manifest.audioSHA256 else {
            throw PodBridgeError.deletionBackupFailed
        }
        if activeHash == manifest.deletedDatabaseSHA256 {
            try original.write(to: environment.databaseURL, options: .atomic)
            let restored = try Data(contentsOf: environment.databaseURL, options: .mappedIfSafe)
            guard restored == original,
                  try ClassicDatabase.inspect(restored, firewireID: environment.firewireID).hash58Valid else {
                throw PodBridgeError.databaseVerificationFailed
            }
        }
        try environment.manager.removeItem(at: folder)
        AppLogger.database(
            "Interrupted deletion automatically rolled back id=\(manifest.trackID) title=\(manifest.title)",
            level: .info
        )
    }

    private static func deleteTrackSynchronously(
        id: UInt32,
        root: URL,
        backupRoot: URL?
    ) throws -> DeletionResult {
        try Task.checkCancellation()
        let environment = try prepareTrackDeletion(id: id, root: root, backupRoot: backupRoot)
        var transaction: IPodDatabaseTransaction?
        do {
            var manifest = try createVerifiedDeletionBackup(environment: environment)
            transaction = try IPodDatabaseTransaction(
                store: environment.store,
                original: environment.originalDatabase,
                temporaryName: "iTunesDB.podbridge.delete.tmp",
                backupURL: environment.bundleURL
            ) {
                try failIfInjected(.afterDatabaseReplacement)
            }
            guard let transaction else { throw PodBridgeError.databaseVerificationFailed }
            try activateDeletedDatabase(transaction: transaction, environment: environment)
            try failIfInjected(.beforeAudioDelete)
            try environment.manager.removeItem(at: environment.audioURL)
            guard !environment.manager.fileExists(atPath: environment.audioURL.path) else {
                throw PodBridgeError.audioCopyVerificationFailed
            }
            manifest.completed = true
            try writeDeletionManifest(manifest, folder: environment.bundleURL)
            return completedDeletionResult(environment: environment, manifest: manifest)
        } catch {
            let operationError = error
            let restorationFailed = rollbackTrackDeletion(transaction: transaction, environment: environment)
            if !restorationFailed { try? environment.manager.removeItem(at: environment.bundleURL) }
            AppLogger.database(
                "Track deletion failed id=\(id) error=\(operationError.localizedDescription); "
                    + "rollback=\(restorationFailed ? "failed" : "completed")",
                level: .error
            )
            if restorationFailed { throw PodBridgeError.restoreFailed }
            throw operationError
        }
    }

    private static func prepareTrackDeletion(
        id: UInt32,
        root: URL,
        backupRoot: URL?
    ) throws -> TrackDeletionEnvironment {
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
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
        let removal = try ClassicDatabase.removingTrack(
            existing: original,
            trackID: id,
            firewireID: firewireID
        )
        guard let audioURL = trackURL(path: removal.removedTrack.ipodPath, root: root),
              manager.fileExists(atPath: audioURL.path),
              let audioSize = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              audioSize > 0,
              audioSize == Int(removal.removedTrack.byteCount) else {
            throw PodBridgeError.audioCopyVerificationFailed
        }
        let bundle = try createDeletionBackupBundle(
            trackID: id,
            requiredBytes: audioSize + original.count + 10_000_000,
            backupRoot: backupRoot,
            manager: manager
        )
        let fileExtension = audioURL.pathExtension.lowercased()
        let audioFilename = fileExtension.isEmpty ? "audio" : "audio.\(fileExtension)"
        return TrackDeletionEnvironment(
            manager: manager,
            store: store,
            originalDatabase: original,
            firewireID: firewireID,
            removal: removal,
            audioURL: audioURL,
            audioSize: audioSize,
            bundleURL: bundle,
            databaseBackupURL: bundle.appendingPathComponent("iTunesDB"),
            audioFilename: audioFilename,
            audioBackupURL: bundle.appendingPathComponent(audioFilename)
        )
    }

    private static func createDeletionBackupBundle(
        trackID: UInt32,
        requiredBytes: Int,
        backupRoot: URL?,
        manager: FileManager
    ) throws -> URL {
        let localRoot = try resolvedDeletionBackupRoot(override: backupRoot)
        try manager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        if let capacity = try? localRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           capacity < Int64(requiredBytes) {
            throw PodBridgeError.deletionBackupFailed
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let bundle = localRoot.appendingPathComponent(
            "\(stamp)-track-\(trackID)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    private static func createVerifiedDeletionBackup(
        environment: TrackDeletionEnvironment
    ) throws -> DeletionManifest {
        try environment.originalDatabase.write(to: environment.databaseBackupURL, options: .atomic)
        try environment.manager.copyItem(at: environment.audioURL, to: environment.audioBackupURL)
        var sourceCache: [String: Data] = [:]
        let sourceDigest = try sha256(of: environment.audioURL, cache: &sourceCache)
        var backupCache: [String: Data] = [:]
        let backupDigest = try sha256(of: environment.audioBackupURL, cache: &backupCache)
        guard sourceDigest == backupDigest,
              try Data(contentsOf: environment.databaseBackupURL) == environment.originalDatabase,
              try environment.audioBackupURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                == environment.audioSize else {
            throw PodBridgeError.deletionBackupFailed
        }
        let track = environment.removal.removedTrack
        let manifest = DeletionManifest(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            byteCount: track.byteCount,
            createdAt: Date(),
            originalIPodPath: track.ipodPath,
            audioFilename: environment.audioFilename,
            audioSHA256: sourceDigest.hexString,
            originalDatabaseSHA256: Data(SHA256.hash(data: environment.originalDatabase)).hexString,
            deletedDatabaseSHA256: Data(SHA256.hash(data: environment.removal.data)).hexString,
            deviceIdentifier: environment.firewireID.hexString,
            completed: false
        )
        try writeDeletionManifest(manifest, folder: environment.bundleURL)
        try Task.checkCancellation()
        return manifest
    }

    private static func activateDeletedDatabase(
        transaction: IPodDatabaseTransaction,
        environment: TrackDeletionEnvironment
    ) throws {
        try transaction.stage(environment.removal.data)
        try transaction.activate()
        let active = try environment.store.readDatabase()
        let diagnostics = try ClassicDatabase.inspect(active, firewireID: environment.firewireID)
        guard active == environment.removal.data,
              diagnostics.hash58Valid,
              diagnostics.playlistSectionsConsistent,
              diagnostics.primaryPlaylistMembers == environment.removal.library.tracks.count,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid else {
            throw PodBridgeError.databaseVerificationFailed
        }
    }

    private static func rollbackTrackDeletion(
        transaction: IPodDatabaseTransaction?,
        environment: TrackDeletionEnvironment
    ) -> Bool {
        var restorationFailed = false
        let databaseWasActivated = transaction?.databaseActivated == true
        if let transaction {
            do {
                try transaction.rollback()
            } catch {
                restorationFailed = true
                AppLogger.database(
                    "Track deletion database rollback failed id=\(environment.removal.removedTrack.id) "
                        + "error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
        if databaseWasActivated, !environment.manager.fileExists(atPath: environment.audioURL.path) {
            do {
                try environment.manager.createDirectory(
                    at: environment.audioURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try environment.manager.copyItem(at: environment.audioBackupURL, to: environment.audioURL)
            } catch {
                restorationFailed = true
                AppLogger.database(
                    "Track deletion audio rollback failed id=\(environment.removal.removedTrack.id) "
                        + "error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
        if databaseWasActivated, !environment.manager.fileExists(atPath: environment.audioURL.path) {
            restorationFailed = true
        }
        return restorationFailed
    }

    private static func completedDeletionResult(
        environment: TrackDeletionEnvironment,
        manifest: DeletionManifest
    ) -> DeletionResult {
        let track = environment.removal.removedTrack
        let backup = DeletionBackup(
            folderURL: environment.bundleURL,
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            byteCount: track.byteCount,
            createdAt: manifest.createdAt,
            deviceIdentifier: manifest.deviceIdentifier
        )
        AppLogger.database(
            "Track deleted id=\(track.id) title=\(track.title) bytesFreed=\(environment.audioSize) "
                + "remainingTracks=\(environment.removal.library.tracks.count) "
                + "localBackup=\(environment.bundleURL.lastPathComponent) hash58=valid",
            level: .info
        )
        return DeletionResult(
            deletedTrack: track,
            remainingTracks: environment.removal.library.tracks.count,
            freedBytes: UInt32(clamping: environment.audioSize),
            backup: backup
        )
    }

}
