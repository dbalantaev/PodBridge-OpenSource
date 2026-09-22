// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PodBridgeUnavailableView: View {
    let title: String
    let systemImage: String
    let description: Text?

    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct PodBridgeLabeledContent<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

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
    @State private var showingSettings = false
    @State private var confirmingRestore = false
    @State private var showingLibrary = false
    @State private var showingALACarte = false
    @State private var showingTransferSuccess: TransferCompletion?
    @State private var showingTransferProgress = false
    @State private var showingSignatureIDPrompt = false
    @State private var showingSignatureIDHelp = false
    @State private var showingDeviceModelChooser = false
    @State private var signatureID = ""
    @State private var showingImportReview = false
    @State private var showingErrorAlert = false
    @State private var presentedErrorMessage = ""

    var body: some View {
        dialogContent
            .onChange(of: scenePhase) { phase in
                AppLogger.app("Scene phase=\(String(describing: phase))", level: .info)
                if phase != .active { PersistentLogStore.shared.flush() }
            }
            .onChange(of: model.transferCompletion?.id) { _ in
                guard !showingALACarte else { return }
                guard let completion = model.transferCompletion else { return }
                showingTransferSuccess = completion
            }
            .onChange(of: model.destinationNeedsFirewireID) { needsID in
                guard needsID else { return }
                signatureID = ""
                Task { @MainActor in
                    await Task.yield()
                    showingSignatureIDPrompt = true
                }
            }
            .onChange(of: model.shouldChooseDeviceProfile) { shouldShow in
                guard shouldShow else { return }
                model.acknowledgeDeviceProfilePrompt()
                showingDeviceModelChooser = true
            }
            .onChange(of: model.errorMessage) { message in
                guard let message else { return }
                presentedErrorMessage = message
                showingErrorAlert = true
            }
            .onChange(of: model.isScanning) { scanning in
                guard !scanning, !model.files.isEmpty else { return }
                showingImportReview = true
            }
    }

    private var rootContent: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    homeHeader
                    homeContent
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                }
            }
            .background(Color(.systemBackground))
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .overlay {
            if model.isConnectingIPod {
                PodBridgeLoadingOverlay(
                    title: "Connecting to iPod…",
                    detail: "Reading and verifying the music library"
                )
            } else if model.isScanning {
                PodBridgeLoadingOverlay(
                    title: "Scanning Music…",
                    detail: "Finding supported songs and playlists"
                )
            } else if model.isRestoring {
                PodBridgeLoadingOverlay(
                    title: "Restoring iPod Library…",
                    detail: "Keep the iPod connected until verification finishes"
                )
            }
        }
    }

    private var homeHeader: some View {
        ZStack {
            Text("PodBridge")
                .font(model.destinationFolder == nil ? .headline : .title2.bold())
                .frame(maxWidth: .infinity, alignment: model.destinationFolder == nil ? .center : .leading)

            HStack {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var primaryPresentationContent: some View {
        rootContent
        .background {
            DebugShakeDetector {
                openDiagnostics(source: "shake")
            }
            .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $showingDiagnostics) {
#if DEBUG
            DiagnosticsDrawerView(
                isEmulatingIPod: model.isEmulatingIPod,
                emulateIPod: { model.emulateConnectedIPod() }
            )
#else
            DiagnosticsDrawerView()
#endif
        }
        .sheet(isPresented: $showingSettings) {
            PodBridgeSettingsView {
                showingSettings = false
                Task { @MainActor in
                    await Task.yield()
                    openDiagnostics(source: "settings")
                }
            }
        }
        .sheet(isPresented: $showingLibrary) {
            PodBridgeLibraryView(model: model)
        }
        .sheet(isPresented: $showingImportReview) {
            ImportReviewView(model: model) {
                showingImportReview = false
                Task { @MainActor in
                    await Task.yield()
                    confirmingSync = true
                }
            }
        }
#if PODBRIDGE_ALACARTE
        .sheet(isPresented: $showingALACarte) {
            ALACarteBrowserView(model: model)
        }
#endif
        .fullScreenCover(isPresented: $showingTransferProgress) {
            TransferProgressView(model: model)
        }
        .fullScreenCover(item: $showingTransferSuccess) { completion in
            TransferSuccessView(model: model, completion: completion)
        }
    }

    private var secondaryPresentationContent: some View {
        primaryPresentationContent
        .sheet(isPresented: $showingSignatureIDHelp) {
            SignatureIDHelpView()
        }
    }

    private var importerContent: some View {
        secondaryPresentationContent
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
    }

    private var alertContent: some View {
        importerContent
        .alert("PodBridge", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) {
                showingErrorAlert = false
                model.errorMessage = nil
            }
        } message: {
            Text(presentedErrorMessage)
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
    }

    private var dialogContent: some View {
        alertContent
        .confirmationDialog("Choose the iPod model", isPresented: $showingDeviceModelChooser, titleVisibility: .visible) {
            ForEach(IPodDeviceProfile.allCases) { profile in
                Button(profile.title + (profile.isHardwareTested ? " · tested" : " · untested")) {
                    model.selectDeviceProfile(profile)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only iPod Classic 7th gen 160 GB has been tested on real hardware. Every other model is experimental: make a full backup and begin with one track.")
        }
        .confirmationDialog("Add music to this iPod?", isPresented: $confirmingSync, titleVisibility: .visible) {
            Button("Back up library and add \(model.files.count) tracks") {
                showingTransferProgress = true
                model.startCopy()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PodBridge will preserve existing tracks, playlists, and artwork, create verified database backups, then add music, M3U playlists, and embedded covers.")
        }
        .confirmationDialog("Restore the original iPod library?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            if let backup = model.backups.first {
                Button("Restore \(backup.name) (\(backup.trackCount) tracks)", role: .destructive) {
                    model.restoreOldestBackup()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("PodBridge will first save the current database, restore the oldest verified backup, and remove only music files added after that backup.")
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        if model.destinationFolder == nil {
            disconnectedHome
        } else {
            connectedHome
        }
    }

    private var disconnectedHome: some View {
        VStack(spacing: 0) {
            Button {
                choosingDestination = true
            } label: {
                VStack(spacing: 0) {
                    PodBridgeIPodClassicArtwork(showsCable: true)
                        .frame(height: 232)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect your iPod")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text("Choose your connected iPod in Files")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect your iPod")
            .accessibilityHint("Opens Files to choose the connected iPod")
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 8) {
                Label("Works with iPod classic, nano, mini and other supported models. Changes only your music library, never firmware.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Learn how to connect") { showingSignatureIDHelp = true }
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 14)

            Text("For music you own. Not affiliated with Apple.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectedHome: some View {
        VStack(spacing: 12) {
            deviceCard
                .padding(.top, 8)

            homeAction(title: "Add Music", subtitle: addMusicSubtitle, icon: "music.note", tint: .blue) {
                choosingSource = true
            }
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID || model.isCopying)

#if PODBRIDGE_ALACARTE
            homeAction(title: "ALACarte", subtitle: "Import music from your server", icon: "music.note", tint: .pink) {
                showingALACarte = true
            }
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID || model.isCopying)
#endif

            homeAction(title: "Your Library", subtitle: librarySubtitle, icon: "books.vertical.fill", tint: .purple) {
                showingLibrary = true
            }
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID || model.isCopying)

            if model.destinationDeviceProfile == nil {
                setupCard
            } else if model.destinationNeedsFirewireID {
                signatureCard
            }

            if !model.files.isEmpty && !model.isCopying {
                readyToTransferCard
            }

            Label("Keep PodBridge open while transferring music. It does not distribute music files.", systemImage: "lightbulb.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var deviceCard: some View {
        HStack(spacing: 18) {
            PodBridgeIPodDeviceArtwork(profile: model.destinationDeviceProfile)
                .frame(width: 66, height: 112)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.isEmulatingIPod ? "Demo iPod" : (model.destinationFolder?.lastPathComponent ?? "iPod"))
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(model.destinationDeviceProfile?.shortTitle ?? "iPod detected")
#if DEBUG
                    if model.isEmulatingIPod {
                        Text("EMULATED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.14), in: Capsule())
                            .foregroundStyle(.orange)
                    }
#endif
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let fraction = model.storageUsedFraction {
                    ProgressView(value: fraction)
                        .padding(.top, 6)
                }

                if let free = model.storageFreeBytes, let total = model.storageTotalBytes {
                    Text("\(formattedBytes(free)) free of \(formattedBytes(total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let count = model.existingTrackCount {
                    Text("\(count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                showingDeviceModelChooser = true
            } label: {
                Image(systemName: "ipod")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.isCopying || model.isManagingLibrary || model.isRestoring)
            .accessibilityLabel("Choose iPod model")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func homeAction(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(tint, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish iPod setup", systemImage: "ipod")
                .font(.headline)
            Text("Choose the exact iPod model before PodBridge writes to its library.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose iPod Model") { showingDeviceModelChooser = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private var signatureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Signature ID required", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("PodBridge needs this iPod’s signature ID before changing the music library.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Set Signature ID") { showingSignatureIDPrompt = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private var readyToTransferCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to add")
                        .font(.headline)
                    Text("\(model.files.count) songs · \(model.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change") { choosingSource = true }
                    .font(.caption.weight(.semibold))
            }
            Button {
                showingImportReview = true
            } label: {
                Text("Review \(model.files.count) Songs")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var transferProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Adding Music")
                .font(.headline)
            ProgressView(value: model.copyProgress)
            Text("\(model.copiedCount) of \(model.files.count) songs")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("Keep PodBridge open and your iPod connected until the transfer finishes.", systemImage: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Stop", role: .destructive) { model.cancelCopy() }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            Text(transferSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var transferSubtitle: String {
#if targetEnvironment(macCatalyst)
        "Transfer music from a Mac folder directly to the iPod library."
#else
        "Transfer music from the iPhone directly to the iPod library."
#endif
    }

    private var addMusicSubtitle: String {
        "Choose a music folder in Files"
    }

    private var librarySubtitle: String {
        let albumCount = model.libraryAlbums.count
        return "\(model.libraryTracks.count) songs · \(albumCount) \(albumCount == 1 ? "album" : "albums")"
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
        sectionCard(title: transferSectionTitle, icon: "arrow.right.circle") {
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

#if PODBRIDGE_ALACARTE
    private var alacarteSection: some View {
        sectionCard(title: "3. Self-hosted library", icon: "network") {
            Text("Connect to your own PodBridge-compatible ALACarte server and import already-downloaded ALAC/M4A files.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showingALACarte = true
            } label: {
                Label("Connect to ALACarte", systemImage: "macbook.and.iphone")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.isCopying)
        }
    }
#endif

    private var librarySection: some View {
        sectionCard(title: librarySectionTitle, icon: "music.note") {
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

    private var librarySectionTitle: String {
        "3. Manage iPod library"
    }

    private var transferSectionTitle: String {
        "4. Sync library"
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
        NavigationView {
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
        NavigationView {
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("New Playlist", systemImage: "plus") {
                        showingPlaylistComposer = true
                    }
                    .disabled(model.isManagingLibrary || model.libraryTracks.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
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
                PodBridgeUnavailableView("Album no longer exists", systemImage: "music.note")
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
        NavigationView {
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
        NavigationView {
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
                        try await Task.sleep(nanoseconds: 20_000_000_000)
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
        NavigationView {
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
        NavigationView {
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
        NavigationView {
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


private struct PodBridgeIPodClassicArtwork: View {
    var showsCable = false

    var body: some View {
        Image(showsCable ? "IPodRenderCable" : "IPodRender")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

/// A neutral, recognisable device silhouette. iPod storage does not expose the
/// physical case colour, so the app intentionally never guesses it.
private struct PodBridgeIPodDeviceArtwork: View {
    let profile: IPodDeviceProfile?

    private var bodyAspect: CGFloat {
        switch profile {
        case .nano3: 1.20
        case .nano4: 0.47
        case .nano1And2: 0.46
        default: 0.60
        }
    }

    private var screenFraction: CGFloat {
        switch profile {
        case .video5: 0.32
        case .nano3: 0.36
        case .nano4: 0.28
        default: 0.38
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let width = min(proxy.size.width, height * bodyAspect)
            let x = (proxy.size.width - width) / 2
            let bezel = max(3, width * 0.075)
            ZStack {
                RoundedRectangle(cornerRadius: width * (profile == .nano4 ? 0.30 : 0.12), style: .continuous)
                    .fill(.white.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: width * (profile == .nano4 ? 0.30 : 0.12), style: .continuous)
                            .stroke(.white.opacity(0.65), lineWidth: 1)
                    )
                    .frame(width: width, height: height)
                    .position(x: x + width / 2, y: height / 2)

                RoundedRectangle(cornerRadius: max(2, width * 0.05), style: .continuous)
                    .fill(Color.black.opacity(0.84))
                    .frame(width: width - bezel * 2, height: height * screenFraction)
                    .position(x: x + width / 2, y: height * (profile == .nano3 ? 0.38 : 0.31))

                if profile != .nano3 && profile != .nano4 {
                    Circle()
                        .fill(Color(.systemGray5))
                        .overlay(Circle().stroke(Color.black.opacity(0.10), lineWidth: 1))
                        .frame(width: width * 0.54, height: width * 0.54)
                        .overlay(Circle().fill(.white).frame(width: width * 0.17, height: width * 0.17))
                        .position(x: x + width / 2, y: height * 0.70)
                } else if profile == .nano3 {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: height * 0.22, height: height * 0.22)
                        .overlay(Circle().fill(.white).frame(width: height * 0.07, height: height * 0.07))
                        .position(x: x + width * 0.73, y: height * 0.53)
                } else {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: width * 0.65, height: width * 0.65)
                        .overlay(Circle().fill(.white).frame(width: width * 0.20, height: width * 0.20))
                        .position(x: x + width / 2, y: height * 0.68)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PodBridgeLoadingOverlay: View {
    let title: String
    let detail: String?
    var cancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.18)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.bordered)
                        .padding(.top, 2)
                }
            }
            .padding(24)
            .frame(maxWidth: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "Please wait")
    }
}

private struct ImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let add: () -> Void
    @State private var selectedIDs: Set<String>

    init(model: MusicTransferViewModel, add: @escaping () -> Void) {
        self.model = model
        self.add = add
        _selectedIDs = State(initialValue: Set(model.files.map(\.id)))
    }

    private var selectedFiles: [MusicFile] { model.scannedFiles.filter { selectedIDs.contains($0.id) } }
    private var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.byteCount } }

    var body: some View {
        NavigationView {
            List {
                Section {
                    PodBridgeLabeledContent("Selected") { Text("\(selectedFiles.count) of \(model.scannedFiles.count) songs") }
                    PodBridgeLabeledContent("Size") { Text(selectedBytes.formatted(.byteCount(style: .file))) }
                    PodBridgeLabeledContent("Playlists") { Text("\(model.scannedPlaylists.count)") }
                    if !model.skippedAudioByExtension.isEmpty {
                        PodBridgeLabeledContent("Skipped") {
                            Text(model.skippedAudioByExtension.sorted { $0.key < $1.key }.map { "\($0.value) .\($0.key)" }.joined(separator: ", "))
                        }
                    }
                } footer: {
                    Text("PodBridge found supported audio in the selected folder. Other file types are ignored.")
                }

                if !model.scannedPlaylists.isEmpty {
                    Section("Playlists") {
                        ForEach(model.scannedPlaylists) { playlist in
                            let included = playlist.fileIndices.filter { index in
                                model.scannedFiles.indices.contains(index) && selectedIDs.contains(model.scannedFiles[index].id)
                            }.count
                            HStack {
                                Label(playlist.name, systemImage: "music.note.list")
                                Spacer()
                                Text("\(included) songs").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Songs") {
                    ForEach(model.scannedFiles) { file in
                        Button {
                            if selectedIDs.contains(file.id) { selectedIDs.remove(file.id) }
                            else { selectedIDs.insert(file.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(file.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.displayTitle).foregroundStyle(.primary).lineLimit(1)
                                    Text(importSubtitle(for: file)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(file.byteCount.formatted(.byteCount(style: .file)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(file.displayTitle)
                        .accessibilityValue(selectedIDs.contains(file.id) ? "Selected" : "Not selected")
                        .accessibilityHint("Double-tap to change whether this song is imported")
                    }
                }
            }
            .navigationTitle("Review Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedFiles.count)") {
                        model.keepImportFiles(withIDs: selectedIDs)
                        add()
                    }
                    .disabled(selectedFiles.isEmpty)
                }
            }
        }
    }

    private func importSubtitle(for file: MusicFile) -> String {
        let metadata = [file.displayArtist, file.preview?.album]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return metadata.isEmpty ? file.name : metadata.joined(separator: " · ")
    }
}

private struct PodBridgeDockCableArtwork: View {
    let width: CGFloat
    let dark: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: width * 0.015, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: dark
                                ? [Color(white: 0.68), Color(white: 0.34)]
                                : [Color(white: 0.93), Color(white: 0.58)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: width * 0.015, style: .continuous)
                            .stroke(.black.opacity(0.28), lineWidth: 0.6)
                    )
                    .frame(width: width * 0.22, height: 12)

                Rectangle()
                    .fill(.black.opacity(0.30))
                    .frame(width: width * 0.13, height: 2)
                    .offset(y: -3)
            }

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: dark
                            ? [Color(white: 0.60), Color(white: 0.32)]
                            : [Color(white: 0.90), Color(white: 0.60)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.16), lineWidth: 0.5))
                .frame(width: 8, height: 17)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(dark ? Color(white: 0.72) : Color(white: 0.92))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.14), lineWidth: 0.5))
                .frame(width: 10, height: 10)

            Rectangle()
                .fill(dark ? Color(white: 0.58) : Color(white: 0.82))
                .frame(width: 4, height: 15)
        }
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

// MARK: - PodBridge consumer library UI (Iteration 3)
private struct PodBridgeLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    @State private var searchText = ""
    @State private var section = 0

    private var tracks: [ClassicTrack] {
        model.libraryTracks.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) || $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }
    private var albums: [IPodAlbum] {
        model.libraryAlbums.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) || $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }
    private var artists: [String] {
        Array(Set(model.libraryTracks.map(\.artist))).filter {
            !$0.isEmpty && (searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText))
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var playlists: [(index: Int, playlist: ClassicPlaylist)] {
        Array(model.libraryPlaylists.enumerated()).compactMap { index, playlist in
            searchText.isEmpty || playlist.name.localizedCaseInsensitiveContains(searchText)
                ? (index, playlist)
                : nil
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Button { dismiss() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                Text("PodBridge")
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("iPod Library")
                            .font(.largeTitle.bold())
                        Text("\(model.libraryTracks.count.formatted()) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your iPod…", text: $searchText)
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Picker("Library", selection: $section) {
                        Text("Songs").tag(0); Text("Albums").tag(1); Text("Artists").tag(2); Text("Playlists").tag(3)
                    }
                    .pickerStyle(.segmented)

                    NavigationLink(destination: PodBridgeLibraryToolsView(model: model)) {
                        HStack(spacing: 13) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).background(.purple, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Library Tools").font(.headline).foregroundStyle(.primary)
                                Text("Artwork, metadata, duplicates and playlists").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                        .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }.buttonStyle(.plain)

                    libraryContent
                }.padding(16)
            }
            .background(Color(.systemBackground))
            .navigationBarHidden(true)
        }
        .overlay {
            if model.isManagingLibrary {
                PodBridgeLoadingOverlay(
                    title: model.artworkSearchProgress == nil ? "Updating iPod Library…" : "Finding Artwork…",
                    detail: libraryActivityDetail,
                    cancel: model.artworkSearchProgress == nil ? nil : { model.cancelArtworkSearch() }
                )
            }
        }
    }

    private var libraryActivityDetail: String? {
        guard let progress = model.artworkSearchProgress else {
            return "Verifying changes and keeping the database consistent"
        }
        return "\(progress.completedItems) of \(progress.totalItems) checked · \(progress.matchedItems) matches"
    }

    @ViewBuilder private var libraryContent: some View {
        if section == 0 && tracks.isEmpty {
            libraryEmptyState("No songs found", message: searchText.isEmpty ? "Music already on this iPod will appear here. Add a folder from Files to get started." : "Try another search.", symbol: "music.note")
        } else if section == 1 && albums.isEmpty {
            libraryEmptyState("No albums found", message: searchText.isEmpty ? "Albums are created automatically from the music on your iPod." : "Try another search.", symbol: "square.stack")
        } else if section == 2 && artists.isEmpty {
            libraryEmptyState("No artists found", message: searchText.isEmpty ? "Artists will appear when the iPod contains music with artist metadata." : "Try another search.", symbol: "person")
        } else if section == 3 && playlists.isEmpty {
            libraryEmptyState("No playlists yet", message: "Create and manage playlists from Library Tools.", symbol: "music.note.list")
        } else if section == 1 {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(model: model, albumID: album.id) } label: {
                        libraryRow(
                            title: album.title.isEmpty ? "Unknown Album" : album.title,
                            subtitle: album.artist.isEmpty ? "Unknown Artist" : album.artist,
                            artwork: album.tracks.first(where: { $0.artworkData != nil })?.artworkData,
                            symbol: "opticaldisc.fill"
                        )
                    }.buttonStyle(.plain)
                    if album.id != albums.last?.id { Divider().padding(.leading, 62) }
                }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            LazyVStack(spacing: 0) {
                if section == 0 {
                    ForEach(tracks) { track in
                        NavigationLink(destination: TrackDetailView(model: model, trackID: track.id)) {
                            libraryTrackRow(track)
                        }
                        .buttonStyle(.plain)
                    }
                } else if section == 2 {
                    ForEach(artists, id: \.self) { artist in
                        let sample = model.libraryTracks.first { $0.artist == artist }
                        NavigationLink(destination: ArtistDetailView(model: model, artist: artist)) {
                            libraryRow(
                                title: artist,
                                subtitle: "\(model.libraryTracks.filter { $0.artist == artist }.count) songs",
                                artwork: sample?.artworkData,
                                symbol: "person.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(playlists, id: \.index) { item in
                        let index = item.index
                        let playlist = item.playlist
                        NavigationLink(destination: PlaylistDetailView(model: model, playlistIndex: index)) {
                            playlistRow(playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func libraryTrackRow(_ track: ClassicTrack) -> some View {
        libraryRow(title: track.title, subtitle: track.artist, artwork: track.artworkData, symbol: "music.note")
    }

    private func libraryEmptyState(_ title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func playlistRow(_ playlist: ClassicPlaylist) -> some View {
        let tracksByID = Dictionary(uniqueKeysWithValues: model.libraryTracks.map { ($0.id, $0) })
        let playlistTracks = playlist.trackIDs.compactMap { tracksByID[$0] }
        return HStack(spacing: 12) {
            PlaylistArtworkView(tracks: playlistTracks).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name.isEmpty ? "Untitled Playlist" : playlist.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text("\(playlistTracks.count) songs").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func libraryRow(title: String, subtitle: String, artwork: Data?, symbol: String) -> some View {
        HStack(spacing: 12) {
            PodBridgeArtworkView(data: artwork, symbol: symbol).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "Unknown" : title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle.isEmpty ? "Unknown Artist" : subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }.padding(.vertical, 8).contentShape(Rectangle())
    }
}

private struct TrackDetailView: View {
    @ObservedObject var model: MusicTransferViewModel
    let trackID: UInt32
    @State private var editingMetadata = false
    @State private var choosingArtwork = false
    @State private var showingArtworkSearch = false
    @State private var confirmingDeletion = false

    private var track: ClassicTrack? { model.libraryTracks.first { $0.id == trackID } }

    var body: some View {
        Group {
            if let track {
                List {
                    Section {
                        HStack(spacing: 16) {
                            PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                                .frame(width: 92, height: 92)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.title.isEmpty ? "Unknown Song" : track.title).font(.title3.weight(.semibold))
                                Text(track.artist.isEmpty ? "Unknown Artist" : track.artist).foregroundStyle(.secondary)
                                Text(track.album.isEmpty ? "Unknown Album" : track.album).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Details") {
                        PodBridgeLabeledContent("Album") { Text(track.album.isEmpty ? "—" : track.album) }
                        PodBridgeLabeledContent("Artist") { Text(track.artist.isEmpty ? "—" : track.artist) }
                        PodBridgeLabeledContent("Album Artist") { Text(track.albumArtist.isEmpty ? "—" : track.albumArtist) }
                        PodBridgeLabeledContent("Genre") { Text(track.genre.isEmpty ? "—" : track.genre) }
                        PodBridgeLabeledContent("Track") { Text(track.trackNumber == 0 ? "—" : String(track.trackNumber)) }
                    }
                    Section("Artwork") {
                        Button("Choose artwork from Files", systemImage: "folder") { choosingArtwork = true }
                        Button("Find artwork online", systemImage: "photo.badge.magnifyingglass") { showingArtworkSearch = true }
                    }
                    if let album = model.libraryAlbums.first(where: { $0.tracks.contains(where: { $0.id == track.id }) }) {
                        Section {
                            NavigationLink(destination: AlbumDetailView(model: model, albumID: album.id)) {
                                Text("Open Album")
                            }
                        }
                    }
                    Section {
                        Button("Delete from iPod", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    }
                }
                .navigationTitle("Song")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editingMetadata = true }
                    }
                }
                .sheet(isPresented: $editingMetadata) {
                    TrackMetadataEditor(track: track) { update in
                        model.editTrackMetadata(track, update: update)
                    }
                }
                .sheet(isPresented: $showingArtworkSearch) {
                    OnlineArtworkPicker(target: .track(track)) { artwork in
                        model.setTrackArtwork(track, artwork: artwork)
                    }
                }
                .confirmationDialog(
                    "Delete this song from iPod?",
                    isPresented: $confirmingDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete \(track.title)", role: .destructive) {
                        model.deleteTrackPermanently(track)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the audio file and its library entry. Approximately \(ByteCountFormatter.string(fromByteCount: Int64(track.byteCount), countStyle: .file)) will be freed.")
                }
                .fileImporter(
                    isPresented: $choosingArtwork,
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { model.setTrackArtwork(track, imageURL: url) }
                    case .failure(let error):
                        model.errorMessage = error.localizedDescription
                    }
                }
            } else {
                PodBridgeUnavailableView("Song no longer exists", systemImage: "music.note")
            }
        }
    }
}

private struct ArtistDetailView: View {
    @ObservedObject var model: MusicTransferViewModel
    let artist: String

    private var albums: [IPodAlbum] {
        model.libraryAlbums.filter { $0.artist == artist || $0.tracks.contains(where: { $0.artist == artist }) }
    }

    var body: some View {
        List {
            Section {
                Text("\(albums.count) \(albums.count == 1 ? "album" : "albums") · \(model.libraryTracks.filter { $0.artist == artist }.count) songs")
                    .foregroundStyle(.secondary)
            }
            Section("Albums") {
                ForEach(albums) { album in
                    NavigationLink(destination: AlbumDetailView(model: model, albumID: album.id)) {
                        HStack(spacing: 12) {
                            PodBridgeArtworkView(data: album.tracks.first(where: { $0.artworkData != nil })?.artworkData, symbol: "opticaldisc.fill")
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.title.isEmpty ? "Unknown Album" : album.title).foregroundStyle(.primary)
                                Text("\(album.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let playlistIndex: Int
    @State private var renaming = false
    @State private var confirmingDeletion = false
    @State private var editingSongs = false

    private var playlist: ClassicPlaylist? {
        model.libraryPlaylists.indices.contains(playlistIndex) ? model.libraryPlaylists[playlistIndex] : nil
    }

    private var tracks: [ClassicTrack] {
        guard let playlist else { return [] }
        let tracksByID = Dictionary(uniqueKeysWithValues: model.libraryTracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { tracksByID[$0] }
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    Section {
                        Text("\(tracks.count) songs").foregroundStyle(.secondary)
                    }
                    Section("Songs") {
                        ForEach(tracks) { track in
                            NavigationLink(destination: TrackDetailView(model: model, trackID: track.id)) {
                                HStack(spacing: 12) {
                                    PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).foregroundStyle(.primary)
                                        Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Delete playlist", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    }
                }
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Edit") {
                            Button("Rename Playlist", systemImage: "pencil") { renaming = true }
                            Button("Edit Songs", systemImage: "music.note.list") { editingSongs = true }
                        }
                    }
                }
                .sheet(isPresented: $renaming) {
                    PlaylistRenameEditor(
                        target: PlaylistRenameTarget(index: playlistIndex, playlist: playlist)
                    ) { name in
                        model.renamePlaylist(at: playlistIndex, to: name)
                    }
                }
                .sheet(isPresented: $editingSongs) {
                    PlaylistMembersEditor(tracks: model.libraryTracks, playlist: playlist) { trackIDs in
                        model.replacePlaylistMembers(at: playlistIndex, trackIDs: trackIDs)
                        editingSongs = false
                        dismiss()
                    }
                }
                .confirmationDialog(
                    "Delete this playlist?",
                    isPresented: $confirmingDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete playlist only", role: .destructive) {
                        model.deletePlaylist(at: playlistIndex, includingSongs: false)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Its songs will remain on the iPod.")
                }
            } else {
                PodBridgeUnavailableView("Playlist no longer exists", systemImage: "music.note.list")
            }
        }
    }
}

private struct PlaylistMembersEditor: View {
    @Environment(\.dismiss) private var dismiss
    let tracks: [ClassicTrack]
    let playlist: ClassicPlaylist
    let save: ([UInt32]) -> Void
    @State private var selectedIDs: [UInt32]
    @State private var searchText = ""
    @State private var confirmingEmptyPlaylist = false

    init(tracks: [ClassicTrack], playlist: ClassicPlaylist, save: @escaping ([UInt32]) -> Void) {
        self.tracks = tracks
        self.playlist = playlist
        self.save = save
        _selectedIDs = State(initialValue: playlist.trackIDs)
    }

    private var tracksByID: [UInt32: ClassicTrack] { Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }) }
    private var selectedTracks: [ClassicTrack] { selectedIDs.compactMap { tracksByID[$0] } }
    private var availableTracks: [ClassicTrack] {
        let selected = Set(selectedIDs)
        return tracks.filter {
            !selected.contains($0.id) && (searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || $0.album.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section("Playlist Order") {
                    ForEach(selectedTracks) { track in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { selectedIDs.removeAll { $0 == track.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(track.title) from playlist")
                        }
                    }
                    .onMove { selectedIDs.move(fromOffsets: $0, toOffset: $1) }
                }
                if !availableTracks.isEmpty {
                    Section("Add Songs") {
                        ForEach(availableTracks) { track in
                            Button {
                                selectedIDs.append(track.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).foregroundStyle(.primary)
                                        Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                }
                            }
                            .accessibilityLabel("Add \(track.title) to playlist")
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Add a song")
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if selectedIDs.isEmpty { confirmingEmptyPlaylist = true }
                        else { save(selectedIDs) }
                    }
                    .disabled(selectedIDs == playlist.trackIDs)
                }
            }
            .confirmationDialog("Save an empty playlist?", isPresented: $confirmingEmptyPlaylist, titleVisibility: .visible) {
                Button("Keep Empty Playlist") { save([]) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The playlist will remain on the iPod without songs. You can also cancel and delete the playlist from its page.")
            }
        }
    }
}

private struct PodBridgeArtworkView: View {
    let data: Data?
    let symbol: String

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.12), Color(white: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct PlaylistArtworkView: View {
    let tracks: [ClassicTrack]

    var body: some View {
        let covers = Array(tracks.prefix(4))
        ZStack {
            if covers.isEmpty {
                PodBridgeArtworkView(data: nil, symbol: "music.note.list")
            } else {
                GeometryReader { proxy in
                    let side = proxy.size.width / 2
                    ForEach(Array(covers.enumerated()), id: \.offset) { index, track in
                        PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                            .frame(width: side, height: side)
                            .offset(x: index % 2 == 0 ? 0 : side, y: index < 2 ? 0 : side)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PodBridgeLibraryToolsView: View {
    @ObservedObject var model: MusicTransferViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                NavigationLink { LibraryDoctorView(model: model) } label: {
                    tool("Library Doctor", "Find and fix metadata, artwork and duplicate tracks", "stethoscope", .mint)
                }
                Button { model.findMissingArtwork() } label: {
                    tool("Fix Missing Artwork", "Find and apply covers for \(model.missingArtworkTrackCount) tracks", "photo", .pink)
                }
                .disabled(model.automaticArtworkCandidateCount == 0 || model.isManagingLibrary)
                NavigationLink { DuplicateReviewView(model: model) } label: {
                    tool("Duplicates", "Review possible duplicate tracks", "doc.on.doc", .blue)
                }
                NavigationLink { MetadataIssuesView(model: model) } label: {
                    tool("Fix Metadata", "Review incomplete artist, album and genre fields", "tag.fill", .purple)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Library Tools")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tool(_ title: String, _ subtitle: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct LibraryDoctorView: View {
    @ObservedObject var model: MusicTransferViewModel
    @State private var repairCompletion: LibraryRepairCompletion?

    private var duplicateGroups: [[ClassicTrack]] { duplicateTrackGroups(model.libraryTracks) }
    private var metadataIssues: [ClassicTrack] { metadataIssueTracks(model.libraryTracks) }
    private var brokenAlbums: Int { brokenAlbumGroups(model.libraryAlbums).count }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PodBridgeCelebrationMark(markSize: 56, height: 120)
                    .padding(.top, 8)
                VStack(spacing: 4) {
                    Text("Scan Complete").font(.title2.bold())
                    Text("\(model.libraryTracks.count) tracks analyzed").foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    doctorRow(duplicateGroups.count, "Possible duplicates", "doc.on.doc", .red)
                    Divider().padding(.leading, 52)
                    doctorRow(model.missingArtworkTrackCount, "Missing artwork", "photo", .orange)
                    Divider().padding(.leading, 52)
                    doctorRow(metadataIssues.count, "Metadata issues", "tag", .blue)
                    Divider().padding(.leading, 52)
                    doctorRow(brokenAlbums, "Broken album groups", "rectangle.stack", .purple)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                NavigationLink { LibraryIssueReviewView(model: model) } label: {
                    Text("Review Issues")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                if model.safeAlbumRepairCount > 0 || model.missingArtworkTrackCount > 0 {
                    Button {
                        model.fixAllSafeLibraryIssues()
                    } label: {
                        Label("Fix All Safe Issues", systemImage: "wand.and.stars")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isManagingLibrary)
                    Text("Repairs missing artwork and consistent album grouping only. Possible duplicates are never deleted automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Library Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.libraryRepairCompletion?.id) { _ in
            repairCompletion = model.libraryRepairCompletion
        }
        .alert("Library Updated", isPresented: Binding(
            get: { repairCompletion != nil },
            set: { if !$0 { repairCompletion = nil } }
        )) {
            Button("Done", role: .cancel) { repairCompletion = nil }
        } message: {
            if let repairCompletion {
                Text(repairSuccessMessage(repairCompletion))
            }
        }
    }

    private func doctorRow(_ count: Int, _ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color.opacity(0.14)).frame(width: 32, height: 32)
                .overlay(Image(systemName: icon).font(.caption.bold()).foregroundStyle(color))
            Text(count.formatted()).font(.headline.monospacedDigit()).fixedSize(horizontal: true, vertical: false)
            Text(title); Spacer()
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func repairSuccessMessage(_ completion: LibraryRepairCompletion) -> String {
        var parts: [String] = []
        if completion.repairedAlbumGroups > 0 {
            parts.append("Fixed \(completion.repairedAlbumGroups) album groups")
        }
        if completion.restoredEmbeddedArtwork > 0 {
            parts.append("restored \(completion.restoredEmbeddedArtwork) embedded covers")
        }
        if completion.addedOnlineArtwork > 0 {
            parts.append("found \(completion.addedOnlineArtwork) online covers")
        }
        return parts.isEmpty
            ? "No safe changes were needed. Possible duplicates were left untouched."
            : parts.joined(separator: ", ") + ". Possible duplicates were left untouched."
    }
}

private struct LibraryIssueReviewView: View {
    @ObservedObject var model: MusicTransferViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NavigationLink { DuplicateReviewView(model: model) } label: { issueCard("Possible Duplicates", "\(duplicateTrackGroups(model.libraryTracks).count) groups", "doc.on.doc", .red) }
                Button { model.findMissingArtwork() } label: { issueCard("Fix Missing Artwork", "\(model.missingArtworkTrackCount) tracks without an iPod cover", "photo", .orange) }
                    .disabled(model.automaticArtworkCandidateCount == 0 || model.isManagingLibrary)
                NavigationLink { MetadataIssuesView(model: model) } label: { issueCard("Metadata Issues", "\(metadataIssueTracks(model.libraryTracks).count) tracks", "tag", .blue) }
                NavigationLink { BrokenAlbumGroupsView(model: model) } label: { issueCard("Broken Album Groups", "\(brokenAlbumGroups(model.libraryAlbums).count) groups", "rectangle.stack", .purple) }
            }.padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review Issues")
    }
    private func issueCard(_ title: String, _ subtitle: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 42, height: 42).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading) { Text(title).font(.headline).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct BrokenAlbumGroupsView: View {
    @ObservedObject var model: MusicTransferViewModel
    private var groups: [[IPodAlbum]] { brokenAlbumGroups(model.libraryAlbums) }

    var body: some View {
        Group {
            if groups.isEmpty {
                PodBridgeUnavailableView(
                    "No Broken Album Groups",
                    systemImage: "checkmark.circle",
                    description: Text("Albums with the same title use consistent album artists.")
                )
            } else {
                List {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, albums in
                        Section(albums.first?.title.isEmpty == false ? albums.first!.title : "Unknown Album") {
                            ForEach(albums) { album in
                                NavigationLink(destination: AlbumDetailView(model: model, albumID: album.id)) {
                                    HStack(spacing: 12) {
                                        PodBridgeArtworkView(data: album.tracks.first(where: { $0.artworkData != nil })?.artworkData, symbol: "opticaldisc")
                                            .frame(width: 46, height: 46)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.artist.isEmpty ? "Unknown Album Artist" : album.artist)
                                            Text("\(album.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Broken Albums")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MetadataIssuesView: View {
    @ObservedObject var model: MusicTransferViewModel
    private var tracks: [ClassicTrack] { metadataIssueTracks(model.libraryTracks) }
    var body: some View {
        Group {
            if tracks.isEmpty && model.safeAlbumRepairCount == 0 {
                PodBridgeUnavailableView("No Metadata Issues", systemImage: "checkmark.circle", description: Text("PodBridge did not find incomplete core metadata."))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if model.safeAlbumRepairCount > 0 {
                            Button {
                                model.repairAlbumGrouping()
                            } label: {
                                Label("Fix All Safe Album Issues (\(model.safeAlbumRepairCount))", systemImage: "wand.and.stars")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isManagingLibrary)
                        }
                        LazyVStack(spacing: 0) {
                        ForEach(tracks) { track in
                            NavigationLink { MetadataIssueDetailView(model: model, trackID: track.id) } label: {
                                HStack(spacing: 12) {
                                    PodBridgeArtworkView(data: track.artworkData, symbol: "music.note").frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title.isEmpty ? "Missing title" : track.title).font(.headline).foregroundStyle(.primary)
                                        Text(track.artist.isEmpty ? "Missing artist" : track.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            if track.id != tracks.last?.id { Divider().padding(.leading, 74) }
                        }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
            }
        }.navigationTitle("Fix Metadata")
         .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MetadataIssueDetailView: View {
    @ObservedObject var model: MusicTransferViewModel
    let trackID: UInt32
    private var track: ClassicTrack? { model.libraryTracks.first { $0.id == trackID } }
    var body: some View {
        ScrollView {
            if let track {
                VStack(spacing: 16) {
                    PodBridgeArtworkView(data: track.artworkData, symbol: "music.note").frame(width: 92, height: 92).padding(.top, 8)
                    VStack(spacing: 3) { Text(track.title.isEmpty ? "Unknown Track" : track.title).font(.title3.bold()); Text(track.artist.isEmpty ? "Unknown Artist" : track.artist).foregroundStyle(.secondary) }
                    metadataCard(title: "Current", track: track, suggested: false)
                    metadataCard(title: "Suggested", track: track, suggested: true)

                }.padding(20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Fix Metadata")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Apply") {
                    if let track {
                        model.editTrackMetadata(track, update: .init(title: track.title, artist: track.artist, album: track.album, genre: track.genre, year: track.year, trackNumber: track.trackNumber, albumArtist: track.artist, compilation: track.compilation))
                    }
                }
                .disabled(track?.artist.isEmpty != false || track?.albumArtist.isEmpty != true)
            }
        }
    }
    private func metadataCard(title: String, track: ClassicTrack, suggested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 10)
            valueRow("Artist", track.artist)
            Divider(); valueRow("Album Artist", suggested && track.albumArtist.isEmpty ? track.artist : track.albumArtist)
            Divider(); valueRow("Album", track.album)
            Divider(); valueRow("Genre", track.genre)
        }.padding(14).background(suggested ? Color.green.opacity(0.10) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func valueRow(_ key: String, _ value: String) -> some View { HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "—" : value).lineLimit(1) }.font(.subheadline).padding(.vertical, 10) }
}

private struct DuplicateReviewView: View {
    @ObservedObject var model: MusicTransferViewModel
    private var groups: [[ClassicTrack]] { duplicateTrackGroups(model.libraryTracks) }
    var body: some View {
        Group {
            if groups.isEmpty {
                PodBridgeUnavailableView(
                    "No Duplicates Found",
                    systemImage: "checkmark.circle",
                    description: Text("No tracks share the same normalized artist, title, album, and album artist.")
                )
            } else {
                List(Array(groups.enumerated()), id: \.offset) { index, group in
                    NavigationLink(destination: DuplicateGroupView(model: model, groupKey: duplicateGroupKey(group.first))) {
                        HStack(spacing: 12) {
                            PodBridgeArtworkView(data: group.first?.artworkData, symbol: "doc.on.doc")
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.first?.title.isEmpty == false ? (group.first?.title ?? "") : "Unknown Song")
                                    .foregroundStyle(.primary)
                                Text(group.first?.artist.isEmpty == false ? group.first!.artist : "Unknown Artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(group.count) copies · review before deleting")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Duplicates")
    }
}

private struct DuplicateGroupView: View {
    @ObservedObject var model: MusicTransferViewModel
    let groupKey: String
    @State private var trackToDelete: ClassicTrack?

    private var tracks: [ClassicTrack] {
        model.libraryTracks.filter { duplicateGroupKey($0) == groupKey }
            .sorted { $0.byteCount > $1.byteCount }
    }

    var body: some View {
        Group {
            if tracks.count < 2 {
                PodBridgeUnavailableView(
                    "Duplicate group updated",
                    systemImage: "checkmark.circle",
                    description: Text("There are no longer multiple matching copies.")
                )
            } else {
                List {
                    Section {
                        Text("PodBridge matched these songs within the same album and album artist. Review the size, duration and artwork before deleting anything. Nothing is removed automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Copies") {
                        ForEach(tracks) { track in
                            HStack(spacing: 12) {
                                PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                                    .frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.album.isEmpty ? "Unknown Album" : track.album)
                                        .foregroundStyle(.primary)
                                    Text(duplicateTechnicalSummary(track))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(duplicateMetadataSummary(track))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("Delete this copy", systemImage: "trash", role: .destructive) {
                                        trackToDelete = track
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, height: 36)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Review Copies")
                .navigationBarTitleDisplayMode(.inline)
                .confirmationDialog(
                    "Delete this copy from iPod?",
                    isPresented: Binding(get: { trackToDelete != nil }, set: { if !$0 { trackToDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    if let track = trackToDelete {
                        Button("Delete \(track.title)", role: .destructive) {
                            trackToDelete = nil
                            model.deleteTrackPermanently(track)
                        }
                    }
                    Button("Cancel", role: .cancel) { trackToDelete = nil }
                } message: {
                    Text("The selected audio file and its iPod library entry will be removed. The other copies will remain.")
                }
            }
        }
    }
}

private func metadataIssueTracks(_ tracks: [ClassicTrack]) -> [ClassicTrack] {
    tracks.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func duplicateTrackGroups(_ tracks: [ClassicTrack]) -> [[ClassicTrack]] {
    Dictionary(grouping: tracks) { duplicateGroupKey($0) }
        .values
        .filter { $0.count > 1 }
        .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
}

private func brokenAlbumGroups(_ albums: [IPodAlbum]) -> [[IPodAlbum]] {
    return Dictionary(grouping: albums.filter { !$0.title.isEmpty }) { normalizedLibraryText($0.title) }
        .values
        .filter { albums in
            guard albums.count > 1 else { return false }
            let artists = albums.map { normalizedLibraryText($0.artist) }.filter { !$0.isEmpty }
            guard Set(artists).count > 1 else { return false }
            return artists.contains { left in
                artists.contains { right in left != right && (left.contains(right) || right.contains(left)) }
            }
        }
        .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
}

private func duplicateGroupKey(_ track: ClassicTrack?) -> String {
    guard let track else { return "" }
    let albumArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
    return [track.artist, track.title, track.album, albumArtist]
        .map(normalizedLibraryText)
        .joined(separator: "\u{0}")
}

private func normalizedLibraryText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
}

private func duplicateTechnicalSummary(_ track: ClassicTrack) -> String {
    let minutes = track.durationMS / 60_000
    let seconds = (track.durationMS / 1_000) % 60
    let duration = String(format: "%u:%02u", minutes, seconds)
    let size = ByteCountFormatter.string(fromByteCount: Int64(track.byteCount), countStyle: .file)
    let bitrate = track.bitrate == 0 ? nil : "\(track.bitrate) kbps"
    return ([duration, bitrate, size].compactMap { $0 }).joined(separator: " · ")
}

private func duplicateMetadataSummary(_ track: ClassicTrack) -> String {
    let format = track.ipodPath.split(separator: ".").last.map { String($0).uppercased() }
        ?? track.fileType
    let number = track.trackNumber == 0 ? nil : "Track \(track.trackNumber)"
    let genre = track.genre.isEmpty ? nil : track.genre
    return ([format, number, genre].compactMap { $0 }).joined(separator: " · ")
}


private struct PodBridgeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let openDiagnostics: () -> Void

    var body: some View {
        NavigationView {
            List {
                Section("General") {
                    HStack {
                        Label("Appearance", systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Text("System").foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        SupportedFormatsView()
                    } label: {
                        Label("File Formats", systemImage: "waveform")
                    }
                }

                Section("Diagnostics") {
                    Button {
                        dismiss()
                        openDiagnostics()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                            .foregroundStyle(.primary)
                    }
                    Button {
                        PersistentLogStore.shared.flush()
                    } label: {
                        Label("Export Logs", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                    }
                }

                Section("About") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PodBridge")
                            Text("Music for a more iconic era.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SupportedFormatsView: View {
    var body: some View {
        List {
            Label("AAC / M4A", systemImage: "checkmark.circle.fill")
            Label("ALAC", systemImage: "checkmark.circle.fill")
            Label("MP3", systemImage: "checkmark.circle.fill")
            Label("WAV", systemImage: "checkmark.circle.fill")
            Label("AIFF", systemImage: "checkmark.circle.fill")
        }
        .foregroundStyle(.primary)
        .navigationTitle("File Formats")
    }
}

private struct TransferProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel

    private var currentTrackName: String {
        guard model.files.indices.contains(model.copiedCount) else { return "Finishing iPod library…" }
        return model.files[model.copiedCount].sourceURL.deletingPathExtension().lastPathComponent
    }

    private var currentTrackContext: String? {
        guard model.files.indices.contains(model.copiedCount) else { return nil }
        let parent = model.files[model.copiedCount].sourceURL.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? nil : parent
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Adding Music")
                        .font(.title2.weight(.bold))
                        .padding(.top, 22)

                    PodBridgeIPodClassicArtwork()
                        .frame(width: 92, height: 160)
                        .padding(.top, 26)

                    VStack(spacing: 12) {
                        Text("\(model.copiedCount) of \(model.files.count) songs")
                            .font(.headline.weight(.semibold))

                        ProgressView(value: model.copyProgress)
                            .progressViewStyle(.linear)
                            .tint(.blue)

                        VStack(spacing: 3) {
                            Text(model.files.indices.contains(model.copiedCount) ? "Adding “\(currentTrackName)”" : currentTrackName)
                                .font(.subheadline)
                                .lineLimit(1)
                            if let currentTrackContext {
                                Text(currentTrackContext)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, 24)

                    Label {
                        Text("Keep PodBridge open and do not disconnect your iPod until the transfer finishes.")
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 34)

                    Button("Cancel", role: .destructive) {
                        model.cancelCopy()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .background(Color(.systemGroupedBackground))
            .interactiveDismissDisabled(model.isCopying)
            .onChange(of: model.isCopying) { copying in
                if !copying { dismiss() }
            }
        }
    }
}

private struct TransferSuccessView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let completion: TransferCompletion
    @State private var showingLibrary = false

    private var summaryRows: [(String, String, Int)] {
        if !completion.playlists.isEmpty {
            return completion.playlists.map { ($0.name, "Playlist", $0.trackCount) }
        }
        guard completion.addedTracks > 0 else { return [] }
        return [("Music", completion.destinationName, completion.addedTracks)]
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    successMark
                        .padding(.top, 30)

                    VStack(spacing: 7) {
                        Text("Music Added")
                            .font(.largeTitle.bold())
                        Text("\(completion.addedTracks) songs were added\nto \(completion.destinationName).")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 6)

                    if !summaryRows.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(summaryRows.enumerated()), id: \.offset) { index, row in
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color(.secondarySystemFill))
                                        .frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.0).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(row.1) · \(row.2) song\(row.2 == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                                .padding(.vertical, 10)
                                if index < summaryRows.count - 1 { Divider().padding(.leading, 56) }
                            }
                        }
                        .padding(.horizontal, 14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 20)
                        .padding(.top, 28)
                    }

                    VStack(spacing: 10) {
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        Button("View in Library") { showingLibrary = true }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 28)
                }
            }
            .background(Color(.systemGroupedBackground))
            .sheet(isPresented: $showingLibrary) { PodBridgeLibraryView(model: model) }
        }
    }

    private var successMark: some View {
        PodBridgeCelebrationMark(markSize: 72, height: 142)
    }
}

private struct PodBridgeCelebrationMark: View {
    let markSize: CGFloat
    let height: CGFloat

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: markSize, height: markSize)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: markSize * 0.44, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .green.opacity(0.25), radius: 12, y: 5)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Success")
    }
}
