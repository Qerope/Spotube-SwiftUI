import Foundation

struct Track: Codable, Identifiable, Hashable {
    var id: String; var title: String; var artist: String
    var album: String?; var art: String?; var duration: Double?
    var extra: [String: String]?
}

extension Track {
    var albumID: String? { extra?["albumUri"] }
    var artistID: String? { extra?["artistUri"] }
    var artistNames: [String] { artist.components(separatedBy: ", ").filter { !$0.isEmpty } }
    var primaryArtist: String { artistNames.first ?? artist }
    /// (name, id) for every credited artist, when the plugin provided ids.
    var artistLinks: [Collection] {
        let ids = extra?["artistUris"]?.split(separator: ",").map(String.init) ?? artistID.map { [$0] } ?? []
        return zip(artistNames, ids).map { Collection(id: $1, title: $0, subtitle: "Artist", kind: "artist") }
    }
    var explicit: Bool { extra?["explicit"] == "1" }
    var trackNumber: Int? { extra?["trackNumber"].flatMap { Int($0) } }
    var disc: Int? { extra?["disc"].flatMap { Int($0) } }
    var plays: Int? { extra?["plays"].flatMap { Int($0) } }
    var addedAt: Date? { extra?["addedAt"].flatMap { ISO8601DateFormatter().date(from: $0) } }
    var shareURL: URL? { extra?["uri"]?.hasPrefix("spotify:track:") == true ? URL(string: "https://open.spotify.com/track/\(id)") : nil }
    var albumLink: Collection? { albumID.map { Collection(id: $0, title: album ?? "Album", art: art, kind: "album") } }
    var artistLink: Collection? { artistLinks.first ?? artistID.map { Collection(id: $0, title: primaryArtist, subtitle: "Artist", kind: "artist") } }
}

/// Anything that opens as a page: album, playlist, artist, local playlist, mix, library list.
struct Collection: Codable, Identifiable, Hashable {
    var id: String; var title: String; var subtitle: String?; var art: String?
    var kind: String?; var color: String?
    /// Artwork for generated covers (local playlists, mixes).
    var mosaic: [String]?
    /// Release day (ISO 8601) for new releases.
    var released: String? = nil

    enum Kind { case album, artist, playlist, spotifyLiked, local, mix, favorites, downloads, history }
    var type: Kind {
        if id.hasPrefix("spotify:artist:") { return .artist }
        if id.hasPrefix("spotify:album:") { return .album }
        if id == "liked" { return .spotifyLiked }
        if id.hasPrefix("local:") { return .local }
        if id.hasPrefix("mix:") { return .mix }
        if id == "favorites" { return .favorites }
        if id == "downloads" { return .downloads }
        if id == "history" { return .history }
        return kind == "artist" ? .artist : kind == "album" || kind == "single" || kind == "ep" || kind == "compilation" ? .album : .playlist
    }
    var isArtist: Bool { type == .artist }
    var shareURL: URL? {
        let p = id.split(separator: ":")
        return p.count == 3 && p[0] == "spotify" ? URL(string: "https://open.spotify.com/\(p[1])/\(p[2])") : nil
    }
    static let favorites = Collection(id: "favorites", title: "Favorite Songs", subtitle: "Songs you love", kind: "favorites")
    static let downloads = Collection(id: "downloads", title: "Downloaded", subtitle: "Available offline", kind: "downloads")
    static let history = Collection(id: "history", title: "Recently Played", kind: "history")
}

struct CollectionDetails: Codable {
    var id: String?; var title: String?; var subtitle: String?; var art: String?; var color: String?; var kind: String?
    var description: String?; var year: String?; var label: String?; var copyright: String?; var artistId: String?
    var followers: Int?; var tracks: [Track]; var more: [Collection]?
}

struct ArtistPage: Codable {
    var name: String; var art: String?; var header: String?; var color: String?; var bio: String?
    var monthlyListeners: Int?; var followers: Int?; var topCities: [String]?
    var tracks: [Track]; var albums: [Collection]; var related: [Collection]?; var appearsOn: [Collection]?
}

struct SearchResult: Codable {
    struct Top: Codable { var id: String; var type: String }
    var top: Top?; var tracks: [Track]; var artists: [Collection]; var albums: [Collection]?; var playlists: [Collection]?; var error: String?
}

/// A YouTube upload that could be the audio for a track ("Choose Version").
struct Candidate: Codable, Identifiable, Hashable {
    var id: String; var title: String; var channel: String; var duration: Double?; var music: Bool; var score: Int; var current: Bool
}

struct PlayContext: Codable, Hashable {
    var id: String; var title: String; var art: String?
}

extension Double {
    var nanSafe: Double? { isFinite ? self : nil }
    var mmss: String { let s = Int(isFinite ? max(self, 0) : 0); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
    /// "1 hr 12 min" / "48 min"
    var longDuration: String {
        let m = Int((self / 60).rounded())
        return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
    }
}

extension Int {
    var compact: String {
        let d = Double(self)
        switch d {
        case 1e9...: return String(format: "%.1fB", d / 1e9)
        case 1e6...: return String(format: "%.1fM", d / 1e6)
        case 1e3...: return String(format: "%.1fK", d / 1e3)
        default: return "\(self)"
        }
    }
}

extension Array where Element == Track {
    var totalDuration: Double { reduce(0) { $0 + ($1.duration ?? 0) } }
    var summary: String { "\(count) song\(count == 1 ? "" : "s")" + (totalDuration > 0 ? ", \(totalDuration.longDuration)" : "") }
    func uniqued() -> [Track] { var seen = Set<String>(); return filter { seen.insert($0.id).inserted } }
    /// Up to four distinct album covers, for mosaic artwork.
    var mosaic: [String] { var seen = Set<String>(); return compactMap(\.art).filter { seen.insert($0).inserted }.prefix(4).map { $0 } }
}

let nowMs: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

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

/// Disk cache for things that can be re-fetched (collection pages, lyrics) so pages open instantly and work offline.
enum DiskCache {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "pages")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }()
    private static func file(_ key: String) -> URL { dir.appending(path: key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key) }
    static func load<T: Decodable>(_ t: T.Type, _ key: String) -> T? {
        (try? Data(contentsOf: file(key))).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    static func save<T: Encodable>(_ v: T, _ key: String) { try? JSONEncoder().encode(v).write(to: file(key), options: .atomic) }
}
