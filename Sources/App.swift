import SwiftUI
import AVFoundation

@main struct SpotubeLiteApp: App {
    @State var router = Router()
    @AppStorage("accent") var accent = Theme.defaultAccent

    init() {
        PluginStorage.setup()
        // v2.1: the default accent became Apple Music red; move everyone off the old green default once.
        if !UserDefaults.standard.bool(forKey: "accentV2") {
            UserDefaults.standard.set("Red", forKey: "accent"); UserDefaults.standard.set(true, forKey: "accentV2")
        }
        Cloud.shared.start()
        _ = Library.shared
        let flush = { MainActor.assumeIsolated { Player.shared.flush(); Task { await Cloud.shared.syncNow() } } }
        #if os(macOS)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in flush() }
        // Space = play/pause anywhere except while typing (a menu shortcut would eat spaces in text fields).
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 49, e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
            MainActor.assumeIsolated { Player.shared.toggle() }
            return nil
        }
        #else
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in flush() }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Task { await Cloud.shared.hello(); await Cloud.shared.syncNow() } }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(PluginManager.shared).environment(Player.shared).environment(router)
                .environment(Library.shared).environment(Downloads.shared).environment(Cloud.shared)
                .preferredColorScheme(.dark).tint(Theme.color(accent))
                #if os(macOS)
                .frame(minWidth: 900, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Playlist") { router.newPlaylistTracks = [] }.keyboardShortcut("n")
                Button("New Smart Playlist") { router.smartEdit = SmartEdit() }.keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { router.sidebar = .search; router.focusSearch = true }.keyboardShortcut("f")
            }
            CommandMenu("Playback") {
                Button(Player.shared.playing ? "Pause" : "Play") { Player.shared.toggle() }
                Button("Next") { Player.shared.next() }.keyboardShortcut(.rightArrow)
                Button("Previous") { Player.shared.prev() }.keyboardShortcut(.leftArrow)
                Button("Forward 10 Seconds") { Player.shared.skip(10) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Back 10 Seconds") { Player.shared.skip(-10) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Divider()
                Button("Volume Up") { Player.shared.volume = min(1, Player.shared.volume + 0.1) }.keyboardShortcut(.upArrow)
                Button("Volume Down") { Player.shared.volume = max(0, Player.shared.volume - 0.1) }.keyboardShortcut(.downArrow)
                Divider()
                Button("Love Current Song") { if let t = Player.shared.current { Library.shared.toggleLike(t) } }.keyboardShortcut("l")
                Button("Shuffle") { Player.shared.shuffle.toggle() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Repeat") { Player.shared.cycleRepeat() }.keyboardShortcut("r")
                Divider()
                Button("Now Playing") { router.showFull.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Lyrics") { router.showFull = true; router.panel = .lyrics }.keyboardShortcut("u", modifiers: [.command, .option])
                Button("Up Next") { router.showQueue.toggle() }.keyboardShortcut("u")
            }
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsView().frame(width: 560, height: 620)
                .environment(PluginManager.shared).environment(Player.shared).environment(router)
                .environment(Library.shared).environment(Downloads.shared).environment(Cloud.shared)
                .preferredColorScheme(.dark).tint(Theme.color(accent))
        }
        // Menu bar player: music keeps playing with the window closed.
        MenuBarExtra {
            MenuBarPlayer().environment(Player.shared).environment(router).environment(Library.shared).preferredColorScheme(.dark)
        } label: {
            Image(systemName: Player.shared.playing ? "waveform" : "music.note")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

enum Theme {
    static let defaultAccent = "Red"
    /// Apple Music red (#FA2D48).
    static let red = Color(red: 250 / 255, green: 45 / 255, blue: 72 / 255)
    static let accents: [(String, Color)] = [
        ("Red", red), ("Green", Color(red: 0.12, green: 0.84, blue: 0.38)),
        ("Pink", Color(red: 1, green: 0.33, blue: 0.6)), ("Orange", .orange), ("Yellow", .yellow),
        ("Blue", Color(red: 0.25, green: 0.55, blue: 1)), ("Purple", Color(red: 0.62, green: 0.4, blue: 1)), ("Teal", .teal),
    ]
    static func color(_ name: String) -> Color { accents.first { $0.0 == name }?.1 ?? accents[0].1 }
    #if os(macOS)
    static let gutter: CGFloat = 24
    #else
    static let gutter: CGFloat = 16
    #endif
}

#if os(macOS)
struct MenuBarPlayer: View {
    @Environment(Player.self) var p
    @Environment(Library.self) var lib
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Art(url: p.current?.art, size: 52)
                VStack(alignment: .leading) {
                    Text(p.current?.title ?? "Not playing").lineLimit(1)
                    Text(p.loading ? "Loading…" : (p.current?.artist ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let t = p.current {
                    Button { lib.toggleLike(t) } label: { Image(systemName: lib.isLiked(t) ? "heart.fill" : "heart") }.buttonStyle(.plain).foregroundStyle(.tint)
                }
            }
            SeekBar(compact: true)
            HStack(spacing: 28) {
                Button { p.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(p.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) }
                Button { p.prev() } label: { Image(systemName: "backward.fill") }
                Button { p.toggle() } label: { Image(systemName: p.playing ? "pause.fill" : "play.fill").font(.title) }
                Button { p.next() } label: { Image(systemName: "forward.fill") }
                Button { p.cycleRepeat() } label: { Image(systemName: p.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(p.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)) }
            }.buttonStyle(.plain).font(.title3)
            Divider()
            HStack {
                Button("Open Lyd") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.borderless).font(.caption)
        }
        .padding(14).frame(width: 320).background(.black)
    }
}
#endif
