// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct IPodLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    @State private var searchText = ""
    @State private var backupToRestore: IPodSyncEngine.DeletionBackup?
    @State private var backupToDiscard: IPodSyncEngine.DeletionBackup?
    @State private var playlistToRename: PlaylistRenameTarget?
    @State private var playlistToDelete: PlaylistRenameTarget?
    @State private var showingPlaylistComposer = false

    private var filteredAlbums: [IPodAlbum] {
        guard !searchText.isEmpty else { return model.libraryAlbums }
        return model.libraryAlbums.filter { album in
            album.title.localizedCaseInsensitiveContains(searchText)
                || album.artist.localizedCaseInsensitiveContains(searchText)
                || album.tracks.contains { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        NavigationView {
            List {
                activitySection
                deletionBackupSection
                artworkSection
                playlistsSection
                albumsSection
                resultSection
            }
            .navigationTitle("iPod Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Album, artist, or song")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("New Playlist", systemImage: "plus") {
                        showingPlaylistComposer = true
                    }
                    .disabled(model.isManagingLibrary || model.libraryTracks.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .disabled(model.isManagingLibrary)
                }
            }
        }
        .confirmationDialog(
            "Restore this deleted track?",
            isPresented: Binding(get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } }),
            titleVisibility: .visible
        ) {
            if let backup = backupToRestore {
                Button("Restore to iPod") {
                    backupToRestore = nil
                    model.restoreDeletedTrack(backup)
                }
            }
            Button("Cancel", role: .cancel) { backupToRestore = nil }
        } message: {
            Text("Restoration is allowed only while the iPod library is unchanged since deletion.")
        }
        .confirmationDialog(
            "Delete the iPhone backup?",
            isPresented: Binding(get: { backupToDiscard != nil }, set: { if !$0 { backupToDiscard = nil } }),
            titleVisibility: .visible
        ) {
            if let backup = backupToDiscard {
                Button("Make deletion permanent", role: .destructive) {
                    backupToDiscard = nil
                    model.discardDeletedTrackBackup(backup)
                }
            }
            Button("Cancel", role: .cancel) { backupToDiscard = nil }
        } message: {
            Text("The track will remain deleted from the iPod and its only PodBridge backup will be removed from this iPhone.")
        }
        .confirmationDialog(
            "Delete this playlist?",
            isPresented: Binding(get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let target = playlistToDelete {
                let importedTrackCount = IPodSyncEngine.importedCompilationTrackIDs(
                    playlist: target.playlist,
                    tracks: model.libraryTracks
                ).count
                Button("Delete playlist only", role: .destructive) {
                    playlistToDelete = nil
                    model.deletePlaylist(at: target.index, includingSongs: false)
                }
                if importedTrackCount > 0 {
                    Button("Delete playlist and \(importedTrackCount) imported songs", role: .destructive) {
                        playlistToDelete = nil
                        model.deletePlaylist(at: target.index, includingSongs: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: {
            if let target = playlistToDelete {
                Text("Deleting only \(target.playlist.name) keeps its songs. The imported-songs option removes only tracks owned by its matching compilation album; reused songs from the older library stay untouched.")
            }
        }
        .sheet(item: $playlistToRename) { target in
            PlaylistRenameEditor(target: target) { name in
                model.renamePlaylist(at: target.index, to: name)
            }
        }
        .sheet(isPresented: $showingPlaylistComposer) {
            PlaylistComposerView(tracks: model.libraryTracks) { name, trackIDs in
                model.createPlaylist(name: name, trackIDs: trackIDs)
            }
        }
    }

    @ViewBuilder
    private var activitySection: some View {
        if model.isManagingLibrary {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    if let progress = model.artworkSearchProgress {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Searching album artwork…").font(.subheadline)
                            Text("\(progress.completedItems) of \(progress.totalItems) albums/songs · \(progress.matchedItems) matches")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { model.cancelArtworkSearch() }
                            .buttonStyle(.borderless)
                    } else {
                        Text("Verifying and updating the iPod…").font(.subheadline)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var artworkSection: some View {
        if model.automaticArtworkCandidateCount > 0 {
            Section {
                Button("Find missing artwork", systemImage: "photo.badge.magnifyingglass") {
                    model.findMissingArtwork()
                }
                .disabled(model.isManagingLibrary)
            } footer: {
                Text("Missing normal-album covers are matched by album and album artist. Every playlist song is matched individually by title and artist; custom shared playlist artwork may be replaced by the song's original-release cover. \(model.automaticArtworkCandidateCount) tracks can be checked.")
            }
        }
    }

    @ViewBuilder
    private var deletionBackupSection: some View {
        if let backup = model.deletionBackups.first {
            Section {
                DeletionBackupSummary(backup: backup)
                Button("Restore to iPod", systemImage: "arrow.uturn.backward") {
                    backupToRestore = backup
                }
                .disabled(model.isManagingLibrary)
                Button("Make deletion permanent", systemImage: "trash", role: .destructive) {
                    backupToDiscard = backup
                }
                .disabled(model.isManagingLibrary)
            } header: {
                Text("Earlier local safety backup")
            } footer: {
                Text("New deletions are permanent and do not create audio backups. This older backup can still be restored if the library has not changed, or discarded to free iPhone storage.")
            }
        }
    }

    private var albumsSection: some View {
        Section("Albums (\(filteredAlbums.count))") {
            ForEach(filteredAlbums) { album in
                NavigationLink {
                    AlbumDetailView(model: model, albumID: album.id)
                } label: {
                    AlbumRow(album: album)
                }
            }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        if !model.libraryPlaylists.isEmpty {
            Section("Playlists (\(model.libraryPlaylists.count))") {
                ForEach(Array(model.libraryPlaylists.enumerated()), id: \.offset) { index, playlist in
                    HStack {
                        Button {
                            playlistToRename = PlaylistRenameTarget(index: index, playlist: playlist)
                        } label: {
                            HStack(spacing: 10) {
                            Image(systemName: "music.note.list").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name).foregroundStyle(.primary)
                                Text("\(playlist.trackIDs.count) tracks")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                playlistToRename = PlaylistRenameTarget(index: index, playlist: playlist)
                            }
                            Button("Restore covers from audio files", systemImage: "arrow.uturn.backward.circle") {
                                model.restoreEmbeddedArtwork(
                                    trackIDs: playlist.trackIDs,
                                    label: playlist.name
                                )
                            }
                            Button("Restore original song covers online", systemImage: "photo.badge.magnifyingglass") {
                                model.replaceSongArtworkFromInternet(
                                    trackIDs: playlist.trackIDs,
                                    label: playlist.name
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isManagingLibrary)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            playlistToDelete = PlaylistRenameTarget(index: index, playlist: playlist)
                        }
                        .disabled(model.isManagingLibrary)
                        Button("Rename", systemImage: "pencil") {
                            playlistToRename = PlaylistRenameTarget(index: index, playlist: playlist)
                        }
                        .tint(.blue)
                        .disabled(model.isManagingLibrary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let message = model.resultMessage {
            Section {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

}
