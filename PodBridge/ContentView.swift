// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    private static let privacyPolicyURL = URL(
        string: "https://github.com/dbalantaev/PodBridge-OpenSource/blob/main/PRIVACY.md"
    )!

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MusicTransferViewModel()
    @State private var choosingSource = false
    @State private var choosingDestination = false
    @State private var showFiles = false
    @State private var confirmingSync = false
    @State private var showingDiagnostics = false
    @State private var confirmingRestore = false
    @State private var showingLibrary = false
    @State private var showingSignatureIDPrompt = false
    @State private var showingSignatureIDHelp = false
    @State private var showingDeviceModelChooser = false
    @State private var signatureID = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    safetyNotice
                    sourceSection
                    destinationSection
                    librarySection
                    transferSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("PodBridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Diagnostics", systemImage: "ladybug") {
                        openDiagnostics(source: "button")
                    }
                }
            }
        }
        .background {
            DebugShakeDetector {
                openDiagnostics(source: "shake")
            }
            .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticsDrawerView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingLibrary) {
            IPodLibraryView(model: model)
        }
        .sheet(isPresented: $showingSignatureIDHelp) {
            SignatureIDHelpView()
        }
        .fileImporter(
            isPresented: $choosingSource,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderResult(result, destination: false)
        }
        .fileImporter(
            isPresented: $choosingDestination,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderResult(result, destination: true)
        }
        .alert(
            "PodBridge",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .alert("iPod signature ID", isPresented: $showingSignatureIDPrompt) {
            TextField("16 hexadecimal digits", text: $signatureID)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Save to iPod and verify") {
                model.storeFirewireIDAndRepair(signatureID)
            }
            .disabled(!signatureIDIsValid)
            Button("How to find it") {
                Task { @MainActor in
                    await Task.yield()
                    showingSignatureIDHelp = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the 16-character ID from your Mac. PodBridge will save it to this iPod, remember it on your iPhone, and verify the music database.")
        }
        .confirmationDialog(
            "Choose the iPod model",
            isPresented: $showingDeviceModelChooser,
            titleVisibility: .visible
        ) {
            ForEach(IPodDeviceProfile.allCases) { profile in
                Button(profile.title + (profile.isHardwareTested ? " · tested" : " · untested")) {
                    model.selectDeviceProfile(profile)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only iPod Classic 7th gen 160 GB has been tested on real hardware. Every other model is experimental: make a full backup and begin with one track.")
        }
        .confirmationDialog(
            "Add music to this iPod?",
            isPresented: $confirmingSync,
            titleVisibility: .visible
        ) {
            Button("Back up library and add \(model.files.count) tracks") { model.startCopy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PodBridge will preserve existing tracks, playlists, and artwork, create verified database backups, then add music, M3U playlists, and embedded covers.")
        }
        .confirmationDialog(
            "Restore the original iPod library?",
            isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            if let backup = model.backups.first {
                Button("Restore \(backup.name) (\(backup.trackCount) tracks)", role: .destructive) {
                    model.restoreOldestBackup()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PodBridge will first save the current database, restore the oldest verified backup, and remove only music files added after that backup.")
        }
        .onChange(of: scenePhase) { _, phase in
            AppLogger.app("Scene phase=\(String(describing: phase))", level: .info)
            if phase != .active { PersistentLogStore.shared.flush() }
        }
        .onChange(of: model.destinationNeedsFirewireID) { _, needsID in
            guard needsID else { return }
            signatureID = ""
            Task { @MainActor in
                await Task.yield()
                showingSignatureIDPrompt = true
            }
        }
    }

    private var signatureIDIsValid: Bool {
        let value = signatureID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: [.anchored, .caseInsensitive])
        return value.count == 16 && value.allSatisfy(\.isHexDigit)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.tint)
            Text("Add music from Files to the iPod library")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Transfer music from the iPhone directly to the iPod library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("PodBridge changes only the music library, never firmware. Keep the app open and do not disconnect the iPod until sync completes.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Link(destination: Self.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
        }
        .font(.footnote)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private var sourceSection: some View {
        sectionCard(title: "1. Music source", icon: "music.note.list") {
            folderRow(
                title: model.sourceFolder?.lastPathComponent ?? "No folder selected",
                subtitle: sourceSubtitle,
                buttonTitle: model.sourceFolder == nil ? "Choose" : "Change"
            ) {
                choosingSource = true
            }

            if !model.files.isEmpty {
                DisclosureGroup(isExpanded: $showFiles) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.files) { file in
                            HStack(spacing: 10) {
                                Image(systemName: "music.note")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).lineLimit(1)
                                    Text(file.relativePath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(file.byteCount, format: .byteCount(style: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                } label: {
                    Text("Found tracks")
                        .font(.subheadline.weight(.medium))
                }
                if !model.playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Playlists")
                            .font(.subheadline.weight(.medium))
                        ForEach(model.playlists) { playlist in
                            HStack(spacing: 10) {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name).lineLimit(1)
                                    Text("\(playlist.fileIndices.count) tracks")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        Text("Each song keeps its own embedded artwork. Cover Flow may use one of those song covers for the compilation.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var destinationSection: some View {
        sectionCard(title: "2. iPod destination", icon: "externaldrive") {
            folderRow(
                title: model.destinationFolder?.lastPathComponent ?? "No folder selected",
                subtitle: model.destinationFolder == nil
                    ? "Connect the iPod, then choose its root folder."
                    : model.destinationDeviceProfile == nil
                        ? "iPod found · choose the exact model before writing."
                    : model.destinationNeedsFirewireID
                        ? "iPod found · signature ID needed before writing."
                        : "Validated \(model.destinationDeviceProfile?.shortTitle ?? "iPod").",
                buttonTitle: model.destinationFolder == nil ? "Choose" : "Change"
            ) {
                choosingDestination = true
            }
            if model.destinationFolder != nil {
                if let profile = model.destinationDeviceProfile {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(profile.shortTitle, systemImage: "ipod")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(model.existingTrackCount ?? 0) songs")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let fraction = model.storageUsedFraction,
                           let used = model.storageUsedBytes,
                           let free = model.storageFreeBytes,
                           let total = model.storageTotalBytes {
                            ProgressView(value: fraction)
                                .tint(fraction > 0.9 ? .orange : .accentColor)
                            HStack {
                                Text("\(formattedBytes(used)) used")
                                Spacer()
                                Text("\(formattedBytes(free)) free")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text("\(formattedBytes(total)) total")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Storage capacity is not available from Files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !profile.isHardwareTested {
                            Label("Experimental profile — not tested on real hardware.", systemImage: "flask")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Change iPod model") {
                            showingDeviceModelChooser = true
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showingDeviceModelChooser = true
                    } label: {
                        Label("Choose iPod model", systemImage: "list.bullet")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            if let backup = model.backups.first {
                Button {
                    confirmingRestore = true
                } label: {
                    Label("Restore backup \(backup.name)", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(model.isCopying || model.isRestoring)
            }
            if model.destinationFolder != nil, model.destinationDeviceProfile != nil {
                if model.destinationNeedsFirewireID {
                    Label("Finder did not provide this iPod’s signature ID.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button {
                        showingSignatureIDHelp = true
                    } label: {
                        Label("How to find the signature ID", systemImage: "questionmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    if model.destinationNeedsFirewireID {
                        showingSignatureIDPrompt = true
                    } else {
                        model.repairDatabaseSignature()
                    }
                } label: {
                    Label(
                        model.destinationNeedsFirewireID ? "Set signature ID and re-sign" : "Verify and re-sign iTunesDB",
                        systemImage: "checkmark.seal"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isCopying || model.isRestoring || model.isManagingLibrary)
            }
        }
    }

    private var transferSection: some View {
        sectionCard(title: "4. Sync library", icon: "arrow.right.circle") {
            if model.isCopying {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: model.copyProgress)
                    Text("Copied \(model.copiedCount) of \(model.files.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Stop", role: .destructive) {
                    model.cancelCopy()
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    confirmingSync = true
                } label: {
                    Label("Add to iPod Library", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.files.isEmpty || model.destinationFolder == nil || model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID)
            }

            if let resultMessage = model.resultMessage {
                Label(resultMessage, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private var librarySection: some View {
        sectionCard(title: "3. Manage iPod library", icon: "music.note") {
            if model.destinationFolder == nil {
                Text("Choose the iPod destination to browse and safely delete one track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.destinationDeviceProfile == nil {
                Text("Choose the iPod model before opening its library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.destinationNeedsFirewireID {
                Text("Set the signature ID before changing the iPod library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    showingLibrary = true
                } label: {
                    Label("Browse \(model.libraryTracks.count) tracks", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if let backup = model.deletionBackups.first {
                    Label("A backup from the earlier protected-deletion mode remains for \(backup.title). You can restore or discard it in the library screen.", systemImage: "externaldrive.badge.timemachine")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var sourceSubtitle: String {
        if model.isScanning { return "Scanning for supported audio…" }
        if model.files.isEmpty { return "Choose a folder containing AAC, ALAC, MP3, WAV, or AIFF files." }
        return "\(model.files.count) track\(model.files.count == 1 ? "" : "s") · \(model.playlists.count) playlist\(model.playlists.count == 1 ? "" : "s") · \(model.totalBytes.formatted(.byteCount(style: .file)))"
    }

    private func sectionCard<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func folderRow(
        title: String,
        subtitle: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func handleFolderResult(
        _ result: Result<[URL], Error>,
        destination: Bool
    ) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            if destination {
                model.selectDestination(url)
                if model.destinationFolder != nil { showingDeviceModelChooser = true }
            }
            else { model.selectSource(url) }
        case let .failure(error):
            model.errorMessage = error.localizedDescription
            AppLogger.ui("Folder picker failed error=\(error.localizedDescription)", level: .error)
        }
    }

    private func openDiagnostics(source: String) {
        AppLogger.ui("Diagnostics opened source=\(source)", level: .info)
        showingDiagnostics = true
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct SignatureIDHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let macCommand = "system_profiler SPUSBDataType | awk -F': ' '/Serial Number:/ {print $2}' | grep -E '^[0-9A-Fa-f]{16}$'"
    private let windowsCommand = "Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match '^USB\\\\VID_05AC' -and $_.PNPDeviceID -match '\\\\[0-9A-Fa-f]{16}$' } | ForEach-Object { ([regex]::Match($_.PNPDeviceID, '[0-9A-Fa-f]{16}$')).Value } | Sort-Object -Unique"
    private let linuxCommand = "sudo lsusb -v 2>/dev/null | awk '/iSerial/ {print $3}' | grep -E '^[0-9A-Fa-f]{16}$'"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("PodBridge already checked SysInfo and SysInfoExtended. iOS lets the app read the iPod’s files, but not the USB serial number required to sign iTunesDB.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Connect only the iPod to a computer, run one command below, then enter the 16-character hexadecimal result in PodBridge. The app remembers it for this iPod.")
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Easiest way on a Mac").font(.headline)
                        Text("1. Connect the iPod to the Mac.")
                        Text("2. Open System Information with Spotlight.")
                        Text("3. Select USB, then select the iPod.")
                        Text("4. Copy the 16-character Serial Number and enter it in PodBridge.")
                    }
                    .font(.subheadline)

                    Text("Or use a command")
                        .font(.headline)
                    commandCard(title: "macOS — Terminal", command: macCommand)
                    commandCard(title: "Windows — PowerShell", command: windowsCommand)
                    commandCard(title: "Linux — Terminal", command: linuxCommand)

                    Text("If more than one value appears, disconnect other USB devices and run the command again. Do not use the iPod’s regular serial number from its Settings screen.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Find signature ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func commandCard(title: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            Button {
                UIPasteboard.general.string = command
            } label: {
                Label("Copy command", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview {
    ContentView()
}

private struct IPodLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    @State private var searchText = ""
    @State private var backupToRestore: IPodSyncEngine.DeletionBackup?
    @State private var backupToDiscard: IPodSyncEngine.DeletionBackup?
    @State private var playlistToRename: PlaylistRenameTarget?
    @State private var playlistToDelete: PlaylistRenameTarget?
    @State private var showingPlaylistComposer = false

    private var filteredAlbums: [IPodAlbum] {
        guard !searchText.isEmpty else { return model.libraryAlbums }
        return model.libraryAlbums.filter { album in
            album.title.localizedCaseInsensitiveContains(searchText)
                || album.artist.localizedCaseInsensitiveContains(searchText)
                || album.tracks.contains { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                activitySection
                deletionBackupSection
                artworkSection
                playlistsSection
                albumsSection
                resultSection
            }
            .navigationTitle("iPod Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Album, artist, or song")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New Playlist", systemImage: "plus") {
                        showingPlaylistComposer = true
                    }
                    .disabled(model.isManagingLibrary || model.libraryTracks.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(model.isManagingLibrary)
                }
            }
        }
        .confirmationDialog(
            "Restore this deleted track?",
            isPresented: Binding(get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } }),
            titleVisibility: .visible
        ) {
            if let backup = backupToRestore {
                Button("Restore to iPod") {
                    backupToRestore = nil
                    model.restoreDeletedTrack(backup)
                }
            }
            Button("Cancel", role: .cancel) { backupToRestore = nil }
        } message: {
            Text("Restoration is allowed only while the iPod library is unchanged since deletion.")
        }
        .confirmationDialog(
            "Delete the iPhone backup?",
            isPresented: Binding(get: { backupToDiscard != nil }, set: { if !$0 { backupToDiscard = nil } }),
            titleVisibility: .visible
        ) {
            if let backup = backupToDiscard {
                Button("Make deletion permanent", role: .destructive) {
                    backupToDiscard = nil
                    model.discardDeletedTrackBackup(backup)
                }
            }
            Button("Cancel", role: .cancel) { backupToDiscard = nil }
        } message: {
            Text("The track will remain deleted from the iPod and its only PodBridge backup will be removed from this iPhone.")
        }
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: Binding(get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let target = playlistToDelete {
                let importedTrackCount = IPodSyncEngine.importedCompilationTrackIDs(
                    playlist: target.playlist,
                    tracks: model.libraryTracks
                ).count
                Button("Delete playlist only", role: .destructive) {
                    playlistToDelete = nil
                    model.deletePlaylist(at: target.index, includingSongs: false)
                }
                if importedTrackCount > 0 {
                    Button("Delete playlist and \(importedTrackCount) imported songs", role: .destructive) {
                        playlistToDelete = nil
                        model.deletePlaylist(at: target.index, includingSongs: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: {
            if let target = playlistToDelete {
                Text("Deleting only \(target.playlist.name) keeps its songs. The imported-songs option removes only tracks owned by its matching compilation album; reused songs from the older library stay untouched.")
            }
        }
        .sheet(item: $playlistToRename) { target in
            PlaylistRenameEditor(target: target) { name in
                model.renamePlaylist(at: target.index, to: name)
            }
        }
        .sheet(isPresented: $showingPlaylistComposer) {
            PlaylistComposerView(tracks: model.libraryTracks) { name, trackIDs in
                model.createPlaylist(name: name, trackIDs: trackIDs)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if model.isManagingLibrary {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    if let progress = model.artworkSearchProgress {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Searching album artwork…").font(.subheadline)
                            Text("\(progress.completedItems) of \(progress.totalItems) albums/songs · \(progress.matchedItems) matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { model.cancelArtworkSearch() }
                            .buttonStyle(.borderless)
                    } else {
                        Text("Verifying and updating the iPod…").font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var artworkSection: some View {
        if model.automaticArtworkCandidateCount > 0 {
            Section {
                Button("Find missing artwork", systemImage: "photo.badge.magnifyingglass") {
                    model.findMissingArtwork()
                }
                .disabled(model.isManagingLibrary)
            } footer: {
                Text("Missing normal-album covers are matched by album and album artist. Every playlist song is matched individually by title and artist; custom shared playlist artwork may be replaced by the song's original-release cover. \(model.automaticArtworkCandidateCount) tracks can be checked.")
            }
        }
    }

    @ViewBuilder
    private var deletionBackupSection: some View {
        if let backup = model.deletionBackups.first {
            Section {
                DeletionBackupSummary(backup: backup)
                Button("Restore to iPod", systemImage: "arrow.uturn.backward") {
                    backupToRestore = backup
                }
                .disabled(model.isManagingLibrary)
                Button("Make deletion permanent", systemImage: "trash", role: .destructive) {
                    backupToDiscard = backup
                }
                .disabled(model.isManagingLibrary)
            } header: {
                Text("Earlier local safety backup")
            } footer: {
                Text("New deletions are permanent and do not create audio backups. This older backup can still be restored if the library has not changed, or discarded to free iPhone storage.")
            }
        }
    }

    private var albumsSection: some View {
        Section("Albums (\(filteredAlbums.count))") {
            ForEach(filteredAlbums) { album in
                NavigationLink {
                    AlbumDetailView(model: model, albumID: album.id)
                } label: {
                    AlbumRow(album: album)
                }
            }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        if !model.libraryPlaylists.isEmpty {
            Section("Playlists (\(model.libraryPlaylists.count))") {
                ForEach(Array(model.libraryPlaylists.enumerated()), id: \.offset) { index, playlist in
                    HStack {
                        Button {
                            playlistToRename = PlaylistRenameTarget(index: index, playlist: playlist)
                        } label: {
                            HStack(spacing: 10) {
                            Image(systemName: "music.note.list").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).foregroundStyle(.primary)
                                Text("\(playlist.trackIDs.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                playlistToRename = PlaylistRenameTarget(index: index, playlist: playlist)
                            }
                            Button("Restore covers from audio files", systemImage: "arrow.uturn.backward.circle") {
                                model.restoreEmbeddedArtwork(
                                    trackIDs: playlist.trackIDs,
                                    label: playlist.name
                                )
                            }
                            Button("Restore original song covers online", systemImage: "photo.badge.magnifyingglass") {
                                model.replaceSongArtworkFromInternet(
                                    trackIDs: playlist.trackIDs,
                                    label: playlist.name
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isManagingLibrary)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            playlistToDelete = PlaylistRenameTarget(index: index, playlist: playlist)
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Rename", systemImage: "pencil") {
                            playlistToRename = PlaylistRenameTarget(index: index, playlist: playlist)
                        }
                        .tint(.blue)
                        .disabled(model.isManagingLibrary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let message = model.resultMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

}

private struct DeletionBackupSummary: View {
    let backup: IPodSyncEngine.DeletionBackup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(backup.title).font(.headline)
            Text(backup.artist).font(.subheadline).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlbumRow: View {
    let album: IPodAlbum

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).foregroundStyle(.primary)
                Text("\(album.artist) · \(album.tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(album.byteCount), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let albumID: String
    @State private var editingAlbum = false
    @State private var confirmingAlbumDeletion = false
    @State private var trackToEdit: ClassicTrack?
    @State private var trackToDelete: ClassicTrack?
    @State private var choosingAlbumArtwork = false
    @State private var choosingTrackArtwork = false
    @State private var trackArtworkTarget: ClassicTrack?
    @State private var onlineArtworkTarget: OnlineArtworkTarget?

    private var album: IPodAlbum? {
        model.libraryAlbums.first { $0.id == albumID }
    }

    var body: some View {
        Group {
            if let album {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(album.title).font(.title3.weight(.semibold))
                            Text(album.artist).foregroundStyle(.secondary)
                            Text("\(album.tracks.count) tracks · \(ByteCountFormatter.string(fromByteCount: Int64(album.byteCount), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Edit album metadata", systemImage: "pencil") {
                            editingAlbum = true
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Find album artwork online", systemImage: "photo.badge.magnifyingglass") {
                            onlineArtworkTarget = .album(album)
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Choose album artwork from Files", systemImage: "folder") {
                            choosingAlbumArtwork = true
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Restore embedded song covers", systemImage: "arrow.uturn.backward.circle") {
                            model.restoreEmbeddedArtwork(album)
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Find an original cover for every song", systemImage: "sparkles.rectangle.stack") {
                            model.replaceSongArtworkFromInternet(
                                trackIDs: album.tracks.map(\.id),
                                label: album.title
                            )
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Delete album", systemImage: "trash", role: .destructive) {
                            confirmingAlbumDeletion = true
                        }
                        .disabled(model.isManagingLibrary)
                    }
                    Section("Songs") {
                        ForEach(album.tracks) { track in
                            LibraryTrackRow(track: track, disabled: model.isManagingLibrary) {
                                trackToEdit = track
                            } artworkAction: {
                                onlineArtworkTarget = .track(track)
                            } fileArtworkAction: {
                                trackArtworkTarget = track
                                choosingTrackArtwork = true
                            } deleteAction: {
                                trackToDelete = track
                            }
                        }
                    }
                    if model.isManagingLibrary {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Updating and verifying the iPod library…")
                            }
                        }
                    }
                }
                .navigationTitle(album.title)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $editingAlbum) {
                    AlbumMetadataEditor(album: album) { update in
                        model.editAlbumMetadata(album, update: update)
                    }
                }
                .sheet(item: $trackToEdit) { track in
                    TrackMetadataEditor(track: track) { update in
                        model.editTrackMetadata(track, update: update)
                    }
                }
                .sheet(item: $onlineArtworkTarget) { target in
                    OnlineArtworkPicker(target: target) { data in
                        switch target.scope {
                        case .album:
                            if let currentAlbum = self.album {
                                model.setAlbumArtwork(currentAlbum, artwork: data)
                            }
                        case .track:
                            if let trackID = target.trackIDs.first,
                               let currentTrack = model.libraryTracks.first(where: { $0.id == trackID }) {
                                model.setTrackArtwork(currentTrack, artwork: data)
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "Permanently delete this album?",
                    isPresented: $confirmingAlbumDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete \(album.tracks.count) tracks", role: .destructive) {
                        model.deleteAlbumPermanently(album)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(album.title) will be removed without an audio backup, freeing approximately \(ByteCountFormatter.string(fromByteCount: Int64(album.byteCount), countStyle: .file)). This cannot be undone.")
                }
                .confirmationDialog(
                    "Permanently delete this song?",
                    isPresented: Binding(get: { trackToDelete != nil }, set: { if !$0 { trackToDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    if let track = trackToDelete {
                        Button("Delete song", role: .destructive) {
                            trackToDelete = nil
                            model.deleteTrackPermanently(track)
                            if album.tracks.count == 1 { dismiss() }
                        }
                    }
                    Button("Cancel", role: .cancel) { trackToDelete = nil }
                } message: {
                    if let track = trackToDelete {
                        Text("\(track.title) will be removed without an audio backup. This cannot be undone.")
                    }
                }
            } else {
                ContentUnavailableView("Album no longer exists", systemImage: "music.note")
            }
        }
        .fileImporter(
            isPresented: $choosingAlbumArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let album else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first { model.setAlbumArtwork(album, imageURL: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $choosingTrackArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let track = trackArtworkTarget else { return }
            trackArtworkTarget = nil
            switch result {
            case .success(let urls):
                if let url = urls.first { model.setTrackArtwork(track, imageURL: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct AlbumMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let album: IPodAlbum
    let save: (IPodSyncEngine.AlbumMetadataUpdate) -> Void
    @State private var title: String
    @State private var albumArtist: String
    @State private var songArtist: String
    @State private var genre: String
    @State private var year: String
    @State private var compilation: Bool

    init(album: IPodAlbum, save: @escaping (IPodSyncEngine.AlbumMetadataUpdate) -> Void) {
        self.album = album
        self.save = save
        _title = State(initialValue: album.title)
        _albumArtist = State(initialValue: album.albumArtist)
        let songArtists = Set(album.tracks.map { $0.artist.trimmingCharacters(in: .whitespacesAndNewlines) })
        _songArtist = State(initialValue: songArtists.count == 1 ? songArtists.first ?? "" : "")
        _genre = State(initialValue: album.genre)
        _year = State(initialValue: album.year == 0 ? "" : String(album.year))
        _compilation = State(initialValue: album.compilation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Album metadata") {
                    TextField("Album", text: $title)
                    TextField("Album artist", text: $albumArtist)
                    TextField("Song artist (all tracks)", text: $songArtist)
                    TextField("Genre", text: $genre)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    Toggle("Compilation", isOn: $compilation)
                }
                Section {
                    Text("Album-level values will be applied to all \(album.tracks.count) tracks. Use “Various Artists” with Compilation enabled for a mixed-artist album.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Enter a song artist to replace the artist on every track. Leave it empty to keep each song’s current artist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Matching duplicate album cards are merged automatically, including an existing card that already has the new album artist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(IPodSyncEngine.AlbumMetadataUpdate(
                            album: title,
                            albumArtist: albumArtist,
                            songArtist: songArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : songArtist,
                            genre: genre,
                            year: UInt32(year) ?? 0,
                            compilation: compilation
                        ))
                        dismiss()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (compilation && albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
        }
    }
}

private struct LibraryTrackRow: View {
    let track: ClassicTrack
    let disabled: Bool
    let editAction: () -> Void
    let artworkAction: () -> Void
    let fileArtworkAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        Button(action: editAction) {
            HStack(spacing: 12) {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(track.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive, action: deleteAction)
                .disabled(disabled)
            Button("Edit", systemImage: "pencil", action: editAction)
                .tint(.blue)
                .disabled(disabled)
            Button("Artwork", systemImage: "photo", action: artworkAction)
                .tint(.purple)
                .disabled(disabled)
            Button("File", systemImage: "folder", action: fileArtworkAction)
                .tint(.gray)
                .disabled(disabled)
        }
    }

    private var subtitle: String {
        [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct OnlineArtworkTarget: Identifiable {
    enum Scope { case album, track }

    let id = UUID()
    let scope: Scope
    let title: String
    let artist: String
    let trackIDs: [UInt32]

    static func album(_ album: IPodAlbum) -> Self {
        Self(scope: .album, title: album.title, artist: album.artist, trackIDs: album.tracks.map(\.id))
    }

    static func track(_ track: ClassicTrack) -> Self {
        Self(scope: .track, title: track.title, artist: track.artist, trackIDs: [track.id])
    }
}

private struct OnlineArtworkPicker: View {
    @Environment(\.dismiss) private var dismiss
    let target: OnlineArtworkTarget
    let select: (Data) -> Void
    @State private var title: String
    @State private var artist: String
    @State private var candidates: [ArtworkLookupService.Candidate] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    init(target: OnlineArtworkTarget, select: @escaping (Data) -> Void) {
        self.target = target
        self.select = select
        _title = State(initialValue: target.title)
        _artist = State(initialValue: target.artist)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Search") {
                    TextField(target.scope == .album ? "Album" : "Song", text: $title)
                    TextField("Artist", text: $artist)
                    Button("Search the internet", systemImage: "magnifyingglass") { search() }
                        .disabled(searching || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if searching {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for cover variants…")
                        }
                    }
                } else if candidates.isEmpty, errorMessage == nil {
                    Section {
                        Text("Search results will appear here. Choosing one forcibly replaces the current iPod artwork.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if !candidates.isEmpty {
                    Section("Choose artwork") {
                        ForEach(candidates) { candidate in
                            Button {
                                select(candidate.data)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    if let image = UIImage(data: candidate.data) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 76, height: 76)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.title).foregroundStyle(.primary)
                                        Text(candidate.artist).font(.caption).foregroundStyle(.secondary)
                                        Text("Use this cover").font(.caption2).foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Online Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { search() }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private func search() {
        searchTask?.cancel()
        candidates = []
        errorMessage = nil
        searching = true
        let queryTitle = title
        let queryArtist = artist
        searchTask = Task {
            do {
                let service = ArtworkLookupService()
                let found: [ArtworkLookupService.Candidate]
                found = try await withThrowingTaskGroup(of: [ArtworkLookupService.Candidate].self) { group in
                    group.addTask {
                        switch target.scope {
                        case .album:
                            return try await service.albumCandidates(album: queryTitle, artist: queryArtist)
                        case .track:
                            return try await service.trackCandidates(track: queryTitle, artist: queryArtist)
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(20))
                        throw URLError(.timedOut)
                    }
                    guard let first = try await group.next() else { return [] }
                    group.cancelAll()
                    return first
                }
                guard !Task.isCancelled else { return }
                candidates = found
                if found.isEmpty { errorMessage = "No exact cover variants found. You can edit the title or artist and search again." }
                searching = false
            } catch is CancellationError {
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? URLError)?.code == .timedOut
                    ? "The artwork service did not respond within 20 seconds. Try again."
                    : error.localizedDescription
                searching = false
            }
        }
    }
}

private struct PlaylistRenameTarget: Identifiable {
    let index: Int
    let playlist: ClassicPlaylist

    var id: Int { index }
}

private struct PlaylistComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let tracks: [ClassicTrack]
    let save: (String, [UInt32]) -> Void
    @State private var name = ""
    @State private var searchText = ""
    @State private var selectedIDs: [UInt32] = []

    private var selected: Set<UInt32> { Set(selectedIDs) }
    private var filteredTracks: [ClassicTrack] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Playlist") {
                    TextField("Name", text: $name)
                    Text("\(selectedIDs.count) songs selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Songs") {
                    ForEach(filteredTracks) { track in
                        Button {
                            toggle(track.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(track.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).foregroundStyle(.primary)
                                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Song, artist, or album")
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines), selectedIDs)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedIDs.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: UInt32) {
        if let index = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: index) }
        else { selectedIDs.append(id) }
    }
}

private struct PlaylistRenameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: PlaylistRenameTarget
    let save: (String) -> Void
    @State private var name: String

    init(target: PlaylistRenameTarget, save: @escaping (String) -> Void) {
        self.target = target
        self.save = save
        _name = State(initialValue: target.playlist.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Playlist name", text: $name)
            }
            .navigationTitle("Rename Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct TrackMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let track: ClassicTrack
    let save: (ClassicDatabase.TrackMetadataUpdate) -> Void
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var year: String
    @State private var trackNumber: String

    init(track: ClassicTrack, save: @escaping (ClassicDatabase.TrackMetadataUpdate) -> Void) {
        self.track = track
        self.save = save
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _genre = State(initialValue: track.genre)
        _year = State(initialValue: track.year == 0 ? "" : String(track.year))
        _trackNumber = State(initialValue: track.trackNumber == 0 ? "" : String(track.trackNumber))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Metadata") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Genre", text: $genre)
                }
                Section("Track details") {
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Track number", text: $trackNumber).keyboardType(.numberPad)
                }
                Section {
                    Text("The audio file is not transcoded. PodBridge updates the iPod database, album/artist links, and Apple sort indexes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(ClassicDatabase.TrackMetadataUpdate(
                            title: title,
                            artist: artist,
                            album: album,
                            genre: genre,
                            year: UInt32(year) ?? 0,
                            trackNumber: UInt32(trackNumber) ?? 0,
                            albumArtist: track.albumArtist,
                            compilation: track.compilation
                        ))
                        dismiss()
                    }
                    .disabled(requiredFieldsAreEmpty)
                }
            }
        }
    }

    private var requiredFieldsAreEmpty: Bool {
        [title, artist, album].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
