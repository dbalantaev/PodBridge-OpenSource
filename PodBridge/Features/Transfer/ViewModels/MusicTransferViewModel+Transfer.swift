// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

private struct TransferRequest {
    let sourceFolder: URL
    let destinationFolder: URL
    let files: [MusicFile]
    let playlists: [SourcePlaylist]
    let byteCount: Int64
}

@MainActor
extension MusicTransferViewModel {
    func scanSource() {
        guard let sourceFolder else {
            errorMessage = PodBridgeError.noSourceFolder.localizedDescription
            return
        }
        sourceScanTask?.cancel()
        sourceSelection = UUID()
        let selection = sourceSelection
        isScanning = true
        errorMessage = nil
        AppLogger.scan("Source scan started", level: .info)
        sourceScanTask = Task {
            let access = sourceFolder.startAccessingSecurityScopedResource()
            defer {
                if access { sourceFolder.stopAccessingSecurityScopedResource() }
                if selection == sourceSelection {
                    isScanning = false
                    sourceScanTask = nil
                }
            }
            do {
                let report = try await MusicTransferEngine.scanWithReport(folder: sourceFolder)
                let found = report.files
                let foundPlaylists = try await MusicTransferEngine.scanPlaylists(folder: sourceFolder, files: found)
                try Task.checkCancellation()
                guard selection == sourceSelection, self.sourceFolder == sourceFolder else { return }
                files = found
                playlists = foundPlaylists
                scannedFiles = found
                scannedPlaylists = foundPlaylists
                skippedAudioByExtension = report.skippedAudioByExtension
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
                guard selection == sourceSelection, self.sourceFolder == sourceFolder else { return }
                errorMessage = error.localizedDescription
                AppLogger.scan("Source scan failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func keepImportFiles(withIDs selectedIDs: Set<String>) {
        guard !isScanning && !isCopying else { return }
        let selection = MusicTransferEngine.importSelection(
            files: scannedFiles,
            playlists: scannedPlaylists,
            selectedIDs: selectedIDs
        )
        files = selection.files
        playlists = selection.playlists
        resultMessage = nil
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
        guard !isCopying, !isManagingLibrary, !isExporting, !isRestoring else { return }
        guard let request = makeTransferRequest() else { return }
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            startSimulatedCopy(trackCount: request.files.count)
            return
        }
#endif
        copyTask?.cancel()
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        AppLogger.sync(
            "Sync requested tracks=\(request.files.count) playlists=\(request.playlists.count) "
                + "bytes=\(request.byteCount)",
            level: .info
        )
        copyTask = Task { [weak self] in
            await self?.performCopy(request)
        }
    }

    private func makeTransferRequest() -> TransferRequest? {
        guard let sourceFolder else {
            errorMessage = PodBridgeError.noSourceFolder.localizedDescription
            return nil
        }
        guard let destinationFolder else {
            errorMessage = PodBridgeError.noDestinationFolder.localizedDescription
            return nil
        }
        guard destinationDeviceProfile != nil else {
            errorMessage = PodBridgeError.deviceModelRequired.localizedDescription
            return nil
        }
        guard !files.isEmpty else {
            errorMessage = PodBridgeError.noMusicFiles.localizedDescription
            return nil
        }
        return TransferRequest(
            sourceFolder: sourceFolder,
            destinationFolder: destinationFolder,
            files: files,
            playlists: playlists,
            byteCount: totalBytes
        )
    }

    private func performCopy(_ request: TransferRequest) async {
        let backgroundExecution = await TransferBackgroundExecution.shared.begin(
            total: request.files.count
        ) { [weak self] in
            self?.copyTask?.cancel()
        }
        let sourceAccess = request.sourceFolder.startAccessingSecurityScopedResource()
        let destinationAccess = request.destinationFolder.startAccessingSecurityScopedResource()
        var transferSucceeded = false
        defer {
            if sourceAccess { request.sourceFolder.stopAccessingSecurityScopedResource() }
            if destinationAccess { request.destinationFolder.stopAccessingSecurityScopedResource() }
            backgroundExecution.finish(success: transferSucceeded)
            isCopying = false
            copyTask = nil
        }
        do {
            let result = try await IPodSyncEngine.sync(
                files: request.files,
                playlists: request.playlists,
                root: request.destinationFolder
            ) { count in
                await MainActor.run {
                    self.copiedCount = count
                    backgroundExecution.update(completed: count, total: request.files.count)
                }
            }
            try applyTransferResult(result, destination: request.destinationFolder)
            transferSucceeded = true
        } catch is CancellationError {
            resultMessage = "Copy stopped after \(copiedCount) track\(copiedCount == 1 ? "" : "s")."
            AppLogger.sync("Sync cancelled copied=\(copiedCount)", level: .error)
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.sync(
                "Sync UI failed copied=\(copiedCount) error=\(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func applyTransferResult(_ result: IPodSyncEngine.Result, destination: URL) throws {
        existingTrackCount = result.total
        let library = try IPodSyncEngine.library(root: destination)
        libraryTracks = library.tracks
        libraryPlaylists = library.playlists
        refreshStorage(for: destination)
        backups = (try? IPodSyncEngine.backups(root: destination)) ?? backups
        let reused = result.exactDuplicatesReused + result.metadataDuplicatesReused
        resultMessage = "Added \(result.added) tracks, reused \(reused) duplicates, "
            + "added \(result.playlistsAdded) playlists, and \(result.coversAdded) covers. "
            + "Backup: \(result.backupURL.lastPathComponent)."
        completeTransfer(addedTracks: result.added, backupName: result.backupURL.lastPathComponent)
        AppLogger.sync(
            "Sync UI completed added=\(result.added) exactDuplicatesReused=\(result.exactDuplicatesReused) "
                + "metadataDuplicatesReused=\(result.metadataDuplicatesReused) "
                + "playlists=\(result.playlistsAdded) covers=\(result.coversAdded) "
                + "total=\(result.total) backup=\(result.backupURL.lastPathComponent)",
            level: .info
        )
    }

    func cancelCopy() {
        copyTask?.cancel()
#if DEBUG || PODBRIDGE_DEMO
        simulationTask?.cancel()
#endif
    }

#if DEBUG || PODBRIDGE_DEMO
    private func startSimulatedCopy(trackCount: Int) {
        simulationTask?.cancel()
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        simulationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCopying = false
                self.simulationTask = nil
            }
            do {
                for index in 1...max(trackCount, 1) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 320_000_000)
                    self.copiedCount = min(index, trackCount)
                }
                self.existingTrackCount = (self.existingTrackCount ?? self.libraryTracks.count) + trackCount
                self.resultMessage = "Simulated a transfer of \(trackCount) tracks. No audio files or physical iPod data were changed."
                self.completeTransfer(addedTracks: trackCount)
            } catch is CancellationError {
                self.resultMessage = "Copy stopped after \(self.copiedCount) tracks."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
#endif

    func refreshStorage(for url: URL) {
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

    func completeTransfer(addedTracks: Int, backupName: String? = nil) {
        let summary = playlists
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .map { TransferCompletion.Playlist(name: $0.name, trackCount: $0.fileIndices.count) }
        let destinationName = destinationFolder?.lastPathComponent ?? "your iPod"
        transferCompletion = TransferCompletion(
            addedTracks: addedTracks,
            destinationName: destinationName.isEmpty ? "your iPod" : destinationName,
            playlists: summary,
            backupName: backupName
        )
        files = []
        playlists = []
        scannedFiles = []
        scannedPlaylists = []
        skippedAudioByExtension = [:]
        copiedCount = 0
    }

}
