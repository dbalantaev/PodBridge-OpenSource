// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev
//
// Hash58 algorithm based on libgpod src/itdb_hash58.c,
// Copyright (C) 2007 Christophe Fergeau.
// See THIRD_PARTY_NOTICES.md for the BSD-3-Clause license.

import CryptoKit
import Foundation
import Metal

/// Implements the device-specific Hash58 signature used by supported iPods.
///
/// Video 5G/5.5G and nano 1G/2G use the same database family without a
/// checksum. An empty key therefore preserves their checksum fields unchanged.
enum Hash58 {
    struct RecoveryContext: Sendable {
        fileprivate let message: Data
        fileprivate let expectedSignature: Data

        init(database: Data) throws {
            guard database.count >= 0x6c else { throw PodBridgeError.invalidDatabase }
            expectedSignature = Data(database[0x58..<0x6c])
            guard expectedSignature.contains(where: { $0 != 0 }) else { throw PodBridgeError.invalidDatabase }
            var normalized = database
            normalized.replaceSubrange(0x18..<0x20, with: Data(repeating: 0, count: 8))
            normalized.replaceSubrange(0x32..<0x46, with: Data(repeating: 0, count: 20))
            normalized.replaceSubrange(0x58..<0x6c, with: Data(repeating: 0, count: 20))
            normalized[0x30] = 1
            normalized[0x31] = 0
            message = normalized
        }

        func search(from start: UInt64, count: UInt64) -> Data? {
            let upper = min(UInt64(UInt32.max) + 1, start + count)
            for suffix in start..<upper {
                if suffix & 0x3ff == 0, Task.isCancelled { return nil }
                let value = UInt32(suffix)
                let id = Data([
                    0x00, 0x0a, 0x27, 0x00,
                    UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                    UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
                ])
                if Hash58.hmacSHA1(key: Hash58.key(for: id), message: message) == expectedSignature {
                    return id
                }
            }
            return nil
        }
    }

    final class MetalRecoveryEngine: @unchecked Sendable {
        private let queue: MTLCommandQueue
        private let pipeline: MTLComputePipelineState
        private let message: MTLBuffer
        private let expected: MTLBuffer
        private let pairTable: MTLBuffer
        private let messageLength: UInt32

        init?(context: RecoveryContext) {
            guard context.message.count <= UInt32.max,
                  let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let function = device.makeDefaultLibrary()?.makeFunction(name: "recover_signature_id"),
                  let pipeline = try? device.makeComputePipelineState(function: function),
                  let message = device.makeBuffer(bytes: [UInt8](context.message), length: context.message.count),
                  let expected = device.makeBuffer(bytes: [UInt8](context.expectedSignature), length: context.expectedSignature.count) else {
                return nil
            }
            var table = [UInt32](repeating: 0, count: 65_536)
            for value in 0..<65_536 {
                let high = value >> 8, low = value & 0xff
                let combined = Hash58.lcm(high, low)
                let a = (combined >> 8) & 0xff, b = combined & 0xff
                let bytes = [Hash58.sBox[a], Hash58.inverseSBox[a], Hash58.sBox[b], Hash58.inverseSBox[b]]
                table[value] = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            }
            guard let pairTable = device.makeBuffer(bytes: table, length: table.count * MemoryLayout<UInt32>.size) else { return nil }
            self.queue = queue
            self.pipeline = pipeline
            self.message = message
            self.expected = expected
            self.pairTable = pairTable
            self.messageLength = UInt32(context.message.count)
        }

        func search(from start: UInt64, count: UInt32) async throws -> Data? {
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw PodBridgeError.invalidDatabase
            }
            let device = pipeline.device
            guard let foundSuffix = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
                  let foundFlag = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) else {
                throw PodBridgeError.invalidDatabase
            }
            foundSuffix.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            foundFlag.contents().storeBytes(of: UInt32(0), as: UInt32.self)
            var length = messageLength, batchStart = start, batchCount = count
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(message, offset: 0, index: 0)
            encoder.setBytes(&length, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.setBuffer(expected, offset: 0, index: 2)
            encoder.setBuffer(pairTable, offset: 0, index: 3)
            encoder.setBytes(&batchStart, length: MemoryLayout<UInt64>.size, index: 4)
            encoder.setBytes(&batchCount, length: MemoryLayout<UInt32>.size, index: 5)
            encoder.setBuffer(foundSuffix, offset: 0, index: 6)
            encoder.setBuffer(foundFlag, offset: 0, index: 7)
            let width = min(pipeline.maxTotalThreadsPerThreadgroup, max(1, pipeline.threadExecutionWidth * 4))
            encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                command.addCompletedHandler { buffer in
                    if let error = buffer.error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
                command.commit()
            }
            guard foundFlag.contents().load(as: UInt32.self) != 0 else { return nil }
            let suffix = foundSuffix.contents().load(as: UInt32.self)
            return Data([
                0x00, 0x0a, 0x27, 0x00,
                UInt8((suffix >> 24) & 0xff), UInt8((suffix >> 16) & 0xff),
                UInt8((suffix >> 8) & 0xff), UInt8(suffix & 0xff)
            ])
        }
    }

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
        var y = Data()
        for pair in 0..<4 {
            let value = lcm(Int(id[pair * 2]), Int(id[pair * 2 + 1]))
            let high = (value >> 8) & 0xff, low = value & 0xff
            y.append(sBox[high]); y.append(inverseSBox[high]); y.append(sBox[low]); y.append(inverseSBox[low])
        }
        return Data(Insecure.SHA1.hash(data: fixed + y))
    }

    private static let sBox = (0...255).map { aesSBox(UInt8($0)) }
    private static let inverseSBox: [UInt8] = {
        var result = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 { result[Int(sBox[index])] = UInt8(index) }
        return result
    }()

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
