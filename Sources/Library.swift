import Foundation
import Observation

struct Playlist: Codable, Identifiable, Hashable {
    struct Item: Codable, Hashable { var track: Track; var added: Date }
    var id: String; var name: String; var notes: String?; var items: [Item]; var created: Date; var updated: Date
    /// Set for smart playlists: songs are picked live by these rules instead of `items`.
    var smart: SmartRules?
    var tracks: [Track] { items.map(\.track) }
}

/// Your library: favourite songs, your own playlists, saved albums/artists/playlists, plus a cache of the
/// Spotify library. Everything except the Spotify cache syncs through the server (last writer wins).
@MainActor @Observable final class Library {
    static let shared = Library()
    struct Liked: Codable, Hashable { var track: Track; var at: Date }
    struct Saved: Codable, Hashable { var item: Collection; var at: Date }
    private struct Local: Codable {
        var likes: [String: Liked] = [:]; var playlists: [String: Playlist] = [:]; var saved: [String: Saved] = [:]; var stamps: [String: Int64] = [:]
    }
    private struct SpotifyCache: Codable { var playlists: [Collection] = []; var albums: [Collection] = []; var artists: [Collection] = [] }

    private(set) var likes: [String: Liked]
    private(set) var playlists: [String: Playlist]
    private(set) var saved: [String: Saved]
    private(set) var spotifyPlaylists: [Collection]
    private(set) var spotifyAlbums: [Collection]
    private(set) var spotifyArtists: [Collection]
    var refreshing = false
    var spotifyError: String?
    @ObservationIgnored private var stamps: [String: Int64]

    private init() {
        let l = Store.load(Local.self, "library") ?? Local()
        likes = l.likes; playlists = l.playlists; saved = l.saved; stamps = l.stamps
        let s = Store.load(SpotifyCache.self, "spotify-library") ?? SpotifyCache()
        spotifyPlaylists = s.playlists; spotifyAlbums = s.albums; spotifyArtists = s.artists
        for kind in ["like", "playlist", "saved"] { Cloud.shared.handlers[kind] = { [weak self] in self?.apply($0) } }
    }

    private func persist() { Store.save(Local(likes: likes, playlists: playlists, saved: saved, stamps: stamps), "library") }

    private func push<T: Encodable>(_ kind: String, _ key: String, _ v: T?) {
        let ts = max(nowMs(), (stamps["\(kind)/\(key)"] ?? 0) + 1)
        stamps["\(kind)/\(key)"] = ts
        persist()
        Cloud.shared.record(kind, key, v.flatMap { try? JSON($0) }, at: ts)
    }

    private func apply(_ ch: Change) {
        let k = "\(ch.kind)/\(ch.key)"
        guard ch.updatedAt > (stamps[k] ?? 0) else { return }
        stamps[k] = ch.updatedAt
        switch ch.kind {
        case "like": likes[ch.key] = ch.deleted ? nil : try? ch.value?.decode(Liked.self)
        case "playlist": playlists[ch.key] = ch.deleted ? nil : try? ch.value?.decode(Playlist.self)
        case "saved": saved[ch.key] = ch.deleted ? nil : try? ch.value?.decode(Saved.self)
        default: break
        }
        persist()
    }

    // MARK: Favourites

    func isLiked(_ t: Track) -> Bool { likes[t.id] != nil }
    func toggleLike(_ t: Track) { setLiked(t, !isLiked(t)) }
    func setLiked(_ t: Track, _ on: Bool) {
        guard on != isLiked(t) else { return }
        likes[t.id] = on ? Liked(track: t, at: .now) : nil
        push("like", t.id, likes[t.id])
    }
    var favorites: [Track] { likes.values.sorted { $0.at > $1.at }.map(\.track) }
    func likedAt(_ t: Track) -> Date? { likes[t.id]?.at }

    // MARK: Your playlists

    var localPlaylists: [Playlist] { playlists.values.sorted { $0.updated > $1.updated } }
    /// Playlists you can add songs to (not smart ones).
    var editablePlaylists: [Playlist] { localPlaylists.filter { !$0.isSmart } }
    /// Songs of a playlist: its items, or the live result of its rules.
    func tracks(_ p: Playlist) -> [Track] { p.smart.map { SmartEngine.tracks($0) } ?? p.tracks }
    func tracks(ofPlaylist id: String) -> [Track] { playlists[id].map(tracks) ?? [] }
    func collection(_ p: Playlist) -> Collection {
        let t = tracks(p)
        return Collection(id: p.id, title: p.name, subtitle: "\(p.isSmart ? "Smart Playlist" : "Playlist") · \(t.count) song\(t.count == 1 ? "" : "s")",
                          art: t.mosaic.first, kind: "local", mosaic: t.mosaic)
    }

