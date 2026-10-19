// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import UIKit

@MainActor
extension MusicTransferViewModel {
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

    func removeSignatureIDForRecoveryTest() throws -> URL {
        guard let destinationFolder else { throw PodBridgeError.noDestinationFolder }
        guard !isEmulatingIPod else {
            throw NSError(domain: "PodBridge.Diagnostics", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Connect the physical iPod before using this test."
            ])
        }
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }

        let id = try ClassicDatabase.firewireID(at: destinationFolder)
        let hex = id.map { String(format: "%02X", $0) }.joined()
        let manager = FileManager.default
        let documents = try manager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let backupFolder = documents.appendingPathComponent("PodBridge", isDirectory: true)
        try manager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let backupURL = backupFolder.appendingPathComponent(
            "iPod-Signature-ID-Backup_\(formatter.string(from: Date())).txt"
        )
        let contents = """
        PodBridge iPod Signature ID backup

        Signature ID: \(hex)

        Keep this file. If automatic recovery is interrupted, enter the 16-digit ID above in PodBridge.
        """
        try contents.write(to: backupURL, atomically: true, encoding: .utf8)
        let verifiedBackup = try String(contentsOf: backupURL, encoding: .utf8)
        guard verifiedBackup.contains("Signature ID: \(hex)") else {
            throw NSError(domain: "PodBridge.Diagnostics", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The ID backup could not be verified, so the iPod was not changed."
            ])
        }

        try ClassicDatabase.removeFirewireIDForTesting(at: destinationFolder, expectedID: id)
        UserDefaults.standard.removeObject(
            forKey: "PodBridge.signatureRecoveryCursor.\(destinationFolder.lastPathComponent)"
        )
        destinationNeedsFirewireID = true
        signatureRecoveryProgress = nil
        resultMessage = "Signature ID removed for testing. A verified backup is saved in "
            + "Files → On My iPhone → PodBridgeALACarte → PodBridge."
        return backupURL
    }

    func startLocalSignatureRecovery() {
        guard let destinationFolder, destinationNeedsFirewireID, !isRecoveringSignatureID else { return }
        let databaseURL = destinationFolder.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        let cursorKey = "PodBridge.signatureRecoveryCursor.\(destinationFolder.lastPathComponent)"
        let savedCursor = UInt64(UserDefaults.standard.string(forKey: cursorKey) ?? "0") ?? 0
        isRecoveringSignatureID = true
        UIApplication.shared.isIdleTimerDisabled = true
        errorMessage = nil
        resultMessage = nil

        signatureRecoveryTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isRecoveringSignatureID = false
                UIApplication.shared.isIdleTimerDisabled = false
                signatureRecoveryTask = nil
            }
            do {
                let recovery = try await LocalSignatureRecoveryService.recover(
                    databaseURL: databaseURL,
                    startAt: savedCursor,
                    onEngineSelected: { self.signatureRecoveryUsesMetal = $0 },
                    onProgress: {
                        UserDefaults.standard.set(String($0.tested), forKey: cursorKey)
                        self.signatureRecoveryProgress = $0
                    }
                )
                UserDefaults.standard.removeObject(forKey: cursorKey)
                guard let candidate = recovery.candidate else {
                    errorMessage = "No matching signature ID was found. "
                        + "The existing iTunesDB may not contain a valid device signature."
                    return
                }
                signatureRecoveryProgress = .init(
                    tested: recovery.tested,
                    total: LocalSignatureRecoveryService.candidateCount,
                    candidatesPerSecond: recovery.candidatesPerSecond
                )
                storeFirewireIDAndRepair(candidate.map { String(format: "%02X", $0) }.joined())
                resultMessage = "Signature ID was recovered locally and saved to the iPod."
            } catch is CancellationError {
                // The cursor is saved after every completed batch so recovery can resume.
            } catch {
                errorMessage = "Local recovery could not start: \(error.localizedDescription)"
            }
        }
    }

    func stopLocalSignatureRecovery() {
        signatureRecoveryTask?.cancel()
        signatureRecoveryTask = nil
    }

    func repairDatabaseSignature() {
        guard let destinationFolder, !isManagingLibrary, !isCopying else { return }
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

}
