// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct RockboxTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    @State private var musicSource: URL?
    @State private var musicDestination: URL?
    @State private var themeSource: URL?
    @State private var choosingMusicSource = false
    @State private var choosingMusicDestination = false
    @State private var choosingTheme = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Rockbox reads music directly from the iPod filesystem. Choose any folder inside the iPod volume, such as Music, and PodBridge will copy files there without changing the Apple music database.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Music") {
                    pickerRow(
                        title: "Music source",
                        value: musicSource?.lastPathComponent ?? "Choose a folder in Files"
                    ) { choosingMusicSource = true }
                    pickerRow(
                        title: "iPod destination",
                        value: musicDestination?.lastPathComponent ?? "Choose a folder inside this iPod"
                    ) { choosingMusicDestination = true }
                    if model.isRockboxCopying {
                        ProgressView(value: progress)
                        Text("Copied \(model.rockboxCopiedCount) files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Stop copying", role: .destructive) { model.cancelRockboxCopy() }
                    } else {
                        Button("Copy Music for Rockbox") {
                            guard let musicSource, let musicDestination else { return }
                            model.copyMusicForRockbox(from: musicSource, to: musicDestination)
                        }
                        .disabled(musicSource == nil || musicDestination == nil)
                    }
                }

                Section("Theme") {
                    Text("Choose a theme file or a folder from your iPhone. Its contents are copied to the hidden .rockbox/themes folder on the iPod.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    pickerRow(
                        title: "Theme from Files",
                        value: themeSource?.lastPathComponent ?? "Choose theme file or folder"
                    ) { choosingTheme = true }
                    Button("Install Rockbox Theme") {
                        guard let themeSource else { return }
                        model.installRockboxTheme(from: themeSource)
                    }
                    .disabled(themeSource == nil || model.isRockboxCopying)
                }

                if let message = model.resultMessage {
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Rockbox")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $choosingMusicSource, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { musicSource = url }
            }
            .fileImporter(isPresented: $choosingMusicDestination, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { musicDestination = url }
            }
            .fileImporter(isPresented: $choosingTheme, allowedContentTypes: [.item]) { result in
                if case let .success(url) = result { themeSource = url }
            }
        }
    }

    private var progress: Double {
        guard model.rockboxTotalCount > 0 else { return 0 }
        return min(1, Double(model.rockboxCopiedCount) / Double(model.rockboxTotalCount))
    }

    private func pickerRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Choose", action: action)
        }
    }
}

