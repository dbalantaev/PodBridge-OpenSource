// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

#if DEBUG || PODBRIDGE_DEMO
struct DemoIPodFixture {
    let containerURL: URL
    let rootURL: URL
    let library: ClassicLibrary
    let needsFirewireID: Bool
    let diskUseStatus: IPodDiskUseStatus
    let storageTotalBytes: Int64
    let storageFreeBytes: Int64
}

/// Builds a disposable mounted-volume fixture for diagnostics and product demos.
///
/// The fixture exercises the same database and device-preference readers as a
/// connected iPod while keeping all generated data inside a temporary directory.
enum DemoIPodFactory {
    private struct TrackSeed {
        let title: String
        let artist: String
        let album: String
        let trackNumber: UInt32
        let durationMS: UInt32
    }

    static func create(scenario: DemoIPodScenario) throws -> DemoIPodFixture {
        let manager = FileManager.default
        let container = manager.temporaryDirectory
            .appendingPathComponent("PodBridge-Emulated-\(UUID().uuidString)", isDirectory: true)

        do {
            let root = container.appendingPathComponent(rootName(for: scenario), isDirectory: true)
            let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
            let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
            try manager.createDirectory(at: device, withIntermediateDirectories: true)
            try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
            try writeDeviceIdentity(for: scenario, to: device)
            try writePreferences(for: scenario, to: itunes)

            let library = makeLibrary()
            let database = try ClassicDatabase.build(
                library: library,
                firewireID: Data([0x00, 0x0A, 0x27, 0x00, 0x1A, 0x2B, 0x3C, 0x4D]),
                databaseID: 0x504F444252494447
            )
            try database.write(to: itunes.appendingPathComponent("iTunesDB"), options: .atomic)

            return DemoIPodFixture(
                containerURL: container,
                rootURL: root,
                library: library,
                needsFirewireID: scenario == .missingSignatureID,
                diskUseStatus: scenario == .diskUseDisabled ? .disabled : .enabled,
                storageTotalBytes: 160_000_000_000,
                storageFreeBytes: 83_000_000_000
            )
        } catch {
            try? manager.removeItem(at: container)
            throw error
        }
    }

    static func remove(containerURL: URL) {
        try? FileManager.default.removeItem(at: containerURL)
    }

    private static func rootName(for scenario: DemoIPodScenario) -> String {
        switch scenario {
        case .normal: "Demo iPod"
        case .diskUseDisabled: "Demo iPod · Disk Use Off"
        case .missingSignatureID: "Demo iPod · Missing ID"
        }
    }

    private static func writeDeviceIdentity(for scenario: DemoIPodScenario, to deviceURL: URL) throws {
        guard scenario != .missingSignatureID else { return }
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: deviceURL.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writePreferences(for scenario: DemoIPodScenario, to itunesURL: URL) throws {
        var preferences = Data(repeating: 0, count: 64)
        if scenario != .diskUseDisabled {
            preferences[0x1f] = 1
        }
        try preferences.write(to: itunesURL.appendingPathComponent("iTunesPrefs"), options: .atomic)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["iPodPrefs": preferences],
            format: .binary,
            options: 0
        )
        try plist.write(to: itunesURL.appendingPathComponent("iTunesPrefs.plist"), options: .atomic)
    }

    private static func makeLibrary() -> ClassicLibrary {
        let tracks = makeTracks()
        return ClassicLibrary(
            name: "Demo iPod",
            tracks: tracks,
            playlists: [
                ClassicPlaylist(name: "Favorites", trackIDs: tracks.prefix(3).map(\.id)),
                ClassicPlaylist(name: "Recently Added", trackIDs: tracks.map(\.id))
            ]
        )
    }

    private static func makeTracks() -> [ClassicTrack] {
        let rows = [
            TrackSeed(
                title: "First Light", artist: "Sample Artist", album: "Morning Sessions",
                trackNumber: 1, durationMS: 180_000
            ),
            TrackSeed(
                title: "Open Road", artist: "Sample Artist", album: "Morning Sessions",
                trackNumber: 2, durationMS: 207_000
            ),
            TrackSeed(
                title: "Blue Hour", artist: "Sample Artist", album: "Morning Sessions",
                trackNumber: 3, durationMS: 198_000
            ),
            TrackSeed(
                title: "Northbound", artist: "Studio Example", album: "Travel Notes",
                trackNumber: 1, durationMS: 224_000
            ),
            TrackSeed(
                title: "Paper Map", artist: "Studio Example", album: "Travel Notes",
                trackNumber: 2, durationMS: 237_000
            ),
            TrackSeed(
                title: "Home Again", artist: "Studio Example", album: "Travel Notes",
                trackNumber: 3, durationMS: 169_000
            ),
            TrackSeed(
                title: "Evening Walk", artist: "Demo Ensemble", album: "Quiet Places",
                trackNumber: 1, durationMS: 217_000
            ),
            TrackSeed(
                title: "Lanterns", artist: "Demo Ensemble", album: "Quiet Places",
                trackNumber: 2, durationMS: 219_000
            ),
            TrackSeed(
                title: "After Rain", artist: "Demo Ensemble", album: "Quiet Places",
                trackNumber: 3, durationMS: 200_000
            ),
            TrackSeed(
                title: "Last Train", artist: "Demo Ensemble", album: "Quiet Places",
                trackNumber: 4, durationMS: 227_000
            )
        ]
        return rows.enumerated().map { index, row in
            ClassicTrack(
                id: UInt32(index + 1), databaseID: UInt64(10_000 + index),
                title: row.title, artist: row.artist, album: row.album,
                genre: "Electronic", fileType: "MPEG audio file",
                ipodPath: String(format: ":iPod_Control:Music:F00:PB%04d.mp3", index + 1),
                byteCount: 8_000_000, durationMS: row.durationMS, trackNumber: row.trackNumber, year: 2001,
                bitrate: 256, sampleRate: 44_100, dateAdded: 3_000_000_000 + UInt32(index),
                albumID: UInt32(index < 3 ? 1 : (index < 6 ? 2 : 3)),
                artistID: UInt32(index < 3 ? 1 : (index < 6 ? 2 : 3)),
                artworkImageID: index % 3 == 0 ? 0 : UInt32(index + 100), albumArtist: row.artist
            )
        }
    }
}
#endif
