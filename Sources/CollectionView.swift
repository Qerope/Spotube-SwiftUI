import SwiftUI

enum TrackSort: String, CaseIterable, Identifiable {
    case original = "Default Order", title = "Title", artist = "Artist", album = "Album", added = "Date Added", duration = "Duration", popularity = "Popularity"
    var id: String { rawValue }
}

/// Album, playlist (Spotify or yours), Liked Songs, Favorites, Downloaded, Recently Played, mixes.
struct CollectionView: View {
    let c: Collection
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Downloads.self) var dl
    @Environment(Router.self) var router
    @Environment(PluginManager.self) var pm
    @State private var remote: CollectionDetails?
    @State private var err: String?
    @State private var loading = false
    @State private var filter = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var tint: Color?
    @AppStorage private var sortRaw: String
    @AppStorage private var ascending: Bool

    init(c: Collection) {
        self.c = c
        let k = "sort." + (c.type == .album ? "album" : c.id.hasPrefix("spotify:") || c.id == "liked" ? "playlist" : c.id.split(separator: ":").first.map(String.init) ?? c.id)
        _sortRaw = AppStorage(wrappedValue: TrackSort.original.rawValue, k)
        _ascending = AppStorage(wrappedValue: true, k + ".asc")
    }

    private var isLive: Bool { [.local, .favorites, .downloads, .history].contains(c.type) }
    private var details: CollectionDetails? {
        switch c.type {
        case .local:
            guard let p = lib.playlists[c.id] else { return nil }
            return CollectionDetails(title: p.name, subtitle: p.isSmart ? smartSummary(p) : "Your Playlist", description: p.notes, tracks: lib.tracks(p))
        case .favorites: return CollectionDetails(title: c.title, subtitle: "Songs you love", tracks: lib.favorites)
        case .downloads: return CollectionDetails(title: c.title, subtitle: "\(dl.totalBytes.bytes) on this device", tracks: dl.tracks)
        case .history: return CollectionDetails(title: c.title, subtitle: "On this device", tracks: player.history)
        default: return remote
        }
    }
    private var tracks: [Track] { details?.tracks ?? [] }
    private var title: String { details?.title ?? c.title }
    private var art: String? { details?.art ?? c.art }
    private var sort: TrackSort { TrackSort(rawValue: sortRaw) ?? .original }
    private var isAlbum: Bool { c.type == .album }
    private var smart: Playlist? { lib.playlists[c.id].flatMap { $0.isSmart ? $0 : nil } }
    private var editable: Bool { c.type == .local && smart == nil }
    private var canReorder: Bool { editable && sort == .original && filter.isEmpty }
    private func smartSummary(_ p: Playlist) -> String {
        guard let r = p.smart else { return "" }
        let n = r.rules.count
        return n == 0 ? "All songs · \(r.order.rawValue)" : "\(n) rule\(n == 1 ? "" : "s") · \(r.order.rawValue)"
    }

    private var shown: [Track] {
        var t = tracks
        let f = filter.lowercased().split(separator: " ").map(String.init)
        if !f.isEmpty { t = t.filter { x in f.allSatisfy { "\(x.title) \(x.artist) \(x.album ?? "")".lowercased().contains($0) } } }
        let up = ascending
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Bool { up ? a < b : a > b }
        switch sort {
        case .original: if !up { t.reverse() }
        case .title: t.sort { cmp($0.title.lowercased(), $1.title.lowercased()) }
        case .artist: t.sort { cmp($0.artist.lowercased() + $0.album.orEmpty, $1.artist.lowercased() + $1.album.orEmpty) }
        case .album: t.sort { cmp($0.album.orEmpty.lowercased() + String(format: "%03d", $0.trackNumber ?? 0), $1.album.orEmpty.lowercased() + String(format: "%03d", $1.trackNumber ?? 0)) }
        case .added: t.sort { cmp(addedAt($0) ?? .distantPast, addedAt($1) ?? .distantPast) }
        case .duration: t.sort { cmp($0.duration ?? 0, $1.duration ?? 0) }
        case .popularity: t.sort { cmp($0.plays ?? 0, $1.plays ?? 0) }
        }
        return t
    }
    private func addedAt(_ t: Track) -> Date? {
        switch c.type {
        case .favorites: lib.likedAt(t)
        case .downloads: dl.items[t.id]?.at
        case .local: lib.playlists[c.id]?.items.first { $0.track.id == t.id }?.added
        default: t.addedAt
        }
    }
    private var context: PlayContext { PlayContext(id: c.id, title: title, art: art ?? tracks.mosaic.first) }

    var body: some View {
        List {
            header.listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            if tracks.isEmpty {
                Group {
                    if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    else if let err { errorView(err) }
                    else { emptyView }
                }.listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                TrackRow(t: t, number: isAlbum && sort == .original ? (t.trackNumber ?? i + 1) : nil, showArt: !isAlbum || sort != .original,
                         showAlbum: !isAlbum, playlistID: editable ? c.id : nil) {
                    player.play(shown, at: i, context: context)
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: Theme.gutter - 4, bottom: 3, trailing: Theme.gutter - 4))
            }
            .onMove(perform: canReorder ? { lib.move(in: c.id, from: $0, to: $1) } : nil)
            .onDelete(perform: editable ? { s in lib.remove(Set(s.map { shown[$0].id }), from: c.id) } : c.type == .downloads ? { s in dl.remove(s.map { shown[$0].id }) } : nil)
            footer.listRowSeparator(.hidden).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(alignment: .top) {
            LinearGradient(colors: [(tint ?? .clear).opacity(0.55), .black], startPoint: .top, endPoint: .bottom).frame(height: 520).ignoresSafeArea()
        }
        .background(.black)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find in \(noun)")
        #else
        .searchable(text: $filter, placement: .toolbar, prompt: "Find in \(noun)")
        #endif
        .toolbar {
            ToolbarItem { sortMenu }
            ToolbarItem { Menu { moreMenu } label: { Image(systemName: "ellipsis.circle") } }
        }
        .task(id: "\(c.id)|\(pm.revision)") { await load() }
        .task(id: art) {
            if let h = details?.color ?? c.color, let col = Color(hex: h) { tint = col }
            else if let a = art { tint = await ImageStore.shared.color(a) }
        }
        .refreshable { await load() }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { lib.rename(c.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(title)”?", isPresented: $confirmDelete) {
            Button("Delete Playlist", role: .destructive) { lib.deletePlaylist(c.id); router.paths[router.tab] = NavigationPath(); router.sidebar = .home }
        } message: { Text("This removes it from all your devices.") }
    }

    private var noun: String { isAlbum ? "Album" : c.type == .favorites || c.type == .downloads ? "Songs" : "Playlist" }

    // MARK: Header

    @ViewBuilder private var header: some View {
        #if os(macOS)
        HStack(alignment: .bottom, spacing: 24) {
            CollectionArt(c: Collection(id: c.id, title: title, art: art, kind: c.kind, mosaic: c.mosaic ?? (c.type == .mix || isLive ? tracks.mosaic : nil)), size: 210)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            VStack(alignment: .leading, spacing: 8) {
                Text(kindLabel.uppercased()).font(.caption.weight(.bold)).foregroundStyle(.secondary)
                Text(title).font(.system(size: 34, weight: .bold)).lineLimit(2)
                subtitleLink.font(.title3)
                metaLine
                if let d = details?.description, !d.isEmpty { Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 14) { PlayButtons(tracks: shown, context: context); actions }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.gutter).padding(.top, 8)
        #else
        VStack(spacing: 10) {
            CollectionArt(c: Collection(id: c.id, title: title, art: art, kind: c.kind, mosaic: c.mosaic ?? (c.type == .mix || isLive ? tracks.mosaic : nil)), size: 250)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10).padding(.top, 8)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            subtitleLink.font(.title3)
            metaLine
            if let d = details?.description, !d.isEmpty { Text(d).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3) }
            PlayButtons(tracks: shown, context: context).padding(.top, 4)
            actions.padding(.top, 2)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, Theme.gutter).padding(.bottom, 8)
        #endif
    }

    private var kindLabel: String {
        switch c.type {
        case .album: (details?.kind ?? c.kind ?? "album").capitalized
        case .local: smart != nil ? "Smart Playlist" : "Your Playlist"
        case .mix: "Mix"
        case .favorites, .downloads, .history: "Library"
        default: "Playlist"
        }
    }

    @ViewBuilder private var subtitleLink: some View {
        if let s = details?.subtitle ?? c.subtitle, !s.isEmpty {
            if let a = details?.artistId {
                Button { router.open(Collection(id: a, title: s, subtitle: "Artist", kind: "artist")) } label: { Text(s).foregroundStyle(.tint) }.buttonStyle(.plain)
            } else { Text(s).foregroundStyle(.tint) }
        }
    }

    private var metaLine: some View {
        let parts = [isAlbum ? details?.year : nil, details?.followers.map { "\($0.compact) saves" }, tracks.isEmpty ? nil : tracks.summary].compactMap { $0 }
        return Text(parts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 22) {
            if [.album, .playlist, .spotifyLiked].contains(c.type), !lib.isSavedInSpotify(c) {
                let col = Collection(id: c.id, title: title, subtitle: details?.subtitle ?? c.subtitle, art: art, kind: c.kind ?? details?.kind, color: details?.color)
                Button { lib.toggleSave(col); router.flash(lib.isSaved(col) ? "Added to Library" : "Removed from Library") } label: {
                    Image(systemName: lib.isSaved(c) ? "checkmark.circle.fill" : "plus.circle")
                }.help(lib.isSaved(c) ? "In your library" : "Add to Library")
            }
            DownloadButton(tracks: tracks)
            if let u = c.shareURL { ShareLink(item: u) { Image(systemName: "square.and.arrow.up") } }
            Menu { moreMenu } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden).fixedSize()
        }
        .font(.title2).buttonStyle(.borderless).foregroundStyle(.tint)
    }

    @ViewBuilder private var moreMenu: some View {
        Button { player.playNext(shown); router.flash("Playing next") } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(shown); router.flash("Added to queue") } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button { router.addToPlaylist = shown } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        Button { router.newPlaylistTracks = shown } label: { Label("Save as New Playlist…", systemImage: "plus.square.on.square") }
        if let p = smart {
            Divider()
            Button { router.smartEdit = SmartEdit(playlist: p) } label: { Label("Edit Rules…", systemImage: "slider.horizontal.3") }
        }
        if c.type == .local {
            Divider()
            Button { newName = title; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
        }
        if c.type == .history { Button(role: .destructive) { player.clearHistory() } label: { Label("Clear History", systemImage: "trash") } }
        if c.type == .downloads, !tracks.isEmpty { Button(role: .destructive) { dl.removeAll() } label: { Label("Remove All Downloads", systemImage: "trash") } }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sortRaw) {
                ForEach(TrackSort.allCases.filter { $0 != .popularity || isAlbum }) { s in
                    Text(s == .original ? (isAlbum ? "Album Order" : c.type == .favorites || c.type == .history ? "Recent First" : "Playlist Order") : s.rawValue).tag(s.rawValue)
                }
            }.pickerStyle(.inline)
            Picker("Order", selection: $ascending) {
                Text(sort == .original ? "Normal" : sort == .added || sort == .duration || sort == .popularity ? "Lowest / Oldest First" : "A → Z").tag(true)
                Text(sort == .original ? "Reversed" : sort == .added || sort == .duration || sort == .popularity ? "Highest / Newest First" : "Z → A").tag(false)
            }.pickerStyle(.inline)
        } label: { Image(systemName: "arrow.up.arrow.down") }
        .help("Sort")
    }

    // MARK: Footer / states

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isAlbum, let d = details {
                VStack(alignment: .leading, spacing: 3) {
                    if let y = d.year { Text(y) }
                    Text(tracks.summary)
                    if let l = d.label { Text(l) }
                    if let cp = d.copyright, !cp.isEmpty { Text(cp).lineLimit(2) }
                }.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter)
                if let more = d.more, !more.isEmpty {
                    Shelf(title: "More by \(d.subtitle ?? "this artist")") { ForEach(more) { CollectionCard(c: $0, size: 140) } }
                }
            } else if !tracks.isEmpty, !isAlbum {
                Text(tracks.summary).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter)
            }
        }.padding(.vertical, 20).padding(.bottom, 20)
    }

    private func errorView(_ e: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
        } description: { Text(e).textSelection(.enabled) } actions: { Button("Try Again") { Task { await load() } } }
    }

    @ViewBuilder private var emptyView: some View {
        switch c.type {
        case .favorites: EmptyState(title: "No Favorite Songs", icon: "heart", message: "Tap ♥ on any song to add it here. Favorites sync to all your devices.")
        case .downloads: EmptyState(title: "Nothing Downloaded", icon: "arrow.down.circle", message: "Download songs, albums or playlists to listen offline.")
        case .local:
            if let p = smart {
                ContentUnavailableView {
                    Label("No Matching Songs", systemImage: "gearshape.2")
                } description: { Text("Nothing matches these rules yet. It fills up as you listen and love songs.") } actions: {
                    Button("Edit Rules…") { router.smartEdit = SmartEdit(playlist: p) }
                }
            } else { EmptyState(title: "Empty Playlist", icon: "music.note.list", message: "Add songs from any “…” menu → Add to Playlist.") }
        case .history: EmptyState(title: "Nothing Played Yet", icon: "clock")
        default: if details != nil { EmptyState(title: "No Songs", icon: "music.note") }
        }
    }

    private func load() async {
        if smart != nil { await PlayCounts.shared.refresh() }
        guard !isLive else { return }
        if remote == nil { remote = Catalog.cached(c) }
        loading = true; defer { loading = false }
        do { remote = try await Catalog.details(c); err = nil }
        catch { if remote == nil { err = error.localizedDescription } }
    }
}

extension Optional where Wrapped == String { var orEmpty: String { self ?? "" } }
