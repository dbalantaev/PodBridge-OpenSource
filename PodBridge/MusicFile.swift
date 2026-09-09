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

    var id: String { sourceURL.path }
    var name: String { sourceURL.lastPathComponent }
}

struct SourcePlaylist: Identifiable, Hashable, Sendable {
    let name: String
    let fileIndices: [Int]
    var artworkData: Data? = nil
    var artworkFilename: String? = nil

    var id: String { name + ":" + fileIndices.map(String.init).joined(separator: ",") }
}

struct TransferSummary: Sendable {
    let copied: Int
    let destinationName: String
}

enum IPodDeviceProfile: String, CaseIterable, Identifiable, Sendable {
    case classic7
    case classic6
    case video5
    case nano1And2
    case nano3
    case nano4

    enum Checksum: Sendable {
        case none
        case hash58
    }

    var id: String { rawValue }

    var title: String {
        switch self {
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
        case .video5, .nano1And2: .none
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
