// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct DeletionBackupSummary: View {
    let backup: IPodSyncEngine.DeletionBackup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(backup.title).font(.headline)
            Text(backup.artist).font(.subheadline).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AlbumRow: View {
    let album: IPodAlbum

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).foregroundStyle(.primary)
                Text("\(album.artist) · \(album.tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(album.byteCount), countStyle: .file))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct AlbumDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let albumID: String
    @State private var editingAlbum = false
    @State private var confirmingAlbumDeletion = false
    @State private var trackToEdit: ClassicTrack?
    @State private var trackToDelete: ClassicTrack?
    @State private var choosingAlbumArtwork = false
    @State private var choosingTrackArtwork = false
    @State private var trackArtworkTarget: ClassicTrack?
    @State private var onlineArtworkTarget: OnlineArtworkTarget?

    private var album: IPodAlbum? {
        model.libraryAlbums.first { $0.id == albumID }
    }

    var body: some View {
        Group {
            if let album {
                List {
                    PodBridgeOperationProgressView(model: model)
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(album.title).font(.title3.weight(.semibold))
                            Text(album.artist).foregroundStyle(.secondary)
                            Text("\(album.tracks.count) tracks · \(ByteCountFormatter.string(fromByteCount: Int64(album.byteCount), countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Edit album metadata", systemImage: "pencil") {
                            editingAlbum = true
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Find album artwork online", systemImage: "photo.badge.magnifyingglass") {
                            onlineArtworkTarget = .album(album)
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Choose album artwork from Files", systemImage: "folder") {
                            choosingAlbumArtwork = true
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Restore embedded song covers", systemImage: "arrow.uturn.backward.circle") {
                            model.restoreEmbeddedArtwork(album)
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Find an original cover for every song", systemImage: "sparkles.rectangle.stack") {
                            model.replaceSongArtworkFromInternet(
                                trackIDs: album.tracks.map(\.id),
                                label: album.title
                            )
                        }
                        .disabled(model.isManagingLibrary)
                        PodBridgeExportButton(model: model, tracks: album.tracks, title: "Copy album to Files")
                        Button("Delete album", systemImage: "trash", role: .destructive) {
                            confirmingAlbumDeletion = true
                        }
                        .disabled(model.isManagingLibrary || model.isExporting || model.isCopying || model.isRestoring)
                    }
                    Section("Songs") {
                        ForEach(album.tracks) { track in
                            LibraryTrackRow(track: track, disabled: model.isManagingLibrary) {
                                trackToEdit = track
                            } artworkAction: {
                                onlineArtworkTarget = .track(track)
                            } fileArtworkAction: {
                                trackArtworkTarget = track
                                choosingTrackArtwork = true
                            } deleteAction: {
                                trackToDelete = track
                            }
                        }
                    }
                    if model.isManagingLibrary {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Updating and verifying the iPod library…")
                            }
                        }
                    }
                }
                .navigationTitle(album.title)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $editingAlbum) {
                    AlbumMetadataEditor(album: album) { update in
                        model.editAlbumMetadata(album, update: update)
                    }
                }
                .sheet(item: $trackToEdit) { track in
                    TrackMetadataEditor(track: track) { update in
                        model.editTrackMetadata(track, update: update)
                    }
                }
                .sheet(item: $onlineArtworkTarget) { target in
                    OnlineArtworkPicker(target: target) { data in
                        switch target.scope {
                        case .album:
                            if let currentAlbum = self.album {
                                model.setAlbumArtwork(currentAlbum, artwork: data)
                            }
                        case .track:
                            if let trackID = target.trackIDs.first,
                               let currentTrack = model.libraryTracks.first(where: { $0.id == trackID }) {
                                model.setTrackArtwork(currentTrack, artwork: data)
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "Permanently delete this album?",
                    isPresented: $confirmingAlbumDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete \(album.tracks.count) tracks", role: .destructive) {
                        model.deleteAlbumPermanently(album)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(album.title) will be removed without an audio backup, freeing approximately \(ByteCountFormatter.string(fromByteCount: Int64(album.byteCount), countStyle: .file)). This cannot be undone.")
                }
                .confirmationDialog(
                    "Permanently delete this song?",
                    isPresented: Binding(get: { trackToDelete != nil }, set: { if !$0 { trackToDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    if let track = trackToDelete {
                        Button("Delete song", role: .destructive) {
                            trackToDelete = nil
                            model.deleteTrackPermanently(track)
                            if album.tracks.count == 1 { dismiss() }
                        }
                    }
                    Button("Cancel", role: .cancel) { trackToDelete = nil }
                } message: {
                    if let track = trackToDelete {
                        Text("\(track.title) will be removed without an audio backup. This cannot be undone.")
                    }
                }
            } else {
                PodBridgeUnavailableView("Album no longer exists", systemImage: "music.note")
            }
        }
        .fileImporter(
            isPresented: $choosingAlbumArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let album else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first { model.setAlbumArtwork(album, imageURL: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $choosingTrackArtwork,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let track = trackArtworkTarget else { return }
            trackArtworkTarget = nil
            switch result {
            case .success(let urls):
                if let url = urls.first { model.setTrackArtwork(track, imageURL: url) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

struct AlbumMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let album: IPodAlbum
    let save: (IPodSyncEngine.AlbumMetadataUpdate) -> Void
    @State private var title: String
    @State private var albumArtist: String
    @State private var songArtist: String
    @State private var genre: String
    @State private var year: String
    @State private var compilation: Bool

    init(album: IPodAlbum, save: @escaping (IPodSyncEngine.AlbumMetadataUpdate) -> Void) {
        self.album = album
        self.save = save
        _title = State(initialValue: album.title)
        _albumArtist = State(initialValue: album.albumArtist)
        let songArtists = Set(album.tracks.map { $0.artist.trimmingCharacters(in: .whitespacesAndNewlines) })
        _songArtist = State(initialValue: songArtists.count == 1 ? songArtists.first ?? "" : "")
        _genre = State(initialValue: album.genre)
        _year = State(initialValue: album.year == 0 ? "" : String(album.year))
        _compilation = State(initialValue: album.compilation)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Album metadata") {
                    TextField("Album", text: $title)
                    TextField("Album artist", text: $albumArtist)
                    TextField("Song artist (all tracks)", text: $songArtist)
                    TextField("Genre", text: $genre)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    Toggle("Compilation", isOn: $compilation)
                }
                Section {
                    Text("Album-level values will be applied to all \(album.tracks.count) tracks. Use “Various Artists” with Compilation enabled for a mixed-artist album.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Enter a song artist to replace the artist on every track. Leave it empty to keep each song’s current artist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Matching duplicate album cards are merged automatically, including an existing card that already has the new album artist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(IPodSyncEngine.AlbumMetadataUpdate(
                            album: title,
                            albumArtist: albumArtist,
                            songArtist: songArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : songArtist,
                            genre: genre,
                            year: UInt32(year) ?? 0,
                            compilation: compilation
                        ))
                        dismiss()
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (compilation && albumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
        }
    }
}

struct LibraryTrackRow: View {
    let track: ClassicTrack
    let disabled: Bool
    let editAction: () -> Void
    let artworkAction: () -> Void
    let fileArtworkAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        Button(action: editAction) {
            HStack(spacing: 12) {
                Image(systemName: "music.note").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(track.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(disabled)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive, action: deleteAction)
                .disabled(disabled)
            Button("Edit", systemImage: "pencil", action: editAction)
                .tint(.blue)
                .disabled(disabled)
            Button("Artwork", systemImage: "photo", action: artworkAction)
                .tint(.purple)
                .disabled(disabled)
            Button("File", systemImage: "folder", action: fileArtworkAction)
                .tint(.gray)
                .disabled(disabled)
        }
    }

    private var subtitle: String {
        [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
