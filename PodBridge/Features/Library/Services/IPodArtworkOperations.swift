// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import AVFoundation
import Foundation

extension IPodSyncEngine {
    struct PlaylistArtworkManifest: Codable {
        var version: Int
        var anchorTrackIDs: [UInt32]
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
        replaceExistingPlaylistArtwork: Bool = true,
        progress: @escaping @Sendable (ArtworkSearchProgress) async -> Void
    ) async throws -> ArtworkSearchResult {
        let task = Task.detached(priority: .userInitiated) {
            try await findMissingArtworkSynchronously(
                root: root,
                lookup: lookup,
                replaceExistingPlaylistArtwork: replaceExistingPlaylistArtwork,
                progress: progress
            )
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
        guard restoredDiagnostics.primaryPlaylistFound,
              restoredDiagnostics.primaryPlaylistMembers == restoredLibrary.tracks.count,
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
        guard trackInventoryIsPreserved(before: library, after: edit.library),
              tracksDifferOnlyByArtwork(before: library, after: edit.library) else {
            AppLogger.artwork(
                "Playlist artwork rejected reason=non-artwork-library-change before=\(library.tracks.count) after=\(edit.library.tracks.count)",
                level: .error
            )
            throw PodBridgeError.databaseVerificationFailed
        }
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
                  diagnostics.primaryPlaylistFound == originalDiagnostics.primaryPlaylistFound,
                  diagnostics.primaryPlaylistMembers == originalDiagnostics.primaryPlaylistMembers,
                  diagnostics.playlistSectionTypes == originalDiagnostics.playlistSectionTypes,
                  diagnostics.playlistSectionsConsistent == originalDiagnostics.playlistSectionsConsistent,
                  diagnostics.sortIndexesValid == originalDiagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid == originalDiagnostics.jumpTablesValid else {
                AppLogger.artwork(
                    "Playlist artwork active verification failed bytes=\(active.count)/\(edit.data.count) "
                        + "hash58=\(diagnostics.hash58Valid) master=\(diagnostics.primaryPlaylistFound)/\(originalDiagnostics.primaryPlaylistFound) "
                        + "members=\(diagnostics.primaryPlaylistMembers)/\(originalDiagnostics.primaryPlaylistMembers) "
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
        guard trackInventoryIsPreserved(before: library, after: edit.library),
              tracksDifferOnlyByArtwork(before: library, after: edit.library) else {
            AppLogger.artwork(
                "\(logOperation) rejected reason=non-artwork-library-change before=\(library.tracks.count) after=\(edit.library.tracks.count)",
                level: .error
            )
            throw PodBridgeError.databaseVerificationFailed
        }
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
                  diagnostics.primaryPlaylistFound == originalDiagnostics.primaryPlaylistFound,
                  diagnostics.primaryPlaylistMembers == originalDiagnostics.primaryPlaylistMembers,
                  diagnostics.playlistSectionTypes == originalDiagnostics.playlistSectionTypes,
                  diagnostics.playlistSectionsConsistent == originalDiagnostics.playlistSectionsConsistent,
                  diagnostics.sortIndexesValid == originalDiagnostics.sortIndexesValid,
                  diagnostics.jumpTablesValid == originalDiagnostics.jumpTablesValid else {
                AppLogger.artwork(
                    "\(logOperation) active verification failed bytes=\(active.count)/\(edit.data.count) "
                        + "hash58=\(diagnostics.hash58Valid) master=\(diagnostics.primaryPlaylistFound)/\(originalDiagnostics.primaryPlaylistFound) "
                        + "members=\(diagnostics.primaryPlaylistMembers)/\(originalDiagnostics.primaryPlaylistMembers) "
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

    /// A metadata, playlist, or artwork edit must never add, remove, replace, or
    /// redirect an audio record. Comparing the master member count alone is not
    /// sufficient: a malformed rewrite could theoretically replace one track
    /// with another while keeping the same total.
    static func trackInventoryIsPreserved(
        before: ClassicLibrary,
        after: ClassicLibrary
    ) -> Bool {
        guard before.tracks.count == after.tracks.count,
              Set(before.tracks.map(\.id)).count == before.tracks.count,
              Set(after.tracks.map(\.id)).count == after.tracks.count else { return false }
        let afterByID = Dictionary(uniqueKeysWithValues: after.tracks.map { ($0.id, $0) })
        return before.tracks.allSatisfy { original in
            guard let updated = afterByID[original.id] else { return false }
            return updated.databaseID == original.databaseID
                && updated.ipodPath == original.ipodPath
                && updated.byteCount == original.byteCount
                && updated.durationMS == original.durationMS
                && updated.bitrate == original.bitrate
                && updated.sampleRate == original.sampleRate
                && updated.dateAdded == original.dateAdded
        }
    }

    /// Artwork repair is narrower than a general library edit. Every field
    /// except the artwork reference and decoded preview must remain identical.
    private static func tracksDifferOnlyByArtwork(
        before: ClassicLibrary,
        after: ClassicLibrary
    ) -> Bool {
        let afterByID = Dictionary(uniqueKeysWithValues: after.tracks.map { ($0.id, $0) })
        return before.tracks.allSatisfy { original in
            guard var updated = afterByID[original.id] else { return false }
            updated.artworkImageID = original.artworkImageID
            updated.artworkByteCount = original.artworkByteCount
            updated.artworkData = original.artworkData
            return updated == original
        }
    }

    private static func findMissingArtworkSynchronously(
        root: URL,
        lookup: ArtworkLookupService,
        replaceExistingPlaylistArtwork: Bool,
        progress: @escaping @Sendable (ArtworkSearchProgress) async -> Void
    ) async throws -> ArtworkSearchResult {
        try Task.checkCancellation()
        let store = LocalIPodVolumeStore(root: root)
        let original = try store.readDatabase()
        let firewireID = try IPodDeviceProfile.databaseKey(at: root)
        let originalLibrary = try ClassicDatabase.parse(original)
        let before = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard before.primaryPlaylistFound,
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
                && ($0.artworkImageID == 0 || replaceExistingPlaylistArtwork)
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
        guard trackInventoryIsPreserved(before: originalLibrary, after: edit.library),
              tracksDifferOnlyByArtwork(before: originalLibrary, after: edit.library) else {
            AppLogger.artwork(
                "Automatic artwork rejected reason=non-artwork-library-change before=\(originalLibrary.tracks.count) after=\(edit.library.tracks.count)",
                level: .error
            )
            throw PodBridgeError.databaseVerificationFailed
        }
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
                  diagnostics.primaryPlaylistMembers == edit.library.tracks.count,
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

    static func playlistArtworkManifestURL(root: URL) -> URL {
        root.appendingPathComponent("iPod_Control/iTunes/PodBridgePlaylistArtwork.json")
    }

    static func readPlaylistArtworkManifest(root: URL) -> PlaylistArtworkManifest? {
        let url = playlistArtworkManifestURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(PlaylistArtworkManifest.self, from: data),
              manifest.version == 1 else { return nil }
        return manifest
    }

    static func addPlaylistArtworkAnchors(_ anchors: Set<UInt32>, root: URL) throws {
        var stored = Set(readPlaylistArtworkManifest(root: root)?.anchorTrackIDs ?? [])
        stored.formUnion(anchors)
        let manifest = PlaylistArtworkManifest(version: 1, anchorTrackIDs: stored.sorted())
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: playlistArtworkManifestURL(root: root), options: .atomic)
    }
}
