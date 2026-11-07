import SwiftUI

struct ArtistView: View {
    let c: Collection
    @Environment(Player.self) var player
    @Environment(Library.self) var lib
    @Environment(Router.self) var router
    @Environment(PluginManager.self) var pm
    @State private var page: ArtistPage?
    @State private var err: String?
    @State private var allTop = false
    @State private var bioOpen = false

    private var name: String { page.map { $0.name.isEmpty ? c.title : $0.name } ?? c.title }
    private var context: PlayContext { PlayContext(id: c.id, title: name, art: page?.art ?? c.art) }
    private var saveItem: Collection { Collection(id: c.id, title: name, subtitle: "Artist", art: page?.art ?? c.art, kind: "artist") }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                hero
                if let page {
                    buttons(page)
                    if !page.tracks.isEmpty { popular(page.tracks) }
                    let groups: [(String, [Collection])] = [
                        ("Albums", page.albums.filter { $0.kind == "album" }),
                        ("Singles & EPs", page.albums.filter { $0.kind == "single" || $0.kind == "ep" }),
                        ("Compilations", page.albums.filter { $0.kind == "compilation" }),
                        ("Other Releases", page.albums.filter { !["album", "single", "ep", "compilation"].contains($0.kind ?? "") }),
                        ("Appears On", page.appearsOn ?? []),
                    ]
                    ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { g in
                        Shelf(title: g.0) { ForEach(g.1) { CollectionCard(c: $0, size: 150) } }
                    }
                    if let r = page.related, !r.isEmpty {
                        Shelf(title: "Fans Also Like") { ForEach(r) { CollectionCard(c: $0, size: 130) } }
                    }
                    about(page)
                } else if let err {
                    ContentUnavailableView { Label("Couldn't load artist", systemImage: "exclamationmark.triangle") } description: { Text(err) }
                        actions: { Button("Try Again") { Task { await load() } } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.bottom, 30)
        }
        .scrollContentBackground(.hidden).background(.black)
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .navigationTitle(name)
        .task(id: "\(c.id)|\(pm.revision)") { await load() }
        .refreshable { await load() }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { g in
                Art(url: page?.header ?? page?.art ?? c.art, size: nil, radius: 0, square: false)
                    .frame(width: g.size.width, height: g.size.height).clipped()
            }
            LinearGradient(colors: [.clear, .black.opacity(0.3), .black], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 44, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.5).shadow(radius: 10)
                if let m = page?.monthlyListeners, m > 0 { Text("\(m.compact) monthly listeners").font(.subheadline).foregroundStyle(.secondary) }
            }.padding(Theme.gutter)
        }
        #if os(macOS)
        .frame(height: 320)
        #else
        .frame(height: 380)
        #endif
        .clipped()
    }

    private func buttons(_ p: ArtistPage) -> some View {
        HStack(spacing: 12) {
            PlayButtons(tracks: p.tracks, context: context)
            Button { player.startRadio(Track(id: "seed-" + c.id, title: name, artist: name, extra: ["artistUri": c.id])) } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }.buttonStyle(CapsuleButton()).help("Start Station")
            if !lib.isSavedInSpotify(saveItem) {
                Button { lib.toggleSave(saveItem); router.flash(lib.isSaved(saveItem) ? "Following \(name)" : "Unfollowed \(name)") } label: {
                    Image(systemName: lib.isSaved(saveItem) ? "checkmark" : "plus")
                }.buttonStyle(CapsuleButton()).help(lib.isSaved(saveItem) ? "Following" : "Follow")
            }
        }.padding(.horizontal, Theme.gutter)
    }

    private func popular(_ tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Top Songs").font(.title2.bold())
                Spacer()
                if tracks.count > 5 { Button(allTop ? "Show Less" : "Show All") { withAnimation { allTop.toggle() } }.buttonStyle(.borderless).foregroundStyle(.tint) }
            }
            ForEach(Array(tracks.prefix(allTop ? 50 : 5).enumerated()), id: \.offset) { i, t in
                TrackRow(t: t, trailing: t.plays.map { "\($0.compact) plays" }) { player.play(tracks, at: i, context: context) }
            }
        }.padding(.horizontal, Theme.gutter)
    }

    @ViewBuilder private func about(_ p: ArtistPage) -> some View {
        if !(p.bio ?? "").isEmpty || (p.followers ?? 0) > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text("About").font(.title2.bold())
                if let bio = p.bio, !bio.isEmpty {
                    Text(bio).foregroundStyle(.secondary).lineLimit(bioOpen ? nil : 5)
                    Button(bioOpen ? "Less" : "More") { withAnimation { bioOpen.toggle() } }.buttonStyle(.borderless).foregroundStyle(.tint)
                }
                HStack(spacing: 30) {
                    if let f = p.followers, f > 0 { stat("\(f.compact)", "Followers") }
                    if let m = p.monthlyListeners, m > 0 { stat("\(m.compact)", "Monthly Listeners") }
                }
                if let cities = p.topCities, !cities.isEmpty {
                    Text("Top cities: " + cities.prefix(5).joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, Theme.gutter)
        }
    }
    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading) { Text(v).font(.title3.bold()); Text(l).font(.caption).foregroundStyle(.secondary) }
    }

    private func load() async {
        if page == nil { page = Catalog.cachedArtist(c.id) }
        do { page = try await Catalog.artist(c.id); err = nil } catch { if page == nil { err = error.localizedDescription } }
    }
}
