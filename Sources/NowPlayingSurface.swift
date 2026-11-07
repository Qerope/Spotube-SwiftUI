#if os(iOS)
import ActivityKit
import UIKit
import WidgetKit

/// Lock Screen / Dynamic Island Live Activity and the Now Playing widget, kept in step with the player.
@MainActor final class NowPlayingSurface {
    static let shared = NowPlayingSurface()
    private var activity: Activity<NowPlayingAttributes>?
    private var artFor: String?
    private var thumb: Data?
    private var lastState: NowPlayingAttributes.ContentState?
    private var lastWidget: (String, Bool)?
    private var endTask: Task<Void, Never>?
    var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true }

    private init() {
        // Leftovers from a previous run (app killed while playing).
        for a in Activity<NowPlayingAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NowPlayingSurface.shared.endNow() }
        }
    }

    func update(track: Track?, playing: Bool, position: Double, duration: Double, liked: Bool) {
        guard let t = track else { endNow(); SharedPlayer.save(nil); reloadWidget(nil); return }
        if artFor != t.id { artFor = t.id; thumb = nil; loadArt(t) }
        let state = NowPlayingAttributes.ContentState(title: t.title, artist: t.artist, playing: playing,
                                                      start: playing ? Date().addingTimeInterval(-position) : nil,
                                                      position: position, duration: duration, art: thumb, liked: liked)
        SharedPlayer.save(.init(title: t.title, artist: t.artist, album: t.album, playing: playing, position: position, duration: duration, updated: .now))
        reloadWidget((t.id, playing))
        push(state)
    }

    private func push(_ s: NowPlayingAttributes.ContentState) {
        // Skip redundant updates (same song/state, progress drift under 2 s).
        if let l = lastState, l.title == s.title, l.playing == s.playing, l.art == s.art, l.liked == s.liked, l.duration == s.duration,
           abs((l.start ?? .distantPast).timeIntervalSince(s.start ?? .distantPast)) < 2, l.playing || abs(l.position - s.position) < 2 { return }
        lastState = s
        endTask?.cancel()
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { endNow(); return }
        let content = ActivityContent(state: s, staleDate: nil)
        if let a = activity, a.activityState == .active {
            Task { await a.update(content) }
        } else if s.playing {
            activity = try? Activity.request(attributes: NowPlayingAttributes(), content: content)
        }
        // Like Apple Music: the activity goes away a while after you pause.
        if !s.playing {
            endTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15 * 60))
                guard !Task.isCancelled else { return }
                self?.endNow()
            }
        }
    }

    func endNow() {
        endTask?.cancel()
        let all = Activity<NowPlayingAttributes>.activities
        activity = nil; lastState = nil
        for a in all { Task { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    private func reloadWidget(_ key: (String, Bool)?) {
        if let k = key, let l = lastWidget, l == k { return }
        lastWidget = key
        WidgetCenter.shared.reloadTimelines(ofKind: "NowPlaying")
    }

    private func loadArt(_ t: Track) {
        guard let u = t.art else { return }
        Task {
            guard let img = await ImageStore.shared.image(u), artFor == t.id else { return }
            // Widget: a decent size in the shared container. Live Activity: a tiny JPEG that fits the 4 KB budget.
            if let url = SharedPlayer.artURL, let big = img.resized(300).jpegData(compressionQuality: 0.8) { try? big.write(to: url, options: .atomic) }
            let small = img.resized(60)
            var q: CGFloat = 0.6
            var d = small.jpegData(compressionQuality: q)
            while let x = d, x.count > 2600, q > 0.15 { q -= 0.15; d = small.jpegData(compressionQuality: q) }
            thumb = (d?.count ?? .max) <= 2600 ? d : nil
            WidgetCenter.shared.reloadTimelines(ofKind: "NowPlaying")
            if var s = lastState { s.art = thumb; lastState = nil; push(s) }
        }
    }
}

private extension UIImage {
    func resized(_ side: CGFloat) -> UIImage {
        let f = UIGraphicsImageRendererFormat.default(); f.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: f).image { _ in
            let s = max(side / size.width, side / size.height)
            draw(in: CGRect(x: (side - size.width * s) / 2, y: (side - size.height * s) / 2, width: size.width * s, height: size.height * s))
        }
    }
}
#endif
