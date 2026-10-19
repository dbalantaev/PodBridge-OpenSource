// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

#if DEBUG || PODBRIDGE_DEMO
enum DemoIPodScenario: String, CaseIterable, Identifiable {
    case normal
    case diskUseDisabled
    case missingSignatureID

    var id: String { rawValue }
}
#endif

/// Navigation and presentation actions exposed by the home screen.
struct PodBridgeHomeActions {
    let connectToIPod: () -> Void
    let showConnectionGuide: () -> Void
    let showDiskModeGuide: () -> Void
    let chooseSource: () -> Void
    let showRockboxTransfer: () -> Void
    let showALACarte: () -> Void
    let showLibrary: () -> Void
    let showDeviceModelChooser: () -> Void
    let showSignatureRecovery: () -> Void
    let showImportReview: () -> Void
}

/// The user-visible outcome of a completed music import.
struct TransferCompletion: Identifiable, Equatable {
    struct Playlist: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let trackCount: Int
    }

    let id = UUID()
    let addedTracks: Int
    let destinationName: String
    let playlists: [Playlist]
    let backupName: String?
}

/// The user-visible outcome of a library repair operation.
struct LibraryRepairCompletion: Identifiable, Equatable {
    let id = UUID()
    let repairedAlbumGroups: Int
    let restoredEmbeddedArtwork: Int
    let addedOnlineArtwork: Int

    var repairedArtwork: Int { restoredEmbeddedArtwork + addedOnlineArtwork }
}

/// Progress reported while searching the local Signature ID recovery space.
struct SignatureRecoveryProgress: Equatable, Sendable {
    let tested: UInt64
    let total: UInt64
    let candidatesPerSecond: Double

    var fraction: Double { total == 0 ? 0 : Double(tested) / Double(total) }

    var remainingSeconds: TimeInterval? {
        guard candidatesPerSecond > 0 else { return nil }
        return Double(total - tested) / candidatesPerSecond
    }
}
