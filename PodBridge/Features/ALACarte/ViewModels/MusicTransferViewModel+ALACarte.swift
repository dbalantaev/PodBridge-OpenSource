// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

@MainActor
extension MusicTransferViewModel {
#if PODBRIDGE_ALACARTE
    func importFromALACarte(client: ALACarteClient, items selectedItems: [ALACarteLibraryItem]) {
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            startSimulatedALACarteImport(selectedItems)
            return
        }
#endif
        guard let destinationFolder else {
            errorMessage = PodBridgeError.noDestinationFolder.localizedDescription
            return
        }
        guard destinationDeviceProfile != nil else {
            errorMessage = PodBridgeError.deviceModelRequired.localizedDescription
            return
        }
        guard !destinationNeedsFirewireID, !isCopying, !isManagingLibrary,
              !isExporting, !isRestoring, !selectedItems.isEmpty else { return }

        copyTask?.cancel()
        beginALACarteImport()
        copyTask = Task { [weak self] in
            await self?.performALACarteImport(
                client: client,
                items: selectedItems,
                destination: destinationFolder
            )
        }
    }

    func copyFromALACarteToRockbox(client: ALACarteClient, items selectedItems: [ALACarteLibraryItem]) {
        guard let destinationFolder else {
            errorMessage = PodBridgeError.noDestinationFolder.localizedDescription
            return
        }
        guard !isCopying, !isManagingLibrary, !isExporting,
              !isRestoring, !selectedItems.isEmpty else { return }

        copyTask?.cancel()
        beginALACarteImport()
        copyTask = Task { [weak self] in
            await self?.performALACarteRockboxCopy(
                client: client,
                items: selectedItems,
                destination: destinationFolder
            )
        }
    }

    private func beginALACarteImport() {
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        alacarteStatus = "Preparing ALACarte selections…"
    }

    private func performALACarteImport(
        client: ALACarteClient,
        items: [ALACarteLibraryItem],
        destination: URL
    ) async {
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer { finishALACarteTransfer(destination: destination, accessed: destinationAccess) }
        do {
            let result = try await ALACarteTransferService.addToAppleLibrary(
                client: client,
                items: items,
                destination: destination
            ) { [weak self] progress in
                await self?.receiveALACarteProgress(progress)
            }
            refreshLibraryAfterALACarteSync(result, destination: destination)
            reportALACarteCompletion(result, itemCount: items.count)
        } catch is CancellationError {
            resultMessage = "ALACarte import was cancelled before completion."
        } catch {
            reportALACarteFailure(error, itemCount: items.count, operation: "import")
        }
    }

    private func performALACarteRockboxCopy(
        client: ALACarteClient,
        items: [ALACarteLibraryItem],
        destination: URL
    ) async {
        let destinationAccess = destination.startAccessingSecurityScopedResource()
        defer { finishALACarteTransfer(destination: destination, accessed: destinationAccess) }
        do {
            let result = try await ALACarteTransferService.copyToRockbox(
                client: client,
                items: items,
                destination: destination
            ) { [weak self] progress in
                await self?.receiveALACarteProgress(progress)
            }
            refreshStorage(for: destination)
            let size = result.copiedBytes.formatted(.byteCount(style: .file))
            resultMessage = "Copied \(result.copiedFiles) files (\(size)) to Rockbox /Music."
            AppLogger.sync(
                "ALACarte Rockbox copy completed items=\(items.count) files=\(result.copiedFiles)",
                level: .info
            )
        } catch is CancellationError {
            resultMessage = "ALACarte Rockbox copy was cancelled. Partial files were removed."
        } catch {
            reportALACarteFailure(error, itemCount: items.count, operation: "Rockbox copy")
        }
    }

    private func finishALACarteTransfer(destination: URL, accessed: Bool) {
        if accessed { destination.stopAccessingSecurityScopedResource() }
        alacarteStatus = nil
        isCopying = false
        copyTask = nil
    }

    private func receiveALACarteProgress(_ progress: ALACarteTransferService.Progress) {
        switch progress {
        case let .downloading(index, count, title, completed, total):
            let prefix = "Downloading \(index + 1) of \(count): "
            alacarteStatus = completed == 0 ? prefix + title : prefix + "\(completed) of \(total) files"
        case let .writingAppleLibrary(completed, total):
            copiedCount = completed
            alacarteStatus = "Writing to iPod: \(completed) of \(total) tracks"
        case let .copyingRockbox(completed):
            copiedCount = completed
            alacarteStatus = "Copying to Rockbox /Music: \(completed) files"
        }
    }

    private func refreshLibraryAfterALACarteSync(_ result: IPodSyncEngine.Result, destination: URL) {
        existingTrackCount = result.total
        if let library = try? IPodSyncEngine.library(root: destination) {
            libraryTracks = library.tracks
            libraryPlaylists = library.playlists
        }
        refreshStorage(for: destination)
        backups = (try? IPodSyncEngine.backups(root: destination)) ?? backups
    }

    private func reportALACarteCompletion(_ result: IPodSyncEngine.Result, itemCount: Int) {
        let reused = result.exactDuplicatesReused + result.metadataDuplicatesReused
        resultMessage = "Imported \(itemCount) selections: \(result.added) new tracks, \(reused) reused, and \(result.playlistsAdded) playlists. Backup: \(result.backupURL.lastPathComponent)."
        completeTransfer(addedTracks: result.added, backupName: result.backupURL.lastPathComponent)
    }

    private func reportALACarteFailure(_ error: Error, itemCount: Int, operation: String) {
        errorMessage = error.localizedDescription
        AppLogger.sync(
            "ALACarte \(operation) failed items=\(itemCount) error=\(error.localizedDescription)",
            level: .error
        )
    }

#if DEBUG && PODBRIDGE_ALACARTE
    private func startSimulatedALACarteImport(_ selectedItems: [ALACarteLibraryItem]) {
        simulationTask?.cancel()
        let totalTracks = max(selectedItems.reduce(0) { $0 + $1.trackCount }, 1)
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        alacarteStatus = "Preparing \(selectedItems.count) selected items…"
        simulationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCopying = false
                self.alacarteStatus = nil
                self.simulationTask = nil
            }
            do {
                for (index, item) in selectedItems.enumerated() {
                    try Task.checkCancellation()
                    self.alacarteStatus = "Downloading \(index + 1) of \(selectedItems.count): \(item.title)"
                    try await Task.sleep(nanoseconds: 650_000_000)
                }
                for index in 1...totalTracks {
                    try Task.checkCancellation()
                    self.alacarteStatus = "Writing to iPod: \(index) of \(totalTracks) tracks"
                    try await Task.sleep(nanoseconds: 110_000_000)
                    self.copiedCount = index
                }
                self.existingTrackCount = (self.existingTrackCount ?? self.libraryTracks.count) + totalTracks
                self.transferCompletion = TransferCompletion(
                    addedTracks: totalTracks,
                    destinationName: "Demo iPod",
                    playlists: selectedItems.filter { $0.kind == .playlist }.prefix(3).map {
                        TransferCompletion.Playlist(name: $0.title, trackCount: $0.trackCount)
                    },
                    backupName: nil
                )
                self.resultMessage = "Added \(totalTracks) demo tracks from ALACarte. The demo resets when PodBridge restarts."
                self.copiedCount = 0
            } catch is CancellationError {
                self.resultMessage = "Demo ALACarte transfer cancelled."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
#endif
#endif

}
