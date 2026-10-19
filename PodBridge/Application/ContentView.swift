// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    private enum FolderKind { case source, destination }

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MusicTransferViewModel()
    @State private var choosingFolder = false
    @State private var folderKind: FolderKind = .source
    @State private var showingDiagnostics = false
    @State private var showingSettings = false
    @State private var openDiagnosticsAfterSettings = false
    @State private var confirmingRestore = false
    @State private var showingLibrary = false
    @State private var showingALACarte = false
    @State private var showingRockboxTransfer = false
    @State private var showingTransferSuccess: TransferCompletion?
    @State private var showingTransferProgress = false
    @State private var showingSignatureIDPrompt = false
    @State private var showingSignatureIDHelp = false
    @State private var showingSignatureRecovery = false
    @State private var showingConnectionGuide = false
    @State private var showingDiskModeGuide = false
    @AppStorage("PodBridge.skipConnectionOnboarding") private var skipConnectionOnboarding = false
    @State private var showingPreflight = false
    @State private var showingDeviceModelChooser = false
    @State private var signatureID = ""
    @State private var showingImportReview = false
    @State private var showingErrorAlert = false
    @State private var presentedErrorMessage = ""

    var body: some View {
        dialogContent
            .onChange(of: scenePhase) { _, phase in
                AppLogger.app("Scene phase=\(String(describing: phase))", level: .info)
                if phase != .active {
                    PersistentLogStore.shared.flush()
                    model.stopLocalSignatureRecovery()
                }
            }
            .onChange(of: model.transferCompletion?.id) {
                guard !showingALACarte else { return }
                guard let completion = model.transferCompletion else { return }
                showingTransferSuccess = completion
            }
            .onChange(of: model.shouldChooseDeviceProfile) { _, shouldShow in
                guard shouldShow else { return }
                model.acknowledgeDeviceProfilePrompt()
                showingDeviceModelChooser = true
            }
            .onChange(of: model.errorMessage) { _, message in
                guard let message else { return }
                presentedErrorMessage = message
                showingErrorAlert = true
            }
            .onChange(of: model.isScanning) { _, scanning in
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
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
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

}

private extension ContentView {
    private var primaryPresentationContent: some View {
        rootContent
        .background {
            DebugShakeDetector {
                openDiagnostics(source: "shake")
            }
            .frame(width: 0, height: 0)
        }
        .sheet(isPresented: $showingDiagnostics) {
#if DEBUG || PODBRIDGE_DEMO
            DiagnosticsDrawerView(
                isEmulatingIPod: model.isEmulatingIPod,
                emulateIPod: { model.emulateConnectedIPod($0) },
                disconnectEmulatedIPod: { model.disconnectDestination() },
                canRemoveSignatureID: model.destinationFolder != nil && !model.destinationNeedsFirewireID,
                removeSignatureID: { try model.removeSignatureIDForRecoveryTest() }
            )
#else
            DiagnosticsDrawerView(
                canRemoveSignatureID: model.destinationFolder != nil && !model.destinationNeedsFirewireID,
                removeSignatureID: { try model.removeSignatureIDForRecoveryTest() }
            )
#endif
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            guard openDiagnosticsAfterSettings else { return }
            openDiagnosticsAfterSettings = false
            openDiagnostics(source: "settings")
        }) {
            PodBridgeSettingsView {
                openDiagnosticsAfterSettings = true
            }
        }
        .sheet(isPresented: $showingLibrary) {
            PodBridgeLibraryView(model: model)
        }
        .sheet(isPresented: $showingRockboxTransfer) {
            RockboxTransferView(model: model)
        }
        .sheet(isPresented: $showingImportReview) {
            ImportReviewView(model: model) {
                showingImportReview = false
                Task { @MainActor in
                    await Task.yield()
                    showingPreflight = true
                }
            }
        }
        .sheet(isPresented: $showingPreflight) {
            TransferPreflightView(model: model) {
                showingPreflight = false
                Task { @MainActor in
                    await Task.yield()
                    showingTransferProgress = true
                    model.startCopy()
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
        .sheet(isPresented: $showingSignatureRecovery) {
            SignatureRecoveryView(
                model: model,
                enterManually: {
                    showingSignatureRecovery = false
                    Task { @MainActor in
                        await Task.yield()
                        signatureID = ""
                        showingSignatureIDPrompt = true
                    }
                },
                showComputerHelp: {
                    showingSignatureRecovery = false
                    Task { @MainActor in
                        await Task.yield()
                        showingSignatureIDHelp = true
                    }
                }
            )
        }
        .sheet(isPresented: $showingConnectionGuide) {
            ConnectionGuideView {
                Task { @MainActor in
                    await Task.yield()
                    chooseFolder(.destination)
                }
            }
        }
        .sheet(isPresented: $showingDiskModeGuide) {
            DiskModeGuideView {
                Task { @MainActor in
                    await Task.yield()
                    chooseFolder(.destination)
                }
            }
        }
    }

    private var importerContent: some View {
        secondaryPresentationContent
        .fileImporter(
            isPresented: $choosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderResult(result, destination: folderKind == .destination)
        }
    }

    private var alertContent: some View {
        importerContent
        .alert("PodBridge", isPresented: $showingErrorAlert) {
            Button("Diagnostics") {
                showingErrorAlert = false
                model.errorMessage = nil
                Task { @MainActor in
                    await Task.yield()
                    openDiagnostics(source: "error")
                }
            }
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
            Text(
                "Paste the 16-character ID from your Mac. PodBridge will save it to this iPod, "
                    + "remember it on your iPhone, and verify the music database."
            )
        }
    }

    private var dialogContent: some View {
        alertContent
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
            Text(
                "Only iPod Classic 7th gen 160 GB has been tested on real hardware. "
                    + "Every other model is experimental: make a full backup and begin with one track."
            )
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
            Text(
                "PodBridge will first save the current database, restore the oldest verified backup, "
                    + "and remove only music files added after that backup."
            )
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        PodBridgeHomeView(
            model: model,
            actions: PodBridgeHomeActions(
                connectToIPod: connectToIPod,
                showConnectionGuide: { showingConnectionGuide = true },
                showDiskModeGuide: { showingDiskModeGuide = true },
                chooseSource: { chooseFolder(.source) },
                showRockboxTransfer: { showingRockboxTransfer = true },
                showALACarte: { showingALACarte = true },
                showLibrary: { showingLibrary = true },
                showDeviceModelChooser: { showingDeviceModelChooser = true },
                showSignatureRecovery: { showingSignatureRecovery = true },
                showImportReview: { showingImportReview = true }
            )
        )
    }

}

private extension ContentView {
    private var signatureIDIsValid: Bool {
        let value = signatureID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: [.anchored, .caseInsensitive])
        return value.count == 16 && value.allSatisfy(\.isHexDigit)
    }

    private func handleFolderResult(
        _ result: Result<[URL], Error>,
        destination: Bool
    ) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else {
                AppLogger.ui("Folder picker returned no selection", level: .info)
                return
            }
            AppLogger.ui("Folder selected kind=\(destination ? "destination" : "source")", level: .info)
            if destination {
                model.selectDestination(url)
            } else {
                model.selectSource(url)
            }
        case let .failure(error):
            model.errorMessage = error.localizedDescription
            AppLogger.ui("Folder picker failed error=\(error.localizedDescription)", level: .error)
        }
    }

    private func chooseFolder(_ kind: FolderKind) {
        folderKind = kind
        AppLogger.ui("Folder picker requested kind=\(kind == .destination ? "destination" : "source")", level: .info)
        choosingFolder = true
    }

    private func connectToIPod() {
        if skipConnectionOnboarding {
            chooseFolder(.destination)
        } else {
            showingConnectionGuide = true
        }
    }

    private func openDiagnostics(source: String) {
        AppLogger.ui("Diagnostics opened source=\(source)", level: .info)
        showingDiagnostics = true
    }

}

#Preview {
    ContentView()
}
