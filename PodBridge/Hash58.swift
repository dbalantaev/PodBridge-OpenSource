// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev
//
// Hash58 algorithm based on libgpod src/itdb_hash58.c,
// Copyright (C) 2007 Christophe Fergeau.
// See THIRD_PARTY_NOTICES.md for the BSD-3-Clause license.

import CryptoKit
import Foundation

/// Implements the device-specific Hash58 signature used by supported iPods.
///
/// Video 5G/5.5G and nano 1G/2G use the same database family without a
/// checksum. An empty key therefore preserves their checksum fields unchanged.
enum Hash58 {
    /// Verifies that a database contains the signature derived from `firewireID`.
    static func verify(_ database: Data, firewireID: Data) throws -> Bool {
        try sign(database, firewireID: firewireID) == database
    }

    /// Returns a copy of the database with its Hash58 signature recalculated.
    static func sign(_ database: Data, firewireID: Data) throws -> Data {
        if firewireID.isEmpty { return database }
        guard database.count >= 0x6c, firewireID.count == 8 else { throw PodBridgeError.invalidDatabase }
        var result = database
        let savedID = result[0x18..<0x20]
        let savedUnknown = result[0x32..<0x46]
        result.replaceSubrange(0x18..<0x20, with: Data(repeating: 0, count: 8))
        result.replaceSubrange(0x32..<0x46, with: Data(repeating: 0, count: 20))
        result.replaceSubrange(0x58..<0x6c, with: Data(repeating: 0, count: 20))
        result[0x30] = 1; result[0x31] = 0
        let hash = hmacSHA1(key: key(for: firewireID), message: result)
        result.replaceSubrange(0x58..<0x6c, with: hash)
        result.replaceSubrange(0x18..<0x20, with: savedID)
        result.replaceSubrange(0x32..<0x46, with: savedUnknown)
        return result
    }

    private static func key(for id: Data) -> Data {
        let fixed = Data([0x67, 0x23, 0xfe, 0x30, 0x45, 0x33, 0xf8, 0x90, 0x99, 0x21, 0x07, 0xc1, 0xd0, 0x12, 0xb2, 0xa1, 0x07, 0x81])
        let sbox = (0...255).map { aesSBox(UInt8($0)) }
        var inverse = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 { inverse[Int(sbox[index])] = UInt8(index) }
        var y = Data()
        for pair in 0..<4 {
            let value = lcm(Int(id[pair * 2]), Int(id[pair * 2 + 1]))
            let high = (value >> 8) & 0xff, low = value & 0xff
            y.append(sbox[high]); y.append(inverse[high]); y.append(sbox[low]); y.append(inverse[low])
        }
        return Data(Insecure.SHA1.hash(data: fixed + y))
    }

    private static func hmacSHA1(key: Data, message: Data) -> Data {
        var padded = key + Data(repeating: 0, count: max(0, 64 - key.count))
        padded = Data(padded.prefix(64))
        let innerKey = Data(padded.map { $0 ^ 0x36 })
        let outerKey = Data(padded.map { $0 ^ 0x5c })
        let inner = Data(Insecure.SHA1.hash(data: innerKey + message))
        return Data(Insecure.SHA1.hash(data: outerKey + inner))
    }

    private static func aesSBox(_ value: UInt8) -> UInt8 {
        var inverse: UInt8 = 0
        if value != 0 {
            inverse = 1
            for _ in 0..<254 { inverse = multiply(inverse, value) }
        }
        return inverse ^ rotate(inverse, 1) ^ rotate(inverse, 2) ^ rotate(inverse, 3) ^ rotate(inverse, 4) ^ 0x63
    }

    private static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, result: UInt8 = 0
        for _ in 0..<8 {
            if b & 1 != 0 { result ^= a }
            let high = a & 0x80
            a <<= 1
            if high != 0 { a ^= 0x1b }
            b >>= 1
        }
        return result
    }

    private static func rotate(_ value: UInt8, _ bits: UInt8) -> UInt8 { (value << bits) | (value >> (8 - bits)) }
    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
    private static func lcm(_ a: Int, _ b: Int) -> Int { a == 0 || b == 0 ? 1 : a * b / gcd(a, b) }
}
