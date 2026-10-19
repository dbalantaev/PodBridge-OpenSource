// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI

struct ALACarteWriteBar: View {
    let selectedItemCount: Int
    let trackCount: Int
    @ObservedObject var model: MusicTransferViewModel
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                VStack(spacing: 2) {
                    Text("Write \(selectedItemCount) selected to iPod")
                        .font(.headline)
                    Text("\(trackCount) tracks")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isCopying || model.destinationFolder == nil)
            destinationHelp
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var destinationHelp: some View {
        if model.destinationFolder == nil {
            Text("Connect an iPod before writing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID {
            Text(
                "Rockbox /Music is available now. Choose the iPod model and "
                    + "resolve its signature ID to use Apple Library."
            )
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ALACarteWriteProgressView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let writesToRockbox: Bool
    let finished: () -> Void
    @State private var completion: TransferCompletion?
    @State private var rockboxFinished = false

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer()
                if let completion {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(.green)
                    Text("Music Added").font(.largeTitle.bold())
                    Text("\(completion.addedTracks) songs added to \(completion.destinationName).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if !completion.playlists.isEmpty {
                        Text(completion.playlists.map(\.name).joined(separator: " · "))
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    Button("Done") {
                        finished()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if rockboxFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(.green)
                    Text("Files Copied").font(.largeTitle.bold())
                    Text(model.resultMessage ?? "Music was copied to Rockbox /Music.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done") {
                        finished()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if !model.isCopying, let error = model.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    Text("Transfer Failed").font(.title.bold())
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done") {
                        finished()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                    Text(writesToRockbox ? "Copying for Rockbox" : "Adding Music")
                        .font(.title2.bold())
                    Text(status)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("\(model.copiedCount) \(writesToRockbox ? "files copied" : "tracks written to iPod")")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Label(
                        "Keep the iPod connected. PodBridge keeps the screen awake "
                            + "and requests background time if you lock it.",
                        systemImage: "info.circle.fill"
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel", role: .destructive) { model.cancelCopy() }
                        .buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(28)
            .navigationTitle("ALACarte")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(completion == nil && model.isCopying)
        .onChange(of: model.isCopying) { _, copying in
            guard !copying else { return }
            if writesToRockbox {
                rockboxFinished = model.errorMessage == nil && model.resultMessage != nil
            } else if let result = model.transferCompletion {
                completion = result
            }
        }
    }

    private var status: String {
        model.alacarteStatus ?? "Preparing transfer…"
    }

    private var progress: Double? {
        guard model.isCopying else { return nil }
        let words = status.split(separator: " ")
        guard let ofIndex = words.firstIndex(of: "of"),
              ofIndex > words.startIndex,
              ofIndex + 1 < words.endIndex,
              let current = Double(words[ofIndex - 1]),
              let total = Double(words[ofIndex + 1]), total > 0 else { return nil }
        return min(1, current / total)
    }
}
