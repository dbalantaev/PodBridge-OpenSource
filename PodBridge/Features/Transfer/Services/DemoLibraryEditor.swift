// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

#if DEBUG || PODBRIDGE_DEMO
/// Applies demo-library edits in memory without touching mounted-volume data.
enum DemoLibraryEditor {
    static func updateTrack(
        id: UInt32,
        with update: ClassicDatabase.TrackMetadataUpdate,
        in tracks: inout [ClassicTrack]
    ) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].title = update.title
        tracks[index].artist = update.artist
        tracks[index].album = update.album
        tracks[index].genre = update.genre
        tracks[index].year = update.year
        tracks[index].trackNumber = update.trackNumber
        tracks[index].albumArtist = update.albumArtist
        tracks[index].compilation = update.compilation
    }

    static func updateAlbum(
        trackIDs: Set<UInt32>,
        with update: IPodSyncEngine.AlbumMetadataUpdate,
        in tracks: inout [ClassicTrack]
    ) {
        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            tracks[index].album = update.album
            tracks[index].albumArtist = update.albumArtist
            if let artist = update.songArtist {
                tracks[index].artist = artist
            }
            tracks[index].genre = update.genre
            tracks[index].year = update.year
            tracks[index].compilation = update.compilation
        }
    }

    static func setArtwork(_ artwork: Data, trackIDs: Set<UInt32>, in tracks: inout [ClassicTrack]) {
        var nextID = (tracks.map(\.artworkImageID).max() ?? 0) + 1
        for index in tracks.indices where trackIDs.contains(tracks[index].id) {
            tracks[index].artworkData = artwork
            tracks[index].artworkByteCount = UInt32(clamping: artwork.count)
            tracks[index].artworkImageID = nextID
            nextID += 1
        }
    }

    static func deleteTracks(
        withIDs trackIDs: Set<UInt32>,
        tracks: inout [ClassicTrack],
        playlists: inout [ClassicPlaylist]
    ) {
        tracks.removeAll { trackIDs.contains($0.id) }
        playlists = playlists.map {
            ClassicPlaylist(name: $0.name, trackIDs: $0.trackIDs.filter { !trackIDs.contains($0) })
        }
    }

    static func renamePlaylist(at index: Int, to name: String, in playlists: inout [ClassicPlaylist]) {
        guard playlists.indices.contains(index) else { return }
        playlists[index].name = name
    }

    static func replacePlaylistMembers(
        at index: Int,
        with trackIDs: [UInt32],
        in playlists: inout [ClassicPlaylist]
    ) {
        guard playlists.indices.contains(index) else { return }
        playlists[index].trackIDs = trackIDs
    }
}
#endif
