// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension MusicTransferViewModel {
    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var copyProgress: Double {
        guard !files.isEmpty else { return 0 }
        return Double(copiedCount) / Double(files.count)
    }

    var storageUsedBytes: Int64? {
        guard let total = storageTotalBytes, let free = storageFreeBytes else { return nil }
        return max(0, total - free)
    }

    var storageUsedFraction: Double? {
        guard let total = storageTotalBytes, total > 0, let used = storageUsedBytes else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var missingArtworkTrackCount: Int {
        libraryTracks.filter { $0.artworkImageID == 0 }.count
    }

    var automaticArtworkCandidateCount: Int {
        missingArtworkTrackCount
    }

    var safeAlbumRepairCount: Int {
        IPodSyncEngine.albumArtistRepairPreview(
            tracks: libraryTracks,
            playlists: libraryPlaylists
        ).albums
    }

    var libraryAlbums: [IPodAlbum] {
        let groups = Dictionary(grouping: libraryTracks) { track in
            let groupingArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            return track.albumID == 0 ? "metadata:\(groupingArtist)\u{0}\(track.album)" : "id:\(track.albumID)"
        }
        return groups.map { key, tracks in
            let orderedTracks = tracks.sorted {
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let first = orderedTracks[0]
            let albumArtist = first.albumArtist.isEmpty ? first.artist : first.albumArtist
            return IPodAlbum(
                id: key,
                title: first.album,
                artist: albumArtist,
                albumArtist: albumArtist,
                compilation: orderedTracks.contains(where: \.compilation),
                genre: first.genre,
                year: first.year,
                tracks: orderedTracks
            )
        }.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            return artistOrder == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artistOrder == .orderedAscending
        }
    }
}
