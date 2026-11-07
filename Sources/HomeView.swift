import SwiftUI

struct HomeView: View {
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Cloud.self) var cloud
    @Environment(Router.self) var router
    @Environment(PluginManager.self) var pm
    @State private var remote: [HistoryEntry] = Store.load([HistoryEntry].self, "remote-history") ?? []
    @State private var stats: Stats? = Store.load(Stats.self, "stats-30")

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                Text(greeting).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, Theme.gutter)
                    #if os(macOS)
                    .overlay(alignment: .bottomLeading) { Text("Home").font(.largeTitle.bold()).offset(y: 38).padding(.horizontal, Theme.gutter) }
                    .padding(.bottom, 34)
                    #endif
                HandoffCard()
                if pm.metadata?.has("login") == true, lib.spotifyPlaylists.isEmpty, recent.isEmpty, lib.favorites.isEmpty { onboarding }
                if !recent.isEmpty {
                    Shelf(title: "Recently Played") { ForEach(recent) { CollectionCard(c: $0) } }
                }
                let releases = Discovery.shared.shelf
                if !releases.isEmpty {
                    Shelf(title: "New Releases", subtitle: "From artists you listen to") { ForEach(releases) { CollectionCard(c: $0) } }
                }
                let mixes = Mixes.all()
                if !mixes.isEmpty {
                    Shelf(title: "Made for You", subtitle: "Mixes built from your listening") { ForEach(mixes) { CollectionCard(c: $0) } }
                }
                if let s = stats, !s.topTracks.isEmpty { topSongs(s) }
                if !lib.allPlaylists.isEmpty {
                    Shelf(title: "Your Playlists", seeAll: { router.push(.library(.playlists)) }) { ForEach(lib.allPlaylists.prefix(20)) { CollectionCard(c: $0) } }
                }
                if !lib.albums.isEmpty {
                    Shelf(title: "Your Albums", seeAll: { router.push(.library(.albums)) }) { ForEach(lib.albums.prefix(20)) { CollectionCard(c: $0) } }
                }
                let artists = topArtists
                if !artists.isEmpty {
                    Shelf(title: "Your Top Artists", subtitle: "Last 30 days") { ForEach(artists) { CollectionCard(c: $0, size: 130) } }
                }
                if !player.history.isEmpty {
                    Shelf(title: "Played on This Device", seeAll: { router.push(.library(.recent)) }) {
                        ForEach(Array(player.history.prefix(15).enumerated()), id: \.element.id) { i, t in
                            TrackCard(t: t) { player.play(Array(player.history.prefix(50)), at: i, context: PlayContext(id: "history", title: "Recently Played")) }
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden).background(.black)
        #if os(iOS)
        .navigationTitle("Home")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileMenu() } }
        #endif
        .refreshable { await load() }
        .task(id: cloud.status == .online) { await load() }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    /// Albums / playlists / artists you played recently, across devices (server) and this device.
    private var recent: [Collection] {
        var seen = Set<String>(), out: [Collection] = []
        let entries = remote.map { ($0.context, $0.track) } + player.history.map { (Optional<PlayContext>.none, $0) }
        for (ctx, t) in entries {
            let c: Collection?
            if let ctx, !ctx.id.isEmpty, !["history", "favorites", "downloads"].contains(ctx.id), !ctx.id.hasPrefix("radio:"), !ctx.id.hasPrefix("mix:") {
                c = Collection(id: ctx.id, title: ctx.title, subtitle: ctx.id.hasPrefix("spotify:album:") ? t.primaryArtist : nil, art: ctx.art,
                               kind: ctx.id.hasPrefix("spotify:artist:") ? "artist" : nil,
                               mosaic: ctx.id.hasPrefix("local:") ? lib.tracks(ofPlaylist: ctx.id).mosaic : nil)
            } else if let a = t.albumLink {
                c = Collection(id: a.id, title: a.title, subtitle: t.primaryArtist, art: a.art, kind: "album")
            } else { c = nil }
            if let c, !c.title.isEmpty, seen.insert(c.id).inserted { out.append(c) }
            if out.count >= 20 { break }
        }
        return out
    }

    private var topArtists: [Collection] {
        (stats?.topArtists ?? []).prefix(15).compactMap { a in
            a.id.map { Collection(id: $0, title: a.name, subtitle: "Artist", art: Catalog.cachedArtist($0)?.art, kind: "artist") }
        }
    }

    private func topSongs(_ s: Stats) -> some View {
        let tracks = s.topTracks.prefix(20).map(\.track)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Songs").font(.title2.bold())
                    Text("Your most played, last 30 days").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Replay") { router.push(.stats) }.buttonStyle(.borderless).foregroundStyle(.tint)
            }.padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(52), spacing: 6), count: 4), spacing: 24) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        TrackRow(t: t, showAlbum: false, trailing: "\(s.topTracks[i].plays) plays") {
                            player.play(Array(tracks), at: i, context: PlayContext(id: "mix:replay", title: "Top Songs"))
                        }.frame(width: 330)
                    }
                }.padding(.horizontal, Theme.gutter)
            }.scrollClipDisabled()
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Connect Spotify", systemImage: "person.crop.circle.badge.plus").font(.title3.bold())
            Text("Log in to Spotify to bring in your playlists, Liked Songs and saved albums. Logging in on one device logs in all your devices.")
                .foregroundStyle(.secondary)
            Button("Log In to Spotify") {
                guard let p = pm.plugins.first(where: { $0.has("login") }) else { return }
                Task { let _: String? = try? await p.call("login", timeout: 900); pm.revision += 1; await lib.refreshSpotify() }
            }.buttonStyle(.borderedProminent)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, Theme.gutter)
    }

    private func load() async {
        guard cloud.enabled else { await Discovery.shared.refresh(); return }
        if let h = try? await cloud.history(limit: 120) { remote = h; Store.save(h, "remote-history") }
        if let s = try? await cloud.stats(days: 30) { stats = s; Mixes.stats = s; Store.save(s, "stats-30") }
        await PlayCounts.shared.refresh()
        await Discovery.shared.refresh()
        await cloud.refreshDevices()
    }
}

