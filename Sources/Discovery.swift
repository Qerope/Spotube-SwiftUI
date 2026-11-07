import Foundation
import Observation

/// "New Releases" from artists you follow, play and love (refreshed every few hours, cached for offline).
@MainActor @Observable final class Discovery {
    static let shared = Discovery()
    private(set) var releases: [Collection] = Store.load([Collection].self, "new-releases") ?? []
    @ObservationIgnored private var refreshedAt = UserDefaults.standard.double(forKey: "new-releases.at")
    @ObservationIgnored private var running = false

    /// The artists your listening is built around, most important first.
    static func yourArtists(limit: Int = 40) -> [(id: String, name: String)] {
        var score: [String: (name: String, s: Double)] = [:]
        func bump(_ id: String?, _ name: String, _ by: Double) {
            guard let id, id.hasPrefix("spotify:artist:") else { return }
            score[id] = (score[id]?.name ?? name, (score[id]?.s ?? 0) + by)
        }
        for a in Library.shared.artists { bump(a.id, a.title, 20) }
        for (i, a) in (Mixes.stats?.topArtists ?? []).enumerated() { bump(a.id, a.name, 30 - Double(min(i, 25))) }
        for p in PlayCounts.shared.byID.values { bump(p.track.artistID, p.track.primaryArtist, Double(min(p.plays, 10))) }
        for t in Library.shared.favorites { bump(t.artistID, t.primaryArtist, 3) }
        return score.sorted { $0.value.s > $1.value.s }.prefix(limit).map { ($0.key, $0.value.name) }
    }

    func refresh(force: Bool = false) async {
        guard !running, force || releases.isEmpty || Date().timeIntervalSince1970 - refreshedAt > 6 * 3600,
              let m = PluginManager.shared.metadata, m.has("releases") else { return }
        let artists = Self.yourArtists()
        guard !artists.isEmpty else { return }
        running = true; defer { running = false }
        guard let list: [Collection] = try? await m.call("releases", [artists.map { ["id": $0.id, "name": $0.name] }], timeout: 90) else { return }
        releases = list
        refreshedAt = Date().timeIntervalSince1970
        UserDefaults.standard.set(refreshedAt, forKey: "new-releases.at")
        Store.save(list, "new-releases")
    }

    /// Cards with the release date ("Today", "3 days ago", "Oct 16").
    var shelf: [Collection] {
        releases.prefix(30).map { c in
            var c = c
            if let d = c.releaseDate {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: d), to: Calendar.current.startOfDay(for: .now)).day ?? 99
                let when = days <= 0 ? "Today" : days == 1 ? "Yesterday" : days < 7 ? "\(days) days ago" : d.formatted(.dateTime.month(.abbreviated).day())
                c.subtitle = [c.subtitle, when].compactMap { $0 }.joined(separator: " · ")
            }
            return c
        }
    }
}

extension Collection {
    var releaseDate: Date? { released.flatMap { try? Date($0, strategy: .iso8601) } }
}
