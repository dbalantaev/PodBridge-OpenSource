// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI

/// Renders the connected and disconnected home states.
///
/// Navigation and modal presentation remain owned by `ContentView`; this view
/// receives only the actions exposed by the home surface.
struct PodBridgeHomeView: View {
    @ObservedObject var model: MusicTransferViewModel
    let actions: PodBridgeHomeActions

    @ViewBuilder
    var body: some View {
        if model.destinationFolder == nil {
            disconnectedHome
        } else {
            connectedHome
        }
    }

    private var disconnectedHome: some View {
        VStack(spacing: 0) {
            Button(action: actions.connectToIPod) {
                VStack(spacing: 0) {
                    PodBridgeIPodClassicArtwork(showsCable: true)
                        .frame(height: 232)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect your iPod")
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            Text(connectionLocationText)
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
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect your iPod")
            .accessibilityHint(connectionAccessibilityHint)
            .padding(.top, 10)

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "Works with supported iPod classic, Video and nano models. "
                        + "Changes only your music library, never firmware.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Learn how to connect", action: actions.showConnectionGuide)
                    .font(.caption.weight(.semibold))
                Button("iPod doesn’t appear in Files?", action: actions.showDiskModeGuide)
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
            deviceCard.padding(.top, 8)

#if DEBUG || PODBRIDGE_DEMO
            if model.isEmulatingIPod {
                HStack {
                    Label("Demo mode · no physical iPod is changed", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Exit Demo") { model.disconnectDestination() }
                        .font(.caption.weight(.semibold))
                        .disabled(model.isCopying || model.isManagingLibrary || model.isRestoring)
                }
                .padding(.horizontal, 4)
            }
#endif

            homeAction(
                title: "Add Music",
                subtitle: addMusicSubtitle,
                icon: "music.note",
                tint: .blue,
                action: actions.chooseSource
            )
                .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID || model.isCopying)

            homeAction(
                title: "Rockbox Files",
                subtitle: "Copy music to a folder or install a theme",
                icon: "folder.badge.plus",
                tint: .orange,
                action: actions.showRockboxTransfer
            )
            .disabled(model.isCopying || model.isManagingLibrary || model.isRestoring)

#if PODBRIDGE_ALACARTE
            homeAction(
                title: "ALACarte",
                subtitle: "Import music from your server",
                icon: "music.note",
                tint: .pink,
                action: actions.showALACarte
            )
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID || model.isCopying)
#endif

            homeAction(
                title: "Your Library",
                subtitle: librarySubtitle,
                icon: "books.vertical.fill",
                tint: .purple,
                action: actions.showLibrary
            )
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID || model.isCopying)

            if model.destinationDeviceProfile == nil {
                setupCard
            } else if model.destinationNeedsFirewireID {
                signatureCard
            }
            if model.destinationDiskUseStatus == .disabled { diskUseCard }
            if !model.files.isEmpty && !model.isCopying { readyToTransferCard }

            Label(
                "Keep PodBridge open while transferring music. It does not distribute music files.",
                systemImage: "lightbulb.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

}

private extension PodBridgeHomeView {
    private var deviceCard: some View {
        HStack(spacing: 18) {
            PodBridgeIPodDeviceArtwork(profile: model.destinationDeviceProfile)
                .frame(width: 66, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.isEmulatingIPod ? "Demo iPod" : (model.destinationFolder?.lastPathComponent ?? "iPod"))
                    .font(.headline)
                    .lineLimit(1)
                deviceDescription
                if let fraction = model.storageUsedFraction {
                    ProgressView(value: fraction).padding(.top, 6)
                }
                storageDescription
            }
            Spacer(minLength: 0)
            Button(action: actions.showDeviceModelChooser) {
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
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var deviceDescription: some View {
        HStack(spacing: 6) {
            Text(model.destinationDeviceProfile?.shortTitle ?? "iPod detected")
#if DEBUG || PODBRIDGE_DEMO
            if model.isEmulatingIPod {
                Text("DEMO")
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
    }

    @ViewBuilder
    private var storageDescription: some View {
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

    private func homeAction(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
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
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish iPod setup", systemImage: "ipod").font(.headline)
            Text("Choose the exact iPod model before PodBridge writes to its library.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose iPod Model", action: actions.showDeviceModelChooser)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }

    private var signatureCard: some View {
#if targetEnvironment(macCatalyst)
        EmptyView()
#else
        VStack(alignment: .leading, spacing: 10) {
            Label("Signature ID required", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(
                "PodBridge checked the available Device files but could not find this iPod’s 16-digit signing ID. "
                    + "iOS does not expose the USB serial number, so it must be entered once."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Recover Signature ID", action: actions.showSignatureRecovery)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
#endif
    }

    private var diskUseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Make future connections easier", systemImage: "externaldrive.badge.checkmark")
                .font(.headline)
            Text(
                "This iPod’s disk-use setting is off. PodBridge can enable it so you usually won’t need Disk Mode "
                    + "next time. A copy of the original settings is saved first."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button {
                model.enablePersistentDiskUse()
            } label: {
                if model.isUpdatingDiskUse {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Enable Disk Use").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isUpdatingDiskUse || model.isCopying)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
    }

    private var readyToTransferCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to add").font(.headline)
                    Text("\(model.files.count) songs · \(model.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change", action: actions.chooseSource).font(.caption.weight(.semibold))
            }
            Button(action: actions.showImportReview) {
                Text("Review \(model.files.count) Songs")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID)
        }
        .padding(16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var addMusicSubtitle: String {
#if targetEnvironment(macCatalyst)
        "Choose a music folder on your Mac"
#else
        "Choose a music folder in Files"
#endif
    }

    private var connectionLocationText: String {
#if targetEnvironment(macCatalyst)
        "Choose your mounted iPod in Finder"
#else
        "Choose your connected iPod in Files"
#endif
    }

    private var connectionAccessibilityHint: String {
#if targetEnvironment(macCatalyst)
        "Opens the folder picker to choose the mounted iPod"
#else
        "Opens Files to choose the connected iPod"
#endif
    }

    private var librarySubtitle: String {
        let albumCount = model.libraryAlbums.count
        return "\(model.libraryTracks.count) songs · \(albumCount) \(albumCount == 1 ? "album" : "albums")"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
