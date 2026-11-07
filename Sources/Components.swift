import SwiftUI

// MARK: - Artwork

struct Art: View {
    let url: String?
    var size: CGFloat? = 48
    var radius: CGFloat? = nil
    /// false = fill whatever frame it's given (headers, backgrounds) instead of a square.
    var square = true
    @State private var img: PlatformImage?

    var body: some View {
        Color(white: 0.1)
            .overlay {
                if let img { Image(platformImage: img).resizable().scaledToFill().transition(.opacity) }
                else { Image(systemName: "music.note").font(.system(size: (size ?? 120) * 0.3)).foregroundStyle(.white.opacity(0.18)) }
            }
            .frame(width: size, height: size)
            .aspectRatio(square ? 1 : nil, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius ?? max(3, (size ?? 200) / 12), style: .continuous))
            .task(id: url) {
                guard let url else { img = nil; return }
                if let c = ImageStore.shared.cached(url) { img = c; return }
                let i = await ImageStore.shared.image(url)
                withAnimation(.easeOut(duration: 0.2)) { img = i }
            }
    }
}

/// Cover for any collection: artwork, a 2×2 mosaic (your playlists, mixes) or a generated gradient tile.
struct CollectionArt: View {
    let c: Collection
    var size: CGFloat? = 160
    var radius: CGFloat? = nil
    @Environment(Library.self) var lib

    var body: some View {
        let mosaic = c.type == .local ? (lib.tracks(ofPlaylist: c.id).mosaic) : (c.mosaic ?? [])
        Group {
            if c.isArtist {
                Art(url: c.art, size: size, radius: (size ?? 400) / 2)
            } else if mosaic.count >= 4 {
                let s = size.map { $0 / 2 }
                VStack(spacing: 0) {
                    HStack(spacing: 0) { Art(url: mosaic[0], size: s, radius: 0); Art(url: mosaic[1], size: s, radius: 0) }
                    HStack(spacing: 0) { Art(url: mosaic[2], size: s, radius: 0); Art(url: mosaic[3], size: s, radius: 0) }
                }
                .frame(width: size, height: size).aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: radius ?? max(3, (size ?? 200) / 12), style: .continuous))
            } else if let a = c.art ?? mosaic.first {
                Art(url: a, size: size, radius: radius)
            } else {
                generated
            }
        }
    }

    private var generated: some View {
        let (icon, colors): (String, [Color]) = switch c.type {
        case .favorites, .spotifyLiked: ("heart.fill", [.pink, .purple])
        case .downloads: ("arrow.down.circle.fill", [.green, .teal])
        case .history: ("clock.fill", [.orange, .red])
        case .mix: ("sparkles", [.indigo, .cyan])
        default: ("music.note.list", [Color(white: 0.3), Color(white: 0.12)])
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay { Image(systemName: icon).font(.system(size: (size ?? 120) * 0.32, weight: .semibold)).foregroundStyle(.white.opacity(0.9)) }
            .frame(width: size, height: size).aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius ?? max(3, (size ?? 200) / 12), style: .continuous))
    }
}

/// Animated bars shown on the playing row.
struct NowPlayingBars: View {
    var playing: Bool
    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative.reversing, options: .repeating, isActive: playing)
            .foregroundStyle(.tint)
    }
}

// MARK: - Track rows

