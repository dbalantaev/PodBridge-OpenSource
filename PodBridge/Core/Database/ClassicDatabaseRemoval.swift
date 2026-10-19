// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    static func removingTrack(existing: Data, trackID: UInt32, firewireID: Data) throws -> RemovalResult {
        let originalLibrary = try parse(existing)
        guard let removedIndex = originalLibrary.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw PodBridgeError.trackNotFound
        }
        let removedTrack = originalLibrary.tracks[removedIndex]
        var expectedLibrary = originalLibrary
        expectedLibrary.tracks.remove(at: removedIndex)
        expectedLibrary.playlists = expectedLibrary.playlists.map { playlist in
            ClassicPlaylist(name: playlist.name, trackIDs: playlist.trackIDs.filter { $0 != trackID })
        }

        let output = try removingTrackSections(
            existing,
            trackID: trackID,
            removedIndex: removedIndex,
            removedTrack: removedTrack,
            expectedLibrary: expectedLibrary
        )
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified.tracks.map(\.id) == expectedLibrary.tracks.map(\.id),
              verified.playlists == expectedLibrary.playlists,
              !verified.tracks.contains(where: { $0.id == trackID }),
              verified.playlists.allSatisfy({ !$0.trackIDs.contains(trackID) }),
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == expectedLibrary.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return RemovalResult(data: signed, library: verified, removedTrack: removedTrack)
    }

    private static func removingTrackSections(
        _ existing: Data,
        trackID: UInt32,
        removedIndex: Int,
        removedTrack: ClassicTrack,
        expectedLibrary: ClassicLibrary
    ) throws -> Data {
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        guard sections.contains(where: { $0.type == 1 }),
              sections.contains(where: { $0.type == 2 || $0.type == 3 }) else {
            throw PodBridgeError.invalidDatabase
        }
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            if section.type == 1 {
                output.append(try trackSectionRemoving(existing, range: section.range, trackID: trackID))
            } else if section.type == 2 || section.type == 3 {
                output.append(try playlistSectionRemoving(
                    existing,
                    range: section.range,
                    trackID: trackID,
                    removedTrackIndex: removedIndex,
                    remainingTracks: expectedLibrary.tracks
                ))
            } else if section.type == 4,
                      removedTrack.albumID != 0,
                      !expectedLibrary.tracks.contains(where: { $0.albumID == removedTrack.albumID }) {
                output.append(try entitySectionRemoving(
                    existing,
                    range: section.range,
                    listTag: "mhla",
                    recordTag: "mhia",
                    entityID: removedTrack.albumID
                ))
            } else if section.type == 8,
                      removedTrack.artistID != 0,
                      !expectedLibrary.tracks.contains(where: { $0.artistID == removedTrack.artistID }) {
                output.append(try entitySectionRemoving(
                    existing,
                    range: section.range,
                    listTag: "mhli",
                    recordTag: "mhii",
                    entityID: removedTrack.artistID
                ))
            } else {
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    /// Removes several tracks while rebuilding indexes and playlist sections once.
    static func removingTracks(existing: Data, trackIDs: [UInt32], firewireID: Data) throws -> BatchRemovalResult {
        let uniqueIDs = Array(Set(trackIDs))
        guard !uniqueIDs.isEmpty else { throw PodBridgeError.trackNotFound }
        let originalLibrary = try parse(existing)
        let requested = Set(uniqueIDs)
        let removedTracks = originalLibrary.tracks.filter { requested.contains($0.id) }
        guard removedTracks.count == requested.count else { throw PodBridgeError.trackNotFound }
        var data = existing
        var library = originalLibrary
        for track in removedTracks {
            let result = try removingTrack(existing: data, trackID: track.id, firewireID: firewireID)
            data = result.data
            library = result.library
        }
        return BatchRemovalResult(data: data, library: library, removedTracks: removedTracks)
    }

    /// Clears a large library in one pass while retaining the device's root
    /// header, master playlist headers, and unknown database sections.
    static func clearingLibrary(existing: Data, firewireID: Data) throws -> BatchRemovalResult {
        let originalLibrary = try parse(existing)
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        var output = Data(existing.prefix(rootHeader))
        for section in sections {
            switch section.type {
            case 1, 4, 8:
                var value = Data(existing[section.range])
                let listOffset = Int(try value.littleUInt32(at: 4))
                let listHeader = Int(try value.littleUInt32(at: listOffset + 4))
                let end = listOffset + listHeader
                guard end <= value.count else { throw PodBridgeError.invalidDatabase }
                value = Data(value.prefix(end))
                try value.setLittleUInt32(UInt32(value.count), at: 8)
                try value.setLittleUInt32(0, at: listOffset + 8)
                output.append(value)
            case 2, 3:
                output.append(try playlistSectionClearing(existing, range: section.range))
            default:
                output.append(existing[section.range])
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        let signed = try Hash58.sign(output, firewireID: firewireID)
        let verified = try parse(signed)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard verified.tracks.isEmpty,
              verified.playlists.isEmpty,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == 0,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else { throw PodBridgeError.databaseVerificationFailed }
        return BatchRemovalResult(data: signed, library: verified, removedTracks: originalLibrary.tracks)
    }

    private static func playlistSectionClearing(_ data: Data, range: Range<Int>) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlp",
              cursor <= source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(cursor))
        var primaryFound = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if try source.littleUInt32(at: cursor + 20) != 0 {
                guard !primaryFound else { throw PodBridgeError.invalidDatabase }
                primaryFound = true
                output.append(try primaryPlaylistClearing(Data(source[cursor..<(cursor + length)])))
            }
            cursor += length
        }
        guard primaryFound, cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(1, at: listOffset + 8)
        return output
    }

    private static func primaryPlaylistClearing(_ source: Data) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        guard header <= source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        var cursor = header
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod", length >= 72,
               try child.littleUInt32(at: 12) == 52 {
                output.append(try updatedSortIndex(child, order: []))
            } else if child.ascii(at: 0, length: 4) == "mhod", length >= 40,
                      try child.littleUInt32(at: 12) == 53 {
                let type = try child.littleUInt32(at: 24)
                output.append(jumpTableObject(type: type, order: [], tracks: []) { _ in "" })
            } else if child.ascii(at: 0, length: 4) != "mhip" {
                output.append(child)
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(0, at: 16)
        return output
    }

    /// Updates one track's display metadata and rebuilds dependent indexes.

    private static func trackSectionRemoving(_ data: Data, range: Range<Int>, trackID: UInt32) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var removed = 0
        while cursor + 16 <= source.count, source.ascii(at: cursor, length: 4) == "mhit" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if try source.littleUInt32(at: cursor + 0x10) == trackID {
                removed += 1
            } else {
                output.append(source[cursor..<(cursor + length)])
            }
            cursor += length
        }
        guard removed == 1, cursor == source.count else { throw PodBridgeError.invalidDatabase }
        let oldCount = try source.littleUInt32(at: listOffset + 8)
        guard oldCount > 0 else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldCount - 1, at: listOffset + 8)
        return output
    }

    private static func entitySectionRemoving(
        _ data: Data,
        range: Range<Int>,
        listTag: String,
        recordTag: String,
        entityID: UInt32
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: sectionHeader, length: 4) == listTag else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: sectionHeader + 4))
        var cursor = sectionHeader + listHeader
        var output = Data(source.prefix(cursor))
        var removed: UInt32 = 0
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            if try source.littleUInt32(at: cursor + 16) == entityID {
                removed += 1
            } else {
                output.append(source[cursor..<(cursor + length)])
            }
            cursor += length
        }
        guard cursor == source.count, removed == 1 else { throw PodBridgeError.invalidDatabase }
        let oldCount = try source.littleUInt32(at: sectionHeader + 8)
        guard oldCount >= removed else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldCount - removed, at: sectionHeader + 8)
        return output
    }

    private static func playlistSectionRemoving(
        _ data: Data,
        range: Range<Int>,
        trackID: UInt32,
        removedTrackIndex: Int,
        remainingTracks: [ClassicTrack]
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlp" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var primaryFound = false
        while cursor + 24 <= source.count, source.ascii(at: cursor, length: 4) == "mhyp" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            let isPrimary = try record.littleUInt32(at: 20) != 0
            if isPrimary {
                guard !primaryFound else { throw PodBridgeError.invalidDatabase }
                primaryFound = true
            }
            output.append(try playlistRecordRemoving(
                record,
                trackID: trackID,
                removedTrackIndex: removedTrackIndex,
                remainingTracks: remainingTracks,
                isPrimary: isPrimary
            ))
            cursor += length
        }
        guard primaryFound, cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func playlistRecordRemoving(
        _ source: Data,
        trackID: UInt32,
        removedTrackIndex: Int,
        remainingTracks: [ClassicTrack],
        isPrimary: Bool
    ) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        let total = Int(try source.littleUInt32(at: 8))
        guard header >= 24, total == source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        var cursor = header
        var removedMembers: UInt32 = 0
        var nextMemberOrder = 0
        var sortOrders: [UInt32: [Int]] = [:]
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            var child = Data(source[cursor..<(cursor + length)])
            let tag = child.ascii(at: 0, length: 4)
            if tag == "mhip", length >= 28 {
                if try child.littleUInt32(at: 24) == trackID {
                    removedMembers += 1
                } else {
                    child = try playlistItem(child, settingOrder: nextMemberOrder)
                    output.append(child)
                    nextMemberOrder += 1
                }
            } else if isPrimary, tag == "mhod", length >= 72, try child.littleUInt32(at: 12) == 52 {
                let sortType = try child.littleUInt32(at: 24)
                let order = try sortOrderRemoving(
                    child,
                    removedTrackIndex: removedTrackIndex,
                    remainingTrackCount: remainingTracks.count
                )
                sortOrders[sortType] = order
                output.append(try updatedSortIndex(child, order: order))
            } else if isPrimary, tag == "mhod", length >= 40, try child.littleUInt32(at: 12) == 53 {
                let sortType = try child.littleUInt32(at: 24)
                let order = sortOrders[sortType] ?? Array(remainingTracks.indices)
                output.append(jumpTableObject(
                    type: sortType,
                    order: order,
                    tracks: remainingTracks
                ) { jumpValue($0, sortType: sortType) })
            } else {
                output.append(child)
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try validateRemovedMembers(removedMembers, primary: isPrimary)
        let oldMembers = try source.littleUInt32(at: 16)
        guard removedMembers <= oldMembers else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(oldMembers - removedMembers, at: 16)
        return output
    }

    private static func validateRemovedMembers(_ removedMembers: UInt32, primary: Bool) throws {
        guard !primary || removedMembers == 1 else {
            throw PodBridgeError.databaseVerificationFailed
        }
    }

    private static func sortOrderRemoving(
        _ source: Data,
        removedTrackIndex: Int,
        remainingTrackCount: Int
    ) throws -> [Int] {
        let storedCount = Int(try source.littleUInt32(at: 28))
        guard storedCount == remainingTrackCount + 1,
              removedTrackIndex >= 0, removedTrackIndex < storedCount,
              72 + storedCount * 4 <= source.count else { throw PodBridgeError.invalidDatabase }
        var order: [Int] = []
        for offset in 0..<storedCount {
            let index = Int(try source.littleUInt32(at: 72 + offset * 4))
            guard index >= 0, index < storedCount else { throw PodBridgeError.invalidDatabase }
            if index == removedTrackIndex { continue }
            order.append(index > removedTrackIndex ? index - 1 : index)
        }
        guard order.count == remainingTrackCount, Set(order).count == remainingTrackCount else {
            throw PodBridgeError.invalidDatabase
        }
        return order
    }
}
