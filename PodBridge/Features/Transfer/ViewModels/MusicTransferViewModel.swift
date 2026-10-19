// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import UIKit

@MainActor
final class MusicTransferViewModel: ObservableObject {
    @Published var sourceFolder: URL?
    @Published var destinationFolder: URL?
    @Published var destinationDeviceProfile: IPodDeviceProfile?
    @Published var shouldChooseDeviceProfile = false
    @Published var existingTrackCount: Int?
    @Published var storageTotalBytes: Int64?
    @Published var storageFreeBytes: Int64?
    @Published var files: [MusicFile] = []
    @Published var playlists: [SourcePlaylist] = []
    @Published var scannedFiles: [MusicFile] = []
    @Published var scannedPlaylists: [SourcePlaylist] = []
    @Published var skippedAudioByExtension: [String: Int] = [:]
    @Published var isScanning = false
    @Published var isConnectingIPod = false
    @Published var isCopying = false
    @Published var copiedCount = 0
    @Published var isRockboxCopying = false
    @Published var rockboxCopiedCount = 0
    @Published var rockboxTotalCount = 0
    @Published var transferCompletion: TransferCompletion?
    @Published var libraryRepairCompletion: LibraryRepairCompletion?
    @Published var resultMessage: String?
    @Published var backups: [IPodSyncEngine.Backup] = []
    @Published var libraryTracks: [ClassicTrack] = []
    @Published var libraryPlaylists: [ClassicPlaylist] = []
    @Published var deletionBackups: [IPodSyncEngine.DeletionBackup] = []
    @Published var isRestoring = false
    @Published var isManagingLibrary = false
    @Published var isExporting = false
    @Published var exportedCount = 0
    @Published var exportTotalCount = 0
    @Published var deletionProgress: IPodSyncEngine.DeletionProgress?
    @Published var artworkSearchProgress: IPodSyncEngine.ArtworkSearchProgress?
#if PODBRIDGE_ALACARTE
    @Published var alacarteStatus: String?
#endif
    @Published var destinationNeedsFirewireID = false
    @Published var destinationDiskUseStatus: IPodDiskUseStatus = .unavailable
    @Published var isUpdatingDiskUse = false
    @Published var signatureRecoveryProgress: SignatureRecoveryProgress?
    @Published var isRecoveringSignatureID = false
    @Published var signatureRecoveryUsesMetal = false
    @Published var errorMessage: String?

    var copyTask: Task<Void, Never>?
    var rockboxCopyTask: Task<Void, Never>?
    var destinationLoadTask: Task<Void, Never>?
    var diskUseTask: Task<Void, Never>?
    var exportTask: Task<Void, Never>?
    var libraryTask: Task<Void, Never>?
    var restoreTask: Task<Void, Never>?
    var sourceScanTask: Task<Void, Never>?
    var signatureRecoveryTask: Task<Void, Never>?
#if DEBUG || PODBRIDGE_DEMO
    var simulationTask: Task<Void, Never>?
    var emulatedIPodContainer: URL?
#endif
    var artworkTask: Task<Void, Never>?
    var destinationSelection = UUID()
    var sourceSelection = UUID()
    var exportStartedAt: Date?
    var deletionStartedAt: Date?
    @Published var isEmulatingIPod = false

    var operationETA: String? {
        let completed: Int
        let total: Int
        let started: Date?
        if isExporting {
            completed = exportedCount
            total = exportTotalCount
            started = exportStartedAt
        } else if let progress = deletionProgress {
            completed = progress.completed
            total = progress.total
            started = deletionStartedAt
        } else {
            return nil
        }
        guard completed > 0, total > completed, let started else { return nil }
        let seconds = Int(Date().timeIntervalSince(started) / Double(completed) * Double(total - completed))
        guard seconds >= 0 else { return nil }
        return seconds < 60 ? "About \(max(1, seconds))s left" : "About \((seconds + 59) / 60)m left"
    }

}
