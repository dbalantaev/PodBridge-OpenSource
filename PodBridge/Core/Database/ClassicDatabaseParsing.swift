// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    struct Diagnostics: Sendable {
        let playlists: Int
        let primaryPlaylistFound: Bool
        let primaryPlaylistMembers: Int
        let playlistSectionTypes: [UInt32]
        let playlistSectionsConsistent: Bool
        let sortIndexesValid: Bool
        let jumpTablesValid: Bool
        let hash58Valid: Bool
    }

    struct TrackDiagnostics: Sendable {
        let id: UInt32
        let path: String
        let marker: String
        let type1: UInt8
        let type2: UInt8
        let sizePrimary: UInt32
        let sizeRepeated: UInt32
        let rootLibraryIDValid: Bool
        let databaseIDsMatch: Bool
        let primaryMembershipValid: Bool
        let headerValid: Bool

        var isValid: Bool {
            rootLibraryIDValid && databaseIDsMatch && primaryMembershipValid && headerValid
        }
    }

    // MARK: - Parsing and diagnostics

    /// Parses the track and playlist model from an iTunesDB byte buffer.
    static func parse(_ data: Data) throws -> ClassicLibrary {
        guard data.ascii(at: 0, length: 4) == "mhbd" else { throw PodBridgeError.invalidDatabase }
        let headerLength = Int(try data.littleUInt32(at: 4))
        guard headerLength >= 0x6c, headerLength <= data.count else { throw PodBridgeError.invalidDatabase }

        var tracks: [ClassicTrack] = []
        var typeTwoPlaylistRecords: [ParsedPlaylist] = []
        var typeThreePlaylistRecords: [ParsedPlaylist] = []
        var cursor = headerLength
        while cursor + 16 <= data.count, data.ascii(at: cursor, length: 4) == "mhsd" {
            let sectionLength = Int(try data.littleUInt32(at: cursor + 8))
            let sectionType = try data.littleUInt32(at: cursor + 12)
            guard sectionLength > 0, cursor + sectionLength <= data.count else { throw PodBridgeError.invalidDatabase }
            if sectionType == 1 {
                tracks = try parseTracks(data, section: cursor..<(cursor + sectionLength))
            } else if sectionType == 2 {
                typeTwoPlaylistRecords = try parsePlaylistRecords(data, section: cursor..<(cursor + sectionLength))
            } else if sectionType == 3 {
                typeThreePlaylistRecords = try parsePlaylistRecords(data, section: cursor..<(cursor + sectionLength))
            }
            cursor += sectionLength
        }
        guard !tracks.isEmpty || data.count < 1_024 * 1_024 else { throw PodBridgeError.invalidDatabase }
        // Classic firmware and libgpod prefer the type-3 playlist copy when it exists.
        // Reading type 2 first hid stale type-3 primary playlists from verification.
        let playlistRecords = typeThreePlaylistRecords.isEmpty ? typeTwoPlaylistRecords : typeThreePlaylistRecords
        let primary = playlistRecords.first(where: \.isPrimary)
        return ClassicLibrary(
            name: primary?.playlist.name ?? "iPod",
            tracks: tracks,
            playlists: playlistRecords.filter { !$0.isPrimary }.map(\.playlist)
        )
    }

    /// Validates structural invariants and the device-specific database hash.
    static func inspect(_ data: Data, firewireID: Data) throws -> Diagnostics {
        let headerLength = Int(try data.littleUInt32(at: 4))
        let sections = try topLevelSections(data, start: headerLength)
        let playlistSections = sections.filter { $0.type == 2 || $0.type == 3 }
        var recordsByType: [UInt32: [ParsedPlaylist]] = [:]
        var auditsByType: [UInt32: (Bool, Bool)] = [:]
        for section in playlistSections {
            recordsByType[section.type] = try parsePlaylistRecords(data, section: section.range)
            auditsByType[section.type] = try primaryIndexAudit(data, section: section.range)
        }
        let primaryType: UInt32? = recordsByType[3] == nil ? (recordsByType[2] == nil ? nil : 2) : 3
        let records = primaryType.flatMap { recordsByType[$0] } ?? []
        let primary = records.first(where: \.isPrimary)
        let primaryIDs = playlistSections.compactMap { section in
            recordsByType[section.type]?.first(where: \.isPrimary)?.playlist.trackIDs
        }
        let sectionsConsistent = !primaryIDs.isEmpty && primaryIDs.dropFirst().allSatisfy { $0 == primaryIDs.first }
        let indexAudits = playlistSections.compactMap { auditsByType[$0.type] }
        return Diagnostics(
            playlists: records.filter { !$0.isPrimary }.count,
            primaryPlaylistFound: primary != nil,
            primaryPlaylistMembers: primary?.playlist.trackIDs.count ?? 0,
            playlistSectionTypes: playlistSections.map(\.type),
            playlistSectionsConsistent: sectionsConsistent,
            sortIndexesValid: !indexAudits.isEmpty && indexAudits.allSatisfy { $0.0 },
            jumpTablesValid: !indexAudits.isEmpty && indexAudits.allSatisfy { $0.1 },
            hash58Valid: try Hash58.verify(data, firewireID: firewireID)
        )
    }

    /// Audits one serialized track against the expected imported record.
    static func inspectTrack(_ data: Data, expected track: ClassicTrack) throws -> TrackDiagnostics {
        let headerLength = Int(try data.littleUInt32(at: 4))
        let sections = try topLevelSections(data, start: headerLength)
        guard let trackSection = sections.first(where: { $0.type == 1 }) else {
            throw PodBridgeError.invalidDatabase
        }
        let recordRange = try trackRecordRange(in: data, section: trackSection.range, id: track.id)
        let recordOffset = recordRange.lowerBound
        let recordHeader = Int(try data.littleUInt32(at: recordOffset + 4))
        guard recordHeader >= 0x248 else { throw PodBridgeError.databaseVerificationFailed }
        let strings = try recordStrings(
            in: data,
            firstChild: recordOffset + recordHeader,
            recordEnd: recordRange.upperBound,
            minimumLength: 40
        )

        let marker = data.ascii(at: recordOffset + 0x18, length: 4) ?? ""
        let type1 = data[recordOffset + 0x1c]
        let type2 = data[recordOffset + 0x1d]
        let sizePrimary = try data.littleUInt32(at: recordOffset + 0x24)
        let sizeRepeated = try data.littleUInt32(at: recordOffset + 0x12c)
        let dbid = try data.littleUInt64(at: recordOffset + 0x70)
        let dbid2 = try data.littleUInt64(at: recordOffset + 0xa8)
        let rootLibraryID = try data.littleUInt64(at: 0x24)
        let trackRootLibraryID = try data.littleUInt64(at: recordOffset + 0x124)
        let primaryLists = sections.filter { $0.type == 2 || $0.type == 3 }.compactMap { section -> [UInt32]? in
            try? parsePlaylistRecords(data, section: section.range).first(where: \.isPrimary)?.playlist.trackIDs
        }
        let memberValid = !primaryLists.isEmpty && primaryLists.allSatisfy { ids in
            ids.filter { $0 == track.id }.count == 1
        }
        let headerValid = try trackHeaderIsValid(
            data,
            offset: recordOffset,
            track: track,
            strings: strings
        )
        return TrackDiagnostics(
            id: track.id,
            path: strings[2] ?? "",
            marker: marker,
            type1: type1,
            type2: type2,
            sizePrimary: sizePrimary,
            sizeRepeated: sizeRepeated,
            rootLibraryIDValid: trackRootLibraryID == rootLibraryID && rootLibraryID != 0,
            databaseIDsMatch: dbid == track.databaseID && dbid2 == track.databaseID && dbid != 0,
            primaryMembershipValid: memberValid,
            headerValid: headerValid
        )
    }

    private static func primaryIndexAudit(_ data: Data, section: Range<Int>) throws -> (Bool, Bool) {
        let sectionHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + sectionHeader
        guard data.ascii(at: list, length: 4) == "mhlp" else { return (false, false) }
        var playlist = list + Int(try data.littleUInt32(at: list + 4))
        while playlist + 24 <= section.upperBound, data.ascii(at: playlist, length: 4) == "mhyp" {
            let header = Int(try data.littleUInt32(at: playlist + 4))
            let total = Int(try data.littleUInt32(at: playlist + 8))
            guard total >= header, playlist + total <= section.upperBound else { throw PodBridgeError.invalidDatabase }
            if try data.littleUInt32(at: playlist + 20) != 0 {
                let members = try data.littleUInt32(at: playlist + 16)
                var child = playlist + header
                var sortCounts: [UInt32] = []
                var jumpCounts: [UInt32] = []
                while child + 16 <= playlist + total, data.ascii(at: child, length: 4) == "mhod" {
                    let length = Int(try data.littleUInt32(at: child + 8))
                    guard length > 0, child + length <= playlist + total else { throw PodBridgeError.invalidDatabase }
                    let type = try data.littleUInt32(at: child + 12)
                    if type == 52, length >= 32 {
                        sortCounts.append(try data.littleUInt32(at: child + 28))
                    } else if type == 53, length >= 40 {
                        let entries = Int(try data.littleUInt32(at: child + 28))
                        guard 40 + entries * 12 <= length else { throw PodBridgeError.invalidDatabase }
                        var sum: UInt32 = 0
                        for index in 0..<entries { sum += try data.littleUInt32(at: child + 48 + index * 12) }
                        jumpCounts.append(sum)
                    }
                    child += length
                }
                return (
                    !sortCounts.isEmpty && sortCounts.allSatisfy { $0 == members },
                    !jumpCounts.isEmpty && jumpCounts.allSatisfy { $0 == members }
                )
            }
            playlist += total
        }
        return (false, false)
    }

    private static func trackHeaderIsValid(
        _ data: Data,
        offset: Int,
        track: ClassicTrack,
        strings: [UInt32: String]
    ) throws -> Bool {
        let format = trackFormat(track)
        let artworkLink = try data.littleUInt32(at: offset + 0x160)
        let artworkCount = try data.littleUInt16(at: offset + 0x7c)
        let artworkValid = track.artworkImageID == 0
            ? data[offset + 0xa4] == 2 && artworkLink == 0
            : data[offset + 0xa4] == 1 && artworkCount == 1 && artworkLink == track.artworkImageID
        return try data.littleUInt32(at: offset + 0x14) == 1
            && data.ascii(at: offset + 0x18, length: 4) == format.marker
            && data[offset + 0x1c] == format.type1
            && data[offset + 0x1d] == format.type2
            && (data[offset + 0x1e] != 0) == track.compilation
            && data.littleUInt32(at: offset + 0x24) == track.byteCount
            && data.littleUInt32(at: offset + 0x12c) == track.byteCount
            && data.littleUInt32(at: offset + 0x28) == track.durationMS
            && data.littleUInt32(at: offset + 0x3c) == track.sampleRate << 16
            && data.littleUInt32(at: offset + 0x88) == Float(track.sampleRate).bitPattern
            && data.littleUInt32(at: offset + 0xd0) == 1
            && data.littleUInt32(at: offset + 0x120) == track.albumID
            && data.littleUInt32(at: offset + 0x130) == 0
            && data.littleUInt64(at: offset + 0x134) != 0
            && data.littleUInt32(at: offset + 0x168) == 1
            && data.littleUInt32(at: offset + 0x1e0) == track.artistID
            && strings[1] == track.title
            && strings[2] == track.ipodPath
            && (strings[22] ?? "") == track.albumArtist
            && artworkValid
    }

    private static func parseTracks(_ data: Data, section: Range<Int>) throws -> [ClassicTrack] {
        let mhsdHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + mhsdHeader
        guard data.ascii(at: list, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        var cursor = list + Int(try data.littleUInt32(at: list + 4))
        var tracks: [ClassicTrack] = []
        while cursor + 16 <= section.upperBound, data.ascii(at: cursor, length: 4) == "mhit" {
            let header = Int(try data.littleUInt32(at: cursor + 4))
            let total = Int(try data.littleUInt32(at: cursor + 8))
            guard header >= 156, total >= header, cursor + total <= section.upperBound else {
                throw PodBridgeError.invalidDatabase
            }
            tracks.append(try parsedTrack(
                data,
                offset: cursor,
                header: header,
                total: total
            ))
            cursor += total
        }
        return tracks
    }

    private static func parsedTrack(
        _ data: Data,
        offset: Int,
        header: Int,
        total: Int
    ) throws -> ClassicTrack {
        let strings = try recordStrings(
            in: data,
            firstChild: offset + header,
            recordEnd: offset + total,
            minimumLength: 24
        )
        return ClassicTrack(
                id: try data.littleUInt32(at: offset + 0x10),
                databaseID: try data.littleUInt64(at: offset + 0x70),
                title: strings[1] ?? "Unknown Track",
                artist: strings[4] ?? "Unknown Artist",
                album: strings[3] ?? "Unknown Album",
                genre: strings[5] ?? "",
                fileType: strings[6] ?? "AAC audio file",
                ipodPath: strings[2] ?? "",
                byteCount: try data.littleUInt32(at: offset + 0x24),
                durationMS: try data.littleUInt32(at: offset + 0x28),
                trackNumber: try data.littleUInt32(at: offset + 0x2c),
                year: try data.littleUInt32(at: offset + 0x34),
                bitrate: try data.littleUInt32(at: offset + 0x38),
                sampleRate: try data.littleUInt32(at: offset + 0x3c) >> 16,
                dateAdded: try data.littleUInt32(at: offset + 0x68),
                rating: data[offset + 0x1f],
                playCount: try data.littleUInt32(at: offset + 0x50),
                skipCount: header >= 0xa4 ? try data.littleUInt32(at: offset + 0x9c) : 0,
                lastPlayed: try data.littleUInt32(at: offset + 0x58),
                lastSkipped: header >= 0xa4 ? try data.littleUInt32(at: offset + 0xa0) : 0,
                albumID: header >= 0x124 ? try data.littleUInt32(at: offset + 0x120) : 0,
                artistID: header >= 0x1e4 ? try data.littleUInt32(at: offset + 0x1e0) : 0,
                artworkImageID: header >= 0x164 ? try data.littleUInt32(at: offset + 0x160) : 0,
                artworkByteCount: header >= 0x84 ? try data.littleUInt32(at: offset + 0x80) : 0,
                artworkData: nil,
                sourceURL: nil,
                sortTitle: strings[27] ?? "",
                sortArtist: strings[23] ?? "",
                sortAlbum: strings[28] ?? "",
                sortAlbumArtist: strings[29] ?? "",
                albumArtist: strings[22] ?? "",
                compilation: data[offset + 0x1e] != 0
            )
    }

    private static func trackRecordRange(in data: Data, section: Range<Int>, id: UInt32) throws -> Range<Int> {
        let sectionHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + sectionHeader
        guard data.ascii(at: list, length: 4) == "mhlt" else { throw PodBridgeError.invalidDatabase }
        var cursor = list + Int(try data.littleUInt32(at: list + 4))
        while cursor + 16 <= section.upperBound, data.ascii(at: cursor, length: 4) == "mhit" {
            let total = Int(try data.littleUInt32(at: cursor + 8))
            guard total > 0, cursor + total <= section.upperBound else { throw PodBridgeError.invalidDatabase }
            if try data.littleUInt32(at: cursor + 0x10) == id { return cursor..<(cursor + total) }
            cursor += total
        }
        throw PodBridgeError.databaseVerificationFailed
    }

    private static func recordStrings(
        in data: Data,
        firstChild: Int,
        recordEnd: Int,
        minimumLength: Int
    ) throws -> [UInt32: String] {
        var strings: [UInt32: String] = [:]
        var child = firstChild
        while child + 40 <= recordEnd, data.ascii(at: child, length: 4) == "mhod" {
            let length = Int(try data.littleUInt32(at: child + 8))
            let type = try data.littleUInt32(at: child + 12)
            guard length >= minimumLength, child + length <= recordEnd else { throw PodBridgeError.invalidDatabase }
            if length >= 40 {
                let stringLength = min(Int(try data.littleUInt32(at: child + 28)), length - 40)
                strings[type] = String(
                    data: data[(child + 40)..<(child + 40 + stringLength)],
                    encoding: .utf16LittleEndian
                )
            }
            child += length
        }
        return strings
    }

    private struct ParsedPlaylist {
        let playlist: ClassicPlaylist
        let isPrimary: Bool
    }

    private static func parsePlaylistRecords(_ data: Data, section: Range<Int>) throws -> [ParsedPlaylist] {
        let sectionHeader = Int(try data.littleUInt32(at: section.lowerBound + 4))
        let list = section.lowerBound + sectionHeader
        guard data.ascii(at: list, length: 4) == "mhlp" else { return [] }
        var cursor = list + Int(try data.littleUInt32(at: list + 4))
        var result: [ParsedPlaylist] = []
        while cursor + 20 <= section.upperBound, data.ascii(at: cursor, length: 4) == "mhyp" {
            let header = Int(try data.littleUInt32(at: cursor + 4))
            let total = Int(try data.littleUInt32(at: cursor + 8))
            guard total >= header, cursor + total <= section.upperBound else { throw PodBridgeError.invalidDatabase }
            var name = "Playlist"
            var ids: [UInt32] = []
            var child = cursor + header
            while child + 16 <= cursor + total {
                let tag = data.ascii(at: child, length: 4)
                let length = Int(try data.littleUInt32(at: child + 8))
                guard length > 0, child + length <= cursor + total else { break }
                if tag == "mhod", try data.littleUInt32(at: child + 12) == 1, length >= 40 {
                    let stringLength = min(Int(try data.littleUInt32(at: child + 28)), length - 40)
                    name = String(
                        data: data[(child + 40)..<(child + 40 + stringLength)],
                        encoding: .utf16LittleEndian
                    ) ?? name
                } else if tag == "mhip", length >= 28 {
                    ids.append(try data.littleUInt32(at: child + 24))
                }
                child += length
            }
            let isPrimary: Bool
            if header >= 24 {
                isPrimary = try data.littleUInt32(at: cursor + 20) != 0
            } else {
                isPrimary = false
            }
            result.append(ParsedPlaylist(
                playlist: ClassicPlaylist(name: name, trackIDs: ids),
                isPrimary: isPrimary
            ))
            cursor += total
        }
        return result
    }
}
