// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import XCTest
@testable import PodBridge

final class MusicTransferEngineTests: XCTestCase {
    func testScanFindsSupportedMusicAndPreservesRelativePaths() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Album", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("a".utf8).write(to: root.appendingPathComponent("Album/02 Song.m4a"))
        try Data("b".utf8).write(to: root.appendingPathComponent("Album/01 Intro.mp3"))
        try Data("x".utf8).write(to: root.appendingPathComponent("cover.jpg"))

        let files = try await MusicTransferEngine.scan(folder: root)

        XCTAssertEqual(files.map(\.relativePath), ["Album/01 Intro.mp3", "Album/02 Song.m4a"])
    }

    func testCopyCreatesSafeImportTreeAndDoesNotOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source.m4a")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("music".utf8).write(to: source)
        let file = MusicFile(
            sourceURL: source,
            relativePath: "Artist:Name/Album/Track?.m4a",
            byteCount: 5
        )
        let importFolder = try MusicTransferEngine.prepareImportFolder(destination: destination)

        let first = try MusicTransferEngine.copy(file: file, to: importFolder)
        let second = try MusicTransferEngine.copy(file: file, to: importFolder)

        XCTAssertEqual(first.lastPathComponent, "source.m4a")
        XCTAssertEqual(second.lastPathComponent, "source (2).m4a")
        XCTAssertTrue(first.path.contains("Artist_Name/Album"))
        XCTAssertEqual(try Data(contentsOf: first), Data("music".utf8))
    }

    func testFilenameSanitizationKeepsExtension() {
        XCTAssertEqual(
            MusicTransferEngine.sanitizedFilename("Track: One?.M4A"),
            "Track_ One_.m4a"
        )
    }

    func testM3UPlaylistNameAndOrderArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let playlistFolder = root.appendingPathComponent("Playlists", isDirectory: true)
        let tracks = playlistFolder.appendingPathComponent("Любимки", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: tracks.appendingPathComponent("001 First.m4a"))
        try Data("b".utf8).write(to: tracks.appendingPathComponent("002 Second.m4a"))
        let text = """
        #EXTM3U
        #PLAYLIST:Любимки
        Любимки/002 Second.m4a
        Любимки/001 First.m4a
        ../../outside.m4a
        """
        try text.write(to: playlistFolder.appendingPathComponent("Любимки.m3u8"), atomically: true, encoding: .utf8)
        let files = try await MusicTransferEngine.scan(folder: root)

        let playlists = try await MusicTransferEngine.scanPlaylists(folder: root, files: files)

        XCTAssertEqual(playlists.map(\.name), ["Любимки"])
        XCTAssertEqual(playlists[0].fileIndices.map { files[$0].name }, ["002 Second.m4a", "001 First.m4a"])
    }

    func testM3UResolvesExportedAbsoluteAndWindowsPathsInsideSelectedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = root.appendingPathComponent("Audio/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        let first = tracks.appendingPathComponent("01 First Song.m4a")
        let second = tracks.appendingPathComponent("02 Second Song.m4a")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let text = """
        #EXTM3U
        file:///old/export/My%20Playlist/Audio/Album/02%20Second%20Song.m4a
        C:\\Music\\My Playlist\\Audio\\Album\\01 First Song.m4a
        """
        try text.write(to: root.appendingPathComponent("Exported.m3u8"), atomically: true, encoding: .utf8)
        let files = try await MusicTransferEngine.scan(folder: root)

        let playlists = try await MusicTransferEngine.scanPlaylists(folder: root, files: files)

        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists[0].fileIndices.map { files[$0].name }, ["02 Second Song.m4a", "01 First Song.m4a"])
    }
}