/// Square card for a single song (plays on tap).
struct TrackCard: View {
    let t: Track
    var size: CGFloat = 150
    let play: () -> Void
    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 6) {
                Art(url: t.art, size: size).shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Text(t.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: size).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).foregroundStyle(.primary)
        .contextMenu { TrackMenu(t: t) }
    }
}

/// "Continue from <device>": pick up what another device was playing.
struct HandoffCard: View {
    @Environment(Cloud.self) var cloud
    @Environment(Player.self) var player
    var body: some View {
        if let d = candidate, let s = d.state, let t = s.current {
            HStack(spacing: 14) {
                Art(url: t.art, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Label(s.playing ? "Playing on \(d.name ?? "another device")" : "Continue from \(d.name ?? "another device")", systemImage: d.icon)
                        .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    Text(t.title).font(.headline).lineLimit(1)
                    Text("\(t.artist) · \(s.position.mmss)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { player.takeOver(d) } label: { Label("Play Here", systemImage: "play.fill").lineLimit(1) }.buttonStyle(.borderedProminent).fixedSize()
            }
            .padding(14)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, Theme.gutter)
        }
    }
    private var candidate: Device? {
        cloud.otherDevices
            .filter { d in
                guard let s = d.state, let t = s.current else { return false }
                return Double(nowMs() - s.at) < 6 * 3600 * 1000 && (t.id != player.current?.id || !player.playing)
            }
            .max { ($0.state?.at ?? 0) < ($1.state?.at ?? 0) }
    }
}

#if os(iOS)
struct ProfileMenu: View {
    @Environment(Router.self) var router
    var body: some View {
        Menu {
            Button { router.push(.stats) } label: { Label("Replay", systemImage: "chart.bar.xaxis") }
            Button { router.push(.settings) } label: { Label("Settings", systemImage: "gearshape") }
        } label: { Image(systemName: "person.crop.circle").font(.title3) }
    }
}
#endif
