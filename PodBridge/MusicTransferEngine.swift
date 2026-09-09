// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Scans source folders and prepares ordered audio and playlist inputs for sync.
///
/// This type does not modify the iPod. All destination writes are performed by
/// `IPodSyncEngine` after the scan has completed.
enum MusicTransferEngine {
    /// File extensions accepted by the source scanner.
    static let supportedExtensions: Set<String> = [
        "aac", "aif", "aiff", "m4a", "m4b", "mp3", "wav",
    ]

    /// Recursively scans a source folder and returns supported audio in stable order.
    static func scan(folder: URL) async throws -> [MusicFile] {
        try await Task.detached(priority: .userInitiated) {
            let access = folder.startAccessingSecurityScopedResource()
            defer {
                if access { folder.stopAccessingSecurityScopedResource() }
            }

            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .nameKey]
            let candidates = try recursiveFiles(at: folder, keys: keys)
            AppLogger.scan("Recursive source enumeration files=\(candidates.count)", level: .debug)

            let rootPath = folder.standardizedFileURL.path
            var files: [MusicFile] = []

            for fileURL in candidates {
                try Task.checkCancellation()
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }
                let values = try fileURL.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }

                let standardizedPath = fileURL.standardizedFileURL.path
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                let relativePath = standardizedPath.hasPrefix(prefix)
                    ? String(standardizedPath.dropFirst(prefix.count))
                    : fileURL.lastPathComponent

