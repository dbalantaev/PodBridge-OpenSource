// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev
import Foundation
extension ClassicDatabase {
    private struct ImportPreparation {
        let library: ClassicLibrary
        let tracks: [ClassicTrack], albums: [ClassicTrack], artists: [ClassicTrack]
        let playlists: [ClassicPlaylist]
    }
    private struct ImportTrackAllocator {
        private let increment: UInt32
        private var trackIDs: Set<UInt32>, databaseIDs: Set<UInt64>
        private var nextTrackID: UInt32
        private var albumIDs: [String: UInt32], artistIDs: [String: UInt32]
        private var nextAlbumID: UInt32, nextArtistID: UInt32, nextArtworkID: UInt32
        private(set) var newAlbums: [ClassicTrack] = [], newArtists: [ClassicTrack] = []
        init(library: ClassicLibrary) {
            let recentIDs = library.tracks.suffix(32).map(\.id)
            increment = recentIDs.count >= 2
                && zip(recentIDs, recentIDs.dropFirst()).allSatisfy { $1 == $0 &+ 2 } ? 2 : 1
            trackIDs = Set(library.tracks.map(\.id))
            databaseIDs = Set(library.tracks.map(\.databaseID))
            nextTrackID = (library.tracks.map(\.id).max() ?? 0) &+ increment
            albumIDs = Self.albumIDs(in: library.tracks)
            artistIDs = Self.artistIDs(in: library.tracks)
            nextAlbumID = (albumIDs.values.max() ?? 0) &+ 1
            nextArtistID = (artistIDs.values.max() ?? 0) &+ 1
            nextArtworkID = (library.tracks.map(\.artworkImageID).max() ?? 0) &+ 1
        }
        mutating func prepare(_ additions: [ClassicTrack]) -> [ClassicTrack] { additions.map { prepare($0) } }
        private mutating func prepare(_ source: ClassicTrack) -> ClassicTrack {
            var track = source
            track.id = nextAvailableTrackID()
            track.databaseID = nextAvailableDatabaseID()
            assignAlbum(to: &track)
            assignArtist(to: &track)
            assignArtwork(to: &track)
            return track
        }
        private mutating func nextAvailableTrackID() -> UInt32 {
            while nextTrackID == 0 || trackIDs.contains(nextTrackID) { nextTrackID &+= increment }
            defer { nextTrackID &+= increment }
            trackIDs.insert(nextTrackID)
            return nextTrackID
        }
        private mutating func nextAvailableDatabaseID() -> UInt64 {
            var identifier: UInt64
            repeat { identifier = UInt64.random(in: 1...UInt64.max) } while databaseIDs.contains(identifier)
            databaseIDs.insert(identifier)
            return identifier
        }
        private mutating func assignAlbum(to track: inout ClassicTrack) {
            let key = "\(ClassicDatabase.albumGroupingArtist(track))\u{0}\(track.album)"
            if let identifier = albumIDs[key] {
                track.albumID = identifier
                return
            }
            track.albumID = nextAlbumID
            albumIDs[key] = nextAlbumID
            nextAlbumID &+= 1
            newAlbums.append(track)
        }
        private mutating func assignArtist(to track: inout ClassicTrack) {
            if let identifier = artistIDs[track.artist] {
                track.artistID = identifier
                return
            }
            track.artistID = nextArtistID
            artistIDs[track.artist] = nextArtistID
            nextArtistID &+= 1
            newArtists.append(track)
        }
        private mutating func assignArtwork(to track: inout ClassicTrack) {
            guard let artwork = track.artworkData, !artwork.isEmpty else { return }
            track.artworkImageID = nextArtworkID
            track.artworkByteCount = UInt32(clamping: artwork.count)
            nextArtworkID &+= 1
        }
        private static func albumIDs(in tracks: [ClassicTrack]) -> [String: UInt32] {
            Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                guard track.albumID != 0 else { return nil }
                return ("\(ClassicDatabase.albumGroupingArtist(track))\u{0}\(track.album)", track.albumID)
            })
        }
        private static func artistIDs(in tracks: [ClassicTrack]) -> [String: UInt32] {
            Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
                guard track.artistID != 0 else { return nil }
                return (track.artist, track.artistID)
            })
        }
    }
    static func merge(
        existing: Data,
        additions: [ClassicTrack],
        pendingPlaylists: [PendingPlaylist] = [],
        firewireID: Data
    ) throws -> MergeResult {
        let originalLibrary = try parse(existing)
        let preparation = prepareImport(
            additions: additions,
            pendingPlaylists: pendingPlaylists,
            in: originalLibrary
        )
        let signed = try mergedDatabase(
            existing: existing,
            preparation: preparation,
            firewireID: firewireID
        )
        return try verifiedMerge(
            signed,
            originalLibrary: originalLibrary,
            preparation: preparation,
            firewireID: firewireID
        )
    }
    private static func prepareImport(
        additions: [ClassicTrack],
        pendingPlaylists: [PendingPlaylist],
        in originalLibrary: ClassicLibrary
    ) -> ImportPreparation {
        var allocator = ImportTrackAllocator(library: originalLibrary)
        let tracks = allocator.prepare(additions)
        var library = originalLibrary
        library.tracks.append(contentsOf: tracks)
        let playlists = appendedPlaylists(
            pendingPlaylists,
            originalTrackIDs: Set(originalLibrary.tracks.map(\.id)),
            additions: tracks,
            existingPlaylists: library.playlists
        )
        library.playlists.append(contentsOf: playlists)
        return ImportPreparation(
            library: library,
            tracks: tracks,
            albums: allocator.newAlbums,
            artists: allocator.newArtists,
            playlists: playlists
        )
    }
    private static func appendedPlaylists(
        _ pendingPlaylists: [PendingPlaylist],
        originalTrackIDs: Set<UInt32>,
        additions: [ClassicTrack],
        existingPlaylists: [ClassicPlaylist]
    ) -> [ClassicPlaylist] {
        var names = Set(existingPlaylists.map { $0.name.lowercased() })
        return pendingPlaylists.compactMap { pending in
            let trackIDs = pending.members.compactMap { member -> UInt32? in
                switch member {
                case .existingTrackID(let identifier):
                    return originalTrackIDs.contains(identifier) ? identifier : nil
                case .additionIndex(let index):
                    return additions.indices.contains(index) ? additions[index].id : nil
                }
            }
            guard !trackIDs.isEmpty else { return nil }
            let name = uniquePlaylistName(pending.name, usedNames: &names)
            return ClassicPlaylist(name: name, trackIDs: trackIDs)
        }
    }
    private static func uniquePlaylistName(_ requested: String, usedNames: inout Set<String>) -> String {
        var name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Imported Playlist" }
        let base = name
        var suffix = 2
        while usedNames.contains(name.lowercased()) {
            name = "\(base) (\(suffix))"
            suffix += 1
        }
        usedNames.insert(name.lowercased())
        return name
    }
    private static func mergedDatabase(
        existing: Data,
        preparation: ImportPreparation,
        firewireID: Data
    ) throws -> Data {
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        let replacements = try mergedSectionReplacements(existing, sections: sections, preparation: preparation)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            output.append(replacements[section.range.lowerBound] ?? existing[section.range])
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return try Hash58.sign(output, firewireID: firewireID)
    }
    private static func mergedSectionReplacements(
        _ data: Data,
        sections: [TopLevelSection],
        preparation: ImportPreparation
    ) throws -> [Int: Data] {
        guard let trackSection = sections.first(where: { $0.type == 1 }) else { throw PodBridgeError.invalidDatabase }
        let playlistSections = sections.filter { $0.type == 2 || $0.type == 3 }
        guard !playlistSections.isEmpty else { throw PodBridgeError.invalidDatabase }
        let rootLibraryID = try data.littleUInt64(at: 0x24)
        var replacements = [trackSection.range.lowerBound: try mergedTrackSection(
            data,
            range: trackSection.range,
            additions: preparation.tracks,
            rootLibraryID: rootLibraryID
        )]
        for section in playlistSections {
            replacements[section.range.lowerBound] = try mergedPlaylistSection(
                data,
                range: section.range,
                additions: preparation.tracks,
                tracks: preparation.library.tracks,
                appendedPlaylists: preparation.playlists
            )
        }
        try addEntityReplacement(
            type: 4,
            records: preparation.albums.map(albumRecord),
            to: &replacements,
            data: data,
            sections: sections
        )
        try addEntityReplacement(
            type: 8,
            records: preparation.artists.map(artistRecord),
            to: &replacements,
            data: data,
            sections: sections
        )
        return replacements
    }
    private static func addEntityReplacement(
        type: UInt32,
        records: [Data],
        to replacements: inout [Int: Data],
        data: Data,
        sections: [TopLevelSection]
    ) throws {
        guard let section = sections.first(where: { $0.type == type }) else { return }
        replacements[section.range.lowerBound] = try mergedEntitySection(data, range: section.range, additions: records)
    }
    private static func verifiedMerge(
        _ data: Data,
        originalLibrary: ClassicLibrary,
        preparation: ImportPreparation,
        firewireID: Data
    ) throws -> MergeResult {
        let verified = try parse(data)
        let diagnostics = try inspect(data, firewireID: firewireID)
        let added = try preparation.tracks.map { try inspectTrack(data, expected: $0) }
        guard verified.tracks.count == preparation.library.tracks.count,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == preparation.library.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.hash58Valid,
              added.allSatisfy(\.isValid),
              Set(verified.tracks.prefix(originalLibrary.tracks.count).map(\.id))
                == Set(originalLibrary.tracks.map(\.id)) else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return MergeResult(data: data, library: preparation.library, addedTrackDiagnostics: added)
    }
    private static func mergedTrackSection(
        _ data: Data,
        range: Range<Int>,
        additions: [ClassicTrack],
        rootLibraryID: UInt64
    ) throws -> Data {
        var section = Data(data[range])
        let sectionHeader = Int(try section.littleUInt32(at: 4))
        guard section.ascii(at: sectionHeader, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        let oldCount = try section.littleUInt32(at: sectionHeader + 8)
        for track in additions { section.append(trackRecord(track, rootLibraryID: rootLibraryID)) }
        try section.setLittleUInt32(UInt32(section.count), at: 8)
        try section.setLittleUInt32(oldCount + UInt32(additions.count), at: sectionHeader + 8)
        return section
    }
    private static func mergedPlaylistSection(
        _ data: Data,
        range: Range<Int>,
        additions: [ClassicTrack],
        tracks: [ClassicTrack],
        appendedPlaylists: [ClassicPlaylist]
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var records: [Data] = []
        var primaryFound = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let primary = try source.littleUInt32(at: cursor + 20) != 0
            let record = Data(source[cursor..<(cursor + length)])
            if primary {
                guard !primaryFound else { throw PodBridgeError.invalidDatabase }
                records.append(try mergedPrimaryPlaylistRecord(record, additions: additions, tracks: tracks))
                primaryFound = true
            } else {
                records.append(record)
            }
            cursor += length
        }
        guard primaryFound else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(listOffset + listHeader))
        records.forEach { output.append($0) }
        appendedPlaylists.forEach {
            output.append(playlistRecord(name: $0.name, ids: $0.trackIDs, primary: false, tracks: []))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(UInt32(records.count + appendedPlaylists.count), at: listOffset + 8)
        return output
    }
    private static func mergedPrimaryPlaylistRecord(
        _ source: Data,
        additions: [ClassicTrack],
        tracks: [ClassicTrack]
    ) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        let total = Int(try source.littleUInt32(at: 8))
        guard header >= 24, total == source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        var cursor = header
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod",
               length >= 72,
               try child.littleUInt32(at: 12) == 52 {
                let sortType = try child.littleUInt32(at: 24)
                let order = try mergedSortOrder(
                    child,
                    sortType: sortType,
                    additions: additions,
                    tracks: tracks
                )
                output.append(try updatedSortIndex(child, order: order))
            } else if child.ascii(at: 0, length: 4) == "mhod",
                      length >= 40,
                      try child.littleUInt32(at: 12) == 53 {
                output.append(try updatedJumpTable(child, additions: additions, tracks: tracks))
            } else {
                output.append(child)
            }
            cursor += length
        }
        let oldMembers = try source.littleUInt32(at: 16)
        for (offset, track) in additions.enumerated() {
            output.append(playlistItem(order: Int(oldMembers) + offset, trackID: track.id))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldMembers + UInt32(additions.count), at: 16)
        return output
    }
    private static func mergedSortOrder(
        _ source: Data,
        sortType: UInt32,
        additions: [ClassicTrack],
        tracks: [ClassicTrack]
    ) throws -> [Int] {
        let oldTrackCount = tracks.count - additions.count
        let storedCount = Int(try source.littleUInt32(at: 28))
        guard oldTrackCount >= 0,
              storedCount == oldTrackCount,
              72 + storedCount * 4 <= source.count else {
            throw PodBridgeError.invalidDatabase
        }
        var order: [Int] = []
        for offset in 0..<storedCount {
            let index = Int(try source.littleUInt32(at: 72 + offset * 4))
            guard index >= 0, index < oldTrackCount else { throw PodBridgeError.invalidDatabase }
            order.append(index)
        }
        guard Set(order).count == oldTrackCount else { throw PodBridgeError.invalidDatabase }
        let knownAppleSort = [UInt32(3), 4, 5, 7].contains(sortType)
        for newIndex in oldTrackCount..<tracks.count {
            guard knownAppleSort else {
                order.append(newIndex)
                continue
            }
            let insertion = order.firstIndex { existingIndex in
                compareTracks(tracks[newIndex], tracks[existingIndex], sortType: sortType) == .orderedAscending
            } ?? order.endIndex
            order.insert(newIndex, at: insertion)
        }
        return order
    }
    private static func mergedEntitySection(_ data: Data, range: Range<Int>, additions: [Data]) throws -> Data {
        var section = Data(data[range])
        let sectionHeader = Int(try section.littleUInt32(at: 4))
        guard sectionHeader + 12 <= section.count else { throw PodBridgeError.invalidDatabase }
        let oldCount = try section.littleUInt32(at: sectionHeader + 8)
        additions.forEach { section.append($0) }
        try section.setLittleUInt32(UInt32(section.count), at: 8)
        try section.setLittleUInt32(oldCount + UInt32(additions.count), at: sectionHeader + 8)
        return section
    }
}
