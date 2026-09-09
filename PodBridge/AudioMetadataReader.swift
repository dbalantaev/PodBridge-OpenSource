// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import AVFoundation
import Foundation

/// Extracts iPod-compatible metadata from source audio files with AVFoundation.
///
/// Metadata reading is intentionally isolated from destination writes so scans
/// can be cancelled before any iPod state is changed.
enum AudioMetadataReader {
    /// Release identity used to distinguish editions while grouping albums.
    struct AlbumIdentity: Sendable, Equatable {
        let albumArtist: String
        let releaseID: String
    }

    /// Reads metadata, stream properties, and embedded artwork for one file.
    static func read(_ file: MusicFile) async throws -> ClassicTrack {
        let asset = AVURLAsset(url: file.sourceURL)
        let duration = try await asset.load(.duration)
        let metadata = try await asset.load(.commonMetadata)
        let metadataFormats = try await asset.load(.availableMetadataFormats)
        var containerMetadata = metadata
        for format in metadataFormats {
            containerMetadata.append(contentsOf: try await asset.loadMetadata(for: format))
        }
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
              duration.isNumeric,
              duration.seconds > 0 else {
            throw PodBridgeError.unsupportedAudio
        }

        var values: [AVMetadataKey: String] = [:]
        for item in metadata {
            guard let key = item.commonKey, let value = try? await item.load(.stringValue) else { continue }
            values[key] = value
        }
        var artworkData: Data?
        if let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork }) {
            artworkData = try? await artworkItem.load(.dataValue)
        }

        let guessed = file.sourceURL.deletingPathExtension().lastPathComponent
        let title = values[.commonKeyTitle] ?? guessed
        let artist = values[.commonKeyArtist] ?? "Unknown Artist"
        let album = values[.commonKeyAlbumName] ?? file.sourceURL.deletingLastPathComponent().lastPathComponent
        let explicitSortTitle = await sortMetadataValue(
            in: containerMetadata,
            rawKeys: ["sonm", "tsot"],
            identifiers: [.id3MetadataTitleSortOrder]
        )
        let explicitSortArtist = await sortMetadataValue(
            in: containerMetadata,
            rawKeys: ["soar", "tsop"],
            identifiers: [.id3MetadataPerformerSortOrder]
        )
        let explicitSortAlbum = await sortMetadataValue(
            in: containerMetadata,
            rawKeys: ["soal", "tsoa"],
            identifiers: [.id3MetadataAlbumSortOrder]
        )
        let explicitSortAlbumArtist = await sortMetadataValue(
            in: containerMetadata,
            rawKeys: ["soaa"],
            identifiers: []
        )
        let albumIdentity = await albumIdentity(in: containerMetadata)
        let estimatedBitrate = try await audioTrack.load(.estimatedDataRate)
        let descriptions = try await audioTrack.load(.formatDescriptions)
        guard let streamDescription = descriptions.first.flatMap({
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }) else {
            throw PodBridgeError.unsupportedAudio
        }
        let fileType: String
        switch streamDescription.mFormatID {
        case kAudioFormatMPEGLayer3:
            fileType = "MPEG audio file"
        case kAudioFormatAppleLossless:
            fileType = "Apple Lossless audio file"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            fileType = "AAC audio file"
        case kAudioFormatLinearPCM:
            let ext = file.sourceURL.pathExtension.lowercased()
            fileType = ext == "wav" ? "WAV audio file" : "AIFF audio file"
        default:
            throw PodBridgeError.unsupportedAudio
        }
        let sampleRate = descriptions.first.flatMap { description in
            CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mSampleRate
        } ?? 44_100
        return ClassicTrack(
            id: 0,
            databaseID: 0,
            title: title,
            artist: artist,
            album: album,
            genre: values[.commonKeyType] ?? "",
            fileType: fileType,
            ipodPath: "",
            byteCount: UInt32(clamping: file.byteCount),
            durationMS: UInt32(clamping: Int64(max(0, duration.seconds) * 1_000)),
            trackNumber: parseLeadingNumber(from: guessed),
            year: 0,
            bitrate: UInt32(clamping: Int64(estimatedBitrate / 1_000)),
            sampleRate: UInt32(clamping: Int64(sampleRate)),
            dateAdded: macTime(Date()),
            artworkData: artworkData,
            sourceURL: file.sourceURL,
            sortTitle: explicitSortTitle,
            sortArtist: explicitSortArtist.isEmpty ? articleIndependentSortValue(artist) : explicitSortArtist,
            sortAlbum: explicitSortAlbum.isEmpty ? articleIndependentSortValue(album) : explicitSortAlbum,
            sortAlbumArtist: explicitSortAlbumArtist,
            albumArtist: albumIdentity.albumArtist,
            sourceAlbumID: albumIdentity.releaseID
        )
    }

    static func albumIdentity(at url: URL) async -> AlbumIdentity {
        let asset = AVURLAsset(url: url)
        guard let formats = try? await asset.load(.availableMetadataFormats) else {
            return AlbumIdentity(albumArtist: "", releaseID: "")
        }
        var metadata: [AVMetadataItem] = []
        for format in formats {
            if let items = try? await asset.loadMetadata(for: format) {
                metadata.append(contentsOf: items)
            }
        }
        return await albumIdentity(in: metadata)
    }

    private static func albumIdentity(in metadata: [AVMetadataItem]) async -> AlbumIdentity {
        let albumArtist = await flexibleMetadataValue(
            in: metadata,
            exactKeys: ["aart", "tpe2", "album_artist", "albumartist"],
            keyFragments: ["albumartist", "album_artist"]
        )
        let upc = await flexibleMetadataValue(
            in: metadata,
            exactKeys: ["upc", "barcode"],
            keyFragments: [":upc", ".upc", "barcode"]
        )
        return AlbumIdentity(
            albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            releaseID: upc.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func flexibleMetadataValue(
        in metadata: [AVMetadataItem],
        exactKeys: Set<String>,
        keyFragments: [String]
    ) async -> String {
        for item in metadata {
            let key = metadataKeyString(item)
            guard exactKeys.contains(key) || keyFragments.contains(where: key.contains) else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func sortMetadataValue(
        in metadata: [AVMetadataItem],
        rawKeys: Set<String>,
        identifiers: Set<AVMetadataIdentifier>
    ) async -> String {
        for item in metadata {
            if let identifier = item.identifier, identifiers.contains(identifier),
               let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
            let key = metadataKeyString(item)
            if rawKeys.contains(key),
               let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func metadataKeyString(_ item: AVMetadataItem) -> String {
        if let key = item.key as? String { return key.lowercased() }
        if let number = item.key as? NSNumber {
            let value = number.uint32Value
            let bytes: [UInt8] = [
                UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
            ]
            return String(bytes: bytes, encoding: .ascii)?.lowercased() ?? ""
        }
        return item.identifier?.rawValue.lowercased() ?? ""
    }

    private static func articleIndependentSortValue(_ value: String) -> String {
        for article in ["The ", "An ", "A "] where value.range(
            of: article,
            options: [.caseInsensitive, .anchored],
            range: value.startIndex..<value.endIndex,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil {
            return String(value.dropFirst(article.count))
        }
        return ""
    }

    private static func parseLeadingNumber(from value: String) -> UInt32 {
        UInt32(value.prefix { $0.isNumber }) ?? 0
    }

    static func macTime(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970) + 2_082_844_800)
    }
}
