// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

struct BinaryWriter {
    private(set) var data = Data()

    var count: Int { data.count }

    mutating func tag(_ value: String) {
        data.append(contentsOf: value.utf8)
    }

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    mutating func u32(_ value: UInt32) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    mutating func zeros(_ count: Int) {
        data.append(Data(repeating: 0, count: count))
    }

    mutating func bytes(_ value: Data) { data.append(value) }

    mutating func patchU16(_ value: UInt16, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + 2), with: $0) }
    }

    mutating func patchU32(_ value: UInt32, at offset: Int) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    mutating func patchBytes(_ value: Data, at offset: Int) {
        data.replaceSubrange(offset..<(offset + value.count), with: value)
    }
}

extension Data {
    mutating func setLittleUInt16(_ value: UInt16, at offset: Int) throws {
        guard offset >= 0, offset + 2 <= count else { throw PodBridgeError.invalidDatabase }
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset..<(offset + 2), with: $0) }
    }

    mutating func setLittleUInt32(_ value: UInt32, at offset: Int) throws {
        guard offset >= 0, offset + 4 <= count else { throw PodBridgeError.invalidDatabase }
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    func littleUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { throw PodBridgeError.invalidDatabase }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw PodBridgeError.invalidDatabase }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func littleUInt64(at offset: Int) throws -> UInt64 {
        UInt64(try littleUInt32(at: offset)) | (UInt64(try littleUInt32(at: offset + 4)) << 32)
    }

    func ascii(at offset: Int, length: Int) -> String? {
        guard offset >= 0, offset + length <= count else { return nil }
        return String(data: self[offset..<(offset + length)], encoding: .ascii)
    }
}
