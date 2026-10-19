// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

// MARK: - PodBridge consumer library UI (Iteration 3)
struct PodBridgeLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    @State private var searchText = ""
    @State private var section = 0
    @State private var showingPlaylistComposer = false
    @State private var confirmingLibraryClear = false

    private var tracks: [ClassicTrack] {
        model.libraryTracks.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.artist.localizedCaseInsensitiveContains(searchText) || $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }
    private var albums: [IPodAlbum] {
        model.libraryAlbums.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) || $0.artist.localizedCaseInsensitiveContains(searchText)
        }
    }
    private var artists: [String] {
        Array(Set(model.libraryTracks.map(\.artist))).filter {
            !$0.isEmpty && (searchText.isEmpty || $0.localizedCaseInsensitiveContains(searchText))
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var playlists: [(index: Int, playlist: ClassicPlaylist)] {
        Array(model.libraryPlaylists.enumerated()).compactMap { index, playlist in
            searchText.isEmpty || playlist.name.localizedCaseInsensitiveContains(searchText)
                ? (index, playlist)
                : nil
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Button { dismiss() } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                Text("PodBridge")
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("iPod Library")
                            .font(.largeTitle.bold())
                        Text("\(model.libraryTracks.count.formatted()) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search your iPod…", text: $searchText)
                            .textInputAutocapitalization(.never)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Picker("Library", selection: $section) {
                        Text("Songs").tag(0); Text("Albums").tag(1); Text("Artists").tag(2); Text("Playlists").tag(3)
                    }
                    .pickerStyle(.segmented)

                    if section == 3 {
                        Button {
                            showingPlaylistComposer = true
                        } label: {
                            Label("New Playlist", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isManagingLibrary || model.libraryTracks.isEmpty)
                    }

                    NavigationLink(destination: PodBridgeLibraryToolsView(model: model)) {
                        HStack(spacing: 13) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44).background(.purple, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Library Tools").font(.headline).foregroundStyle(.primary)
                                Text("Find missing artwork, incomplete metadata and duplicates").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                        }
                        .padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }.buttonStyle(.plain)

                    if !model.libraryTracks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Move music from this iPod").font(.headline)
                            PodBridgeExportButton(
                                model: model,
                                tracks: model.libraryTracks,
                                title: "Copy entire library to Files"
                            )
                            Button("Erase all music from iPod", systemImage: "trash", role: .destructive) {
                                confirmingLibraryClear = true
                            }
                            .disabled(model.isManagingLibrary || model.isExporting || model.isCopying || model.isRestoring)
                            Text("Copying keeps the iPod unchanged. Erasing removes every song and playlist without an audio backup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }

                    PodBridgeOperationProgressView(model: model)
                    libraryContent
                }
                .padding(16)
                .frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemBackground))
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showingPlaylistComposer) {
            PlaylistComposerView(tracks: model.libraryTracks) { name, trackIDs in
                model.createPlaylist(name: name, trackIDs: trackIDs)
            }
        }
        .confirmationDialog("Erase the entire iPod music library?", isPresented: $confirmingLibraryClear, titleVisibility: .visible) {
            Button("Erase \(model.libraryTracks.count) songs and all playlists", role: .destructive) {
                model.clearLibraryPermanently()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes approximately \(ByteCountFormatter.string(fromByteCount: Int64(model.libraryTracks.reduce(0) { $0 + UInt64($1.byteCount) }), countStyle: .file)) of audio. Copy the library to Files first if you want to keep it.")
        }
        .overlay {
            if model.isExporting {
                PodBridgeLoadingOverlay(
                    title: "Copying music to Files…",
                    detail: "\(model.exportedCount) of \(model.exportTotalCount) songs" + (model.operationETA.map { " · \($0)" } ?? ""),
                    progress: Double(model.exportedCount) / Double(max(1, model.exportTotalCount))
                )
            } else if model.isManagingLibrary {
                PodBridgeLoadingOverlay(
                    title: model.artworkSearchProgress == nil ? "Updating iPod Library…" : "Finding Artwork…",
                    detail: libraryActivityDetail,
                    cancel: model.artworkSearchProgress == nil ? nil : { model.cancelArtworkSearch() },
                    progress: model.deletionProgress.flatMap { $0.total > 0 ? Double($0.completed) / Double($0.total) : nil }
                )
            }
        }
    }

    private var libraryActivityDetail: String? {
        if let progress = model.deletionProgress {
            let count = progress.total > 0 ? " · \(progress.completed) of \(progress.total)" : ""
            return progress.stage + count + (model.operationETA.map { " · \($0)" } ?? "")
        }
        guard let progress = model.artworkSearchProgress else {
            return "Verifying changes and keeping the database consistent"
        }
        return "\(progress.completedItems) of \(progress.totalItems) checked · \(progress.matchedItems) matches"
    }

    @ViewBuilder private var libraryContent: some View {
        if section == 0 && tracks.isEmpty {
            libraryEmptyState("No songs found", message: searchText.isEmpty ? "Music already on this iPod will appear here. Add a folder from Files to get started." : "Try another search.", symbol: "music.note")
        } else if section == 1 && albums.isEmpty {
            libraryEmptyState("No albums found", message: searchText.isEmpty ? "Albums are created automatically from the music on your iPod." : "Try another search.", symbol: "square.stack")
        } else if section == 2 && artists.isEmpty {
            libraryEmptyState("No artists found", message: searchText.isEmpty ? "Artists will appear when the iPod contains music with artist metadata." : "Try another search.", symbol: "person")
        } else if section == 3 && playlists.isEmpty {
            libraryEmptyState("No playlists yet", message: "Tap New Playlist to choose songs already on this iPod.", symbol: "music.note.list")
        } else if section == 1 {
            LazyVStack(spacing: 0) {
                ForEach(albums) { album in
                    NavigationLink { AlbumDetailView(model: model, albumID: album.id) } label: {
                        libraryRow(
                            title: album.title.isEmpty ? "Unknown Album" : album.title,
                            subtitle: album.artist.isEmpty ? "Unknown Artist" : album.artist,
                            artwork: album.tracks.first(where: { $0.artworkData != nil })?.artworkData,
                            symbol: "opticaldisc.fill"
                        )
                    }.buttonStyle(.plain)
                    if album.id != albums.last?.id { Divider().padding(.leading, 62) }
                }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            LazyVStack(spacing: 0) {
                if section == 0 {
                    ForEach(tracks) { track in
                        NavigationLink(destination: TrackDetailView(model: model, trackID: track.id)) {
                            libraryTrackRow(track)
                        }
                        .buttonStyle(.plain)
                    }
                } else if section == 2 {
                    ForEach(artists, id: \.self) { artist in
                        let sample = model.libraryTracks.first { $0.artist == artist }
                        NavigationLink(destination: ArtistDetailView(model: model, artist: artist)) {
                            libraryRow(
                                title: artist,
                                subtitle: "\(model.libraryTracks.filter { $0.artist == artist }.count) songs",
                                artwork: sample?.artworkData,
                                symbol: "person.fill"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(playlists, id: \.index) { item in
                        let index = item.index
                        let playlist = item.playlist
                        NavigationLink(destination: PlaylistDetailView(model: model, playlistIndex: index)) {
                            playlistRow(playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func libraryTrackRow(_ track: ClassicTrack) -> some View {
        libraryRow(title: track.title, subtitle: track.artist, artwork: track.artworkData, symbol: "music.note")
    }

    private func libraryEmptyState(_ title: String, message: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func playlistRow(_ playlist: ClassicPlaylist) -> some View {
        let tracksByID = Dictionary(uniqueKeysWithValues: model.libraryTracks.map { ($0.id, $0) })
        let playlistTracks = playlist.trackIDs.compactMap { tracksByID[$0] }
        return HStack(spacing: 12) {
            PlaylistArtworkView(tracks: playlistTracks).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name.isEmpty ? "Untitled Playlist" : playlist.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text("\(playlistTracks.count) songs").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func libraryRow(title: String, subtitle: String, artwork: Data?, symbol: String) -> some View {
        HStack(spacing: 12) {
            PodBridgeArtworkView(data: artwork, symbol: symbol).frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "Unknown" : title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle.isEmpty ? "Unknown Artist" : subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }.padding(.vertical, 8).contentShape(Rectangle())
    }
}

struct PodBridgeOperationProgressView: View {
    @ObservedObject var model: MusicTransferViewModel

    var body: some View {
        if model.isExporting {
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: Double(model.exportedCount), total: Double(max(1, model.exportTotalCount)))
                Text("Copying \(model.exportedCount) of \(model.exportTotalCount) songs to Files" + (model.operationETA.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let progress = model.deletionProgress {
            VStack(alignment: .leading, spacing: 5) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                } else {
                    ProgressView()
                }
                Text(progress.stage + (progress.total > 0 ? " · \(progress.completed) of \(progress.total)" : "") + (model.operationETA.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else if let message = model.resultMessage {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct PodBridgeExportButton: View {
    @ObservedObject var model: MusicTransferViewModel
    let tracks: [ClassicTrack]
    let title: String
    @State private var choosingFolder = false

    var body: some View {
        Button(title, systemImage: "square.and.arrow.up") { choosingFolder = true }
            .disabled(tracks.isEmpty || model.isExporting || model.isManagingLibrary || model.isCopying || model.isRestoring)
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder):
                    model.exportTracks(tracks, to: folder)
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
    }
}

struct TrackDetailView: View {
    @ObservedObject var model: MusicTransferViewModel
    let trackID: UInt32
    @State private var editingMetadata = false
    @State private var choosingArtwork = false
    @State private var showingArtworkSearch = false
    @State private var confirmingDeletion = false

    private var track: ClassicTrack? { model.libraryTracks.first { $0.id == trackID } }

    private var deleteButton: some View {
        Button("Delete from iPod", systemImage: "trash", role: .destructive) {
            confirmingDeletion = true
        }
        .disabled(model.isManagingLibrary || model.isExporting || model.isCopying || model.isRestoring)
    }

    var body: some View {
        Group {
            if let track {
                List {
                    PodBridgeOperationProgressView(model: model)
                    Section {
                        HStack(spacing: 16) {
                            PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                                .frame(width: 92, height: 92)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.title.isEmpty ? "Unknown Song" : track.title).font(.title3.weight(.semibold))
                                Text(track.artist.isEmpty ? "Unknown Artist" : track.artist).foregroundStyle(.secondary)
                                Text(track.album.isEmpty ? "Unknown Album" : track.album).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Details") {
                        PodBridgeLabeledContent("Album") { Text(track.album.isEmpty ? "—" : track.album) }
                        PodBridgeLabeledContent("Artist") { Text(track.artist.isEmpty ? "—" : track.artist) }
                        PodBridgeLabeledContent("Album Artist") { Text(track.albumArtist.isEmpty ? "—" : track.albumArtist) }
                        PodBridgeLabeledContent("Genre") { Text(track.genre.isEmpty ? "—" : track.genre) }
                        PodBridgeLabeledContent("Track") { Text(track.trackNumber == 0 ? "—" : String(track.trackNumber)) }
                    }
                    Section("Artwork") {
                        Button("Choose artwork from Files", systemImage: "folder") { choosingArtwork = true }
                        Button("Find artwork online", systemImage: "photo.badge.magnifyingglass") { showingArtworkSearch = true }
                    }
                    if let album = model.libraryAlbums.first(where: { $0.tracks.contains(where: { $0.id == track.id }) }) {
                        Section {
                            NavigationLink(destination: AlbumDetailView(model: model, albumID: album.id)) {
                                Text("Open Album")
                            }
                        }
                    }
                    Section {
                        PodBridgeExportButton(model: model, tracks: [track], title: "Copy song to Files")
                        deleteButton
                    }
                }
                .navigationTitle("Song")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit") { editingMetadata = true }
                    }
                }
                .sheet(isPresented: $editingMetadata) {
                    TrackMetadataEditor(track: track) { update in
                        model.editTrackMetadata(track, update: update)
                    }
                }
                .sheet(isPresented: $showingArtworkSearch) {
                    OnlineArtworkPicker(target: .track(track)) { artwork in
                        model.setTrackArtwork(track, artwork: artwork)
                    }
                }
                .confirmationDialog(
                    "Delete this song from iPod?",
                    isPresented: $confirmingDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete \(track.title)", role: .destructive) {
                        model.deleteTrackPermanently(track)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This removes the audio file and its library entry. Approximately \(ByteCountFormatter.string(fromByteCount: Int64(track.byteCount), countStyle: .file)) will be freed.")
                }
                .fileImporter(
                    isPresented: $choosingArtwork,
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        if let url = urls.first { model.setTrackArtwork(track, imageURL: url) }
                    case .failure(let error):
                        model.errorMessage = error.localizedDescription
                    }
                }
            } else {
                PodBridgeUnavailableView("Song no longer exists", systemImage: "music.note")
            }
        }
    }
}

struct ArtistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let artist: String
    @State private var confirmingDeletion = false

    private var tracks: [ClassicTrack] { model.libraryTracks.filter { $0.artist == artist } }

    private var albums: [IPodAlbum] {
        model.libraryAlbums.filter { $0.artist == artist || $0.tracks.contains(where: { $0.artist == artist }) }
    }

    var body: some View {
        List {
            PodBridgeOperationProgressView(model: model)
            Section {
                Text("\(albums.count) \(albums.count == 1 ? "album" : "albums") · \(model.libraryTracks.filter { $0.artist == artist }.count) songs")
                    .foregroundStyle(.secondary)
                PodBridgeExportButton(model: model, tracks: tracks, title: "Copy artist to Files")
                Button("Delete artist from iPod", systemImage: "trash", role: .destructive) {
                    confirmingDeletion = true
                }
                .disabled(tracks.isEmpty || model.isManagingLibrary || model.isExporting || model.isCopying || model.isRestoring)
            }
            Section("Albums") {
                ForEach(albums) { album in
                    NavigationLink(destination: AlbumDetailView(model: model, albumID: album.id)) {
                        HStack(spacing: 12) {
                            PodBridgeArtworkView(data: album.tracks.first(where: { $0.artworkData != nil })?.artworkData, symbol: "opticaldisc.fill")
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(album.title.isEmpty ? "Unknown Album" : album.title).foregroundStyle(.primary)
                                Text("\(album.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(artist)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Permanently delete this artist?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete \(tracks.count) songs", role: .destructive) {
                model.deleteArtistPermanently(artist)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only songs credited to \(artist) will be removed. This cannot be undone.")
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MusicTransferViewModel
    let playlistIndex: Int
    @State private var renaming = false
    @State private var confirmingDeletion = false
    @State private var editingSongs = false

    private var playlist: ClassicPlaylist? {
        model.libraryPlaylists.indices.contains(playlistIndex) ? model.libraryPlaylists[playlistIndex] : nil
    }

    private var tracks: [ClassicTrack] {
        guard let playlist else { return [] }
        let tracksByID = Dictionary(uniqueKeysWithValues: model.libraryTracks.map { ($0.id, $0) })
        return playlist.trackIDs.compactMap { tracksByID[$0] }
    }

    var body: some View {
        Group {
            if let playlist {
                List {
                    Section {
                        Text("\(tracks.count) songs").foregroundStyle(.secondary)
                    }
                    Section("Songs") {
                        ForEach(tracks) { track in
                            NavigationLink(destination: TrackDetailView(model: model, trackID: track.id)) {
                                HStack(spacing: 12) {
                                    PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).foregroundStyle(.primary)
                                        Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Delete playlist", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    }
                }
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Edit") {
                            Button("Rename Playlist", systemImage: "pencil") { renaming = true }
                            Button("Edit Songs", systemImage: "music.note.list") { editingSongs = true }
                        }
                    }
                }
                .sheet(isPresented: $renaming) {
                    PlaylistRenameEditor(
                        target: PlaylistRenameTarget(index: playlistIndex, playlist: playlist)
                    ) { name in
                        model.renamePlaylist(at: playlistIndex, to: name)
                    }
                }
                .sheet(isPresented: $editingSongs) {
                    PlaylistMembersEditor(tracks: model.libraryTracks, playlist: playlist) { trackIDs in
                        model.replacePlaylistMembers(at: playlistIndex, trackIDs: trackIDs)
                        editingSongs = false
                        dismiss()
                    }
                }
                .confirmationDialog(
                    "Delete this playlist?",
                    isPresented: $confirmingDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete playlist only", role: .destructive) {
                        model.deletePlaylist(at: playlistIndex, includingSongs: false)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Its songs will remain on the iPod.")
                }
            } else {
                PodBridgeUnavailableView("Playlist no longer exists", systemImage: "music.note.list")
            }
        }
    }
}

struct PlaylistMembersEditor: View {
    @Environment(\.dismiss) private var dismiss
    let tracks: [ClassicTrack]
    let playlist: ClassicPlaylist
    let save: ([UInt32]) -> Void
    @State private var selectedIDs: [UInt32]
    @State private var searchText = ""
    @State private var confirmingEmptyPlaylist = false

    init(tracks: [ClassicTrack], playlist: ClassicPlaylist, save: @escaping ([UInt32]) -> Void) {
        self.tracks = tracks
        self.playlist = playlist
        self.save = save
        _selectedIDs = State(initialValue: playlist.trackIDs)
    }

    private var tracksByID: [UInt32: ClassicTrack] { Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }) }
    private var selectedTracks: [ClassicTrack] { selectedIDs.compactMap { tracksByID[$0] } }
    private var availableTracks: [ClassicTrack] {
        let selected = Set(selectedIDs)
        return tracks.filter {
            !selected.contains($0.id) && (searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || $0.album.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section("Playlist Order") {
                    ForEach(selectedTracks) { track in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { selectedIDs.removeAll { $0 == track.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(track.title) from playlist")
                        }
                    }
                    .onMove { selectedIDs.move(fromOffsets: $0, toOffset: $1) }
                }
                if !availableTracks.isEmpty {
                    Section("Add Songs") {
                        ForEach(availableTracks) { track in
                            Button {
                                selectedIDs.append(track.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title).foregroundStyle(.primary)
                                        Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                }
                            }
                            .accessibilityLabel("Add \(track.title) to playlist")
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Add a song")
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if selectedIDs.isEmpty { confirmingEmptyPlaylist = true }
                        else { save(selectedIDs) }
                    }
                    .disabled(selectedIDs == playlist.trackIDs)
                }
            }
            .confirmationDialog("Save an empty playlist?", isPresented: $confirmingEmptyPlaylist, titleVisibility: .visible) {
                Button("Keep Empty Playlist") { save([]) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The playlist will remain on the iPod without songs. You can also cancel and delete the playlist from its page.")
            }
        }
    }
}

struct PodBridgeArtworkView: View {
    let data: Data?
    let symbol: String

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.12), Color(white: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol).font(.system(size: 24, weight: .medium)).foregroundStyle(.white.opacity(0.82))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct PlaylistArtworkView: View {
    let tracks: [ClassicTrack]

    var body: some View {
        let covers = Array(tracks.prefix(4))
        ZStack {
            if covers.isEmpty {
                PodBridgeArtworkView(data: nil, symbol: "music.note.list")
            } else {
                GeometryReader { proxy in
                    let side = proxy.size.width / 2
                    ForEach(Array(covers.enumerated()), id: \.offset) { index, track in
                        PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                            .frame(width: side, height: side)
                            .offset(x: index % 2 == 0 ? 0 : side, y: index < 2 ? 0 : side)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
