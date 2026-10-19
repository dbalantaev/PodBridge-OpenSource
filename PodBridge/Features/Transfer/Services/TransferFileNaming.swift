// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// Builds safe destination names and avoids overwriting existing files.
enum TransferFileNaming {
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
