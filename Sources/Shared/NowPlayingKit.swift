// Shared by the app and the widget extension: Live Activity attributes, the widget snapshot and playback intents.
#if os(iOS)
import ActivityKit
import AppIntents
import Foundation

struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var playing: Bool
        /// When position 0 was (while playing), so the progress bar runs by itself.
        var start: Date?
        var position: Double
        var duration: Double
        /// Tiny JPEG thumbnail (a Live Activity can't load images itself and has a 4 KB budget).
        var art: Data?
        var liked: Bool = false
    }
}

/// Snapshot of the player the widgets read, in the shared App Group container.
enum SharedPlayer {
    struct Snapshot: Codable {
        var title: String; var artist: String; var album: String?
        var playing: Bool; var position: Double; var duration: Double; var updated: Date
    }
    /// AltStore/SideStore rename App Groups when re-signing and list the real ones under ALTAppGroups.
    static var group: String { (Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String])?.first ?? "group.dev.qerope.SpotubeLite" }
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var artURL: URL? { container?.appendingPathComponent("nowplaying.jpg") }

    static func load() -> Snapshot? {
        guard let u = container?.appendingPathComponent("nowplaying.json"), let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: d)
    }
    static func save(_ s: Snapshot?) {
        guard let u = container?.appendingPathComponent("nowplaying.json") else { return }
        if let s, let d = try? JSONEncoder().encode(s) { try? d.write(to: u, options: .atomic) } else { try? FileManager.default.removeItem(at: u) }
    }
}

enum PlayerAction: String { case toggle, next, previous }

/// The app sets this at launch; intents run inside the app process (AudioPlaybackIntent).
@MainActor enum RemoteControl { static var handler: ((PlayerAction) -> Void)? }

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult { RemoteControl.handler?(.toggle); return .result() }
}
struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult { RemoteControl.handler?(.next); return .result() }
}
struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    static let isDiscoverable = false
    init() {}
    @MainActor func perform() async throws -> some IntentResult { RemoteControl.handler?(.previous); return .result() }
}
#endif