struct TrackRow: View {
    let t: Track
    var number: Int? = nil
    var showArt = true
    var showAlbum = true
    var playlistID: String? = nil
    var trailing: String? = nil
    let play: () -> Void

    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Downloads.self) var dl
    @State private var hover = false

    var body: some View {
        let isCurrent = player.current?.id == t.id
        HStack(spacing: 12) {
            if let number {
                ZStack {
                    if isCurrent { NowPlayingBars(playing: player.playing) } else { Text("\(number)").foregroundStyle(.secondary) }
                }.font(.callout.monospacedDigit()).frame(width: 26)
            }
            if showArt {
                Art(url: t.art, size: 44)
                    .overlay { if isCurrent && number == nil { Color.black.opacity(0.45).overlay { NowPlayingBars(playing: player.playing) }.clipShape(RoundedRectangle(cornerRadius: 4)) } }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(t.title).lineLimit(1).foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                HStack(spacing: 4) {
                    if t.explicit { Image(systemName: "e.square.fill").font(.caption2) }
                    if dl.items[t.id] != nil { Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.tint) }
                    Text(t.artist).lineLimit(1)
                }.font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            if showAlbum, let a = t.album {
                Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).frame(width: 220, alignment: .leading)
            }
            #endif
            if lib.isLiked(t) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.tint) }
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            else if let d = t.duration, d > 0 { Text(d.mmss).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Menu { TrackMenu(t: t, playlistID: playlistID) } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            #if os(macOS)
            .opacity(hover ? 1 : 0.35)
            #endif
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .accessibilityAddTraits(.isButton)
        #if os(macOS)
        .onHover { hover = $0 }
        .background(hover ? Color.white.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .draggable(DragTrack.encode(t))
        #endif
        .contextMenu { TrackMenu(t: t, playlistID: playlistID) }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { player.playNext([t]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }.tint(.indigo)
            Button { player.addToQueue([t]) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }.tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { lib.toggleLike(t) } label: { Label(lib.isLiked(t) ? "Unlove" : "Love", systemImage: lib.isLiked(t) ? "heart.slash" : "heart") }.tint(.pink)
            if let playlistID { Button(role: .destructive) { lib.remove([t.id], from: playlistID) } label: { Label("Remove", systemImage: "trash") } }
        }
        #endif
    }
}

/// Every action for a song, used by context menus, "…" buttons and the player.
struct TrackMenu: View {
    let t: Track
    var playlistID: String? = nil
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Downloads.self) var dl
    @Environment(Router.self) var router

    var body: some View {
        Button { player.playNext([t]); router.flash("Playing next") } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([t]); router.flash("Added to queue") } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        Button { lib.toggleLike(t) } label: { Label(lib.isLiked(t) ? "Unlove" : "Love", systemImage: lib.isLiked(t) ? "heart.slash" : "heart") }
        Menu {
            Button { router.newPlaylistTracks = [t] } label: { Label("New Playlist…", systemImage: "plus") }
            Divider()
            ForEach(lib.editablePlaylists) { p in
                Button(p.name) { router.flash(lib.add([t], to: p.id) > 0 ? "Added to \(p.name)" : "Already in \(p.name)") }
            }
        } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
        switch dl.state(t) {
        case .done: Button(role: .destructive) { dl.remove([t.id]) } label: { Label("Remove Download", systemImage: "trash") }
        case .queued, .downloading: Label("Downloading…", systemImage: "arrow.down.circle.dotted")
        default: Button { dl.download([t]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
        if let playlistID { Button(role: .destructive) { lib.remove([t.id], from: playlistID) } label: { Label("Remove from Playlist", systemImage: "minus.circle") } }
        Divider()
        Button { player.startRadio(t) } label: { Label("Start Station", systemImage: "dot.radiowaves.left.and.right") }
        if t.artistLinks.count > 1 {
            Menu { ForEach(t.artistLinks) { a in Button(a.title) { router.open(a) } } } label: { Label("Go to Artist", systemImage: "music.microphone") }
        } else if let a = t.artistLink {
            Button { router.open(a) } label: { Label("Go to Artist", systemImage: "music.microphone") }
        }
        if let a = t.albumLink { Button { router.open(a) } label: { Label("Go to Album", systemImage: "square.stack") } }
        Divider()
        if let u = t.shareURL {
            ShareLink(item: u) { Label("Share Song…", systemImage: "square.and.arrow.up") }
            Button { Clipboard.copy(u.absoluteString); router.flash("Link copied") } label: { Label("Copy Link", systemImage: "link") }
        }
        Button { router.chooseVersion = t } label: { Label("Choose Version…", systemImage: "waveform.badge.magnifyingglass") }
        if player.current?.id == t.id {
            Button { AudioFix.rematch(t, router: router) } label: { Label("Wrong Song? Find Another", systemImage: "exclamationmark.bubble") }
        }
    }
}

/// Fixing the YouTube match for a track (synced to your other devices).
@MainActor enum AudioFix {
    static func rematch(_ t: Track, router: Router) {
        Task {
            guard let p = PluginManager.shared.audio, p.has("rematch"), let arg = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) else { return }
            do { let _: String = try await p.call("rematch", [arg]); Player.shared.reloadAudio(for: t); router.flash("Trying another version") }
            catch { router.flash("No other version found") }
        }
    }
    static func choose(_ t: Track, _ c: Candidate) async {
        guard let p = PluginManager.shared.audio, let arg = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) else { return }
        let _: String? = try? await p.call("choose", [arg, c.id])
        Player.shared.reloadAudio(for: t)
    }
}

