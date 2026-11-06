import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(PluginManager.self) var pm
    @Environment(Player.self) var player
    @State var full = false
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "house") }
            NavigationStack { SearchView() }.tabItem { Label("Search", systemImage: "magnifyingglass") }
            NavigationStack { PluginsView() }.tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
        }
        .safeAreaInset(edge: .bottom) { if player.current != nil { MiniPlayer().onTapGesture { full = true }.padding(.bottom, 52) } }
        .sheet(isPresented: $full) { FullPlayer() }
        .onAppear { player.plugins = pm }
    }
}

struct Art: View {
    let url: String?; var size: CGFloat = 48
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init)) { $0.resizable().scaledToFill() } placeholder: { Color(white: 0.08) }
            .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 10))
    }
}

struct TrackList: View {
    @Environment(Player.self) var player
    let tracks: [Track]
    var body: some View {
        List(Array(tracks.enumerated()), id: \.offset) { i, t in
            Button { player.play(tracks, at: i) } label: {
                HStack {
                    Art(url: t.art)
                    VStack(alignment: .leading) {
                        Text(t.title).foregroundStyle(player.current == t ? .green : .white).lineLimit(1)
                        Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }.listRowBackground(Color.black)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(.black)
    }
}

struct HomeView: View {
    @Environment(PluginManager.self) var pm
    @State var tracks: [Track] = []
    var body: some View {
        TrackList(tracks: tracks).navigationTitle("Spotube Lite")
            .overlay { if tracks.isEmpty { ContentUnavailableView("Nothing here", systemImage: "music.note", description: Text(pm.metadata?.name ?? "Install a metadata plugin")) } }
            .task(id: pm.metadata?.id) {
                guard let m = pm.metadata, m.has("home") else { return }
                tracks = (try? await m.call("home")) ?? []
            }
    }
}

struct SearchView: View {
    @Environment(PluginManager.self) var pm
    @State var q = ""
    @State var tracks: [Track] = []
    @State var err: String?
    var body: some View {
        TrackList(tracks: tracks).navigationTitle("Search")
            .searchable(text: $q).onSubmit(of: .search) {
                Task {
                    do { tracks = try await pm.metadata?.call("search", [q]) ?? []; err = nil } catch { err = error.localizedDescription }
                }
            }
            .overlay { if let err { Text(err).foregroundStyle(.red).padding() } }
    }
}

struct PluginsView: View {
    @Environment(PluginManager.self) var pm
    @State var url = ""
    @State var importing = false
    @State var err: String?
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
                    VStack(alignment: .leading) {
                        Text(p.name); Text("v\(p.version) · \(p.abilities.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }.swipeActions { Button("Delete", role: .destructive) { pm.remove(p) } }
                }
            }
            Section("Install") {
                TextField("https://…/plugin.js", text: $url).textInputAutocapitalization(.never).keyboardType(.URL)
                Button("Install from URL") { Task { await install(URL(string: url)) } }
                Button("Install from Files") { importing = true }
                if let err { Text(err).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden).background(.black).navigationTitle("Plugins")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { r in Task { await install(try? r.get()) } }
    }
    func install(_ u: URL?) async {
        guard let u else { return }
        do { try await pm.install(from: u); err = nil } catch { err = error.localizedDescription }
    }
}

extension Binding where Value == String {
    init(_ b: Binding<String?>, replacingNilWith d: String) { self.init(get: { b.wrappedValue ?? d }, set: { b.wrappedValue = $0 }) }
}

struct MiniPlayer: View {
    @Environment(Player.self) var p
    var body: some View {
        HStack {
            Art(url: p.current?.art, size: 40)
            VStack(alignment: .leading) {
                Text(p.current?.title ?? "").lineLimit(1)
                Text(p.error ?? p.current?.artist ?? "").font(.caption).foregroundStyle(p.error == nil ? .secondary : Color.red).lineLimit(1)
            }
            Spacer()
            Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.title2) }
            Button { p.next() } label: { Image(systemName: "forward.fill").font(.title2) }
        }
        .padding(10).background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 8).foregroundStyle(.white)
    }
}

struct FullPlayer: View {
    @Environment(Player.self) var p
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Art(url: p.current?.art, size: 320)
            VStack { Text(p.current?.title ?? "").font(.title2.bold()); Text(p.current?.artist ?? "").foregroundStyle(.secondary) }.lineLimit(1)
            let d = max(p.current?.duration ?? p.av.currentItem?.duration.seconds.nanSafe ?? 1, 1)
            Slider(value: Binding(get: { min(p.progress, d) }, set: { p.seek($0) }), in: 0...d)
            HStack(spacing: 48) {
                Button { p.prev() } label: { Image(systemName: "backward.fill") }
                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64)) }
                Button { p.next() } label: { Image(systemName: "forward.fill") }
            }.font(.title).foregroundStyle(.white)
            Spacer()
        }.padding(32).frame(maxWidth: .infinity).background(Color.black.ignoresSafeArea()).presentationBackground(.black)
    }
}

extension Double { var nanSafe: Double? { isFinite ? self : nil } }