struct ConnectionGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("PodBridge.skipConnectionOnboarding") private var skipConnectionOnboarding = false
    @State private var page = 0

    let onContinue: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TabView(selection: $page) {
                    prepareIPodPage.tag(0)
                    connectIPodPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Toggle("Don’t show this again", isOn: $skipConnectionOnboarding)
                    .font(.footnote)
                    .padding(.horizontal, 22)

                Button {
                    dismiss()
                    onContinue()
                } label: {
                    Text(page == 0 ? "Choose iPod in Files" : "I’m in Disk Mode — Choose iPod")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 22)
                if page == 0 {
                    Button("iPod doesn’t appear? Use Disk Mode") {
                        withAnimation { page = 1 }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle("Get started")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var prepareIPodPage: some View {
        guidePage(title: "Connect directly", symbol: "cable.connector") {
#if targetEnvironment(macCatalyst)
            guideStep("Connect the iPod with a data-capable USB cable.")
            guideStep("Wait for it to appear in Finder under Locations.")
#else
            guideStep("Connect the iPod directly to your iPhone or iPad with a data-capable cable or adapter.")
            guideStep("Unlock the iPhone, open Files → Browse, and look under Locations.")
#endif
            guideStep("Choose the iPod’s top-level folder—the one containing iPod_Control.")
            Label("No computer, jailbreak or extra bridge device is required.", systemImage: "iphone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var connectIPodPage: some View {
        guidePage(title: "If it doesn’t appear", symbol: "arrow.clockwise") {
            DiskModeInstructions(compact: true)
        }
    }

    private var transferPage: some View {
        guidePage(title: "Add music safely", symbol: "music.note.list") {
            guideStep("Choose a folder with your music, review the detected tracks and playlists, and select the exact iPod model.")
            guideStep("Start with one track. Keep the iPod connected until PodBridge confirms completion, then eject it in Finder when available.")
            Label("After PodBridge changes the library, do not sync this iPod with Finder, Music, or iTunes. Their sync can replace the PodBridge changes.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text("PodBridge backs up and verifies the music database before changing it. Only iPod Classic 160 GB (late 2009 / 7th generation) has been tested on real hardware for this release.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func guidePage<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                Text(title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                content()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
    }

    private func guideStep(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DiskModeGuideView: View {
    @Environment(\.dismiss) private var dismiss
    let onChooseIPod: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                DiskModeInstructions(compact: false)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    onChooseIPod()
                } label: {
                    Text("Open Files and Choose iPod")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Make iPod appear")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

struct DiskModeInstructions: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AnimatedAssetImage(name: "DiskModeTutorial")
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 280 : 390)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)

            instruction(1, "Disconnect the iPod from the iPhone.")
            instruction(2, "Hold Menu + Center for about 6 seconds.")
            instruction(3, "When the Apple logo appears, immediately hold Center + Play/Pause.")
            instruction(4, "Wait for Disk Mode, reconnect the cable, then choose the iPod in Files.")

            Label("If iPhone reports that the accessory uses too much power, use a powered USB adapter. The cable must support data, not charging only.", systemImage: "bolt.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AnimatedAssetImage: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> UIImageView {
        let view = NonIntrinsicImageView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = Self.animatedImage(named: name)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    private static func animatedImage(named name: String) -> UIImage? {
        guard let data = NSDataAsset(name: name)?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var images: [UIImage] = []
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            images.append(UIImage(cgImage: cgImage))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
        }
        guard !images.isEmpty else { return nil }
        return UIImage.animatedImage(with: images, duration: max(duration, 0.1))
    }
}

private final class NonIntrinsicImageView: UIImageView {
    override var intrinsicContentSize: CGSize { .zero }
}

struct TransferPreflightView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let start: () -> Void

    private var hasEnoughReportedSpace: Bool {
        guard let free = model.storageFreeBytes else { return true }
        return free > model.totalBytes
    }

    var body: some View {
        NavigationView {
            List {
                Section("Transfer") {
                    PodBridgeLabeledContent("iPod") { Text(model.destinationDeviceProfile?.shortTitle ?? "Unknown") }
                    PodBridgeLabeledContent("Songs") { Text("\(model.files.count)") }
                    PodBridgeLabeledContent("Playlists") { Text("\(model.playlists.count)") }
                    PodBridgeLabeledContent("Music size") { Text(model.totalBytes.formatted(.byteCount(style: .file))) }
                    if let free = model.storageFreeBytes {
                        PodBridgeLabeledContent("Free on iPod") { Text(free.formatted(.byteCount(style: .file))) }
                    } else {
                        Label("Files did not report available space. Check the iPod capacity before continuing.", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    }
                    if !hasEnoughReportedSpace {
                        Label("The selected music exceeds the reported free space.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section("Protect your library") {
                    Label("PodBridge creates and verifies a database backup before changing the iPod.", systemImage: "externaldrive.badge.timemachine")
                    Label("Keep both devices connected and PodBridge open during the transfer.", systemImage: "cable.connector")
                    Label("Do not sync this iPod with Finder, Music or iTunes after using PodBridge.", systemImage: "exclamationmark.triangle")
                    if model.destinationDeviceProfile?.isHardwareTested == false {
                        Label("This iPod model has not been tested on physical hardware. Begin with one song.", systemImage: "flask")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button(action: start) {
                        Label("Back Up and Add \(model.files.count) Songs", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!hasEnoughReportedSpace || model.files.isEmpty || model.destinationFolder == nil || model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID)
                }
            }
            .navigationTitle("Before You Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct SignatureRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let enterManually: () -> Void
    let showComputerHelp: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("PodBridge could not find the signing ID in the readable iPod files. Choose how you want to recover it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    recoveryCard(
                        title: "Use a computer",
                        subtitle: "Fastest · usually under a minute",
                        symbol: "laptopcomputer",
                        tint: .blue
                    ) {
                        Text("Read the USB serial number on a Mac, Windows PC or Linux computer, then enter its 16 hexadecimal digits once.")
                            .font(.subheadline)
                        HStack {
                            Button("Show Instructions", action: showComputerHelp)
                                .buttonStyle(.borderedProminent)
                            Button("Enter ID", action: enterManually)
                                .buttonStyle(.bordered)
                        }
                    }

                    recoveryCard(
                        title: "Recover on this iPhone",
                        subtitle: "No computer · may take many hours",
                        symbol: "iphone.gen3.radiowaves.left.and.right",
                        tint: .orange
                    ) {
                        Text("PodBridge will use brute force: it will try possible IDs one by one and check each one against the signature in the existing iTunesDB. Everything happens on this iPhone and nothing is uploaded.")
                            .font(.subheadline)

                        if let progress = model.signatureRecoveryProgress {
                            ProgressView(value: progress.fraction)
                            HStack {
                                Text("\(progress.tested.formatted()) of \(progress.total.formatted())")
                                Spacer()
                                Text("\(Int(progress.candidatesPerSecond).formatted())/sec")
                            }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            if let seconds = progress.remainingSeconds {
                                Text("Estimated remaining time: \(durationText(seconds))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }

                        if model.isRecoveringSignatureID {
                            Label(
                                model.signatureRecoveryUsesMetal ? "Metal GPU acceleration active" : "CPU compatibility mode",
                                systemImage: model.signatureRecoveryUsesMetal ? "gpu" : "cpu"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.signatureRecoveryUsesMetal ? .green : .secondary)
                        }

                        if model.isRecoveringSignatureID {
                            Button(role: .destructive) {
                                model.stopLocalSignatureRecovery()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                model.startLocalSignatureRecovery()
                            } label: {
                                Label(
                                    model.signatureRecoveryProgress == nil ? "Start Local Recovery" : "Continue Local Recovery",
                                    systemImage: "bolt.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Label("Brute-force recovery can take many hours. The fastest option is still using a computer.", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                            Label("For an overnight run, connect the iPhone to power and leave PodBridge open on this screen. The display will stay on.", systemImage: "moon.stars.fill")
                            Label("Recovery pauses when you lock the iPhone or switch apps, then continues from the saved position.", systemImage: "pause.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Recover signature ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: model.destinationNeedsFirewireID) { _, needsID in
                if !needsID { dismiss() }
            }
        }
    }

    private func recoveryCard<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = seconds / 60
        let hours = minutes / 60
        if hours >= 1 { return String(format: "%.1f hours", hours) }
        return "\(max(1, Int(minutes.rounded(.up)))) minutes"
    }
}

struct SignatureIDHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let macCommand = "system_profiler SPUSBDataType | awk -F': ' '/Serial Number:/ {print $2}' | grep -E '^[0-9A-Fa-f]{16}$'"
    private let windowsCommand = "Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -match '^USB\\\\VID_05AC' -and $_.PNPDeviceID -match '\\\\[0-9A-Fa-f]{16}$' } | ForEach-Object { ([regex]::Match($_.PNPDeviceID, '[0-9A-Fa-f]{16}$')).Value } | Sort-Object -Unique"
    private let linuxCommand = "sudo lsusb -v 2>/dev/null | awk '/iSerial/ {print $3}' | grep -E '^[0-9A-Fa-f]{16}$'"

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("PodBridge already checked SysInfo, SysInfoExtended, ExtendedSysInfoXml and the other readable Device metadata. iOS lets the app read the iPod’s files, but not the USB serial number required to sign iTunesDB.")
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
