// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct TransferProgressView: View {
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
            .onChange(of: model.isCopying) { _, copying in
                if !copying { dismiss() }
            }
        }
    }
}
