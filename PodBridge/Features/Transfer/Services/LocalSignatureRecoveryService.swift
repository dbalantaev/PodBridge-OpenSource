// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

struct LocalSignatureRecoveryResult: Sendable {
    let candidate: Data?
    let tested: UInt64
    let candidatesPerSecond: Double
}

/// Searches the local Hash58 candidate space without owning UI state or persistence.
enum LocalSignatureRecoveryService {
    static let candidateCount = UInt64(UInt32.max) + 1

    static func recover(
        databaseURL: URL,
        startAt savedCursor: UInt64,
        onEngineSelected: @escaping @MainActor @Sendable (Bool) -> Void,
        onProgress: @escaping @MainActor @Sendable (SignatureRecoveryProgress) -> Void
    ) async throws -> LocalSignatureRecoveryResult {
        let context = try await Task.detached(priority: .userInitiated) {
            try Hash58.RecoveryContext(database: Data(contentsOf: databaseURL))
        }.value
        let metal = Hash58.MetalRecoveryEngine(context: context)
        await onEngineSelected(metal != nil)

        var cursor = min(savedCursor, candidateCount)
        let started = Date()
        let initialCursor = cursor
        let batchSize: UInt64 = metal == nil ? 4_096 : 262_144

        while cursor < candidateCount {
            try Task.checkCancellation()
            let count = min(batchSize, candidateCount - cursor)
            let candidate = try await searchBatch(
                context: context,
                metal: metal,
                cursor: cursor,
                count: count
            )
            try Task.checkCancellation()
            let tested = cursor + count
            let rate = Double(tested - initialCursor) / max(0.001, Date().timeIntervalSince(started))
            if let candidate {
                return LocalSignatureRecoveryResult(
                    candidate: candidate,
                    tested: tested,
                    candidatesPerSecond: rate
                )
            }

            cursor = tested
            await onProgress(
                SignatureRecoveryProgress(
                    tested: cursor,
                    total: candidateCount,
                    candidatesPerSecond: rate
                )
            )
            await Task.yield()
        }

        return LocalSignatureRecoveryResult(
            candidate: nil,
            tested: cursor,
            candidatesPerSecond: progressRate(
                tested: cursor - initialCursor,
                since: started
            )
        )
    }

    private static func searchBatch(
        context: Hash58.RecoveryContext,
        metal: Hash58.MetalRecoveryEngine?,
        cursor: UInt64,
        count: UInt64
    ) async throws -> Data? {
        if let metal {
            return try await metal.search(from: cursor, count: UInt32(count))
        }

        let batch = Task.detached(priority: .utility) {
            context.search(from: cursor, count: count)
        }
        return await withTaskCancellationHandler {
            await batch.value
        } onCancel: {
            batch.cancel()
        }
    }

    private static func progressRate(tested: UInt64, since start: Date) -> Double {
        Double(tested) / max(0.001, Date().timeIntervalSince(start))
    }
}
