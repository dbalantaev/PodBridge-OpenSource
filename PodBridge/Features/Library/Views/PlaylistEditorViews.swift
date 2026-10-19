// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct PlaylistRenameTarget: Identifiable {
    let index: Int
    let playlist: ClassicPlaylist

    var id: Int { index }
}

struct PlaylistComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let tracks: [ClassicTrack]
    let save: (String, [UInt32]) -> Void
    @State private var name = ""
    @State private var searchText = ""
    @State private var selectedIDs: [UInt32] = []

    private var selected: Set<UInt32> { Set(selectedIDs) }
    private var filteredTracks: [ClassicTrack] {
        guard !searchText.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || $0.album.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section("Playlist") {
                    TextField("Name", text: $name)
                    Text("\(selectedIDs.count) songs selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Songs") {
                    ForEach(filteredTracks) { track in
                        Button {
                            toggle(track.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(track.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).foregroundStyle(.primary)
                                    Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Song, artist, or album")
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines), selectedIDs)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedIDs.isEmpty)
                }
            }
        }
    }

    private func toggle(_ id: UInt32) {
        if let index = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: index) }
        else { selectedIDs.append(id) }
    }
}

struct PlaylistRenameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: PlaylistRenameTarget
    let save: (String) -> Void
    @State private var name: String

    init(target: PlaylistRenameTarget, save: @escaping (String) -> Void) {
        self.target = target
        self.save = save
        _name = State(initialValue: target.playlist.name)
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Playlist name", text: $name)
            }
            .navigationTitle("Rename Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct TrackMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let track: ClassicTrack
    let save: (ClassicDatabase.TrackMetadataUpdate) -> Void
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var genre: String
    @State private var year: String
    @State private var trackNumber: String

    init(track: ClassicTrack, save: @escaping (ClassicDatabase.TrackMetadataUpdate) -> Void) {
        self.track = track
        self.save = save
        _title = State(initialValue: track.title)
        _artist = State(initialValue: track.artist)
        _album = State(initialValue: track.album)
        _genre = State(initialValue: track.genre)
        _year = State(initialValue: track.year == 0 ? "" : String(track.year))
        _trackNumber = State(initialValue: track.trackNumber == 0 ? "" : String(track.trackNumber))
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Metadata") {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Genre", text: $genre)
                }
                Section("Track details") {
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Track number", text: $trackNumber).keyboardType(.numberPad)
                }
                Section {
                    Text("The audio file is not transcoded. PodBridge updates the iPod database, album/artist links, and Apple sort indexes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(ClassicDatabase.TrackMetadataUpdate(
                            title: title,
                            artist: artist,
                            album: album,
                            genre: genre,
                            year: UInt32(year) ?? 0,
                            trackNumber: UInt32(trackNumber) ?? 0,
                            albumArtist: track.albumArtist,
                            compilation: track.compilation
                        ))
                        dismiss()
                    }
                    .disabled(requiredFieldsAreEmpty)
                }
            }
        }
    }

    private var requiredFieldsAreEmpty: Bool {
        [title, artist, album].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
