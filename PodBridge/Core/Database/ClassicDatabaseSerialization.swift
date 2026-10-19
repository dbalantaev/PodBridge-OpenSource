// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    private struct JumpTableGroup {
        let letter: UInt16
        let start: UInt32
        var count: UInt32
    }

    static func trackSection(_ tracks: [ClassicTrack], rootLibraryID: UInt64) -> Data {
        var body = BinaryWriter()
        body.tag("mhlt"); body.u32(92); body.u32(UInt32(tracks.count)); body.zeros(80)
        for track in tracks { body.bytes(trackRecord(track, rootLibraryID: rootLibraryID)) }
        return section(type: 1, body: body.data)
    }

    static func trackRecord(_ track: ClassicTrack, rootLibraryID: UInt64) -> Data {
        var writer = BinaryWriter()
        // Build a clean libgpod-compatible header. Copying the first old track's
        // header leaked MP3 flags into AAC tracks when the first library item was MP3.
        writer.tag("mhit"); writer.u32(0x248); writer.u32(0); writer.u32(0)
        writer.zeros(0x248 - 16)
        writer.patchU32(track.id, at: 0x10)
        writer.patchU32(1, at: 0x14)
        let format = trackFormat(track)
        writer.patchBytes(Data(format.marker.utf8), at: 0x18)
        writer.patchBytes(Data([format.type1, format.type2, track.compilation ? 1 : 0, 0]), at: 0x1c)
        writer.patchBytes(Data([track.rating]), at: 0x1f)
        writer.patchU32(track.dateAdded, at: 0x20)
        writer.patchU32(track.byteCount, at: 0x24)
        writer.patchU32(track.durationMS, at: 0x28)
        writer.patchU32(track.trackNumber, at: 0x2c)
        writer.patchU32(0, at: 0x30)
        writer.patchU32(track.year, at: 0x34)
        writer.patchU32(track.bitrate, at: 0x38)
        writer.patchU32(track.sampleRate << 16, at: 0x3c)
        writer.patchU32(track.playCount, at: 0x50)
        writer.patchU32(track.lastPlayed, at: 0x58)
        writer.patchU32(track.dateAdded, at: 0x68)
        var dbid = BinaryWriter(); dbid.u64(track.databaseID)
        writer.patchBytes(dbid.data, at: 0x70)
        writer.patchU16(format.compressed ? 0xffff : 0, at: 0x7e)
        writer.patchU32(Float(track.sampleRate).bitPattern, at: 0x88)
        writer.patchU16(format.unknown144, at: 0x90)
        writer.patchU32(track.skipCount, at: 0x9c)
        writer.patchU32(track.lastSkipped, at: 0xa0)
        writer.patchBytes(Data([track.artworkImageID == 0 ? 2 : 1, 0, 0, 0]), at: 0xa4)
        writer.patchBytes(dbid.data, at: 0xa8)
        writer.patchBytes(Data([0, 0, 2, 0]), at: 0xb0)
        writer.patchU32(1, at: 0xd0)
        writer.patchU32(track.albumID, at: 0x120)
        var rootID = BinaryWriter(); rootID.u64(rootLibraryID)
        writer.patchBytes(rootID.data, at: 0x124)
        // iTunesDB stores the file size twice. This used to be written four bytes
        // late at 0x130, leaving the firmware-facing copy at 0x12c as zero.
        writer.patchU32(track.byteCount, at: 0x12c)
        writer.patchU32(0, at: 0x130)
        var magic = BinaryWriter(); magic.u64(0x0000_8080_8080_8080)
        writer.patchBytes(magic.data, at: 0x134)
        writer.patchU32(1, at: 0x168)
        writer.patchU32(track.artistID, at: 0x1e0)
        if track.artworkImageID != 0 {
            writer.patchU16(1, at: 0x7c)
            writer.patchU32(track.artworkByteCount, at: 0x80)
            writer.patchU32(track.artworkImageID, at: 0x160)
        }
        let strings = trackStrings(track)
        for item in strings { writer.bytes(stringObject(type: item.0, value: item.1)) }
        writer.patchU32(UInt32(writer.count), at: 8)
        writer.patchU32(UInt32(strings.count), at: 12)
        return writer.data
    }

    private static func trackStrings(_ track: ClassicTrack) -> [(UInt32, String)] {
        [
            (1, track.title), (4, track.artist), (3, track.album), (5, track.genre),
            (6, track.fileType), (2, track.ipodPath), (27, track.sortTitle),
            (23, track.sortArtist), (28, track.sortAlbum), (29, track.sortAlbumArtist),
            (22, track.albumArtist)
        ].filter { !$0.1.isEmpty }
    }

    struct TrackFormat {
        let marker: String
        let type1: UInt8
        let type2: UInt8
        let compressed: Bool
        let unknown144: UInt16
    }

    static func trackFormat(_ track: ClassicTrack) -> TrackFormat {
        let ext = track.ipodPath.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        let upper = String(ext.uppercased().prefix(4)).padding(toLength: 4, withPad: " ", startingAt: 0)
        let marker = String(upper.reversed())
        let description = track.fileType.lowercased()
        if ext == "mp3" {
            return TrackFormat(marker: marker, type1: 0, type2: 1, compressed: true, unknown144: 0x000c)
        }
        if description.contains("lossless") {
            return TrackFormat(marker: marker, type1: 0, type2: 0, compressed: true, unknown144: 0x003c)
        }
        if ["m4a", "m4b", "aac"].contains(ext) {
            return TrackFormat(marker: marker, type1: 1, type2: 0, compressed: true, unknown144: 0x0033)
        }
        return TrackFormat(marker: marker, type1: 0, type2: 0, compressed: false, unknown144: 0)
    }

    static func playlistSection(_ library: ClassicLibrary, type: UInt32) -> Data {
        var list = BinaryWriter()
        list.tag("mhlp"); list.u32(92); list.u32(UInt32(library.playlists.count + 1)); list.zeros(80)
        list.bytes(playlistRecord(
            name: library.name,
            ids: library.tracks.map(\.id),
            primary: true,
            tracks: library.tracks
        ))
        for playlist in library.playlists {
            list.bytes(playlistRecord(name: playlist.name, ids: playlist.trackIDs, primary: false, tracks: []))
        }
        return section(type: type, body: list.data)
    }

    static func albumSection(_ tracks: [ClassicTrack]) -> Data {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert("\(albumGroupingArtist($0))\u{0}\($0.album)").inserted }
        var list = BinaryWriter()
        list.tag("mhla"); list.u32(92); list.u32(UInt32(unique.count)); list.zeros(80)
        unique.forEach { list.bytes(albumRecord($0)) }
        return section(type: 4, body: list.data)
    }

    static func artistSection(_ tracks: [ClassicTrack]) -> Data {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.artist).inserted }
        var list = BinaryWriter()
        list.tag("mhli"); list.u32(92); list.u32(UInt32(unique.count)); list.zeros(80)
        unique.forEach { list.bytes(artistRecord($0)) }
        return section(type: 8, body: list.data)
    }

    static func playlistRecord(name: String, ids: [UInt32], primary: Bool, tracks: [ClassicTrack]) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhyp"); writer.u32(108); writer.u32(0); writer.u32(0)
        writer.u32(UInt32(ids.count)); writer.u32(primary ? 1 : 0); writer.u32(AudioMetadataReader.macTime(Date()))
        writer.u64(UInt64.random(in: 1...UInt64.max)); writer.u32(0); writer.u16(1); writer.u16(0)
        writer.u32(primary ? 10 : 1); writer.zeros(60)
        var children = 0
        writer.bytes(stringObject(type: 1, value: name)); children += 1
        if primary {
            let indexTypes: [UInt32] = [3, 4, 5, 7, 18]
            for type in indexTypes {
                let order = type == 18
                    ? Array(tracks.indices)
                    : tracks.indices.sorted {
                        compareTracks(tracks[$0], tracks[$1], sortType: type) == .orderedAscending
                    }
                writer.bytes(indexObject(type: type, order: order)); children += 1
                writer.bytes(jumpTableObject(
                    type: type,
                    order: order,
                    tracks: tracks
                ) { jumpValue($0, sortType: type) })
                children += 1
            }
        }
        for (offset, id) in ids.enumerated() { writer.bytes(playlistItem(order: offset, trackID: id)) }
        writer.patchU32(UInt32(writer.count), at: 8)
        writer.patchU32(UInt32(children), at: 12)
        return writer.data
    }

    static func playlistItem(order: Int, trackID: UInt32) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhip"); writer.u32(76); writer.u32(120); writer.u32(1)
        writer.u32(0); writer.u32(0); writer.u32(trackID)
        writer.u32(0); writer.u32(0); writer.zeros(40)
        writer.tag("mhod"); writer.u32(24); writer.u32(44); writer.u32(100); writer.zeros(8)
        writer.u32(UInt32(order)); writer.zeros(16)
        return writer.data
    }

    private static func indexObject(type: UInt32, order: [Int]) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhod"); writer.u32(24); writer.u32(UInt32(72 + order.count * 4)); writer.u32(52); writer.zeros(8)
        writer.u32(type); writer.u32(UInt32(order.count)); writer.zeros(40)
        for index in order { writer.u32(UInt32(index)) }
        return writer.data
    }

    static func jumpTableObject(
        type: UInt32,
        order: [Int],
        tracks: [ClassicTrack],
        key: (ClassicTrack) -> String
    ) -> Data {
        var groups: [JumpTableGroup] = []
        for (position, trackIndex) in order.enumerated() {
            let letter = jumpLetter(key(tracks[trackIndex]))
            if let last = groups.indices.last, groups[last].letter == letter {
                groups[last].count += 1
            } else {
                groups.append(JumpTableGroup(letter: letter, start: UInt32(position), count: 1))
            }
        }
        var writer = BinaryWriter()
        writer.tag("mhod"); writer.u32(24); writer.u32(UInt32(40 + groups.count * 12)); writer.u32(53); writer.zeros(8)
        writer.u32(type); writer.u32(UInt32(groups.count)); writer.zeros(8)
        for group in groups {
            writer.u16(group.letter); writer.u16(0); writer.u32(group.start); writer.u32(group.count)
        }
        return writer.data
    }

    static func albumRecord(_ track: ClassicTrack) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhia"); writer.u32(88); writer.u32(0); writer.u32(2); writer.u32(track.albumID)
        writer.u64(track.databaseID); writer.u32(2); writer.zeros(56)
        writer.bytes(stringObject(type: 200, value: track.album))
        writer.bytes(stringObject(type: 201, value: albumGroupingArtist(track)))
        writer.patchU32(UInt32(writer.count), at: 8)
        return writer.data
    }

    static func artistRecord(_ track: ClassicTrack) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhii"); writer.u32(80); writer.u32(0); writer.u32(1); writer.u32(track.artistID)
        writer.u64(track.databaseID); writer.u32(2); writer.zeros(48)
        writer.bytes(stringObject(type: 300, value: track.artist))
        writer.patchU32(UInt32(writer.count), at: 8)
        return writer.data
    }

    static func stringObject(type: UInt32, value: String) -> Data {
        let text = value.data(using: .utf16LittleEndian) ?? Data()
        var writer = BinaryWriter()
        writer.tag("mhod"); writer.u32(24); writer.u32(UInt32(40 + text.count)); writer.u32(type); writer.zeros(8)
        writer.u32(1); writer.u32(UInt32(text.count)); writer.u32(1); writer.u32(0); writer.bytes(text)
        return writer.data
    }

    static func section(type: UInt32, body: Data) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhsd")
        writer.u32(96)
        writer.u32(UInt32(96 + body.count))
        writer.u32(type)
        writer.zeros(80)
        writer.bytes(body)
        return writer.data
    }
}
