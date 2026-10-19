// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Runs an ALACarte download and delivers it to one destination workflow.
///
/// The service owns downloaded temporary folders until the destination write
/// finishes. It removes them after success, cancellation, or failure. Access to
/// the security-scoped iPod URL remains owned by the calling view model.
enum ALACarteTransferService {
    enum Progress: Sendable {
        case downloading(itemIndex: Int, itemCount: Int, title: String, completed: Int, total: Int)
        case writingAppleLibrary(completed: Int, total: Int)
        case copyingRockbox(completed: Int)
    }

    static func addToAppleLibrary(
        client: ALACarteClient,
        items: [ALACarteLibraryItem],
        destination: URL,
        progress: @escaping @Sendable (Progress) async -> Void
    ) async throws -> IPodSyncEngine.Result {
        let batch = try await download(client: client, items: items, progress: progress)
        defer { removeTemporaryFolders(batch.downloadedFolders) }
        return try await IPodSyncEngine.sync(
            files: batch.files,
            playlists: batch.playlists,
            root: destination
        ) { completed in
            await progress(.writingAppleLibrary(completed: completed, total: batch.files.count))
        }
    }

    static func copyToRockbox(
        client: ALACarteClient,
        items: [ALACarteLibraryItem],
        destination: URL,
        progress: @escaping @Sendable (Progress) async -> Void
    ) async throws -> RockboxTransferEngine.CopyResult {
        let batch = try await download(client: client, items: items, progress: progress)
        defer { removeTemporaryFolders(batch.downloadedFolders) }
        let musicFolder = destination.appendingPathComponent("Music", isDirectory: true)
        return try await RockboxTransferEngine.copyFolderContents(
            from: batch.downloadedFolders,
            to: musicFolder
        ) { completed in
            await progress(.copyingRockbox(completed: completed))
        }
    }

    private static func download(
        client: ALACarteClient,
        items: [ALACarteLibraryItem],
        progress: @escaping @Sendable (Progress) async -> Void
    ) async throws -> ALACarteSourceBatch {
        try await ALACarteSourceDownloader.download(items: items, using: client) { itemIndex, item, completed, total in
            await progress(.downloading(
                itemIndex: itemIndex,
                itemCount: items.count,
                title: item.title,
                completed: completed,
                total: total
            ))
        }
    }

    private static func removeTemporaryFolders(_ folders: [URL]) {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }
}
