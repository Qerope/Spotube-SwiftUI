import AVFoundation
import MediaPlayer
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum RepeatMode: String, Codable, CaseIterable { case off, all, one }

@MainActor @Observable final class Player {
    let av = AVPlayer()
    /// Play order (shuffled when shuffle is on); `original` keeps the source order.
    var queue: [Track] = []
    private var original: [Track] = []
    var index = 0
    var playing = false
    var progress = 0.0
    var error: String?
    var loading = false
    var shuffle = false { didSet { if shuffle != oldValue { applyShuffle() } } }
    var repeatMode: RepeatMode = .off { didSet { save() } }
    var autoplay = true { didSet { save() } }
    var volume: Float = 1 { didSet { av.volume = volume; save() } }
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var duration: Double? { av.currentItem?.duration.seconds.nanSafe ?? current?.duration }
    var upcoming: ArraySlice<Track> { queue.indices.contains(index + 1) ? queue[(index + 1)...] : [] }
    weak var plugins: PluginManager?

    /// Most recent first, de-duplicated.
    var history: [Track] = Store.load([Track].self, "history")
        ?? (try? JSONDecoder().decode([Track].self, from: Data(contentsOf: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SpotubeLite-history.json")))) ?? []

    private var generation = 0
    private var resumeAt: Double?
    /// Resolved playable files/URLs per track id, and in-flight resolutions (shared by play + prefetch).
    private var ready: [String: (url: URL, note: String?)] = [:]
    private var resolving: [String: Task<(url: URL, note: String?), Error>] = [:]

    init() {
        restore()
        av.volume = volume
        av.addPeriodicTimeObserver(forInterval: .init(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progress = t.seconds
                if Int(t.seconds * 2) % 20 == 0 { self.save() }   // every ~10 s
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.av.currentItem else { return }
                self.advance(auto: true)
            }
        }
        let rc = MPRemoteCommandCenter.shared()
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        rc.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.playing == false { self?.toggle() } }; return .success }
        rc.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { if self?.playing == true { self?.toggle() } }; return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.prev() }; return .success }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            MainActor.assumeIsolated { if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) } }; return .success
        }
    }

    // MARK: Queue control

    func play(_ tracks: [Track], at i: Int) {
        guard tracks.indices.contains(i) else { return }
        original = tracks
        if shuffle { var rest = tracks; let first = rest.remove(at: i); queue = [first] + rest.shuffled(); index = 0 }
        else { queue = tracks; index = i }
        load()
    }
    func jump(to i: Int) { guard queue.indices.contains(i) else { return }; index = i; load() }
    func next() { advance(auto: false) }
    func prev() {
        if progress > 3 || (index == 0 && repeatMode != .all) { seek(0); return }
        index = index == 0 ? queue.count - 1 : index - 1; load()
    }
    func playNext(_ t: Track) {
        if queue.isEmpty { play([t], at: 0); return }
        queue.insert(t, at: index + 1); original.append(t); save(); prefetch()
    }
    func addToQueue(_ t: Track) {
        if queue.isEmpty { play([t], at: 0); return }
        queue.append(t); original.append(t); save()
    }
    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let t = queue.remove(at: i); original.removeAll { $0.id == t.id }
        if i < index { index -= 1 }
        save()
    }
    func move(from: IndexSet, to: Int) {
        let cur = current
        queue.move(fromOffsets: from, toOffset: to)
        if let cur, let i = queue.firstIndex(of: cur) { index = i }
        save()
    }
    func cycleRepeat() { repeatMode = RepeatMode.allCases[(RepeatMode.allCases.firstIndex(of: repeatMode)! + 1) % 3] }

    func toggle() {
        guard av.currentItem != nil else { if current != nil, !loading { load() }; return }
        playing ? av.pause() : av.play(); playing.toggle(); nowPlaying()
    }
    func seek(_ s: Double) { av.seek(to: .init(seconds: s, preferredTimescale: 600)); progress = s; nowPlaying() }

    private func advance(auto: Bool) {
        if auto, repeatMode == .one { seek(0); av.play(); return }
        if index + 1 < queue.count { index += 1; load(); return }
        if repeatMode == .all, !queue.isEmpty { index = 0; load(); return }
        if autoplay {
            Task {
                await extendWithRadio()
                if index + 1 < queue.count { index += 1; load() } else { playing = false }
            }
            return
        }
        playing = false; av.pause()
    }

    private func applyShuffle() {
        guard let cur = current else { save(); return }
        if shuffle {
            original = queue
            var rest = queue; rest.remove(at: index)
            queue = [cur] + rest.shuffled(); index = 0
        } else if !original.isEmpty {
            queue = original; index = queue.firstIndex(of: cur) ?? 0
        }
        save(); prefetch()
    }

    /// Autoplay: when the queue runs out, continue with the current artist's popular songs.
    private func extendWithRadio() async {
        guard let m = plugins?.metadata, let t = current ?? queue.last else { return }
        var more: [Track] = []
        if m.has("radio") { more = (try? await m.call("radio", [try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))])) ?? [] }
        else if let a = t.extra?["artistUri"], m.has("artist") {
            struct Page: Decodable { var tracks: [Track] }
            more = ((try? await m.call("artist", [a]) as Page)?.tracks) ?? []
        }
        let have = Set(queue.map(\.id))
        let fresh = more.filter { !have.contains($0.id) }.shuffled().prefix(10)
        guard !fresh.isEmpty else { return }
        queue += fresh; original += fresh; save()
    }

    // MARK: Loading

    private var sources: [JSPlugin] {
        guard let pm = plugins else { return [] }
        return ([pm.audio] + pm.plugins.filter { $0.abilities.contains("audio") && $0.id != pm.audio?.id }).compactMap { $0 }
    }

    /// Resolve a track to a playable URL once (cached + de-duplicated between playback and prefetch).
    private func resolve(_ t: Track, skipping skip: Set<String> = []) async throws -> (url: URL, note: String?) {
        if skip.isEmpty, let r = ready[t.id], !r.url.isFileURL || FileManager.default.fileExists(atPath: r.url.path) { return r }
        if skip.isEmpty, let task = resolving[t.id] { return try await task.value }
        let srcs = sources.filter { !skip.contains($0.id) }
        let task = Task { () throws -> (url: URL, note: String?) in
            guard !srcs.isEmpty else { throw NSError(domain: "audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio plugin"]) }
            var errs: [String] = []
            let arg = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))
            for src in srcs {
                do {
                    let s: StreamResult = try await src.call("stream", [arg])
                    guard let u = URL(string: s.url) else { continue }
                    let url = (s.headers != nil && !u.isFileURL)
                        ? try await ChunkedDownload.file(u, headers: s.headers ?? [:], key: "\(src.id)-\(t.id)") : u
                    return (url, errs.isEmpty && src.id == srcs.first?.id ? nil : "via \(src.name)")
                } catch { errs.append("\(src.name): \(error.localizedDescription)") }
            }
            throw NSError(domain: "audio", code: 2, userInfo: [NSLocalizedDescriptionKey: errs.joined(separator: " · ")])
        }
        if skip.isEmpty { resolving[t.id] = task }
        defer { if skip.isEmpty { resolving[t.id] = nil } }
        let r = try await task.value
        ready[t.id] = r
        return r
    }

    private func load() {
        guard let t = current else { return }
        generation += 1
        let gen = generation, start = resumeAt
        resumeAt = nil
        error = nil; progress = start ?? 0; loading = true
        av.pause(); av.replaceCurrentItem(with: nil)
        nowPlaying(); save()
        // Start warming neighbours right away instead of after the current track is ready.
        Task { try? await Task.sleep(for: .seconds(1)); if gen == generation { warm() } }
        Task {
            var skip = Set<String>()
            while gen == generation {
                do {
                    let r = try await resolve(t, skipping: skip)
                    guard gen == generation else { return }
                    let item = AVPlayerItem(url: r.url)
                    av.replaceCurrentItem(with: item)
                    if let start { await av.seek(to: .init(seconds: start, preferredTimescale: 600)) }
                    av.play()
                    for _ in 0..<150 where item.status == .unknown { try await Task.sleep(for: .milliseconds(100)) }
                    guard gen == generation else { return }
                    guard item.status == .readyToPlay else {
                        // Broken file/stream: drop it and try the remaining sources.
                        if r.url.isFileURL { try? FileManager.default.removeItem(at: r.url) }
                        ready[t.id] = nil
                        if let first = sources.first(where: { !skip.contains($0.id) }) { skip.insert(first.id) } else { throw item.error ?? URLError(.cannotDecodeContentData) }
                        continue
                    }
                    loading = false; playing = true; error = r.note
                    nowPlaying(); remember(t); prefetch()
                    return
                } catch {
                    if gen == generation { self.error = error.localizedDescription; loading = false; playing = false }
                    return
                }
            }
        }
    }

    /// Warm the cache around the current track (next two + previous) so skipping is instant.
    private func prefetch() {
        if autoplay, repeatMode == .off, index >= queue.count - 2 { Task { await extendWithRadio(); warm() } } else { warm() }
    }
    private func warm() {
        var around = [index + 1, index + 2, index - 1].filter { queue.indices.contains($0) && $0 != index }
        if repeatMode == .all, index == queue.count - 1, !queue.isEmpty { around.append(0) }
        for i in around { let t = queue[i]; Task { _ = try? await resolve(t) } }
    }

    // MARK: History, persistence, now playing

    private func remember(_ t: Track) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        Store.save(history, "history")
    }
    func clearHistory() { history = []; Store.save(history, "history") }

    private struct State: Codable {
        var queue: [Track]; var original: [Track]; var index: Int; var progress: Double
        var shuffle: Bool; var repeatMode: RepeatMode; var autoplay: Bool; var volume: Float
    }
    private func save() {
        Store.save(State(queue: queue, original: original, index: index, progress: progress, shuffle: shuffle,
                         repeatMode: repeatMode, autoplay: autoplay, volume: volume), "player")
    }
    private func restore() {
        guard let s = Store.load(State.self, "player") else { return }
        queue = s.queue; original = s.original; index = s.index; shuffle = s.shuffle
        repeatMode = s.repeatMode; autoplay = s.autoplay; volume = s.volume
        progress = s.progress; resumeAt = s.progress > 1 ? s.progress : nil
    }

    private var artworkFor: String?
    private func nowPlaying() {
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration ?? 0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0]
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        if let old = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork], artworkFor == t.id { info[MPMediaItemPropertyArtwork] = old }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        guard artworkFor != t.id, let s = t.art, let u = URL(string: s) else { return }
        artworkFor = t.id
        Task {
            guard let (d, _) = try? await URLSession.shared.data(from: u) else { return }
            #if os(macOS)
            guard let img = NSImage(data: d) else { return }
            #else
            guard let img = UIImage(data: d) else { return }
            #endif
            guard current?.id == t.id else { return }
            var i = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            i[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = i
        }
    }
}

/// Small JSON persistence in Application Support.
enum Store {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SpotubeLite")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()
    static func load<T: Decodable>(_ t: T.Type, _ name: String) -> T? {
        (try? Data(contentsOf: dir.appending(path: name + ".json"))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    static func save<T: Encodable>(_ v: T, _ name: String) {
        try? JSONEncoder().encode(v).write(to: dir.appending(path: name + ".json"), options: .atomic)
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
