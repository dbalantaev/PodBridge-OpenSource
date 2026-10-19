// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Rebuilds the iTunes metadata tree while preserving the MP4 media payload.
enum MP4AudioMetadataWriter {
    private struct MP4Box {
        let type: String
        let range: Range<Int>
        let headerLength: Int
    }

    private static let managedMP4Tags: Set<String> = [
        "©nam", "©ART", "©alb", "aART", "©gen", "©day", "trkn", "cpil", "covr"
    ]

    static func write(track: ClassicTrack, artwork: Data?, to url: URL) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        let topLevel = try mp4Boxes(in: original, range: 0..<original.count)
        guard let moov = topLevel.first(where: { $0.type == "moov" }), moov.headerLength == 8 else {
            throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
        }
        var moovData = Data(original[moov.range])
        try replaceMP4Metadata(in: &moovData, track: track, artwork: artwork)
        let delta = moovData.count - moov.range.count
        if delta != 0 {
            try adjustChunkOffsets(in: &moovData, by: delta, threshold: moov.range.upperBound)
        }
        var output = Data(original[..<moov.range.lowerBound])
        output.append(moovData)
        output.append(original[moov.range.upperBound...])
        try output.write(to: url, options: .atomic)
    }

    private static func replaceMP4Metadata(in moov: inout Data, track: ClassicTrack, artwork: Data?) throws {
        let children = try mp4Boxes(in: moov, range: 8..<moov.count)
        let items = mp4ItemList(track: track, artwork: artwork)
        if let udta = children.first(where: { $0.type == "udta" }) {
            guard udta.headerLength == 8 else { throw PodBridgeError.invalidDatabase }
            var udtaData = Data(moov[udta.range])
            try replaceMP4ItemList(in: &udtaData, with: items)
            moov.replaceSubrange(udta.range, with: udtaData)
        } else {
            moov.append(mp4Box("udta", payload: mp4MetaBox(items: items)))
        }
        try setMP4BoxSize(&moov)
    }

    private static func replaceMP4ItemList(in udta: inout Data, with items: Data) throws {
        let children = try mp4Boxes(in: udta, range: 8..<udta.count)
        if let meta = children.first(where: { $0.type == "meta" }) {
            guard meta.headerLength == 8 else { throw PodBridgeError.invalidDatabase }
            var metaData = Data(udta[meta.range])
            let metaChildren = try mp4Boxes(in: metaData, range: 12..<metaData.count)
            let replacement = mp4Box("ilst", payload: preservedMP4Items(from: metaData, boxes: metaChildren) + items)
            if let ilst = metaChildren.first(where: { $0.type == "ilst" }) {
                metaData.replaceSubrange(ilst.range, with: replacement)
            } else {
                metaData.append(replacement)
            }
            try setMP4BoxSize(&metaData)
            udta.replaceSubrange(meta.range, with: metaData)
        } else {
            udta.append(mp4MetaBox(items: items))
        }
        try setMP4BoxSize(&udta)
    }

    private static func preservedMP4Items(from meta: Data, boxes: [MP4Box]) -> Data {
        guard let ilst = boxes.first(where: { $0.type == "ilst" }), ilst.range.count >= 8,
              let children = try? mp4Boxes(in: meta, range: (ilst.range.lowerBound + 8)..<ilst.range.upperBound) else {
            return Data()
        }
        return children.reduce(into: Data()) { result, box in
            if !managedMP4Tags.contains(box.type) { result.append(meta[box.range]) }
        }
    }

    private static func mp4MetaBox(items: Data) -> Data {
        let handler = Data(repeating: 0, count: 8) + Data("mdir".utf8)
            + Data(repeating: 0, count: 12) + Data([0])
        let payload = Data([0, 0, 0, 0]) + mp4Box("hdlr", payload: handler) + mp4Box("ilst", payload: items)
        return mp4Box("meta", payload: payload)
    }

    private static func mp4ItemList(track: ClassicTrack, artwork: Data?) -> Data {
        var result = Data()
        result.append(mp4TextItem("©nam", track.title))
        result.append(mp4TextItem("©ART", track.artist))
        result.append(mp4TextItem("©alb", track.album))
        result.append(mp4TextItem("aART", track.albumArtist))
        result.append(mp4TextItem("©gen", track.genre))
        if track.year > 0 { result.append(mp4TextItem("©day", String(track.year))) }
        if track.trackNumber > 0 {
            var payload = Data(repeating: 0, count: 2)
            payload.append(bigEndian(UInt16(clamping: track.trackNumber)))
            payload.append(Data(repeating: 0, count: 4))
            result.append(mp4Item("trkn", valueType: 0, value: payload))
        }
        if track.compilation { result.append(mp4Item("cpil", valueType: 21, value: Data([1]))) }
        if let artwork { result.append(mp4Item("covr", valueType: 14, value: artwork)) }
        return result
    }

    private static func mp4TextItem(_ type: String, _ value: String) -> Data {
        value.isEmpty ? Data() : mp4Item(type, valueType: 1, value: Data(value.utf8))
    }

    private static func mp4Item(_ type: String, valueType: UInt32, value: Data) -> Data {
        mp4Box(type, payload: mp4Box("data", payload: bigEndian(valueType) + Data(repeating: 0, count: 4) + value))
    }

    private static func mp4Box(_ type: String, payload: Data) -> Data {
        var result = bigEndian(UInt32(8 + payload.count))
        if type.first == "©" {
            result.append(0xa9)
            result.append(Data(type.dropFirst().utf8))
        } else {
            result.append(Data(type.utf8))
        }
        result.append(payload)
        return result
    }

    private static func mp4Boxes(in data: Data, range: Range<Int>) throws -> [MP4Box] {
        var result: [MP4Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard offset + 8 <= range.upperBound else { throw PodBridgeError.invalidDatabase }
            let shortSize = Int(try bigUInt32(in: data, at: offset))
            let headerLength = shortSize == 1 ? 16 : 8
            let size: Int
            if shortSize == 1 {
                guard offset + 16 <= range.upperBound else { throw PodBridgeError.invalidDatabase }
                let extendedSize = try bigUInt64(in: data, at: offset + 8)
                guard extendedSize <= UInt64(Int.max) else { throw PodBridgeError.invalidDatabase }
                size = Int(extendedSize)
            } else {
                size = shortSize == 0 ? range.upperBound - offset : shortSize
            }
            guard size >= headerLength, offset + size <= range.upperBound,
                  let type = mp4Type(in: data, at: offset + 4) else {
                throw PodBridgeError.invalidDatabase
            }
            result.append(MP4Box(type: type, range: offset..<(offset + size), headerLength: headerLength))
            offset += size
        }
        return result
    }

    private static func mp4Type(in data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        if data[offset] == 0xa9,
           let suffix = String(data: data[(offset + 1)..<(offset + 4)], encoding: .ascii) {
            return "©" + suffix
        }
        return String(data: data[offset..<(offset + 4)], encoding: .ascii)
    }

    private static func setMP4BoxSize(_ data: inout Data) throws {
        guard data.count <= UInt32.max, try bigUInt32(in: data, at: 0) != 1 else {
            throw PodBridgeError.invalidDatabase
        }
        data.replaceSubrange(0..<4, with: bigEndian(UInt32(data.count)))
    }

    private static func adjustChunkOffsets(in data: inout Data, by delta: Int, threshold: Int) throws {
        try adjustChunkOffsets(in: &data, range: 8..<data.count, by: delta, threshold: threshold)
    }

    private static func adjustChunkOffsets(
        in data: inout Data,
        range: Range<Int>,
        by delta: Int,
        threshold: Int
    ) throws {
        for box in try mp4Boxes(in: data, range: range) {
            if ["trak", "mdia", "minf", "stbl"].contains(box.type) {
                let childRange = (box.range.lowerBound + box.headerLength)..<box.range.upperBound
                try adjustChunkOffsets(in: &data, range: childRange, by: delta, threshold: threshold)
                continue
            }
            guard box.type == "stco" || box.type == "co64" else { continue }
            let stride = box.type == "stco" ? 4 : 8
            let count = Int(try bigUInt32(in: data, at: box.range.lowerBound + box.headerLength + 4))
            var offset = box.range.lowerBound + box.headerLength + 8
            for _ in 0..<count {
                guard offset + stride <= box.range.upperBound else { throw PodBridgeError.invalidDatabase }
                let current = stride == 4
                    ? UInt64(try bigUInt32(in: data, at: offset))
                    : try bigUInt64(in: data, at: offset)
                if current >= UInt64(threshold) {
                    let adjusted = Int64(current) + Int64(delta)
                    guard adjusted >= 0, adjusted <= Int64(UInt32.max) || stride == 8 else {
                        throw PodBridgeError.invalidDatabase
                    }
                    let bytes = stride == 4 ? bigEndian(UInt32(adjusted)) : bigEndian(UInt64(adjusted))
                    data.replaceSubrange(offset..<(offset + stride), with: bytes)
                }
                offset += stride
            }
        }
    }

    private static func bigEndian(_ value: UInt16) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func bigUInt32(in data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw PodBridgeError.invalidDatabase }
        return UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func bigUInt64(in data: Data, at offset: Int) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { throw PodBridgeError.invalidDatabase }
        return (0..<8).reduce(0) { ($0 << 8) | UInt64(data[offset + $1]) }
    }
}
