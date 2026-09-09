// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

struct IPodAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let albumArtist: String
    let compilation: Bool
    let genre: String
    let year: UInt32
    let tracks: [ClassicTrack]

    var byteCount: UInt64 { tracks.reduce(0) { $0 + UInt64($1.byteCount) } }
}

@MainActor
final class MusicTransferViewModel: ObservableObject {
    @Published private(set) var sourceFolder: URL?
    @Published private(set) var destinationFolder: URL?
    @Published private(set) var destinationDeviceProfile: IPodDeviceProfile?
    @Published private(set) var existingTrackCount: Int?
    @Published private(set) var storageTotalBytes: Int64?
    @Published private(set) var storageFreeBytes: Int64?
    @Published private(set) var files: [MusicFile] = []
    @Published private(set) var playlists: [SourcePlaylist] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isCopying = false
    @Published private(set) var copiedCount = 0
    @Published private(set) var resultMessage: String?
    @Published private(set) var backups: [IPodSyncEngine.Backup] = []
    @Published private(set) var libraryTracks: [ClassicTrack] = []
    @Published private(set) var libraryPlaylists: [ClassicPlaylist] = []
    @Published private(set) var deletionBackups: [IPodSyncEngine.DeletionBackup] = []
    @Published private(set) var isRestoring = false
    @Published private(set) var isManagingLibrary = false
    @Published private(set) var artworkSearchProgress: IPodSyncEngine.ArtworkSearchProgress?
    @Published private(set) var destinationNeedsFirewireID = false
    @Published var errorMessage: String?

    private var copyTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var copyProgress: Double {
        guard !files.isEmpty else { return 0 }
        return Double(copiedCount) / Double(files.count)
    }

    var storageUsedBytes: Int64? {
        guard let total = storageTotalBytes, let free = storageFreeBytes else { return nil }
        return max(0, total - free)
    }

    var storageUsedFraction: Double? {
        guard let total = storageTotalBytes, total > 0, let used = storageUsedBytes else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var missingArtworkTrackCount: Int {
        libraryTracks.filter { $0.artworkImageID == 0 }.count
    }

    var automaticArtworkCandidateCount: Int {
        let tracksByID = Dictionary(uniqueKeysWithValues: libraryTracks.map { ($0.id, $0) })
        var playlistTrackIDs = Set(libraryTracks.filter(\.compilation).map(\.id))
        for playlist in libraryPlaylists {
            for trackID in playlist.trackIDs {
                guard let track = tracksByID[trackID],
                      track.album.caseInsensitiveCompare(playlist.name) == .orderedSame else { continue }
                playlistTrackIDs.insert(trackID)
            }
        }
        return libraryTracks.filter { playlistTrackIDs.contains($0.id) || $0.artworkImageID == 0 }.count
    }

    var libraryAlbums: [IPodAlbum] {
        let groups = Dictionary(grouping: libraryTracks) { track in
            let groupingArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            return track.albumID == 0 ? "metadata:\(groupingArtist)\u{0}\(track.album)" : "id:\(track.albumID)"
        }
        return groups.map { key, tracks in
            let orderedTracks = tracks.sorted {
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let first = orderedTracks[0]
            let albumArtist = first.albumArtist.isEmpty ? first.artist : first.albumArtist
            return IPodAlbum(
                id: key,
                title: first.album,
                artist: albumArtist,
                albumArtist: albumArtist,
                compilation: orderedTracks.contains(where: \.compilation),
                genre: first.genre,
                year: first.year,
                tracks: orderedTracks
            )
        }.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            return artistOrder == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artistOrder == .orderedAscending
        }
    }

    func selectSource(_ url: URL) {
        AppLogger.scan("Source selected folder=\(url.lastPathComponent)", level: .info)
        sourceFolder = url
        files = []
        playlists = []
        copiedCount = 0
        resultMessage = nil
        scanSource()
    }

    func selectDestination(_ url: URL) {
        AppLogger.device("Destination selected name=\(url.lastPathComponent)", level: .info)
        destinationFolder = url
        destinationDeviceProfile = nil
        existingTrackCount = nil
        storageTotalBytes = nil
        storageFreeBytes = nil
        copiedCount = 0
        resultMessage = nil
        errorMessage = nil
        backups = []
        libraryTracks = []
        libraryPlaylists = []
        deletionBackups = []
        destinationNeedsFirewireID = false
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let library = try IPodSyncEngine.library(root: url)
            existingTrackCount = library.tracks.count
            libraryTracks = library.tracks
            libraryPlaylists = library.playlists
            backups = try IPodSyncEngine.backups(root: url)
            refreshStorage(for: url)
            AppLogger.device("Destination validation succeeded existingTracks=\(existingTrackCount ?? 0)", level: .info)
        } catch {
            destinationFolder = nil
            errorMessage = error.localizedDescription
            AppLogger.device("Destination validation failed error=\(error.localizedDescription)", level: .error)
        }
    }

