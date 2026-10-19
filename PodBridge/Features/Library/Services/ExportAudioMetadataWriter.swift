// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Writes the iPod library's current metadata into an exported audio copy.
///
/// ID3-compatible containers are updated in place. MP4 audio keeps its media
/// payload while its metadata atom tree is rebuilt.
enum ExportAudioMetadataWriter {
    static func apply(track: ClassicTrack, artwork: Data?, to url: URL) async throws {
        switch url.pathExtension.lowercased() {
        case "mp3", "aac":
            try writeID3Prefix(track: track, artwork: artwork, to: url)
        case "wav":
            try writeRIFFMetadata(track: track, artwork: artwork, to: url)
        case "aif", "aiff":
            try writeAIFFMetadata(track: track, artwork: artwork, to: url)
        case "m4a", "m4b":
            try MP4AudioMetadataWriter.write(track: track, artwork: artwork, to: url)
        default:
            break
        }
    }

    private static func writeID3Prefix(track: ClassicTrack, artwork: Data?, to url: URL) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        let audioOffset = existingID3Length(in: original)
        var output = id3Tag(track: track, artwork: artwork)
        output.append(original.dropFirst(audioOffset))
        try output.write(to: url, options: .atomic)
    }

    private static func writeRIFFMetadata(track: ClassicTrack, artwork: Data?, to url: URL) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 12,
              original.ascii(at: 0, length: 4) == "RIFF",
              original.ascii(at: 8, length: 4) == "WAVE" else {
            throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
        }
        var output = Data(original.prefix(12))
        var offset = 12
        while offset + 8 <= original.count {
            let size = Int(try original.littleUInt32(at: offset + 4))
            let chunkLength = 8 + size + (size % 2)
            guard offset + chunkLength <= original.count else {
                throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
            }
            let identifier = original.ascii(at: offset, length: 4)
            if identifier?.lowercased() != "id3 " {
                output.append(original[offset..<(offset + chunkLength)])
            }
            offset += chunkLength
        }
        guard offset == original.count else {
            throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
        }
        let tag = id3Tag(track: track, artwork: artwork)
        output.append(Data("id3 ".utf8))
        output.append(littleEndian(UInt32(tag.count)))
        output.append(tag)
        if tag.count.isMultiple(of: 2) == false { output.append(0) }
        try output.setLittleUInt32(UInt32(output.count - 8), at: 4)
        try output.write(to: url, options: .atomic)
    }

    private static func writeAIFFMetadata(track: ClassicTrack, artwork: Data?, to url: URL) throws {
        let original = try Data(contentsOf: url, options: .mappedIfSafe)
        guard original.count >= 12,
              original.ascii(at: 0, length: 4) == "FORM",
              ["AIFF", "AIFC"].contains(original.ascii(at: 8, length: 4) ?? "") else {
            throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
        }
        var output = Data(original.prefix(12))
        var offset = 12
        while offset + 8 <= original.count {
            let size = Int(try bigUInt32(in: original, at: offset + 4))
            let chunkLength = 8 + size + (size % 2)
            guard offset + chunkLength <= original.count else {
                throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
            }
            if original.ascii(at: offset, length: 4) != "ID3 " {
                output.append(original[offset..<(offset + chunkLength)])
            }
            offset += chunkLength
        }
        guard offset == original.count else {
            throw IPodSyncEngine.ExportError.metadataRewriteFailed(url.lastPathComponent)
        }
        let tag = id3Tag(track: track, artwork: artwork)
        output.append(Data("ID3 ".utf8))
        output.append(bigEndian(UInt32(tag.count)))
        output.append(tag)
        if tag.count.isMultiple(of: 2) == false { output.append(0) }
        output.replaceSubrange(4..<8, with: bigEndian(UInt32(output.count - 8)))
        try output.write(to: url, options: .atomic)
    }

    private static func id3Tag(track: ClassicTrack, artwork: Data?) -> Data {
        var frames = Data()
        frames.append(textFrame("TIT2", track.title))
        frames.append(textFrame("TPE1", track.artist))
        frames.append(textFrame("TALB", track.album))
        frames.append(textFrame("TPE2", track.albumArtist))
        frames.append(textFrame("TCON", track.genre))
        if track.trackNumber > 0 { frames.append(textFrame("TRCK", String(track.trackNumber))) }
        if track.year > 0 { frames.append(textFrame("TDRC", String(track.year))) }
        if track.compilation { frames.append(textFrame("TCMP", "1")) }
        if let artwork {
            var payload = Data([3])
            payload.append(Data("image/png".utf8))
            payload.append(0)
            payload.append(3)
            payload.append(0)
            payload.append(artwork)
            frames.append(frame("APIC", payload: payload))
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [4, 0, 0])
        tag.append(synchsafe(UInt32(frames.count)))
        tag.append(frames)
        return tag
    }

    private static func textFrame(_ identifier: String, _ value: String) -> Data {
        guard !value.isEmpty else { return Data() }
        var payload = Data([3])
        payload.append(Data(value.utf8))
        return frame(identifier, payload: payload)
    }

    private static func frame(_ identifier: String, payload: Data) -> Data {
        var result = Data(identifier.utf8)
        result.append(synchsafe(UInt32(payload.count)))
        result.append(contentsOf: [0, 0])
        result.append(payload)
        return result
    }

    private static func existingID3Length(in data: Data) -> Int {
        guard data.count >= 10, data.ascii(at: 0, length: 3) == "ID3" else { return 0 }
        let size = Int(data[6] & 0x7f) << 21
            | Int(data[7] & 0x7f) << 14
            | Int(data[8] & 0x7f) << 7
            | Int(data[9] & 0x7f)
        return min(data.count, 10 + size)
    }

    private static func synchsafe(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 21) & 0x7f),
            UInt8((value >> 14) & 0x7f),
            UInt8((value >> 7) & 0x7f),
            UInt8(value & 0x7f)
        ])
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func bigEndian(_ value: UInt32) -> Data {
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
}
