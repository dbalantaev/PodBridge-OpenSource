// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

#if DEBUG || PODBRIDGE_DEMO
/// Runs demo artwork lookup while delegating observable state changes to the main actor.
enum DemoArtworkSearchService {
    static func search(
        tracks: [ClassicTrack],
        trackIDs: Set<UInt32>,
        replaceExisting: Bool,
        onProgress: @escaping @MainActor @Sendable (IPodSyncEngine.ArtworkSearchProgress) -> Void,
        onArtwork: @escaping @MainActor @Sendable (UInt32, Data) -> Void
    ) async -> Int? {
        let targets = tracks.filter {
            trackIDs.contains($0.id) && (replaceExisting || $0.artworkData == nil)
        }
        let service = ArtworkLookupService()
        var updated = 0

        for (offset, track) in targets.enumerated() {
            guard !Task.isCancelled else { return nil }
            await onProgress(
                .init(
                    completedItems: offset,
                    totalItems: targets.count,
                    matchedItems: updated,
                    tracksPrepared: updated
                )
            )
            do {
                let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
                let candidates = try await service.albumCandidates(album: track.album, artist: artist)
                if let artwork = candidates.first?.data {
                    await onArtwork(track.id, artwork)
                    updated += 1
                }
            } catch {
                AppLogger.artwork(
                    "Demo artwork lookup failed id=\(track.id) error=\(error.localizedDescription)",
                    level: .info
                )
            }
        }

        return updated
    }
}
#endif
