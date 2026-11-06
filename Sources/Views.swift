import SwiftUI
import WebKit
import UniformTypeIdentifiers

enum Page: Hashable { case home, search, plugins, collection(Collection) }

/// Shared navigation state so the player (and menu bar) can jump to an artist/album.
@MainActor @Observable final class Router {
    var page: Page? = .home
    var path = NavigationPath()
    var showFull = false
    func open(_ c: Collection) { showFull = false; path.append(c) }
}

extension Track {
    var albumLink: Collection? { extra?["albumUri"].map { Collection(id: $0, title: album ?? "Album", art: art) } }
    var artistLink: Collection? { extra?["artistUri"].map { Collection(id: $0, title: artist.components(separatedBy: ", ").first ?? artist, subtitle: "Artist") } }
}

struct RootView: View {
    @Environment(PluginManager.self) var pm
    @Environment(Player.self) var player
    @Environment(Router.self) var router
    @State var lib: [Collection] = []
    @Bindable var login = WebLogin.shared

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(selection: $router.page) {
                Label("Home", systemImage: "house").tag(Page.home)
                Label("Search", systemImage: "magnifyingglass").tag(Page.search)
                Label("Plugins", systemImage: "puzzlepiece.extension").tag(Page.plugins)
                Section("Library") {
                    ForEach(lib) { c in
                        Label { Text(c.title).lineLimit(1) } icon: { Art(url: c.art, size: 22) }.tag(Page.collection(c))
                    }
                }
            }
            .scrollContentBackground(.hidden).background(.black)
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .task(id: pm.metadata?.id) { await loadLib() }
            .refreshable { await loadLib() }
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    switch router.page ?? .home {
                    case .home: HomeView()
                    case .search: SearchView()
                    case .plugins: PluginsView(reloadLibrary: { Task { await loadLib() } })
                    case .collection(let c): CollectionView(c: c).id(c.id)
                    }
                }
                .navigationDestination(for: Collection.self) { c in
                    if c.id.hasPrefix("spotify:artist:"), pm.metadata?.has("artist") == true { ArtistView(c: c) } else { CollectionView(c: c) }
                }
            }
            .background(.black)
        }
        .onChange(of: router.page) { router.path = NavigationPath() }
        .safeAreaInset(edge: .bottom) { if player.current != nil { MiniPlayer() } }
        .sheet(isPresented: $router.showFull) { FullPlayer() }
        .sheet(isPresented: Binding(get: { login.url != nil }, set: { if !$0 { login.cancel() } })) {
            VStack(spacing: 0) {
                HStack { Text("Log in").font(.headline); Spacer(); Button("Cancel") { login.cancel() } }.padding()
                WebViewBox(web: login.web)
            }.frame(minWidth: 480, minHeight: 640)
        }
        .onAppear { player.plugins = pm }
    }

    func loadLib() async {
        guard let m = pm.metadata, m.has("library") else { lib = []; return }
        lib = (try? await m.call("library")) ?? []
    }
}

/// Track title/artist that jump to the album/artist page when clicked.
struct TrackLinks: View {
    @Environment(Router.self) var router
    let t: Track
    var titleFont: Font = .body
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { if let a = t.albumLink { router.open(a) } } label: { Text(t.title).font(titleFont).lineLimit(1) }
                .buttonStyle(.plain).disabled(t.albumLink == nil).help(t.album.map { "Go to \($0)" } ?? "")
            Button { if let a = t.artistLink { router.open(a) } } label: { Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                .buttonStyle(.plain).disabled(t.artistLink == nil).help("Go to artist")
        }
    }
}

#if os(macOS)
struct WebViewBox: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_: WKWebView, context: Context) {}
}
#else
struct WebViewBox: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_: WKWebView, context: Context) {}
}
#endif

struct Art: View {
    let url: String?; var size: CGFloat = 48
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.08) }
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 10))
    }
}

