// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation

struct IPodAlbum: Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let albumArtist: String
    let compilation: Bool
    let genre: String
    let year: UInt32
    let tracks: [ClassicTrack]

    var byteCount: UInt64 { tracks.reduce(0) { $0 + UInt64($1.byteCount) } }
}

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
}

struct LibraryRepairCompletion: Identifiable, Equatable {
    let id = UUID()
    let repairedAlbumGroups: Int
    let restoredEmbeddedArtwork: Int
    let addedOnlineArtwork: Int

    var repairedArtwork: Int { restoredEmbeddedArtwork + addedOnlineArtwork }
}

@MainActor
final class MusicTransferViewModel: ObservableObject {
    @Published private(set) var sourceFolder: URL?
    @Published private(set) var destinationFolder: URL?
    @Published private(set) var destinationDeviceProfile: IPodDeviceProfile?
    @Published private(set) var shouldChooseDeviceProfile = false
    @Published private(set) var existingTrackCount: Int?
    @Published private(set) var storageTotalBytes: Int64?
    @Published private(set) var storageFreeBytes: Int64?
    @Published private(set) var files: [MusicFile] = []
    @Published private(set) var playlists: [SourcePlaylist] = []
    @Published private(set) var scannedFiles: [MusicFile] = []
    @Published private(set) var scannedPlaylists: [SourcePlaylist] = []
    @Published private(set) var skippedAudioByExtension: [String: Int] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var isConnectingIPod = false
    @Published private(set) var isCopying = false
    @Published private(set) var copiedCount = 0
    @Published private(set) var transferCompletion: TransferCompletion?
    @Published private(set) var libraryRepairCompletion: LibraryRepairCompletion?
    @Published private(set) var resultMessage: String?
    @Published private(set) var backups: [IPodSyncEngine.Backup] = []
    @Published private(set) var libraryTracks: [ClassicTrack] = []
    @Published private(set) var libraryPlaylists: [ClassicPlaylist] = []
    @Published private(set) var deletionBackups: [IPodSyncEngine.DeletionBackup] = []
    @Published private(set) var isRestoring = false
    @Published private(set) var isManagingLibrary = false
    @Published private(set) var artworkSearchProgress: IPodSyncEngine.ArtworkSearchProgress?
#if PODBRIDGE_ALACARTE
    @Published private(set) var alacarteStatus: String?
#endif
    @Published private(set) var destinationNeedsFirewireID = false
    @Published var errorMessage: String?

    private var copyTask: Task<Void, Never>?
#if DEBUG
    private var simulationTask: Task<Void, Never>?
    private var emulatedIPodContainer: URL?
#endif
    private var artworkTask: Task<Void, Never>?
    @Published private(set) var isEmulatingIPod = false

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    var copyProgress: Double {
        guard !files.isEmpty else { return 0 }
        return Double(copiedCount) / Double(files.count)
    }

    var storageUsedBytes: Int64? {
        guard let total = storageTotalBytes, let free = storageFreeBytes else { return nil }
        return max(0, total - free)
    }

