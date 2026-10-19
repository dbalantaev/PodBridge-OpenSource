// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct PodBridgeIPodClassicArtwork: View {
    var showsCable = false

    var body: some View {
        Image(showsCable ? "IPodRenderCable" : "IPodRender")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

struct PodBridgeIPodDeviceArtwork: View {
    let profile: IPodDeviceProfile?

    private var assetName: String {
        switch profile {
        case .mini1And2: "IPodNano12"
        case .classic7: "IPodClassic7"
        case .classic6: "IPodClassic6"
        case .video5: "IPodVideo5"
        case .nano1And2: "IPodNano12"
        case .nano3: "IPodNano3"
        case .nano4: "IPodNano4"
        case nil: "IPodClassic7"
        }
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
        .accessibilityHidden(true)
    }
}

struct PodBridgeLoadingOverlay: View {
    let title: String
    let detail: String?
    var cancel: (() -> Void)? = nil
    var progress: Double? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.18)
                Text(title).font(.headline).multilineTextAlignment(.center)
                if let progress {
                    ProgressView(value: progress)
                        .frame(maxWidth: 240)
                }
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

struct ImportReviewView: View {
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

struct PodBridgeDockCableArtwork: View {
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
