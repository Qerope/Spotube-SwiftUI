import SwiftUI
import WebKit

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case playlists = "Playlists", artists = "Artists", albums = "Albums", songs = "Songs", downloaded = "Downloaded", recent = "Recently Played"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.microphone"
        case .albums: "square.stack"
        case .songs: "heart"
        case .downloaded: "arrow.down.circle"
        case .recent: "clock"
        }
    }
}

enum Route: Hashable { case collection(Collection), library(LibrarySection), stats, settings }
enum SidebarItem: Hashable { case home, search, stats, library(LibrarySection), collection(Collection) }
enum AppTab: Hashable { case home, library, search }
enum PlayerPanel: Hashable { case art, lyrics, queue }

/// Navigation + app-wide sheets, shared by every screen, the player and the menu bar.
@MainActor @Observable final class Router {
    var sidebar: SidebarItem? = .home { didSet { if sidebar != oldValue { macPath = NavigationPath() } } }
    var tab: AppTab = .home
    var paths: [AppTab: NavigationPath] = [:]
    var macPath = NavigationPath()
    var showFull = false
    var panel: PlayerPanel = .art
    var showQueue = false
    var focusSearch = false
    var newPlaylistTracks: [Track]?
    /// Create (playlist nil) or edit a smart playlist.
    var smartEdit: SmartEdit?
    var addToPlaylist: [Track]?
    var chooseVersion: Track?
    var toast: String?

    func open(_ c: Collection) { push(.collection(c)) }
    func push(_ r: Route) {
        showFull = false
        #if os(macOS)
        if case .stats = r { sidebar = .stats; return }
        macPath.append(r)
        #else
        paths[tab, default: NavigationPath()].append(r)
        #endif
    }
    func path(_ t: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[t] ?? NavigationPath() }, set: { self.paths[t] = $0 })
    }
    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(2.2)); if toast == s { toast = nil } }
    }
}

struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case .collection(let c):
            if c.isArtist { ArtistView(c: c) } else { CollectionView(c: c) }
        case .library(let s): LibrarySectionView(section: s)
        case .stats: StatsView()
        case .settings: SettingsView()
        }
    }
}

extension View {
    func withDestinations() -> some View { navigationDestination(for: Route.self) { RouteView(route: $0) } }
}

struct RootView: View {
    @Environment(Router.self) var router
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(PluginManager.self) var pm
    @Bindable var login = WebLogin.shared
    @State private var newName = ""

    var body: some View {
        @Bindable var router = router
        content
            .overlay(alignment: .top) {
                if let t = router.toast {
                    Text(t).font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule()).padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: router.toast)
            .alert("New Playlist", isPresented: Binding(get: { router.newPlaylistTracks != nil }, set: { if !$0 { router.newPlaylistTracks = nil } })) {
                TextField("Playlist name", text: $newName)
                Button("Create") {
                    let p = lib.createPlaylist(newName, tracks: router.newPlaylistTracks ?? [])
                    router.flash("Created \(p.name)")
                    router.newPlaylistTracks = nil; newName = ""
                }
                Button("Cancel", role: .cancel) { router.newPlaylistTracks = nil; newName = "" }
            }
            .sheet(item: $router.chooseVersion) { VersionPicker(t: $0) }
            .sheet(item: $router.smartEdit) { SmartPlaylistEditor(edit: $0) }
            .sheet(isPresented: Binding(get: { router.addToPlaylist != nil }, set: { if !$0 { router.addToPlaylist = nil } })) {
                AddToPlaylistSheet(tracks: router.addToPlaylist ?? [])
            }
            .sheet(isPresented: Binding(get: { login.url != nil }, set: { if !$0 { login.cancel() } })) {
                VStack(spacing: 0) {
                    HStack { Text("Log in").font(.headline); Spacer(); Button("Cancel") { login.cancel() } }.padding()
                    WebViewBox(web: login.web)
                }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 640)
                #endif
            }
            .onOpenURL { u in
                // spotubelite://nowplaying (widget / Live Activity tap)
                if u.host() == "nowplaying" { if Player.shared.current != nil { router.showFull = true }; return }
                // spotubelite://pair?url=…&token=… (from the QR code in Settings on another device)
                guard u.host() == "pair", let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
                      let url = q.first(where: { $0.name == "url" })?.value, let token = q.first(where: { $0.name == "token" })?.value else { return }
                Cloud.shared.url = url; Cloud.shared.token = token
                PluginStorage.setup()
                router.flash("Connected to your server")
            }
            .task { await Library.shared.refreshSpotify() }
            .task { await DebugRoute.run(router) }
    }

    @ViewBuilder var content: some View {
        #if os(macOS)
        @Bindable var router = router
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            NavigationStack(path: $router.macPath) {
                Group {
                    switch router.sidebar ?? .home {
                    case .home: HomeView()
                    case .search: SearchView()
                    case .stats: StatsView()
                    case .library(let s): LibrarySectionView(section: s)
                    case .collection(let c): CollectionView(c: c).id(c.id)
                    }
                }.withDestinations()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { if player.current != nil { MiniPlayerBar() } }
        .inspector(isPresented: $router.showQueue) { QueuePanel().inspectorColumnWidth(min: 280, ideal: 320) }
        .overlay {
            if router.showFull { FullPlayer().ignoresSafeArea().transition(.move(edge: .bottom)).zIndex(1) }
        }
        .animation(.spring(duration: 0.4), value: router.showFull)
        #else
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: router.path(.home)) { HomeView().withDestinations() }
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: router.path(.library)) { LibraryView().withDestinations() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: router.path(.search)) { SearchView().withDestinations() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(MiniPlayerHost(enabled: player.current != nil))
        .fullScreenCover(isPresented: $router.showFull) { FullPlayer() }
        #endif
    }
}

