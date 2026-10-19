// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

@MainActor
extension MusicTransferViewModel {
    func deleteTrack(_ track: ClassicTrack) {
        guard let destinationFolder, !isManagingLibrary, deletionBackups.isEmpty else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
            }
            do {
                let result = try await IPodSyncEngine.deleteTrack(id: track.id, root: destinationFolder)
                existingTrackCount = result.remainingTracks
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                deletionBackups = IPodSyncEngine.deletionBackups().filter {
                    $0.deviceIdentifier == result.backup.deviceIdentifier
                }
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
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
            }
            do {
                let library = try await IPodSyncEngine.restoreDeletion(backup, root: destinationFolder)
                existingTrackCount = library.tracks.count
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                deletionBackups = IPodSyncEngine.deletionBackups().filter {
                    $0.deviceIdentifier == backup.deviceIdentifier
                }
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod { emulateTrackMetadata(track.id, update: update); return }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            DemoLibraryEditor.renamePlaylist(at: index, to: name, in: &libraryPlaylists)
            resultMessage = "Renamed demo playlist to \(name)."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            let playlist = libraryPlaylists.remove(at: index)
            if includingSongs { deleteDemoTracks(withIDs: Set(playlist.trackIDs)) }
            resultMessage = "Deleted demo playlist \(playlist.name)."
            return
        }
#endif
        guard let destinationFolder,
              !isManagingLibrary,
              libraryPlaylists.indices.contains(index) else { return }
        let playlist = libraryPlaylists[index]
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
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

    func replacePlaylistMembers(at index: Int, trackIDs: [UInt32]) {
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            DemoLibraryEditor.replacePlaylistMembers(at: index, with: trackIDs, in: &libraryPlaylists)
            resultMessage = "Updated demo playlist with \(trackIDs.count) songs."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
            }
            do {
                let result = try await IPodSyncEngine.replacePlaylistMembers(
                    index: index,
                    trackIDs: trackIDs,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated playlist with \(trackIDs.count) songs. Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Playlist members edit failed index=\(index) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func deleteTrackPermanently(_ track: ClassicTrack) {
        deleteTracksPermanently([track], description: track.title)
    }

    func deleteAlbumPermanently(_ album: IPodAlbum) {
        deleteTracksPermanently(album.tracks, description: album.title)
    }

    func deleteTracksPermanently(_ tracks: [ClassicTrack], description: String) {
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            deleteDemoTracks(withIDs: Set(tracks.map(\.id)))
            resultMessage = "Deleted \(description) from the demo iPod."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary, !isExporting,
              !isCopying, !isRestoring, !tracks.isEmpty else { return }
        isManagingLibrary = true
        deletionProgress = .init(stage: "Preparing the iPod library", completed: 0, total: 0)
        deletionStartedAt = nil
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                deletionProgress = nil
                deletionStartedAt = nil
                libraryTask = nil
            }
            do {
                let result = try await IPodSyncEngine.deleteTracksPermanently(
                    ids: tracks.map(\.id),
                    root: destinationFolder
                ) { progress in
                    await MainActor.run {
                        if progress.total > 0, self.deletionStartedAt == nil { self.deletionStartedAt = Date() }
                        self.deletionProgress = progress
                    }
                }
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            DemoLibraryEditor.updateAlbum(
                trackIDs: Set(album.tracks.map(\.id)),
                with: update,
                in: &libraryTracks
            )
            resultMessage = "Updated demo album \(update.album)."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
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

    func createPlaylist(name: String, trackIDs: [UInt32]) {
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            libraryPlaylists.append(ClassicPlaylist(name: name, trackIDs: trackIDs))
            resultMessage = "Created demo playlist \(name) with \(trackIDs.count) songs."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
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

}
