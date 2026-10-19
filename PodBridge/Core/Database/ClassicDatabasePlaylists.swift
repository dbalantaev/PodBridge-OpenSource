// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    static func addingPlaylist(
        existing: Data,
        name: String,
        trackIDs: [UInt32],
        firewireID: Data
    ) throws -> EditResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !trackIDs.isEmpty else { throw PodBridgeError.invalidMetadata }
        let library = try parse(existing)
        guard !library.playlists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw PodBridgeError.duplicatePlaylistName
        }
        let validIDs = Set(library.tracks.map(\.id))
        guard trackIDs.allSatisfy(validIDs.contains) else { throw PodBridgeError.trackNotFound }
        let merged = try merge(
            existing: existing,
            additions: [],
            pendingPlaylists: [PendingPlaylist(
                name: name,
                members: trackIDs.map(PendingPlaylistMember.existingTrackID)
            )],
            firewireID: firewireID
        )
        return EditResult(data: merged.data, library: merged.library)
    }

    /// Renames a playlist and, when applicable, its generated compilation album.
    static func renamingPlaylist(
        existing: Data,
        playlistIndex: Int,
        newName: String,
        firewireID: Data
    ) throws -> EditResult {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PodBridgeError.invalidMetadata }
        var expectedLibrary = try parse(existing)
        guard expectedLibrary.playlists.indices.contains(playlistIndex) else { throw PodBridgeError.playlistNotFound }
        guard !expectedLibrary.playlists.enumerated().contains(where: {
            $0.offset != playlistIndex && $0.element.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw PodBridgeError.duplicatePlaylistName }
        expectedLibrary.playlists[playlistIndex].name = name
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionRenaming(
                    existing,
                    range: section.range,
                    playlistIndex: playlistIndex,
                    name: name
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified == expectedLibrary,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Removes a playlist while retaining all referenced tracks.
    static func removingPlaylist(
        existing: Data,
        playlistIndex: Int,
        firewireID: Data
    ) throws -> EditResult {
        var expectedLibrary = try parse(existing)
        guard expectedLibrary.playlists.indices.contains(playlistIndex) else {
            throw PodBridgeError.playlistNotFound
        }
        expectedLibrary.playlists.remove(at: playlistIndex)
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionRemovingPlaylist(
                    existing,
                    range: section.range,
                    playlistIndex: playlistIndex
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified == expectedLibrary,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == verified.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Replaces a playlist's ordered members while retaining every audio track.
    static func replacingPlaylistMembers(
        existing: Data,
        playlistIndex: Int,
        trackIDs: [UInt32],
        firewireID: Data
    ) throws -> EditResult {
        let library = try parse(existing)
        guard library.playlists.indices.contains(playlistIndex) else { throw PodBridgeError.playlistNotFound }
        let validIDs = Set(library.tracks.map(\.id))
        guard trackIDs.allSatisfy(validIDs.contains) else { throw PodBridgeError.trackNotFound }
        var expectedLibrary = library
        expectedLibrary.playlists[playlistIndex].trackIDs = trackIDs
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionReplacingMembers(
                    existing,
                    range: section.range,
                    playlistIndex: playlistIndex,
                    trackIDs: trackIDs
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified == expectedLibrary,
              diagnostics.primaryPlaylistFound,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return EditResult(data: signed, library: verified)
    }

    /// Adds or replaces artwork references for selected tracks.

    private static func playlistSectionRenaming(
        _ data: Data,
        range: Range<Int>,
        playlistIndex: Int,
        name: String
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var userIndex = 0
        var renamed = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            if try record.littleUInt32(at: 20) == 0 {
                if userIndex == playlistIndex {
                    output.append(try playlistRecordRenaming(record, name: name))
                    renamed = true
                } else {
                    output.append(record)
                }
                userIndex += 1
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, renamed else { throw PodBridgeError.playlistNotFound }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func playlistSectionRemovingPlaylist(
        _ data: Data,
        range: Range<Int>,
        playlistIndex: Int
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var userIndex = 0
        var removed = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else {
                throw PodBridgeError.invalidDatabase
            }
            let isPrimary = try source.littleUInt32(at: cursor + 20) != 0
            if !isPrimary, userIndex == playlistIndex {
                removed = true
            } else {
                output.append(source[cursor..<(cursor + length)])
            }
            if !isPrimary { userIndex += 1 }
            cursor += length
        }
        guard cursor == source.count, removed else { throw PodBridgeError.playlistNotFound }
        let oldCount = try source.littleUInt32(at: listOffset + 8)
        guard oldCount > 1 else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldCount - 1, at: listOffset + 8)
        return output
    }

    private static func playlistSectionReplacingMembers(
        _ data: Data,
        range: Range<Int>,
        playlistIndex: Int,
        trackIDs: [UInt32]
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var userIndex = 0
        var replaced = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            if try record.littleUInt32(at: 20) == 0 {
                if userIndex == playlistIndex {
                    output.append(try playlistRecordReplacingMembers(record, trackIDs: trackIDs))
                    replaced = true
                } else {
                    output.append(record)
                }
                userIndex += 1
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, replaced else { throw PodBridgeError.playlistNotFound }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func playlistRecordReplacingMembers(_ source: Data, trackIDs: [UInt32]) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        guard header >= 24, header <= source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        var cursor = header
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if source.ascii(at: cursor, length: 4) != "mhip" {
                output.append(source[cursor..<(cursor + length)])
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        for (index, trackID) in trackIDs.enumerated() {
            output.append(playlistItem(order: index, trackID: trackID))
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(UInt32(trackIDs.count), at: 16)
        return output
    }

    private static func playlistRecordRenaming(_ source: Data, name: String) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        var output = Data(source.prefix(header))
        var cursor = header
        var replaced = false
        var childCount = try source.littleUInt32(at: 12)
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if !replaced,
               child.ascii(at: 0, length: 4) == "mhod",
               try child.littleUInt32(at: 12) == 1 {
                output.append(stringObject(type: 1, value: name))
                replaced = true
            } else {
                output.append(child)
            }
            cursor += length
        }
        if !replaced {
            output.append(stringObject(type: 1, value: name))
            childCount += 1
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(childCount, at: 12)
        return output
    }
}
