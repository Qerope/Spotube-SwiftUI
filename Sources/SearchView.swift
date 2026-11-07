import SwiftUI

struct SearchView: View {
    enum Scope: String, CaseIterable { case all = "Top Results", songs = "Songs", artists = "Artists", albums = "Albums", playlists = "Playlists", library = "Your Library" }
    @Environment(PluginManager.self) var pm
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Router.self) var router
    @Environment(Cloud.self) var cloud
    @State private var q = ""
    @State private var result: SearchResult?
    @State private var loading = false
    @State private var err: String?
    @State private var scope = Scope.all
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if q.trimmingCharacters(in: .whitespaces).isEmpty { idle } else { results }
            }.padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden).background(.black)
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Search")
        #if os(macOS)
        .searchable(text: $q, placement: .toolbar, prompt: "Artists, Songs, Albums, Playlists")
        #else
        .searchable(text: $q, prompt: "Artists, Songs, Albums, Playlists")
        #endif
        .searchFocused($focused)
        .onSubmit(of: .search) { remember(q) }
        .task(id: q) {
            let s = q.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { result = nil; err = nil; return }
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await search(s)
        }
        .onAppear {
            if let d = DebugRoute.query { q = d; DebugRoute.query = nil }
            if router.focusSearch { focused = true; router.focusSearch = false }
        }
        .onChange(of: router.focusSearch) { if router.focusSearch { focused = true; router.focusSearch = false } }
        .task {
            if cloud.enabled, let r = try? await cloud.recentSearches(), !r.isEmpty {
                recent = Array((recent + r.filter { !recent.contains($0) }).prefix(15))
            }
        }
    }

    // MARK: Idle: recent searches + library shortcuts

    @ViewBuilder private var idle: some View {
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Recently Searched").font(.title3.bold())
                    Spacer()
                    Button("Clear") { recent = []; UserDefaults.standard.set(recent, forKey: "recentSearches") }.buttonStyle(.borderless).foregroundStyle(.tint)
                }
                ForEach(recent, id: \.self) { s in
                    Button { q = s } label: {
                        HStack { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary); Text(s); Spacer() }
                            .padding(.vertical, 8).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }.padding(.horizontal, Theme.gutter)
        }
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse Your Library").font(.title3.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(LibrarySection.allCases) { s in
                    Button { router.push(.library(s)) } label: {
                        Label(s.rawValue, systemImage: s.icon).font(.headline).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(.horizontal, 14).background(tileColor(s).gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(PressStyle()).foregroundStyle(.white)
                }
            }
        }.padding(.horizontal, Theme.gutter)
    }
    private func tileColor(_ s: LibrarySection) -> Color {
        [.pink, .purple, .indigo, .red, .green, .orange][LibrarySection.allCases.firstIndex(of: s)! % 6]
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Scope.allCases, id: \.self) { s in
                    Button(s.rawValue) { withAnimation(.snappy) { scope = s } }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 7)
                        .background(scope == s ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white.opacity(0.09)), in: Capsule())
                        .foregroundStyle(scope == s ? .black : .primary).buttonStyle(.plain)
                }
            }.padding(.horizontal, Theme.gutter)
        }
        if loading && result == nil { ProgressView().frame(maxWidth: .infinity).padding(40) }
        if let err, result == nil { EmptyState(title: "Search failed", icon: "exclamationmark.triangle", message: err) }
        if let r = result {
            switch scope {
            case .all: all(r)
            case .songs: songs(r.tracks, limit: nil)
            case .artists: grid(r.artists)
            case .albums: grid(r.albums ?? [])
            case .playlists: grid(r.playlists ?? [])
            case .library: library
            }
        } else if scope == .library { library }
    }

    @ViewBuilder private func all(_ r: SearchResult) -> some View {
        if let top = topResult(r) { topCard(top) }
        if !r.tracks.isEmpty { section("Songs", more: r.tracks.count > 5 ? .songs : nil) { songs(r.tracks, limit: 5) } }
        if !r.artists.isEmpty { Shelf(title: "Artists", seeAll: { scope = .artists }) { ForEach(r.artists.prefix(15)) { CollectionCard(c: $0, size: 130) } } }
        if let a = r.albums, !a.isEmpty { Shelf(title: "Albums", seeAll: { scope = .albums }) { ForEach(a.prefix(15)) { CollectionCard(c: $0) } } }
        if let p = r.playlists, !p.isEmpty { Shelf(title: "Playlists", seeAll: { scope = .playlists }) { ForEach(p.prefix(15)) { CollectionCard(c: $0) } } }
        let mine = libraryMatches
        if !mine.isEmpty { section("In Your Library", more: .library) { songs(mine, limit: 5) } }
        if r.tracks.isEmpty && r.artists.isEmpty && (r.albums ?? []).isEmpty { EmptyState(title: "No results for “\(q)”", icon: "magnifyingglass") }
    }

    private enum Top { case collection(Collection), track(Track) }
    private func topResult(_ r: SearchResult) -> Top? {
        if let top = r.top {
            if let c = (r.artists + (r.albums ?? []) + (r.playlists ?? [])).first(where: { $0.id == top.id }) { return .collection(c) }
            if let t = r.tracks.first(where: { $0.extra?["uri"] == top.id }) { return .track(t) }
        }
        return r.artists.first.map { .collection($0) } ?? r.tracks.first.map { .track($0) }
    }

    private func topCard(_ top: Top) -> some View {
        let (title, sub, art, round): (String, String, String?, Bool) = switch top {
        case .collection(let c): (c.title, c.isArtist ? "Artist" : (c.subtitle ?? ""), c.art, c.isArtist)
        case .track(let t): (t.title, "Song · \(t.artist)", t.art, false)
        }
        return Button {
            remember(q)
            switch top {
            case .collection(let c): router.open(c)
            case .track(let t): player.play([t]); Task { if let more = result?.tracks.filter({ $0.id != t.id }) { player.addToQueue(Array(more.prefix(20))) } }
            }
        } label: {
            HStack(spacing: 16) {
                Art(url: art, size: 96, radius: round ? 48 : 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Top Result").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title).font(.title2.bold()).lineLimit(2)
                    Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.system(size: 40)).foregroundStyle(.tint)
            }
            .padding(14).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(.primary).padding(.horizontal, Theme.gutter)
    }

    private func section<C: View>(_ title: String, more: Scope?, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.title2.bold())
                Spacer()
                if let more { Button("See All") { scope = more }.buttonStyle(.borderless).foregroundStyle(.tint) }
            }.padding(.horizontal, Theme.gutter)
            c()
        }
    }

    private func songs(_ tracks: [Track], limit: Int?) -> some View {
        let shown = limit.map { Array(tracks.prefix($0)) } ?? tracks
        return LazyVStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, t in
                TrackRow(t: t) { remember(q); player.play(tracks, at: i, context: PlayContext(id: "search", title: "“\(q)”")) }
            }
        }.padding(.horizontal, Theme.gutter)
    }

    private func grid(_ items: [Collection]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)], spacing: 20) {
            ForEach(items) { CollectionCard(c: $0, size: 150) }
        }.padding(.horizontal, Theme.gutter)
    }

    /// Songs you already have (favourites, your playlists, downloads, history) matching the query.
    private var libraryMatches: [Track] {
        let words = q.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let pool = lib.favorites + lib.editablePlaylists.flatMap(\.tracks) + Downloads.shared.tracks + player.history
        return pool.uniqued().filter { t in
            let hay = "\(t.title) \(t.artist) \(t.album ?? "")".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
    @ViewBuilder private var library: some View {
        let m = libraryMatches
        if m.isEmpty { EmptyState(title: "Nothing in your library", icon: "music.note.house", message: "Songs you love, download or play show up here.") }
        else { songs(m, limit: nil) }
    }

    private func search(_ s: String) async {
        guard let m = pm.metadata else { err = "Install a metadata plugin in Settings → Plugins"; return }
        loading = true; defer { loading = false }
        do {
            let r: SearchResult = m.has("searchAll") ? try await m.call("searchAll", [s])
                : SearchResult(tracks: try await m.call("search", [s]), artists: [])
            guard s == q.trimmingCharacters(in: .whitespaces) else { return }
            result = r; err = nil
        } catch { if s == q.trimmingCharacters(in: .whitespaces) { err = error.localizedDescription; result = nil } }
    }

    private func remember(_ s: String) {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        recent.removeAll { $0.caseInsensitiveCompare(s) == .orderedSame }
        recent.insert(s, at: 0); recent = Array(recent.prefix(15))
        UserDefaults.standard.set(recent, forKey: "recentSearches")
        Cloud.shared.log(PlayEvent(type: "search", startedAt: nowMs(), q: s))
    }
}
