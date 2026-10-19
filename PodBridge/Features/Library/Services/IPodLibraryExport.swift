// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension IPodSyncEngine {
    struct ExportLibrary: Codable {
        let format: String
        let version: Int
        let exportedAt: Date
        let tracks: [ExportTrack]
        let playlists: [ExportPlaylist]
    }

    struct ExportTrack: Codable {
        let id: UInt32
        let databaseID: UInt64
        let title: String
        let artist: String
        let album: String
        let durationMS: UInt32
        let relativePath: String
        let rating: UInt8
        let playCount: UInt32
        let skipCount: UInt32
        let lastPlayed: UInt32
        let lastSkipped: UInt32
        let artworkRelativePath: String?
    }

    struct ExportPlaylist: Codable {
        let name: String
        let trackDatabaseIDs: [UInt64]
    }

    /// Copies original audio files to a new folder in Files without changing the iPod.
    static func exportTracks(
        _ tracks: [ClassicTrack],
        playlists: [ClassicPlaylist] = [],
        root: URL,
        destinationFolder: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> ExportResult {
        try await Task.detached(priority: .userInitiated) {
            try await performExport(
                tracks: tracks,
                playlists: playlists,
                root: root,
                destinationFolder: destinationFolder,
                progress: progress
            )
        }.value
    }

    private struct ExportedFiles {
        let relativePaths: [UInt32: String]
        let artworkRelativePaths: [UInt32: String]
        let copiedBytes: UInt64
    }

    private static func performExport(
        tracks: [ClassicTrack],
        playlists: [ClassicPlaylist],
        root: URL,
        destinationFolder: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> ExportResult {
        let sources = try exportSources(for: tracks, root: root, destinationFolder: destinationFolder)
        let artwork = try ArtworkDatabase.exportArtwork(
            root: root,
            databaseIDs: Set(tracks.map(\.databaseID))
        )
        let exportFolder = try createExportFolder(in: destinationFolder)
        do {
            let files = try await copyExportFiles(
                sources,
                artworkByDatabaseID: artwork,
                exportFolder: exportFolder,
                progress: progress
            )
            let exportedTracks = makeExportTracks(tracks, files: files)
            let exportedPlaylists = makeExportPlaylists(playlists, tracks: tracks)
            try writeExportManifests(
                tracks: exportedTracks,
                playlists: exportedPlaylists,
                folder: exportFolder
            )
            return ExportResult(
                folderURL: exportFolder,
                copiedTracks: sources.count,
                copiedBytes: files.copiedBytes
            )
        } catch {
            try? FileManager.default.removeItem(at: exportFolder)
            throw error
        }
    }

    private static func exportSources(
        for tracks: [ClassicTrack],
        root: URL,
        destinationFolder: URL
    ) throws -> [(ClassicTrack, URL)] {
        let manager = FileManager.default
        let musicRoot = root.appendingPathComponent("iPod_Control/Music", isDirectory: true)
            .standardizedFileURL.path
        let destinationPath = destinationFolder.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard destinationPath != rootPath, !destinationPath.hasPrefix(rootPath + "/") else {
            throw ExportError.destinationIsIPod
        }
        return try tracks.map { track in
            guard let url = trackURL(path: track.ipodPath, root: root),
                  url.standardizedFileURL.path.hasPrefix(musicRoot + "/") else {
                throw ExportError.unsafeAudioPath
            }
            guard manager.fileExists(atPath: url.path) else {
                throw ExportError.missingAudio(track.title)
            }
            return (track, url)
        }
    }

    private static func createExportFolder(in destination: URL) throws -> URL {
        let manager = FileManager.default
        var folder = destination.appendingPathComponent("PodBridge Export", isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: folder.path) {
            folder = destination.appendingPathComponent("PodBridge Export \(suffix)", isDirectory: true)
            suffix += 1
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func copyExportFiles(
        _ sources: [(ClassicTrack, URL)],
        artworkByDatabaseID: [UInt64: Data],
        exportFolder: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> ExportedFiles {
        var copiedBytes: UInt64 = 0
        var relativePaths: [UInt32: String] = [:]
        var artworkRelativePaths: [UInt32: String] = [:]
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let target = try await copyExportFile(
                source,
                artwork: artworkByDatabaseID[source.0.databaseID],
                to: exportFolder
            )
            copiedBytes += UInt64(source.0.byteCount)
            relativePaths[source.0.id] = relativePath(of: target.audio, in: exportFolder)
            if let artwork = target.artwork {
                artworkRelativePaths[source.0.id] = relativePath(of: artwork, in: exportFolder)
            }
            await progress(index + 1)
        }
        return ExportedFiles(
            relativePaths: relativePaths,
            artworkRelativePaths: artworkRelativePaths,
            copiedBytes: copiedBytes
        )
    }

    private static func copyExportFile(
        _ source: (ClassicTrack, URL),
        artwork: Data?,
        to exportFolder: URL
    ) async throws -> (audio: URL, artwork: URL?) {
        let manager = FileManager.default
        let track = source.0
        let artistName = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        let artist = safeExportName(artistName, fallback: "Unknown Artist")
        let album = safeExportName(track.album, fallback: "Unknown Album")
        let folder = exportFolder.appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(album, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let title = safeExportName(track.title, fallback: "Unknown Song")
        let prefix = track.trackNumber == 0 ? "" : String(format: "%02d - ", track.trackNumber)
        let target = uniqueExportURL(
            folder: folder,
            baseName: prefix + title,
            pathExtension: source.1.pathExtension
        )
        try manager.copyItem(at: source.1, to: target)
        let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(track.byteCount) else { throw ExportError.copyVerificationFailed }
        try await ExportAudioMetadataWriter.apply(track: track, artwork: artwork, to: target)
        guard let artwork else { return (target, nil) }
        let artworkURL = target.deletingPathExtension().appendingPathExtension("cover.png")
        try artwork.write(to: artworkURL, options: .atomic)
        guard try Data(contentsOf: artworkURL) == artwork else {
            throw ExportError.copyVerificationFailed
        }
        return (target, artworkURL)
    }

    private static func uniqueExportURL(folder: URL, baseName: String, pathExtension: String) -> URL {
        let manager = FileManager.default
        var target = folder.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var copyNumber = 2
        while manager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(baseName) (\(copyNumber))")
                .appendingPathExtension(pathExtension)
            copyNumber += 1
        }
        return target
    }

    private static func relativePath(of url: URL, in folder: URL) -> String {
        url.path.replacingOccurrences(of: folder.path + "/", with: "")
    }

    private static func makeExportTracks(_ tracks: [ClassicTrack], files: ExportedFiles) -> [ExportTrack] {
        tracks.map { track in
            ExportTrack(
                id: track.id, databaseID: track.databaseID, title: track.title,
                artist: track.artist, album: track.album, durationMS: track.durationMS,
                relativePath: files.relativePaths[track.id] ?? "", rating: track.rating,
                playCount: track.playCount, skipCount: track.skipCount,
                lastPlayed: track.lastPlayed, lastSkipped: track.lastSkipped,
                artworkRelativePath: files.artworkRelativePaths[track.id]
            )
        }
    }

    private static func makeExportPlaylists(
        _ playlists: [ClassicPlaylist],
        tracks: [ClassicTrack]
    ) -> [ExportPlaylist] {
        let selected = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.databaseID) })
        return playlists.compactMap { playlist in
            let ids = playlist.trackIDs.compactMap { selected[$0] }
            return ids.isEmpty ? nil : ExportPlaylist(name: playlist.name, trackDatabaseIDs: ids)
        }
    }

    private static func writeExportManifests(
        tracks: [ExportTrack],
        playlists: [ExportPlaylist],
        folder: URL
    ) throws {
        let manifest = ExportLibrary(
            format: "PodBridge Library",
            version: 1,
            exportedAt: Date(),
            tracks: tracks,
            playlists: playlists
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(manifest)
        let jsonURL = folder.appendingPathComponent("PodBridge Library.json")
        try json.write(to: jsonURL, options: .atomic)
        guard try Data(contentsOf: jsonURL) == json else { throw ExportError.copyVerificationFailed }
        try writeExportCSV(tracks, folder: folder)
        try writeExportPlaylists(playlists, tracks: tracks, folder: folder)
    }

    private static func writeExportCSV(_ tracks: [ExportTrack], folder: URL) throws {
        let columns = [
            "database_id", "title", "artist", "album", "rating_0_100", "play_count",
            "skip_count", "last_played_apple_epoch", "last_skipped_apple_epoch", "relative_path"
        ]
        var csv = columns.joined(separator: ",") + "\n"
        for track in tracks {
            let values = [
                String(track.databaseID), track.title, track.artist, track.album,
                String(track.rating), String(track.playCount), String(track.skipCount),
                String(track.lastPlayed), String(track.lastSkipped), track.relativePath
            ]
            csv += values.map(csvField).joined(separator: ",") + "\n"
        }
        try Data(csv.utf8).write(
            to: folder.appendingPathComponent("PodBridge Library.csv"),
            options: .atomic
        )
    }

    private static func writeExportPlaylists(
        _ playlists: [ExportPlaylist],
        tracks: [ExportTrack],
        folder: URL
    ) throws {
        guard !playlists.isEmpty else { return }
        let playlistFolder = folder.appendingPathComponent("Playlists", isDirectory: true)
        try FileManager.default.createDirectory(at: playlistFolder, withIntermediateDirectories: true)
        let paths = Dictionary(uniqueKeysWithValues: tracks.map { ($0.databaseID, $0.relativePath) })
        for playlist in playlists {
            let entries = playlist.trackDatabaseIDs.compactMap { paths[$0] }.map { "../\($0)" }
            let body = (["#EXTM3U"] + entries).joined(separator: "\n") + "\n"
            let name = safeExportName(playlist.name, fallback: "Playlist")
            try Data(body.utf8).write(
                to: playlistFolder.appendingPathComponent(name).appendingPathExtension("m3u8"),
                options: .atomic
            )
        }
    }

    static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func safeExportName(_ value: String, fallback: String) -> String {
        let cleaned = String(value.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || "/\\:".unicodeScalars.contains(scalar) {
                return "_"
            }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        let component = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return component.isEmpty ? fallback : String(component.prefix(120))
    }

}
