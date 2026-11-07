import SwiftUI

/// iOS Library tab root (on the Mac these are sidebar entries).
struct LibraryView: View {
    @Environment(Library.self) var lib
    @Environment(Router.self) var router
    @Environment(Downloads.self) var dl
    var body: some View {
        List {
            Section {
                ForEach(LibrarySection.allCases) { s in
                    NavigationLink(value: Route.library(s)) {
                        Label { Text(s.rawValue).font(.title3) } icon: { Image(systemName: s.icon).foregroundStyle(.tint) }
                            .padding(.vertical, 4)
                    }
                }
            }
            .listRowBackground(Color.clear)
            if !lib.recentlyAdded.isEmpty || !lib.allPlaylists.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
                        ForEach((lib.recentlyAdded + lib.allPlaylists).uniqueByID.prefix(24)) { CollectionCard(c: $0, size: 160) }
                    }.padding(.vertical, 8)
                } header: { Text("Recently Added").font(.title2.bold()).foregroundStyle(.primary).textCase(nil) }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(.black)
        .navigationTitle("Library")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { router.newPlaylistTracks = [] } label: { Label("New Playlist", systemImage: "music.note.list") }
                    Button { router.smartEdit = SmartEdit() } label: { Label("New Smart Playlist", systemImage: "gearshape.2") }
                } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
        }
        #endif
        .refreshable { await lib.refreshSpotify() }
    }
}

extension Array where Element == Collection {
    var uniqueByID: [Collection] { var s = Set<String>(); return filter { s.insert($0.id).inserted } }
}

struct LibrarySectionView: View {
    let section: LibrarySection
    var body: some View {
        switch section {
        case .songs: CollectionView(c: .favorites)
        case .downloaded: CollectionView(c: .downloads)
        case .recent: CollectionView(c: .history)
        case .playlists, .albums, .artists: CollectionGrid(section: section)
        }
    }
}

/// Playlists / Albums / Artists grids with sorting and filtering.
struct CollectionGrid: View {
    enum Sort: String, CaseIterable { case recent = "Recently Added", title = "Title", subtitle = "Artist / Owner" }
    let section: LibrarySection
    @Environment(Library.self) var lib
    @Environment(Router.self) var router
    @State private var filter = ""
    @AppStorage private var sortRaw: String

    init(section: LibrarySection) {
        self.section = section
        _sortRaw = AppStorage(wrappedValue: Sort.recent.rawValue, "libsort." + section.rawValue)
    }

    private var items: [Collection] {
        var base: [Collection] = switch section {
        case .albums: lib.albums
        case .artists: lib.artists
        default: [Collection(id: "liked", title: "Liked Songs", subtitle: "Spotify", kind: "playlist")].filter { _ in !lib.spotifyPlaylists.isEmpty }
            + [.favorites] + lib.allPlaylists.filter { $0.id != "liked" }
        }
        let f = filter.lowercased()
        if !f.isEmpty { base = base.filter { "\($0.title) \($0.subtitle ?? "")".lowercased().contains(f) } }
        switch Sort(rawValue: sortRaw) ?? .recent {
        case .recent: return base
        case .title: return base.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .subtitle: return base.sorted { ($0.subtitle ?? "").localizedCaseInsensitiveCompare($1.subtitle ?? "") == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            if section == .playlists {
                HStack(spacing: 24) {
                    Button { router.newPlaylistTracks = [] } label: { Label("New Playlist", systemImage: "plus.square.fill") }
                    Button { router.smartEdit = SmartEdit() } label: { Label("New Smart Playlist", systemImage: "gearshape.2.fill") }
                    Spacer()
                }.font(.headline).buttonStyle(.plain).foregroundStyle(.tint).padding(.horizontal, Theme.gutter).padding(.top, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: section == .artists ? 130 : 160), spacing: 18, alignment: .top)], spacing: 22) {
                ForEach(items) { CollectionCard(c: $0, size: section == .artists ? 130 : 160) }
            }
            .padding(Theme.gutter)
            if items.isEmpty {
                EmptyState(title: filter.isEmpty ? "No \(section.rawValue) Yet" : "No Matches", icon: section.icon,
                           message: filter.isEmpty ? (section == .playlists ? "Create one, or log in to Spotify to see yours." : "Use “Add to Library” on any \(section == .albums ? "album" : "artist") page.") : nil)
            }
            if lib.refreshing { ProgressView().padding() }
            if let e = lib.spotifyError, items.isEmpty { Text(e).font(.footnote).foregroundStyle(.secondary).padding() }
        }
        .scrollContentBackground(.hidden).background(.black)
        .navigationTitle(section.rawValue)
        #if os(iOS)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find in \(section.rawValue)")
        #else
        .searchable(text: $filter, placement: .toolbar, prompt: "Find in \(section.rawValue)")
        #endif
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sortRaw) {
                        ForEach(Sort.allCases, id: \.self) { Text($0 == .subtitle && section == .playlists ? "Owner" : $0 == .subtitle ? "Artist" : $0.rawValue).tag($0.rawValue) }
                    }.pickerStyle(.inline)
                    Button { Task { await lib.refreshSpotify() } } label: { Label("Refresh from Spotify", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .refreshable { await lib.refreshSpotify() }
    }
}

struct AddToPlaylistSheet: View {
    let tracks: [Track]
    @Environment(Library.self) var lib
    @Environment(Router.self) var router
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Button { dismiss(); router.newPlaylistTracks = tracks } label: { Label("New Playlist…", systemImage: "plus") }
                ForEach(lib.editablePlaylists) { p in
                    Button {
                        let n = lib.add(tracks, to: p.id)
                        router.flash(n > 0 ? "Added \(n) song\(n == 1 ? "" : "s") to \(p.name)" : "Already in \(p.name)")
                        dismiss()
                    } label: {
                        HStack { CollectionArt(c: lib.collection(p), size: 40); Text(p.name); Spacer(); Text("\(p.items.count)").foregroundStyle(.secondary) }
                    }.buttonStyle(.plain)
                }
            }
            .navigationTitle("Add \(tracks.count) Song\(tracks.count == 1 ? "" : "s")")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }
}
