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
    private final class TestFailureState: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: TestFailurePoint?

        func set(_ point: TestFailurePoint?) {
            lock.lock()
            defer { lock.unlock() }
            pending = point
        }

        func consume(_ point: TestFailurePoint) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard pending == point else { return false }
            pending = nil
            return true
        }
    }

    private static let testFailureState = TestFailureState()

    /// Installs one single-use failure for a deterministic rollback test.
    static func setTestFailure(_ point: TestFailurePoint?) {
#if DEBUG
        testFailureState.set(point)
#else
        _ = point
#endif
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
        let original = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let playCountsURL = root.appendingPathComponent("iPod_Control/iTunes/Play Counts")
        if let counts = try? Data(contentsOf: playCountsURL, options: .mappedIfSafe),
           let key = try? IPodDeviceProfile.databaseKey(at: root),
           let applied = try? ClassicDatabase.applyingPlayCounts(counts, to: original, firewireID: key) {
            return try ClassicDatabase.parse(applied)
        }
        return try ClassicDatabase.parse(original)
    }

    /// Restores ratings and playback statistics from a PodBridge export manifest.
    /// Playlists with the same name are replaced; other playlists are retained.
    static func importLibraryJSON(_ jsonURL: URL, root: URL) async throws -> LibraryImportResult {
        try await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(ExportLibrary.self, from: Data(contentsOf: jsonURL))
            guard manifest.format == "PodBridge Library", manifest.version == 1 else {
                throw PodBridgeError.invalidMetadata
            }
            let store = LocalIPodVolumeStore(root: root)
            let original = try store.readDatabase()
            let firewireID = try IPodDeviceProfile.databaseKey(at: root)
            var currentData = original
            let playCountsURL = root.appendingPathComponent("iPod_Control/iTunes/Play Counts")
            if let counts = try? Data(contentsOf: playCountsURL, options: .mappedIfSafe) {
                currentData = try ClassicDatabase.applyingPlayCounts(counts, to: original, firewireID: firewireID)
            }
            var library = try ClassicDatabase.parse(currentData)
            let exportedByDatabaseID = Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.databaseID, $0) })
            var restored = 0
            for index in library.tracks.indices {
                let current = library.tracks[index]
                let fallback = manifest.tracks.first {
                    $0.title.caseInsensitiveCompare(current.title) == .orderedSame
                        && $0.artist.caseInsensitiveCompare(current.artist) == .orderedSame
                        && $0.album.caseInsensitiveCompare(current.album) == .orderedSame
                        && abs(Int64($0.durationMS) - Int64(current.durationMS)) <= 2_000
                }
                guard let saved = exportedByDatabaseID[current.databaseID] ?? fallback else { continue }
                library.tracks[index].rating = min(saved.rating, 100)
                library.tracks[index].playCount = saved.playCount
                library.tracks[index].skipCount = saved.skipCount
                library.tracks[index].lastPlayed = saved.lastPlayed
                library.tracks[index].lastSkipped = saved.lastSkipped
                restored += 1
            }
            let currentIDByDatabaseID = Dictionary(uniqueKeysWithValues: library.tracks.map { ($0.databaseID, $0.id) })
            var restoredPlaylists = 0
            for saved in manifest.playlists {
                let ids = saved.trackDatabaseIDs.compactMap { currentIDByDatabaseID[$0] }
                guard !ids.isEmpty else { continue }
                if let index = library.playlists.firstIndex(where: { $0.name.caseInsensitiveCompare(saved.name) == .orderedSame }) {
                    library.playlists[index].trackIDs = ids
                } else {
                    library.playlists.append(ClassicPlaylist(name: saved.name, trackIDs: ids))
                }
                restoredPlaylists += 1
            }
            guard restored > 0 else { throw PodBridgeError.trackNotFound }
            let databaseID = try currentData.littleUInt64(at: 0x18)
            let updated = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: databaseID)
            let verified = try ClassicDatabase.parse(updated)
            guard verified == library else { throw PodBridgeError.databaseVerificationFailed }
            let transaction = try IPodDatabaseTransaction(
                store: store, original: original,
                temporaryName: "iTunesDB.podbridge.library-import.tmp",
                afterActivation: { try failIfInjected(.afterDatabaseReplacement) }
            )
            do {
                try transaction.stage(updated)
                try transaction.activate()
                guard try store.readDatabase() == updated else { throw PodBridgeError.databaseVerificationFailed }
                if FileManager.default.fileExists(atPath: playCountsURL.path) {
                    let archive = playCountsURL.deletingLastPathComponent()
                        .appendingPathComponent("Play Counts.podbridge.\(UUID().uuidString).bak")
                    try FileManager.default.moveItem(at: playCountsURL, to: archive)
                }
                return LibraryImportResult(
                    library: verified, restoredTracks: restored,
                    restoredPlaylists: restoredPlaylists, backupURL: transaction.backupURL
                )
            } catch {
                try transaction.rollback()
                throw error
            }
        }.value
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
                      diagnostics.primaryPlaylistMembers == repaired.library.tracks.count,
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


    // MARK: - Track and playlist operations


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

    static func replacePlaylistMembers(index: Int, trackIDs: [UInt32], root: URL) async throws -> LibraryEditResult {
        try await Task.detached(priority: .userInitiated) {
            try editLibrarySynchronously(root: root, operation: .replacePlaylistMembers(index: index, trackIDs: trackIDs))
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
        var databaseForMerge: Data
        var playCountsURLToArchive: URL?
        let existingLibrary: ClassicLibrary
        let firewireID: Data
        do {
            original = try store.readDatabase()
            stage = "parse-existing-database"
            existingLibrary = try ClassicDatabase.parse(original)
            stage = "read-firewire-guid"
            firewireID = try IPodDeviceProfile.databaseKey(at: root)
            databaseForMerge = original
            let playCountsURL = itunes.appendingPathComponent("Play Counts")
            if manager.fileExists(atPath: playCountsURL.path) {
                stage = "merge-play-counts"
                let playCounts = try Data(contentsOf: playCountsURL, options: .mappedIfSafe)
                if !playCounts.isEmpty {
                    databaseForMerge = try ClassicDatabase.applyingPlayCounts(
                        playCounts,
                        to: original,
                        firewireID: firewireID
                    )
                    playCountsURLToArchive = playCountsURL
                }
            }
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
            "Playlist diagnostics total=\(beforeDiagnostics.playlists) sections=\(beforeDiagnostics.playlistSectionTypes) sectionCopies=\(beforeDiagnostics.playlistSectionsConsistent ? "consistent" : "diverged") master=\(beforeDiagnostics.primaryPlaylistFound ? "found" : "missing") masterMembers=\(beforeDiagnostics.primaryPlaylistMembers) sortIndexes=\(beforeDiagnostics.sortIndexesValid ? "valid" : "invalid") jumpTables=\(beforeDiagnostics.jumpTablesValid ? "valid" : "invalid") hash58=\(beforeDiagnostics.hash58Valid ? "valid" : "invalid")",
            level: beforeDiagnostics.primaryPlaylistFound && beforeDiagnostics.hash58Valid ? .info : .error
        )
        guard beforeDiagnostics.primaryPlaylistFound,
              beforeDiagnostics.primaryPlaylistMembers == existingLibrary.tracks.count,
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
        var sourceMembers = [ClassicDatabase.PendingPlaylistMember?](repeating: nil, count: files.count)
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
            try Task.checkCancellation()
            let pendingPlaylists = playlists.map {
                ClassicDatabase.PendingPlaylist(
                    name: $0.name,
                    members: $0.fileIndices.compactMap { sourceIndex in
                        sourceMembers.indices.contains(sourceIndex) ? sourceMembers[sourceIndex] : nil
                    }
                )
            }
            let merged = try ClassicDatabase.merge(
                existing: databaseForMerge,
                additions: additions,
                pendingPlaylists: pendingPlaylists,
                firewireID: firewireID
            )
            let afterDiagnostics = try ClassicDatabase.inspect(merged.data, firewireID: firewireID)
            AppLogger.database(
                "Database merged outputBytes=\(merged.data.count) totalTracks=\(merged.library.tracks.count) addedPlaylists=\(pendingPlaylists.count) totalPlaylists=\(afterDiagnostics.playlists) sections=\(afterDiagnostics.playlistSectionTypes) sectionCopies=\(afterDiagnostics.playlistSectionsConsistent ? "consistent" : "diverged") master=\(afterDiagnostics.primaryPlaylistFound ? "found" : "missing") masterMembersBefore=\(beforeDiagnostics.primaryPlaylistMembers) masterMembersAfter=\(afterDiagnostics.primaryPlaylistMembers) sortIndexes=\(afterDiagnostics.sortIndexesValid ? "valid" : "invalid") jumpTables=\(afterDiagnostics.jumpTablesValid ? "valid" : "invalid") hash58=\(afterDiagnostics.hash58Valid ? "valid" : "invalid")",
                level: .info
            )
            for audit in merged.addedTrackDiagnostics {
                AppLogger.database(
                    "Track database audit id=\(audit.id) valid=\(audit.isValid) marker=\(audit.marker.debugDescription) type1=\(audit.type1) type2=\(audit.type2) size=\(audit.sizePrimary)/\(audit.sizeRepeated) rootLibraryID=\(audit.rootLibraryIDValid ? "valid" : "invalid") dbids=\(audit.databaseIDsMatch ? "valid" : "invalid") masterCopies=\(audit.primaryMembershipValid ? "valid" : "invalid") path=\(audit.path)",
                    level: audit.isValid ? .info : .error
                )
            }
            let mergedAdditions = Array(merged.library.tracks.suffix(additions.count))
            stage = "prepare-artwork"
            try Task.checkCancellation()
            let artworkPlan = try ArtworkDatabase.prepare(root: root, tracks: mergedAdditions)
            stage = "create-backup"
            try Task.checkCancellation()
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
                try Task.checkCancellation()
                try ArtworkDatabase.apply(artworkPlan, backupFolder: backupFolder)
                appliedArtworkPlan = artworkPlan
                try failIfInjected(.afterArtworkApply)
            } else {
                AppLogger.artwork("No embedded artwork to add", level: .debug)
            }
            stage = "write-temporary-database"
            try Task.checkCancellation()
            try transaction.stage(merged.data)
            let written = try Data(contentsOf: transaction.temporaryURL)
            guard written == merged.data,
                  try ClassicDatabase.parse(written).tracks.count == existingLibrary.tracks.count + additions.count else {
                throw PodBridgeError.databaseVerificationFailed
            }
            AppLogger.database("Temporary database verified bytes=\(written.count)", level: .info)

            stage = "replace-itunesdb"
            try Task.checkCancellation()
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
                      activeDiagnostics.primaryPlaylistMembers == merged.library.tracks.count,
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

                if let playCountsURLToArchive {
                    stage = "archive-play-counts"
                    let backupURL = itunes.appendingPathComponent("Play Counts.bak")
                    if manager.fileExists(atPath: backupURL.path) {
                        try manager.removeItem(at: backupURL)
                    }
                    try manager.moveItem(at: playCountsURLToArchive, to: backupURL)
                    AppLogger.database("Play Counts merged and archived", level: .info)
                }

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
        case replacePlaylistMembers(index: Int, trackIDs: [UInt32])
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
        let originalLibrary = try ClassicDatabase.parse(original)
        let before = try ClassicDatabase.inspect(original, firewireID: firewireID)
        guard before.primaryPlaylistFound,
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
        case let .replacePlaylistMembers(index, trackIDs):
            edit = try ClassicDatabase.replacingPlaylistMembers(
                existing: original,
                playlistIndex: index,
                trackIDs: trackIDs,
                firewireID: firewireID
            )
            description = "playlist-members index=\(index) members=\(trackIDs.count)"
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
        guard trackInventoryIsPreserved(before: originalLibrary, after: edit.library) else {
            AppLogger.database(
                "Library edit rejected operation=\(description) reason=track-inventory-changed before=\(originalLibrary.tracks.count) after=\(edit.library.tracks.count)",
                level: .error
            )
            throw PodBridgeError.databaseVerificationFailed
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
                  diagnostics.primaryPlaylistMembers == edit.library.tracks.count,
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
        let member: ClassicDatabase.PendingPlaylistMember
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

    static func sha256(of url: URL, cache: inout [String: Data]) throws -> Data {
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

    static func trackURL(path: String, root: URL) -> URL? {
        let components = path.split(separator: ":").map(String.init)
        guard components.first == "iPod_Control", components.count >= 3 else { return nil }
        return components.reduce(root) { $0.appendingPathComponent($1) }
    }

    static func rollbackDatabaseAndArtwork(
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

    static func failIfInjected(_ point: TestFailurePoint) throws {
#if DEBUG
        if testFailureState.consume(point) {
            throw PodBridgeError.databaseVerificationFailed
        }
#else
        _ = point
#endif
    }

    static func createBackup(original: Data, in itunes: URL) throws -> URL {
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


}
