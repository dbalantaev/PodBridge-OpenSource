// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import Foundation
import SwiftUI

struct ALACarteBrowserView: View {
    private enum ConnectionMode: String, CaseIterable, Identifiable {
        case automatic = "Auto"
        case local = "Local"
        case internet = "Internet"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    // serverURL is kept only to migrate settings from the previous single-address UI.
    @AppStorage("alacarte.serverURL") private var legacyServerAddress = ""
    @AppStorage("alacarte.localServerURL") private var localServerAddress = ""
    @AppStorage("alacarte.internetServerURL") private var internetServerAddress = ""
    @AppStorage("alacarte.connectionMode") private var connectionMode = ConnectionMode.automatic.rawValue
    @AppStorage("alacarte.username") private var username = ""
    @State private var password = ""
    @State private var client: ALACarteClient?
    @State private var items: [ALACarteLibraryItem] = []
    @State private var searchText = ""
    @State private var connecting = false
    @State private var errorMessage: String?
    @State private var selectedItemIDs: Set<String> = []
    @State private var showingWebInterface = false
    @State private var refreshingLibrary = false
    @State private var libraryTab = 0
    @State private var showingWriteProgress = false
    @State private var confirmingWrite = false
    @State private var writingToRockbox = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?

    private var selectedMode: ConnectionMode {
        ConnectionMode(rawValue: connectionMode) ?? .automatic
    }
    private var hasServerAddressForSelectedMode: Bool {
        switch selectedMode {
        case .automatic:
            !localServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !internetServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .local:
            !localServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .internet:
            !internetServerAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var filteredItems: [ALACarteLibraryItem] {
        let kinds: [ALACarteLibraryItem.Kind?] = [nil, .album, .song, .playlist]
        let kind = kinds[libraryTab]
        return items.filter { item in
            (kind == nil || item.kind == kind) &&
            (searchText.isEmpty ||
            item.title.localizedCaseInsensitiveContains(searchText)
                || item.subtitle.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var selectedItems: [ALACarteLibraryItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectedTrackCount: Int { selectedItems.reduce(0) { $0 + $1.trackCount } }

    var body: some View {
        NavigationView {
            List {
                if client == nil {
                    Section {
                        Picker("Connection", selection: $connectionMode) {
                            ForEach(ConnectionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("http://server.local:7373", text: $localServerAddress)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("https://music.example.com", text: $internetServerAddress)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        Button(connecting ? "Connecting…" : "Connect", systemImage: "network") {
                            connect()
                        }
                        .disabled(
                            connecting || !hasServerAddressForSelectedMode || username.isEmpty || password.isEmpty
                        )
                    } header: {
                        Text("Your ALACarte server")
                    } footer: {
                        Text(
                            "Auto tries the local address first, then the internet address if the local server "
                                + "cannot be reached. The password is not saved; the signed-in session is stored "
                                + "in Keychain."
                        )
                    }
                } else {
                    Section {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(client?.baseURL.host ?? "ALACarte")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button { showingWebInterface = true } label: {
                            Label("Open server", systemImage: "globe")
                        }
                        Button { refreshLibrary() } label: {
                            Label(
                                refreshingLibrary ? "Refreshing…" : "Refresh downloaded music",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(refreshingLibrary || model.isCopying)
                    } footer: {
                        Text("When you close the server, PodBridge refreshes this list automatically.")
                    }
                    Section {
                        Picker("Type", selection: $libraryTab) {
                            Text("All").tag(0)
                            Text("Albums").tag(1)
                            Text("Songs").tag(2)
                            Text("Playlists").tag(3)
                        }
                        .pickerStyle(.segmented)
                        Text("\(items.count) available · \(selectedItemIDs.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(filteredItems) { item in
                            Button { toggle(item) } label: {
                                ALACarteLibraryRow(
                                    item: item,
                                    isSelected: selectedItemIDs.contains(item.id)
                                )
                            }
                                .disabled(model.isCopying)
                        }
                    } header: {
                        Text("Downloaded music")
                    } footer: {
                        Text("Only music already downloaded on your server appears here.")
                    }
                }
                if let status = model.alacarteStatus {
                    Section { HStack(spacing: 12) { ProgressView(); Text(status) } }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .searchable(text: $searchText, prompt: "Album, playlist, or song")
            .safeAreaInset(edge: .bottom) {
                if !selectedItemIDs.isEmpty, client != nil {
                    ALACarteWriteBar(
                        selectedItemCount: selectedItemIDs.count,
                        trackCount: selectedTrackCount,
                        model: model
                    ) {
                        confirmingWrite = true
                    }
                }
            }
            .navigationTitle("ALACarte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(model.isCopying)
                }
                if client != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Disconnect") {
                            client?.forgetSavedSession()
                            client = nil
                            items = []
                            selectedItemIDs.removeAll()
                            password = ""
                        }
                        .disabled(model.isCopying)
                    }
                }
            }
        }
        .task {
            migrateLegacyServerAddress()
            await restoreSavedSession()
        }
        .onDisappear {
            connectionTask?.cancel()
            refreshTask?.cancel()
        }
        .sheet(isPresented: $showingWebInterface) {
            if let client {
                ALACarteWebInterfaceView(
                    serverURL: client.baseURL,
                    sessionCookieHeader: client.webSessionCookieHeader,
                    didClose: refreshLibrary
                )
            }
        }
        .fullScreenCover(isPresented: $showingWriteProgress) {
            ALACarteWriteProgressView(model: model, writesToRockbox: writingToRockbox) {
                showingWriteProgress = false
                selectedItemIDs.removeAll()
                refreshLibrary()
            }
        }
        .confirmationDialog(
            "Write music to iPod?",
            isPresented: $confirmingWrite,
            titleVisibility: .visible
        ) {
            Button("Add \(selectedTrackCount) tracks to Apple library") {
                guard let client else { return }
                writingToRockbox = false
                showingWriteProgress = true
                model.importFromALACarte(client: client, items: selectedItems)
            }
            .disabled(model.destinationDeviceProfile == nil || model.destinationNeedsFirewireID)
            Button("Copy to Rockbox /Music") {
                guard let client else { return }
                writingToRockbox = true
                showingWriteProgress = true
                model.copyFromALACarteToRockbox(client: client, items: selectedItems)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(selectedItemIDs.count) selected items · \(selectedTrackCount) tracks. "
                    + "Apple Library creates a database backup. Rockbox copies verified files directly to /Music."
            )
        }
    }
}

private extension ALACarteBrowserView {
    private func connect() {
        connectionTask?.cancel()
        connecting = true
        errorMessage = nil
        connectionTask = Task {
            do {
                let newClient = try await connectToFirstReachableServer()
                try Task.checkCancellation()
                client = newClient.client
                items = newClient.items
                password = ""
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            connecting = false
            connectionTask = nil
        }
    }

    private func toggle(_ item: ALACarteLibraryItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func refreshLibrary() {
        guard let client, !refreshingLibrary, !model.isCopying else { return }
        refreshTask?.cancel()
        refreshingLibrary = true
        errorMessage = nil
        refreshTask = Task {
            defer {
                refreshingLibrary = false
                refreshTask = nil
            }
            do {
                let refreshed = try await client.library()
                try Task.checkCancellation()
                items = refreshed
                selectedItemIDs.formIntersection(Set(refreshed.map(\.id)))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func restoreSavedSession() async {
        guard client == nil, !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            let urls = try serverURLsForSelectedMode()
            for (index, url) in urls.enumerated() {
                do {
                    let savedClient = ALACarteClient(baseURL: url, requestTimeout: 10)
                    guard savedClient.hasSavedSession else { continue }
                    do {
                        let state = try await savedClient.authState()
                        guard state.authDisabled || state.authed else { continue }
                    } catch ALACarteError.endpointNotFound {
                        // Older servers validate the session when their library is requested.
                    }
                    try await savedClient.validateCompatibilityIfAvailable()
                    let savedItems = try await savedClient.library()
                    client = savedClient
                    items = savedItems
                    errorMessage = nil
                    return
                } catch {
                    guard selectedMode == .automatic,
                          index < urls.count - 1,
                          shouldTryNextServer(after: error) else { throw error }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // A temporary network failure is not a logout; keep the saved cookie.
            errorMessage = error.localizedDescription
        }
    }

    private func migrateLegacyServerAddress() {
        guard localServerAddress.isEmpty, !legacyServerAddress.isEmpty else { return }
        localServerAddress = legacyServerAddress
    }

    private func serverURLsForSelectedMode() throws -> [URL] {
        let rawAddresses: [String]
        switch selectedMode {
        case .automatic:
            rawAddresses = [localServerAddress, internetServerAddress]
        case .local:
            rawAddresses = [localServerAddress]
        case .internet:
            rawAddresses = [internetServerAddress]
        }
        let parsed = try rawAddresses
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(ALACarteServerAddress.parse)
        guard !parsed.isEmpty else { throw ALACarteError.invalidServerURL }
        return parsed.reduce(into: []) { result, url in
            if !result.contains(url) { result.append(url) }
        }
    }

    private func connectToFirstReachableServer() async throws -> (client: ALACarteClient, items: [ALACarteLibraryItem]) {
        let urls = try serverURLsForSelectedMode()
        var lastError: Error?
        for (index, url) in urls.enumerated() {
            do {
                let candidate = ALACarteClient(baseURL: url)
                try await candidate.login(username: username, password: password)
                try await candidate.validateCompatibilityIfAvailable()
                let candidateItems = try await candidate.library()
                return (candidate, candidateItems)
            } catch {
                lastError = error
                guard selectedMode == .automatic,
                      index < urls.count - 1,
                      shouldTryNextServer(after: error) else { throw error }
            }
        }
        throw lastError ?? ALACarteError.invalidServerURL
    }

    private func shouldTryNextServer(after error: Error) -> Bool {
        if case ALACarteError.endpointNotFound = error {
            return true
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

}