    @discardableResult func createPlaylist(_ name: String, tracks: [Track] = []) -> Playlist {
        let p = Playlist(id: "local:" + UUID().uuidString, name: name.isEmpty ? "New Playlist" : name,
                         items: tracks.uniqued().map { .init(track: $0, added: .now) }, created: .now, updated: .now)
        playlists[p.id] = p
        push("playlist", p.id, p)
        return p
    }
    func edit(_ id: String, _ f: (inout Playlist) -> Void) {
        guard var p = playlists[id] else { return }
        f(&p); p.updated = .now
        playlists[id] = p
        push("playlist", id, p)
    }
    func rename(_ id: String, to name: String) { edit(id) { $0.name = name } }
    func deletePlaylist(_ id: String) { playlists[id] = nil; push("playlist", id, Optional<Playlist>.none) }
    /// Adds tracks not already in the playlist; returns how many were added.
    @discardableResult func add(_ tracks: [Track], to id: String) -> Int {
        var n = 0
        edit(id) { p in
            let have = Set(p.items.map(\.track.id))
            let new = tracks.uniqued().filter { !have.contains($0.id) }
            n = new.count
            p.items += new.map { .init(track: $0, added: .now) }
        }
        return n
    }
    func remove(_ trackIDs: Set<String>, from id: String) { edit(id) { $0.items.removeAll { trackIDs.contains($0.track.id) } } }
    func move(in id: String, from: IndexSet, to: Int) { edit(id) { $0.items.move(fromOffsets: from, toOffset: to) } }
    func contains(_ t: Track, in id: String) -> Bool { playlists[id]?.items.contains { $0.track.id == t.id } ?? false }

    // MARK: Saved albums / artists / playlists

    func isSaved(_ c: Collection) -> Bool {
        saved[c.id] != nil || (c.type == .album && spotifyAlbums.contains { $0.id == c.id })
            || (c.type == .artist && spotifyArtists.contains { $0.id == c.id })
            || spotifyPlaylists.contains { $0.id == c.id }
    }
    func toggleSave(_ c: Collection) {
        if saved[c.id] != nil { saved[c.id] = nil; push("saved", c.id, Optional<Saved>.none) }
        else { saved[c.id] = Saved(item: c, at: .now); push("saved", c.id, saved[c.id]) }
    }
    /// Saved in Spotify (can't be removed from here) vs saved in Spotube.
    func isSavedInSpotify(_ c: Collection) -> Bool { saved[c.id] == nil && isSaved(c) }

    private func savedOf(_ k: Collection.Kind) -> [Saved] { saved.values.filter { $0.item.type == k }.sorted { $0.at > $1.at } }
    var albums: [Collection] { merge(savedOf(.album).map(\.item), spotifyAlbums) }
    var artists: [Collection] { merge(savedOf(.artist).map(\.item), spotifyArtists) }
    /// Your playlists first, then saved playlists, then Spotify's.
    var allPlaylists: [Collection] {
        merge(localPlaylists.map(collection) + savedOf(.playlist).map(\.item) + savedOf(.spotifyLiked).map(\.item), spotifyPlaylists)
    }
    /// Newest additions across everything (Library home grid).
    var recentlyAdded: [Collection] {
        let s = saved.values.map { ($0.item, $0.at) }
        let p = playlists.values.map { (collection($0), $0.created) }
        return (s + p).sorted { $0.1 > $1.1 }.map(\.0)
    }
    private func merge(_ a: [Collection], _ b: [Collection]) -> [Collection] {
        var seen = Set<String>(); return (a + b).filter { seen.insert($0.id).inserted }
    }

    // MARK: Spotify library cache

    func refreshSpotify() async {
        guard let m = PluginManager.shared.metadata, m.has("library"), !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            spotifyPlaylists = try await m.call("library")
            if m.has("libraryAlbums") { spotifyAlbums = (try? await m.call("libraryAlbums")) ?? spotifyAlbums }
            if m.has("libraryArtists") { spotifyArtists = (try? await m.call("libraryArtists")) ?? spotifyArtists }
            spotifyError = nil
            Store.save(SpotifyCache(playlists: spotifyPlaylists, albums: spotifyAlbums, artists: spotifyArtists), "spotify-library")
        } catch { spotifyError = error.localizedDescription }
    }
    func clearSpotify() {
        spotifyPlaylists = []; spotifyAlbums = []; spotifyArtists = []
        Store.save(SpotifyCache(), "spotify-library")
    }
}
