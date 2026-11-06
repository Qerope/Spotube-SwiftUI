import SwiftUI
import AVFoundation

@main struct SpotubeLiteApp: App {
    @State var plugins = PluginManager()
    @State var player = Player()
    init() { try? AVAudioSession.sharedInstance().setCategory(.playback) }
    var body: some Scene {
        WindowGroup {
            RootView().environment(plugins).environment(player)
                .preferredColorScheme(.dark).tint(.green)
                .background(Color.black.ignoresSafeArea())
        }
    }
}

struct Track: Codable, Identifiable, Hashable {
    var id: String; var title: String; var artist: String
    var album: String?; var art: String?; var duration: Double?
    var extra: [String: String]?
}
