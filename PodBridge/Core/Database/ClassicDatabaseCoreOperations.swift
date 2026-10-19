// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

extension ClassicDatabase {
    // MARK: - Serialization and shared records

    /// Serializes a complete library and signs it for the selected device.
    static func build(library: ClassicLibrary, firewireID: Data, databaseID: UInt64) throws -> Data {
        guard firewireID.isEmpty || firewireID.count == 8 else { throw PodBridgeError.missingFirewireID }
        var root = BinaryWriter()
        root.tag("mhbd")
        root.u32(244)
        root.u32(0)
        root.u32(1)
        root.u32(0x30)
        root.u32(5)
        root.u64(databaseID)
        root.u16(2)
        root.u16(0)
        root.u64(databaseID ^ 0x504F_4442_5249_4447)
        root.u32(0)
        root.u16(0)
        root.zeros(20)
        root.u16(0x6e65)
        root.u64(databaseID)
        root.u32(0)
        root.u32(0)
        root.zeros(20)
        root.zeros(244 - root.count)

        let rootLibraryID = databaseID ^ 0x504F_4442_5249_4447
        root.bytes(trackSection(library.tracks, rootLibraryID: rootLibraryID))
        root.bytes(playlistSection(library, type: 3))
        root.bytes(playlistSection(library, type: 2))
        root.bytes(albumSection(library.tracks))
        root.bytes(artistSection(library.tracks))
        root.patchU32(UInt32(root.count), at: 8)
        return try Hash58.sign(root.data, firewireID: firewireID)
    }

    static func resigning(existing: Data, firewireID: Data) throws -> EditResult {
        let library = try parse(existing)
        let signed = try Hash58.sign(existing, firewireID: firewireID)
        let diagnostics = try inspect(signed, firewireID: firewireID)
        guard try parse(signed) == library,
              diagnostics.primaryPlaylistFound,
              diagnostics.primaryPlaylistMembers == library.tracks.count,
              diagnostics.playlistSectionsConsistent,
              diagnostics.sortIndexesValid,
              diagnostics.jumpTablesValid,
              diagnostics.hash58Valid else {
            throw PodBridgeError.databaseVerificationFailed
        }
        return EditResult(data: signed, library: library)
    }

    struct TopLevelSection {
        let type: UInt32
        let range: Range<Int>
    }

    static func topLevelSections(_ data: Data, start: Int) throws -> [TopLevelSection] {
        var sections: [TopLevelSection] = []
        var cursor = start
        while cursor + 16 <= data.count, data.ascii(at: cursor, length: 4) == "mhsd" {
            let length = Int(try data.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= data.count else { throw PodBridgeError.invalidDatabase }
            sections.append(TopLevelSection(
                type: try data.littleUInt32(at: cursor + 12),
                range: cursor..<(cursor + length)
            ))
            cursor += length
        }
        guard cursor == data.count else { throw PodBridgeError.invalidDatabase }
        return sections
    }

    static func playlistItem(_ source: Data, settingOrder order: Int) throws -> Data {
        var output = source
        let header = Int(try output.littleUInt32(at: 4))
        var cursor = header
        while cursor + 28 <= output.count {
            let length = Int(try output.littleUInt32(at: cursor + 8))
            guard length > 0, cursor + length <= output.count else { throw PodBridgeError.invalidDatabase }
            if output.ascii(at: cursor, length: 4) == "mhod",
               try output.littleUInt32(at: cursor + 12) == 100 {
                try output.setLittleUInt32(UInt32(order), at: cursor + 24)
                return output
            }
            cursor += length
        }
        return output
    }

    static func updatedSortIndex(_ source: Data, order: [Int]) throws -> Data {
        var updated = Data(source.prefix(72))
        for index in order {
            var value = UInt32(index).littleEndian
            withUnsafeBytes(of: &value) { updated.append(contentsOf: $0) }
        }
        try updated.setLittleUInt32(UInt32(updated.count), at: 8)
        try updated.setLittleUInt32(UInt32(order.count), at: 28)
        return updated
    }
}