    var storageUsedFraction: Double? {
        guard let total = storageTotalBytes, total > 0, let used = storageUsedBytes else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var missingArtworkTrackCount: Int {
        libraryTracks.filter { $0.artworkImageID == 0 }.count
    }

    var automaticArtworkCandidateCount: Int {
        missingArtworkTrackCount
    }

    var safeAlbumRepairCount: Int {
        IPodSyncEngine.albumArtistRepairPreview(
            tracks: libraryTracks,
            playlists: libraryPlaylists
        ).albums
    }

    var libraryAlbums: [IPodAlbum] {
        let groups = Dictionary(grouping: libraryTracks) { track in
            let groupingArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
            return track.albumID == 0 ? "metadata:\(groupingArtist)\u{0}\(track.album)" : "id:\(track.albumID)"
        }
        return groups.map { key, tracks in
            let orderedTracks = tracks.sorted {
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            let first = orderedTracks[0]
            let albumArtist = first.albumArtist.isEmpty ? first.artist : first.albumArtist
            return IPodAlbum(
                id: key,
                title: first.album,
                artist: albumArtist,
                albumArtist: albumArtist,
                compilation: orderedTracks.contains(where: \.compilation),
                genre: first.genre,
                year: first.year,
                tracks: orderedTracks
            )
        }.sorted {
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            return artistOrder == .orderedSame
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                : artistOrder == .orderedAscending
        }
    }

#if DEBUG
    func emulateConnectedIPod() {
        guard !isCopying && !isManagingLibrary && !isRestoring else { return }
        if isEmulatingIPod {
            disconnectEmulatedIPod()
            return
        }

        let manager = FileManager.default
        let container = manager.temporaryDirectory
            .appendingPathComponent("PodBridge-Emulated-\(UUID().uuidString)", isDirectory: true)
        do {
            let root = container.appendingPathComponent("Demo iPod", isDirectory: true)
            let device = root.appendingPathComponent("iPod_Control/Device", isDirectory: true)
            let itunes = root.appendingPathComponent("iPod_Control/iTunes", isDirectory: true)
            try manager.createDirectory(at: device, withIntermediateDirectories: true)
            try manager.createDirectory(at: itunes, withIntermediateDirectories: true)
            try "FirewireGuid: 0x000A27001A2B3C4D\n".write(
                to: device.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8
            )
            let demoTracks = Self.demoTracks
            let library = ClassicLibrary(
                name: "Demo iPod", tracks: demoTracks,
                playlists: [
                    ClassicPlaylist(name: "Favorites", trackIDs: demoTracks.prefix(3).map(\.id)),
                    ClassicPlaylist(name: "Recently Added", trackIDs: demoTracks.map(\.id))
                ]
            )
            let firewireID = Data([0x00, 0x0A, 0x27, 0x00, 0x1A, 0x2B, 0x3C, 0x4D])
            let database = try ClassicDatabase.build(
                library: library, firewireID: firewireID, databaseID: 0x504F444252494447
            )
            try database.write(to: itunes.appendingPathComponent("iTunesDB"), options: .atomic)
            emulatedIPodContainer = container
            destinationFolder = root
            destinationDeviceProfile = nil
            shouldChooseDeviceProfile = true
            libraryTracks = demoTracks
            libraryPlaylists = library.playlists
            existingTrackCount = demoTracks.count
            storageTotalBytes = 160_000_000_000
            storageFreeBytes = 83_000_000_000
            backups = []
            deletionBackups = []
            destinationNeedsFirewireID = false
            errorMessage = nil
            resultMessage = nil
            isEmulatingIPod = true
            AppLogger.device("Debug iPod emulation connected", level: .info)
        } catch {
            try? manager.removeItem(at: container)
            errorMessage = "Could not create the emulated iPod: \(error.localizedDescription)"
            AppLogger.device("Debug iPod emulation failed error=\(error.localizedDescription)", level: .error)
        }
    }

    private func disconnectEmulatedIPod() {
        guard isEmulatingIPod else { return }
        simulationTask?.cancel()
        isEmulatingIPod = false
        destinationFolder = nil
        destinationDeviceProfile = nil
        existingTrackCount = nil
        storageTotalBytes = nil
        storageFreeBytes = nil
        libraryTracks = []
        libraryPlaylists = []
        backups = []
        deletionBackups = []
        destinationNeedsFirewireID = false
        if let container = emulatedIPodContainer { try? FileManager.default.removeItem(at: container) }
        emulatedIPodContainer = nil
        AppLogger.device("Debug iPod emulation disconnected", level: .info)
    }

    private static var demoTracks: [ClassicTrack] {
        let rows: [(String, String, String, UInt32, UInt32)] = [
            ("One More Time", "Daft Punk", "Discovery", 1, 320_000),
            ("Aerodynamic", "Daft Punk", "Discovery", 2, 207_000),
            ("Digital Love", "Daft Punk", "Discovery", 3, 298_000),
            ("Harder, Better, Faster, Stronger", "Daft Punk", "Discovery", 4, 224_000),
            ("Instant Crush", "Daft Punk", "Random Access Memories", 5, 337_000),
            ("Get Lucky", "Daft Punk", "Random Access Memories", 6, 369_000),
            ("Borderline", "Tame Impala", "The Slow Rush", 7, 237_000),
            ("Eventually", "Tame Impala", "Currents", 8, 319_000),
            ("Blinding Lights", "The Weeknd", "After Hours", 9, 200_000),
            ("Nights", "Frank Ocean", "Blonde", 10, 307_000)
        ]
        return rows.enumerated().map { index, row in
            ClassicTrack(
                id: UInt32(index + 1), databaseID: UInt64(10_000 + index),
                title: row.0, artist: row.1, album: row.2,
                genre: "Electronic", fileType: "MPEG audio file",
                ipodPath: String(format: ":iPod_Control:Music:F00:PB%04d.mp3", index + 1),
                byteCount: 8_000_000, durationMS: row.4, trackNumber: row.3, year: 2001,
                bitrate: 256, sampleRate: 44_100, dateAdded: 3_000_000_000 + UInt32(index),
                albumID: UInt32(index + 1), artistID: UInt32(index + 1),
                artworkImageID: index % 3 == 0 ? 0 : UInt32(index + 100), albumArtist: row.1
            )
        }
    }

#endif

    func selectSource(_ url: URL) {
        AppLogger.scan("Source selected folder=\(url.lastPathComponent)", level: .info)
        sourceFolder = url
        files = []
        playlists = []
        scannedFiles = []
        scannedPlaylists = []
        skippedAudioByExtension = [:]
        copiedCount = 0
        resultMessage = nil
        scanSource()
    }

    func selectDestination(_ url: URL) {
#if DEBUG
        if isEmulatingIPod { disconnectEmulatedIPod() }
#endif
        AppLogger.device("Destination selected name=\(url.lastPathComponent)", level: .info)
        destinationFolder = url
        destinationDeviceProfile = nil
        shouldChooseDeviceProfile = false
        existingTrackCount = nil
        storageTotalBytes = nil
        storageFreeBytes = nil
        copiedCount = 0
        resultMessage = nil
        errorMessage = nil
        backups = []
        libraryTracks = []
        libraryPlaylists = []
        deletionBackups = []
        destinationNeedsFirewireID = false
        isConnectingIPod = true
        Task {
            await Task.yield()
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let library = try IPodSyncEngine.library(root: url)
                    let backups = try IPodSyncEngine.backups(root: url)
                    let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                    return (
                        library,
                        backups,
                        values?.volumeTotalCapacity.map(Int64.init),
                        values?.volumeAvailableCapacity.map(Int64.init)
                    )
                }.value
                existingTrackCount = loaded.0.tracks.count
                libraryTracks = loaded.0.tracks
                libraryPlaylists = loaded.0.playlists
                backups = loaded.1
                storageTotalBytes = loaded.2
                storageFreeBytes = loaded.3
                shouldChooseDeviceProfile = true
                AppLogger.device("Destination validation succeeded existingTracks=\(existingTrackCount ?? 0)", level: .info)
            } catch {
                destinationFolder = nil
                errorMessage = error.localizedDescription
                AppLogger.device("Destination validation failed error=\(error.localizedDescription)", level: .error)
            }
            isConnectingIPod = false
        }
    }