struct TrackList<Header: View>: View {
    @Environment(Player.self) var player
    let tracks: [Track]
    @ViewBuilder var header: () -> Header
    var body: some View {
        List {
            header().listRowBackground(Color.black)
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in row(i, t) }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(.black)
    }
    func row(_ i: Int, _ t: Track) -> some View {
            Button { player.play(tracks, at: i) } label: {
                HStack {
                    Art(url: t.art, size: 40)
                    VStack(alignment: .leading) {
                        Text(t.title).foregroundStyle(player.current == t ? .green : .white).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let a = t.album { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220, alignment: .leading) }
                    if let d = t.duration, d > 0 { Text(d.mmss).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).listRowBackground(Color.black)
            .contextMenu { TrackMenu(t: t) }
    }
}
extension TrackList where Header == EmptyView {
    init(tracks: [Track]) { self.init(tracks: tracks) { EmptyView() } }
}

struct SearchResult: Codable { var artists: [Collection]; var tracks: [Track]; var error: String? }

struct Loader: View {
    let title: String; let fn: String; var args: [Any] = []
    @Environment(PluginManager.self) var pm
    @State var tracks: [Track] = []
    @State var err: String?
    @State var loading = true
    var body: some View {
        TrackList(tracks: tracks).navigationTitle(title)
            .overlay {
                if loading { ProgressView() }
                else if let err { ContentUnavailableView { Label("Couldn't load", systemImage: "exclamationmark.triangle") } description: { Text(err).textSelection(.enabled) } actions: { Button("Retry") { Task { await load() } } } }
                else if tracks.isEmpty { ContentUnavailableView("Nothing here", systemImage: "music.note") }
            }
            .task(id: "\(pm.metadata?.id ?? "")|\(fn)|\(args.map { "\($0)" }.joined())") { await load() }
    }
    func load() async {
        loading = true; defer { loading = false }
        guard let m = pm.metadata else { err = "Install a metadata plugin"; return }
        guard m.has(fn) else { err = "\(m.name) has no \(fn)()"; return }
        do { tracks = try await m.call(fn, args); err = nil } catch { err = error.localizedDescription }
    }
}

struct HomeView: View {
    @Environment(Player.self) var player
    var body: some View {
        TrackList(tracks: player.history).navigationTitle("Recently played")
            .overlay { if player.history.isEmpty { ContentUnavailableView("Nothing played yet", systemImage: "clock", description: Text("Songs you play show up here.")) } }
            .toolbar { if !player.history.isEmpty { Button("Clear") { player.clearHistory() } } }
    }
}
struct CollectionView: View { let c: Collection; var body: some View { Loader(title: c.title, fn: "collection", args: [c.id]) } }

struct SearchView: View {
    @Environment(PluginManager.self) var pm
    @Environment(Router.self) var router
    @State var q = ""
    @State var tracks: [Track] = []
    @State var artists: [Collection] = []
    @State var err: String?
    var body: some View {
        TrackList(tracks: tracks) {
            if !artists.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Artists").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(artists) { a in
                                Button { router.open(a) } label: {
                                    VStack {
                                        AsyncImage(url: a.art.flatMap(URL.init)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.08) }
                                            .frame(width: 96, height: 96).clipShape(Circle())
                                        Text(a.title).font(.caption).lineLimit(1).frame(width: 100)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.borderless).foregroundStyle(.white)
                            }
                        }
                    }
                    if !tracks.isEmpty { Text("Songs").font(.headline).padding(.top, 8) }
                }.padding(.vertical, 8)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $q, placement: .toolbar).onSubmit(of: .search) {
            Task {
                guard let m = pm.metadata else { return }
                do {
                    if m.has("searchAll") { let r: SearchResult = try await m.call("searchAll", [q]); artists = r.artists; tracks = r.tracks
                        err = r.error.map { "Artists: \($0)" }; return }
                    else { artists = []; tracks = try await m.call("search", [q]) }
                    err = nil
                } catch { err = error.localizedDescription }
            }
        }
            .overlay { if let err { Text(err).foregroundStyle(.red).padding() } }
    }
}