                files.append(
                    MusicFile(
                        sourceURL: fileURL,
                        relativePath: relativePath,
                        byteCount: Int64(values.fileSize ?? 0)
                    )
                )
            }

            let result = files.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            AppLogger.scan("Supported audio enumeration tracks=\(result.count)", level: .debug)
            return result
        }.value
    }

    /// Parses in-folder `.m3u` and `.m3u8` files against the scanned audio list.
    static func scanPlaylists(folder: URL, files: [MusicFile]) async throws -> [SourcePlaylist] {
        try await Task.detached(priority: .userInitiated) {
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }

            let root = folder.standardizedFileURL.resolvingSymlinksInPath()
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            let fileIndices = Dictionary(uniqueKeysWithValues: files.enumerated().map {
                ($0.element.sourceURL.standardizedFileURL.resolvingSymlinksInPath().path, $0.offset)
            })
            let candidates = try recursiveFiles(at: root, keys: [.isRegularFileKey])

            var playlists: [SourcePlaylist] = []
            for playlistURL in candidates {
                try Task.checkCancellation()
                guard ["m3u", "m3u8"].contains(playlistURL.pathExtension.lowercased()),
                      (try? playlistURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      let text = try? String(contentsOf: playlistURL, encoding: .utf8) else { continue }
                var name = playlistURL.deletingPathExtension().lastPathComponent
                var ordered: [Int] = []
                var ignoredReferences = 0
                for rawLine in text.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("#PLAYLIST:") {
                        let candidate = String(line.dropFirst("#PLAYLIST:".count)).trimmingCharacters(in: .whitespaces)
                        if !candidate.isEmpty { name = candidate }
                        continue
                    }
                    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                    guard !line.contains("\0") else {
                        ignoredReferences += 1
                        continue
                    }
                    guard let index = playlistFileIndex(
                        reference: line,
                        playlistURL: playlistURL,
                        rootPrefix: rootPrefix,
                        exactFileIndices: fileIndices,
                        files: files
                    ) else {
                        ignoredReferences += 1
                        continue
                    }
                    ordered.append(index)
                }
                AppLogger.scan(
                    "Playlist parsed name=\(name) tracks=\(ordered.count) ignoredReferences=\(ignoredReferences)",
                    level: ignoredReferences == 0 ? .debug : .info
                )
                if !ordered.isEmpty { playlists.append(SourcePlaylist(name: name, fileIndices: ordered)) }
            }
            return playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
    }

    private static func playlistFileIndex(
        reference rawReference: String,
        playlistURL: URL,
        rootPrefix: String,
        exactFileIndices: [String: Int],
        files: [MusicFile]
    ) -> Int? {
        var reference = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.count >= 2,
           (reference.hasPrefix("\"") && reference.hasSuffix("\"") ||
            reference.hasPrefix("'") && reference.hasSuffix("'")) {
            reference.removeFirst()
            reference.removeLast()
        }
        reference = reference.removingPercentEncoding ?? reference

        let path: String
        if reference.lowercased().hasPrefix("file://"), let fileURL = URL(string: reference), fileURL.isFileURL {
            path = fileURL.path
        } else {
            guard !reference.contains("://") else { return nil }
            path = reference.replacingOccurrences(of: "\\", with: "/")
        }

        let isWindowsAbsolute = path.count >= 3 && path[path.index(path.startIndex, offsetBy: 1)] == ":" && path[path.index(path.startIndex, offsetBy: 2)] == "/"
        let isAbsolute = path.hasPrefix("/") || isWindowsAbsolute
        if !isWindowsAbsolute {
            let target = (isAbsolute ? URL(fileURLWithPath: path) : playlistURL.deletingLastPathComponent().appendingPathComponent(path))
                .standardizedFileURL
                .resolvingSymlinksInPath()
            if target.path.hasPrefix(rootPrefix), let index = exactFileIndices[target.path] {
                return index
            }
            if !isAbsolute, path.split(separator: "/").contains("..") {
                return nil
            }
        }

        let referenceComponents = normalizedPlaylistPath(path).split(separator: "/").map(String.init)
        guard !referenceComponents.isEmpty else { return nil }
        var bestLength = 0
        var bestIndices: [Int] = []
        for (index, file) in files.enumerated() {
            let fileComponents = normalizedPlaylistPath(file.relativePath).split(separator: "/").map(String.init)
            let matched = commonSuffixLength(referenceComponents, fileComponents)
            guard matched > 0 else { continue }
            if matched > bestLength {
                bestLength = matched
                bestIndices = [index]
            } else if matched == bestLength {
                bestIndices.append(index)
            }
        }
        return bestIndices.count == 1 ? bestIndices[0] : nil
    }

    private static func normalizedPlaylistPath(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static func commonSuffixLength(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        while count < lhs.count, count < rhs.count,
              lhs[lhs.count - 1 - count] == rhs[rhs.count - 1 - count] {
            count += 1
        }
        return count
    }

    private static func recursiveFiles(at root: URL, keys: [URLResourceKey]) throws -> [URL] {
        var directories = [root]
        var files: [URL] = []
        let requested = Set(keys).union([.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey])
        while let directory = directories.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(requested),
                options: [.skipsHiddenFiles]
            )
            for child in children {
                let values = try child.resourceValues(forKeys: requested)
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true { directories.append(child) }
                else if values.isRegularFile == true { files.append(child) }
            }
        }
        return files
    }

    static func prepareImportFolder(destination: URL) throws -> URL {
        let importFolder = destination.appendingPathComponent("PodBridge Imports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: importFolder,
                withIntermediateDirectories: true
            )
            return importFolder
        } catch {
            throw PodBridgeError.cannotCreateImportFolder
        }
    }

    static func copy(file: MusicFile, to importFolder: URL) throws -> URL {
        try Task.checkCancellation()
        let relativeNSString = file.relativePath as NSString
        let relativeDirectory = relativeNSString.deletingLastPathComponent
        let destinationDirectory = relativeDirectory
            .split(separator: "/")
            .reduce(importFolder) { partial, component in
                partial.appendingPathComponent(sanitizedSegment(String(component)), isDirectory: true)
            }

        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let safeName = sanitizedFilename(file.name)
        let destinationURL = availableDestination(
            in: destinationDirectory,
            filename: safeName
        )
        try FileManager.default.copyItem(at: file.sourceURL, to: destinationURL)
        return destinationURL
    }

    static func sanitizedSegment(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*")
            .union(.controlCharacters)
        let cleaned = value.unicodeScalars.map { scalar -> Character in
            forbidden.contains(scalar) ? "_" : Character(String(scalar))
        }
        let result = String(cleaned)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return result.isEmpty ? "_" : String(result.prefix(120))
    }

    static func sanitizedFilename(_ filename: String) -> String {
        let source = filename as NSString
        let stem = source.deletingPathExtension
        let ext = source.pathExtension
        let safeStem = sanitizedSegment(stem)
        let safeExtension = sanitizedSegment(ext).lowercased()
        return safeExtension == "_" || safeExtension.isEmpty
            ? safeStem
            : "\(safeStem).\(safeExtension)"
    }

    static func availableDestination(in folder: URL, filename: String) -> URL {
        let first = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }

        let source = filename as NSString
        let stem = source.deletingPathExtension
        let ext = source.pathExtension
        var counter = 2
        while true {
            let candidateName = ext.isEmpty
                ? "\(stem) (\(counter))"
                : "\(stem) (\(counter)).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}