    func selectDeviceProfile(_ profile: IPodDeviceProfile) {
        guard let destinationFolder else { return }
        destinationDeviceProfile = profile
        shouldChooseDeviceProfile = false
        IPodDeviceProfile.save(profile, for: destinationFolder)
        destinationNeedsFirewireID = false
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
        do {
            try IPodSyncEngine.recoverInterruptedDeletions(root: destinationFolder)
            let databaseKey = try IPodDeviceProfile.databaseKey(at: destinationFolder)
            deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == databaseKey.hexString }
            AppLogger.device("Device profile selected model=\(profile.rawValue) checksum=\(String(describing: profile.checksum)) tested=\(profile.isHardwareTested)", level: .info)
        } catch PodBridgeError.missingFirewireID {
            destinationNeedsFirewireID = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnectDestination() {
        guard !isCopying && !isManagingLibrary && !isRestoring else { return }
#if DEBUG
        if isEmulatingIPod {
            disconnectEmulatedIPod()
            return
        }
#endif
        destinationFolder = nil
        destinationDeviceProfile = nil
        shouldChooseDeviceProfile = false
        existingTrackCount = nil
        storageTotalBytes = nil
        storageFreeBytes = nil
        libraryTracks = []
        libraryPlaylists = []
        backups = []
        deletionBackups = []
        destinationNeedsFirewireID = false
        AppLogger.device("iPod destination safely released by user", level: .info)
    }

    func acknowledgeDeviceProfilePrompt() {
        shouldChooseDeviceProfile = false
    }

    func storeFirewireIDAndRepair(_ value: String) {
        guard let destinationFolder else { return }
        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
        do {
            try ClassicDatabase.storeFirewireID(value, root: destinationFolder)
            destinationNeedsFirewireID = false
            repairDatabaseSignature()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreOldestBackup() {
        guard let destinationFolder, let backup = backups.first else { return }
        isRestoring = true
        resultMessage = nil
        errorMessage = nil
        Task {
            await Task.yield()
            defer { isRestoring = false }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    let access = destinationFolder.startAccessingSecurityScopedResource()
                    defer { if access { destinationFolder.stopAccessingSecurityScopedResource() } }
                    let result = try IPodSyncEngine.restore(backup: backup, root: destinationFolder)
                    let library = try IPodSyncEngine.library(root: destinationFolder)
                    let backups = try IPodSyncEngine.backups(root: destinationFolder)
                    let values = try? destinationFolder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                    return (result, library, backups, values?.volumeTotalCapacity.map(Int64.init), values?.volumeAvailableCapacity.map(Int64.init))
                }.value
                existingTrackCount = loaded.0.tracks
                libraryTracks = loaded.1.tracks
                libraryPlaylists = loaded.1.playlists
                backups = loaded.2
                storageTotalBytes = loaded.3
                storageFreeBytes = loaded.4
                resultMessage = "Restored backup \(backup.name) with \(loaded.0.tracks) tracks. Removed \(loaded.0.removedFiles) files added after it. Safety backup: \(loaded.0.safetyBackup.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.database("Backup restore failed name=\(backup.name) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func repairDatabaseSignature() {
        guard let destinationFolder, !isManagingLibrary, !isCopying else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.repairDatabaseSignature(root: destinationFolder)
                existingTrackCount = result.library.tracks.count
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                if let backup = result.backupURL {
                    resultMessage = "Re-signed iTunesDB. Backup: \(backup.lastPathComponent)."
                } else {
                    resultMessage = "iTunesDB signature and indexes are already valid."
                }
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.database("Signature repair UI failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func scanSource() {
        guard let sourceFolder else {
            errorMessage = PodBridgeError.noSourceFolder.localizedDescription
            return
        }
        isScanning = true
        errorMessage = nil
        AppLogger.scan("Source scan started", level: .info)
        Task {
            let access = sourceFolder.startAccessingSecurityScopedResource()
            defer { if access { sourceFolder.stopAccessingSecurityScopedResource() } }
            do {
                let report = try await MusicTransferEngine.scanWithReport(folder: sourceFolder)
                let found = report.files
                let foundPlaylists = try await MusicTransferEngine.scanPlaylists(folder: sourceFolder, files: found)
                files = found
                playlists = foundPlaylists
                scannedFiles = found
                scannedPlaylists = foundPlaylists
                skippedAudioByExtension = report.skippedAudioByExtension
                AppLogger.scan(
                    "Source scan completed tracks=\(found.count) playlists=\(foundPlaylists.count) bytes=\(found.reduce(0) { $0 + $1.byteCount })",
                    level: .info
                )
                if found.isEmpty {
                    errorMessage = PodBridgeError.noMusicFiles.localizedDescription
                    AppLogger.scan("Source scan found no supported audio", level: .error)
                }
            } catch is CancellationError {
                // A new selection or app dismissal can safely cancel a scan.
                AppLogger.scan("Source scan cancelled", level: .info)
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.scan("Source scan failed error=\(error.localizedDescription)", level: .error)
            }
            isScanning = false
        }
    }

    func keepImportFiles(withIDs selectedIDs: Set<String>) {
        guard !isScanning && !isCopying else { return }
        let selection = MusicTransferEngine.importSelection(
            files: scannedFiles,
            playlists: scannedPlaylists,
            selectedIDs: selectedIDs
        )
        files = selection.files
        playlists = selection.playlists
        resultMessage = nil
    }

    func setSourcePlaylistArtwork(id: String, imageURL: URL) {
        let access = imageURL.startAccessingSecurityScopedResource()
        defer { if access { imageURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            try ArtworkDatabase.validateSourceArtwork(data)
            guard let index = playlists.firstIndex(where: { $0.id == id }) else {
                throw PodBridgeError.playlistNotFound
            }
            playlists[index].artworkData = data
            playlists[index].artworkFilename = imageURL.lastPathComponent
            AppLogger.artwork(
                "Source playlist artwork selected name=\(playlists[index].name) file=\(imageURL.lastPathComponent) bytes=\(data.count)",
                level: .info
            )
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.artwork("Source playlist artwork selection failed error=\(error.localizedDescription)", level: .error)
        }
    }

    func clearSourcePlaylistArtwork(id: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].artworkData = nil
        playlists[index].artworkFilename = nil
    }

    func startCopy() {
        guard let sourceFolder else {
            errorMessage = PodBridgeError.noSourceFolder.localizedDescription
            return
        }
        guard let destinationFolder else {
            errorMessage = PodBridgeError.noDestinationFolder.localizedDescription
            return
        }
        guard destinationDeviceProfile != nil else {
            errorMessage = PodBridgeError.deviceModelRequired.localizedDescription
            return
        }
        guard !files.isEmpty else {
            errorMessage = PodBridgeError.noMusicFiles.localizedDescription
            return
        }
#if DEBUG
        if isEmulatingIPod {
            startSimulatedCopy(trackCount: files.count)
            return
        }
#endif

        copyTask?.cancel()
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        AppLogger.sync("Sync requested tracks=\(files.count) playlists=\(playlists.count) bytes=\(totalBytes)", level: .info)

        copyTask = Task {
            let sourceAccess = sourceFolder.startAccessingSecurityScopedResource()
            let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { sourceFolder.stopAccessingSecurityScopedResource() }
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isCopying = false
                copyTask = nil
            }

            do {
                let result = try await IPodSyncEngine.sync(files: files, playlists: playlists, root: destinationFolder) { count in
                    await MainActor.run { self.copiedCount = count }
                }
                existingTrackCount = result.total
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                let reused = result.exactDuplicatesReused + result.metadataDuplicatesReused
                resultMessage = "Added \(result.added) tracks, reused \(reused) duplicates, added \(result.playlistsAdded) playlists, and \(result.coversAdded) covers. Backup: \(result.backupURL.lastPathComponent)."
                completeTransfer(addedTracks: result.added)
                AppLogger.sync(
                    "Sync UI completed added=\(result.added) exactDuplicatesReused=\(result.exactDuplicatesReused) metadataDuplicatesReused=\(result.metadataDuplicatesReused) playlists=\(result.playlistsAdded) covers=\(result.coversAdded) total=\(result.total) backup=\(result.backupURL.lastPathComponent)",
                    level: .info
                )
            } catch is CancellationError {
                resultMessage = "Copy stopped after \(copiedCount) track\(copiedCount == 1 ? "" : "s")."
                AppLogger.sync("Sync cancelled copied=\(copiedCount)", level: .error)
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Sync UI failed copied=\(copiedCount) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func cancelCopy() {
        copyTask?.cancel()
#if DEBUG
        simulationTask?.cancel()
#endif
    }

#if DEBUG
    private func startSimulatedCopy(trackCount: Int) {
        simulationTask?.cancel()
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        simulationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCopying = false
                self.simulationTask = nil
            }
            do {
                for index in 1...max(trackCount, 1) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 320_000_000)
                    self.copiedCount = min(index, trackCount)
                }
                self.existingTrackCount = (self.existingTrackCount ?? self.libraryTracks.count) + trackCount
                self.resultMessage = "Added \(trackCount) tracks to the emulated iPod. No iTunesDB files were changed."
                self.completeTransfer(addedTracks: trackCount)
            } catch is CancellationError {
                self.resultMessage = "Copy stopped after \(self.copiedCount) tracks."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
#endif

    private func refreshStorage(for url: URL) {
        do {
            let values = try url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            storageTotalBytes = values.volumeTotalCapacity.map(Int64.init)
            storageFreeBytes = values.volumeAvailableCapacity.map(Int64.init)
        } catch {
            storageTotalBytes = nil
            storageFreeBytes = nil
            AppLogger.device("Storage capacity unavailable error=\(error.localizedDescription)", level: .error)
        }
    }

    private func completeTransfer(addedTracks: Int) {
        let summary = playlists
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .map { TransferCompletion.Playlist(name: $0.name, trackCount: $0.fileIndices.count) }
        let destinationName = destinationFolder?.lastPathComponent ?? "your iPod"
        transferCompletion = TransferCompletion(
            addedTracks: addedTracks,
            destinationName: destinationName.isEmpty ? "your iPod" : destinationName,
            playlists: summary
        )
        files = []
        playlists = []
        scannedFiles = []
        scannedPlaylists = []
        skippedAudioByExtension = [:]
        copiedCount = 0
    }

#if PODBRIDGE_ALACARTE
    func importFromALACarte(client: ALACarteClient, items selectedItems: [ALACarteLibraryItem]) {
#if DEBUG
        if isEmulatingIPod {
            startSimulatedALACarteImport(selectedItems)
            return
        }
#endif
        guard let destinationFolder else {
            errorMessage = PodBridgeError.noDestinationFolder.localizedDescription
            return
        }
        guard destinationDeviceProfile != nil else {
            errorMessage = PodBridgeError.deviceModelRequired.localizedDescription
            return
        }
        guard !destinationNeedsFirewireID, !isCopying, !selectedItems.isEmpty else { return }

        copyTask?.cancel()
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        alacarteStatus = "Preparing \(selectedItems.count) selected items…"
        copyTask = Task {
            var downloadedFolders: [URL] = []
            let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                for folder in downloadedFolders { try? FileManager.default.removeItem(at: folder) }
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                alacarteStatus = nil
                isCopying = false
                copyTask = nil
            }
            do {
                var combinedFiles: [MusicFile] = []
                var combinedPlaylists: [SourcePlaylist] = []
                for (itemIndex, item) in selectedItems.enumerated() {
                    try Task.checkCancellation()
                    alacarteStatus = "Downloading \(itemIndex + 1) of \(selectedItems.count): \(item.title)"
                    let folder = try await client.download(item) { completed, total in
                        await MainActor.run {
                            self.alacarteStatus = "Downloading \(itemIndex + 1) of \(selectedItems.count): \(completed) of \(total) files"
                        }
                    }
                    downloadedFolders.append(folder)
                    let found = try await MusicTransferEngine.scan(folder: folder)
                    let foundPlaylists = try await MusicTransferEngine.scanPlaylists(folder: folder, files: found)
                    guard !found.isEmpty else { throw ALACarteError.noCompatibleAudio }
                    let fileOffset = combinedFiles.count
                    combinedFiles.append(contentsOf: found)
                    combinedPlaylists.append(contentsOf: foundPlaylists.map { playlist in
                        SourcePlaylist(
                            name: playlist.name,
                            fileIndices: playlist.fileIndices.map { $0 + fileOffset },
                            artworkData: playlist.artworkData
                        )
                    })
                }

                files = combinedFiles
                playlists = combinedPlaylists
                alacarteStatus = "Writing \(combinedFiles.count) tracks to the iPod…"
                let result = try await IPodSyncEngine.sync(
                    files: combinedFiles,
                    playlists: combinedPlaylists,
                    root: destinationFolder
                ) { count in
                    await MainActor.run {
                        self.copiedCount = count
                        self.alacarteStatus = "Writing to iPod: \(count) of \(combinedFiles.count) tracks"
                    }
                }
                existingTrackCount = result.total
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                let reused = result.exactDuplicatesReused + result.metadataDuplicatesReused
                resultMessage = "Imported \(selectedItems.count) selections: \(result.added) new tracks, \(reused) reused, and \(result.playlistsAdded) playlists. Backup: \(result.backupURL.lastPathComponent)."
                completeTransfer(addedTracks: result.added)
            } catch is CancellationError {
                resultMessage = "ALACarte import was cancelled before completion."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync(
                    "ALACarte import failed items=\(selectedItems.count) error=\(error.localizedDescription)",
                    level: .error
                )
            }
        }
    }
#endif

#if DEBUG && PODBRIDGE_ALACARTE
    private func startSimulatedALACarteImport(_ selectedItems: [ALACarteLibraryItem]) {
        simulationTask?.cancel()
        let totalTracks = max(selectedItems.reduce(0) { $0 + $1.trackCount }, 1)
        isCopying = true
        copiedCount = 0
        transferCompletion = nil
        resultMessage = nil
        errorMessage = nil
        alacarteStatus = "Preparing \(selectedItems.count) selected items…"
        simulationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCopying = false
                self.alacarteStatus = nil
                self.simulationTask = nil
            }
            do {
                for (index, item) in selectedItems.enumerated() {
                    try Task.checkCancellation()
                    self.alacarteStatus = "Downloading \(index + 1) of \(selectedItems.count): \(item.title)"
                    try await Task.sleep(nanoseconds: 650_000_000)
                }
                for index in 1...totalTracks {
                    try Task.checkCancellation()
                    self.alacarteStatus = "Writing to iPod: \(index) of \(totalTracks) tracks"
                    try await Task.sleep(nanoseconds: 110_000_000)
                    self.copiedCount = index
                }
                self.existingTrackCount = (self.existingTrackCount ?? self.libraryTracks.count) + totalTracks
                self.transferCompletion = TransferCompletion(
                    addedTracks: totalTracks,
                    destinationName: "Demo iPod",
                    playlists: selectedItems.filter { $0.kind == .playlist }.prefix(3).map {
                        TransferCompletion.Playlist(name: $0.title, trackCount: $0.trackCount)
                    }
                )
                self.resultMessage = "Added \(totalTracks) demo tracks from ALACarte. The demo resets when PodBridge restarts."
                self.copiedCount = 0
            } catch is CancellationError {
                self.resultMessage = "Demo ALACarte transfer cancelled."
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
#endif

    func deleteTrack(_ track: ClassicTrack) {
        guard let destinationFolder, !isManagingLibrary, deletionBackups.isEmpty else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.deleteTrack(id: track.id, root: destinationFolder)
                existingTrackCount = result.remainingTracks
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == result.backup.deviceIdentifier }
                resultMessage = "Deleted \(result.deletedTrack.title) and freed \(Int64(result.freedBytes).formatted(.byteCount(style: .file))). A verified copy is stored on this iPhone."
                AppLogger.sync(
                    "Delete UI completed id=\(track.id) remaining=\(result.remainingTracks) freedBytes=\(result.freedBytes) localBackup=\(result.backup.folderURL.lastPathComponent)",
                    level: .info
                )
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Delete UI failed id=\(track.id) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func restoreDeletedTrack(_ backup: IPodSyncEngine.DeletionBackup) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let library = try await IPodSyncEngine.restoreDeletion(backup, root: destinationFolder)
                existingTrackCount = library.tracks.count
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == backup.deviceIdentifier }
                resultMessage = "Restored \(backup.title) to the iPod and removed its local backup from this iPhone."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Deleted track restore UI failed id=\(backup.trackID) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func discardDeletedTrackBackup(_ backup: IPodSyncEngine.DeletionBackup) {
        guard !isManagingLibrary else { return }
        do {
            try IPodSyncEngine.discardDeletionBackup(backup)
            deletionBackups = IPodSyncEngine.deletionBackups().filter { $0.deviceIdentifier == backup.deviceIdentifier }
            resultMessage = "The local backup of \(backup.title) was deleted. Its removal from the iPod is now permanent."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func editTrackMetadata(_ track: ClassicTrack, update: ClassicDatabase.TrackMetadataUpdate) {
#if DEBUG
        if isEmulatingIPod { emulateTrackMetadata(track.id, update: update); return }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.editTrackMetadata(id: track.id, update: update, root: destinationFolder)
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated metadata for \(update.title). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Track metadata edit UI failed id=\(track.id) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func renamePlaylist(at index: Int, to name: String) {
#if DEBUG
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            libraryPlaylists[index].name = name
            resultMessage = "Renamed demo playlist to \(name)."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.renamePlaylist(index: index, name: name, root: destinationFolder)
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Renamed playlist to \(name). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Playlist rename UI failed index=\(index) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func deletePlaylist(at index: Int, includingSongs: Bool) {
#if DEBUG
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            let playlist = libraryPlaylists.remove(at: index)
            if includingSongs { emulateDeleteTracks(Set(playlist.trackIDs)) }
            resultMessage = "Deleted demo playlist \(playlist.name)."
            return
        }
#endif
        guard let destinationFolder,
              !isManagingLibrary,
              libraryPlaylists.indices.contains(index) else { return }
        let playlist = libraryPlaylists[index]
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                if includingSongs {
                    let result = try await IPodSyncEngine.deletePlaylistAndTracks(index: index, root: destinationFolder)
                    let library = try IPodSyncEngine.library(root: destinationFolder)
                    existingTrackCount = result.remainingTracks
                    libraryTracks = library.tracks
                    libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                    let freed = ByteCountFormatter.string(fromByteCount: Int64(result.freedBytes), countStyle: .file)
                    resultMessage = result.failedFileDeletions == 0
                        ? "Deleted playlist \(playlist.name), \(result.removedTracks.count) songs, and freed \(freed)."
                        : "Deleted playlist \(playlist.name) and its songs from the library. \(result.failedFileDeletions) orphan audio files could not be deleted."
                } else {
                    let result = try await IPodSyncEngine.deletePlaylist(index: index, root: destinationFolder)
                    libraryTracks = result.library.tracks
                    libraryPlaylists = result.library.playlists
                    backups = try IPodSyncEngine.backups(root: destinationFolder)
                    resultMessage = "Deleted playlist \(playlist.name); its songs remain on the iPod. Backup: \(result.backupURL.lastPathComponent)."
                }
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Playlist delete UI failed index=\(index) includingSongs=\(includingSongs) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func replacePlaylistMembers(at index: Int, trackIDs: [UInt32]) {
#if DEBUG
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            libraryPlaylists[index].trackIDs = trackIDs
            resultMessage = "Updated demo playlist with \(trackIDs.count) songs."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.replacePlaylistMembers(index: index, trackIDs: trackIDs, root: destinationFolder)
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated playlist with \(trackIDs.count) songs. Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Playlist members edit failed index=\(index) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func deleteTrackPermanently(_ track: ClassicTrack) {
        deleteTracksPermanently([track], description: track.title)
    }

    func deleteAlbumPermanently(_ album: IPodAlbum) {
        deleteTracksPermanently(album.tracks, description: album.title)
    }

    private func deleteTracksPermanently(_ tracks: [ClassicTrack], description: String) {
#if DEBUG
        if isEmulatingIPod {
            emulateDeleteTracks(Set(tracks.map(\.id)))
            resultMessage = "Deleted \(description) from the demo iPod."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary, !tracks.isEmpty else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.deleteTracksPermanently(
                    ids: tracks.map(\.id),
                    root: destinationFolder
                )
                let library = try IPodSyncEngine.library(root: destinationFolder)
                existingTrackCount = result.remainingTracks
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                let freed = ByteCountFormatter.string(fromByteCount: Int64(result.freedBytes), countStyle: .file)
                resultMessage = result.failedFileDeletions == 0
                    ? "Permanently deleted \(description) and freed \(freed)."
                    : "Removed \(description) from the library and freed \(freed). \(result.failedFileDeletions) orphan audio files could not be deleted."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Permanent delete UI failed tracks=\(tracks.count) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func editAlbumMetadata(_ album: IPodAlbum, update: IPodSyncEngine.AlbumMetadataUpdate) {
#if DEBUG
        if isEmulatingIPod {
            emulateAlbumMetadata(Set(album.tracks.map(\.id)), update: update)
            resultMessage = "Updated demo album \(update.album)."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.editAlbumMetadata(
                    trackIDs: album.tracks.map(\.id),
                    update: update,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated album \(update.album). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Album metadata edit UI failed album=\(album.title) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func setPlaylistArtwork(at index: Int, imageURL: URL) {
        guard let destinationFolder, !isManagingLibrary else { return }
        let sourceAccess = imageURL.startAccessingSecurityScopedResource()
        let artwork: Data
        do {
            artwork = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            try ArtworkDatabase.validateSourceArtwork(artwork)
        } catch {
            if sourceAccess { imageURL.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
            return
        }
        if sourceAccess { imageURL.stopAccessingSecurityScopedResource() }

#if DEBUG
        if isEmulatingIPod, libraryPlaylists.indices.contains(index) {
            emulateArtwork(Set(libraryPlaylists[index].trackIDs), artwork: artwork)
            resultMessage = "Updated artwork for demo playlist \(libraryPlaylists[index].name)."
            return
        }
#endif

        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let destinationAccess = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if destinationAccess { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let name = libraryPlaylists.indices.contains(index) ? libraryPlaylists[index].name : "playlist"
                let result = try await IPodSyncEngine.setPlaylistArtwork(
                    index: index,
                    artwork: artwork,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated the Cover Flow artwork for \(name). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Playlist artwork UI failed index=\(index) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func setAlbumArtwork(_ album: IPodAlbum, imageURL: URL) {
        guard destinationFolder != nil, !isManagingLibrary,
              let artwork = readArtwork(from: imageURL) else { return }
        setAlbumArtwork(album, artwork: artwork)
    }

    func setAlbumArtwork(_ album: IPodAlbum, artwork: Data) {
#if DEBUG
        if isEmulatingIPod {
            emulateArtwork(Set(album.tracks.map(\.id)), artwork: artwork)
            resultMessage = "Updated artwork for demo album \(album.title)."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.setAlbumArtwork(
                    trackIDs: album.tracks.map(\.id),
                    artwork: artwork,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated artwork for album \(album.title). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Album artwork UI failed album=\(album.title) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func setTrackArtwork(_ track: ClassicTrack, imageURL: URL) {
        guard destinationFolder != nil, !isManagingLibrary,
              let artwork = readArtwork(from: imageURL) else { return }
        setTrackArtwork(track, artwork: artwork)
    }

    func setTrackArtwork(_ track: ClassicTrack, artwork: Data) {
#if DEBUG
        if isEmulatingIPod {
            emulateArtwork([track.id], artwork: artwork)
            resultMessage = "Updated artwork for demo song \(track.title)."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.setTrackArtwork(
                    id: track.id,
                    artwork: artwork,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Updated artwork for \(track.title). Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Track artwork UI failed id=\(track.id) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func createPlaylist(name: String, trackIDs: [UInt32]) {
#if DEBUG
        if isEmulatingIPod {
            libraryPlaylists.append(ClassicPlaylist(name: name, trackIDs: trackIDs))
            resultMessage = "Created demo playlist \(name) with \(trackIDs.count) songs."
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
            }
            do {
                let result = try await IPodSyncEngine.createPlaylist(
                    name: name,
                    trackIDs: trackIDs,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                resultMessage = "Created playlist \(name) with \(trackIDs.count) songs. Backup: \(result.backupURL.lastPathComponent)."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.database("Playlist creation UI failed name=\(name) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func restoreEmbeddedArtwork(_ album: IPodAlbum) {
        restoreEmbeddedArtwork(trackIDs: album.tracks.map(\.id), label: album.title)
    }

    func restoreEmbeddedArtwork(trackIDs: [UInt32], label: String) {
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let result = try await IPodSyncEngine.restoreEmbeddedArtwork(
                    trackIDs: trackIDs,
                    root: destinationFolder
                )
                libraryTracks = result.library.tracks
                libraryPlaylists = result.library.playlists
                if result.restoredTracks > 0 { backups = try IPodSyncEngine.backups(root: destinationFolder) }
                let missing = result.tracksWithoutEmbeddedArtwork == 0
                    ? ""
                    : " \(result.tracksWithoutEmbeddedArtwork) files had no embedded cover."
                resultMessage = result.restoredTracks == 0
                    ? "No embedded original covers were found in \(label)'s audio files."
                    : "Restored embedded covers for \(result.restoredTracks) songs in \(label).\(missing) Backup: \(result.backupURL?.lastPathComponent ?? "created")."
            } catch is CancellationError {
                resultMessage = "Embedded artwork restoration was cancelled before the iPod library changed."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Embedded artwork restore UI failed label=\(label) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func replaceSongArtworkFromInternet(trackIDs: [UInt32], label: String) {
#if DEBUG
        if isEmulatingIPod {
            emulateOnlineArtwork(trackIDs: Set(trackIDs), label: label, replaceExisting: true)
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary, !trackIDs.isEmpty else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let result = try await IPodSyncEngine.replaceSongArtworkFromInternet(
                    trackIDs: trackIDs,
                    root: destinationFolder
                ) { progress in
                    await MainActor.run { self.artworkSearchProgress = progress }
                }
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                if result.updatedTracks > 0 {
                    backups = try IPodSyncEngine.backups(root: destinationFolder)
                    let backupName = result.backupURL?.lastPathComponent ?? "created"
                    resultMessage = "Forced original-release artwork for \(result.updatedTracks) songs in \(label). Backup: \(backupName)."
                } else {
                    resultMessage = "No exact online cover matches were found for \(label). Try choosing artwork for an individual song."
                }
            } catch is CancellationError {
                resultMessage = "Online artwork search was cancelled before the iPod changed."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Scoped online artwork UI failed label=\(label) error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    private func readArtwork(from imageURL: URL) -> Data? {
        let access = imageURL.startAccessingSecurityScopedResource()
        defer { if access { imageURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            try ArtworkDatabase.validateSourceArtwork(data)
            return data
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.artwork("Custom artwork selection failed error=\(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func findMissingArtwork() {
#if DEBUG
        if isEmulatingIPod {
            emulateOnlineArtwork(
                trackIDs: Set(libraryTracks.filter { $0.artworkImageID == 0 || $0.artworkData == nil }.map(\.id)),
                label: "demo library",
                replaceExisting: false
            )
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary, automaticArtworkCandidateCount > 0 else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let missingIDs = libraryTracks.filter { $0.artworkImageID == 0 }.map(\.id)
                let embedded = try await IPodSyncEngine.restoreEmbeddedArtwork(
                    trackIDs: missingIDs,
                    root: destinationFolder
                )
                let remainingIDs = embedded.library.tracks.filter { $0.artworkImageID == 0 }.map(\.id)
                let result = remainingIDs.isEmpty
                    ? IPodSyncEngine.ArtworkSearchResult(searchedItems: 0, matchedItems: 0, updatedTracks: 0, failedLookups: 0, backupURL: nil)
                    : try await IPodSyncEngine.findMissingArtwork(
                        root: destinationFolder,
                        replaceExistingPlaylistArtwork: false
                    ) { progress in
                        await MainActor.run { self.artworkSearchProgress = progress }
                    }
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                let restored = embedded.restoredTracks
                if result.updatedTracks == 0 && restored == 0 {
                    resultMessage = result.searchedItems == 0
                        ? "No embedded covers or searchable missing-artwork tracks were found."
                        : "No embedded covers were found and no exact approved online matches were found for \(result.searchedItems) albums and songs."
                } else {
                    backups = try IPodSyncEngine.backups(root: destinationFolder)
                    let failures = result.failedLookups == 0 ? "" : " \(result.failedLookups) lookups failed and can be retried."
                    let embeddedText = restored == 0 ? "" : "Restored embedded covers for \(restored) tracks. "
                    let onlineText = result.updatedTracks == 0 ? "" : "Added online covers for \(result.updatedTracks) tracks from \(result.matchedItems) exact matches."
                    resultMessage = "\(embeddedText)\(onlineText)\(failures)"
                }
            } catch is CancellationError {
                resultMessage = "Artwork search cancelled before the iPod library was changed."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.artwork("Automatic artwork UI failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func repairAlbumGrouping() {
        runSafeLibraryRepairs(includeArtwork: false)
    }

    func fixAllSafeLibraryIssues() {
        runSafeLibraryRepairs(includeArtwork: true)
    }

    private func runSafeLibraryRepairs(includeArtwork: Bool) {
#if DEBUG
        if isEmulatingIPod {
            let groupsNeedingRepair = safeAlbumRepairCount
            let groups = Dictionary(grouping: libraryTracks.indices) { index in
                let track = libraryTracks[index]
                return track.albumID == 0
                    ? "metadata:\(track.album.lowercased())"
                    : "id:\(track.albumID)"
            }
            for indices in groups.values where indices.count > 1 {
                let namedArtists = indices.map { libraryTracks[$0].albumArtist }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let fallbackArtists = indices.map { libraryTracks[$0].artist }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard let artist = namedArtists.first ?? fallbackArtists.first else { continue }
                for index in indices { libraryTracks[index].albumArtist = artist }
            }
            if includeArtwork {
                let missingIDs = Set(libraryTracks.filter { $0.artworkImageID == 0 }.map(\.id))
                if missingIDs.isEmpty {
                    resultMessage = "Repaired safe album grouping issues in the demo library."
                    libraryRepairCompletion = LibraryRepairCompletion(repairedAlbumGroups: groupsNeedingRepair, restoredEmbeddedArtwork: 0, addedOnlineArtwork: 0)
                } else {
                    emulateOnlineArtwork(
                        trackIDs: missingIDs,
                        label: "demo library",
                        replaceExisting: false,
                        completion: { [weak self, groupsNeedingRepair] updated in
                            self?.libraryRepairCompletion = LibraryRepairCompletion(
                                repairedAlbumGroups: groupsNeedingRepair,
                                restoredEmbeddedArtwork: 0,
                                addedOnlineArtwork: updated
                            )
                        }
                    )
                }
            } else {
                resultMessage = "Repaired safe album grouping issues in the demo library."
                libraryRepairCompletion = LibraryRepairCompletion(repairedAlbumGroups: groupsNeedingRepair, restoredEmbeddedArtwork: 0, addedOnlineArtwork: 0)
            }
            return
        }
#endif
        guard let destinationFolder, !isManagingLibrary else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            let access = destinationFolder.startAccessingSecurityScopedResource()
            defer {
                if access { destinationFolder.stopAccessingSecurityScopedResource() }
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            do {
                let repair = try await IPodSyncEngine.repairAlbumArtists(root: destinationFolder)
                var embeddedResult: IPodSyncEngine.EmbeddedArtworkResult?
                var artworkResult: IPodSyncEngine.ArtworkSearchResult?
                if includeArtwork {
                    let libraryBeforeArtwork = try IPodSyncEngine.library(root: destinationFolder)
                    let missingIDs = libraryBeforeArtwork.tracks.filter { $0.artworkImageID == 0 }.map(\.id)
                    if !missingIDs.isEmpty {
                        embeddedResult = try await IPodSyncEngine.restoreEmbeddedArtwork(trackIDs: missingIDs, root: destinationFolder)
                    }
                    let remaining = (embeddedResult?.library.tracks ?? libraryBeforeArtwork.tracks)
                        .filter { $0.artworkImageID == 0 }
                        .count
                    if remaining > 0 {
                        artworkResult = try await IPodSyncEngine.findMissingArtwork(
                            root: destinationFolder,
                            replaceExistingPlaylistArtwork: false
                        ) { progress in
                            await MainActor.run { self.artworkSearchProgress = progress }
                        }
                    }
                }
                let library = try IPodSyncEngine.library(root: destinationFolder)
                libraryTracks = library.tracks
                libraryPlaylists = library.playlists
                refreshStorage(for: destinationFolder)
                backups = try IPodSyncEngine.backups(root: destinationFolder)
                let embeddedCovers = embeddedResult?.restoredTracks ?? 0
                let onlineCovers = artworkResult?.updatedTracks ?? 0
                let covers = embeddedCovers + onlineCovers
                resultMessage = "Repaired \(repair.repairedAlbums) album groups and added artwork to \(covers) tracks. Possible duplicates were left unchanged."
                libraryRepairCompletion = LibraryRepairCompletion(
                    repairedAlbumGroups: repair.repairedAlbums,
                    restoredEmbeddedArtwork: embeddedCovers,
                    addedOnlineArtwork: onlineCovers
                )
            } catch is CancellationError {
                resultMessage = "Library repair cancelled."
            } catch {
                errorMessage = error.localizedDescription
                AppLogger.sync("Safe library repair failed error=\(error.localizedDescription)", level: .error)
            }
        }
    }

    func cancelArtworkSearch() {
        artworkTask?.cancel()
    }

#if DEBUG
    private func emulateTrackMetadata(_ id: UInt32, update: ClassicDatabase.TrackMetadataUpdate) {
        guard let index = libraryTracks.firstIndex(where: { $0.id == id }) else { return }
        libraryTracks[index].title = update.title
        libraryTracks[index].artist = update.artist
        libraryTracks[index].album = update.album
        libraryTracks[index].genre = update.genre
        libraryTracks[index].year = update.year
        libraryTracks[index].trackNumber = update.trackNumber
        libraryTracks[index].albumArtist = update.albumArtist
        libraryTracks[index].compilation = update.compilation
        resultMessage = "Updated demo metadata for \(update.title)."
    }

    private func emulateAlbumMetadata(_ ids: Set<UInt32>, update: IPodSyncEngine.AlbumMetadataUpdate) {
        for index in libraryTracks.indices where ids.contains(libraryTracks[index].id) {
            libraryTracks[index].album = update.album
            libraryTracks[index].albumArtist = update.albumArtist
            if let artist = update.songArtist { libraryTracks[index].artist = artist }
            libraryTracks[index].genre = update.genre
            libraryTracks[index].year = update.year
            libraryTracks[index].compilation = update.compilation
        }
    }

    private func emulateArtwork(_ ids: Set<UInt32>, artwork: Data) {
        var nextID = (libraryTracks.map(\.artworkImageID).max() ?? 0) + 1
        for index in libraryTracks.indices where ids.contains(libraryTracks[index].id) {
            libraryTracks[index].artworkData = artwork
            libraryTracks[index].artworkByteCount = UInt32(clamping: artwork.count)
            libraryTracks[index].artworkImageID = nextID
            nextID += 1
        }
    }

    private func emulateDeleteTracks(_ ids: Set<UInt32>) {
        libraryTracks.removeAll { ids.contains($0.id) }
        libraryPlaylists = libraryPlaylists.map {
            ClassicPlaylist(name: $0.name, trackIDs: $0.trackIDs.filter { !ids.contains($0) })
        }
        existingTrackCount = libraryTracks.count
    }

    private func emulateOnlineArtwork(
        trackIDs: Set<UInt32>,
        label: String,
        replaceExisting: Bool,
        completion: ((Int) -> Void)? = nil
    ) {
        guard !isManagingLibrary, !trackIDs.isEmpty else { return }
        isManagingLibrary = true
        artworkSearchProgress = nil
        resultMessage = nil
        errorMessage = nil
        artworkTask?.cancel()
        artworkTask = Task {
            defer {
                artworkSearchProgress = nil
                isManagingLibrary = false
                artworkTask = nil
            }
            let service = ArtworkLookupService()
            let targets = libraryTracks.filter {
                trackIDs.contains($0.id) && (replaceExisting || $0.artworkData == nil)
            }
            var updated = 0
            for (offset, track) in targets.enumerated() {
                guard !Task.isCancelled else { return }
                artworkSearchProgress = .init(
                    completedItems: offset,
                    totalItems: targets.count,
                    matchedItems: updated,
                    tracksPrepared: updated
                )
                do {
                    let candidates = try await service.albumCandidates(album: track.album, artist: track.albumArtist.isEmpty ? track.artist : track.albumArtist)
                    if let artwork = candidates.first?.data {
                        emulateArtwork([track.id], artwork: artwork)
                        updated += 1
                    }
                } catch {
                    AppLogger.artwork("Demo artwork lookup failed id=\(track.id) error=\(error.localizedDescription)", level: .info)
                }
            }
            resultMessage = updated == 0
                ? "No exact online artwork matches were found for \(label)."
                : "Added artwork for \(updated) songs in the demo iPod."
            completion?(updated)
        }
    }
#endif
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
