// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Reads, generates, applies, and rolls back iPod artwork database changes.
///
/// Source images are rendered into the device profile's RGB565 `.ithmb` cache
/// formats. The active `ArtworkDB` and cache files are changed transactionally
/// and can be restored using the plan captured before applying them.
enum ArtworkDatabase {
    // MARK: - Transaction models

    /// One append-only artwork cache change captured for rollback.
    struct CacheAppend: Sendable {
        let url: URL
        let originalSize: UInt64
        let existed: Bool
        let data: Data
    }

    /// Complete ArtworkDB and cache update prepared before files are changed.
    struct Plan: Sendable {
        let databaseURL: URL
        let originalDatabase: Data?
        let updatedDatabase: Data
        let appends: [CacheAppend]
    }

    /// A device artwork cache format and its RGB565 dimensions.
    struct Format: Hashable, Sendable {
        let id: UInt32
        let width: Int
        let height: Int

        var imageSize: Int { width * height * 2 }
        var filename: String { "F\(id)_1.ithmb" }
    }

    private struct Location: Sendable {
        let format: Format
        let offset: UInt32
    }

    private static let knownFormats: [UInt32: Format] = [
        1027: Format(id: 1027, width: 100, height: 100),
        1028: Format(id: 1028, width: 100, height: 100),
        1029: Format(id: 1029, width: 200, height: 200),
        1031: Format(id: 1031, width: 42, height: 42),
        1061: Format(id: 1061, width: 56, height: 56),
        1055: Format(id: 1055, width: 128, height: 128),
        1068: Format(id: 1068, width: 128, height: 128),
        1060: Format(id: 1060, width: 320, height: 320),
        1071: Format(id: 1071, width: 240, height: 240),
        1074: Format(id: 1074, width: 50, height: 50),
        1078: Format(id: 1078, width: 80, height: 80),
        1084: Format(id: 1084, width: 240, height: 240),
    ]

