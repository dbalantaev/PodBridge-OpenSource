// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    private struct PlayCountsLayout {
        let headerLength: Int
        let entryLength: Int
        let entryCount: Int
    }

    /// Applies the device-side deltas stored in `iPod_Control/iTunes/Play Counts`
    /// to the corresponding track records. Play Counts entries are positional,
    /// so existing track order must not be changed before this is called.
    static func applyingPlayCounts(
        _ playCounts: Data,
        to existing: Data,
        firewireID: Data
    ) throws -> Data {
        let layout = try playCountsLayout(playCounts)
        let rootHeader = Int(try existing.littleUInt32(at: 4))
        let sections = try topLevelSections(existing, start: rootHeader)
        guard let trackSection = sections.first(where: { $0.type == 1 })?.range else {
            throw PodBridgeError.invalidDatabase
        }

        let updated = try applyingPlayCountEntries(
            playCounts,
            layout: layout,
            to: existing,
            trackSection: trackSection
        )
        return try Hash58.sign(updated, firewireID: firewireID)
    }

    private static func playCountsLayout(_ playCounts: Data) throws -> PlayCountsLayout {
        guard playCounts.count >= 0x60,
              playCounts.ascii(at: 0, length: 4) == "mhdp" else {
            throw PodBridgeError.invalidDatabase
        }
        let layout = PlayCountsLayout(
            headerLength: Int(try playCounts.littleUInt32(at: 4)),
            entryLength: Int(try playCounts.littleUInt32(at: 8)),
            entryCount: Int(try playCounts.littleUInt32(at: 12))
        )
        guard layout.headerLength >= 0x60,
              layout.entryLength >= 0x0c,
              layout.headerLength <= playCounts.count,
              layout.entryCount <= (playCounts.count - layout.headerLength) / layout.entryLength else {
            throw PodBridgeError.invalidDatabase
        }
        return layout
    }

    private static func applyingPlayCountEntries(
        _ playCounts: Data,
        layout: PlayCountsLayout,
        to existing: Data,
        trackSection: Range<Int>
    ) throws -> Data {
        var output = existing
        let sectionHeader = Int(try output.littleUInt32(at: trackSection.lowerBound + 4))
        let listOffset = trackSection.lowerBound + sectionHeader
        guard output.ascii(at: listOffset, length: 4) == "mhlt" else {
            throw PodBridgeError.invalidDatabase
        }

        var trackOffset = listOffset + Int(try output.littleUInt32(at: listOffset + 4))
        for index in 0..<layout.entryCount {
            guard trackOffset + 16 <= trackSection.upperBound,
                  output.ascii(at: trackOffset, length: 4) == "mhit" else {
                throw PodBridgeError.invalidDatabase
            }
            let trackLength = try applyPlayCountEntry(
                playCounts,
                layout: layout,
                index: index,
                trackOffset: trackOffset,
                output: &output
            )
            guard trackOffset + trackLength <= trackSection.upperBound else {
                throw PodBridgeError.invalidDatabase
            }
            trackOffset += trackLength
        }
        return output
    }

    private static func applyPlayCountEntry(
        _ playCounts: Data,
        layout: PlayCountsLayout,
        index: Int,
        trackOffset: Int,
        output: inout Data
    ) throws -> Int {
        let trackHeader = Int(try output.littleUInt32(at: trackOffset + 4))
        let trackLength = Int(try output.littleUInt32(at: trackOffset + 8))
        guard trackHeader >= 0x9c, trackLength >= trackHeader else {
            throw PodBridgeError.invalidDatabase
        }
        let entryOffset = layout.headerLength + index * layout.entryLength
        try applyPlaybackFields(
            playCounts,
            entryOffset: entryOffset,
            trackOffset: trackOffset,
            trackHeader: trackHeader,
            output: &output
        )
        if layout.entryLength >= 0x10 {
            try applyRating(playCounts, entryOffset: entryOffset, trackOffset: trackOffset, output: &output)
        }
        if layout.entryLength >= 0x1c, trackHeader >= 0xf4 {
            try applySkipFields(playCounts, entryOffset: entryOffset, trackOffset: trackOffset, output: &output)
        }
        return trackLength
    }

    private static func applyPlaybackFields(
        _ playCounts: Data,
        entryOffset: Int,
        trackOffset: Int,
        trackHeader: Int,
        output: inout Data
    ) throws {
        let recentPlayCount = try playCounts.littleUInt32(at: entryOffset)
        if recentPlayCount != 0 {
            let stored = try output.littleUInt32(at: trackOffset + 0x50)
            try output.setLittleUInt32(stored &+ recentPlayCount, at: trackOffset + 0x50)
            if trackHeader > 0xb2 { output[trackOffset + 0xb2] = 1 }
        }
        let lastPlayed = try playCounts.littleUInt32(at: entryOffset + 4)
        if lastPlayed != 0 {
            try output.setLittleUInt32(lastPlayed, at: trackOffset + 0x58)
        }
        let bookmark = try playCounts.littleUInt32(at: entryOffset + 8)
        if bookmark != 0 {
            try output.setLittleUInt32(bookmark, at: trackOffset + 0x6c)
        }
    }

    private static func applyRating(
        _ playCounts: Data,
        entryOffset: Int,
        trackOffset: Int,
        output: inout Data
    ) throws {
        let deviceRating = try playCounts.littleUInt32(at: entryOffset + 12)
        guard deviceRating <= 100 else { return }
        let oldRating = output[trackOffset + 0x1f]
        let newRating = UInt8(deviceRating)
        guard oldRating != newRating else { return }
        output[trackOffset + 0x79] = oldRating
        output[trackOffset + 0x1f] = newRating
    }

    private static func applySkipFields(
        _ playCounts: Data,
        entryOffset: Int,
        trackOffset: Int,
        output: inout Data
    ) throws {
        let recentSkipCount = try playCounts.littleUInt32(at: entryOffset + 20)
        if recentSkipCount != 0 {
            let stored = try output.littleUInt32(at: trackOffset + 0x9c)
            try output.setLittleUInt32(stored &+ recentSkipCount, at: trackOffset + 0x9c)
        }
        let lastSkipped = try playCounts.littleUInt32(at: entryOffset + 24)
        if lastSkipped != 0 {
            try output.setLittleUInt32(lastSkipped, at: trackOffset + 0xa0)
        }
    }
}
