import Foundation
import SwiftUI
import Observation
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image { init(platformImage i: NSImage) { self.init(nsImage: i) } }
#else
import UIKit
typealias PlatformImage = UIImage
extension Image { init(platformImage i: UIImage) { self.init(uiImage: i) } }
#endif

// MARK: - Audio cache (streamed + prefetched songs, LRU)

enum AudioCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "audio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()
    static var limitMB: Int {
        get { UserDefaults.standard.object(forKey: "cache.limitMB") as? Int ?? 2048 }
        set { UserDefaults.standard.set(newValue, forKey: "cache.limitMB"); trim() }
    }
    static func path(_ key: String) -> URL { dir.appending(path: key.replacingOccurrences(of: "/", with: "_") + ".m4a") }

    /// Cached file for `key`, marked as recently used.
    static func file(_ key: String) -> URL? {
        let p = path(key)
        guard FileManager.default.fileExists(atPath: p.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: p.path)
        return p
    }

    private static var inflight: [String: Task<URL, Error>] = [:]
    private static let lock = NSLock()

    /// Downloads `url` into the cache under `key` (de-duplicated).
    @discardableResult static func store(_ key: String, from url: URL) async throws -> URL {
        if let f = file(key) { return f }
        lock.lock()
        let task: Task<URL, Error>
        if let t = inflight[key] { task = t } else {
            task = Task.detached {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
                    throw NSError(domain: "audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"])
                }
                let dst = path(key)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.moveItem(at: tmp, to: dst)
                trim()
                return dst
            }
            inflight[key] = task
        }
        lock.unlock()
        defer { lock.lock(); inflight[key] = nil; lock.unlock() }
        return try await task.value
    }

    static var size: Int64 { files.reduce(0) { $0 + $1.size } }
    private static var files: [(url: URL, size: Int64, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []).compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast)
        }
    }
    /// Drops least recently played files beyond the size limit.
    static func trim() {
        var total = size
        let limit = Int64(limitMB) * 1_000_000
        guard total > limit else { return }
        for f in files.sorted(by: { $0.date < $1.date }) where total > limit {
            try? FileManager.default.removeItem(at: f.url); total -= f.size
        }
    }
    static func clear() { files.forEach { try? FileManager.default.removeItem(at: $0.url) } }
}

/// Downloads `url` with bounded Range requests (1 MiB, 4 in parallel) — for direct YouTube streams that need headers.
enum ChunkedDownload {
    static func file(_ url: URL, headers: [String: String], key: String) async throws -> URL {
        if let f = AudioCache.file(key) { return f }
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
        let dst = AudioCache.path(key)
        try data.write(to: dst, options: .atomic)
        AudioCache.trim()
        return dst
    }
}

// MARK: - Downloads (kept for offline listening, never evicted)

@MainActor @Observable final class Downloads {
    static let shared = Downloads()
    struct Item: Codable, Hashable { var track: Track; var file: String; var bytes: Int64; var at: Date }
    enum State: Equatable { case none, queued, downloading, done, failed(String) }

    private(set) var items: [String: Item] = Store.load([String: Item].self, "downloads") ?? [:]
    private(set) var queued: [Track] = []
    private(set) var active: Set<String> = []
    private(set) var failed: [String: String] = [:]
    /// Only download on Wi-Fi (iOS).
    var wifiOnly = UserDefaults.standard.object(forKey: "dl.wifiOnly") as? Bool ?? true { didSet { UserDefaults.standard.set(wifiOnly, forKey: "dl.wifiOnly") } }

    let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SpotubeLite/Downloads")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()

    var tracks: [Track] { items.values.sorted { $0.at > $1.at }.map(\.track) }
    var totalBytes: Int64 { items.values.reduce(0) { $0 + $1.bytes } }

    func file(for id: String) -> URL? {
        guard let i = items[id] else { return nil }
        let u = dir.appending(path: i.file)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    func state(_ t: Track) -> State {
        if items[t.id] != nil { return .done }
        if active.contains(t.id) { return .downloading }
        if queued.contains(where: { $0.id == t.id }) { return .queued }
        if let e = failed[t.id] { return .failed(e) }
        return .none
    }
    func isDownloaded(_ tracks: [Track]) -> Bool { !tracks.isEmpty && tracks.allSatisfy { items[$0.id] != nil } }

    func download(_ tracks: [Track]) {
        for t in tracks where items[t.id] == nil && !active.contains(t.id) && !queued.contains(where: { $0.id == t.id }) {
            failed[t.id] = nil; queued.append(t)
        }
        pump()
    }
    func cancelAll() { queued = [] }

    private func pump() {
        while active.count < 2, !queued.isEmpty {
            let t = queued.removeFirst()
            active.insert(t.id)
            Task {
                do {
                    let src = try await Player.shared.localFile(for: t)
                    let name = t.id.replacingOccurrences(of: "/", with: "_") + ".m4a"
                    let dst = dir.appending(path: name)
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: src, to: dst)
                    let size = (try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
                    items[t.id] = Item(track: t, file: name, bytes: size, at: .now)
                    Store.save(items, "downloads")
                } catch { failed[t.id] = error.localizedDescription }
                active.remove(t.id)
                pump()
            }
        }
    }

    func remove(_ ids: [String]) {
        for id in ids { if let i = items[id] { try? FileManager.default.removeItem(at: dir.appending(path: i.file)) }; items[id] = nil }
        Store.save(items, "downloads")
    }
    func removeAll() { remove(Array(items.keys)) }
}

// MARK: - Lyrics (LRCLIB, synced when available)

struct LyricLine: Identifiable, Hashable { var id: Int; var time: Double?; var text: String }

@MainActor @Observable final class Lyrics {
    static let shared = Lyrics()
    private(set) var trackID: String?
    private(set) var lines: [LyricLine] = []
    private(set) var synced = false
    private(set) var loading = false
    private(set) var missing = false