    /// Verifies that data contains a decodable, non-empty image.
    static func validateSourceArtwork(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 50 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw PodBridgeError.invalidArtwork
        }
    }

    /// Builds an artwork update plan without changing files on disk.
    ///
    /// Returns `nil` when none of the supplied tracks carries artwork data.
    static func prepare(root: URL, tracks: [ClassicTrack]) throws -> Plan? {
        let artworkTracks = tracks.filter { $0.artworkImageID != 0 && $0.artworkData != nil }
        guard !artworkTracks.isEmpty else { return nil }
        let artworkRoot = root.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
        let databaseURL = artworkRoot.appendingPathComponent("ArtworkDB")
        let originalDatabase = try? Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let profile = IPodDeviceProfile.saved(for: root) ?? .classic7
        let formats = try availableFormats(from: originalDatabase, profile: profile)
        AppLogger.artwork(
            "Artwork plan started tracks=\(artworkTracks.count) existingDatabase=\(originalDatabase != nil) formats=\(formats.map(\.id).sorted())",
            level: .info
        )

        var appendData = Dictionary(uniqueKeysWithValues: formats.map { ($0.id, Data()) })
        var originalSizes: [UInt32: UInt64] = [:]
        var existingFiles: [UInt32: Bool] = [:]
        for format in formats {
            let url = artworkRoot.appendingPathComponent(format.filename)
            existingFiles[format.id] = FileManager.default.fileExists(atPath: url.path)
            originalSizes[format.id] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        }

        var imageLocations: [Data: [Location]] = [:]
        var records: [Data] = []
        for track in artworkTracks {
            guard let source = track.artworkData else { continue }
            let digest = Data(SHA256.hash(data: source))
            let locations: [Location]
            if let existing = imageLocations[digest] {
                locations = existing
            } else {
                var generated: [Location] = []
                for format in formats {
                    var current = appendData[format.id] ?? Data()
                    let original = originalSizes[format.id] ?? 0
                    let remainder = Int((original + UInt64(current.count)) % UInt64(format.imageSize))
                    if remainder != 0 { current.append(Data(repeating: 0, count: format.imageSize - remainder)) }
                    let offset = original + UInt64(current.count)
                    guard offset <= UInt32.max else { throw PodBridgeError.unsupportedArtworkDatabase }
                    current.append(try renderRGB565(source, format: format))
                    appendData[format.id] = current
                    generated.append(Location(format: format, offset: UInt32(offset)))
                }
                imageLocations[digest] = generated
                locations = generated
            }
            records.append(imageRecord(track: track, locations: locations))
        }

        let updated = try merge(
            original: originalDatabase,
            records: records,
            nextID: (artworkTracks.map(\.artworkImageID).max() ?? 0) + 1,
            formats: formats
        )
        let appends = formats.compactMap { format -> CacheAppend? in
            guard let data = appendData[format.id], !data.isEmpty else { return nil }
            return CacheAppend(
                url: artworkRoot.appendingPathComponent(format.filename),
                originalSize: originalSizes[format.id] ?? 0,
                existed: existingFiles[format.id] ?? false,
                data: data
            )
        }
        AppLogger.artwork(
            "Artwork plan ready records=\(records.count) databaseBytes=\(updated.count) appendBytes=\(appends.reduce(0) { $0 + $1.data.count })",
            level: .info
        )
        return Plan(databaseURL: databaseURL, originalDatabase: originalDatabase, updatedDatabase: updated, appends: appends)
    }

    /// Applies a prepared plan and writes its original state to the backup folder.
    static func apply(_ plan: Plan, backupFolder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: plan.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original = plan.originalDatabase {
            try original.write(to: backupFolder.appendingPathComponent("ArtworkDB"), options: .atomic)
            AppLogger.artwork("Original ArtworkDB backed up bytes=\(original.count)", level: .info)
        }
        do {
            for append in plan.appends {
                if !manager.fileExists(atPath: append.url.path) { manager.createFile(atPath: append.url.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: append.url)
                try handle.seekToEnd()
                try handle.write(contentsOf: append.data)
                try handle.synchronize()
                try handle.close()
                AppLogger.artwork(
                    "Cache appended file=\(append.url.lastPathComponent) originalBytes=\(append.originalSize) appendedBytes=\(append.data.count)",
                    level: .debug
                )
            }
            try plan.updatedDatabase.write(to: plan.databaseURL, options: .atomic)
            guard try Data(contentsOf: plan.databaseURL) == plan.updatedDatabase else {
                throw PodBridgeError.databaseVerificationFailed
            }
            AppLogger.artwork("ArtworkDB update verified bytes=\(plan.updatedDatabase.count)", level: .info)
        } catch {
            AppLogger.artwork("Artwork apply failed error=\(error.localizedDescription)", level: .error)
            try? rollback(plan)
            throw error
        }
    }

    /// Restores the artwork database and truncates or removes appended caches.
    static func rollback(_ plan: Plan) throws {
        let manager = FileManager.default
        for append in plan.appends where manager.fileExists(atPath: append.url.path) {
            if !append.existed {
                try manager.removeItem(at: append.url)
                AppLogger.artwork("Rollback removed new cache file=\(append.url.lastPathComponent)", level: .debug)
                continue
            }
            let handle = try FileHandle(forWritingTo: append.url)
            try handle.truncate(atOffset: append.originalSize)
            try handle.synchronize()
            try handle.close()
            AppLogger.artwork("Rollback truncated cache file=\(append.url.lastPathComponent) bytes=\(append.originalSize)", level: .debug)
        }
        if let original = plan.originalDatabase {
            try original.write(to: plan.databaseURL, options: .atomic)
        } else {
            try? manager.removeItem(at: plan.databaseURL)
        }
        AppLogger.artwork("Artwork database rollback finished", level: .info)
    }

    private static func availableFormats(from database: Data?, profile: IPodDeviceProfile) throws -> [Format] {
        guard let database else { return defaultFormats(for: profile) }
        guard database.ascii(at: 0, length: 4) == "mhfd" else { throw PodBridgeError.unsupportedArtworkDatabase }
        let rootHeader = Int(try database.littleUInt32(at: 4))
        var cursor = rootHeader
        while cursor + 16 <= database.count, database.ascii(at: cursor, length: 4) == "mhsd" {
            let length = Int(try database.littleUInt32(at: cursor + 8))
            let type = try database.littleUInt32(at: cursor + 12)
            guard length > 0, cursor + length <= database.count else { throw PodBridgeError.unsupportedArtworkDatabase }
            if type == 3 {
                let list = cursor + Int(try database.littleUInt32(at: cursor + 4))
                guard database.ascii(at: list, length: 4) == "mhlf" else { break }
                var item = list + Int(try database.littleUInt32(at: list + 4))
                var result: [Format] = []
                while item + 24 <= cursor + length, database.ascii(at: item, length: 4) == "mhif" {
                    let itemLength = Int(try database.littleUInt32(at: item + 8))
                    let id = try database.littleUInt32(at: item + 16)
                    if let format = knownFormats[id] { result.append(format) }
                    guard itemLength > 0 else { break }
                    item += itemLength
                }
                if !result.isEmpty { return result }
            }
            cursor += length
        }
        throw PodBridgeError.unsupportedArtworkDatabase
    }

    private static func defaultFormats(for profile: IPodDeviceProfile) -> [Format] {
        let ids: [UInt32]
        switch profile {
        case .classic7, .classic6, .nano3:
            ids = [1061, 1055, 1068, 1060]
        case .video5:
            ids = [1028, 1029]
        case .nano1And2:
            ids = [1031, 1027]
        case .nano4:
            ids = [1055, 1068, 1071, 1074, 1078, 1084]
        }
        return ids.compactMap { knownFormats[$0] }
    }

    private static func merge(original: Data?, records: [Data], nextID: UInt32, formats: [Format]) throws -> Data {
        guard let original else { return build(records: records, nextID: nextID, formats: formats) }
        let rootHeader = Int(try original.littleUInt32(at: 4))
        guard rootHeader <= original.count else { throw PodBridgeError.unsupportedArtworkDatabase }
        var output = Data(original.prefix(rootHeader))
        var cursor = rootHeader
        var replaced = false
        while cursor + 16 <= original.count, original.ascii(at: cursor, length: 4) == "mhsd" {
            let length = Int(try original.littleUInt32(at: cursor + 8))
            let type = try original.littleUInt32(at: cursor + 12)
            guard length > 0, cursor + length <= original.count else { throw PodBridgeError.unsupportedArtworkDatabase }
            if type == 1 {
                var section = Data(original[cursor..<(cursor + length)])
                let list = Int(try section.littleUInt32(at: 4))
                guard section.ascii(at: list, length: 4) == "mhli" else { throw PodBridgeError.unsupportedArtworkDatabase }
                let oldCount = try section.littleUInt32(at: list + 8)
                records.forEach { section.append($0) }
                try section.setLittleUInt32(UInt32(section.count), at: 8)
                try section.setLittleUInt32(oldCount + UInt32(records.count), at: list + 8)
                output.append(section)
                replaced = true
            } else {
                output.append(original[cursor..<(cursor + length)])
            }
            cursor += length
        }
        guard replaced, cursor == original.count else { throw PodBridgeError.unsupportedArtworkDatabase }
        try output.setLittleUInt32(UInt32(output.count), at: 8)
        try output.setLittleUInt32(nextID, at: 28)
        return output
    }

    private static func build(records: [Data], nextID: UInt32, formats: [Format]) -> Data {
        var root = BinaryWriter()
        root.tag("mhfd"); root.u32(132); root.u32(0); root.u32(0); root.u32(2); root.u32(3); root.u32(0); root.u32(nextID)
        root.zeros(16); root.u32(2); root.zeros(80)
        var images = BinaryWriter()
        images.tag("mhli"); images.u32(92); images.u32(UInt32(records.count)); images.zeros(80); records.forEach { images.bytes($0) }
        root.bytes(section(type: 1, body: images.data))
        var albums = BinaryWriter()
        albums.tag("mhla"); albums.u32(92); albums.u32(0); albums.zeros(80)
        root.bytes(section(type: 2, body: albums.data))
        var files = BinaryWriter()
        files.tag("mhlf"); files.u32(92); files.u32(UInt32(formats.count)); files.zeros(80)
        for format in formats {
            files.tag("mhif"); files.u32(124); files.u32(124); files.u32(0); files.u32(format.id); files.u32(UInt32(format.imageSize)); files.zeros(100)
        }
        root.bytes(section(type: 3, body: files.data))
        root.patchU32(UInt32(root.count), at: 8)
        return root.data
    }

    private static func imageRecord(track: ClassicTrack, locations: [Location]) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhii"); writer.u32(152); writer.u32(0); writer.u32(UInt32(locations.count))
        writer.u32(track.artworkImageID); writer.u64(track.databaseID); writer.zeros(20)
        writer.u32(track.artworkByteCount); writer.zeros(100)
        locations.forEach { writer.bytes(locationObject($0)) }
        writer.patchU32(UInt32(writer.count), at: 8)
        return writer.data
    }

    private static func locationObject(_ location: Location) -> Data {
        var name = BinaryWriter()
        let text = (":" + location.format.filename).data(using: .utf16LittleEndian) ?? Data()
        let padding = (4 - ((36 + text.count) % 4)) % 4
        name.tag("mhod"); name.u32(24); name.u32(UInt32(36 + text.count + padding)); name.u16(3); name.u16(UInt16(padding))
        name.zeros(8); name.u32(UInt32(text.count)); name.u32(2); name.u32(0); name.bytes(text); name.zeros(padding)

        var image = BinaryWriter()
        image.tag("mhni"); image.u32(76); image.u32(UInt32(76 + name.count)); image.u32(1)
        image.u32(location.format.id); image.u32(location.offset); image.u32(UInt32(location.format.imageSize))
        image.u16(0); image.u16(0); image.u16(UInt16(location.format.height)); image.u16(UInt16(location.format.width))
        image.zeros(4); image.u32(UInt32(location.format.imageSize)); image.zeros(32); image.bytes(name.data)

        var object = BinaryWriter()
        object.tag("mhod"); object.u32(24); object.u32(UInt32(24 + image.count)); object.u32(2); object.zeros(8); object.bytes(image.data)
        return object.data
    }

    private static func section(type: UInt32, body: Data) -> Data {
        var writer = BinaryWriter()
        writer.tag("mhsd"); writer.u32(96); writer.u32(UInt32(96 + body.count)); writer.u32(type); writer.zeros(80); writer.bytes(body)
        return writer.data
    }

    private static func renderRGB565(_ source: Data, format: Format) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
              ] as CFDictionary) else { throw PodBridgeError.invalidArtwork }
        var pixels = [UInt8](repeating: 0, count: format.width * format.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: format.width,
            height: format.height,
            bitsPerComponent: 8,
            bytesPerRow: format.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw PodBridgeError.invalidArtwork }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: format.width, height: format.height))
        let scale = min(CGFloat(format.width) / CGFloat(image.width), CGFloat(format.height) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(format.width) - width) / 2, y: (CGFloat(format.height) - height) / 2, width: width, height: height))
        var result = Data(capacity: format.imageSize)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = UInt16(pixels[offset] >> 3)
            let green = UInt16(pixels[offset + 1] >> 2)
            let blue = UInt16(pixels[offset + 2] >> 3)
            let packed = (red << 11) | (green << 5) | blue
            result.append(UInt8(packed & 0xff)); result.append(UInt8(packed >> 8))
        }
        return result
    }
}
