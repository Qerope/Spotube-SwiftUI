import SwiftUI
import AVFoundation

@main struct SpotubeLiteApp: App {
    @State var plugins = PluginManager()
    @State var player = Player()
    init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(plugins).environment(player)
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
