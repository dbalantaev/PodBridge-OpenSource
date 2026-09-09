// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PodBridge

final class ArtworkDatabaseTests: XCTestCase {
    func testVideoProfileUsesVideoArtworkCaches() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        IPodDeviceProfile.save(.video5, for: root)

        let plan = try XCTUnwrap(ArtworkDatabase.prepare(
            root: root,
            tracks: [makeTrack(id: 1, artworkID: 64, png: try makePNG())]
        ))
        XCTAssertEqual(Set(plan.appends.map { $0.url.lastPathComponent }), ["F1028_1.ithmb", "F1029_1.ithmb"])
        XCTAssertEqual(plan.appends.first { $0.url.lastPathComponent == "F1028_1.ithmb" }?.data.count, 100 * 100 * 2)
        XCTAssertEqual(plan.appends.first { $0.url.lastPathComponent == "F1029_1.ithmb" }?.data.count, 200 * 200 * 2)
    }

    func testClassicArtworkCreates320CoverFlowCacheAndRollsBack() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let png = try makePNG()
        let track = ClassicTrack(
            id: 1, databaseID: 2, title: "Cover", artist: "Artist", album: "Album",
            genre: "", fileType: "AAC audio file", ipodPath: ":iPod_Control:Music:F00:X.m4a",
            byteCount: 10, durationMS: 1_000, trackNumber: 1, year: 2026, bitrate: 256,
            sampleRate: 44_100, dateAdded: 3_000_000_000, artworkImageID: 64,
            artworkByteCount: UInt32(png.count), artworkData: png, sourceURL: nil
        )
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)

        let plan = try XCTUnwrap(ArtworkDatabase.prepare(root: root, tracks: [track]))
        let coverFlow = try XCTUnwrap(plan.appends.first { $0.url.lastPathComponent == "F1060_1.ithmb" })
        XCTAssertEqual(coverFlow.data.count, 320 * 320 * 2)

        try ArtworkDatabase.apply(plan, backupFolder: backup)
        XCTAssertTrue(manager.fileExists(atPath: plan.databaseURL.path))
        XCTAssertEqual((try coverFlow.url.resourceValues(forKeys: [.fileSizeKey])).fileSize, 320 * 320 * 2)

        try ArtworkDatabase.rollback(plan)
        XCTAssertFalse(manager.fileExists(atPath: plan.databaseURL.path))
        XCTAssertFalse(manager.fileExists(atPath: coverFlow.url.path))
    }

    func testArtworkAppendAndRollbackPreserveExistingDatabaseAndCacheBytes() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let firstTrack = makeTrack(id: 1, artworkID: 64, png: try makePNG(red: 0.9))
        let firstBackup = root.appendingPathComponent("backup-1", isDirectory: true)
        try manager.createDirectory(at: firstBackup, withIntermediateDirectories: true)
        let firstPlan = try XCTUnwrap(ArtworkDatabase.prepare(root: root, tracks: [firstTrack]))
        try ArtworkDatabase.apply(firstPlan, backupFolder: firstBackup)

        let databaseBefore = try Data(contentsOf: firstPlan.databaseURL)
        let cacheBefore = Dictionary(uniqueKeysWithValues: try firstPlan.appends.map {
            ($0.url, try Data(contentsOf: $0.url))
        })

        let secondTrack = makeTrack(id: 2, artworkID: 65, png: try makePNG(red: 0.2))
        let secondBackup = root.appendingPathComponent("backup-2", isDirectory: true)
        try manager.createDirectory(at: secondBackup, withIntermediateDirectories: true)
        let secondPlan = try XCTUnwrap(ArtworkDatabase.prepare(root: root, tracks: [secondTrack]))
        try ArtworkDatabase.apply(secondPlan, backupFolder: secondBackup)

        for append in secondPlan.appends {
            let prior = try XCTUnwrap(cacheBefore[append.url])
            let after = try Data(contentsOf: append.url)
            XCTAssertEqual(after.prefix(prior.count), prior)
            XCTAssertGreaterThan(after.count, prior.count)
        }

        try ArtworkDatabase.rollback(secondPlan)
        XCTAssertEqual(try Data(contentsOf: firstPlan.databaseURL), databaseBefore)
        for (url, prior) in cacheBefore {
            XCTAssertEqual(try Data(contentsOf: url), prior)
        }

        try ArtworkDatabase.rollback(firstPlan)
    }

    private func makeTrack(id: UInt32, artworkID: UInt32, png: Data) -> ClassicTrack {
        ClassicTrack(
            id: id, databaseID: UInt64(id) + 100, title: "Cover", artist: "Artist", album: "Album",
            genre: "", fileType: "AAC audio file", ipodPath: ":iPod_Control:Music:F00:X.m4a",
            byteCount: 10, durationMS: 1_000, trackNumber: 1, year: 2026, bitrate: 256,
            sampleRate: 44_100, dateAdded: 3_000_000_000, artworkImageID: artworkID,
            artworkByteCount: UInt32(png.count), artworkData: png, sourceURL: nil
        )
    }

    private func makePNG(red: CGFloat = 0.9) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PodBridgeError.invalidArtwork }
        context.setFillColor(CGColor(red: red, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let image = context.makeImage() else { throw PodBridgeError.invalidArtwork }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PodBridgeError.invalidArtwork
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PodBridgeError.invalidArtwork }
        return data as Data
    }
}
