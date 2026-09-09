// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import XCTest
@testable import PodBridge

final class ClassicDatabaseTests: XCTestCase {
    func testUnsignedDeviceDatabaseIsPreservedWithoutHash58() throws {
        let database = Data((0..<256).map(UInt8.init))
        XCTAssertEqual(try Hash58.sign(database, firewireID: Data()), database)
        XCTAssertTrue(try Hash58.verify(database, firewireID: Data()))
    }

    func testStoringFirewireIDPersistsItInSysInfo() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
        try manager.createDirectory(at: device, withIntermediateDirectories: true)
        try "ModelNumStr: MZ555\nFirewireGuid: 0xFFFFFFFFFFFFFFFF\n".write(
            to: device.appendingPathComponent("SysInfo"),
            atomically: true,
            encoding: .utf8
        )

        try ClassicDatabase.storeFirewireID("000A27001A2B3C4D", root: root)

        let sysInfo = try String(contentsOf: device.appendingPathComponent("SysInfo"), encoding: .utf8)
        XCTAssertTrue(sysInfo.contains("ModelNumStr: MZ555"))
        XCTAssertTrue(sysInfo.contains("FirewireGuid: 0x000a27001a2b3c4d"))
        XCTAssertEqual(try ClassicDatabase.firewireID(at: root), firewireID)
    }

    func testResigningRepairsHashWithoutChangingLibrary() throws {
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [track(id: 7, title: "Song", artist: "Artist", album: "Album")],
            playlists: []
        )
        var database = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        database[0x58] ^= 0xff
        XCTAssertFalse(try ClassicDatabase.inspect(database, firewireID: firewireID).hash58Valid)

        let repaired = try ClassicDatabase.resigning(existing: database, firewireID: firewireID)

        XCTAssertEqual(repaired.library, library)
        XCTAssertTrue(try ClassicDatabase.inspect(repaired.data, firewireID: firewireID).hash58Valid)
    }

    private let firewireID = Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])

    func testHash58MatchesIndependentVector() throws {
        var database = Data(repeating: 0, count: 244)
        database.replaceSubrange(0..<4, with: Data("mhbd".utf8))
        try database.setLittleUInt32(244, at: 4)

        let signed = try Hash58.sign(database, firewireID: firewireID)

        XCTAssertEqual(signed[0x58..<0x6c].map { String(format: "%02x", $0) }.joined(), "d84bca1d95897b7877c0258e91399e18b835c675")
    }

    func testUnicodeAlbumRoundTrips() throws {
        let library = ClassicLibrary(
            name: "Димин iPod",
            tracks: [track(id: 10, title: "Песня №1", artist: "Ёлка", album: "Тёплый альбом")],
            playlists: [ClassicPlaylist(name: "Избранное", trackIDs: [10])]
        )

        let parsed = try ClassicDatabase.parse(ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 42))

        XCTAssertEqual(parsed, library)
    }

    func testMergePreservesExistingTrackPlaylistAndUnknownSectionBytes() throws {
        let existingTrack = track(id: 7, title: "Old", artist: "Artist", album: "Album")
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [existingTrack],
            playlists: [ClassicPlaylist(name: "Keep Me", trackIDs: [7])]
        )
        var original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        var unknown = BinaryWriter()
        unknown.tag("mhsd"); unknown.u32(96); unknown.u32(96); unknown.u32(9); unknown.tag("KEEP"); unknown.zeros(76)
        original.append(unknown.data)
        try original.setLittleUInt32(UInt32(original.count), at: 8)
        original = try Hash58.sign(original, firewireID: firewireID)
        let oldTrackRecord = try record(tag: "mhit", in: original, occurrence: 0)
        let oldPlaylistRecord = try record(tag: "mhyp", in: original, occurrence: 1)
        guard let masterTag = original.range(of: Data("mhyp".utf8)) else { throw PodBridgeError.invalidDatabase }
        original[masterTag.lowerBound + 60] = 0xa5
        original = try Hash58.sign(original, firewireID: firewireID)

        let addition = track(id: 0, title: "New", artist: "New Artist", album: "New Album")
        let result = try ClassicDatabase.merge(existing: original, additions: [addition], firewireID: firewireID)

        XCTAssertNotNil(result.data.range(of: oldTrackRecord))
        XCTAssertNotNil(result.data.range(of: oldPlaylistRecord))
        XCTAssertNotNil(result.data.range(of: unknown.data))
        XCTAssertEqual(result.library.tracks.map(\.title), ["Old", "New"])
        XCTAssertEqual(result.library.playlists, library.playlists)
        guard let mergedMasterTag = result.data.range(of: Data("mhyp".utf8)) else { throw PodBridgeError.invalidDatabase }
        XCTAssertEqual(result.data[mergedMasterTag.lowerBound + 60], 0xa5)
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertTrue(diagnostics.masterPlaylistFound)
        XCTAssertEqual(diagnostics.masterPlaylistMembers, 2)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertTrue(diagnostics.jumpTablesValid)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testTypeThreeSectionDoesNotReplaceMainPlaylistSection() throws {
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [track(id: 7, title: "Old", artist: "Artist", album: "Album")],
            playlists: [ClassicPlaylist(name: "Keep Me", trackIDs: [7])]
        )
        var database = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        guard let playlistSection = topLevelSection(type: 2, in: database) else { throw PodBridgeError.invalidDatabase }
        var typeThree = Data(database[playlistSection])
        try typeThree.setLittleUInt32(3, at: 12)
        let listOffset = Int(try typeThree.littleUInt32(at: 4))
        typeThree.replaceSubrange(listOffset..<(listOffset + 4), with: Data("skip".utf8))
        database.append(typeThree)
        try database.setLittleUInt32(UInt32(database.count), at: 8)
        database = try Hash58.sign(database, firewireID: firewireID)

        let parsed = try ClassicDatabase.parse(database)

        XCTAssertEqual(parsed.name, "My iPod")
        XCTAssertEqual(parsed.playlists.map(\.name), ["Keep Me"])
    }

    func testMergeAddsImportedPlaylistInSourceOrder() throws {
        let library = ClassicLibrary(name: "My iPod", tracks: [], playlists: [])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        let first = track(id: 0, title: "First", artist: "A", album: "X")
        let second = track(id: 0, title: "Second", artist: "B", album: "Y")

        let result = try ClassicDatabase.merge(
            existing: original,
            additions: [first, second],
            pendingPlaylists: [.init(name: "Apple Mix", additionIndices: [1, 0])],
            firewireID: firewireID
        )
        let parsed = try ClassicDatabase.parse(result.data)

        XCTAssertEqual(parsed.playlists.map(\.name), ["Apple Mix"])
        XCTAssertEqual(parsed.playlists[0].trackIDs, [result.library.tracks[1].id, result.library.tracks[0].id])
    }

    func testRemovingTrackUpdatesBothMastersSortIndexesAndUserPlaylists() throws {
        let first = track(id: 7, title: "Alpha", artist: "Artist", album: "Album")
        let removed = track(id: 9, title: "Beta", artist: "Artist", album: "Album")
        let last = track(id: 11, title: "Gamma", artist: "Other", album: "Other Album")
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [first, removed, last],
            playlists: [
                ClassicPlaylist(name: "Keep Order", trackIDs: [11, 9, 7]),
                ClassicPlaylist(name: "Repeated", trackIDs: [9, 9, 7])
            ]
        )
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)

        let result = try ClassicDatabase.removingTrack(existing: original, trackID: 9, firewireID: firewireID)
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)

        XCTAssertEqual(result.removedTrack, removed)
        XCTAssertEqual(result.library.tracks.map(\.id), [7, 11])
        XCTAssertEqual(result.library.playlists[0].trackIDs, [11, 7])
        XCTAssertEqual(result.library.playlists[1].trackIDs, [7])
        XCTAssertEqual(diagnostics.masterPlaylistMembers, 2)
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertTrue(diagnostics.jumpTablesValid)
        XCTAssertTrue(diagnostics.hash58Valid)
        for type in [UInt32(3), UInt32(2)] {
            XCTAssertEqual(try masterTrackIDs(sectionType: type, in: result.data), [7, 11])
        }
    }

    func testEditingTrackMetadataReusesEntitiesAndRebuildsSortIndexes() throws {
        var edited = track(id: 7, title: "Zulu", artist: "Old Artist", album: "Old Album")
        edited.albumID = 2
        edited.artistID = 3
        var existing = track(id: 9, title: "Alpha", artist: "New Artist", album: "New Album")
        existing.albumID = 4
        existing.artistID = 5
        let library = ClassicLibrary(name: "My iPod", tracks: [edited, existing], playlists: [])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        let update = ClassicDatabase.TrackMetadataUpdate(
            title: "A New Title",
            artist: "New Artist",
            album: "New Album",
            genre: "Electronic",
            year: 2025,
            trackNumber: 12
        )

        let result = try ClassicDatabase.editingTrackMetadata(
            existing: original,
            trackID: 7,
            update: update,
            firewireID: firewireID
        )
        let changed = try XCTUnwrap(result.library.tracks.first { $0.id == 7 })
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)

        XCTAssertEqual(changed.title, "A New Title")
        XCTAssertEqual(changed.artist, "New Artist")
        XCTAssertEqual(changed.album, "New Album")
        XCTAssertEqual(changed.genre, "Electronic")
        XCTAssertEqual(changed.year, 2025)
        XCTAssertEqual(changed.trackNumber, 12)
        XCTAssertEqual(changed.albumID, 4)
        XCTAssertEqual(changed.artistID, 5)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertTrue(diagnostics.jumpTablesValid)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testBatchAlbumEditUpdatesAllTracksInOneVerifiedPass() throws {
        var first = track(id: 7, title: "First", artist: "Artist A", album: "Old Mix")
        var second = track(id: 9, title: "Second", artist: "Artist B", album: "Old Mix")
        first.albumID = 20; first.artistID = 30; first.compilation = true; first.albumArtist = "Various Artists"
        second.albumID = 20; second.artistID = 31; second.compilation = true; second.albumArtist = "Various Artists"
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(
                name: "My iPod",
                tracks: [first, second],
                playlists: [ClassicPlaylist(name: "Old Mix", trackIDs: [9, 7])]
            ),
            firewireID: firewireID,
            databaseID: 99
        )

        let result = try ClassicDatabase.editingAlbumMetadata(
            existing: original,
            trackIDs: [7, 9],
            album: "Road Mix",
            albumArtist: "Various Artists",
            genre: "Pop",
            year: 2026,
            compilation: true,
            firewireID: firewireID
        )

        XCTAssertEqual(Set(result.library.tracks.map(\.album)), ["Road Mix"])
        XCTAssertEqual(Set(result.library.tracks.map(\.genre)), ["Pop"])
        XCTAssertEqual(Set(result.library.tracks.map(\.year)), [2026])
        XCTAssertEqual(result.library.tracks.map(\.title), ["First", "Second"])
        XCTAssertEqual(result.library.tracks.map(\.artist), ["Artist A", "Artist B"])
        XCTAssertEqual(result.library.playlists[0].trackIDs, [9, 7])
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertTrue(diagnostics.jumpTablesValid)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testAlbumEditMergesDuplicateSourceAndExistingDestinationCards() throws {
        var oldFirst = track(id: 7, title: "Come Back to Earth", artist: "Mac Miller", album: "The Divine Feminine")
        var oldDuplicate = track(id: 9, title: "Dang!", artist: "Mac Miller", album: "The Divine Feminine")
        var alreadyRenamed = track(id: 11, title: "Favorite Part", artist: "Mac Miller & Ariana Grande", album: "The Divine Feminine")
        oldFirst.albumID = 20; oldFirst.artistID = 30; oldFirst.albumArtist = "Mac Miller & Ariana Grande"
        oldDuplicate.albumID = 21; oldDuplicate.artistID = 30; oldDuplicate.albumArtist = "Mac Miller & Ariana Grande"
        alreadyRenamed.albumID = 22; alreadyRenamed.artistID = 31; alreadyRenamed.albumArtist = "Mac Miller"
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(
                name: "My iPod",
                tracks: [oldFirst, oldDuplicate, alreadyRenamed],
                playlists: []
            ),
            firewireID: firewireID,
            databaseID: 99
        )

        let result = try ClassicDatabase.editingAlbumMetadata(
            existing: original,
            trackIDs: [7],
            album: "The Divine Feminine",
            albumArtist: "Mac Miller",
            artist: "Mac Miller",
            firewireID: firewireID
        )

        XCTAssertEqual(Set(result.library.tracks.map(\.albumArtist)), ["Mac Miller"])
        XCTAssertEqual(Set(result.library.tracks.map(\.albumID)), [20])
        XCTAssertEqual(Set(result.library.tracks.map(\.artist)), ["Mac Miller"])
        XCTAssertEqual(Set(result.library.tracks.map(\.artistID)), [30])
        XCTAssertEqual(try albumEntityIDs(in: result.data), [20])
        XCTAssertEqual(try artistEntityIDs(in: result.data), [30])
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertTrue(diagnostics.jumpTablesValid)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testAtomicAlbumNormalizationMergesEditionCardsAndPreservesSongArtists() throws {
        var standardOne = track(id: 7, title: "One", artist: "Artist", album: "The Record")
        var standardTwo = track(id: 9, title: "Two", artist: "Artist feat. Guest", album: "The Record")
        var deluxeBonus = track(id: 11, title: "Bonus", artist: "Artist", album: "The Record (Deluxe Edition)")
        standardOne.albumID = 20; standardOne.artistID = 30; standardOne.albumArtist = "Artist"
        standardTwo.albumID = 20; standardTwo.artistID = 31; standardTwo.albumArtist = "Artist"
        deluxeBonus.albumID = 21; deluxeBonus.artistID = 30; deluxeBonus.albumArtist = "Artist"
        let playlist = ClassicPlaylist(name: "Favorites", trackIDs: [11, 7])
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(
                name: "My iPod",
                tracks: [standardOne, standardTwo, deluxeBonus],
                playlists: [playlist]
            ),
            firewireID: firewireID,
            databaseID: 99
        )

        let result = try ClassicDatabase.normalizingAlbumArtists(
            existing: original,
            updates: [.init(
                trackIDs: [7, 9, 11],
                album: "The Record (Deluxe Edition)",
                artist: "Artist",
                compilation: true
            )],
            firewireID: firewireID
        )

        XCTAssertEqual(Set(result.library.tracks.map(\.album)), ["The Record (Deluxe Edition)"])
        XCTAssertEqual(Set(result.library.tracks.map(\.albumArtist)), ["Artist"])
        XCTAssertTrue(result.library.tracks.allSatisfy(\.compilation))
        XCTAssertEqual(Set(result.library.tracks.map(\.albumID)).count, 1)
        XCTAssertEqual(result.library.tracks.map(\.artist), ["Artist", "Artist feat. Guest", "Artist"])
        XCTAssertEqual(result.library.playlists, [playlist])
        XCTAssertEqual(try albumEntityIDs(in: result.data).count, 1)
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertTrue(diagnostics.jumpTablesValid)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testAlbumNormalizationPreservesStaleArtworkByteCountWhenArtworkIDIsZero() throws {
        var song = track(id: 7, title: "Song", artist: "Artist", album: "Old Album")
        song.albumID = 20
        song.artistID = 30
        let built = try ClassicDatabase.build(
            library: ClassicLibrary(name: "My iPod", tracks: [song], playlists: []),
            firewireID: firewireID,
            databaseID: 99
        )
        var appleDatabase = built
        let trackOffset = try XCTUnwrap(appleDatabase.range(of: Data("mhit".utf8))?.lowerBound)
        try appleDatabase.setLittleUInt32(777, at: trackOffset + 0x80)
        appleDatabase = try Hash58.sign(appleDatabase, firewireID: firewireID)
        let parsed = try ClassicDatabase.parse(appleDatabase)
        XCTAssertEqual(parsed.tracks.first?.artworkImageID, 0)
        XCTAssertEqual(parsed.tracks.first?.artworkByteCount, 777)

        let result = try ClassicDatabase.normalizingAlbumArtists(
            existing: appleDatabase,
            updates: [.init(trackIDs: [7], album: "New Album", artist: "Artist")],
            firewireID: firewireID
        )

        XCTAssertEqual(result.library.tracks.first?.album, "New Album")
        XCTAssertEqual(result.library.tracks.first?.artworkImageID, 0)
        XCTAssertEqual(result.library.tracks.first?.artworkByteCount, 777)
        XCTAssertTrue(try ClassicDatabase.inspect(result.data, firewireID: firewireID).hash58Valid)
    }

    func testAddingPlaylistUsesExistingTracksInChosenOrderWithoutCopyingMusic() throws {
        let first = track(id: 7, title: "First", artist: "Artist", album: "Album")
        let second = track(id: 9, title: "Second", artist: "Artist", album: "Album")
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(name: "My iPod", tracks: [first, second], playlists: []),
            firewireID: firewireID,
            databaseID: 99
        )

        let result = try ClassicDatabase.addingPlaylist(
            existing: original,
            name: "Chosen on iPhone",
            trackIDs: [9, 7, 9],
            firewireID: firewireID
        )

        XCTAssertEqual(result.library.tracks, [first, second])
        XCTAssertEqual(result.library.playlists, [ClassicPlaylist(name: "Chosen on iPhone", trackIDs: [9, 7, 9])])
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
        XCTAssertEqual(diagnostics.masterPlaylistMembers, 2)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testRenamingPlaylistUpdatesBothCopiesWithoutChangingMembership() throws {
        let song = track(id: 7, title: "Song", artist: "Artist", album: "Album")
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [song],
            playlists: [ClassicPlaylist(name: "Old Name", trackIDs: [7])]
        )
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)

        let result = try ClassicDatabase.renamingPlaylist(
            existing: original,
            playlistIndex: 0,
            newName: "Road Trip",
            firewireID: firewireID
        )

        XCTAssertEqual(result.library.playlists, [ClassicPlaylist(name: "Road Trip", trackIDs: [7])])
        XCTAssertTrue(try ClassicDatabase.inspect(result.data, firewireID: firewireID).hash58Valid)
        for type in [UInt32(3), UInt32(2)] {
            XCTAssertEqual(try masterTrackIDs(sectionType: type, in: result.data), [7])
        }
    }

    func testRemovingPlaylistUpdatesBothCopiesAndPreservesMaster() throws {
        let song = track(id: 7, title: "Song", artist: "Artist", album: "Album")
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [song],
            playlists: [
                ClassicPlaylist(name: "Delete Me", trackIDs: [7]),
                ClassicPlaylist(name: "Keep Me", trackIDs: [7])
            ]
        )
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)

        let result = try ClassicDatabase.removingPlaylist(
            existing: original,
            playlistIndex: 0,
            firewireID: firewireID
        )
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)

        XCTAssertEqual(result.library.playlists, [ClassicPlaylist(name: "Keep Me", trackIDs: [7])])
        XCTAssertEqual(result.library.tracks, [song])
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
        XCTAssertEqual(diagnostics.masterPlaylistMembers, 1)
        XCTAssertTrue(diagnostics.hash58Valid)
        for type in [UInt32(3), UInt32(2)] {
            XCTAssertEqual(try masterTrackIDs(sectionType: type, in: result.data), [7])
        }
    }

    func testAddingArtworkLinksExistingTracksWithoutChangingPlaylists() throws {
        var first = track(id: 7, title: "First", artist: "Artist", album: "Album")
        var second = track(id: 9, title: "Second", artist: "Artist", album: "Album")
        first.artworkImageID = 40
        first.artworkByteCount = 100
        second.artworkImageID = 41
        second.artworkByteCount = 100
        let library = ClassicLibrary(
            name: "My iPod",
            tracks: [first, second],
            playlists: [ClassicPlaylist(name: "Mix", trackIDs: [9, 7])]
        )
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        let image = Data([1, 2, 3, 4])

        let result = try ClassicDatabase.addingArtwork(
            existing: original,
            artworkByTrackID: [7: image, 9: image],
            firewireID: firewireID
        )
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)

        XCTAssertEqual(result.updatedTracks.count, 2)
        XCTAssertEqual(result.library.playlists, library.playlists)
        XCTAssertEqual(Set(result.library.tracks.map(\.artworkByteCount)), [UInt32(image.count)])
        XCTAssertEqual(Set(result.library.tracks.map(\.artworkImageID).filter { $0 != 0 }).count, 2)
        XCTAssertTrue(result.library.tracks.allSatisfy { $0.artworkImageID > 41 })
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
        XCTAssertTrue(diagnostics.hash58Valid)
    }

    func testMergedMasterMemberUsesNormalMusicMhipFields() throws {
        let old = track(id: 7, title: "Old", artist: "Artist", album: "Album")
        let library = ClassicLibrary(name: "My iPod", tracks: [old], playlists: [])
        let original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        let addition = track(id: 0, title: "New", artist: "New Artist", album: "New Album")

        let result = try ClassicDatabase.merge(existing: original, additions: [addition], firewireID: firewireID)
        let newTrackID = try XCTUnwrap(result.library.tracks.last?.id)
        let mhip = try playlistMember(trackID: newTrackID, in: result.data)

        XCTAssertEqual(try mhip.littleUInt32(at: 16), 0, "A normal music member must not be a podcast group")
        XCTAssertEqual(try mhip.littleUInt32(at: 20), 0, "A normal music member must not have a podcast group ID")
        XCTAssertEqual(try mhip.littleUInt32(at: 24), newTrackID)
        XCTAssertEqual(try mhip.littleUInt32(at: 76 + 24), 1, "The second member has zero-based position 1")
        let newTrackRecord = try record(tag: "mhit", in: result.data, occurrence: 1)
        XCTAssertEqual(newTrackRecord.ascii(at: 0x18, length: 4), " A4M", "M4A marker must be the little-endian representation of 'M4A '")
        XCTAssertEqual(Array(newTrackRecord[0x1c..<0x20]), [1, 0, 0, 0], "A normal AAC file must not inherit MP3 type flags")
        XCTAssertEqual(try newTrackRecord.littleUInt32(at: 0x24), 123)
        XCTAssertEqual(try newTrackRecord.littleUInt32(at: 0x12c), 123, "The firmware-facing repeated file size must be populated")
        XCTAssertEqual(try newTrackRecord.littleUInt32(at: 0x130), 0)
        XCTAssertEqual(try newTrackRecord.littleUInt16(at: 0x7e), 0xffff)
        XCTAssertEqual(try newTrackRecord.littleUInt32(at: 0x88), Float(44_100).bitPattern)
        XCTAssertEqual(try newTrackRecord.littleUInt16(at: 0x90), 0x33)
        XCTAssertEqual(newTrackRecord[0xb2], 2)
        XCTAssertEqual(try newTrackRecord.littleUInt64(at: 0x124), try result.data.littleUInt64(at: 0x24))
        XCTAssertNotEqual(try newTrackRecord.littleUInt64(at: 0x134), 0)
        XCTAssertEqual(try newTrackRecord.littleUInt32(at: 0x168), 1)

        for type in [UInt32(3), UInt32(2)] {
            let ids = try masterTrackIDs(sectionType: type, in: result.data)
            XCTAssertEqual(ids.filter { $0 == newTrackID }.count, 1, "Every firmware playlist copy must contain the new track exactly once")
            XCTAssertEqual(ids.count, 2)
        }
        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertEqual(diagnostics.playlistSectionTypes, [3, 2])
        XCTAssertTrue(diagnostics.playlistSectionsConsistent)
    }

    func testMergeContinuesAppleOddTrackIDSequence() throws {
        let oldTracks = (0..<32).map { index in
            track(id: UInt32(101 + index * 2), title: "Old \(index)", artist: "Artist", album: "Album")
        }
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(name: "My iPod", tracks: oldTracks, playlists: []),
            firewireID: firewireID,
            databaseID: 99
        )

        let result = try ClassicDatabase.merge(
            existing: original,
            additions: [track(id: 0, title: "New", artist: "Artist", album: "Album")],
            firewireID: firewireID
        )

        XCTAssertEqual(result.library.tracks.last?.id, 165)
    }

    func testMergePreservesAppleOrderingAndOnlyInsertsNewTrack() throws {
        let alpha = track(id: 101, title: "Alpha Song", artist: "Alpha", album: "Alpha")
        var theGame = track(id: 103, title: "Game Song", artist: "The Artist", album: "The Game")
        theGame.sortArtist = "Artist"
        theGame.sortAlbum = "Game"
        let numeric = track(id: 105, title: "2001", artist: "2Pac", album: "2001")
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(name: "My iPod", tracks: [alpha, theGame, numeric], playlists: []),
            firewireID: firewireID,
            databaseID: 99
        )
        let oldOrders = try Dictionary(uniqueKeysWithValues: [UInt32(3), 4, 5, 7, 18].map {
            ($0, try sortOrder(type: $0, sectionType: 3, in: original))
        })
        let addition = track(id: 0, title: "Beta Song", artist: "Beta", album: "Beta")

        let result = try ClassicDatabase.merge(existing: original, additions: [addition], firewireID: firewireID)

        for type in [UInt32(3), 4, 5, 7, 18] {
            let newOrder = try sortOrder(type: type, sectionType: 3, in: result.data)
            XCTAssertEqual(newOrder.filter { $0 < 3 }, oldOrders[type], "Existing Apple order must remain unchanged for sort type \(type)")
        }
        XCTAssertEqual(try sortOrder(type: 4, sectionType: 3, in: result.data), [0, 3, 1, 2])
        XCTAssertEqual(try sortOrder(type: 5, sectionType: 3, in: result.data), [0, 1, 3, 2])
    }

    func testNewAlbumWithoutSortMetadataIgnoresLeadingThe() throws {
        let alpha = track(id: 101, title: "Alpha Song", artist: "Alpha", album: "Alpha")
        let hotel = track(id: 103, title: "Hotel Song", artist: "Hotel", album: "Hotel")
        let original = try ClassicDatabase.build(
            library: ClassicLibrary(name: "My iPod", tracks: [alpha, hotel], playlists: []),
            firewireID: firewireID,
            databaseID: 99
        )
        let theGame = track(id: 0, title: "Game Song", artist: "New Artist", album: "The Game")

        let result = try ClassicDatabase.merge(existing: original, additions: [theGame], firewireID: firewireID)

        XCTAssertEqual(
            try sortOrder(type: 4, sectionType: 3, in: result.data),
            [0, 2, 1],
            "A newly added 'The Game' album must be sorted under G, not T"
        )
    }

    func testMergeAcceptsAppleDatabaseWithPartialJumpTable() throws {
        let old = track(id: 7, title: "Old", artist: "Artist", album: "Album")
        let library = ClassicLibrary(name: "My iPod", tracks: [old], playlists: [])
        var original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        var cursor = 0
        var patched = false
        while let range = original.range(of: Data("mhod".utf8), in: cursor..<original.count) {
            let offset = range.lowerBound
            let length = Int(try original.littleUInt32(at: offset + 8))
            if length >= 52, try original.littleUInt32(at: offset + 12) == 53 {
                try original.setLittleUInt32(0, at: offset + 48)
                patched = true
                break
            }
            cursor = range.upperBound
        }
        XCTAssertTrue(patched)
        original = try Hash58.sign(original, firewireID: firewireID)
        XCTAssertFalse(try ClassicDatabase.inspect(original, firewireID: firewireID).jumpTablesValid)

        let result = try ClassicDatabase.merge(
            existing: original,
            additions: [track(id: 0, title: "New", artist: "New Artist", album: "New Album")],
            firewireID: firewireID
        )

        XCTAssertEqual(result.library.tracks.count, 2)
        XCTAssertEqual(try ClassicDatabase.parse(result.data).tracks.count, 2)
    }

    func testMergeUpdatesUnknownAppleSortIndexType() throws {
        let old = track(id: 7, title: "Old", artist: "Artist", album: "Album")
        let library = ClassicLibrary(name: "My iPod", tracks: [old], playlists: [])
        var original = try ClassicDatabase.build(library: library, firewireID: firewireID, databaseID: 99)
        var cursor = 0
        var patched = false
        while let range = original.range(of: Data("mhod".utf8), in: cursor..<original.count) {
            let offset = range.lowerBound
            let length = Int(try original.littleUInt32(at: offset + 8))
            if length >= 72,
               try original.littleUInt32(at: offset + 12) == 52,
               try original.littleUInt32(at: offset + 24) == 18 {
                try original.setLittleUInt32(99, at: offset + 24)
                patched = true
                break
            }
            cursor = range.upperBound
        }
        XCTAssertTrue(patched)
        original = try Hash58.sign(original, firewireID: firewireID)

        let result = try ClassicDatabase.merge(
            existing: original,
            additions: [track(id: 0, title: "New", artist: "New Artist", album: "New Album")],
            firewireID: firewireID
        )

        let diagnostics = try ClassicDatabase.inspect(result.data, firewireID: firewireID)
        XCTAssertTrue(diagnostics.sortIndexesValid)
        XCTAssertEqual(diagnostics.masterPlaylistMembers, 2)
    }

    private func track(id: UInt32, title: String, artist: String, album: String) -> ClassicTrack {
        ClassicTrack(
            id: id, databaseID: UInt64(id) + 1_000, title: title, artist: artist,
            album: album, genre: "Rock", fileType: "AAC audio file",
            ipodPath: ":iPod_Control:Music:F00:TEST\(id).m4a", byteCount: 123,
            durationMS: 10_000, trackNumber: 1, year: 2026, bitrate: 256,
            sampleRate: 44_100, dateAdded: 3_000_000_000, sourceURL: nil
        )
    }

    private func record(tag: String, in data: Data, occurrence: Int) throws -> Data {
        let needle = Data(tag.utf8)
        var start = data.startIndex
        var found: Range<Data.Index>?
        for _ in 0...occurrence {
            guard let range = data.range(of: needle, in: start..<data.endIndex) else { throw PodBridgeError.invalidDatabase }
            found = range
            start = range.upperBound
        }
        guard let found else { throw PodBridgeError.invalidDatabase }
        let length = Int(try data.littleUInt32(at: found.lowerBound + 8))
        return Data(data[found.lowerBound..<(found.lowerBound + length)])
    }

    private func topLevelSection(type: UInt32, in data: Data) -> Range<Int>? {
        guard let header = try? data.littleUInt32(at: 4) else { return nil }
        var cursor = Int(header)
        while cursor + 16 <= data.count, data.ascii(at: cursor, length: 4) == "mhsd" {
            guard let lengthValue = try? data.littleUInt32(at: cursor + 8),
                  let typeValue = try? data.littleUInt32(at: cursor + 12) else { return nil }
            let length = Int(lengthValue)
            if typeValue == type { return cursor..<(cursor + length) }
            cursor += length
        }
        return nil
    }

    private func albumEntityIDs(in data: Data) throws -> [UInt32] {
        try entityIDs(sectionType: 4, listTag: "mhla", recordTag: "mhia", in: data)
    }

    private func artistEntityIDs(in data: Data) throws -> [UInt32] {
        try entityIDs(sectionType: 8, listTag: "mhli", recordTag: "mhii", in: data)
    }

    private func entityIDs(
        sectionType: UInt32,
        listTag: String,
        recordTag: String,
        in data: Data
    ) throws -> [UInt32] {
        guard let section = topLevelSection(type: sectionType, in: data) else {
            throw PodBridgeError.invalidDatabase
        }
        let source = Data(data[section])
        let listOffset = Int(try source.littleUInt32(at: 4))
        guard source.ascii(at: listOffset, length: 4) == listTag else {
            throw PodBridgeError.invalidDatabase
        }
        let listHeader = Int(try source.littleUInt32(at: listOffset + 4))
        var cursor = listOffset + listHeader
        var ids: [UInt32] = []
        while cursor + 20 <= source.count, source.ascii(at: cursor, length: 4) == recordTag {
            ids.append(try source.littleUInt32(at: cursor + 16))
            let length = Int(try source.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= source.count else {
                throw PodBridgeError.invalidDatabase
            }
            cursor += length
        }
        guard cursor == source.count else { throw PodBridgeError.invalidDatabase }
        return ids
    }

    private func playlistMember(trackID: UInt32, in data: Data) throws -> Data {
        var cursor = 0
        while let range = data.range(of: Data("mhip".utf8), in: cursor..<data.count) {
            let length = Int(try data.littleUInt32(at: range.lowerBound + 8))
            let record = Data(data[range.lowerBound..<(range.lowerBound + length)])
            if try record.littleUInt32(at: 24) == trackID { return record }
            cursor = range.upperBound
        }
        throw PodBridgeError.invalidDatabase
    }

    private func masterTrackIDs(sectionType: UInt32, in data: Data) throws -> [UInt32] {
        guard let section = topLevelSection(type: sectionType, in: data) else { throw PodBridgeError.invalidDatabase }
        let list = section.lowerBound + Int(try data.littleUInt32(at: section.lowerBound + 4))
        var playlist = list + Int(try data.littleUInt32(at: list + 4))
        while playlist + 24 <= section.upperBound, data.ascii(at: playlist, length: 4) == "mhyp" {
            let header = Int(try data.littleUInt32(at: playlist + 4))
            let total = Int(try data.littleUInt32(at: playlist + 8))
            if try data.littleUInt32(at: playlist + 20) != 0 {
                var ids: [UInt32] = []
                var child = playlist + header
                while child + 28 <= playlist + total {
                    let length = Int(try data.littleUInt32(at: child + 8))
                    guard length > 0 else { throw PodBridgeError.invalidDatabase }
                    if data.ascii(at: child, length: 4) == "mhip" {
                        ids.append(try data.littleUInt32(at: child + 24))
                    }
                    child += length
                }
                return ids
            }
            playlist += total
        }
        throw PodBridgeError.invalidDatabase
    }

    private func sortOrder(type: UInt32, sectionType: UInt32, in data: Data) throws -> [Int] {
        guard let section = topLevelSection(type: sectionType, in: data) else { throw PodBridgeError.invalidDatabase }
        var cursor = section.lowerBound
        while let range = data.range(of: Data("mhod".utf8), in: cursor..<section.upperBound) {
            let offset = range.lowerBound
            let length = Int(try data.littleUInt32(at: offset + 8))
            if length >= 72,
               try data.littleUInt32(at: offset + 12) == 52,
               try data.littleUInt32(at: offset + 24) == type {
                let count = Int(try data.littleUInt32(at: offset + 28))
                return try (0..<count).map { Int(try data.littleUInt32(at: offset + 72 + $0 * 4)) }
            }
            cursor = range.upperBound
        }
        throw PodBridgeError.invalidDatabase
    }
}