    func selectDeviceProfile(_ profile: IPodDeviceProfile) {
        guard let destinationFolder else { return }
        destinationDeviceProfile = profile
        IPodDeviceProfile.save(profile, for: destinationFolder)
        destinationNeedsFirewireID = false
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
        do {
            try IPodSyncEngine.recoverInterruptedDeletions(root: destinationFolder)
            let databaseKey = try IPodDeviceProfile.databaseKey(at: destinationFolder)
            deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == databaseKey.hexString }
            AppLogger.device("Device profile selected model=\(profile.rawValue) checksum=\(String(describing: profile.checksum)) tested=\(profile.isHardwareTested)", level: .info)
        } catch PodBridgeError.missingFirewireID {
            destinationNeedsFirewireID = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func storeFirewireIDAndRepair(_ value: String) {
        guard let destinationFolder else { return }
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
        do {
            try ClassicDatabase.storeFirewireID(value, root: destinationFolder)
            destinationNeedsFirewireID = false
            repairDatabaseSignature()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreOldestBackup() {
        guard let destinationFolder, let backup = backups.first else { return }
        isRestoring = true
        resultMessage = nil
        errorMessage = nil
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if access { destinationFolder.stopAccessingSecurityScopedResource() }
            isRestoring = false
        }
        do {
            let result = try IPodSyncEngine.restore(backup: backup, root: destinationFolder)
            existingTrackCount = result.tracks
            let library = try IPodSyncEngine.library(root: destinationFolder)
            libraryTracks = library.tracks
            libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
            backups = try IPodSyncEngine.backups(root: destinationFolder)
            resultMessage = "Restored backup \(backup.name) with \(result.tracks) tracks. Removed \(result.removedFiles) files added after it. Safety backup: \(result.safetyBackup.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.database("Backup restore failed name=\(backup.name) error=\(error.localizedDescription)", level: .error)
        }
    }

    func repairDatabaseSignature() {
        guard let destinationFolder, !isManagingLibrary, !isCopying else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.repairDatabaseSignature(root: destinationFolder)
                existingTrackCount = result.library.tracks.count
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                if let backup = result.backupURL {
                    resultMessage = "Re-signed iTunesDB. Backup: \(backup.lastPathComponent)."
                } else {
                    resultMessage = "iTunesDB signature and indexes are already valid."
                }
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.database("Signature repair UI failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func scanSource() {
        guard let sourceFolder else {
            errorMessage = PodBridgeError.noSourceFolder.localizedDescription
            return
        }
        isScanning = true
        errorMessage = nil
        AppLogger.scan("Source scan started", level: .info)
        Task {
            do {
                let found = try await MusicTransferEngine.scan(folder: sourceFolder)
                let foundPlaylists = try await MusicTransferEngine.scanPlaylists(folder: sourceFolder, files: found)
                files = found
                playlists = foundPlaylists
                AppLogger.scan(
                    "Source scan completed tracks=\(found.count) playlists=\(foundPlaylists.count) bytes=\(found.reduce(0) { $0 + $1.byteCount })",
                    level: .info
                )
                if found.isEmpty {
                    errorMessage = PodBridgeError.noMusicFiles.localizedDescription
                    AppLogger.scan("Source scan found no supported audio", level: .error)
                }
            } catch is CancellationError {
                // A new selection or app dismissal can safely cancel a scan.
                AppLogger.scan("Source scan cancelled", level: .info)
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.scan("Source scan failed error=\(error.localizedDescription)", level: .error)
            }
            isScanning = false
        }
    }

    func setSourcePlaylistArtwork(id: String, imageURL: URL) {
        let access = imageURL.startAccessingSecurityScopedResource()
        defer { if access { imageURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            try ArtworkDatabase.validateSourceArtwork(data)
            guard let index = playlists.firstIndex(where: { $0.id == id }) else {
                throw PodBridgeError.playlistNotFound
            }
            playlists[index].artworkData = data
            playlists[index].artworkFilename = imageURL.lastPathComponent
            AppLogger.artwork(
                "Source playlist artwork selected name=\(playlists[index].name) file=\(imageURL.lastPathComponent) bytes=\(data.count)",
                level: .info
            )
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.artwork("Source playlist artwork selection failed error=\(error.localizedDescription)", level: .error)
        }
    }

    func clearSourcePlaylistArtwork(id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].artworkData = nil
        playlists[index].artworkFilename = nil
    }

    func startCopy() {
        guard let sourceFolder else {
            errorMessage = PodBridgeError.noSourceFolder.localizedDescription
            return
        }
        guard let destinationFolder else {
            errorMessage = PodBridgeError.noDestinationFolder.localizedDescription
            return
        }
        guard destinationDeviceProfile != nil else {
            errorMessage = PodBridgeError.deviceModelRequired.localizedDescription
            return
        }
        guard !files.isEmpty else {
            errorMessage = PodBridgeError.noMusicFiles.localizedDescription
            return
        }

        copyTask?.cancel()
        isCopying = true
        copiedCount = 0
        resultMessage = nil
        errorMessage = nil
        AppLogger.sync("Sync requested tracks=\(files.count) playlists=\(playlists.count) bytes=\(totalBytes)", level: .info)

        copyTask = Task {
            let sourceAccess = sourceFolder.startAccessingSecurityScopedResource()
            let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { sourceFolder.stopAccessingSecurityScopedResource() }
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isCopying = false
                copyTask = nil
            }

            do {
                let result = try await IPodSyncEngine.sync(files: files, playlists: playlists, root: destinationFolder) { count in
                    await MainActor.run { self.copiedCount = count }
                }
                existingTrackCount = result.total
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                let reused = result.exactDuplicatesReused + result.metadataDuplicatesReused
                resultMessage = "Added \(result.added) tracks, reused \(reused) duplicates, added \(result.playlistsAdded) playlists, and \(result.coversAdded) covers. Backup: \(result.backupURL.lastPathComponent)."
                AppLogger.sync(
                    "Sync UI completed added=\(result.added) exactDuplicatesReused=\(result.exactDuplicatesReused) metadataDuplicatesReused=\(result.metadataDuplicatesReused) playlists=\(result.playlistsAdded) covers=\(result.coversAdded) total=\(result.total) backup=\(result.backupURL.lastPathComponent)",
                    level: .info
                )
            } catch is CancellationError {
                resultMessage = "Copy stopped after \(copiedCount) track\(copiedCount == 1 ? "" : "s")."
                AppLogger.sync("Sync cancelled copied=\(copiedCount)", level: .error)
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Sync UI failed copied=\(copiedCount) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func cancelCopy() {
        copyTask?.cancel()
    }

    private func refreshStorage(for url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            storageTotalBytes = values.volumeTotalCapacity.map(Int64.init)
            storageFreeBytes = values.volumeAvailableCapacity.map(Int64.init)
        } catch {
            storageTotalBytes = nil
            storageFreeBytes = nil
            AppLogger.device("Storage capacity unavailable error=\(error.localizedDescription)", level: .error)
        }
    }

    func deleteTrack(_ track: ClassicTrack) {
        guard let destinationFolder, !isManagingLibrary, deletionBackups.isEmpty else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.deleteTrack(id: track.id, root: destinationFolder)
                existingTrackCount = result.remainingTracks
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == result.backup.deviceIdentifier }
                resultMessage = "Deleted \(result.deletedTrack.title) and freed \(Int64(result.freedBytes).formatted(.byteCount(style: .file))). A verified copy is stored on this iPhone."
                AppLogger.sync(
                    "Delete UI completed id=\(track.id) remaining=\(result.remainingTracks) freedBytes=\(result.freedBytes) localBackup=\(result.backup.folderURL.lastPathComponent)",
                    level: .info
                )
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Delete UI failed id=\(track.id) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func restoreDeletedTrack(_ backup: IPodSyncEngine.DeletionBackup) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let library = try await IPodSyncEngine.restoreDeletion(backup, root: destinationFolder)
                existingTrackCount = library.tracks.count
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == backup.deviceIdentifier }
                resultMessage = "Restored \(backup.title) to the iPod and removed its local backup from this iPhone."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Deleted track restore UI failed id=\(backup.trackID) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func discardDeletedTrackBackup(_ backup: IPodSyncEngine.DeletionBackup) {
        guard !isManagingLibrary else { return }
        do {
            try IPodSyncEngine.discardDeletionBackup(backup)
            deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == backup.deviceIdentifier }
            resultMessage = "The local backup of \(backup.title) was deleted. Its removal from the iPod is now permanent."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func editTrackMetadata(_ track: ClassicTrack, update: ClassicDatabase.TrackMetadataUpdate) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.editTrackMetadata(id: track.id, update: update, root: destinationFolder)
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated metadata for \(update.title). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Track metadata edit UI failed id=\(track.id) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func renamePlaylist(at index: Int, to name: String) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.renamePlaylist(index: index, name: name, root: destinationFolder)
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Renamed playlist to \(name). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Playlist rename UI failed index=\(index) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func deletePlaylist(at index: Int, includingSongs: Bool) {
        guard let destinationFolder,
              !isManagingLibrary,
              libraryPlaylists.indices.contains(index) else { return }
        let playlist = libraryPlaylists[index]
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                if includingSongs {
                    let result = try await IPodSyncEngine.deletePlaylistAndTracks(index: index, root: destinationFolder)
                    let library = try IPodSyncEngine.library(root: destinationFolder)
                    existingTrackCount = result.remainingTracks
                    libraryTracks = library.tracks
                    libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                    let freed = ByteCountFormatter.string(fromByteCount: Int64(result.freedBytes), countStyle: .file)
                    resultMessage = result.failedFileDeletions == 0
                        ? "Deleted playlist \(playlist.name), \(result.removedTracks.count) songs, and freed \(freed)."
                        : "Deleted playlist \(playlist.name) and its songs from the library. \(result.failedFileDeletions) orphan audio files could not be deleted."
                } else {
                    let result = try await IPodSyncEngine.deletePlaylist(index: index, root: destinationFolder)
                    libraryTracks = result.library.tracks
                    libraryPlaylists = result.library.playlists
                    backups = try IPodSyncEngine.backups(root: destinationFolder)
                    resultMessage = "Deleted playlist \(playlist.name); its songs remain on the iPod. Backup: \(result.backupURL.lastPathComponent)."
                }
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Playlist delete UI failed index=\(index) includingSongs=\(includingSongs) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func deleteTrackPermanently(_ track: ClassicTrack) {
        deleteTracksPermanently([track], description: track.title)
    }

    func deleteAlbumPermanently(_ album: IPodAlbum) {
        deleteTracksPermanently(album.tracks, description: album.title)
    }

    private func deleteTracksPermanently(_ tracks: [ClassicTrack], description: String) {
        guard let destinationFolder, !isManagingLibrary, !tracks.isEmpty else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.deleteTracksPermanently(
                    ids: tracks.map(\.id),
                    root: destinationFolder
                )
                let library = try IPodSyncEngine.library(root: destinationFolder)
                existingTrackCount = result.remainingTracks
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                let freed = ByteCountFormatter.string(fromByteCount: Int64(result.freedBytes), countStyle: .file)
                resultMessage = result.failedFileDeletions == 0
                    ? "Permanently deleted \(description) and freed \(freed)."
                    : "Removed \(description) from the library and freed \(freed). \(result.failedFileDeletions) orphan audio files could not be deleted."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Permanent delete UI failed tracks=\(tracks.count) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func editAlbumMetadata(_ album: IPodAlbum, update: IPodSyncEngine.AlbumMetadataUpdate) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.editAlbumMetadata(
                    trackIDs: album.tracks.map(\.id),
                    update: update,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated album \(update.album). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Album metadata edit UI failed album=\(album.title) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func setPlaylistArtwork(at index: Int, imageURL: URL) {
        guard let destinationFolder, !isManagingLibrary else { return }
        let sourceAccess = imageURL.startAccessingSecurityScopedResource()
        let artwork: Data
        do {
            artwork = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            try ArtworkDatabase.validateSourceArtwork(artwork)
        } catch {
            if sourceAccess { imageURL.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            return
        }
        if sourceAccess { imageURL.stopAccessingSecurityScopedResource() }

        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let name = libraryPlaylists.indices.contains(index) ? libraryPlaylists[index].name : "playlist"
                let result = try await IPodSyncEngine.setPlaylistArtwork(
                    index: index,
                    artwork: artwork,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated the Cover Flow artwork for \(name). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Playlist artwork UI failed index=\(index) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func setAlbumArtwork(_ album: IPodAlbum, imageURL: URL) {
        guard destinationFolder != nil, !isManagingLibrary,
              let artwork = readArtwork(from: imageURL) else { return }
        setAlbumArtwork(album, artwork: artwork)
    }

    func setAlbumArtwork(_ album: IPodAlbum, artwork: Data) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.setAlbumArtwork(
                    trackIDs: album.tracks.map(\.id),
                    artwork: artwork,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated artwork for album \(album.title). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Album artwork UI failed album=\(album.title) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func setTrackArtwork(_ track: ClassicTrack, imageURL: URL) {
        guard destinationFolder != nil, !isManagingLibrary,
              let artwork = readArtwork(from: imageURL) else { return }
        setTrackArtwork(track, artwork: artwork)
    }

    func setTrackArtwork(_ track: ClassicTrack, artwork: Data) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.setTrackArtwork(
                    id: track.id,
                    artwork: artwork,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated artwork for \(track.title). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Track artwork UI failed id=\(track.id) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func createPlaylist(name: String, trackIDs: [UInt32]) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.createPlaylist(
                    name: name,
                    trackIDs: trackIDs,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Created playlist \(name) with \(trackIDs.count) songs. Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.database("Playlist creation UI failed name=\(name) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func restoreEmbeddedArtwork(_ album: IPodAlbum) {
        restoreEmbeddedArtwork(trackIDs: album.tracks.map(\.id), label: album.title)
    }

    func restoreEmbeddedArtwork(trackIDs: [UInt32], label: String) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let result = try await IPodSyncEngine.restoreEmbeddedArtwork(
                    trackIDs: trackIDs,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                if result.restoredTracks > 0 { backups = try IPodSyncEngine.backups(root: destinationFolder) }
                let missing = result.tracksWithoutEmbeddedArtwork == 0
                    ? ""
                    : " \(result.tracksWithoutEmbeddedArtwork) files had no embedded cover."
                resultMessage = result.restoredTracks == 0
                    ? "No embedded original covers were found in \(label)'s audio files."
                    : "Restored embedded covers for \(result.restoredTracks) songs in \(label).\(missing) Backup: \(result.backupURL?.lastPathComponent ?? "created")."
            } catch is CancellationError {
                resultMessage = "Embedded artwork restoration was cancelled before the iPod library changed."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Embedded artwork restore UI failed label=\(label) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func replaceSongArtworkFromInternet(trackIDs: [UInt32], label: String) {
        guard let destinationFolder, !isManagingLibrary, !trackIDs.isEmpty else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let result = try await IPodSyncEngine.replaceSongArtworkFromInternet(
                    trackIDs: trackIDs,
                    root: destinationFolder
                ) { progress in
                    await MainActor.run { self.artworkSearchProgress = progress }
                }
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                if result.updatedTracks > 0 {
                    backups = try IPodSyncEngine.backups(root: destinationFolder)
                    let backupName = result.backupURL?.lastPathComponent ?? "created"
                    resultMessage = "Forced original-release artwork for \(result.updatedTracks) songs in \(label). Backup: \(backupName)."
                } else {
                    resultMessage = "No exact online cover matches were found for \(label). Try choosing artwork for an individual song."
                }
            } catch is CancellationError {
                resultMessage = "Online artwork search was cancelled before the iPod changed."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Scoped online artwork UI failed label=\(label) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    private func readArtwork(from imageURL: URL) -> Data? {
        let access = imageURL.startAccessingSecurityScopedResource()
        defer { if access { imageURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            try ArtworkDatabase.validateSourceArtwork(data)
            return data
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.artwork("Custom artwork selection failed error=\(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func findMissingArtwork() {
        guard let destinationFolder, !isManagingLibrary, automaticArtworkCandidateCount > 0 else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let result = try await IPodSyncEngine.findMissingArtwork(root: destinationFolder) { progress in
                    await MainActor.run { self.artworkSearchProgress = progress }
                }
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                if result.updatedTracks == 0 {
                    resultMessage = result.searchedItems == 0
                        ? "No tracks have enough searchable artist, album, or title metadata."
                        : "No exact approved cover matches were found for \(result.searchedItems) albums and songs."
                } else {
                    backups = try IPodSyncEngine.backups(root: destinationFolder)
                    let failures = result.failedLookups == 0 ? "" : " \(result.failedLookups) lookups failed and can be retried."
                    resultMessage = "Added or replaced artwork for \(result.updatedTracks) tracks from \(result.matchedItems) exact matches. Backup: \(result.backupURL?.lastPathComponent ?? "created").\(failures)"
                }
            } catch is CancellationError {
                resultMessage = "Artwork search cancelled before the iPod library was changed."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Automatic artwork UI failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func cancelArtworkSearch() {
        artworkTask?.cancel()
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
