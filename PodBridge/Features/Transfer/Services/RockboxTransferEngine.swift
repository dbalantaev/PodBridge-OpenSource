// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Copies user-selected files for Rockbox without changing Apple's iPod database.
enum RockboxTransferEngine {
    struct CopyResult: Sendable {
        let copiedFiles: Int
        let copiedBytes: Int64
    }

    static func copyFolderContents(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> CopyResult {
        try await copyFolderContents(from: [source], to: destination, progress: progress)
    }

    /// Copies several source trees as one recoverable operation.
    ///
    /// Files created by this call are removed if enumeration, copying,
    /// verification, or cancellation fails. Existing destination files are never
    /// overwritten because every collision receives a new filename.
    static func copyFolderContents(
        from sources: [URL],
        to destination: URL,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> CopyResult {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let destinationRoot = destination.standardizedFileURL.path
            for source in sources {
                let sourceRoot = source.standardizedFileURL.path
                guard destinationRoot != sourceRoot,
                      !destinationRoot.hasPrefix(sourceRoot + "/") else {
                    throw copyError(1, "Choose a different destination folder.")
                }
            }

            let keys: Set<URLResourceKey> = [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ]
            let files = try sources.flatMap { source in
                try recursiveFiles(at: source, keys: keys).map { (source, $0) }
            }.filter { item in
                (try? item.1.resourceValues(forKeys: keys).isRegularFile) == true
            }.sorted {
                $0.1.path.localizedStandardCompare($1.1.path) == .orderedAscending
            }
            guard !files.isEmpty else {
                throw copyError(2, "The selected folder has no files to copy.")
            }

            var createdFiles: [URL] = []
            var createdDirectories: Set<URL> = []
            do {
                var bytes: Int64 = 0
                for (index, item) in files.enumerated() {
                    try Task.checkCancellation()
                    let target = try copy(
                        item.1,
                        relativeTo: item.0,
                        destination: destination,
                        createdDirectories: &createdDirectories
                    )
                    createdFiles.append(target)
                    bytes += try verifiedSize(of: item.1, copiedTo: target)
                    await progress(index + 1)
                }
                return CopyResult(copiedFiles: files.count, copiedBytes: bytes)
            } catch {
                rollback(files: createdFiles, directories: createdDirectories)
                throw error
            }
        }.value
    }

    static func copyTheme(from source: URL, to destination: URL) throws -> CopyResult {
        let manager = FileManager.default
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw copyError(4, "Choose a theme file or a folder containing a theme.")
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let filename = TransferFileNaming.sanitizedFilename(source.lastPathComponent)
        let target = TransferFileNaming.availableDestination(in: destination, filename: filename)
        try manager.copyItem(at: source, to: target)
        let copiedSize = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard copiedSize == values.fileSize else {
            try? manager.removeItem(at: target)
            throw copyError(5, "The theme file could not be verified after copying.")
        }
        return CopyResult(copiedFiles: 1, copiedBytes: Int64(copiedSize))
    }

    private static func copy(
        _ file: URL,
        relativeTo source: URL,
        destination: URL,
        createdDirectories: inout Set<URL>
    ) throws -> URL {
        let sourceRoot = source.standardizedFileURL.path
        let relativePath = String(file.standardizedFileURL.path.dropFirst(sourceRoot.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { throw copyError(6, "A source file has an invalid path.") }
        let components = relativePath.split(separator: "/")
            .map { TransferFileNaming.sanitizedSegment(String($0)) }
        guard let filename = components.last else { throw copyError(6, "A source file has an invalid path.") }
        let parent = components.dropLast().reduce(destination) { folder, component in
            folder.appendingPathComponent(component, isDirectory: true)
        }
        recordMissingDirectories(from: parent, through: destination, in: &createdDirectories)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = TransferFileNaming.availableDestination(in: parent, filename: filename)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    private static func verifiedSize(of source: URL, copiedTo target: URL) throws -> Int64 {
        let copiedSize = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? -1
        let sourceSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? -2
        guard copiedSize == sourceSize else {
            try? FileManager.default.removeItem(at: target)
            throw copyError(3, "A copied file could not be verified.")
        }
        return sourceSize
    }

    private static func recordMissingDirectories(
        from directory: URL,
        through root: URL,
        in result: inout Set<URL>
    ) {
        let manager = FileManager.default
        var current = directory.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while current.path.hasPrefix(rootPath), current.path != rootPath {
            if !manager.fileExists(atPath: current.path) { result.insert(current) }
            current.deleteLastPathComponent()
        }
        if !manager.fileExists(atPath: root.path) { result.insert(root.standardizedFileURL) }
    }

    private static func rollback(files: [URL], directories: Set<URL>) {
        let manager = FileManager.default
        for file in files.reversed() { try? manager.removeItem(at: file) }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            guard (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true else { continue }
            try? manager.removeItem(at: directory)
        }
    }

    private static func recursiveFiles(at root: URL, keys: Set<URLResourceKey>) throws -> [URL] {
        var directories = [root]
        var files: [URL] = []
        let requested = keys.union([.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey])
        while let directory = directories.popLast() {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(requested),
                options: [.skipsHiddenFiles]
            )
            for child in children {
                let values = try child.resourceValues(forKeys: requested)
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    directories.append(child)
                } else if values.isRegularFile == true {
                    files.append(child)
                }
            }
        }
        return files
    }

    private static func copyError(_ code: Int, _ description: String) -> NSError {
        NSError(
            domain: "PodBridge.Rockbox",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