enum Clipboard {
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
}

// MARK: - Collections

/// Actions for an album / playlist / artist card.
struct CollectionMenu: View {
    let c: Collection
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Downloads.self) var dl
    @Environment(Router.self) var router
    var body: some View {
        Button { load { player.play($0, context: c.context) } } label: { Label("Play", systemImage: "play") }
        Button { load { player.playShuffled($0, context: c.context) } } label: { Label("Shuffle", systemImage: "shuffle") }
        Button { load { player.playNext($0); router.flash("Playing next") } } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { load { player.addToQueue($0); router.flash("Added to queue") } } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        if c.type == .album || c.type == .artist || c.type == .playlist || c.type == .spotifyLiked, !lib.isSavedInSpotify(c) {
            Button { lib.toggleSave(c) } label: {
                lib.isSaved(c) ? Label("Remove from Library", systemImage: "minus.circle") : Label("Add to Library", systemImage: "plus.circle")
            }
        }
        Button { load { dl.download($0); router.flash("Downloading \($0.count) songs") } } label: { Label("Download", systemImage: "arrow.down.circle") }
        Button { load { router.addToPlaylist = $0 } } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        if c.isArtist { Button { player.startRadio(Track(id: "seed", title: c.title, artist: c.title, extra: ["artistUri": c.id])) } label: { Label("Start Station", systemImage: "dot.radiowaves.left.and.right") } }
        if let u = c.shareURL {
            Divider()
            ShareLink(item: u) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        if c.type == .local {
            Divider()
            Button(role: .destructive) { lib.deletePlaylist(c.id); router.flash("Deleted \(c.title)") } label: { Label("Delete Playlist", systemImage: "trash") }
        }
    }
    private func load(_ f: @escaping ([Track]) -> Void) {
        Task { if let t = try? await Catalog.tracks(c), !t.isEmpty { f(t) } else { router.flash("Couldn't load \(c.title)") } }
    }
}

extension Collection {
    var context: PlayContext { PlayContext(id: id, title: title, art: art ?? mosaic?.first) }
}

struct CollectionCard: View {
    let c: Collection
    var size: CGFloat = 160
    @Environment(Router.self) var router
    var body: some View {
        Button { router.open(c) } label: {
            VStack(alignment: c.isArtist ? .center : .leading, spacing: 6) {
                CollectionArt(c: c, size: size).shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Text(c.title).font(.callout.weight(.medium)).lineLimit(1)
                if let s = c.subtitle, !c.isArtist { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: size).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(.primary)
        .contextMenu { CollectionMenu(c: c) }
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

/// Horizontally scrolling section with a title, Apple Music style.
struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var seeAll: (() -> Void)? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if let seeAll { Button("See All", action: seeAll).buttonStyle(.borderless).foregroundStyle(.tint) }
            }.padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) { content }.padding(.horizontal, Theme.gutter)
            }.scrollClipDisabled()
        }
    }
}

/// Big "Play" / "Shuffle" buttons on album, playlist and artist pages.
struct PlayButtons: View {
    let tracks: [Track]
    let context: PlayContext
    @Environment(Player.self) var player
    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(tracks, context: context) } label: { Label("Play", systemImage: "play.fill").lineLimit(1).frame(minWidth: 96, maxWidth: .infinity) }
            Button { player.playShuffled(tracks, context: context) } label: { Label("Shuffle", systemImage: "shuffle").lineLimit(1).frame(minWidth: 96, maxWidth: .infinity) }
        }
        .buttonStyle(CapsuleButton()).disabled(tracks.isEmpty)
        #if os(macOS)
        .frame(width: 260)
        #endif
    }
}

