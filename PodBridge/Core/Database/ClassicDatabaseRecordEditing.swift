// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    private struct EntityEditPlan {
        let listTag: String
        let recordTag: String
        let oldID: UInt32
        let newID: UInt32
        let oldStillUsed: Bool
        let newRecord: Data
    }

    struct EntityMergePlan {
        let listTag: String
        let recordTag: String
        let targetID: UInt32
        let orphanedIDs: Set<UInt32>
        let replacement: Data
    }

    static func trackSectionEditing(_ data: Data, range: Range<Int>, track: ClassicTrack) throws -> Data {
        try trackSectionEditing(data, range: range, tracksByID: [track.id: track])
    }

    static func trackSectionEditing(
        _ data: Data,
        range: Range<Int>,
        tracksByID: [UInt32: ClassicTrack]
    ) throws -> Data {
        let source = Data(data[range])
        let sectionHeader = Int(try source.littleUInt32(at: 4))
        let listOffset = sectionHeader
        guard source.ascii(at: listOffset, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var edited = Set<UInt32>()
        while cursor + 16 <= source.count, source.ascii(at: cursor, length: 4) == "mhit" {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let record = Data(source[cursor..<(cursor + length)])
            let trackID = try record.littleUInt32(at: 0x10)
            if let track = tracksByID[trackID] {
                output.append(try trackRecordEditing(record, track: track))
                edited.insert(trackID)
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, edited == Set(tracksByID.keys) else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func trackRecordEditing(_ source: Data, track: ClassicTrack) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        guard header >= 0x1e4, header <= source.count else { throw PodBridgeError.invalidDatabase }
        var output = Data(source.prefix(header))
        try output.setLittleUInt32(track.trackNumber, at: 0x2c)
        try output.setLittleUInt32(track.year, at: 0x34)
        try output.setLittleUInt32(track.albumID, at: 0x120)
        try output.setLittleUInt32(track.artistID, at: 0x1e0)
        output[0x1e] = track.compilation ? 1 : 0
        if track.artworkImageID != 0 {
            try output.setLittleUInt16(1, at: 0x7c)
            try output.setLittleUInt32(track.artworkByteCount, at: 0x80)
            output[0xa4] = 1
            try output.setLittleUInt32(track.artworkImageID, at: 0x160)
        }
        let desired = editableStrings(for: track)
        var handled = Set<UInt32>()
        var childCount: UInt32 = 0
        var cursor = header
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod",
               let type = try? child.littleUInt32(at: 12),
               let value = desired[type] {
                if handled.insert(type).inserted, !value.isEmpty {
                    output.append(stringObject(type: type, value: value))
                    childCount += 1
                }
            } else {
                output.append(child)
                childCount += 1
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        for type in desired.keys.sorted() where !handled.contains(type) {
            if let value = desired[type], !value.isEmpty {
                output.append(stringObject(type: type, value: value))
                childCount += 1
            }
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(childCount, at: 12)
        return output
    }

    private static func editableStrings(for track: ClassicTrack) -> [UInt32: String] {
        [
            1: track.title,
            4: track.artist,
            3: track.album,
            5: track.genre,
            27: track.sortTitle,
            23: track.sortArtist,
            28: track.sortAlbum,
            29: track.sortAlbumArtist,
            22: track.albumArtist
        ]
    }

    static func albumSectionEditing(
        _ data: Data,
        range: Range<Int>,
        originalTrack: ClassicTrack,
        updatedTrack: ClassicTrack,
        allTracks: [ClassicTrack]
    ) throws -> Data {
        try entitySectionEditing(
            data,
            range: range,
            plan: EntityEditPlan(
                listTag: "mhla",
                recordTag: "mhia",
                oldID: originalTrack.albumID,
                newID: updatedTrack.albumID,
                oldStillUsed: allTracks.contains {
                    $0.id != updatedTrack.id && $0.albumID == originalTrack.albumID
                },
                newRecord: albumRecord(updatedTrack)
            )
        )
    }

    static func artistSectionEditing(
        _ data: Data,
        range: Range<Int>,
        originalTrack: ClassicTrack,
        updatedTrack: ClassicTrack,
        allTracks: [ClassicTrack]
    ) throws -> Data {
        try entitySectionEditing(
            data,
            range: range,
            plan: EntityEditPlan(
                listTag: "mhli",
                recordTag: "mhii",
                oldID: originalTrack.artistID,
                newID: updatedTrack.artistID,
                oldStillUsed: allTracks.contains {
                    $0.id != updatedTrack.id && $0.artistID == originalTrack.artistID
                },
                newRecord: artistRecord(updatedTrack)
            )
        )
    }

    private static func entitySectionEditing(
        _ data: Data,
        range: Range<Int>,
        plan: EntityEditPlan
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == plan.listTag else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var count: UInt32 = 0
        var newFound = false
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == plan.recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let id = try source.littleUInt32(at: cursor + 16)
            if id == plan.oldID, plan.oldID != plan.newID, !plan.oldStillUsed {
                // Drop the entity that became orphaned after the edit.
            } else {
                output.append(source[cursor..<(cursor + length)])
                count += 1
                if id == plan.newID { newFound = true }
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        if !newFound {
            output.append(plan.newRecord)
            count += 1
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(count, at: listOffset + 8)
        return output
    }

    static func entitySectionMergingRecords(
        _ data: Data,
        range: Range<Int>,
        plan: EntityMergePlan
    ) throws -> Data {
        let source = Data(data[range])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == plan.listTag else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var output = Data(source.prefix(cursor))
        var insertedReplacement = false
        var outputCount: UInt32 = 0
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == plan.recordTag {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else {
                throw PodBridgeError.invalidDatabase
            }
            let id = try source.littleUInt32(at: cursor + 16)
            if id == plan.targetID {
                if !insertedReplacement {
                    output.append(plan.replacement)
                    outputCount += 1
                    insertedReplacement = true
                }
            } else if plan.orphanedIDs.contains(id) {
                // Every track that used this duplicate ID now points at targetID, so the
                // obsolete entity must not remain as a ghost album or artist card.
            } else {
                output.append(source[cursor..<(cursor + length)])
                outputCount += 1
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        if !insertedReplacement {
            output.append(plan.replacement)
            outputCount += 1
        }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(outputCount, at: listOffset + 8)
        return output
    }
}
