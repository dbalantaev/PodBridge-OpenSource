// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct TransferSuccessView: View {
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

                    if let backupName = completion.backupName {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Library backup saved").font(.subheadline.weight(.semibold))
                                Text(backupName).font(.caption).textSelection(.enabled)
                                Text("You can restore a PodBridge backup from the connected iPod screen if needed.")
                                    .font(.caption)
                            }
                        } icon: {
                            Image(systemName: "externaldrive.badge.timemachine")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
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
        .navigationViewStyle(.stack)
    }

    private var successMark: some View {
        PodBridgeCelebrationMark(markSize: 72, height: 142)
    }
}

struct PodBridgeCelebrationMark: View {
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