struct CapsuleButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(.tint)
            .padding(.vertical, 12).padding(.horizontal, 18)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DownloadButton: View {
    let tracks: [Track]
    @Environment(Downloads.self) var dl
    @State private var confirm = false
    var body: some View {
        let done = tracks.filter { dl.items[$0.id] != nil }.count
        let busy = tracks.contains { dl.state($0) == .downloading || dl.state($0) == .queued }
        Button {
            if done == tracks.count { confirm = true } else { dl.download(tracks) }
        } label: {
            if busy { ProgressView(value: Double(done), total: Double(max(tracks.count, 1))).progressViewStyle(.circular).controlSize(.small) }
            else { Image(systemName: done == tracks.count && done > 0 ? "arrow.down.circle.fill" : "arrow.down.circle") }
        }
        .help(done == tracks.count && done > 0 ? "Downloaded" : "Download")
        .disabled(tracks.isEmpty)
        .confirmationDialog("Remove \(tracks.count) downloaded songs?", isPresented: $confirm) {
            Button("Remove Downloads", role: .destructive) { dl.remove(tracks.map(\.id)) }
        }
    }
}

struct EmptyState: View {
    let title: String; let icon: String; var message: String? = nil
    var body: some View {
        ContentUnavailableView { Label(title, systemImage: icon) } description: { if let message { Text(message) } }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Loading collections

/// Loads tracks + header info for any collection (with an on-disk cache so pages open instantly and offline).
@MainActor enum Catalog {
    private static var memory: [String: CollectionDetails] = [:]

    static func cached(_ c: Collection) -> CollectionDetails? { memory[c.id] ?? DiskCache.load(CollectionDetails.self, "c-" + c.id) }

    static func details(_ c: Collection) async throws -> CollectionDetails {
        let lib = Library.shared
        switch c.type {
        case .local:
            guard let p = lib.playlists[c.id] else { throw err("Playlist was deleted") }
            if p.isSmart { await PlayCounts.shared.refresh() }
            return CollectionDetails(title: p.name, subtitle: "Playlist", description: p.notes, tracks: lib.tracks(p))
        case .favorites: return CollectionDetails(title: c.title, tracks: lib.favorites)
        case .downloads: return CollectionDetails(title: c.title, tracks: Downloads.shared.tracks)
        case .history: return CollectionDetails(title: c.title, tracks: Player.shared.history)
        case .mix: return CollectionDetails(title: c.title, subtitle: c.subtitle, tracks: try await Mixes.tracks(c.id))
        case .artist:
            let a = try await artist(c.id)
            return CollectionDetails(title: a.name, art: a.art, tracks: a.tracks)
        default:
            guard let m = PluginManager.shared.metadata else { throw err("Install a metadata plugin in Settings → Plugins") }
            let d: CollectionDetails = m.has("details") ? try await m.call("details", [c.id])
                : CollectionDetails(title: c.title, tracks: try await m.call("collection", [c.id]))
            memory[c.id] = d
            DiskCache.save(d, "c-" + c.id)
            return d
        }
    }

    static func tracks(_ c: Collection) async throws -> [Track] { try await details(c).tracks }

    static func cachedArtist(_ id: String) -> ArtistPage? { DiskCache.load(ArtistPage.self, "a-" + id) }
    static func artist(_ id: String) async throws -> ArtistPage {
        guard let m = PluginManager.shared.metadata, m.has("artist") else { throw err("Your metadata plugin has no artist pages") }
        let a: ArtistPage = try await m.call("artist", [id])
        DiskCache.save(a, "a-" + id)
        return a
    }

    private static func err(_ s: String) -> NSError { NSError(domain: "catalog", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Generated playlists on Home ("Made for You").
@MainActor enum Mixes {
    static var stats: Stats?

    static func all() -> [Collection] {
        var out: [Collection] = []
        let fav = Library.shared.favorites
        if fav.count >= 4 { out.append(Collection(id: "mix:favorites", title: "Favorites Mix", subtitle: "Songs you love, shuffled", kind: "mix", mosaic: fav.shuffled().mosaic)) }
        if let s = stats, s.topTracks.count >= 4 {
            out.append(Collection(id: "mix:replay", title: "Replay Mix", subtitle: "Your most played lately", kind: "mix", mosaic: s.topTracks.map(\.track).mosaic))
        }
        if Discovery.yourArtists(limit: 3).count >= 2 {
            out.append(Collection(id: "mix:discover", title: "Discovery Mix", subtitle: "Songs you've never played, from artists like yours", kind: "mix",
                                  mosaic: Discovery.shared.releases.compactMap(\.art).prefix(4).map { $0 }))
        }
        let older = Array(Player.shared.history.dropFirst(40))
        if older.count >= 8 { out.append(Collection(id: "mix:rediscover", title: "Rediscover", subtitle: "Songs you haven't played in a while", kind: "mix", mosaic: older.shuffled().mosaic)) }
        let artists = (stats?.topArtists.compactMap { a in a.id.map { ($0, a.name) } } ?? [])
            + Player.shared.history.compactMap { t in t.artistID.map { ($0, t.primaryArtist) } }
        var seen = Set<String>()
        for (id, name) in artists where seen.insert(id).inserted && seen.count <= 4 {
            out.append(Collection(id: "mix:artist:" + id, title: "\(name) Station", subtitle: "\(name) and similar artists", art: Catalog.cachedArtist(id)?.art, kind: "mix"))
        }
        return out
    }

    /// Related artists' songs you have never played, from artists you don't already listen to.
    private static func discover() async throws -> [Track] {
        guard let m = PluginManager.shared.metadata, m.has("radio") else { return [] }
        let mine = Discovery.yourArtists(limit: 60)
        let known = Set(mine.map(\.id))
        let heard = Set(PlayCounts.shared.byID.keys).union(Player.shared.history.map(\.id)).union(Library.shared.likes.keys)
        let seeds = Array(mine.prefix(12).shuffled().prefix(4))
        var out: [Track] = []
        await withTaskGroup(of: [Track].self) { g in
            for s in seeds {
                g.addTask { @MainActor in
                    let seed = Track(id: "seed", title: "", artist: "", extra: ["artistUri": s.id])
                    guard let arg = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) else { return [] }
                    return (try? await m.call("radio", [arg])) ?? []
                }
            }
            for await t in g { out += t }
        }
        var perArtist: [String: Int] = [:]
        let fresh = out.uniqued().filter { t in
            guard !heard.contains(t.id), let a = t.artistID, !known.contains(a) else { return false }
            perArtist[a, default: 0] += 1
            return perArtist[a]! <= 3
        }
        if fresh.isEmpty { throw NSError(domain: "mix", code: 1, userInfo: [NSLocalizedDescriptionKey: "Listen to a few more artists and Discovery Mix fills up."]) }
        return fresh.shuffled()
    }

    static func tracks(_ id: String) async throws -> [Track] {
        switch id {
        case "mix:favorites": return Array(Library.shared.favorites.shuffled().prefix(100))
        case "mix:replay":
            if let s = try? await Cloud.shared.stats(days: 30) { stats = s; return s.topTracks.map(\.track) }
            return Array(Player.shared.history.prefix(50))
        case "mix:rediscover": return Array(Player.shared.history.dropFirst(40).shuffled().prefix(60))
        case "mix:discover": return try await discover()
        default:
            guard id.hasPrefix("mix:artist:"), let m = PluginManager.shared.metadata else { return [] }
            let seed = Track(id: "seed", title: "", artist: "", extra: ["artistUri": String(id.dropFirst("mix:artist:".count))])
            if m.has("radio") { return try await m.call("radio", [try JSONSerialization.jsonObject(with: JSONEncoder().encode(seed))]) }
            return try await Catalog.artist(String(id.dropFirst("mix:artist:".count))).tracks
        }
    }
}
