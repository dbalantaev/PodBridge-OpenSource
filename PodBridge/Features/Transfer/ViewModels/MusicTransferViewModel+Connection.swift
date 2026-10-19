// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import UIKit

private struct IPodDestinationSnapshot: Sendable {
    let library: ClassicLibrary
    let backups: [IPodSyncEngine.Backup]
    let totalCapacity: Int64?
    let availableCapacity: Int64?
    let diskUseStatus: IPodDiskUseStatus
}

private struct IPodRestoreSnapshot: Sendable {
    let tracks: Int
    let removedFiles: Int
    let safetyBackup: URL
    let library: ClassicLibrary
    let backups: [IPodSyncEngine.Backup]
    let totalCapacity: Int64?
    let availableCapacity: Int64?
}

@MainActor
extension MusicTransferViewModel {
    func selectSource(_ url: URL) {
        sourceScanTask?.cancel()
        sourceSelection = UUID()
        AppLogger.scan("Source selected folder=\(url.lastPathComponent)", level: .info)
        sourceFolder = url
        files = []
        playlists = []
        scannedFiles = []
        scannedPlaylists = []
        skippedAudioByExtension = [:]
        copiedCount = 0
        resultMessage = nil
        scanSource()
    }

    func selectDestination(_ url: URL) {
        guard !isCopying, !isManagingLibrary, !isRestoring, !isExporting,
              !isRockboxCopying, !isUpdatingDiskUse else { return }
        stopLocalSignatureRecovery()
        destinationLoadTask?.cancel()
        destinationSelection = UUID()
        let selection = destinationSelection
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod { disconnectEmulatedIPod() }
#endif
        prepareDestinationSelection(url)
        destinationLoadTask = Task {
            defer {
                if selection == destinationSelection {
                    isConnectingIPod = false
                    destinationLoadTask = nil
                }
            }
            await Task.yield()
            do {
                let loaded = try await loadDestinationSnapshot(url)
                try Task.checkCancellation()
                guard selection == destinationSelection, destinationFolder == url else { return }
                applyDestinationSnapshot(loaded)
                shouldChooseDeviceProfile = true
                AppLogger.device(
                    "Destination validation succeeded existingTracks=\(existingTrackCount ?? 0)",
                    level: .info
                )
            } catch is CancellationError {
                return
            } catch {
                guard selection == destinationSelection, destinationFolder == url else { return }
                destinationFolder = nil
                errorMessage = error.localizedDescription
                AppLogger.device("Destination validation failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    private func prepareDestinationSelection(_ url: URL) {
        AppLogger.device("Destination selected name=\(url.lastPathComponent)", level: .info)
        destinationFolder = url
        destinationDeviceProfile = nil
        shouldChooseDeviceProfile = false
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
        destinationDiskUseStatus = .unavailable
        isConnectingIPod = true
    }

    private func loadDestinationSnapshot(_ url: URL) async throws -> IPodDestinationSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            )
            return IPodDestinationSnapshot(
                library: try IPodSyncEngine.library(root: url),
                backups: try IPodSyncEngine.backups(root: url),
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                availableCapacity: values?.volumeAvailableCapacity.map(Int64.init),
                diskUseStatus: IPodDiskUsePreferences.status(at: url)
            )
        }.value
    }

    private func applyDestinationSnapshot(_ snapshot: IPodDestinationSnapshot) {
        existingTrackCount = snapshot.library.tracks.count
        libraryTracks = snapshot.library.tracks
        libraryPlaylists = snapshot.library.playlists
        backups = snapshot.backups
        storageTotalBytes = snapshot.totalCapacity
        storageFreeBytes = snapshot.availableCapacity
        destinationDiskUseStatus = snapshot.diskUseStatus
    }

