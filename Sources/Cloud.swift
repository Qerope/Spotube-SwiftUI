import Foundation
import Network
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Untyped JSON for sync payloads.
enum JSON: Codable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    init<T: Encodable>(_ v: T) throws { self = try JSONDecoder.sync.decode(JSON.self, from: JSONEncoder.sync.encode(v)) }
    func decode<T: Decodable>(_ t: T.Type) throws -> T { try JSONDecoder.sync.decode(T.self, from: JSONEncoder.sync.encode(self)) }
    var string: String? { if case .string(let s) = self { return s }; return nil }
}

extension JSONEncoder { static let sync: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }() }
extension JSONDecoder { static let sync: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }() }

struct Change: Codable { var kind: String; var key: String; var value: JSON?; var updatedAt: Int64; var deleted: Bool }

/// One listen, sent to the server for history and stats.
struct PlayEvent: Codable {
    var type = "play"; var uid = UUID().uuidString; var device = ""
    var track: Track?; var startedAt: Int64 = 0; var endedAt: Int64 = 0; var listened: Double = 0; var duration: Double = 0
    var completed = false; var skipped = false; var source = ""
    var contextId = ""; var contextTitle = ""; var contextArt = ""
    var shuffle = false; var `repeat` = ""; var autoplay = false
    var tzOffset = TimeZone.current.secondsFromGMT(); var q = ""
}

/// What a device is playing; other devices show it as "Continue from …".
struct RemoteState: Codable, Hashable {
    var queue: [Track]; var index: Int; var position: Double; var playing: Bool; var context: PlayContext?; var at: Int64
    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
}

struct Device: Codable, Identifiable, Hashable {
    var id: String; var name: String?; var platform: String?; var lastSeen: Int64?; var state: RemoteState?
    enum CodingKeys: String, CodingKey { case id, name, platform, lastSeen = "last_seen", state }
    var icon: String { platform == "iOS" ? "iphone" : platform == "macOS" ? "laptopcomputer" : "desktopcomputer" }
}

struct CacheInfo: Codable, Hashable { var files: Int; var bytes: Int64; var limit: Int64; var diskFree: Int64 }

struct Stats: Codable {
    struct TopTrack: Codable, Hashable { var track: Track; var plays: Int; var minutes: Double }
    struct TopArtist: Codable, Hashable { var name: String; var id: String?; var plays: Int; var minutes: Double }
    struct TopAlbum: Codable, Hashable { var title: String; var artist: String; var plays: Int; var minutes: Double; var art: String? }
    struct Day: Codable, Hashable { var day: String; var minutes: Double }
    struct DeviceMinutes: Codable, Hashable { var device: String; var minutes: Double }
    var days: Int; var minutes: Double; var plays: Int; var uniqueTracks: Int; var uniqueArtists: Int; var skipRate: Double
    var topTracks: [TopTrack]; var topArtists: [TopArtist]; var topAlbums: [TopAlbum]
    var byHour: [Double]; var byWeekday: [Double]; var byDay: [Day]; var byDevice: [DeviceMinutes]
}

struct HistoryEntry: Codable, Hashable { var track: Track; var at: Int64; var device: String?; var context: PlayContext? }

/// Client for the Spotube server: sync, events, handoff, server streaming and the Mac "helper" role.
@MainActor @Observable final class Cloud {
    static let shared = Cloud()
    enum Status: Equatable { case off, connecting, online, offline(String) }
    struct Config: Codable { var url: String; var token: String }

    var url: String { didSet { UserDefaults.standard.set(url, forKey: "cloud.url"); reconnect() } }
    var token: String { didSet { UserDefaults.standard.set(token, forKey: "cloud.token"); reconnect() } }
    var status: Status = .off
    var devices: [Device] = []
    var cacheInfo: CacheInfo?
    var lastSync: Date?
    var pending: Int { outbox.count + events.count }
    /// Mac only: fetch songs for other devices when YouTube blocks the server.
    var helper = UserDefaults.standard.object(forKey: "cloud.helper") as? Bool ?? true { didSet { UserDefaults.standard.set(helper, forKey: "cloud.helper") } }

    let deviceID: String
    let deviceName: String
    #if os(macOS)
    let platform = "macOS"
    #else
    let platform = "iOS"
    #endif

    @ObservationIgnored var handlers: [String: (Change) -> Void] = [:]
    @ObservationIgnored var onCommand: ((String, [String: String]) -> Void)?
    private var outbox: [Change] = Store.load([Change].self, "outbox") ?? []
    private var events: [PlayEvent] = Store.load([PlayEvent].self, "events") ?? []
    @ObservationIgnored private var since = UserDefaults.standard.integer(forKey: "cloud.since")
    @ObservationIgnored private var streamKey = UserDefaults.standard.string(forKey: "cloud.streamKey")
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncQueued = false
    @ObservationIgnored private var statePublished: Int64 = 0

