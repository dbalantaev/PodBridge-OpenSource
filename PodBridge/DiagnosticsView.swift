import SwiftUI
import UIKit

struct DiagnosticsDrawerView: View {
    @Environment(\.dismiss) private var dismiss
#if DEBUG || PODBRIDGE_DEMO
    var isEmulatingIPod = false
    var emulateIPod: ((DemoIPodScenario) -> Void)?
    var disconnectEmulatedIPod: (() -> Void)?
#endif
    var canRemoveSignatureID = false
    var removeSignatureID: (() throws -> URL)?
    @State private var logSize: Int64 = 0
    @State private var shareItem: DiagnosticShareItem?
    @State private var errorMessage: String?
    @State private var confirmingClear = false
    @State private var confirmingSignatureIDRemoval = false
    @State private var signatureIDBackupURL: URL?

    var body: some View {
        NavigationView {
            Form {
                Section("Environment") {
                    PodBridgeLabeledContent("App") { Text(appVersion) }
                    PodBridgeLabeledContent("System") { Text(systemDescription) }
                    PodBridgeLabeledContent("Device") { Text(deviceDescription) }
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
                    PodBridgeLabeledContent("Log file size") {
                        Text(ByteCountFormatter.string(fromByteCount: logSize, countStyle: .file))
                    }
                } header: {
                    Text("Persistent diagnostics")
                } footer: {
                    Text("The file survives app restarts and rotates at 4 MB. It can include filenames and playlist names, but never absolute paths, FirewireGuid, or media contents.")
                }
#if DEBUG || PODBRIDGE_DEMO
                Section("Demo iPods") {
                    demoButton("Normal iPod", subtitle: "ID present · Disk Use enabled", symbol: "ipod", scenario: .normal)
                    demoButton("iPod without Disk Use", subtitle: "Shows the prompt to enable disk use", symbol: "externaldrive.badge.xmark", scenario: .diskUseDisabled)
#if !targetEnvironment(macCatalyst)
                    demoButton("iPod without signature ID", subtitle: "Shows computer and local brute-force recovery", symbol: "key.slash", scenario: .missingSignatureID)
#endif
                    if isEmulatingIPod {
                        Button(role: .destructive) {
                            disconnectEmulatedIPod?()
                            dismiss()
                        } label: {
                            Label("Disconnect Demo iPod", systemImage: "eject.fill")
                        }
                    }
                    Text("Each option creates a temporary iPod Classic 7G library. No physical iPod is modified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
#endif
#if !targetEnvironment(macCatalyst)
                Section {
                    Button(role: .destructive) {
                        confirmingSignatureIDRemoval = true
                    } label: {
                        Label("Remove iPod signature ID for test", systemImage: "key.slash")
                    }
                    .disabled(!canRemoveSignatureID || removeSignatureID == nil)
                } header: {
                    Text("Signature recovery test")
                } footer: {
                    Text("PodBridge first saves and verifies a TXT backup in Files. Only then does it remove the ID from readable iPod metadata and this app’s cache.")
                }
#endif
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
        .confirmationDialog("Remove the signature ID from this iPod?", isPresented: $confirmingSignatureIDRemoval) {
            Button("Back up ID and remove it", role: .destructive, action: removeIDForTest)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is only for testing local brute-force recovery. PodBridge will verify a backup in Files before changing the iPod.")
        }
        .alert("Diagnostics", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

#if DEBUG || PODBRIDGE_DEMO
    private func demoButton(
        _ title: String,
        subtitle: String,
        symbol: String,
        scenario: DemoIPodScenario
    ) -> some View {
        Button {
            emulateIPod?(scenario)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
    }
#endif

    private var systemDescription: String {
#if targetEnvironment(macCatalyst)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)"
#else
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
#endif
    }

    private var deviceDescription: String {
#if targetEnvironment(macCatalyst)
        return "Mac"
#else
        return UIDevice.current.model
#endif
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

    private func removeIDForTest() {
        do {
            signatureIDBackupURL = try removeSignatureID?()
            errorMessage = "ID removed. Backup saved at Files → On My iPhone → PodBridgeALACarte → PodBridge → \(signatureIDBackupURL?.lastPathComponent ?? "backup.txt")."
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
                PodBridgeUnavailableView(
                    "No logs yet",
                    systemImage: "doc.text",
                    description: Text("PodBridgePro diagnostics from current and previous runs will appear here.")
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
            ToolbarItemGroup(placement: .navigationBarTrailing) {
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

struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