    func selectDeviceProfile(_ profile: IPodDeviceProfile) {
        guard let destinationFolder else { return }
        destinationDeviceProfile = profile
        shouldChooseDeviceProfile = false
        IPodDeviceProfile.save(profile, for: destinationFolder)
        destinationNeedsFirewireID = false
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
        do {
            try IPodSyncEngine.recoverInterruptedDeletions(root: destinationFolder)
            let databaseKey = try IPodDeviceProfile.databaseKey(at: destinationFolder)
            deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == databaseKey.hexString }
            AppLogger.device(
                "Device profile selected model=\(profile.rawValue) "
                    + "checksum=\(String(describing: profile.checksum)) tested=\(profile.isHardwareTested)",
                level: .info
            )
        } catch PodBridgeError.missingFirewireID {
#if targetEnvironment(macCatalyst)
            destinationNeedsFirewireID = false
            errorMessage = "PodBridge could not read this iPod’s USB serial number. "
                + "Reconnect the iPod directly to the Mac, choose its mounted volume again, "
                + "and make sure removable-volume access is allowed."
#else
            destinationNeedsFirewireID = true
#endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectDestination() {
        guard !isCopying, !isManagingLibrary, !isRestoring, !isExporting,
              !isRockboxCopying, !isUpdatingDiskUse else { return }
        stopLocalSignatureRecovery()
        destinationLoadTask?.cancel()
        destinationLoadTask = nil
        destinationSelection = UUID()
        isConnectingIPod = false
#if DEBUG || PODBRIDGE_DEMO
        if isEmulatingIPod {
            disconnectEmulatedIPod()
            return
        }
#endif
        destinationFolder = nil
        destinationDeviceProfile = nil
        shouldChooseDeviceProfile = false
        existingTrackCount = nil
        storageTotalBytes = nil
        storageFreeBytes = nil
        libraryTracks = []
        libraryPlaylists = []
        backups = []
        deletionBackups = []
        destinationNeedsFirewireID = false
        destinationDiskUseStatus = .unavailable
        AppLogger.device("iPod destination safely released by user", level: .info)
    }

    func acknowledgeDeviceProfilePrompt() {
        shouldChooseDeviceProfile = false
    }

    func enablePersistentDiskUse() {
        guard let destinationFolder, destinationDiskUseStatus == .disabled,
              !isUpdatingDiskUse else { return }
        isUpdatingDiskUse = true
        resultMessage = nil
        errorMessage = nil
        diskUseTask = Task {
            await Task.yield()
            defer {
                isUpdatingDiskUse = false
                diskUseTask = nil
            }
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    let access = destinationFolder.startAccessingSecurityScopedResource()
                    defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
                    return try IPodDiskUsePreferences.enable(at: destinationFolder)
                }.value
                destinationDiskUseStatus = .enabled
                resultMessage = "Disk use is enabled for future connections. Original settings were "
                    + "backed up in \(backup.deletingLastPathComponent().lastPathComponent)."
            } catch {
                destinationDiskUseStatus = IPodDiskUsePreferences.status(at: destinationFolder)
                errorMessage = error.localizedDescription
            }
        }
    }

    func restoreOldestBackup() {
        guard let destinationFolder, let backup = backups.first else { return }
        isRestoring = true
        resultMessage = nil
        errorMessage = nil
        restoreTask = Task {
            await Task.yield()
            defer {
                isRestoring = false
                restoreTask = nil
            }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let access = destinationFolder.startAccessingSecurityScopedResource()
                    defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
                    let result = try IPodSyncEngine.restore(backup: backup, root: destinationFolder)
                    let library = try IPodSyncEngine.library(root: destinationFolder)
                    let backups = try IPodSyncEngine.backups(root: destinationFolder)
                    let values = try? destinationFolder.resourceValues(
                        forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
                    )
                    return IPodRestoreSnapshot(
                        tracks: result.tracks,
                        removedFiles: result.removedFiles,
                        safetyBackup: result.safetyBackup,
                        library: library,
                        backups: backups,
                        totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
                        availableCapacity: values?.volumeAvailableCapacity.map(Int64.init)
                    )
                }.value
                existingTrackCount = loaded.tracks
                libraryTracks = loaded.library.tracks
                libraryPlaylists = loaded.library.playlists
                backups = loaded.backups
                storageTotalBytes = loaded.totalCapacity
                storageFreeBytes = loaded.availableCapacity
                resultMessage = "Restored backup \(backup.name) with \(loaded.tracks) tracks. "
                    + "Removed \(loaded.removedFiles) files added after it. "
                    + "Safety backup: \(loaded.safetyBackup.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.database("Backup restore failed name=\(backup.name) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

}