    private struct LRC: Codable { var syncedLyrics: String?; var plainLyrics: String?; var instrumental: Bool? }

    func load(_ t: Track?) async {
        guard let t, t.id != trackID else { return }
        trackID = t.id; lines = []; synced = false; missing = false; loading = true
        defer { if trackID == t.id { loading = false } }
        let cached = DiskCache.load(LRC.self, "lrc-" + t.id)
        var r = cached
        if r == nil { r = await fetch(t) }
        guard trackID == t.id else { return }
        if let r, cached == nil { DiskCache.save(r, "lrc-" + t.id) }
        if let s = r?.syncedLyrics, !s.isEmpty { lines = Self.parse(s); synced = true }
        else if let p = r?.plainLyrics, !p.isEmpty { lines = p.components(separatedBy: "\n").enumerated().map { LyricLine(id: $0, time: nil, text: $1) } }
        else if r?.instrumental == true { lines = [LyricLine(id: 0, time: nil, text: "♪ Instrumental ♪")] }
        missing = lines.isEmpty
    }

    private func fetch(_ t: Track) async -> LRC? {
        func get<T: Decodable>(_ path: String, _ q: [String: String]) async -> T? {
            var c = URLComponents(string: "https://lrclib.net/api/" + path)!
            c.queryItems = q.map { URLQueryItem(name: $0, value: $1) }
            var r = URLRequest(url: c.url!, timeoutInterval: 12)
            r.setValue("SpotubeLite/2.0 (https://github.com/Qerope/Spotube-SwiftUI)", forHTTPHeaderField: "User-Agent")
            guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(T.self, from: d)
        }
        var q = ["track_name": t.title, "artist_name": t.primaryArtist]
        if let a = t.album { q["album_name"] = a }
        if let d = t.duration, d > 0 { q["duration"] = String(Int(d.rounded())) }
        if let r: LRC = await get("get", q), r.syncedLyrics != nil || r.plainLyrics != nil { return r }
        let clean = t.title.replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
        let list: [LRC] = await get("search", ["track_name": clean, "artist_name": t.primaryArtist]) ?? []
        return list.first { $0.syncedLyrics != nil } ?? list.first
    }

    static func parse(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for line in s.components(separatedBy: "\n") {
            let ns = line as NSString
            let ms = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let t = Double(ns.substring(with: m.range(at: 1)))! * 60 + Double(ns.substring(with: m.range(at: 2)))!
                out.append(LyricLine(id: 0, time: t, text: text))
            }
        }
        return out.sorted { ($0.time ?? 0) < ($1.time ?? 0) }.enumerated().map { LyricLine(id: $0, time: $1.time, text: $1.text) }
    }
}

// MARK: - Images (memory + disk cache, average colour)

@MainActor final class ImageStore {
    static let shared = ImageStore()
    private let memory = NSCache<NSString, PlatformImage>()
    private var colors: [String: Color] = [:]
    private var tasks: [String: Task<PlatformImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20,
                              directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "images"))
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    init() { memory.countLimit = 400 }

    func cached(_ url: String) -> PlatformImage? { memory.object(forKey: url as NSString) }

    func image(_ url: String) async -> PlatformImage? {
        if let i = cached(url) { return i }
        if let t = tasks[url] { return await t.value }
        let t = Task<PlatformImage?, Never> {
            guard let u = URL(string: url), let (d, _) = try? await session.data(from: u) else { return nil }
            return PlatformImage(data: d)
        }
        tasks[url] = t
        let i = await t.value
        tasks[url] = nil
        if let i { memory.setObject(i, forKey: url as NSString) }
        return i
    }

    /// Average colour of the artwork (for player and header backgrounds).
    func color(_ url: String) async -> Color? {
        if let c = colors[url] { return c }
        guard let img = await image(url) else { return nil }
        #if os(macOS)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #else
        guard let cg = img.cgImage else { return nil }
        #endif
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        colors[url] = c
        return c
    }
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
