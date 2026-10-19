// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    static func addingArtwork(
        existing: Data,
        artworkByTrackID: [UInt32: Data],
        firewireID: Data
    ) throws -> ArtworkUpdateResult {
        guard !artworkByTrackID.isEmpty else { throw PodBridgeError.invalidArtwork }
        let originalLibrary = try parse(existing)
        let requestedIDs = Set(artworkByTrackID.keys)
        guard requestedIDs.isSubset(of: Set(originalLibrary.tracks.map(\.id))) else {
            throw PodBridgeError.trackNotFound
        }
        var nextArtworkID = (originalLibrary.tracks.map(\.artworkImageID).max() ?? 0) &+ 1
        if nextArtworkID == 0 { nextArtworkID = 1 }
        var updatedByID: [UInt32: ClassicTrack] = [:]
        for originalTrack in originalLibrary.tracks where requestedIDs.contains(originalTrack.id) {
            guard let artwork = artworkByTrackID[originalTrack.id],
                  !artwork.isEmpty else { continue }
            var track = originalTrack
            track.artworkImageID = nextArtworkID
            track.artworkByteCount = UInt32(clamping: artwork.count)
            track.artworkData = artwork
            updatedByID[track.id] = track
            nextArtworkID &+= 1
            if nextArtworkID == 0 { nextArtworkID = 1 }
        }
        guard !updatedByID.isEmpty else { throw PodBridgeError.invalidArtwork }

        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 1 {
                output.append(try trackSectionEditing(existing, range: section.range, tracksByID: updatedByID))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        let updatedTracks = originalLibrary.tracks.compactMap { updatedByID[$0.id] }
        let audits = try updatedTracks.map { try inspectTrack(signed, expected: $0) }
        guard diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid,
              audits.allSatisfy(\.isValid),
              updatedTracks.allSatisfy({ expected in
                  verified.tracks.first(where: { $0.id == expected.id })?.artworkImageID == expected.artworkImageID
              }) else { throw PodBridgeError.databaseVerificationFailed }
        return ArtworkUpdateResult(data: signed, library: verified, updatedTracks: updatedTracks)
    }
}
