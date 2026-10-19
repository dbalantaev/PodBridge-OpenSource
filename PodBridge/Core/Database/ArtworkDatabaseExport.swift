// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ArtworkDatabase {
    private struct StoredLocation {
        let databaseID: UInt64
        let format: Format
        let offset: Int
    }

    /// Decodes the largest available iPod artwork rendition for each requested track.
    ///
    /// iPod caches contain RGB565 display assets rather than the original source
    /// image. Export therefore returns PNG data at the best resolution retained by
    /// the device profile.
    static func exportArtwork(root: URL, databaseIDs: Set<UInt64>) throws -> [UInt64: Data] {
        guard !databaseIDs.isEmpty else { return [:] }
        let artworkRoot = root.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
        let databaseURL = artworkRoot.appendingPathComponent("ArtworkDB")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }
        let database = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        let locations = try storedLocations(in: database, databaseIDs: databaseIDs)
        var result: [UInt64: Data] = [:]
        var cacheData: [UInt32: Data] = [:]

        for location in locations.sorted(by: { $0.format.imageSize > $1.format.imageSize })
        where result[location.databaseID] == nil {
            let cache: Data
            if let loaded = cacheData[location.format.id] {
                cache = loaded
            } else {
                let url = artworkRoot.appendingPathComponent(location.format.filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                cache = try Data(contentsOf: url, options: .mappedIfSafe)
                cacheData[location.format.id] = cache
            }
            let upperBound = location.offset + location.format.imageSize
            guard location.offset >= 0, upperBound <= cache.count else {
                throw PodBridgeError.unsupportedArtworkDatabase
            }
            let pixels = Data(cache[location.offset..<upperBound])
            result[location.databaseID] = try pngFromRGB565(pixels, format: location.format)
        }
        return result
    }

    private static func storedLocations(
        in database: Data,
        databaseIDs: Set<UInt64>
    ) throws -> [StoredLocation] {
        guard database.ascii(at: 0, length: 4) == "mhfd" else {
            throw PodBridgeError.unsupportedArtworkDatabase
        }
        let rootHeader = Int(try database.littleUInt32(at: 4))
        var sectionOffset = rootHeader
        while sectionOffset + 16 <= database.count,
              database.ascii(at: sectionOffset, length: 4) == "mhsd" {
            let sectionLength = Int(try database.littleUInt32(at: sectionOffset + 8))
            let sectionType = try database.littleUInt32(at: sectionOffset + 12)
            guard sectionLength > 0, sectionOffset + sectionLength <= database.count else {
                throw PodBridgeError.unsupportedArtworkDatabase
            }
            if sectionType == 1 {
                return try storedLocations(
                    in: database,
                    section: sectionOffset..<(sectionOffset + sectionLength),
                    databaseIDs: databaseIDs
                )
            }
            sectionOffset += sectionLength
        }
        return []
    }

    private static func storedLocations(
        in database: Data,
        section: Range<Int>,
        databaseIDs: Set<UInt64>
    ) throws -> [StoredLocation] {
        let listOffset = section.lowerBound + Int(try database.littleUInt32(at: section.lowerBound + 4))
        guard listOffset + 12 <= section.upperBound,
              database.ascii(at: listOffset, length: 4) == "mhli" else {
            throw PodBridgeError.unsupportedArtworkDatabase
        }
        var recordOffset = listOffset + Int(try database.littleUInt32(at: listOffset + 4))
        var result: [StoredLocation] = []
        while recordOffset + 28 <= section.upperBound,
              database.ascii(at: recordOffset, length: 4) == "mhii" {
            let recordLength = Int(try database.littleUInt32(at: recordOffset + 8))
            let headerLength = Int(try database.littleUInt32(at: recordOffset + 4))
            let databaseID = try database.littleUInt64(at: recordOffset + 20)
            guard recordLength > 0,
                  headerLength >= 28,
                  recordOffset + recordLength <= section.upperBound else {
                throw PodBridgeError.unsupportedArtworkDatabase
            }
            if databaseIDs.contains(databaseID) {
                result.append(contentsOf: try storedLocations(
                    in: database,
                    record: recordOffset..<(recordOffset + recordLength),
                    databaseID: databaseID,
                    childrenOffset: recordOffset + headerLength
                ))
            }
            recordOffset += recordLength
        }
        return result
    }

    private static func storedLocations(
        in database: Data,
        record: Range<Int>,
        databaseID: UInt64,
        childrenOffset: Int
    ) throws -> [StoredLocation] {
        var childOffset = childrenOffset
        var result: [StoredLocation] = []
        while childOffset + 24 <= record.upperBound,
              database.ascii(at: childOffset, length: 4) == "mhod" {
            let childLength = Int(try database.littleUInt32(at: childOffset + 8))
            let childHeader = Int(try database.littleUInt32(at: childOffset + 4))
            guard childLength > 0, childOffset + childLength <= record.upperBound else {
                throw PodBridgeError.unsupportedArtworkDatabase
            }
            let imageOffset = childOffset + childHeader
            if imageOffset + 36 <= childOffset + childLength,
               database.ascii(at: imageOffset, length: 4) == "mhni",
               let format = knownFormats[try database.littleUInt32(at: imageOffset + 16)] {
                let offset = Int(try database.littleUInt32(at: imageOffset + 20))
                result.append(StoredLocation(databaseID: databaseID, format: format, offset: offset))
            }
            childOffset += childLength
        }
        return result
    }

    private static func pngFromRGB565(_ data: Data, format: Format) throws -> Data {
        guard data.count == format.imageSize else { throw PodBridgeError.invalidArtwork }
        var pixels = [UInt8](repeating: 0, count: format.width * format.height * 4)
        for pixelIndex in 0..<(format.width * format.height) {
            let sourceOffset = pixelIndex * 2
            let packed = UInt16(data[sourceOffset]) | UInt16(data[sourceOffset + 1]) << 8
            let destinationOffset = pixelIndex * 4
            pixels[destinationOffset] = UInt8(UInt16((packed >> 11) & 0x1f) * 255 / 31)
            pixels[destinationOffset + 1] = UInt8(UInt16((packed >> 5) & 0x3f) * 255 / 63)
            pixels[destinationOffset + 2] = UInt8(UInt16(packed & 0x1f) * 255 / 31)
            pixels[destinationOffset + 3] = 255
        }
        guard let context = CGContext(
            data: &pixels,
            width: format.width,
            height: format.height,
            bitsPerComponent: 8,
            bytesPerRow: format.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let image = context.makeImage() else {
            throw PodBridgeError.invalidArtwork
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw PodBridgeError.invalidArtwork }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PodBridgeError.invalidArtwork }
        return output as Data
    }
}