#if os(iOS)
/// Shows the mini player above the tab bar (hidden when nothing is queued, on iOS 26.1+).
struct MiniPlayerHost: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) { content.tabViewBottomAccessory(isEnabled: enabled) { MiniPlayerAccessory() } }
        else { content.tabViewBottomAccessory { MiniPlayerAccessory() } }
    }
}
#endif

#if os(macOS)
struct Sidebar: View {
    @Environment(Router.self) var router
    @Environment(Library.self) var lib
    @Environment(Cloud.self) var cloud
    var body: some View {
        @Bindable var router = router
        List(selection: $router.sidebar) {
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                Label("Replay", systemImage: "chart.bar.xaxis").tag(SidebarItem.stats)
            }
            Section("Library") {
                ForEach(LibrarySection.allCases) { s in Label(s.rawValue, systemImage: s.icon).tag(SidebarItem.library(s)) }
            }
            Section("Playlists") {
                ForEach(lib.allPlaylists) { c in
                    Label { Text(c.title).lineLimit(1) } icon: { CollectionArt(c: c, size: 20, radius: 4) }
                        .tag(SidebarItem.collection(c))
                        .contextMenu { CollectionMenu(c: c) }
                        .dropDestination(for: String.self) { ids, _ in dropTracks(ids, on: c) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button { router.newPlaylistTracks = [] } label: { Label("New Playlist", systemImage: "music.note.list") }
                    Button { router.smartEdit = SmartEdit() } label: { Label("New Smart Playlist", systemImage: "gearshape.2") }
                } label: { Label("New Playlist", systemImage: "plus") } primaryAction: { router.newPlaylistTracks = [] }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                SyncBadge()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
    private func dropTracks(_ ids: [String], on c: Collection) -> Bool {
        guard c.type == .local, lib.playlists[c.id]?.isSmart != true else { return false }
        let tracks = ids.compactMap { DragTrack.decode($0) }
        guard !tracks.isEmpty else { return false }
        let n = lib.add(tracks, to: c.id)
        router.flash(n > 0 ? "Added to \(c.title)" : "Already in \(c.title)")
        return true
    }
}
#endif

/// Sync status dot (green online, orange syncing/pending, red offline).
struct SyncBadge: View {
    @Environment(Cloud.self) var cloud
    var body: some View {
        let (color, text): (Color, String) = switch cloud.status {
        case .online: (cloud.pending > 0 ? .orange : .green, cloud.pending > 0 ? "Syncing \(cloud.pending) changes" : "Synced")
        case .connecting: (.orange, "Connecting to server…")
        case .offline(let e): (.red, "Server unreachable: \(e)")
        case .off: (.gray, "No server configured")
        }
        Circle().fill(color).frame(width: 7, height: 7).help(text).accessibilityLabel(text)
    }
}

/// Tracks dragged onto sidebar playlists travel as JSON strings.
enum DragTrack {
    static func encode(_ t: Track) -> String { (try? String(data: JSONEncoder().encode(t), encoding: .utf8)) ?? "" }
    static func decode(_ s: String) -> Track? { try? JSONDecoder().decode(Track.self, from: Data(s.utf8)) }
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

/// Launch arguments for automated screenshots: `-debugRoute search:daft punk|artist:<uri>|album:<uri>|player|lyrics|queue|stats|settings|library`
/// and `-debugPlay <query>` to start playing the first search result.
enum DebugRoute {
    @MainActor static func run(_ router: Router) async {
        let d = UserDefaults.standard
        if let q = d.string(forKey: "debugPlay"), let m = PluginManager.shared.metadata {
            if let r: SearchResult = try? await m.call("searchAll", [q]), !r.tracks.isEmpty { Player.shared.play(r.tracks, at: 0) }
        }
        if d.double(forKey: "debugSkip") > 0 {
            let n = d.double(forKey: "debugSkip")
            Task { try? await Task.sleep(for: .seconds(n)); Player.shared.next() }
        }
        // -debugSeekEnd N: after N s jump to 10 s before the end (crossfade testing).
        if d.double(forKey: "debugSeekEnd") > 0 {
            let n = d.double(forKey: "debugSeekEnd")
            Task { try? await Task.sleep(for: .seconds(n)); if let du = Player.shared.duration { Player.shared.seek(du - 10) } }
        }
        guard let r = d.string(forKey: "debugRoute") else { return }
        try? await Task.sleep(for: .seconds(1))
        let parts = r.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "search":
            #if os(macOS)
            router.sidebar = .search
            #else
            router.tab = .search
            #endif
            DebugRoute.query = arg
        case "smart": router.smartEdit = SmartEdit()
        case "artist": router.open(Collection(id: arg, title: "Artist", kind: "artist"))
        case "album", "playlist", "collection": router.open(Collection(id: arg, title: ""))
        case "player": router.showFull = true
        case "lyrics": router.showFull = true; router.panel = .lyrics
        case "queue": router.showFull = true; router.panel = .queue
        case "stats": router.push(.stats)
        case "settings": router.push(.settings)
        case "library":
            #if os(macOS)
            router.sidebar = .library(LibrarySection(rawValue: arg) ?? .playlists)
            #else
            router.tab = .library
            if let s = LibrarySection(rawValue: arg) { router.push(.library(s)) }
            #endif
        default: break
        }
    }
    @MainActor static var query: String?
}
