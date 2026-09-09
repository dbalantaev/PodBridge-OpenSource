// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit

struct DiagnosticsDrawerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logSize: Int64 = 0
    @State private var shareItem: DiagnosticShareItem?
    @State private var errorMessage: String?
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Environment") {
                    LabeledContent("App") { Text(appVersion) }
                    LabeledContent("System") { Text("\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)") }
                    LabeledContent("Device") { Text(UIDevice.current.model) }
                }
                Section {
                    NavigationLink {
                        DiagnosticLogsView()
                    } label: {
                        Label("Open log", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        export()
                    } label: {
                        Label("Share diagnostics", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear logs", systemImage: "trash")
                    }
                    LabeledContent("Log file size") {
                        Text(ByteCountFormatter.string(fromByteCount: logSize, countStyle: .file))
                    }
                } header: {
                    Text("Persistent diagnostics")
                } footer: {
                    Text("The file survives app restarts and rotates at 4 MB. It can include filenames and playlist names, but never absolute paths, FirewireGuid, or media contents.")
                }
                Section("Open") {
                    Text("Tap the bug button or shake the iPhone to reopen this drawer.")
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { refresh() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("Clear the persistent log?", isPresented: $confirmingClear) {
            Button("Clear logs", role: .destructive, action: clear)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes diagnostics from current and previous app runs.")
        }
        .alert("Diagnostics", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func refresh() {
        logSize = PersistentLogStore.shared.fileSize()
    }

    private func export() {
        do {
            shareItem = DiagnosticShareItem(url: try PersistentLogStore.shared.makeExportFile())
            AppLogger.ui("Diagnostics export prepared", level: .info)
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.ui("Diagnostics export failed error=\(error.localizedDescription)", level: .error)
        }
        refresh()
    }

    private func clear() {
        do {
            try PersistentLogStore.shared.clear()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DiagnosticLogsView: View {
    @State private var text = ""
    @State private var shareItem: DiagnosticShareItem?
    @State private var errorMessage: String?
    @State private var confirmingClear = false

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableView(
                    "No logs yet",
                    systemImage: "doc.text",
                    description: Text("PodBridge diagnostics from current and previous runs will appear here.")
                )
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle("Persistent log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise", action: reload)
                Button("Share", systemImage: "square.and.arrow.up", action: export)
                Button("Clear", systemImage: "trash", role: .destructive) { confirmingClear = true }
            }
        }
        .task { reload() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("Clear the persistent log?", isPresented: $confirmingClear) {
            Button("Clear log", role: .destructive, action: clear)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Diagnostics", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func reload() {
        text = PersistentLogStore.shared.text()
    }

    private func clear() {
        do {
            try PersistentLogStore.shared.clear()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func export() {
        do {
            shareItem = DiagnosticShareItem(url: try PersistentLogStore.shared.makeExportFile())
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
