// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

@MainActor
extension MusicTransferViewModel {
    func repairAlbumGrouping() {
        runSafeLibraryRepairs(includeArtwork: false)
    }

    func fixAllSafeLibraryIssues() {
        runSafeLibraryRepairs(includeArtwork: true)
    }

    private func runSafeLibraryRepairs(includeArtwork: Bool) {
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            repairDemoLibrary(includeArtwork: includeArtwork)
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            await performSafeLibraryRepair(
                at: destinationFolder,
                includeArtwork: includeArtwork
            )
        }
    }

    private func performSafeLibraryRepair(at destination: URL, includeArtwork: Bool) async {
        let access = destination.startAccessingSecurityScopedResource()
        defer {
            if access { destination.stopAccessingSecurityScopedResource() }
            artworkSearchProgress = nil
            isManagingLibrary = false
            artworkTask = nil
        }
        do {
            let repair = try await IPodSyncEngine.repairAlbumArtists(root: destination)
            let covers = try await repairMissingArtworkIfNeeded(
                at: destination,
                enabled: includeArtwork
            )
            let library = try IPodSyncEngine.library(root: destination)
            libraryTracks = library.tracks
            libraryPlaylists = library.playlists
            refreshStorage(for: destination)
            backups = try IPodSyncEngine.backups(root: destination)
            resultMessage = "Repaired \(repair.repairedAlbums) album groups and added artwork to "
                + "\(covers.embedded + covers.online) tracks. Possible duplicates were left unchanged."
            libraryRepairCompletion = LibraryRepairCompletion(
                repairedAlbumGroups: repair.repairedAlbums,
                restoredEmbeddedArtwork: covers.embedded,
                addedOnlineArtwork: covers.online
            )
        } catch is CancellationError {
            resultMessage = "Library repair cancelled."
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.sync(
                "Safe library repair failed error=\(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func repairMissingArtworkIfNeeded(
        at destination: URL,
        enabled: Bool
    ) async throws -> (embedded: Int, online: Int) {
        guard enabled else { return (0, 0) }
        let library = try IPodSyncEngine.library(root: destination)
        let missingIDs = library.tracks.filter { $0.artworkImageID == 0 }.map(\.id)
        var embedded: IPodSyncEngine.EmbeddedArtworkResult?
        if !missingIDs.isEmpty {
            embedded = try await IPodSyncEngine.restoreEmbeddedArtwork(
                trackIDs: missingIDs,
                root: destination
            )
        }
        let remaining = (embedded?.library.tracks ?? library.tracks)
            .filter { $0.artworkImageID == 0 }
            .count
        guard remaining > 0 else { return (embedded?.restoredTracks ?? 0, 0) }
        let online = try await IPodSyncEngine.findMissingArtwork(
            root: destination,
            replaceExistingPlaylistArtwork: false
        ) { progress in
            await MainActor.run { self.artworkSearchProgress = progress }
        }
        return (embedded?.restoredTracks ?? 0, online.updatedTracks)
    }

#if DEBUG || PODBRIDGE_DEMO
    private func repairDemoLibrary(includeArtwork: Bool) {
        let repairedGroups = normalizeDemoAlbumArtists()
        guard includeArtwork else {
            completeDemoLibraryRepair(groups: repairedGroups, artwork: 0)
            return
        }
        let missingIDs = Set(libraryTracks.filter { $0.artworkImageID == 0 }.map(\.id))
        guard !missingIDs.isEmpty else {
            completeDemoLibraryRepair(groups: repairedGroups, artwork: 0)
            return
        }
        emulateOnlineArtwork(
            trackIDs: missingIDs,
            label: "demo library",
            replaceExisting: false
        ) { [weak self] updated in
            self?.completeDemoLibraryRepair(groups: repairedGroups, artwork: updated)
        }
    }

    private func normalizeDemoAlbumArtists() -> Int {
        let repairedGroups = safeAlbumRepairCount
        let groups = Dictionary(grouping: libraryTracks.indices) { index in
            let track = libraryTracks[index]
            return track.albumID == 0
                ? "metadata:\(track.album.lowercased())"
                : "id:\(track.albumID)"
        }
        for indices in groups.values where indices.count > 1 {
            let albumArtists = indices.map { libraryTracks[$0].albumArtist }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let trackArtists = indices.map { libraryTracks[$0].artist }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard let artist = albumArtists.first ?? trackArtists.first else { continue }
            for index in indices {
                libraryTracks[index].albumArtist = artist
            }
        }
        return repairedGroups
    }

    private func completeDemoLibraryRepair(groups: Int, artwork: Int) {
        resultMessage = "Repaired safe album grouping issues in the demo library."
        libraryRepairCompletion = LibraryRepairCompletion(
            repairedAlbumGroups: groups,
            restoredEmbeddedArtwork: 0,
            addedOnlineArtwork: artwork
        )
    }
#endif
}
