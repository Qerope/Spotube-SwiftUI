import SwiftUI
import AVFoundation

@main struct SpotubeLiteApp: App {
    @State var plugins = PluginManager()
    @State var player = Player()
    @State var router = Router()
    init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
    var body: some Scene {
        WindowGroup(id: "main") {
            RootView().environment(plugins).environment(player).environment(router)
                .preferredColorScheme(.dark).tint(.green)
                .background(Color.black.ignoresSafeArea())
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Playback") {
                Button("Play/Pause") { player.toggle() }.keyboardShortcut(.space, modifiers: [])
                Button("Next") { player.next() }.keyboardShortcut(.rightArrow)
                Button("Previous") { player.prev() }.keyboardShortcut(.leftArrow)
            }
        }
        #endif
        #if os(macOS)
        // Menu bar player: music keeps playing with the window closed.
        MenuBarExtra {
            MenuBarPlayer().environment(player).environment(router).preferredColorScheme(.dark)
        } label: {
            Image(systemName: player.playing ? "waveform" : "music.note")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

struct Track: Codable, Identifiable, Hashable {
    var id: String; var title: String; var artist: String
    var album: String?; var art: String?; var duration: Double?
    var extra: [String: String]?
}

/// Playlist / album / liked-songs entry returned by `library()`.
struct Collection: Codable, Identifiable, Hashable {
    var id: String; var title: String; var subtitle: String?; var art: String?
}

#if os(macOS)
struct MenuBarPlayer: View {
    @Environment(Player.self) var p
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Art(url: p.current?.art, size: 48)
                VStack(alignment: .leading) {
                    Text(p.current?.title ?? "Not playing").lineLimit(1)
                    Text(p.loading ? "Loading…" : (p.current?.artist ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 28) {
                Button { p.prev() } label: { Image(systemName: "backward.fill") }
                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.title) }
                Button { p.next() } label: { Image(systemName: "forward.fill") }
            }.buttonStyle(.plain).font(.title3)
            Divider()
            HStack {
                Button("Open Spotube Lite") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).font(.caption)
        }
        .padding(14).frame(width: 300).background(.black)
    }
}
#endif
