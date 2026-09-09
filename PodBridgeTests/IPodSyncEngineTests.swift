// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import XCTest
@testable import PodBridge

final class IPodSyncEngineTests: XCTestCase {
    func testImportPreservesSourceMetadataForPlaylistTracks() {
        let incoming = [
            artistTrack(id: 0, title: "One", artist: "Artist A", album: "Album A"),
            artistTrack(id: 0, title: "Two", artist: "Artist B feat. Guest", album: "Album B"),
            artistTrack(id: 0, title: "Three", artist: "Artist C", album: "Album C")
        ]
        let playlist = SourcePlaylist(name: "Road Trip", fileIndices: [0, 1, 2])

        let prepared = IPodSyncEngine.preparedTracksForImport(
            incoming: incoming,
            existing: [],
            playlists: [playlist]
        )

        XCTAssertEqual(prepared, incoming)
    }

    func testDeluxeAndStandardEditionProduceOneConsolidationPlan() {
        var standardOne = artistTrack(id: 1, title: "One", artist: "Artist", album: "The Record")
        var standardTwo = artistTrack(id: 2, title: "Two", artist: "Artist", album: "The Record")
        var deluxeBonus = artistTrack(id: 3, title: "Bonus", artist: "Artist", album: "The Record (Deluxe Edition)")
        standardOne.albumArtist = "Artist"; standardOne.albumID = 10
        standardTwo.albumArtist = "Artist"; standardTwo.albumID = 10
        deluxeBonus.albumArtist = "Artist"; deluxeBonus.albumID = 20

        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(tracks: [standardOne, standardTwo, deluxeBonus]),
            .init(albums: 1, tracks: 3)
        )
    }

    func testTrackListOverlapMergesRenamedReissueButDurationMismatchDoesNot() {
        var originalOne = artistTrack(id: 1, title: "Opening", artist: "Artist", album: "Blue")
        var originalTwo = artistTrack(id: 2, title: "Closing", artist: "Artist", album: "Blue")
        var reissueOne = artistTrack(id: 3, title: "Opening", artist: "Artist", album: "The Blue Sessions")
        var reissueTwo = artistTrack(id: 4, title: "Closing", artist: "Artist", album: "The Blue Sessions")
        var bonus = artistTrack(id: 5, title: "Bonus", artist: "Artist", album: "The Blue Sessions")
        for index in [1, 2] {
            if index == 1 { originalOne.albumID = 10; originalOne.albumArtist = "Artist" }
            else { originalTwo.albumID = 10; originalTwo.albumArtist = "Artist" }
        }
        reissueOne.albumID = 20; reissueOne.albumArtist = "Artist"
        reissueTwo.albumID = 20; reissueTwo.albumArtist = "Artist"
        bonus.albumID = 20; bonus.albumArtist = "Artist"

        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(
                tracks: [originalOne, originalTwo, reissueOne, reissueTwo, bonus]
            ),
            .init(albums: 1, tracks: 5)
        )

        reissueOne.durationMS += 10_000
        reissueTwo.durationMS += 10_000
        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(
                tracks: [originalOne, originalTwo, reissueOne, reissueTwo, bonus]
            ).albums,
            0
        )
    }

    func testDiscSetsMergeButSameNamedSingleAndAlbumStaySeparate() {
        var discOne = artistTrack(id: 1, title: "A", artist: "Artist", album: "Live (Disc 1)")
        var discTwo = artistTrack(id: 2, title: "B", artist: "Artist", album: "Live CD2")
        discOne.albumID = 10; discOne.albumArtist = "Artist"
        discTwo.albumID = 20; discTwo.albumArtist = "Artist"
        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(tracks: [discOne, discTwo]),
            .init(albums: 1, tracks: 2)
        )

        var albumOne = artistTrack(id: 3, title: "Intro", artist: "Artist", album: "Home")
        var albumTwo = artistTrack(id: 4, title: "Finale", artist: "Artist", album: "Home")
        var single = artistTrack(id: 5, title: "Home", artist: "Artist", album: "Home")
        albumOne.albumID = 30; albumOne.albumArtist = "Artist"
        albumTwo.albumID = 30; albumTwo.albumArtist = "Artist"
        single.albumID = 40; single.albumArtist = "Artist"
        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(tracks: [albumOne, albumTwo, single]).albums,
            0
        )
    }

    func testSharedUPCCanMergeDifferentlyNamedReleaseRecords() {
        var first = artistTrack(id: 1, title: "One", artist: "Artist", album: "Original Name")
        var renamed = artistTrack(id: 2, title: "Bonus", artist: "Artist", album: "International Name")
        first.albumID = 10; first.albumArtist = "Artist"; first.sourceAlbumID = "0-12345-67890-5"
        renamed.albumID = 20; renamed.albumArtist = "Artist"; renamed.sourceAlbumID = "012345678905"

        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(tracks: [first, renamed]),
            .init(albums: 1, tracks: 2)
        )
    }

    func testImportedPlaylistDeletionOwnershipExcludesReusedLibrarySongs() {
        var reused = artistTrack(id: 1, title: "Old Song", artist: "Artist", album: "Original Album")
        reused.albumArtist = "Artist"
        var imported = artistTrack(id: 2, title: "New Song", artist: "Another Artist", album: "Road Trip")
        imported.albumArtist = "Various Artists"
        imported.compilation = true
        let playlist = ClassicPlaylist(name: "Road Trip", trackIDs: [1, 2])

        XCTAssertEqual(
            IPodSyncEngine.importedCompilationTrackIDs(
                playlist: playlist,
                tracks: [reused, imported]
            ),
            [2]
        )
        XCTAssertTrue(IPodSyncEngine.importedCompilationTrackIDs(
            playlist: ClassicPlaylist(name: "Made on iPhone", trackIDs: [1]),
            tracks: [reused, imported]
        ).isEmpty)
    }

    func testMergeCollectsOnlySameImportCohortIntoPlaylistCompilation() {
        var anchor = artistTrack(id: 1, title: "New One", artist: "Artist A", album: "Road Trip")
        anchor.albumArtist = "Various Artists"
        anchor.compilation = true
        anchor.albumID = 10
        anchor.ipodPath = ":iPod_Control:Music:F00:PBANCHOR.m4a"
        anchor.dateAdded = 3_000_000_100

        var legacyCopy = artistTrack(id: 2, title: "New Two", artist: "Artist B", album: "Artist B Album")
        legacyCopy.albumArtist = "Artist B"
        legacyCopy.albumID = 20
        legacyCopy.ipodPath = ":iPod_Control:Music:F01:PBLEGACY.m4a"
        legacyCopy.dateAdded = 3_000_000_120

        var reusedOldSong = artistTrack(id: 3, title: "Old Song", artist: "Old Artist", album: "Old Album")
        reusedOldSong.albumArtist = "Old Artist"
        reusedOldSong.albumID = 30
        reusedOldSong.ipodPath = ":iPod_Control:Music:F02:APPLE.m4a"
        reusedOldSong.dateAdded = 2_900_000_000

        var olderPodBridgeSong = artistTrack(id: 4, title: "Older Import", artist: "Other", album: "Other Album")
        olderPodBridgeSong.albumArtist = "Other"
        olderPodBridgeSong.albumID = 40
        olderPodBridgeSong.ipodPath = ":iPod_Control:Music:F03:PBOLDER.m4a"
        olderPodBridgeSong.dateAdded = 2_900_000_000

        let playlist = ClassicPlaylist(name: "Road Trip", trackIDs: [1, 2, 3, 4])

        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(
                tracks: [anchor, legacyCopy, reusedOldSong, olderPodBridgeSong],
                playlists: [playlist]
            ),
            .init(albums: 1, tracks: 2)
        )
    }

    func testMergeDoesNotTreatPlaylistBuiltFromLibraryAsImportedAlbum() {
        var first = artistTrack(id: 1, title: "One", artist: "Artist A", album: "Album A")
        var second = artistTrack(id: 2, title: "Two", artist: "Artist B", album: "Album B")
        first.albumArtist = "Artist A"; first.albumID = 10
        second.albumArtist = "Artist B"; second.albumID = 20
        first.ipodPath = ":iPod_Control:Music:F00:PBONE.m4a"
        second.ipodPath = ":iPod_Control:Music:F01:PBTWO.m4a"
        let playlist = ClassicPlaylist(name: "Made on iPhone", trackIDs: [1, 2])

        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(
                tracks: [first, second],
                playlists: [playlist]
            ),
            .init(albums: 0, tracks: 0)
        )
    }

    func testNewAlbumNormalizesFeaturedArtistsToExistingMainArtist() {
        let existing = [artistTrack(
            id: 9,
            title: "Album Track",
            artist: "6LACK",
            album: "Since I Have a Lover"
        )]
        let incoming = [
            artistTrack(id: 0, title: "Feature One", artist: "6LACK & 2 Chainz", album: "Since I Have a Lover"),
            artistTrack(id: 0, title: "Feature Two", artist: "6LACK feat. Don Toliver", album: "Since I Have a Lover")
        ]

        let normalized = IPodSyncEngine.normalizedAlbumArtistsForImport(
            incoming: incoming,
            existing: existing
        )

        XCTAssertEqual(Set(normalized.map(\.artist)), ["6LACK & 2 Chainz", "6LACK feat. Don Toliver"])
        XCTAssertEqual(Set(normalized.map(\.albumArtist)), ["6LACK"])
        XCTAssertEqual(
            IPodSyncEngine.albumArtistRepairPreview(tracks: existing + incoming),
            .init(albums: 1, tracks: 3)
        )
    }

    func testNewAlbumKeepsOneSharedJointArtistAndSkipsAmbiguousCredits() {
        let joint = [
            artistTrack(id: 0, title: "One", artist: "Silk Sonic", album: "An Evening"),
            artistTrack(id: 0, title: "Two", artist: "Silk Sonic", album: "An Evening")
        ]
        let ambiguous = [
            artistTrack(id: 0, title: "A", artist: "Artist A", album: "Shared Title"),
            artistTrack(id: 0, title: "B", artist: "Artist B", album: "Shared Title"),
            artistTrack(id: 0, title: "Duet", artist: "Artist A & Artist B", album: "Shared Title")
        ]

        XCTAssertEqual(
            IPodSyncEngine.normalizedAlbumArtistsForImport(incoming: joint, existing: []),
            joint
        )
        XCTAssertEqual(
            IPodSyncEngine.normalizedAlbumArtistsForImport(incoming: ambiguous, existing: []),
            ambiguous
        )
        XCTAssertEqual(IPodSyncEngine.albumArtistRepairPreview(tracks: joint).albums, 0)
        XCTAssertEqual(IPodSyncEngine.albumArtistRepairPreview(tracks: ambiguous).albums, 0)
    }

    func testEmbeddedAlbumIdentityNormalizesCommaCreditsWithinOneRelease() {
        var solo = artistTrack(
            id: 0,
            title: "Solo",
            artist: "Mac Miller",
            album: "The Divine Feminine"
        )
        solo.albumArtist = "Mac Miller"
        solo.sourceAlbumID = "093624817154"
        var commaFeature = artistTrack(
            id: 0,
            title: "Feature",
            artist: "Mac Miller,Ariana Grande",
            album: "The Divine Feminine"
        )
        commaFeature.albumArtist = "Mac Miller"
        commaFeature.sourceAlbumID = "093624817154"

        let normalized = IPodSyncEngine.normalizedAlbumArtistsForImport(
            incoming: [solo, commaFeature],
            existing: []
        )

        XCTAssertEqual(Set(normalized.map(\.artist)), ["Mac Miller", "Mac Miller,Ariana Grande"])
        XCTAssertEqual(Set(normalized.map(\.albumArtist)), ["Mac Miller"])
    }

    func testDifferentReleaseIDsAreNotCombined() {
        var original = artistTrack(
            id: 0,
            title: "Original",
            artist: "Artist",
            album: "Shared Album"
        )
        original.albumArtist = "Artist"
        original.sourceAlbumID = "111"
        var deluxeFeature = artistTrack(
            id: 0,
            title: "Deluxe Feature",
            artist: "Artist, Guest",
            album: "Shared Album"
        )
        deluxeFeature.albumArtist = "Artist"
        deluxeFeature.sourceAlbumID = "222"

        XCTAssertEqual(
            IPodSyncEngine.normalizedAlbumArtistsForImport(
                incoming: [original, deluxeFeature],
                existing: []
            ),
            [original, deluxeFeature]
        )
    }

    func testRepairAlbumArtistsMergesExistingCoverFlowCardsWithOneBackup() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
        var main = artistTrack(id: 9, title: "Solo", artist: "Mac Miller", album: "The Divine Feminine")
        main.albumID = 2
        main.artistID = 3
        main.artworkImageID = 40
        main.artworkByteCount = 100
        var feature = artistTrack(
            id: 11,
            title: "Feature",
            artist: "Mac Miller & Ariana Grande",
            album: "The Divine Feminine"
        )
        feature.albumID = 4
        feature.artistID = 5
        feature.artworkImageID = 41
        feature.artworkByteCount = 120
        let playlist = ClassicPlaylist(name: "Favorites", trackIDs: [11, 9])
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(name: "Test iPod", tracks: [main, feature], playlists: [playlist]),
            firewireID: firewireID,
            databaseID: 123
        )
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))

        let progressRecorder = AlbumRepairProgressRecorder()
        let result = try await IPodSyncEngine.repairAlbumArtists(root: root) { progress in
            await progressRecorder.append(progress)
        }
        let active = try Data(contentsOf: itunes.appendingPathComponent("iTunesDB"))
        let progress = await progressRecorder.values

        XCTAssertEqual(result.repairedAlbums, 1)
        XCTAssertEqual(result.repairedTracks, 2)
        XCTAssertEqual(Set(result.library.tracks.map(\.artist)), ["Mac Miller", "Mac Miller & Ariana Grande"])
        XCTAssertEqual(Set(result.library.tracks.map(\.albumArtist)), ["Mac Miller"])
        XCTAssertEqual(Set(result.library.tracks.map(\.albumID)).count, 1)
        XCTAssertEqual(Set(result.library.tracks.map(\.artistID)).count, 2)
        XCTAssertEqual(result.library.tracks.map(\.artworkImageID), [40, 41])
        XCTAssertEqual(result.library.playlists, [playlist])
        let backupURL = try XCTUnwrap(result.backupURL)
        XCTAssertEqual(try Data(contentsOf: backupURL.appendingPathComponent("iTunesDB")), original)
        XCTAssertTrue(try ClassicDatabase.inspect(active, firewireID: firewireID).hash58Valid)
        XCTAssertEqual(progress.first?.stage, .scanningFiles)
        XCTAssertEqual(progress.first?.completedTracks, 0)
        XCTAssertTrue(progress.contains { $0.stage == .scanningFiles && $0.completedTracks == 2 })
        XCTAssertTrue(progress.contains { $0.stage == .analyzingAlbums })
        XCTAssertEqual(progress.last?.stage, .updatingDatabase)
        XCTAssertEqual(progress.last?.albumsFound, 1)
    }

    func testRepairDatabaseSignatureBacksUpAndReplacesOnlyAfterVerification() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let library = ClassicLibrary(
            name: "Test iPod",
            tracks: [artistTrack(id: 9, title: "Song", artist: "Artist", album: "Album")],
            playlists: []
        )
        var damaged = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        damaged[0x58] ^= 0xff
        let databaseURL = itunes.appendingPathComponent("iTunesDB")
        try damaged.write(to: databaseURL)

        let result = try await IPodSyncEngine.repairDatabaseSignature(root: root)
        let active = try Data(contentsOf: databaseURL)

        XCTAssertTrue(result.databaseChanged)
        XCTAssertEqual(result.library, library)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backupURL).appendingPathComponent("iTunesDB")), damaged)
        XCTAssertEqual(try ClassicDatabase.parse(active), library)
        XCTAssertTrue(try ClassicDatabase.inspect(active, firewireID: firewireID).hash58Valid)
    }

    func testSyncBacksUpDatabasePreservesLibraryAndAddsPlayablePath() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)

        let oldTrack = ClassicTrack(
            id: 9, databaseID: 9009, title: "Existing", artist: "Old Artist",
            album: "Old Album", genre: "", fileType: "AAC audio file",
            ipodPath: ":iPod_Control:Music:F00:OLD.m4a", byteCount: 10,
            durationMS: 1_000, trackNumber: 1, year: 2020, bitrate: 256,
            sampleRate: 44_100, dateAdded: 3_000_000_000, albumID: 2, artistID: 3,
            sourceURL: nil
        )
        let library = ClassicLibrary(name: "Test iPod", tracks: [oldTrack], playlists: [ClassicPlaylist(name: "Old Playlist", trackIDs: [9])])
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))

        let source = root.appendingPathComponent("Новая песня.wav")
        try waveData().write(to: source)
        let file = MusicFile(sourceURL: source, relativePath: source.lastPathComponent, byteCount: Int64(try Data(contentsOf: source).count))

        let result = try await IPodSyncEngine.sync(files: [file], root: root) { _ in }
        let updated = try ClassicDatabase.parse(Data(contentsOf: itunes.appendingPathComponent("iTunesDB")))

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(updated.tracks.count, 2)
        XCTAssertEqual(updated.tracks.first?.title, "Existing")
        XCTAssertEqual(updated.playlists, library.playlists)
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("iTunesDB")), original)
        let newPath = updated.tracks[1].ipodPath.replacingOccurrences(of: ":", with: "/")
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent(newPath).path))
    }

    /// Exercises the real transactional writer against a temporary iPod-shaped volume.
    func testVirtualIPodSyncFailureRestoresDatabaseAndRemovesPartialAudio() async throws {
        let fixture = try VirtualIPodFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let library = ClassicLibrary(name: "Test iPod", tracks: [], playlists: [])
        let original = try fixture.install(library)

        let source = fixture.root.appendingPathComponent("broken.wav")
        let audio = waveData()
        try audio.write(to: source)
        let file = MusicFile(
            sourceURL: source,
            relativePath: source.lastPathComponent,
            byteCount: Int64(audio.count + 1)
        )

        do {
            _ = try await IPodSyncEngine.sync(files: [file], root: fixture.root) { _ in }
            XCTFail("A mismatched source size must fail before activation")
        } catch let error as PodBridgeError {
            guard case .audioCopyVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.readDatabase(), original)
        let copiedFolder = fixture.root.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedFolder.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: copiedFolder, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(try IPodSyncEngine.library(root: fixture.root), library)
    }

    /// Ensures invalid artwork is rejected before ArtworkDB or iTunesDB is changed.
    func testVirtualIPodInvalidArtworkLeavesDatabaseAndArtworkUntouched() async throws {
        let fixture = try VirtualIPodFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var track = artistTrack(id: 9, title: "Song", artist: "Artist", album: "Mix")
        track.albumArtist = "Various Artists"
        track.compilation = true
        let library = ClassicLibrary(
            name: "Test iPod",
            tracks: [track],
            playlists: [ClassicPlaylist(name: "Mix", trackIDs: [track.id])]
        )
        let original = try fixture.install(library)

        do {
            _ = try await IPodSyncEngine.setPlaylistArtwork(
                index: 0,
                artwork: Data([0x00, 0x01, 0x02]),
                root: fixture.root
            )
            XCTFail("Invalid image data must be rejected")
        } catch let error as PodBridgeError {
            guard case .invalidArtwork = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.readDatabase(), original)
        let artworkRoot = fixture.root.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkRoot.path))
        XCTAssertEqual(try IPodSyncEngine.library(root: fixture.root), library)
    }

    /// Simulates the verification error shown by the app after database replacement.
    func testVirtualIPodInjectedVerificationFailureRestoresDatabaseAndAudio() async throws {
        let fixture = try VirtualIPodFixture()
        defer {
            IPodSyncEngine.setTestFailure(nil)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let original = try fixture.install(ClassicLibrary(name: "Test iPod", tracks: [], playlists: []))
        let source = fixture.root.appendingPathComponent("song.wav")
        let audio = waveData()
        try audio.write(to: source)
        let file = MusicFile(sourceURL: source, relativePath: source.lastPathComponent, byteCount: Int64(audio.count))

        IPodSyncEngine.setTestFailure(.afterDatabaseReplacement)
        do {
            _ = try await IPodSyncEngine.sync(files: [file], root: fixture.root) { _ in }
            XCTFail("Injected post-replacement failure must be surfaced")
        } catch let error as PodBridgeError {
            guard case .databaseVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.readDatabase(), original)
        let musicFolder = fixture.root.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: musicFolder, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(try IPodSyncEngine.library(root: fixture.root).tracks.count, 0)
    }

    /// Simulates an artwork cache failure after ArtworkDB has already been changed.
    func testVirtualIPodInjectedArtworkFailureRollsBackArtworkAndDatabase() async throws {
        let fixture = try VirtualIPodFixture()
        defer {
            IPodSyncEngine.setTestFailure(nil)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        var track = artistTrack(id: 9, title: "Song", artist: "Artist", album: "Album")
        track.artworkImageID = 0
        let library = ClassicLibrary(name: "Test iPod", tracks: [track], playlists: [])
        let original = try fixture.install(library)

        IPodSyncEngine.setTestFailure(.afterArtworkApply)
        do {
            _ = try await IPodSyncEngine.setTrackArtwork(
                id: track.id,
                artwork: try onePixelPNG(),
                root: fixture.root
            )
            XCTFail("Injected artwork failure must be surfaced")
        } catch let error as PodBridgeError {
            guard case .databaseVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.readDatabase(), original)
        let artworkRoot = fixture.root.appendingPathComponent("iPod_Control/Artwork", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkRoot.appendingPathComponent("ArtworkDB").path))
        XCTAssertEqual(try IPodSyncEngine.library(root: fixture.root), library)
    }

    /// Simulates cancellation/failure after activating a deletion database.
    func testVirtualIPodInjectedDeletionFailureRestoresDatabaseAndAudio() async throws {
        let fixture = try VirtualIPodFixture()
        defer {
            IPodSyncEngine.setTestFailure(nil)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let audio = waveData()
        let audioURL = fixture.root.appendingPathComponent("iPod_Control/Music/F00/OLD.wav")
        try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audio.write(to: audioURL)
        let track = ClassicTrack(
            id: 9, databaseID: 9009, title: "Existing", artist: "Artist", album: "Album",
            genre: "", fileType: "WAV audio file", ipodPath: ":iPod_Control:Music:F00:OLD.wav",
            byteCount: UInt32(audio.count), durationMS: 1_000, trackNumber: 1, year: 2020,
            bitrate: 64, sampleRate: 8_000, dateAdded: 3_000_000_000, sourceURL: nil
        )
        let library = ClassicLibrary(name: "Test iPod", tracks: [track], playlists: [])
        let original = try fixture.install(library)

        IPodSyncEngine.setTestFailure(.beforeAudioDelete)
        do {
            _ = try await IPodSyncEngine.deleteTrack(id: track.id, root: fixture.root, backupRoot: fixture.root.appendingPathComponent("Backups"))
            XCTFail("Injected deletion failure must be surfaced")
        } catch let error as PodBridgeError {
            guard case .databaseVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try fixture.readDatabase(), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try IPodSyncEngine.library(root: fixture.root), library)
    }

    func testRestoreReturnsToBackupAndRemovesOnlyTracksAddedAfterIt() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let library = ClassicLibrary(name: "Test iPod", tracks: [], playlists: [])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))
        let source = root.appendingPathComponent("New.wav")
        try waveData().write(to: source)
        let file = MusicFile(sourceURL: source, relativePath: source.lastPathComponent, byteCount: Int64(try Data(contentsOf: source).count))
        let sync = try await IPodSyncEngine.sync(files: [file], root: root) { _ in }
        let addedLibrary = try ClassicDatabase.parse(Data(contentsOf: itunes.appendingPathComponent("iTunesDB")))
        let addedURL = root.appendingPathComponent(addedLibrary.tracks[0].ipodPath.replacingOccurrences(of: ":", with: "/"))
        XCTAssertTrue(manager.fileExists(atPath: addedURL.path))

        let backup = try XCTUnwrap(IPodSyncEngine.backups(root: root).first { $0.url == sync.backupURL })
        let restored = try IPodSyncEngine.restore(backup: backup, root: root)

        XCTAssertEqual(restored.tracks, 0)
        XCTAssertEqual(restored.removedFiles, 1)
        XCTAssertEqual(try Data(contentsOf: itunes.appendingPathComponent("iTunesDB")), original)
        XCTAssertFalse(manager.fileExists(atPath: addedURL.path))
    }

    func testExactDuplicateReusesExistingTrackAndAddsItToImportedPlaylist() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let musicFolder = root.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try manager.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)

        let audio = waveData()
        let existingAudio = musicFolder.appendingPathComponent("OLD.wav")
        try audio.write(to: existingAudio)
        let oldTrack = ClassicTrack(
            id: 9, databaseID: 9009, title: "Already There", artist: "Artist",
            album: "Album", genre: "", fileType: "WAV audio file",
            ipodPath: ":iPod_Control:Music:F00:OLD.wav", byteCount: UInt32(audio.count),
            durationMS: 100, trackNumber: 1, year: 2020, bitrate: 64,
            sampleRate: 8_000, dateAdded: 3_000_000_000, albumID: 2, artistID: 3,
            sourceURL: nil
        )
        let library = ClassicLibrary(name: "Test iPod", tracks: [oldTrack], playlists: [])
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))

        let source = root.appendingPathComponent("Duplicate.wav")
        try audio.write(to: source)
        let file = MusicFile(sourceURL: source, relativePath: source.lastPathComponent, byteCount: Int64(audio.count))
        let playlist = SourcePlaylist(name: "Imported Mix", fileIndices: [0])

        let result = try await IPodSyncEngine.sync(files: [file], playlists: [playlist], root: root) { _ in }
        let updated = try ClassicDatabase.parse(Data(contentsOf: itunes.appendingPathComponent("iTunesDB")))

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.exactDuplicatesReused, 0)
        XCTAssertEqual(result.metadataDuplicatesReused, 0)
        XCTAssertEqual(updated.tracks.count, 2)
        XCTAssertEqual(updated.playlists.last?.trackIDs, [updated.tracks.last?.id].compactMap { $0 })
        XCTAssertEqual(try manager.contentsOfDirectory(at: musicFolder, includingPropertiesForKeys: nil).count, 1)
        XCTAssertEqual(updated.tracks.first?.album, "Album")
        XCTAssertNotEqual(updated.tracks.last?.album, "Imported Mix")
        XCTAssertEqual(try Data(contentsOf: result.backupURL.appendingPathComponent("iTunesDB")), original)
    }

    func testImportedPlaylistKeepsPerSongArtworkInsteadOfApplyingSharedPlaylistCover() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        try ClassicDatabase.build(
            library: ClassicLibrary(name: "Test iPod", tracks: [], playlists: []),
            firewireID: firewireID,
            databaseID: 123
        ).write(to: itunes.appendingPathComponent("iTunesDB"))

        let firstURL = root.appendingPathComponent("First Artist - First Song.wav")
        let secondURL = root.appendingPathComponent("Second Artist - Second Song.wav")
        let firstAudio = waveData()
        var secondAudio = waveData()
        secondAudio[secondAudio.count - 1] ^= 1
        try firstAudio.write(to: firstURL)
        try secondAudio.write(to: secondURL)
        let files = [
            MusicFile(sourceURL: firstURL, relativePath: firstURL.lastPathComponent, byteCount: Int64(firstAudio.count)),
            MusicFile(sourceURL: secondURL, relativePath: secondURL.lastPathComponent, byteCount: Int64(secondAudio.count))
        ]
        let playlistArtwork = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

        let result = try await IPodSyncEngine.sync(
            files: files,
            playlists: [SourcePlaylist(
                name: "My Playlist",
                fileIndices: [0, 1],
                artworkData: playlistArtwork,
                artworkFilename: "playlist.png"
            )],
            root: root
        ) { _ in }
        let library = try IPodSyncEngine.library(root: root)

        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(library.playlists, [ClassicPlaylist(name: "My Playlist", trackIDs: library.tracks.map(\.id))])
        XCTAssertFalse(library.tracks.allSatisfy { $0.album == "My Playlist" })
        XCTAssertNotEqual(Set(library.tracks.map(\.albumArtist)), ["Various Artists"])
        XCTAssertEqual(Set(library.tracks.map(\.compilation)), [false])
        XCTAssertTrue(library.tracks.allSatisfy { $0.artworkImageID == 0 })
        XCTAssertEqual(Set(library.tracks.map(\.artworkByteCount)), [0])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("iPod_Control/Artwork/F1060_1.ithmb").path
        ))
        XCTAssertEqual(
            IPodSyncEngine.customPlaylistArtworkAnchorIDs(root: root, library: library).count,
            0
        )
        XCTAssertTrue(try ClassicDatabase.inspect(
            Data(contentsOf: itunes.appendingPathComponent("iTunesDB")),
            firewireID: firewireID
        ).hash58Valid)

        let firstTrack = try XCTUnwrap(library.tracks.first)
        let secondTrack = try XCTUnwrap(library.tracks.last)
        let trackEdit = try await IPodSyncEngine.setTrackArtwork(
            id: firstTrack.id,
            artwork: playlistArtwork,
            root: root
        )
        XCTAssertNotEqual(trackEdit.library.tracks[0].artworkImageID, firstTrack.artworkImageID)
        XCTAssertEqual(trackEdit.library.tracks[1].artworkImageID, secondTrack.artworkImageID)

        let albumEdit = try await IPodSyncEngine.setAlbumArtwork(
            trackIDs: trackEdit.library.tracks.map(\.id),
            artwork: playlistArtwork,
            root: root
        )
        XCTAssertTrue(zip(trackEdit.library.tracks, albumEdit.library.tracks).allSatisfy { pair in
            pair.0.artworkImageID != pair.1.artworkImageID
        })
        XCTAssertTrue(try ClassicDatabase.inspect(
            Data(contentsOf: itunes.appendingPathComponent("iTunesDB")),
            firewireID: firewireID
        ).hash58Valid)

    }

    func testDuplicateInsideOneImportIsCopiedOnceAndReusedInPlaylist() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(name: "Test iPod", tracks: [], playlists: []),
            firewireID: firewireID,
            databaseID: 123
        )
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))

        let audio = waveData()
        let firstURL = root.appendingPathComponent("First.wav")
        let secondURL = root.appendingPathComponent("Second.wav")
        try audio.write(to: firstURL)
        try audio.write(to: secondURL)
        let files = [firstURL, secondURL].map {
            MusicFile(sourceURL: $0, relativePath: $0.lastPathComponent, byteCount: Int64(audio.count))
        }
        let playlist = SourcePlaylist(name: "Repeated Entry", fileIndices: [0, 1])

        let result = try await IPodSyncEngine.sync(files: files, playlists: [playlist], root: root) { _ in }
        let updated = try ClassicDatabase.parse(Data(contentsOf: itunes.appendingPathComponent("iTunesDB")))

        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.exactDuplicatesReused, 1)
        XCTAssertEqual(updated.tracks.count, 1)
        XCTAssertEqual(updated.playlists.last?.trackIDs, [updated.tracks[0].id, updated.tracks[0].id])
    }

    func testDeleteOneTrackBacksUpAudioAndDatabaseThenRestoresExactly() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let music = root.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        let phoneBackups = root.appendingPathComponent("Phone Backups", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try manager.createDirectory(at: music, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        let audio = waveData()
        let audioURL = music.appendingPathComponent("DELETE.wav")
        try audio.write(to: audioURL)
        let track = ClassicTrack(
            id: 9, databaseID: 9009, title: "Delete Me", artist: "Artist",
            album: "Album", genre: "", fileType: "WAV audio file",
            ipodPath: ":iPod_Control:Music:F00:DELETE.wav", byteCount: UInt32(audio.count),
            durationMS: 100, trackNumber: 1, year: 2020, bitrate: 64,
            sampleRate: 8_000, dateAdded: 3_000_000_000, albumID: 2, artistID: 3,
            sourceURL: nil
        )
        let library = ClassicLibrary(
            name: "Test iPod",
            tracks: [track],
            playlists: [ClassicPlaylist(name: "Playlist", trackIDs: [9])]
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))

        let deletion = try await IPodSyncEngine.deleteTrack(id: 9, root: root, backupRoot: phoneBackups)
        let afterDeletion = try ClassicDatabase.parse(Data(contentsOf: itunes.appendingPathComponent("iTunesDB")))

        XCTAssertEqual(deletion.deletedTrack, track)
        XCTAssertEqual(deletion.freedBytes, UInt32(audio.count))
        XCTAssertTrue(afterDeletion.tracks.isEmpty)
        XCTAssertEqual(afterDeletion.playlists, [ClassicPlaylist(name: "Playlist", trackIDs: [])])
        XCTAssertFalse(manager.fileExists(atPath: audioURL.path))
        XCTAssertTrue(manager.fileExists(atPath: deletion.backup.folderURL.appendingPathComponent("iTunesDB").path))
        XCTAssertEqual(IPodSyncEngine.deletionBackups(backupRoot: phoneBackups).count, 1)

        let restored = try await IPodSyncEngine.restoreDeletion(deletion.backup, root: root)

        XCTAssertEqual(restored, library)
        XCTAssertEqual(try Data(contentsOf: itunes.appendingPathComponent("iTunesDB")), original)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertFalse(manager.fileExists(atPath: deletion.backup.folderURL.path))
    }

    func testBackupNamesRemainUniqueWhenCreatedInTheSameSecond() throws {
        let fixture = try VirtualIPodFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try fixture.install(ClassicLibrary(name: "Test iPod", tracks: [], playlists: []))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LocalIPodVolumeStore(root: fixture.root, now: { fixedDate })

        let first = try store.createBackup(of: original)
        let second = try store.createBackup(of: original)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("iTunesDB")), original)
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("iTunesDB")), original)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-2"))
    }

    func testTransactionSurfacesDatabaseRollbackFailure() throws {
        let fixture = try VirtualIPodFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try fixture.install(ClassicLibrary(name: "Test iPod", tracks: [], playlists: []))
        let store = LocalIPodVolumeStore(root: fixture.root)
        let transaction = try IPodDatabaseTransaction(
            store: store,
            original: original,
            temporaryName: "iTunesDB.rollback-test.tmp"
        )
        try transaction.stage(Data("replacement".utf8))
        try transaction.activate()
        try FileManager.default.removeItem(at: fixture.itunes)

        XCTAssertThrowsError(try transaction.rollback()) { error in
            guard case PodBridgeError.restoreFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRestoreDeletionFailureRestoresDeletedDatabaseAndKeepsBackup() async throws {
        let fixture = try makeDeletionFixture()
        defer {
            IPodSyncEngine.setTestFailure(nil)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let deletion = try await IPodSyncEngine.deleteTrack(
            id: fixture.track.id,
            root: fixture.root,
            backupRoot: fixture.phoneBackups
        )
        let deletedDatabase = try Data(contentsOf: fixture.databaseURL)

        IPodSyncEngine.setTestFailure(.afterDatabaseReplacement)
        do {
            _ = try await IPodSyncEngine.restoreDeletion(deletion.backup, root: fixture.root)
            XCTFail("Injected restore failure must be surfaced")
        } catch let error as PodBridgeError {
            guard case .databaseVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), deletedDatabase)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deletion.backup.folderURL.path))
    }

    func testPermanentBatchDeletionFailureRestoresDatabaseAndLeavesAudio() async throws {
        let fixture = try makeDeletionFixture()
        defer {
            IPodSyncEngine.setTestFailure(nil)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        IPodSyncEngine.setTestFailure(.afterDatabaseReplacement)

        do {
            _ = try await IPodSyncEngine.deleteTracksPermanently(ids: [fixture.track.id], root: fixture.root)
            XCTFail("Injected deletion failure must be surfaced")
        } catch let error as PodBridgeError {
            guard case .databaseVerificationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), fixture.originalDatabase)
        XCTAssertEqual(try Data(contentsOf: fixture.audioURL), fixture.audio)
    }

    func testRenamePlaylistAndEditExistingTrackCreateVerifiedDatabaseBackups() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        var track = ClassicTrack(
            id: 9, databaseID: 9009, title: "Old Title", artist: "Old Artist",
            album: "Old Playlist", genre: "Rock", fileType: "AAC audio file",
            ipodPath: ":iPod_Control:Music:F00:OLD.m4a", byteCount: 100,
            durationMS: 1_000, trackNumber: 1, year: 2020, bitrate: 256,
            sampleRate: 44_100, dateAdded: 3_000_000_000, albumID: 2, artistID: 3,
            sourceURL: nil, albumArtist: "Various Artists", compilation: true
        )
        let library = ClassicLibrary(
            name: "Test iPod",
            tracks: [track],
            playlists: [ClassicPlaylist(name: "Old Playlist", trackIDs: [9])]
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        try original.write(to: itunes.appendingPathComponent("iTunesDB"))

        let renamed = try await IPodSyncEngine.renamePlaylist(index: 0, name: "New Playlist", root: root)
        let update = ClassicDatabase.TrackMetadataUpdate(
            title: "New Title", artist: "New Artist", album: "New Album",
            genre: "Pop", year: 2026, trackNumber: 4
        )
        let edited = try await IPodSyncEngine.editTrackMetadata(id: 9, update: update, root: root)
        track = try XCTUnwrap(edited.library.tracks.first)

        XCTAssertEqual(renamed.library.playlists[0].name, "New Playlist")
        XCTAssertEqual(renamed.library.tracks[0].album, "New Playlist")
        XCTAssertEqual(edited.library.playlists[0].name, "New Playlist")
        XCTAssertEqual(track.title, "New Title")
        XCTAssertEqual(track.artist, "New Artist")
        XCTAssertEqual(track.album, "New Album")
        XCTAssertEqual(track.genre, "Pop")
        XCTAssertEqual(track.year, 2026)
        XCTAssertEqual(track.trackNumber, 4)
        XCTAssertNotEqual(renamed.backupURL, edited.backupURL)
        XCTAssertEqual(try Data(contentsOf: renamed.backupURL.appendingPathComponent("iTunesDB")), original)
        XCTAssertTrue(try ClassicDatabase.inspect(
            Data(contentsOf: itunes.appendingPathComponent("iTunesDB")),
            firewireID: firewireID
        ).hash58Valid)
    }

    func testEditCompilationThenDeletePlaylistAndAllTracksWithoutAudioBackup() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let music = root.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try manager.createDirectory(at: music, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        let audio = waveData()
        let firstURL = music.appendingPathComponent("FIRST.wav")
        let secondURL = music.appendingPathComponent("SECOND.wav")
        try audio.write(to: firstURL)
        try audio.write(to: secondURL)
        let tracks = [
            ClassicTrack(
                id: 9, databaseID: 9009, title: "First", artist: "Artist", album: "Old Album",
                genre: "Rock", fileType: "WAV audio file", ipodPath: ":iPod_Control:Music:F00:FIRST.wav",
                byteCount: UInt32(audio.count), durationMS: 100, trackNumber: 1, year: 2020,
                bitrate: 64, sampleRate: 8_000, dateAdded: 3_000_000_000,
                albumID: 2, artistID: 3, sourceURL: nil
            ),
            ClassicTrack(
                id: 11, databaseID: 9011, title: "Second", artist: "Other Artist", album: "Old Album",
                genre: "Rock", fileType: "WAV audio file", ipodPath: ":iPod_Control:Music:F00:SECOND.wav",
                byteCount: UInt32(audio.count), durationMS: 100, trackNumber: 2, year: 2020,
                bitrate: 64, sampleRate: 8_000, dateAdded: 3_000_000_000,
                albumID: 2, artistID: 4, sourceURL: nil
            )
        ]
        let library = ClassicLibrary(
            name: "Test iPod",
            tracks: tracks,
            playlists: [ClassicPlaylist(name: "Album Mix", trackIDs: [11, 9])]
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
            .write(to: itunes.appendingPathComponent("iTunesDB"))

        let albumEdit = try await IPodSyncEngine.editAlbumMetadata(
            trackIDs: [9, 11],
            update: .init(
                album: "Album Mix",
                albumArtist: "Various Artists",
                genre: "Pop",
                year: 2026,
                compilation: true
            ),
            root: root
        )
        let albumIDs = Set(albumEdit.library.tracks.map(\.albumID))
        let artistIDs = Set(albumEdit.library.tracks.map(\.artistID))
        XCTAssertEqual(Set(albumEdit.library.tracks.map(\.album)), ["Album Mix"])
        XCTAssertEqual(Set(albumEdit.library.tracks.map(\.artist)), ["Artist", "Other Artist"])
        XCTAssertEqual(Set(albumEdit.library.tracks.map(\.albumArtist)), ["Various Artists"])
        XCTAssertEqual(Set(albumEdit.library.tracks.map(\.compilation)), [true])
        XCTAssertEqual(Set(albumEdit.library.tracks.map(\.genre)), ["Pop"])
        XCTAssertEqual(Set(albumEdit.library.tracks.map(\.year)), [2026])
        XCTAssertEqual(albumIDs.count, 1)
        XCTAssertEqual(artistIDs.count, 2)
        let backupCountBeforeDeletion = try IPodSyncEngine.backups(root: root).count

        let deletion = try await IPodSyncEngine.deletePlaylistAndTracks(index: 0, root: root)
        let finalLibrary = try IPodSyncEngine.library(root: root)

        XCTAssertEqual(deletion.removedTracks.count, 2)
        XCTAssertEqual(deletion.freedBytes, UInt64(audio.count * 2))
        XCTAssertEqual(deletion.failedFileDeletions, 0)
        XCTAssertTrue(finalLibrary.tracks.isEmpty)
        XCTAssertTrue(finalLibrary.playlists.isEmpty)
        XCTAssertFalse(manager.fileExists(atPath: firstURL.path))
        XCTAssertFalse(manager.fileExists(atPath: secondURL.path))
        XCTAssertEqual(try IPodSyncEngine.backups(root: root).count, backupCountBeforeDeletion)
    }

    func testFindArtworkReplacesPlaylistCoverWithOriginalSongReleaseCover() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
        let track = ClassicTrack(
            id: 9, databaseID: 9009, title: "Song", artist: "Test Artist",
            album: "My Playlist", genre: "Rock", fileType: "AAC audio file",
            ipodPath: ":iPod_Control:Music:F00:SONG.m4a", byteCount: 100,
            durationMS: 1_000, trackNumber: 1, year: 2026, bitrate: 256,
            sampleRate: 44_100, dateAdded: 3_000_000_000, albumID: 2, artistID: 3,
            artworkImageID: 55, artworkByteCount: 10, sourceURL: nil,
            albumArtist: "", compilation: false
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        try ClassicDatabase.build(
            library: ClassicLibrary(
                name: "Test iPod",
                tracks: [track],
                playlists: [ClassicPlaylist(name: "My Playlist", trackIDs: [9])]
            ),
            firewireID: firewireID,
            databaseID: 123
        ).write(to: itunes.appendingPathComponent("iTunesDB"))

        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkURLProtocol.self]
        ArtworkURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "musicbrainz.org" {
                let json = """
                {"recordings":[{"score":100,"title":"Song","artist-credit":[{"name":"Test Artist"}],"releases":[{"title":"Original Single","status":"Official","date":"2020-01-01","release-group":{"id":"11111111-2222-3333-4444-555555555555","primary-type":"Single","secondary-types":[]}}]}]}
                """
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            if url.host == "coverartarchive.org" {
                let json = """
                {"images":[{"image":"https://images.example/cover.png","thumbnails":{"500":"https://images.example/cover.png"},"front":true,"approved":true}]}
                """
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, png)
        }
        defer { ArtworkURLProtocol.handler = nil }
        let lookup = ArtworkLookupService(
            session: URLSession(configuration: configuration),
            observesRateLimit: false
        )

        let result = try await IPodSyncEngine.findMissingArtwork(root: root, lookup: lookup) { _ in }
        let library = try IPodSyncEngine.library(root: root)

        XCTAssertEqual(result.searchedItems, 1)
        XCTAssertEqual(result.matchedItems, 1)
        XCTAssertEqual(result.updatedTracks, 1)
        XCTAssertGreaterThan(try XCTUnwrap(library.tracks.first).artworkImageID, 55)
        XCTAssertEqual(try XCTUnwrap(library.tracks.first).album, "My Playlist")
        XCTAssertFalse(try XCTUnwrap(library.tracks.first).compilation)
        XCTAssertEqual(library.playlists, [ClassicPlaylist(name: "My Playlist", trackIDs: [9])])
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("iPod_Control/Artwork/ArtworkDB").path))
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("iPod_Control/Artwork/F1060_1.ithmb").path))
        XCTAssertTrue(try ClassicDatabase.inspect(
            Data(contentsOf: itunes.appendingPathComponent("iTunesDB")),
            firewireID: firewireID
        ).hash58Valid)

        let firstOnlineArtworkID = try XCTUnwrap(library.tracks.first).artworkImageID
        let forced = try await IPodSyncEngine.replaceSongArtworkFromInternet(
            trackIDs: [9],
            root: root,
            lookup: lookup
        ) { _ in }
        let forcedLibrary = try IPodSyncEngine.library(root: root)
        XCTAssertEqual(forced.searchedItems, 1)
        XCTAssertEqual(forced.updatedTracks, 1)
        XCTAssertGreaterThan(try XCTUnwrap(forcedLibrary.tracks.first).artworkImageID, firstOnlineArtworkID)
        XCTAssertTrue(try ClassicDatabase.inspect(
            Data(contentsOf: itunes.appendingPathComponent("iTunesDB")),
            firewireID: firewireID
        ).hash58Valid)
    }

    private func waveData() -> Data {
        let sampleRate: UInt32 = 8_000
        let samples = Data(repeating: 128, count: 800)
        var writer = BinaryWriter()
        writer.tag("RIFF"); writer.u32(UInt32(36 + samples.count)); writer.tag("WAVE")
        writer.tag("fmt "); writer.u32(16); writer.u16(1); writer.u16(1)
        writer.u32(sampleRate); writer.u32(sampleRate); writer.u16(1); writer.u16(8)
        writer.tag("data"); writer.u32(UInt32(samples.count)); writer.bytes(samples)
        return writer.data
    }

    private func onePixelPNG() throws -> Data {
        guard let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") else {
            throw PodBridgeError.invalidArtwork
        }
        return data
    }

    private func makeDeletionFixture() throws -> (
        root: URL,
        databaseURL: URL,
        audioURL: URL,
        phoneBackups: URL,
        originalDatabase: Data,
        audio: Data,
        track: ClassicTrack
    ) {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let music = root.appendingPathComponent("iPod_Control/Music/F00", isDirectory: true)
        let phoneBackups = root.appendingPathComponent("Phone Backups", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try manager.createDirectory(at: music, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
        let audio = waveData()
        let audioURL = music.appendingPathComponent("DELETE.wav")
        try audio.write(to: audioURL)
        let track = ClassicTrack(
            id: 9, databaseID: 9009, title: "Delete Me", artist: "Artist",
            album: "Album", genre: "", fileType: "WAV audio file",
            ipodPath: ":iPod_Control:Music:F00:DELETE.wav", byteCount: UInt32(audio.count),
            durationMS: 100, trackNumber: 1, year: 2020, bitrate: 64,
            sampleRate: 8_000, dateAdded: 3_000_000_000, albumID: 2, artistID: 3,
            sourceURL: nil
        )
        let library = ClassicLibrary(
            name: "Test iPod",
            tracks: [track],
            playlists: [ClassicPlaylist(name: "Playlist", trackIDs: [track.id])]
        )
        let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])
        let originalDatabase = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        let databaseURL = itunes.appendingPathComponent("iTunesDB")
        try originalDatabase.write(to: databaseURL)
        return (root, databaseURL, audioURL, phoneBackups, originalDatabase, audio, track)
    }

    private func artistTrack(
        id: UInt32,
        title: String,
        artist: String,
        album: String
    ) -> ClassicTrack {
        ClassicTrack(
            id: id,
            databaseID: id == 0 ? 0 : UInt64(id) * 1_000,
            title: title,
            artist: artist,
            album: album,
            genre: "R&B",
            fileType: "AAC audio file",
            ipodPath: id == 0 ? "" : ":iPod_Control:Music:F00:\(id).m4a",
            byteCount: 100,
            durationMS: 180_000,
            trackNumber: id,
            year: 2023,
            bitrate: 256,
            sampleRate: 44_100,
            dateAdded: 3_000_000_000,
            sourceURL: nil
        )
    }
}

private actor AlbumRepairProgressRecorder {
    private var storage: [IPodSyncEngine.AlbumArtistRepairProgress] = []

    var values: [IPodSyncEngine.AlbumArtistRepairProgress] { storage }

    func append(_ progress: IPodSyncEngine.AlbumArtistRepairProgress) {
        storage.append(progress)
    }
}

private final class ArtworkURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Minimal on-disk iPod volume used by integration tests.
///
/// The fixture intentionally uses the same folder names and signed database
/// bytes as a physical Classic. This catches failures in file replacement,
/// rollback, and path handling without requiring hardware.
private struct VirtualIPodFixture {
    let root: URL
    let itunes: URL
    let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
        try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )
    }

    @discardableResult
    func install(_ library: ClassicLibrary) throws -> Data {
        let data = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 123)
        try data.write(to: itunes.appendingPathComponent("iTunesDB"), options: .atomic)
        return data
    }

    func readDatabase() throws -> Data {
        try Data(contentsOf: itunes.appendingPathComponent("iTunesDB"), options: .mappedIfSafe)
    }
}
