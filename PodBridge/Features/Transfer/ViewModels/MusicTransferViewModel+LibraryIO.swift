// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

@MainActor
extension MusicTransferViewModel {
    func exportTracks(_ tracks: [ClassicTrack], to folder: URL) {
        guard let destinationFolder, !isExporting, !isManagingLibrary,
              !isCopying, !isRestoring, !tracks.isEmpty else { return }
        isExporting = true
        exportedCount = 0
        exportTotalCount = tracks.count
        exportStartedAt = Date()
        resultMessage = nil
        errorMessage = nil
        exportTask = Task {
            let deviceAccess = destinationFolder.startAccessingSecurityScopedResource()
            let folderAccess = folder.startAccessingSecurityScopedResource()
            defer {
                if folderAccess { folder.stopAccessingSecurityScopedResource() }
                if deviceAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isExporting = false
                exportStartedAt = nil
                exportTask = nil
            }
            do {
                let result = try await IPodSyncEngine.exportTracks(
                    tracks,
                    playlists: libraryPlaylists,
                    root: destinationFolder,
                    destinationFolder: folder
                ) { count in
                    await MainActor.run { self.exportedCount = count }
                }
                resultMessage = "Copied \(result.copiedTracks) songs to \(result.folderURL.lastPathComponent) in Files. The iPod was not changed."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func importLibraryJSON(_ url: URL) {
        guard let destinationFolder, !isManagingLibrary, !isExporting, !isCopying, !isRestoring else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let deviceAccess = destinationFolder.startAccessingSecurityScopedResource()
            let fileAccess = url.startAccessingSecurityScopedResource()
            defer {
                if fileAccess { url.stopAccessingSecurityScopedResource() }
                if deviceAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
            }
            do {
                let result = try await IPodSyncEngine.importLibraryJSON(url, root: destinationFolder)
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                resultMessage = "Restored statistics for \(result.restoredTracks) songs and \(result.restoredPlaylists) playlists. Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func clearLibraryPermanently() {
        guard let destinationFolder, !isManagingLibrary, !isExporting,
              !isCopying, !isRestoring, !libraryTracks.isEmpty else { return }
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            deleteDemoTracks(withIDs: Set(libraryTracks.map(\.id)))
            libraryPlaylists = []
            resultMessage = "Cleared the demo iPod library."
            return
        }
#endif
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
                let result = try await IPodSyncEngine.clearLibrary(root: destinationFolder) { progress in
                    await MainActor.run {
                        if progress.total > 0, self.deletionStartedAt == nil { self.deletionStartedAt = Date() }
                        self.deletionProgress = progress
                    }
                }
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                existingTrackCount = result.remainingTracks
                refreshStorage(for: destinationFolder)
                resultMessage = result.failedFileDeletions == 0
                    ? "Erased all \(result.removedTracks.count) songs and playlists from the iPod."
                    : "Cleared the library, but \(result.failedFileDeletions) audio files could not be removed."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func deleteArtistPermanently(_ artist: String) {
        let tracks = libraryTracks.filter { $0.artist == artist }
        deleteTracksPermanently(tracks, description: artist)
    }

}
