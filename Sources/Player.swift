import AVFoundation
import MediaPlayer
import Observation

@MainActor @Observable final class Player {
    let av = AVPlayer()
    var queue: [Track] = []
    var index = 0
    var playing = false
    var progress = 0.0
    var error: String?
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    weak var plugins: PluginManager?

    init() {
        av.addPeriodicTimeObserver(forInterval: .init(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.progress = t.seconds }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        let rc = MPRemoteCommandCenter.shared()
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        rc.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        rc.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.prev() }; return .success }
    }

    func play(_ tracks: [Track], at i: Int) { queue = tracks; index = i; load() }
    func next() { if index + 1 < queue.count { index += 1; load() } else { playing = false } }
    func prev() { if progress > 3 || index == 0 { av.seek(to: .zero) } else { index -= 1; load() } }
    func toggle() { playing ? av.pause() : av.play(); playing.toggle(); nowPlaying() }
    func seek(_ s: Double) { av.seek(to: .init(seconds: s, preferredTimescale: 600)) }

    private func load() {
        guard let t = current, let src = plugins?.audio else { error = "No audio plugin"; return }
        error = nil; progress = 0
        Task {
            do {
                let s: String = try await src.call("stream", [try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))])
                guard let u = URL(string: s), t == current else { return }
                av.replaceCurrentItem(with: AVPlayerItem(url: u)); av.play(); playing = true; nowPlaying()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func nowPlaying() {
        guard let t = current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: t.duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0]
    }
}
