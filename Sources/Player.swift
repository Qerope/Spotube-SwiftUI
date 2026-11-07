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
    static let shared = Player()
    /// The player for the current song. During a crossfade a fresh one takes over and `fader` fades the old song out.
    private(set) var av = AVPlayer()
    private var fader: AVPlayer?
    private var fadeTask: Task<Void, Never>?
    private var timeObserver: Any?
    /// Crossfade length in seconds (0 = off). Like Apple Music, it only applies when songs advance on their own.
    var crossfade = UserDefaults.standard.object(forKey: "crossfade") as? Double ?? 6 { didSet { UserDefaults.standard.set(crossfade, forKey: "crossfade") } }
    /// Play order (shuffled when shuffle is on); `original` keeps the source order.
    var queue: [Track] = []
    private var original: [Track] = []
    var index = 0
    var playing = false
    var progress = 0.0
    var error: String?
    var loading = false
    /// Where the current song comes from: Downloaded, Cached, Server, yt-dlp, …
    var source: String?
    var context: PlayContext?
    var shuffle = false { didSet { if shuffle != oldValue { applyShuffle() } } }
    var repeatMode: RepeatMode = .off { didSet { save(); updateRemoteModes() } }
    var autoplay = true { didSet { save() } }
    var volume: Float = 1 { didSet { if fadeTask == nil { av.volume = volume }; save() } }
    var sleepAt: Date? { didSet { sleepEndOfTrack = sleepAt == nil ? sleepEndOfTrack : false } }
    var sleepEndOfTrack = false
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var duration: Double? { av.currentItem?.duration.seconds.nanSafe ?? current?.duration }
    var upcoming: ArraySlice<Track> { queue.indices.contains(index + 1) ? queue[(index + 1)...] : [] }
    var plugins: PluginManager { PluginManager.shared }

    /// Most recent first, de-duplicated (this device).
    var history: [Track] = Store.load([Track].self, "history") ?? []

    private var generation = 0
    private var resumeAt: Double?
    private var failures = 0
    private struct Resolved { var url: URL; var note: String?; var key: String?; var source: String }
    private var ready: [String: Resolved] = [:]
    private var resolving: [String: Task<Resolved, Error>] = [:]
    private struct Session { var uid = UUID().uuidString; var track: Track; var started = Date(); var listened = 0.0; var source: String; var context: PlayContext? }
    private var session: Session?
    private var lastTick = Date()

    private init() {
        restore()
        attach(makePlayer())
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, (n.object as? AVPlayerItem) === self.av.currentItem else { return }
                self.finishSession(completed: true)
                self.advance(auto: true)
            }
        }
        setupRemoteCommands()
        #if os(iOS)
        setupAudioSession()
        RemoteControl.handler = { [weak self] a in
            switch a { case .toggle: self?.toggle(); case .next: self?.next(); case .previous: self?.prev() }
        }
        #endif
        Cloud.shared.onCommand = { [weak self] cmd, args in
            guard let self else { return }
            switch cmd {
            case "pause": self.pause()
            #if os(macOS)
            case "fetch":
                guard let v = args["videoId"] else { return }
                Task { if let f = try? await YtDlp.audio("https://www.youtube.com/watch?v=" + v) { await Cloud.shared.share(videoId: v, file: f) } }
            #endif
            default: break
            }
        }
    }

    private func makePlayer() -> AVPlayer {
        let p = AVPlayer()
        p.volume = volume
        p.isMuted = UserDefaults.standard.bool(forKey: "debugMute")
        return p
    }
    private func attach(_ p: AVPlayer) {
        if let o = timeObserver { av.removeTimeObserver(o) }
        av = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: .init(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    // MARK: Crossfade

    /// The song that plays next when this one ends on its own (nil when it won't simply move on).
    private var autoNextIndex: Int? {
        if repeatMode == .one || sleepEndOfTrack || sleepAt.map({ $0 < .now.addingTimeInterval(crossfade) }) == true { return nil }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all && queue.count > 1 ? 0 : nil
    }
    private func maybeCrossfade(_ seconds: Double) {
        guard crossfade > 0, playing, !loading, fader == nil, av.rate > 0,
              let d = av.currentItem?.duration.seconds.nanSafe, d > crossfade * 2 + 10,
              d - seconds <= crossfade, d - seconds > 1, let i = autoNextIndex else { return }
        // Only when the next song is ready locally (or resolved): a crossfade must never turn into silence.
        let t = queue[i]
        guard Downloads.shared.file(for: t.id) != nil || ready[t.id] != nil else { return }
        NSLog("[Player] crossfade %.0fs → %@", crossfade, t.title)
        finishSession(completed: true)
        fader = av
        index = i
        load(crossfadeFrom: av)
    }
    /// Equal-power fade from `old` to the current player over `seconds` (uses the time `old` has left).
    private func runFade(from old: AVPlayer) {
        let new = av
        let left = (old.currentItem?.duration.seconds.nanSafe ?? 0) - old.currentTime().seconds
        let length = max(1, min(crossfade, left.isFinite ? left : crossfade))
        let start = Date()
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let x = min(1, Date().timeIntervalSince(start) / length)
                old.volume = self.volume * Float(cos(x * .pi / 2))
                new.volume = self.volume * Float(sin(x * .pi / 2))
                if x >= 1 { break }
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard let self, !Task.isCancelled else { return }
            NSLog("[Player] crossfade finished")
            self.endFade()
        }
    }
    /// Stops the outgoing song immediately (skip, pause, new queue…) and restores full volume.
    private func endFade() {
        fadeTask?.cancel(); fadeTask = nil
        fader?.pause(); fader?.replaceCurrentItem(with: nil); fader = nil
        av.volume = volume
    }

    private func tick(_ seconds: Double) {
        let now = Date(), dt = now.timeIntervalSince(lastTick)
        lastTick = now
        progress = seconds
        maybeCrossfade(seconds)
        if playing, av.rate > 0, dt < 2 { session?.listened += dt }
        if let s = sleepAt, now >= s { sleepAt = nil; pause() }
        if Int(seconds * 2) % 20 == 0 { save() }
        if Int(seconds * 2) % 30 == 0 { publish() }
    }

    // MARK: Queue control

    func play(_ tracks: [Track], at i: Int = 0, context: PlayContext? = nil) {
        guard tracks.indices.contains(i) else { return }
        original = tracks
        self.context = context
        if shuffle { var rest = tracks; let first = rest.remove(at: i); queue = [first] + rest.shuffled(); index = 0 }
        else { queue = tracks; index = i }
        failures = 0
        load()
    }
    func playShuffled(_ tracks: [Track], context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if !shuffle { shuffle = true }
        play(tracks, at: Int.random(in: tracks.indices), context: context)
    }
    /// "Start Station": this song followed by an endless radio of similar songs.
    func startRadio(_ t: Track) {
        play([t], context: PlayContext(id: "radio:" + t.id, title: "\(t.title) Station", art: t.art))
        Task { await extendWithRadio(seed: t) }
    }
    func jump(to i: Int) { guard queue.indices.contains(i) else { return }; index = i; failures = 0; load() }
    func next() { advance(auto: false) }
    func prev() {
        if progress > 3 || (index == 0 && repeatMode != .all) { seek(0); return }
        index = index == 0 ? queue.count - 1 : index - 1; load()
    }
    func playNext(_ tracks: [Track]) {
        if queue.isEmpty { play(tracks); return }
        queue.insert(contentsOf: tracks, at: index + 1); original.append(contentsOf: tracks); save(); prefetch()
    }
    func addToQueue(_ tracks: [Track]) {
        if queue.isEmpty { play(tracks); return }
        queue.append(contentsOf: tracks); original.append(contentsOf: tracks); save()
    }
    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let t = queue.remove(at: i)
        if let j = original.firstIndex(of: t) { original.remove(at: j) }
        if i < index { index -= 1 }
        save()
    }
    func clearUpcoming() {
        guard queue.indices.contains(index) else { return }
        queue.removeSubrange((index + 1)...); original = queue; save()
    }
    func move(from: IndexSet, to: Int) {
        let cur = current
        queue.move(fromOffsets: from, toOffset: to)
        if let cur, let i = queue.firstIndex(of: cur) { index = i }
        save()
    }
    func cycleRepeat() { repeatMode = RepeatMode.allCases[(RepeatMode.allCases.firstIndex(of: repeatMode)! + 1) % 3] }

    func toggle() { playing ? pause() : resume() }
    func pause() { endFade(); av.pause(); playing = false; nowPlaying(); save(); publish(force: true) }
    func resume() {
        guard av.currentItem != nil else { if current != nil, !loading { load() }; return }
        if sleepAt.map({ $0 < .now }) == true { sleepAt = nil }
        av.play(); playing = true; nowPlaying(); publish(force: true)
    }
    func seek(_ s: Double) { av.seek(to: .init(seconds: s, preferredTimescale: 600)); progress = s; nowPlaying() }
    func skip(_ by: Double) { seek(max(0, min(progress + by, (duration ?? progress) - 1))) }

    func setSleep(minutes: Int?) { sleepEndOfTrack = false; sleepAt = minutes.map { Date().addingTimeInterval(Double($0) * 60) } }
    func setSleepEndOfTrack() { sleepAt = nil; sleepEndOfTrack = true }

    private func advance(auto: Bool) {
        if auto, sleepEndOfTrack { sleepEndOfTrack = false; pause(); seek(0); return }
        if auto, repeatMode == .one { seek(0); av.play(); return }
        failures = auto ? failures : 0
        if index + 1 < queue.count { index += 1; load(); return }
        if repeatMode == .all, !queue.isEmpty { index = 0; load(); return }
        if autoplay {
            Task {
                await extendWithRadio()
                if index + 1 < queue.count { index += 1; load() } else { pause() }
            }
            return
        }
        pause()
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
        save(); prefetch(); updateRemoteModes()
    }

    /// Autoplay / stations: append similar songs (plugin `radio`, else the artist's popular songs).
    private func extendWithRadio(seed: Track? = nil) async {
        guard let m = plugins.metadata, let t = seed ?? current ?? queue.last else { return }
        var more: [Track] = []
        if m.has("radio") { more = (try? await m.call("radio", [try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))])) ?? [] }
        else if let a = t.artistID, m.has("artist") { more = ((try? await m.call("artist", [a]) as ArtistPage)?.tracks) ?? [] }
        let have = Set(queue.map(\.id))
        let fresh = more.filter { !have.contains($0.id) }.prefix(15)
        guard !fresh.isEmpty else { return }
        queue += fresh; original += fresh; save(); warm()
    }

    // MARK: Resolving audio

    private var sources: [JSPlugin] {
        ([plugins.audio] + plugins.plugins.filter { $0.abilities.contains("audio") && $0.id != plugins.audio?.id }).compactMap { $0 }
    }

    /// Offline-first: downloaded file → locally cached file → audio plugins (local yt-dlp, the server, direct).
    private func resolve(_ t: Track, skipping skip: Set<String> = []) async throws -> Resolved {
        if let f = Downloads.shared.file(for: t.id) { return Resolved(url: f, key: nil, source: "Downloaded") }
        if skip.isEmpty, let r = ready[t.id], !r.url.isFileURL || FileManager.default.fileExists(atPath: r.url.path) { return r }
        if skip.isEmpty, let task = resolving[t.id] { return try await task.value }
        let srcs = sources.filter { !skip.contains($0.id) }
        let task = Task { () throws -> Resolved in
            guard !srcs.isEmpty else { throw NSError(domain: "audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio plugin"]) }
            var errs: [String] = []
            let arg = try JSONSerialization.jsonObject(with: JSONEncoder().encode(t))
            for src in srcs {
                // Already cached on this device under the matched YouTube id? Then no network at all.
                if src.has("matched"), let vid: String = try? await src.call("matched", [arg]), let f = AudioCache.file("yt-" + vid) {
                    return Resolved(url: f, key: "yt-" + vid, source: "Cached")
                }
                do {
                    let s: StreamResult = try await src.call("stream", [arg])
                    guard let u = URL(string: s.url) else { continue }
                    let note = errs.isEmpty && src.id == srcs.first?.id ? nil : "via \(src.name)"
                    if let k = s.key, let f = AudioCache.file(k) { return Resolved(url: f, note: note, key: k, source: "Cached") }
                    if u.isFileURL { return Resolved(url: u, note: note, key: s.key, source: "yt-dlp") }
                    if let h = s.headers {
                        let f = try await ChunkedDownload.file(u, headers: h, key: s.key ?? "\(src.id)-\(t.id)")
                        return Resolved(url: f, note: note, key: s.key, source: "YouTube")
                    }
                    let server = Cloud.shared.base.map { u.absoluteString.hasPrefix($0.absoluteString) } ?? false
                    return Resolved(url: u, note: note, key: s.key, source: server ? "Server" : src.name)
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

    /// A local file for `t` (for Downloads): resolves and fetches streamed audio into the cache.
    func localFile(for t: Track) async throws -> URL {
        let r = try await resolve(t)
        if r.url.isFileURL { return r.url }
        let f = try await AudioCache.store(r.key ?? "t-\(t.id)", from: r.url)
        ready[t.id] = Resolved(url: f, key: r.key, source: "Cached")
        return f
    }

    private func load(crossfadeFrom old: AVPlayer? = nil) {
        guard let t = current else { return }
        finishSession(completed: false)
        generation += 1
        let gen = generation, start = old == nil ? resumeAt : nil
        resumeAt = nil
        error = nil; progress = start ?? 0; loading = true; source = nil
        if old != nil {
            // The old song keeps playing on its own player; the next one starts silent on a fresh player.
            attach(makePlayer()); av.volume = 0
        } else {
            endFade()
            av.pause(); av.replaceCurrentItem(with: nil)
        }
        nowPlaying(); save()
        Task { try? await Task.sleep(for: .seconds(1)); if gen == generation { warm() } }
        Task {
            var skip = Set<String>()
            while gen == generation {
                do {
                    let r = try await resolve(t, skipping: skip)
                    guard gen == generation else { return }
                    let item = AVPlayerItem(url: r.url)
                    av.replaceCurrentItem(with: item)
                    if let start, start > 1 { await av.seek(to: .init(seconds: start, preferredTimescale: 600)) }
                    av.play()
                    for _ in 0..<200 where item.status == .unknown { try await Task.sleep(for: .milliseconds(100)) }
                    guard gen == generation else { return }
                    guard item.status == .readyToPlay else {
                        // Broken file/stream: drop it and try the remaining sources.
                        if r.url.isFileURL, r.source != "Downloaded" { try? FileManager.default.removeItem(at: r.url) }
                        ready[t.id] = nil
                        if let first = sources.first(where: { !skip.contains($0.id) }) { skip.insert(first.id) } else { throw item.error ?? URLError(.cannotDecodeContentData) }
                        continue
                    }
                    if let old { runFade(from: old) }
                    loading = false; playing = true; error = r.note; source = r.source; failures = 0
                    session = Session(track: t, source: r.source, context: context)
                    nowPlaying(); remember(t); prefetch(); publish(force: true)
                    // Streaming from the server: keep a local copy so replays and offline listening are instant.
                    if !r.url.isFileURL, let k = r.key { let u = r.url; Task.detached { _ = try? await AudioCache.store(k, from: u) } }
                    return
                } catch {
                    guard gen == generation else { return }
                    endFade()
                    self.error = Net.shared.online ? error.localizedDescription : "You're offline and this song isn't downloaded"
                    loading = false; playing = false; failures += 1
                    nowPlaying()
                    // Like Apple Music: skip songs that can't be played (but don't spin through a whole queue).
                    if failures < 4, index + 1 < queue.count {
                        Task { try? await Task.sleep(for: .seconds(1.5)); if gen == generation { index += 1; load() } }
                    }
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
        if Net.shared.expensive && !UserDefaults.standard.bool(forKey: "prefetchCellular") { return }
        var around = [index + 1, index + 2, index - 1].filter { queue.indices.contains($0) && $0 != index }
        if repeatMode == .all, index == queue.count - 1, !queue.isEmpty { around.append(0) }
        for i in around {
            let t = queue[i]
            Task { if let r = try? await resolve(t), !r.url.isFileURL, let k = r.key { _ = try? await AudioCache.store(k, from: r.url) } }
        }
    }

    /// Change the YouTube upload used for a track ("Wrong song" / "Choose Version") and replay if it's playing.
    func reloadAudio(for t: Track) {
        ready[t.id] = nil
        if current?.id == t.id { resumeAt = nil; load() }
    }

    // MARK: Listening history + events

    private func finishSession(completed: Bool) {
        guard let s = session else { return }
        session = nil
        guard s.listened >= 3 else { return }
        let d = s.track.duration ?? duration ?? 0
        Cloud.shared.log(PlayEvent(track: s.track, startedAt: Int64(s.started.timeIntervalSince1970 * 1000), endedAt: nowMs(),
                                   listened: s.listened, duration: d, completed: completed,
                                   skipped: !completed && s.listened < min(30, max(d * 0.5, 10)), source: s.source,
                                   contextId: s.context?.id ?? "", contextTitle: s.context?.title ?? "", contextArt: s.context?.art ?? "",
                                   shuffle: shuffle, repeat: repeatMode.rawValue, autoplay: autoplay))
    }
    /// Call when the app is about to quit / go to background so the current listen is recorded.
    func flush() { finishSession(completed: false); if playing, let t = current { session = Session(track: t, source: source ?? "", context: context) }; save() }

    private func remember(_ t: Track) {
        history.removeAll { $0.id == t.id }
        history.insert(t, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        Store.save(history, "history")
    }
    func clearHistory() { history = []; Store.save(history, "history") }

    // MARK: Handoff

    private func publish(force: Bool = false) {
        guard current != nil else { return }
        let lo = max(0, index - 30), hi = min(queue.count, index + 120)
        Cloud.shared.publish(RemoteState(queue: Array(queue[lo..<hi]), index: index - lo, position: progress, playing: playing, context: context,
                                         at: force ? nowMs() : nowMs() / 15000 * 15000))
    }
    /// Continue what another device is playing, and pause it there.
    func takeOver(_ d: Device) {
        guard let s = d.state, s.current != nil else { return }
        original = s.queue; queue = s.queue; index = s.index; context = s.context
        if shuffle { shuffle = false }
        resumeAt = s.position + (s.playing ? Double(nowMs() - s.at) / 1000 : 0)
        load()
        Cloud.shared.command(d.id, "pause")
    }

    // MARK: Persistence

    private struct State: Codable {
        var queue: [Track]; var original: [Track]; var index: Int; var progress: Double
        var shuffle: Bool; var repeatMode: RepeatMode; var autoplay: Bool; var volume: Float; var context: PlayContext?
    }
    private func save() {
        Store.save(State(queue: queue, original: original, index: index, progress: progress, shuffle: shuffle,
                         repeatMode: repeatMode, autoplay: autoplay, volume: volume, context: context), "player")
    }
    private func restore() {
        guard let s = Store.load(State.self, "player") else { return }
        queue = s.queue; original = s.original; index = s.index; shuffle = s.shuffle
        repeatMode = s.repeatMode; autoplay = s.autoplay; volume = s.volume; context = s.context
        progress = s.progress; resumeAt = s.progress > 1 ? s.progress : nil
    }

    // MARK: System integration (Now Playing, lock screen, CarPlay, AirPods, media keys)

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        rc.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        rc.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.prev() }; return .success }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            MainActor.assumeIsolated { if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) } }; return .success
        }
        rc.likeCommand.localizedTitle = "Love"
        rc.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if let t = self?.current { Library.shared.toggleLike(t); self?.nowPlaying() } }; return .success
        }
        rc.changeShuffleModeCommand.addTarget { [weak self] e in
            MainActor.assumeIsolated { if let e = e as? MPChangeShuffleModeCommandEvent { self?.shuffle = e.shuffleType != .off } }; return .success
        }
        rc.changeRepeatModeCommand.addTarget { [weak self] e in
            MainActor.assumeIsolated {
                if let e = e as? MPChangeRepeatModeCommandEvent { self?.repeatMode = e.repeatType == .one ? .one : e.repeatType == .all ? .all : .off }
            }; return .success
        }
    }
    private func updateRemoteModes() {
        let rc = MPRemoteCommandCenter.shared()
        rc.changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        rc.changeRepeatModeCommand.currentRepeatType = repeatMode == .one ? .one : repeatMode == .all ? .all : .off
    }

    #if os(iOS)
    private func setupAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? s.setActive(true)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began { self.playing = false; self.nowPlaying() }
                else if let o = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt, AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) {
                    try? AVAudioSession.sharedInstance().setActive(true); self.resume()
                }
            }
        }
        // Headphones unplugged / AirPods removed → pause, like every music app.
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self?.pause()
            }
        }
    }
    #endif

    private var artworkFor: String?
    func nowPlaying() {
        #if os(iOS)
        NowPlayingSurface.shared.update(track: current, playing: playing || loading, position: progress, duration: duration ?? current?.duration ?? 0,
                                        liked: current.map(Library.shared.isLiked) ?? false)
        #endif
        guard let t = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration ?? 0, MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index, MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count]
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        if let c = context { info[MPNowPlayingInfoCollectionIdentifier] = c.title }
        MPRemoteCommandCenter.shared().likeCommand.isActive = Library.shared.isLiked(t)
        if let old = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork], artworkFor == t.id { info[MPMediaItemPropertyArtwork] = old }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
        #endif
        guard artworkFor != t.id, let s = t.art else { return }
        artworkFor = t.id
        Task {
            guard let img = await ImageStore.shared.image(s), current?.id == t.id else { return }
            var i = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            i[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = i
        }
    }
}

/// `stream()` may return a URL string or `{ url, headers?, key? }` (`key` = cache key, e.g. "yt-<videoId>").
struct StreamResult: Decodable {
    var url: String; var headers: [String: String]?; var key: String?
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer().decode(String.self) { url = s; return }
        let c = try d.container(keyedBy: K.self)
        url = try c.decode(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        key = try c.decodeIfPresent(String.self, forKey: .key)
    }
    enum K: CodingKey { case url, headers, key }
}