struct PluginsView: View {
    @Environment(PluginManager.self) var pm
    var reloadLibrary: () -> Void
    @State var url = ""
    @State var importing = false
    @State var msg: String?
    var body: some View {
        @Bindable var pm = pm
        Form {
            Section("Active") {
                Picker("Metadata", selection: Binding($pm.metadataID, replacingNilWith: pm.metadata?.id ?? "")) {
                    ForEach(pm.plugins.filter { $0.abilities.contains("metadata") }) { Text($0.name).tag($0.id) }
                }
                Picker("Audio source", selection: Binding($pm.audioID, replacingNilWith: pm.audio?.id ?? "")) {
                    ForEach(pm.plugins.filter { $0.abilities.contains("audio") }) { Text($0.name).tag($0.id) }
                }
            }
            Section("Installed") {
                ForEach(pm.plugins) { p in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text("v\(p.version) · \(p.abilities.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if p.has("login") {
                            Button("Log in") { run(p, "login") }
                            Button("Log out") { run(p, "logout") }
                        }
                        Button(role: .destructive) { pm.remove(p) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            Section("Install") {
                TextField("https://…/plugin.js", text: $url)
                Button("Install from URL") { Task { await install(URL(string: url)) } }
                Button("Install from file…") { importing = true }
                if let msg { Text(msg).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(.black).navigationTitle("Plugins")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { r in Task { await install(try? r.get()) } }
    }
    func run(_ p: JSPlugin, _ fn: String) {
        Task {
            do { let _: String? = try await p.call(fn); msg = "\(p.name): \(fn) ok"; reloadLibrary() } catch { msg = error.localizedDescription }
        }
    }
    func install(_ u: URL?) async {
        guard let u else { return }
        do { try await pm.install(from: u); msg = "Installed" } catch { msg = error.localizedDescription }
    }
}

extension Binding where Value == String {
    init(_ b: Binding<String?>, replacingNilWith d: String) { self.init(get: { b.wrappedValue ?? d }, set: { b.wrappedValue = $0 }) }
}

struct MiniPlayer: View {
    @Environment(Player.self) var p
    @Environment(Router.self) var router
    var body: some View {
        HStack {
            Button { router.showFull = true } label: { Art(url: p.current?.art, size: 40) }.buttonStyle(.plain).help("Now playing")
            VStack(alignment: .leading, spacing: 2) {
                if let t = p.current { TrackLinks(t: t) }
                if p.loading { Text("Loading…").font(.caption2).foregroundStyle(.secondary) }
                else if let e = p.error { Text(e).font(.caption2).foregroundStyle(e.hasPrefix("via") ? Color.secondary : Color.red).lineLimit(1) }
            }.frame(maxWidth: 260, alignment: .leading)
            Spacer()
            Button { p.prev() } label: { Image(systemName: "backward.fill") }
            Button { p.toggle() } label: {
                if p.loading { ProgressView().controlSize(.small).frame(width: 24) }
                else { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.title2) }
            }
            Button { p.next() } label: { Image(systemName: "forward.fill") }
            Spacer()
            Text("\(p.progress.mmss) / \((p.duration ?? 0).mmss)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { router.showFull = true } label: { Image(systemName: "chevron.up") }
        }
        .buttonStyle(.plain).font(.title3)
        .padding(10).background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 12)).padding(8).foregroundStyle(.white)
    }
}

struct FullPlayer: View {
    @Environment(Player.self) var p
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 24) {
            HStack { Spacer(); Button { dismiss() } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain) }
            Spacer()
            Art(url: p.current?.art, size: 320)
            if let t = p.current { TrackLinks(t: t, titleFont: .title2.bold()) }
            let d = max(p.duration ?? 1, 1)
            Slider(value: Binding(get: { min(p.progress, d) }, set: { p.seek($0) }), in: 0...d)
            HStack(spacing: 48) {
                Button { p.prev() } label: { Image(systemName: "backward.fill") }
                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                Button { p.next() } label: { Image(systemName: "forward.fill") }
            }.font(.title).buttonStyle(.plain).foregroundStyle(.white)
            Spacer()
        }.padding(32).frame(minWidth: 420, minHeight: 600).frame(maxWidth: .infinity).background(Color.black.ignoresSafeArea()).presentationBackground(.black)
    }
}

extension Double {
    var nanSafe: Double? { isFinite ? self : nil }
    var mmss: String { let s = Int(isFinite ? self : 0); return String(format: "%d:%02d", s / 60, s % 60) }
}

struct ArtistPage: Codable { var name: String; var art: String?; var tracks: [Track]; var albums: [Collection] }

struct ArtistView: View {
    let c: Collection
    @Environment(PluginManager.self) var pm
    @Environment(Router.self) var router
    @State var page: ArtistPage?
    @State var err: String?
    var body: some View {
        TrackList(tracks: page?.tracks ?? []) {
            if let page {
                HStack(spacing: 20) {
                    AsyncImage(url: (page.art ?? c.art).flatMap(URL.init)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.08) }
                        .frame(width: 140, height: 140).clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text("Artist").font(.caption).foregroundStyle(.secondary)
                        Text(page.name.isEmpty ? c.title : page.name).font(.largeTitle.bold())
                    }
                }.padding(.vertical, 12)
                if !page.albums.isEmpty {
                    Text("Discography").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(page.albums) { a in
                            Button { router.open(a) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AsyncImage(url: a.art.flatMap(URL.init)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.08) }
                                        .frame(width: 140, height: 140).clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text(a.title).font(.callout).lineLimit(1)
                                    Text(a.subtitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(width: 140).contentShape(Rectangle())
                            }.buttonStyle(.borderless).foregroundStyle(.white)
                        }
                    }
                }
                if !page.tracks.isEmpty { Text("Popular").font(.headline).padding(.top, 12) }
            }
        }
        .navigationTitle(c.title)
        .overlay {
            if let err { ContentUnavailableView("Couldn't load artist", systemImage: "exclamationmark.triangle", description: Text(err)) }
            else if page == nil { ProgressView() }
        }
        .task(id: c.id) {
            do { page = try await pm.metadata?.call("artist", [c.id]); err = nil } catch { err = error.localizedDescription }
        }
    }
}

struct TrackMenu: View {
    @Environment(Router.self) var router
    @Environment(Player.self) var player
    let t: Track
    var body: some View {
        if let a = t.artistLink { Button("Go to Artist") { router.open(a) } }
        if let a = t.albumLink { Button("Go to Album") { router.open(a) } }
        Button("Play Next") { player.playNext(t) }
    }
}
