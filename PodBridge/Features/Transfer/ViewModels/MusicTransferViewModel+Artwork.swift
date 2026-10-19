// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

@MainActor
extension MusicTransferViewModel {
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

#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            DemoLibraryEditor.setArtwork(
                artwork,
                trackIDs: Set(libraryPlaylists[index].trackIDs),
                in: &libraryTracks
            )
            resultMessage = "Updated artwork for demo playlist \(libraryPlaylists[index].name)."
            return
        }
#endif

        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        libraryTask = Task {
            let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                libraryTask = nil
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            DemoLibraryEditor.setArtwork(
                artwork,
                trackIDs: Set(album.tracks.map(\.id)),
                in: &libraryTracks
            )
            resultMessage = "Updated artwork for demo album \(album.title)."
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            DemoLibraryEditor.setArtwork(artwork, trackIDs: [track.id], in: &libraryTracks)
            resultMessage = "Updated artwork for demo song \(track.title)."
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            emulateOnlineArtwork(trackIDs: Set(trackIDs), label: label, replaceExisting: true)
            return
        }
#endif
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
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            let candidates = libraryTracks.filter {
                $0.artworkImageID == 0 || $0.artworkData == nil
            }
            emulateOnlineArtwork(
                trackIDs: Set(candidates.map(\.id)),
                label: "demo library",
                replaceExisting: false
            )
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary,
              automaticArtworkCandidateCount > 0 else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            await performMissingArtworkSearch(at: destinationFolder)
        }
    }

    private func performMissingArtworkSearch(at destination: URL) async {
        let access = destination.startAccessingSecurityScopedResource()
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            artworkSearchProgress = nil
            isManagingLibrary = false
            artworkTask = nil
        }
        do {
            let outcome = try await restoreAndSearchMissingArtwork(at: destination)
            let library = try IPodSyncEngine.library(root: destination)
            libraryTracks = library.tracks
            libraryPlaylists = library.playlists
            refreshStorage(for: destination)
            try reportMissingArtwork(outcome, destination: destination)
        } catch is CancellationError {
            resultMessage = "Artwork search cancelled before the iPod library was changed."
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.artwork(
                "Automatic artwork UI failed error=\(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func restoreAndSearchMissingArtwork(
        at destination: URL
    ) async throws -> (restored: Int, search: IPodSyncEngine.ArtworkSearchResult) {
        let missingIDs = libraryTracks.filter { $0.artworkImageID == 0 }.map(\.id)
        let embedded = try await IPodSyncEngine.restoreEmbeddedArtwork(
            trackIDs: missingIDs,
            root: destination
        )
        let stillMissing = embedded.library.tracks.contains { $0.artworkImageID == 0 }
        let search: IPodSyncEngine.ArtworkSearchResult
        if stillMissing {
            search = try await IPodSyncEngine.findMissingArtwork(
                root: destination,
                replaceExistingPlaylistArtwork: false
            ) { progress in
                await MainActor.run { self.artworkSearchProgress = progress }
            }
        } else {
            search = IPodSyncEngine.ArtworkSearchResult(
                searchedItems: 0,
                matchedItems: 0,
                updatedTracks: 0,
                failedLookups: 0,
                backupURL: nil
            )
        }
        return (embedded.restoredTracks, search)
    }

    private func reportMissingArtwork(
        _ outcome: (restored: Int, search: IPodSyncEngine.ArtworkSearchResult),
        destination: URL
    ) throws {
        if outcome.search.updatedTracks == 0, outcome.restored == 0 {
            resultMessage = outcome.search.searchedItems == 0
                ? "No embedded covers or searchable missing-artwork tracks were found."
                : "No embedded covers were found and no exact approved online matches were found for "
                    + "\(outcome.search.searchedItems) albums and songs."
            return
        }
        backups = try IPodSyncEngine.backups(root: destination)
        let failures = outcome.search.failedLookups == 0
            ? ""
            : " \(outcome.search.failedLookups) lookups failed and can be retried."
        let embedded = outcome.restored == 0
            ? ""
            : "Restored embedded covers for \(outcome.restored) tracks. "
        let online = outcome.search.updatedTracks == 0
            ? ""
            : "Added online covers for \(outcome.search.updatedTracks) tracks "
                + "from \(outcome.search.matchedItems) exact matches."
        resultMessage = "\(embedded)\(online)\(failures)"
    }

    func cancelArtworkSearch() {
        artworkTask?.cancel()
    }

}
