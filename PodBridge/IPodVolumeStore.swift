// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// File-system boundary for an iPod volume exposed through Files.
///
/// The production implementation uses the real `iPod_Control` directory
/// layout. Tests can provide another implementation without changing the
/// database or transaction logic.
protocol IPodVolumeStore {
    var root: URL { get }
    var itunesURL: URL { get }
    var databaseURL: URL { get }

    func readDatabase() throws -> Data
    func writeVerifiedDatabase(_ data: Data, to temporaryURL: URL) throws
    func replaceDatabase(with temporaryURL: URL) throws
    func createBackup(of original: Data) throws -> URL
    func restoreDatabase(_ original: Data) throws
    func removeItem(at url: URL)
}

/// The real on-disk iPod implementation used by the application.
struct LocalIPodVolumeStore: IPodVolumeStore {
    let root: URL
    let manager: FileManager
    private let now: () -> Date

    init(
        root: URL,
        manager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.root = root
        self.manager = manager
        self.now = now
    }

    var itunesURL: URL {
        root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
    }

    var databaseURL: URL {
        itunesURL.appendingPathComponent("iTunesDB")
    }

    func readDatabase() throws -> Data {
        try Data(contentsOf: databaseURL, options: .mappedIfSafe)
    }

    func writeVerifiedDatabase(_ data: Data, to temporaryURL: URL) throws {
        try? manager.removeItem(at: temporaryURL)
        try data.write(to: temporaryURL, options: .atomic)
        if let handle = try? FileHandle(forWritingTo: temporaryURL) {
            try handle.synchronize()
            try handle.close()
        }
        guard try Data(contentsOf: temporaryURL, options: .mappedIfSafe) == data else {
            throw PodBridgeError.databaseVerificationFailed
        }
    }

    func replaceDatabase(with temporaryURL: URL) throws {
        _ = try manager.replaceItemAt(databaseURL, withItemAt: temporaryURL, backupItemName: nil)
    }

    func createBackup(of original: Data) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
        let parent = itunesURL.appendingPathComponent("PodBridge Backups", isDirectory: true)
        var folder = parent.appendingPathComponent(stamp, isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let backupURL = folder.appendingPathComponent("iTunesDB")
        try original.write(to: backupURL, options: .atomic)
        guard try Data(contentsOf: backupURL, options: .mappedIfSafe) == original else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return folder
    }

    func restoreDatabase(_ original: Data) throws {
        try original.write(to: databaseURL, options: .atomic)
    }

    func removeItem(at url: URL) {
        try? manager.removeItem(at: url)
    }
}

/// Coordinates the common database part of a mutating iPod operation.
///
/// The transaction deliberately does not own artwork or audio files. Those
/// resources have their own rollback plans, while this type guarantees that
/// the active `iTunesDB` is restored when database activation fails.
final class IPodDatabaseTransaction {
    let store: IPodVolumeStore
    let original: Data
    let backupURL: URL
    let temporaryURL: URL
    private let afterActivation: (() throws -> Void)?
    private(set) var databaseActivated = false

    init(
        store: IPodVolumeStore,
        original: Data? = nil,
        temporaryName: String,
        backupURL: URL? = nil,
        afterActivation: (() throws -> Void)? = nil
    ) throws {
        self.store = store
        self.afterActivation = afterActivation
        if let original {
            self.original = original
        } else {
            self.original = try store.readDatabase()
        }
        if let backupURL {
            self.backupURL = backupURL
        } else {
            self.backupURL = try store.createBackup(of: self.original)
        }
        self.temporaryURL = store.itunesURL.appendingPathComponent(temporaryName)
    }

    func stage(_ data: Data) throws {
        try store.writeVerifiedDatabase(data, to: temporaryURL)
    }

    func activate() throws {
        try store.replaceDatabase(with: temporaryURL)
        databaseActivated = true
        try afterActivation?()
    }

    func rollback() throws {
        store.removeItem(at: temporaryURL)
        guard databaseActivated else { return }
        do {
            try store.restoreDatabase(original)
            guard try store.readDatabase() == original else {
                throw PodBridgeError.restoreFailed
            }
            databaseActivated = false
        } catch {
            throw PodBridgeError.restoreFailed
        }
    }
}
