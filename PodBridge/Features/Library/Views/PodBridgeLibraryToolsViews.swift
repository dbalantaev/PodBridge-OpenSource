// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Dmitry Balantaev

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct PodBridgeLibraryToolsView: View {
    @ObservedObject var model: MusicTransferViewModel
    @State private var choosingLibraryJSON = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                NavigationLink { LibraryDoctorView(model: model) } label: {
                    tool("Library Doctor", "Find and fix metadata, artwork and duplicate tracks", "stethoscope", .mint)
                }
                Button { model.findMissingArtwork() } label: {
                    tool("Fix Missing Artwork", "Find and apply covers for \(model.missingArtworkTrackCount) tracks", "photo", .pink)
                }
                .disabled(model.automaticArtworkCandidateCount == 0 || model.isManagingLibrary)
                NavigationLink { DuplicateReviewView(model: model) } label: {
                    tool("Duplicates", "Review possible duplicate tracks", "doc.on.doc", .blue)
                }
                NavigationLink { MetadataIssuesView(model: model) } label: {
                    tool("Fix Metadata", "Review incomplete artist, album and genre fields", "tag.fill", .purple)
                }
                Button { choosingLibraryJSON = true } label: {
                    tool("Restore PodBridge Export", "Import ratings, play counts, skips, dates and playlists from JSON", "arrow.uturn.backward.circle", .orange)
                }
                .disabled(model.isManagingLibrary || model.isExporting || model.isCopying || model.isRestoring)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Library Tools")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $choosingLibraryJSON,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                model.importLibraryJSON(url)
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func tool(_ title: String, _ subtitle: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct LibraryDoctorView: View {
    @ObservedObject var model: MusicTransferViewModel
    @State private var repairCompletion: LibraryRepairCompletion?

    private var duplicateGroups: [[ClassicTrack]] { duplicateTrackGroups(model.libraryTracks) }
    private var metadataIssues: [ClassicTrack] { metadataIssueTracks(model.libraryTracks) }
    private var brokenAlbums: Int { brokenAlbumGroups(model.libraryAlbums).count }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PodBridgeCelebrationMark(markSize: 56, height: 120)
                    .padding(.top, 8)
                VStack(spacing: 4) {
                    Text("Scan Complete").font(.title2.bold())
                    Text("\(model.libraryTracks.count) tracks analyzed").foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    doctorRow(duplicateGroups.count, "Possible duplicates", "doc.on.doc", .red)
                    Divider().padding(.leading, 52)
                    doctorRow(model.missingArtworkTrackCount, "Missing artwork", "photo", .orange)
                    Divider().padding(.leading, 52)
                    doctorRow(metadataIssues.count, "Metadata issues", "tag", .blue)
                    Divider().padding(.leading, 52)
                    doctorRow(brokenAlbums, "Broken album groups", "rectangle.stack", .purple)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                NavigationLink { LibraryIssueReviewView(model: model) } label: {
                    Text("Review Issues")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                if model.safeAlbumRepairCount > 0 || model.missingArtworkTrackCount > 0 {
                    Button {
                        model.fixAllSafeLibraryIssues()
                    } label: {
                        Label("Fix All Safe Issues", systemImage: "wand.and.stars")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isManagingLibrary)
                    Text("Repairs missing artwork and consistent album grouping only. Possible duplicates are never deleted automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Library Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.libraryRepairCompletion?.id) {
            repairCompletion = model.libraryRepairCompletion
        }
        .alert("Library Updated", isPresented: Binding(
            get: { repairCompletion != nil },
            set: { if !$0 { repairCompletion = nil } }
        )) {
            Button("Done", role: .cancel) { repairCompletion = nil }
        } message: {
            if let repairCompletion {
                Text(repairSuccessMessage(repairCompletion))
            }
        }
    }

    private func doctorRow(_ count: Int, _ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color.opacity(0.14)).frame(width: 32, height: 32)
                .overlay(Image(systemName: icon).font(.caption.bold()).foregroundStyle(color))
            Text(count.formatted()).font(.headline.monospacedDigit()).fixedSize(horizontal: true, vertical: false)
            Text(title); Spacer()
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func repairSuccessMessage(_ completion: LibraryRepairCompletion) -> String {
        var parts: [String] = []
        if completion.repairedAlbumGroups > 0 {
            parts.append("Fixed \(completion.repairedAlbumGroups) album groups")
        }
        if completion.restoredEmbeddedArtwork > 0 {
            parts.append("restored \(completion.restoredEmbeddedArtwork) embedded covers")
        }
        if completion.addedOnlineArtwork > 0 {
            parts.append("found \(completion.addedOnlineArtwork) online covers")
        }
        return parts.isEmpty
            ? "No safe changes were needed. Possible duplicates were left untouched."
            : parts.joined(separator: ", ") + ". Possible duplicates were left untouched."
    }
}

struct LibraryIssueReviewView: View {
    @ObservedObject var model: MusicTransferViewModel
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NavigationLink { DuplicateReviewView(model: model) } label: { issueCard("Possible Duplicates", "\(duplicateTrackGroups(model.libraryTracks).count) groups", "doc.on.doc", .red) }
                Button { model.findMissingArtwork() } label: { issueCard("Fix Missing Artwork", "\(model.missingArtworkTrackCount) tracks without an iPod cover", "photo", .orange) }
                    .disabled(model.automaticArtworkCandidateCount == 0 || model.isManagingLibrary)
                NavigationLink { MetadataIssuesView(model: model) } label: { issueCard("Metadata Issues", "\(metadataIssueTracks(model.libraryTracks).count) tracks", "tag", .blue) }
                NavigationLink { BrokenAlbumGroupsView(model: model) } label: { issueCard("Broken Album Groups", "\(brokenAlbumGroups(model.libraryAlbums).count) groups", "rectangle.stack", .purple) }
            }.padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review Issues")
    }
    private func issueCard(_ title: String, _ subtitle: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 42, height: 42).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading) { Text(title).font(.headline).foregroundStyle(.primary); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding(14).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct BrokenAlbumGroupsView: View {
    @ObservedObject var model: MusicTransferViewModel
    private var groups: [[IPodAlbum]] { brokenAlbumGroups(model.libraryAlbums) }

    var body: some View {
        Group {
            if groups.isEmpty {
                PodBridgeUnavailableView(
                    "No Broken Album Groups",
                    systemImage: "checkmark.circle",
                    description: Text("Albums with the same title use consistent album artists.")
                )
            } else {
                List {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, albums in
                        Section(albums.first?.title.isEmpty == false ? albums.first!.title : "Unknown Album") {
                            ForEach(albums) { album in
                                BrokenAlbumRow(album: album, model: model)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Broken Albums")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MetadataIssuesView: View {
    @ObservedObject var model: MusicTransferViewModel
    private var tracks: [ClassicTrack] { metadataIssueTracks(model.libraryTracks) }
    var body: some View {
        Group {
            if tracks.isEmpty && model.safeAlbumRepairCount == 0 {
                PodBridgeUnavailableView("No Metadata Issues", systemImage: "checkmark.circle", description: Text("PodBridge did not find incomplete core metadata."))
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if model.safeAlbumRepairCount > 0 {
                            Button {
                                model.repairAlbumGrouping()
                            } label: {
                                Label("Fix All Safe Album Issues (\(model.safeAlbumRepairCount))", systemImage: "wand.and.stars")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isManagingLibrary)
                        }
                        LazyVStack(spacing: 0) {
                        ForEach(tracks) { track in
                            NavigationLink { MetadataIssueDetailView(model: model, trackID: track.id) } label: {
                                HStack(spacing: 12) {
                                    PodBridgeArtworkView(data: track.artworkData, symbol: "music.note").frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title.isEmpty ? "Missing title" : track.title).font(.headline).foregroundStyle(.primary)
                                        Text(track.artist.isEmpty ? "Missing artist" : track.artist).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                            if track.id != tracks.last?.id { Divider().padding(.leading, 74) }
                        }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(16)
                }
                .background(Color(.systemGroupedBackground))
            }
        }.navigationTitle("Fix Metadata")
         .navigationBarTitleDisplayMode(.inline)
    }
}

struct MetadataIssueDetailView: View {
    @ObservedObject var model: MusicTransferViewModel
    let trackID: UInt32
    private var track: ClassicTrack? { model.libraryTracks.first { $0.id == trackID } }
    var body: some View {
        ScrollView {
            if let track {
                VStack(spacing: 16) {
                    PodBridgeArtworkView(data: track.artworkData, symbol: "music.note").frame(width: 92, height: 92).padding(.top, 8)
                    VStack(spacing: 3) { Text(track.title.isEmpty ? "Unknown Track" : track.title).font(.title3.bold()); Text(track.artist.isEmpty ? "Unknown Artist" : track.artist).foregroundStyle(.secondary) }
                    metadataCard(title: "Current", track: track, suggested: false)
                    metadataCard(title: "Suggested", track: track, suggested: true)

                }.padding(20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Fix Metadata")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Apply") {
                    if let track {
                        model.editTrackMetadata(track, update: .init(title: track.title, artist: track.artist, album: track.album, genre: track.genre, year: track.year, trackNumber: track.trackNumber, albumArtist: track.artist, compilation: track.compilation))
                    }
                }
                .disabled(track?.artist.isEmpty != false || track?.albumArtist.isEmpty != true)
            }
        }
    }
    private func metadataCard(title: String, track: ClassicTrack, suggested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 10)
            valueRow("Artist", track.artist)
            Divider(); valueRow("Album Artist", suggested && track.albumArtist.isEmpty ? track.artist : track.albumArtist)
            Divider(); valueRow("Album", track.album)
            Divider(); valueRow("Genre", track.genre)
        }.padding(14).background(suggested ? Color.green.opacity(0.10) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func valueRow(_ key: String, _ value: String) -> some View { HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "—" : value).lineLimit(1) }.font(.subheadline).padding(.vertical, 10) }
}

struct DuplicateReviewView: View {
    @ObservedObject var model: MusicTransferViewModel
    private var groups: [[ClassicTrack]] { duplicateTrackGroups(model.libraryTracks) }
    var body: some View {
        Group {
            if groups.isEmpty {
                PodBridgeUnavailableView(
                    "No Duplicates Found",
                    systemImage: "checkmark.circle",
                    description: Text("No tracks share the same normalized artist, title, album, and album artist.")
                )
            } else {
                List(Array(groups.enumerated()), id: \.offset) { index, group in
                    NavigationLink(destination: DuplicateGroupView(model: model, groupKey: duplicateGroupKey(group.first))) {
                        HStack(spacing: 12) {
                            PodBridgeArtworkView(data: group.first?.artworkData, symbol: "doc.on.doc")
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.first?.title.isEmpty == false ? (group.first?.title ?? "") : "Unknown Song")
                                    .foregroundStyle(.primary)
                                Text(group.first?.artist.isEmpty == false ? group.first!.artist : "Unknown Artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(group.count) copies · review before deleting")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Duplicates")
    }
}

struct DuplicateGroupView: View {
    @ObservedObject var model: MusicTransferViewModel
    let groupKey: String
    @State private var trackToDelete: ClassicTrack?

    private var tracks: [ClassicTrack] {
        model.libraryTracks.filter { duplicateGroupKey($0) == groupKey }
            .sorted { $0.byteCount > $1.byteCount }
    }

    var body: some View {
        Group {
            if tracks.count < 2 {
                PodBridgeUnavailableView(
                    "Duplicate group updated",
                    systemImage: "checkmark.circle",
                    description: Text("There are no longer multiple matching copies.")
                )
            } else {
                List {
                    Section {
                        Text("PodBridge matched these songs within the same album and album artist. Review the size, duration and artwork before deleting anything. Nothing is removed automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("Copies") {
                        ForEach(tracks) { track in
                            HStack(spacing: 12) {
                                PodBridgeArtworkView(data: track.artworkData, symbol: "music.note")
                                    .frame(width: 52, height: 52)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.album.isEmpty ? "Unknown Album" : track.album)
                                        .foregroundStyle(.primary)
                                    Text(duplicateTechnicalSummary(track))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(duplicateMetadataSummary(track))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("Delete this copy", systemImage: "trash", role: .destructive) {
                                        trackToDelete = track
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, height: 36)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Review Copies")
                .navigationBarTitleDisplayMode(.inline)
                .confirmationDialog(
                    "Delete this copy from iPod?",
                    isPresented: Binding(get: { trackToDelete != nil }, set: { if !$0 { trackToDelete = nil } }),
                    titleVisibility: .visible
                ) {
                    if let track = trackToDelete {
                        Button("Delete \(track.title)", role: .destructive) {
                            trackToDelete = nil
                            model.deleteTrackPermanently(track)
                        }
                    }
                    Button("Cancel", role: .cancel) { trackToDelete = nil }
                } message: {
                    Text("The selected audio file and its iPod library entry will be removed. The other copies will remain.")
                }
            }
        }
    }
}

private func metadataIssueTracks(_ tracks: [ClassicTrack]) -> [ClassicTrack] {
    tracks.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private func duplicateTrackGroups(_ tracks: [ClassicTrack]) -> [[ClassicTrack]] {
    Dictionary(grouping: tracks) { duplicateGroupKey($0) }
        .values
        .filter { $0.count > 1 }
        .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
}

private func brokenAlbumGroups(_ albums: [IPodAlbum]) -> [[IPodAlbum]] {
    return Dictionary(grouping: albums.filter { !$0.title.isEmpty }) { normalizedLibraryText($0.title) }
        .values
        .filter { albums in
            guard albums.count > 1 else { return false }
            let artists = albums.map { normalizedLibraryText($0.artist) }.filter { !$0.isEmpty }
            guard Set(artists).count > 1 else { return false }
            return artists.contains { left in
                artists.contains { right in left != right && (left.contains(right) || right.contains(left)) }
            }
        }
        .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
}

private func duplicateGroupKey(_ track: ClassicTrack?) -> String {
    guard let track else { return "" }
    let albumArtist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
    return [track.artist, track.title, track.album, albumArtist]
        .map(normalizedLibraryText)
        .joined(separator: "\u{0}")
}

private func normalizedLibraryText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .lowercased()
}

private func duplicateTechnicalSummary(_ track: ClassicTrack) -> String {
    let minutes = track.durationMS / 60_000
    let seconds = (track.durationMS / 1_000) % 60
    let duration = String(format: "%u:%02u", minutes, seconds)
    let size = ByteCountFormatter.string(fromByteCount: Int64(track.byteCount), countStyle: .file)
    let bitrate = track.bitrate == 0 ? nil : "\(track.bitrate) kbps"
    return ([duration, bitrate, size].compactMap { $0 }).joined(separator: " · ")
}

private func duplicateMetadataSummary(_ track: ClassicTrack) -> String {
    let format = track.ipodPath.split(separator: ".").last.map { String($0).uppercased() }
        ?? track.fileType
    let number = track.trackNumber == 0 ? nil : "Track \(track.trackNumber)"
    let genre = track.genre.isEmpty ? nil : track.genre
    return ([format, number, genre].compactMap { $0 }).joined(separator: " · ")
}

private struct BrokenAlbumRow: View {
    let album: IPodAlbum
    @ObservedObject var model: MusicTransferViewModel

    var body: some View {
        NavigationLink(destination: AlbumDetailView(model: model, albumID: album.id)) {
            HStack(spacing: 12) {
                PodBridgeArtworkView(
                    data: album.tracks.first(where: { $0.artworkData != nil })?.artworkData,
                    symbol: "opticaldisc"
                )
                .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.artist.isEmpty ? "Unknown Album Artist" : album.artist)
                    Text("\(album.tracks.count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
