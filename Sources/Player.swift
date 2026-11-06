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
        guard let t = current, let pm = plugins else { return }
        // Active audio plugin first, then every other audio plugin as fallback.
        let sources = ([pm.audio] + pm.plugins.filter { $0.abilities.contains("audio") && $0.id != pm.audio?.id }).compactMap { $0 }
        guard !sources.isEmpty else { error = "No audio plugin"; return }
        error = nil; progress = 0
        Task {
            var errs: [String] = []
            for src in sources {
                do {
                    let s: StreamResult = try await src.call("stream", [try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))])
                    guard let u = URL(string: s.url) else { continue }
                    guard t == current else { return }
                    // Hosts that reject open-ended ranges (googlevideo): fetch in bounded chunks to a cache file.
                    let playURL = (s.headers != nil || u.host?.contains("googlevideo") == true)
                        ? try await ChunkedDownload.file(u, headers: s.headers ?? [:], key: "\(src.id)-\(t.id)") : u
                    guard t == current else { return }
                    av.replaceCurrentItem(with: AVPlayerItem(url: playURL)); av.play(); playing = true
                    error = errs.isEmpty ? nil : "via \(src.name)"; nowPlaying(); return
                } catch { errs.append("\(src.name): \(error.localizedDescription)") }
            }
            if t == current { self.error = errs.joined(separator: " · ") }
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

/// `stream()` may return a URL string or `{ url, headers }`.
struct StreamResult: Decodable {
    var url: String; var headers: [String: String]?
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) { url = s; return }
        let c = try d.container(keyedBy: K.self)
        url = try c.decode(String.self, forKey: .url); headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
    }
    enum K: CodingKey { case url, headers }
}

enum ChunkedDownload {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "audio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()
    /// Downloads `url` with bounded Range requests (1 MiB, 4 in parallel) and returns a local file URL (cached by key).
    static func file(_ url: URL, headers: [String: String], key: String) async throws -> URL {
        let dst = dir.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".m4a")
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        let chunk = 1 << 20
        func get(_ a: Int, _ b: Int) async throws -> (Data, HTTPURLResponse) {
            var r = URLRequest(url: url); headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("bytes=\(a)-\(b)", forHTTPHeaderField: "Range")
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard let h = resp as? HTTPURLResponse, h.statusCode == 206 || h.statusCode == 200 else {
                throw NSError(domain: "audio", code: (resp as? HTTPURLResponse)?.statusCode ?? 0, userInfo: [NSLocalizedDescriptionKey: "Stream HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
            }
            return (d, h)
        }
        let (first, h) = try await get(0, chunk - 1)
        let total = Int((h.value(forHTTPHeaderField: "Content-Range") ?? "").split(separator: "/").last ?? "") ?? first.count
        var parts = [0: first]
        try await withThrowingTaskGroup(of: (Int, Data).self) { g in
            var next = chunk, running = 0
            func add() { let a = next; next += chunk; running += 1; g.addTask { (a, try await get(a, min(a + chunk, total) - 1).0) } }
            while next < total && running < 4 { add() }
            while let (a, d) = try await g.next() { parts[a] = d; running -= 1; if next < total { add() } }
        }
        var data = Data(capacity: total)
        for k in parts.keys.sorted() { data.append(parts[k]!) }
        try data.write(to: dst, options: .atomic)
        return dst
    }
}
