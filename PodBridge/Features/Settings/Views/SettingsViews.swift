// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct PodBridgeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let openDiagnostics: () -> Void
    @State private var shareItem: DiagnosticShareItem?
    @State private var exportError: String?

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
                        exportDiagnostics()
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
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .alert("Diagnostics", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    private func exportDiagnostics() {
        do {
            PersistentLogStore.shared.flush()
            shareItem = DiagnosticShareItem(url: try PersistentLogStore.shared.makeExportFile())
            AppLogger.ui("Diagnostics export prepared from settings", level: .info)
        } catch {
            exportError = error.localizedDescription
            AppLogger.ui("Diagnostics export from settings failed error=\(error.localizedDescription)", level: .error)
        }
    }
}

struct SupportedFormatsView: View {
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
