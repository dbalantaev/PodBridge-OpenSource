// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

@MainActor
extension MusicTransferViewModel {
#if DEBUG || PODBRIDGE_DEMO
    func emulateConnectedIPod(_ scenario: DemoIPodScenario = .normal) {
        guard !isCopying && !isManagingLibrary && !isRestoring else { return }
        if isEmulatingIPod {
            disconnectEmulatedIPod()
        }

        do {
            let fixture = try DemoIPodFactory.create(scenario: scenario)
            emulatedIPodContainer = fixture.containerURL
            destinationFolder = fixture.rootURL
            destinationDeviceProfile = .classic7
            shouldChooseDeviceProfile = false
            libraryTracks = fixture.library.tracks
            libraryPlaylists = fixture.library.playlists
            existingTrackCount = fixture.library.tracks.count
            storageTotalBytes = fixture.storageTotalBytes
            storageFreeBytes = fixture.storageFreeBytes
            backups = []
            deletionBackups = []
            destinationNeedsFirewireID = fixture.needsFirewireID
            destinationDiskUseStatus = fixture.diskUseStatus
            errorMessage = nil
            resultMessage = nil
            isEmulatingIPod = true
            AppLogger.device("Demo iPod connected scenario=\(scenario.rawValue)", level: .info)
        } catch {
            errorMessage = "Could not create the emulated iPod: \(error.localizedDescription)"
            AppLogger.device("Demo iPod creation failed error=\(error.localizedDescription)", level: .error)
        }
    }

    func disconnectEmulatedIPod() {
        guard isEmulatingIPod else { return }
        simulationTask?.cancel()
        isEmulatingIPod = false
        destinationFolder = nil
        destinationDeviceProfile = nil
        existingTrackCount = nil
        storageTotalBytes = nil
        storageFreeBytes = nil
        libraryTracks = []
        libraryPlaylists = []
        backups = []
        deletionBackups = []
        destinationNeedsFirewireID = false
        destinationDiskUseStatus = .unavailable
        if let container = emulatedIPodContainer { DemoIPodFactory.remove(containerURL: container) }
        emulatedIPodContainer = nil
        AppLogger.device("Demo iPod disconnected", level: .info)
    }

#endif

#if DEBUG || PODBRIDGE_DEMO
    func emulateTrackMetadata(_ id: UInt32, update: ClassicDatabase.TrackMetadataUpdate) {
        DemoLibraryEditor.updateTrack(id: id, with: update, in: &libraryTracks)
        resultMessage = "Updated demo metadata for \(update.title)."
    }

    func deleteDemoTracks(withIDs ids: Set<UInt32>) {
        DemoLibraryEditor.deleteTracks(withIDs: ids, tracks: &libraryTracks, playlists: &libraryPlaylists)
        existingTrackCount = libraryTracks.count
    }

    func emulateOnlineArtwork(
        trackIDs: Set<UInt32>,
        label: String,
        replaceExisting: Bool,
        completion: ((Int) -> Void)? = nil
    ) {
        guard !isManagingLibrary, !trackIDs.isEmpty else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            defer {
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            guard let updated = await DemoArtworkSearchService.search(
                tracks: libraryTracks,
                trackIDs: trackIDs,
                replaceExisting: replaceExisting,
                onProgress: { self.artworkSearchProgress = $0 },
                onArtwork: { trackID, artwork in
                    DemoLibraryEditor.setArtwork(artwork, trackIDs: [trackID], in: &self.libraryTracks)
                }
            ) else { return }
            resultMessage = updated == 0
                ? "No exact online artwork matches were found for \(label)."
                : "Added artwork for \(updated) songs in the demo iPod."
            completion?(updated)
        }
    }
#endif
}