    var enabled: Bool { base != nil && !token.isEmpty }
    var base: URL? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s.hasPrefix("http") ? URL(string: s) : nil
    }
    var otherDevices: [Device] { devices.filter { $0.id != deviceID } }

    private init() {
        let bundled = Bundle.main.url(forResource: "server", withExtension: "json")
            .flatMap { try? JSONDecoder().decode(Config.self, from: Data(contentsOf: $0)) }
        url = UserDefaults.standard.string(forKey: "cloud.url") ?? bundled?.url ?? ""
        token = UserDefaults.standard.string(forKey: "cloud.token") ?? bundled?.token ?? ""
        if let id = UserDefaults.standard.string(forKey: "cloud.device") { deviceID = id }
        else { deviceID = UUID().uuidString; UserDefaults.standard.set(deviceID, forKey: "cloud.device") }
        #if os(macOS)
        deviceName = Host.current().localizedName ?? "Mac"
        #else
        deviceName = UIDevice.current.name
        #endif
    }

    func start() {
        guard loops.isEmpty, enabled else { if !enabled { status = .off }; return }
        status = .connecting
        loops = [Task { await mainLoop() }, Task { await commandLoop() }]
    }
    func reconnect() {
        loops.forEach { $0.cancel() }; loops = []
        UserDefaults.standard.removeObject(forKey: "cloud.streamKey"); streamKey = nil
        start()
    }

    private func mainLoop() async {
        while !Task.isCancelled {
            await hello()
            await syncNow()
            try? await Task.sleep(for: .seconds(status == .online ? 30 : 15))
        }
    }

    /// Long-poll for commands (pause when another device takes over, fetch requests for the Mac helper).
    private func commandLoop() async {
        while !Task.isCancelled {
            do {
                #if os(macOS)
                let h = helper && YtDlp.bin != nil
                #else
                let h = false
                #endif
                let cmds: [RemoteCommand] = try await send("GET", "/v1/commands/wait?device=\(deviceID)&helper=\(h)&timeout=25", Optional<Int>.none, timeout: 40)
                cmds.forEach(handle)
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private struct RemoteCommand: Codable { var cmd: String; var args: [String: String]? }
    private func handle(_ c: RemoteCommand) { onCommand?(c.cmd, c.args ?? [:]) }

    func hello() async {
        struct Hello: Codable { var id, name, platform, appVersion: String }
        struct Resp: Codable { var streamKey: String; var devices: [Device]; var cache: CacheInfo; var commands: [RemoteCommand] }
        do {
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            let r: Resp = try await send("POST", "/v1/hello", Hello(id: deviceID, name: deviceName, platform: platform, appVersion: v))
            streamKey = r.streamKey; UserDefaults.standard.set(r.streamKey, forKey: "cloud.streamKey")
            devices = r.devices; cacheInfo = r.cache; status = .online
            r.commands.forEach(handle)
        } catch { status = .offline(error.localizedDescription) }
    }

    // MARK: Sync

    func record(_ kind: String, _ key: String, _ value: JSON?, at: Int64 = nowMs()) {
        outbox.removeAll { $0.kind == kind && $0.key == key }
        outbox.append(Change(kind: kind, key: key, value: value, updatedAt: at, deleted: value == nil))
        Store.save(outbox, "outbox")
        scheduleSync()
    }

    func log(_ e: PlayEvent) {
        var e = e; e.device = deviceID
        events.append(e); Store.save(events, "events")
        scheduleSync()
    }

    func scheduleSync() {
        guard enabled, !syncQueued else { return }
        syncQueued = true
        Task { try? await Task.sleep(for: .seconds(1.5)); syncQueued = false; await syncNow() }
    }

    func syncNow() async {
        guard enabled, !syncing else { return }
        syncing = true; defer { syncing = false }
        struct SyncIn: Codable { var device: String; var since: Int; var changes: [Change] }
        struct SyncOut: Codable { var seq: Int; var changes: [Change] }
        struct OK: Codable {}
        do {
            let evs = Array(events.prefix(500))
            if !evs.isEmpty {
                let _: OK = try await send("POST", "/v1/events", evs)
                let sent = Set(evs.map(\.uid)); events.removeAll { sent.contains($0.uid) }; Store.save(events, "events")
            }
            let sending = outbox
            let r: SyncOut = try await send("POST", "/v1/sync", SyncIn(device: deviceID, since: since, changes: sending))
            outbox.removeAll { c in sending.contains { $0.kind == c.kind && $0.key == c.key && $0.updatedAt == c.updatedAt } }
            Store.save(outbox, "outbox")
            for ch in r.changes where !outbox.contains(where: { $0.kind == ch.kind && $0.key == ch.key && $0.updatedAt > ch.updatedAt }) {
                handlers[ch.kind]?(ch)
            }
            since = r.seq; UserDefaults.standard.set(since, forKey: "cloud.since")
            lastSync = .now; status = .online
        } catch { status = .offline(error.localizedDescription) }
    }

    /// Forget the sync position and pull everything again (Settings → Resync).
    func resync() async { since = 0; UserDefaults.standard.set(0, forKey: "cloud.since"); await syncNow() }

    // MARK: Handoff

    func publish(_ s: RemoteState) {
        guard enabled, s.at > statePublished else { return }
        statePublished = s.at
        struct In: Codable { var device: String; var state: RemoteState }
        struct OK: Codable {}
        Task { let _: OK? = try? await send("PUT", "/v1/state", In(device: deviceID, state: s)) }
    }
    func command(_ target: String, _ cmd: String, _ args: [String: String] = [:]) {
        struct In: Codable { var target, cmd, sender: String; var args: [String: String] }
        struct OK: Codable {}
        Task { let _: OK? = try? await send("POST", "/v1/command", In(target: target, cmd: cmd, sender: deviceID, args: args)) }
    }

    // MARK: Reads

    func stats(days: Int) async throws -> Stats { try await send("GET", "/v1/stats?days=\(days)", Optional<Int>.none, timeout: 30) }
    func trackPlays() async throws -> [TrackPlays] { try await send("GET", "/v1/plays/tracks", Optional<Int>.none, timeout: 30) }
    func history(limit: Int = 200) async throws -> [HistoryEntry] { try await send("GET", "/v1/history?limit=\(limit)", Optional<Int>.none) }
    func recentSearches() async throws -> [String] { try await send("GET", "/v1/searches?limit=15", Optional<Int>.none) }
    func refreshDevices() async { if let d: [Device] = try? await send("GET", "/v1/devices", Optional<Int>.none) { devices = d } }

    // MARK: Audio

    /// Asks the server to have `videoId` cached (downloading it or asking a Mac helper), then returns a streamable URL.
    func prepareAudio(_ videoId: String) async throws -> URL {
        guard let base else { throw err("Server not configured") }
        struct Ready: Codable { var ready: Bool }
        let _: Ready = try await send("POST", "/v1/audio/\(videoId)/prefetch?wait=1&d=\(deviceID)", Optional<Int>.none, timeout: 170)
        if streamKey == nil { await hello() }
        guard let key = streamKey else { throw err("Server unreachable") }
        return base.appending(path: "v1/audio/\(videoId)").appending(queryItems: [.init(name: "k", value: key), .init(name: "d", value: deviceID)])
    }

    /// Mac: share a song fetched locally with the server cache so other devices get it instantly.
    func share(videoId: String, file: URL) async {
        guard enabled else { return }
        struct Exists: Codable { var exists: Bool }
        guard let e: Exists = try? await send("GET", "/v1/audio/\(videoId)/exists", Optional<Int>.none), !e.exists,
              var r = request("PUT", "/v1/audio/\(videoId)", timeout: 120) else { return }
        r.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        _ = try? await URLSession.shared.upload(for: r, fromFile: file)
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, timeout: TimeInterval) -> URLRequest? {
        guard let base, let u = URL(string: base.absoluteString + path) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, _ body: B?, timeout: TimeInterval = 20) async throws -> T {
        guard var r = request(method, path, timeout: timeout) else { throw err("Server not configured") }
        if let body { r.httpBody = try JSONEncoder.sync.encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw err((try? JSONDecoder().decode(ServerError.self, from: d).detail) ?? "Server HTTP \(code)")
        }
        return try JSONDecoder.sync.decode(T.self, from: d)
    }
    private func err(_ s: String) -> NSError { NSError(domain: "server", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}

/// Network reachability (offline mode, cellular rules).
@MainActor @Observable final class Net {
    static let shared = Net()
    var online = true
    var expensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { p in
            Task { @MainActor in Net.shared.online = p.status == .satisfied; Net.shared.expensive = p.isExpensive }
        }
        monitor.start(queue: .global(qos: .utility))
    }
}

private struct ServerError: Codable { var detail: String }
