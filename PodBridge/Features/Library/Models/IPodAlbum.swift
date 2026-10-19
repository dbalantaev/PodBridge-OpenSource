// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// A library album assembled from iPod track records for browsing and editing.
struct IPodAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let albumArtist: String
    let compilation: Bool
    let genre: String
    let year: UInt32
    let tracks: [ClassicTrack]

    var byteCount: UInt64 { tracks.reduce(0) { $0 + UInt64($1.byteCount) } }
}
