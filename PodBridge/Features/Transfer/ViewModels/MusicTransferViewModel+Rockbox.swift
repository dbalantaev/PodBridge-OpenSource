// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import UIKit

extension MusicTransferViewModel {
    func copyMusicForRockbox(from source: URL, to folder: URL) {
        guard let destinationFolder, !isRockboxCopying, !isCopying, !isManagingLibrary, !isRestoring else { return }
        guard isFolder(folder, inside: destinationFolder) else {
            errorMessage = "Choose a destination folder on the connected iPod."
            return
        }
        isRockboxCopying = true
        rockboxCopiedCount = 0
        rockboxTotalCount = 0
        resultMessage = nil
        errorMessage = nil
        rockboxCopyTask = Task { [self] in
            let sourceAccess = source.startAccessingSecurityScopedResource()
            let iPodAccess = destinationFolder.startAccessingSecurityScopedResource()
            let folderAccess = folder.startAccessingSecurityScopedResource()
            defer {
                if folderAccess { folder.stopAccessingSecurityScopedResource() }
                if iPodAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                isRockboxCopying = false
                rockboxCopyTask = nil
            }
            do {
                let report = try await MusicTransferEngine.scanWithReport(folder: source)
                let audioFiles = report.files
                guard !audioFiles.isEmpty else { throw PodBridgeError.noMusicFiles }
                rockboxTotalCount = audioFiles.count
                let result = try await RockboxTransferEngine.copyFolderContents(from: source, to: folder) { count in
                    await MainActor.run { self.rockboxCopiedCount = count }
                }
                resultMessage = "Copied \(result.copiedFiles) files (\(result.copiedBytes.formatted(.byteCount(style: .file)))) to \(folder.lastPathComponent) for Rockbox."
                AppLogger.sync("Rockbox music copy completed files=\(result.copiedFiles) destination=\(folder.lastPathComponent)", level: .info)
            } catch is CancellationError {
                resultMessage = "Rockbox music copy stopped after \(rockboxCopiedCount) files."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Rockbox music copy failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func installRockboxTheme(from source: URL) {
        guard let destinationFolder, !isRockboxCopying, !isCopying, !isManagingLibrary, !isRestoring else { return }
        let themes = destinationFolder.appendingPathComponent(".rockbox/themes", isDirectory: true)
        isRockboxCopying = true
        rockboxCopiedCount = 0
        rockboxTotalCount = 0
        resultMessage = nil
        errorMessage = nil
        rockboxCopyTask = Task { [self] in
            let sourceAccess = source.startAccessingSecurityScopedResource()
            let iPodAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if iPodAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                isRockboxCopying = false
                rockboxCopyTask = nil
            }
            do {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey])
                let result: RockboxTransferEngine.CopyResult
                if values.isDirectory == true {
                    let files = try await MusicTransferEngine.scanWithReport(folder: source).files
                    rockboxTotalCount = max(files.count, 1)
                    result = try await RockboxTransferEngine.copyFolderContents(from: source, to: themes) { count in
                        await MainActor.run { self.rockboxCopiedCount = count }
                    }
                } else {
                    result = try RockboxTransferEngine.copyTheme(from: source, to: themes)
                    rockboxCopiedCount = 1
                    rockboxTotalCount = 1
                }
                resultMessage = "Installed \(result.copiedFiles) theme file\(result.copiedFiles == 1 ? "" : "s") in .rockbox/themes."
                AppLogger.sync("Rockbox theme installed files=\(result.copiedFiles)", level: .info)
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Rockbox theme installation failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func cancelRockboxCopy() {
        rockboxCopyTask?.cancel()
    }

    private func isFolder(_ folder: URL, inside root: URL) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return folderPath != rootPath && folderPath.hasPrefix(rootPath + "/")
    }

}
