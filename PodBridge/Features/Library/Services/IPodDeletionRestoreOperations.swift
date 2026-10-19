// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import CryptoKit
import Foundation

/// Restores one recoverable deletion only while the active database still
/// matches the exact post-deletion state recorded in its local manifest.
extension IPodSyncEngine {
    private struct DeletionRestoreEnvironment {
        let manager: FileManager
        let store: LocalIPodVolumeStore
        let manifest: DeletionManifest
        let audioBackupURL: URL
        let activeDatabase: Data
        let originalDatabase: Data
        let firewireID: Data
        let restoredLibrary: ClassicLibrary
        let audioDestinationURL: URL
    }

    private enum DeletionRestoreInternalError: Error {
        case databaseRollbackFailed
    }

    static func restoreDeletion(
        _ backup: DeletionBackup,
        root: URL
    ) async throws -> ClassicLibrary {
        try await Task.detached(priority: .userInitiated) {
            try restoreDeletionSynchronously(backup, root: root)
        }.value
    }

    private static func restoreDeletionSynchronously(
        _ backup: DeletionBackup,
        root: URL
    ) throws -> ClassicLibrary {
        try Task.checkCancellation()
        let environment = try prepareDeletionRestore(backup: backup, root: root)
        var copiedAudio = false
        do {
            try restoreDeletedAudio(environment: environment, copiedAudio: &copiedAudio)
            try activateRestoredDatabase(backup: backup, environment: environment)
            try? environment.manager.removeItem(at: backup.folderURL)
            logCompletedDeletionRestore(environment: environment)
            return environment.restoredLibrary
        } catch DeletionRestoreInternalError.databaseRollbackFailed {
            throw PodBridgeError.restoreFailed
        } catch {
            let operationError = error
            if copiedAudio {
                try rollbackRestoredAudio(environment: environment)
            }
            AppLogger.database(
                "Deleted track restore failed id=\(environment.manifest.trackID) "
                    + "error=\(operationError.localizedDescription)",
                level: .error
            )
            throw operationError
        }
    }

    private static func prepareDeletionRestore(
        backup: DeletionBackup,
        root: URL
    ) throws -> DeletionRestoreEnvironment {
        let manager = FileManager.default
        let store = LocalIPodVolumeStore(root: root, manager: manager)
        let manifest = try readDeletionManifest(folder: backup.folderURL)
        guard manifest.completed, manifest.trackID == backup.trackID else {
            throw PodBridgeError.deletionRestoreUnavailable
        }
        let original = try Data(
            contentsOf: backup.folderURL.appendingPathComponent("iTunesDB"),
            options: .mappedIfSafe
        )
        let active = try store.readDatabase()
        guard Data(SHA256.hash(data: active)).hexString == manifest.deletedDatabaseSHA256,
              Data(SHA256.hash(data: original)).hexString == manifest.originalDatabaseSHA256 else {
            throw PodBridgeError.deletionRestoreUnavailable
        }
        let audioBackupURL = backup.folderURL.appendingPathComponent(manifest.audioFilename)
        var cache: [String: Data] = [:]
        guard try sha256(of: audioBackupURL, cache: &cache).hexString == manifest.audioSHA256,
              try audioBackupURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(manifest.byteCount) else {
            throw PodBridgeError.deletionBackupFailed
        }
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        guard firewireID.hexString == manifest.deviceIdentifier else {
            throw PodBridgeError.deletionRestoreUnavailable
        }
        let restoredLibrary = try ClassicDatabase.parse(original)
        let diagnostics = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard restoredLibrary.tracks.contains(where: { $0.id == manifest.trackID }),
              diagnostics.hash58Valid,
              diagnostics.playlistSectionsConsistent,
              diagnostics.primaryPlaylistMembers == restoredLibrary.tracks.count,
              let destination = trackURL(path: manifest.originalIPodPath, root: root) else {
            throw PodBridgeError.deletionBackupFailed
        }
        return DeletionRestoreEnvironment(
            manager: manager,
            store: store,
            manifest: manifest,
            audioBackupURL: audioBackupURL,
            activeDatabase: active,
            originalDatabase: original,
            firewireID: firewireID,
            restoredLibrary: restoredLibrary,
            audioDestinationURL: destination
        )
    }

    private static func restoreDeletedAudio(
        environment: DeletionRestoreEnvironment,
        copiedAudio: inout Bool
    ) throws {
        let destination = environment.audioDestinationURL
        try environment.manager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if environment.manager.fileExists(atPath: destination.path) {
            var existingCache: [String: Data] = [:]
            guard try sha256(of: destination, cache: &existingCache).hexString
                    == environment.manifest.audioSHA256 else {
                throw PodBridgeError.deletionRestoreUnavailable
            }
        } else {
            try environment.manager.copyItem(at: environment.audioBackupURL, to: destination)
            copiedAudio = true
        }
        var restoredCache: [String: Data] = [:]
        guard try sha256(of: destination, cache: &restoredCache).hexString
                == environment.manifest.audioSHA256 else {
            throw PodBridgeError.audioCopyVerificationFailed
        }
    }

    private static func activateRestoredDatabase(
        backup: DeletionBackup,
        environment: DeletionRestoreEnvironment
    ) throws {
        var transaction: IPodDatabaseTransaction?
        do {
            transaction = try IPodDatabaseTransaction(
                store: environment.store,
                original: environment.activeDatabase,
                temporaryName: "iTunesDB.podbridge.restore-deletion.tmp",
                backupURL: backup.folderURL
            ) {
                try failIfInjected(.afterDatabaseReplacement)
            }
            guard let transaction else { throw PodBridgeError.databaseVerificationFailed }
            try transaction.stage(environment.originalDatabase)
            try transaction.activate()
            let written = try environment.store.readDatabase()
            guard written == environment.originalDatabase,
                  try ClassicDatabase.inspect(written, firewireID: environment.firewireID).hash58Valid else {
                throw PodBridgeError.databaseVerificationFailed
            }
        } catch {
            let operationError = error
            do {
                try transaction?.rollback()
            } catch {
                AppLogger.database(
                    "Deleted track database rollback failed id=\(environment.manifest.trackID) "
                        + "error=\(error.localizedDescription); restored audio retained",
                    level: .error
                )
                throw DeletionRestoreInternalError.databaseRollbackFailed
            }
            throw operationError
        }
    }

    private static func rollbackRestoredAudio(environment: DeletionRestoreEnvironment) throws {
        do {
            try environment.manager.removeItem(at: environment.audioDestinationURL)
            guard !environment.manager.fileExists(atPath: environment.audioDestinationURL.path) else {
                throw PodBridgeError.restoreFailed
            }
        } catch {
            AppLogger.database(
                "Deleted track audio rollback failed id=\(environment.manifest.trackID) "
                    + "error=\(error.localizedDescription)",
                level: .error
            )
            throw PodBridgeError.restoreFailed
        }
    }

    private static func logCompletedDeletionRestore(environment: DeletionRestoreEnvironment) {
        AppLogger.database(
            "Deleted track restored id=\(environment.manifest.trackID) "
                + "title=\(environment.manifest.title) tracks=\(environment.restoredLibrary.tracks.count) "
                + "localBackupRemoved=true",
            level: .info
        )
    }
}
