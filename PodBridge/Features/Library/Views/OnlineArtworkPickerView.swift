// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct OnlineArtworkTarget: Identifiable {
    enum Scope { case album, track }

    let id = UUID()
    let scope: Scope
    let title: String
    let artist: String
    let trackIDs: [UInt32]

    static func album(_ album: IPodAlbum) -> Self {
        Self(scope: .album, title: album.title, artist: album.artist, trackIDs: album.tracks.map(\.id))
    }

    static func track(_ track: ClassicTrack) -> Self {
        Self(scope: .track, title: track.title, artist: track.artist, trackIDs: [track.id])
    }
}

struct OnlineArtworkPicker: View {
    @Environment(\.dismiss) private var dismiss
    let target: OnlineArtworkTarget
    let select: (Data) -> Void
    @State private var title: String
    @State private var artist: String
    @State private var candidates: [ArtworkLookupService.Candidate] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    init(target: OnlineArtworkTarget, select: @escaping (Data) -> Void) {
        self.target = target
        self.select = select
        _title = State(initialValue: target.title)
        _artist = State(initialValue: target.artist)
    }

    var body: some View {
        NavigationView {
            List {
                Section("Search") {
                    TextField(target.scope == .album ? "Album" : "Song", text: $title)
                    TextField("Artist", text: $artist)
                    Button("Search the internet", systemImage: "magnifyingglass") { search() }
                        .disabled(searching || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if searching {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for cover variants…")
                        }
                    }
                } else if candidates.isEmpty, errorMessage == nil {
                    Section {
                        Text("Search results will appear here. Choosing one forcibly replaces the current iPod artwork.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if !candidates.isEmpty {
                    Section("Choose artwork") {
                        ForEach(candidates) { candidate in
                            Button {
                                select(candidate.data)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    if let image = UIImage(data: candidate.data) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 76, height: 76)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.title).foregroundStyle(.primary)
                                        Text(candidate.artist).font(.caption).foregroundStyle(.secondary)
                                        Text("Use this cover").font(.caption2).foregroundStyle(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Online Artwork")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { search() }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private func search() {
        searchTask?.cancel()
        candidates = []
        errorMessage = nil
        searching = true
        let queryTitle = title
        let queryArtist = artist
        searchTask = Task {
            do {
                let service = ArtworkLookupService()
                let found: [ArtworkLookupService.Candidate]
                found = try await withThrowingTaskGroup(of: [ArtworkLookupService.Candidate].self) { group in
                    group.addTask {
                        switch target.scope {
                        case .album:
                            return try await service.albumCandidates(album: queryTitle, artist: queryArtist)
                        case .track:
                            return try await service.trackCandidates(track: queryTitle, artist: queryArtist)
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 20_000_000_000)
                        throw URLError(.timedOut)
                    }
                    guard let first = try await group.next() else { return [] }
                    group.cancelAll()
                    return first
                }
                guard !Task.isCancelled else { return }
                candidates = found
                if found.isEmpty { errorMessage = "No exact cover variants found. You can edit the title or artist and search again." }
                searching = false
            } catch is CancellationError {
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? URLError)?.code == .timedOut
                    ? "The artwork service did not respond within 20 seconds. Try again."
                    : error.localizedDescription
                searching = false
            }
        }
    }
}
