// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    static func playlistSectionResorting(_ data: Data, range: Range<Int>, tracks: [ClassicTrack]) throws -> Data {
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
            if try record.littleUInt32(at: 20) != 0 {
                guard !primaryFound else { throw PodBridgeError.invalidDatabase }
                output.append(try primaryPlaylistRecordResorting(record, tracks: tracks))
                primaryFound = true
            } else {
                output.append(record)
            }
            cursor += length
        }
        guard cursor == source.count, primaryFound else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func primaryPlaylistRecordResorting(_ source: Data, tracks: [ClassicTrack]) throws -> Data {
        let header = Int(try source.littleUInt32(at: 4))
        var output = Data(source.prefix(header))
        var cursor = header
        var orders: [UInt32: [Int]] = [:]
        while cursor + 16 <= source.count {
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else { throw PodBridgeError.invalidDatabase }
            let child = Data(source[cursor..<(cursor + length)])
            if child.ascii(at: 0, length: 4) == "mhod", length >= 72, try child.littleUInt32(at: 12) == 52 {
                let type = try child.littleUInt32(at: 24)
                let order = try resortedOrder(child, sortType: type, tracks: tracks)
                orders[type] = order
                output.append(try updatedSortIndex(child, order: order))
            } else if child.ascii(at: 0, length: 4) == "mhod", length >= 40, try child.littleUInt32(at: 12) == 53 {
                let type = try child.littleUInt32(at: 24)
                let order = orders[type] ?? Array(tracks.indices)
                output.append(jumpTableObject(type: type, order: order, tracks: tracks) {
                    jumpValue($0, sortType: type)
                })
            } else {
                output.append(child)
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        return output
    }

    private static func resortedOrder(_ source: Data, sortType: UInt32, tracks: [ClassicTrack]) throws -> [Int] {
        let count = Int(try source.littleUInt32(at: 28))
        guard count == tracks.count, 72 + count * 4 <= source.count else { throw PodBridgeError.invalidDatabase }
        if [UInt32(3), 4, 5, 7].contains(sortType) {
            return tracks.indices.sorted {
                compareTracks(tracks[$0], tracks[$1], sortType: sortType) == .orderedAscending
            }
        }
        var order: [Int] = []
        for offset in 0..<count {
            let index = Int(try source.littleUInt32(at: 72 + offset * 4))
            guard tracks.indices.contains(index) else { throw PodBridgeError.invalidDatabase }
            order.append(index)
        }
        guard Set(order).count == tracks.count else { throw PodBridgeError.invalidDatabase }
        return order
    }

    static func compareTracks(_ lhs: ClassicTrack, _ rhs: ClassicTrack, sortType: UInt32) -> ComparisonResult {
        let lhsStrings = sortComponents(lhs, sortType: sortType)
        let rhsStrings = sortComponents(rhs, sortType: sortType)
        for (left, right) in zip(lhsStrings, rhsStrings) {
            let comparison = compareAppleStrings(left, right)
            if comparison != .orderedSame { return comparison }
        }
        if [UInt32(4), 5, 7].contains(sortType), lhs.trackNumber != rhs.trackNumber {
            return lhs.trackNumber < rhs.trackNumber ? .orderedAscending : .orderedDescending
        }
        return compareAppleStrings(effectiveTitle(lhs), effectiveTitle(rhs))
    }

    private static func sortComponents(_ track: ClassicTrack, sortType: UInt32) -> [String] {
        switch sortType {
        case 3:
            return [effectiveTitle(track)]
        case 4:
            return [effectiveAlbum(track)]
        case 5:
            return [effectiveArtist(track), effectiveAlbum(track)]
        case 7:
            return [track.genre, effectiveArtist(track), effectiveAlbum(track)]
        default:
            return []
        }
    }

    private static func effectiveTitle(_ track: ClassicTrack) -> String {
        track.sortTitle.isEmpty ? track.title : track.sortTitle
    }

    private static func effectiveAlbum(_ track: ClassicTrack) -> String {
        track.sortAlbum.isEmpty ? articleIndependentSortValue(track.album) : track.sortAlbum
    }

    private static func effectiveArtist(_ track: ClassicTrack) -> String {
        if !track.sortArtist.isEmpty { return track.sortArtist }
        return articleIndependentSortValue(track.artist)
    }

    static func albumGroupingArtist(_ track: ClassicTrack) -> String {
        track.albumArtist.isEmpty ? track.artist : track.albumArtist
    }

    static func articleIndependentSortValue(_ value: String) -> String {
        let leadingArticles = ["The ", "An ", "A "]
        for article in leadingArticles where value.range(
            of: article,
            options: [.caseInsensitive, .anchored],
            range: value.startIndex..<value.endIndex,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil {
            return String(value.dropFirst(article.count))
        }
        return value
    }

    private static func compareAppleStrings(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsCategory = appleSortCategory(lhs)
        let rhsCategory = appleSortCategory(rhs)
        if lhsCategory != rhsCategory {
            // Apple Classic order observed in the original database:
            // alphabetic buckets, then the numeric bucket, then empty/no-letter values.
            return lhsCategory < rhsCategory ? .orderedAscending : .orderedDescending
        }
        return lhs.localizedCaseInsensitiveCompare(rhs)
    }

    private static func appleSortCategory(_ value: String) -> Int {
        guard let first = firstAlphanumeric(value) else { return 2 }
        return first.isNumber ? 1 : 0
    }

    private static func firstAlphanumeric(_ value: String) -> Character? {
        value.first { $0.isLetter || $0.isNumber }
    }

    private struct JumpEntry {
        var letter: UInt16
        var reserved: UInt16
        var start: UInt32
        var count: UInt32
    }

    static func updatedJumpTable(_ source: Data, additions: [ClassicTrack], tracks: [ClassicTrack]) throws -> Data {
        let sortType = try source.littleUInt32(at: 24)
        let entryCount = Int(try source.littleUInt32(at: 28))
        guard 40 + entryCount * 12 <= source.count else { throw PodBridgeError.invalidDatabase }
        var entries = try jumpEntries(source, count: entryCount)
        if entries.isEmpty, !tracks.isEmpty {
            entries = jumpEntries(tracks: tracks, sortType: sortType)
        } else {
            mergeJumpEntries(&entries, additions: additions, sortType: sortType)
        }
        return try serializedJumpTable(source, entries: entries)
    }

    private static func jumpEntries(_ source: Data, count: Int) throws -> [JumpEntry] {
        var entries: [JumpEntry] = []
        for index in 0..<count {
            let offset = 40 + index * 12
            entries.append(JumpEntry(
                letter: try source.littleUInt16(at: offset),
                reserved: try source.littleUInt16(at: offset + 2),
                start: try source.littleUInt32(at: offset + 4),
                count: try source.littleUInt32(at: offset + 8)
            ))
        }
        return entries
    }

    private static func jumpEntries(tracks: [ClassicTrack], sortType: UInt32) -> [JumpEntry] {
        let sorted = tracks.sorted {
            jumpValue($0, sortType: sortType)
                .localizedCaseInsensitiveCompare(jumpValue($1, sortType: sortType)) == .orderedAscending
        }
        var entries: [JumpEntry] = []
        for track in sorted {
            let letter = jumpLetter(jumpValue(track, sortType: sortType))
            if let last = entries.indices.last, entries[last].letter == letter {
                entries[last].count += 1
            } else {
                entries.append(JumpEntry(letter: letter, reserved: 0, start: 0, count: 1))
            }
        }
        return entries
    }

    private static func mergeJumpEntries(
        _ entries: inout [JumpEntry],
        additions: [ClassicTrack],
        sortType: UInt32
    ) {
        for track in additions {
            let letter = jumpLetter(jumpValue(track, sortType: sortType))
            if let index = entries.firstIndex(where: { $0.letter == letter }) {
                entries[index].count += 1
            } else {
                let insertion = entries.firstIndex {
                    jumpBucketRank($0.letter) > jumpBucketRank(letter)
                } ?? entries.endIndex
                entries.insert(JumpEntry(letter: letter, reserved: 0, start: 0, count: 1), at: insertion)
            }
        }
    }

    private static func serializedJumpTable(_ source: Data, entries: [JumpEntry]) throws -> Data {
        var runningStart: UInt32 = 0
        var updated = Data(source.prefix(40))
        for var entry in entries {
            entry.start = runningStart
            var letter = entry.letter.littleEndian
            var reserved = entry.reserved.littleEndian
            var start = entry.start.littleEndian
            var count = entry.count.littleEndian
            withUnsafeBytes(of: &letter) { updated.append(contentsOf: $0) }
            withUnsafeBytes(of: &reserved) { updated.append(contentsOf: $0) }
            withUnsafeBytes(of: &start) { updated.append(contentsOf: $0) }
            withUnsafeBytes(of: &count) { updated.append(contentsOf: $0) }
            runningStart += entry.count
        }
        try updated.setLittleUInt32(UInt32(updated.count), at: 8)
        try updated.setLittleUInt32(UInt32(entries.count), at: 28)
        return updated
    }

    private static func jumpBucketRank(_ letter: UInt16) -> Int {
        if letter >= 65, letter <= 90 { return Int(letter - 65) }
        if letter == 48 { return 26 }
        return 27
    }

    static func jumpValue(_ track: ClassicTrack, sortType: UInt32) -> String {
        switch sortType {
        case 3: effectiveTitle(track)
        case 4: effectiveAlbum(track)
        case 5: effectiveArtist(track)
        case 7: track.genre
        case 18: ""
        default: ""
        }
    }

    static func jumpLetter(_ value: String) -> UInt16 {
        guard let character = firstAlphanumeric(value),
              let scalar = String(character).uppercased().unicodeScalars.first else { return 0 }
        if character.isNumber { return 48 }
        if scalar.value >= 65, scalar.value <= 90 { return UInt16(scalar.value) }
        // The Apple-generated database groups Cyrillic/non-Latin alphabetic
        // values before Latin A while exposing only A-Z/0 jump buckets.
        return 65
    }
}
