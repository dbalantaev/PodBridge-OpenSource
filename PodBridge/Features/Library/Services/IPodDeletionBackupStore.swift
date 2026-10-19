// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Persists and discovers recoverable deletion bundles in app-local storage.
///
/// Each manifest identifies the device and hashes the original database, the
/// deleted database, and the retained audio before a restore is offered.
extension IPodSyncEngine {
    struct DeletionManifest: Codable {
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

    static func discardDeletionBackup(_ backup: DeletionBackup) throws {
        let manifest = try readDeletionManifest(folder: backup.folderURL)
        guard manifest.completed, manifest.trackID == backup.trackID else {
            throw PodBridgeError.deletionRestoreUnavailable
        }
        try FileManager.default.removeItem(at: backup.folderURL)
        AppLogger.database(
            "Local deleted-track backup discarded id=\(backup.trackID) title=\(backup.title)",
            level: .info
        )
    }

    static func resolvedDeletionBackupRoot(override: URL?) throws -> URL {
        if let override { return override }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PodBridgeError.deletionBackupFailed
        }
        return documents.appendingPathComponent("PodBridge Deleted Tracks", isDirectory: true)
    }

    static func writeDeletionManifest(_ manifest: DeletionManifest, folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: folder.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    static func readDeletionManifest(folder: URL) throws -> DeletionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            DeletionManifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        )
    }
}
