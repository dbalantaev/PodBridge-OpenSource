// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import UIKit

/// A bounded, file-backed diagnostic log that survives app restarts.
///
/// Access is serialized internally because the logger is shared by UI and
/// detached transfer work. The store keeps recent entries within its rotation
/// limit and never records audio bytes or source file contents.
final class PersistentLogStore: @unchecked Sendable {
    static let shared = PersistentLogStore()

    private let maximumFileSize: Int
    private let retainedFileSize: Int
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let timestampFormatter: DateFormatter
    private let exportFormatter: DateFormatter
    let fileURL: URL

    init(
        directoryURL: URL? = nil,
        maximumFileSize: Int = 4 * 1_024 * 1_024,
        retainedFileSize: Int = 2 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.maximumFileSize = maximumFileSize
        self.retainedFileSize = retainedFileSize
        self.fileManager = fileManager
        queue = DispatchQueue(label: "org.podbridge.app.persistent-log", qos: .utility)

        timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"

        exportFormatter = DateFormatter()
        exportFormatter.locale = Locale(identifier: "en_US_POSIX")
        exportFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"

        let base = directoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("PodBridgeLogs", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("PodBridge.log")
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func append(category: String, level: AppLogLevel, message: String) {
        let date = Date()
        queue.async { [weak self] in
            self?.append(date: date, category: category, level: level, message: message)
        }
    }

    func text() -> String {
        queue.sync {
            (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
    }

    func fileSize() -> Int64 {
        queue.sync {
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
            return attributes?[.size] as? Int64 ?? 0
        }
    }

    func flush() {
        queue.sync {}
    }

    func clear() throws {
        try queue.sync {
            try Data().write(to: fileURL, options: .atomic)
        }
    }

    func makeExportFile() throws -> URL {
        try queue.sync {
            let stamp = String(Int(Date().timeIntervalSince1970))
            let exportURL = fileManager.temporaryDirectory.appendingPathComponent("PodBridge-diagnostics-\(stamp).txt")
            if fileManager.fileExists(atPath: exportURL.path) {
                try fileManager.removeItem(at: exportURL)
            }
            let body = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            try (diagnosticHeader() + body).write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        }
    }

    private func append(date: Date, category: String, level: AppLogLevel, message: String) {
        rotateIfNeeded()
        let safeMessage = message
            .replacingOccurrences(of: "\r\n", with: " ↵ ")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .replacingOccurrences(of: "\r", with: " ↵ ")
        let line = "\(timestampFormatter.string(from: date)) [\(level.rawValue)] [\(category)] \(safeMessage)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        guard fileSizeWithoutQueue() > Int64(maximumFileSize),
              let data = try? Data(contentsOf: fileURL) else { return }
        let retained = String(decoding: data.suffix(retainedFileSize), as: UTF8.self)
        try? Data(retained.utf8).write(to: fileURL, options: .atomic)
    }

    private func fileSizeWithoutQueue() -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        return attributes?[.size] as? Int64 ?? 0
    }

    private func diagnosticHeader() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let device = UIDevice.current
        return """
        PODBRIDGE DIAGNOSTICS
        Exported: \(exportFormatter.string(from: Date()))
        App: \(version) (\(build))
        Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")
        Device: \(device.model)
        System: \(device.systemName) \(device.systemVersion)
        Privacy: contains selected filenames and playlist names, but not absolute paths, FirewireGuid, or media contents.
        ================================================================================

        """
    }
}
