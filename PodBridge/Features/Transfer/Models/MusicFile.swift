// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

/// A source audio file selected for import into an iPod library.
///
/// The URL remains outside the iPod database; only the relative path and
/// validated byte count are used while copying the file to the destination.
struct MusicFile: Identifiable, Hashable, Sendable {
    let sourceURL: URL
    let relativePath: String
    let byteCount: Int64
    let preview: Preview?

    struct Preview: Hashable, Sendable {
        let title: String
        let artist: String
        let album: String
    }

    init(sourceURL: URL, relativePath: String, byteCount: Int64, preview: Preview? = nil) {
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.preview = preview
    }

    var id: String { sourceURL.path }
    var name: String { sourceURL.lastPathComponent }

    var displayTitle: String {
        let value = preview?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? sourceURL.deletingPathExtension().lastPathComponent : value
    }

    var displayArtist: String? {
        let value = preview?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value == "Unknown Artist" ? nil : value
    }
}

struct SourcePlaylist: Identifiable, Hashable, Sendable {
    let name: String
    let fileIndices: [Int]
    var artworkData: Data? = nil
    var artworkFilename: String? = nil

    var id: String { name + ":" + fileIndices.map(String.init).joined(separator: ",") }
}

struct SourceScanReport: Sendable {
    let files: [MusicFile]
    let skippedAudioByExtension: [String: Int]

    var skippedAudioCount: Int { skippedAudioByExtension.values.reduce(0, +) }
}

struct SourceImportSelection: Sendable {
    let files: [MusicFile]
    let playlists: [SourcePlaylist]
}

struct TransferSummary: Sendable {
    let copied: Int
    let destinationName: String
}

enum IPodDeviceProfile: String, CaseIterable, Identifiable, Sendable {
    case mini1And2
    case classic7
    case classic6
    case video5
    case nano1And2
    case nano3
    case nano4

    enum Checksum: Sendable, Equatable {
        case none
        case hash58
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mini1And2: "iPod mini 1st / 2nd gen"
        case .classic7: "iPod Classic 7th gen (160 GB)"
        case .classic6: "iPod Classic 6th / 6.5th gen"
        case .video5: "iPod Video 5th / 5.5th gen"
        case .nano1And2: "iPod nano 1st / 2nd gen"
        case .nano3: "iPod nano 3rd gen"
        case .nano4: "iPod nano 4th gen"
        }
    }

    var shortTitle: String {
        switch self {
        case .mini1And2: "mini 1G / 2G"
        case .classic7: "Classic 7G"
        case .classic6: "Classic 6G / 6.5G"
        case .video5: "Video 5G / 5.5G"
        case .nano1And2: "nano 1G / 2G"
        case .nano3: "nano 3G"
        case .nano4: "nano 4G"
        }
    }

    var checksum: Checksum {
        switch self {
        case .classic7, .classic6, .nano3, .nano4: .hash58
        case .mini1And2, .video5, .nano1And2: .none
        }
    }

    var isHardwareTested: Bool { self == .classic7 }

    static func save(_ profile: Self, for root: URL) {
        var selections = UserDefaults.standard.dictionary(forKey: "PodBridge.deviceProfiles") as? [String: String] ?? [:]
        selections[root.lastPathComponent] = profile.rawValue
        UserDefaults.standard.set(selections, forKey: "PodBridge.deviceProfiles")
    }

    static func saved(for root: URL) -> Self? {
        let selections = UserDefaults.standard.dictionary(forKey: "PodBridge.deviceProfiles") as? [String: String]
        return selections?[root.lastPathComponent].flatMap(Self.init(rawValue:))
    }

    static func databaseKey(at root: URL) throws -> Data {
        let profile = saved(for: root) ?? .classic7
        switch profile.checksum {
        case .none: return Data()
        case .hash58: return try ClassicDatabase.firewireID(at: root)
        }
    }
}

enum IPodDiskUseStatus: Equatable, Sendable {
    case unavailable
    case disabled
    case enabled
}

/// Reads the legacy "enable disk use" bit used by classic iPods and updates it
/// only when the known preference structures can be validated first.
enum IPodDiskUsePreferences {
    private static let flagOffset = 0x1f

    private struct Snapshot {
        let rawURL: URL
        let raw: Data
        let plistURL: URL
        let plist: Data?
        let plistObject: [String: Any]?
        let plistFormat: PropertyListSerialization.PropertyListFormat?
    }

    static func status(at root: URL) -> IPodDiskUseStatus {
        guard let snapshot = try? snapshot(at: root) else { return .unavailable }
        let rawEnabled = snapshot.raw[flagOffset] != 0
        guard let plistObject = snapshot.plistObject else {
            return rawEnabled ? .enabled : .disabled
        }
        guard let preferences = plistObject["iPodPrefs"] as? Data,
              preferences.count > flagOffset else { return .unavailable }
        return rawEnabled && preferences[flagOffset] != 0 ? .enabled : .disabled
    }

    @discardableResult
    static func enable(at root: URL) throws -> URL {
        let snapshot = try snapshot(at: root)
        let manager = FileManager.default
        let backups = root.appendingPathComponent("iPod_Control/iTunes/PodBridge Settings Backups", isDirectory: true)
        let backup = backups.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        try snapshot.raw.write(to: backup.appendingPathComponent("iTunesPrefs"), options: .atomic)
        if let plist = snapshot.plist {
            try plist.write(to: backup.appendingPathComponent("iTunesPrefs.plist"), options: .atomic)
        }

        var raw = snapshot.raw
        raw[flagOffset] = 1
        var plistData: Data?
        if var object = snapshot.plistObject,
           var preferences = object["iPodPrefs"] as? Data,
           let format = snapshot.plistFormat {
            preferences[flagOffset] = 1
            object["iPodPrefs"] = preferences
            plistData = try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
        }

        do {
            try raw.write(to: snapshot.rawURL, options: .atomic)
            if let plistData { try plistData.write(to: snapshot.plistURL, options: .atomic) }
            guard status(at: root) == .enabled else { throw UpdateError.verificationFailed }
            AppLogger.device("Enabled persistent disk use; settings backup=\(backup.lastPathComponent)", level: .info)
            return backup
        } catch {
            try? snapshot.raw.write(to: snapshot.rawURL, options: .atomic)
            if let plist = snapshot.plist { try? plist.write(to: snapshot.plistURL, options: .atomic) }
            throw error
        }
    }

    private static func snapshot(at root: URL) throws -> Snapshot {
        let iTunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
        let rawURL = iTunes.appendingPathComponent("iTunesPrefs")
        let plistURL = iTunes.appendingPathComponent("iTunesPrefs.plist")
        let raw = try Data(contentsOf: rawURL)
        guard raw.count > flagOffset else { throw UpdateError.unknownFormat }

        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return Snapshot(rawURL: rawURL, raw: raw, plistURL: plistURL, plist: nil, plistObject: nil, plistFormat: nil)
        }
        let plist = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let object = try PropertyListSerialization.propertyList(from: plist, format: &format) as? [String: Any],
              let preferences = object["iPodPrefs"] as? Data,
              preferences.count > flagOffset else { throw UpdateError.unknownFormat }
        return Snapshot(rawURL: rawURL, raw: raw, plistURL: plistURL, plist: plist, plistObject: object, plistFormat: format)
    }

    private enum UpdateError: LocalizedError {
        case unknownFormat
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .unknownFormat:
                return "This iPod uses an unknown settings format, so PodBridge did not change it."
            case .verificationFailed:
                return "The disk-use setting could not be verified. The original settings were restored."
            }
        }
    }
}

enum PodBridgeError: LocalizedError {
    case noSourceFolder
    case noDestinationFolder
    case noMusicFiles
    case cannotCreateImportFolder
    case notAnIPod
    case missingFirewireID
    case invalidFirewireID
    case invalidDatabase
    case databaseVerificationFailed
    case cannotCreateTrackFile
    case restoreFailed
    case unsupportedArtworkDatabase
    case invalidArtwork
    case unsupportedAudio
    case audioCopyVerificationFailed
    case libraryRestoreRequired
    case trackNotFound
    case deletionBackupFailed
    case deletionRestoreUnavailable
    case invalidMetadata
    case playlistNotFound
    case duplicatePlaylistName
    case playlistHasNoCompilationAlbum
    case deviceModelRequired

    var errorDescription: String? {
        switch self {
        case .noSourceFolder:
            return "Choose a music folder first."
        case .noDestinationFolder:
            return "Choose the iPod destination folder first."
        case .noMusicFiles:
            return "No supported music files were found in this folder."
        case .cannotCreateImportFolder:
            return "PodBridge could not create its import folder on the destination."
        case .notAnIPod:
            return "The selected folder is not an initialized iPod. Select the disk root containing iPod_Control."
        case .missingFirewireID:
            return "The iPod signature ID is missing. Enter its 16 hexadecimal digits before writing the library."
        case .invalidFirewireID:
            return "The iPod signature ID must contain exactly 16 hexadecimal digits."
        case .invalidDatabase:
            return "The existing iTunesDB format is invalid or unsupported. Nothing was changed."
        case .databaseVerificationFailed:
            return "The new iTunesDB failed verification. The existing library was left unchanged."
        case .cannotCreateTrackFile:
            return "PodBridge could not allocate a unique track filename."
        case .restoreFailed:
            return "The iTunesDB replacement failed and automatic restore also failed. Reconnect the iPod to a computer and restore the PodBridge backup."
        case .unsupportedArtworkDatabase:
            return "This iPod ArtworkDB uses image formats PodBridge does not support yet. Nothing was changed."
        case .invalidArtwork:
            return "An embedded cover image could not be decoded safely. Nothing was changed."
        case .unsupportedAudio:
            return "This audio file does not contain a playable iPod-compatible MP3, AAC, Apple Lossless, WAV, or AIFF stream. Nothing was changed."
        case .audioCopyVerificationFailed:
            return "The copied audio file failed size verification. The library was not changed."
        case .libraryRestoreRequired:
            return "The iPod's duplicate playlist sections do not agree. Restore the oldest known-good PodBridge backup before syncing again."
        case .trackNotFound:
            return "The selected track is no longer present in the iPod library. Refresh the library and try again."
        case .deletionBackupFailed:
            return "PodBridge could not create and verify the local backup, so the track was not deleted."
        case .deletionRestoreUnavailable:
            return "This deletion can no longer be restored because the iPod library changed after it."
        case .invalidMetadata:
            return "Title, artist, album, and playlist names cannot be empty."
        case .playlistNotFound:
            return "The selected playlist is no longer present in the iPod library. Refresh and try again."
        case .duplicatePlaylistName:
            return "Another playlist already uses this name."
        case .playlistHasNoCompilationAlbum:
            return "This playlist has no PodBridge compilation album whose Cover Flow artwork can be changed."
        case .deviceModelRequired:
            return "Choose the iPod model before writing its library."
        }
    }
}
