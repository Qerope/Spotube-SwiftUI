import SwiftUI

// MARK: - Model

/// Rules of a smart playlist (stored on the synced `Playlist`, so it updates itself on every device).
struct SmartRules: Codable, Hashable {
    enum Match: String, Codable, CaseIterable { case all, any }
    enum Order: String, Codable, CaseIterable, Identifiable {
        case mostPlayed = "Most Played", recentlyPlayed = "Recently Played", leastRecentlyPlayed = "Least Recently Played"
        case recentlyAdded = "Recently Added", random = "Random", title = "Title", artist = "Artist"
        var id: String { rawValue }
    }
    var match: Match = .all
    var rules: [SmartRule] = []
    var limit: Int? = 50
    var order: Order = .mostPlayed
}

struct SmartRule: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case artist = "Artist", title = "Title", album = "Album", loved = "Favorite", plays = "Plays", skips = "Skips"
        case lastPlayed = "Last Played", added = "Date Added", duration = "Duration", downloaded = "Downloaded", explicit = "Explicit"
        var id: String { rawValue }
        var kind: Kind {
            switch self {
            case .artist, .title, .album: .text
            case .plays, .skips: .count
            case .lastPlayed, .added: .days
            case .duration: .minutes
            case .loved, .downloaded, .explicit: .flag
            }
        }
        enum Kind { case text, count, days, minutes, flag }
    }
    enum Op: String, Codable, CaseIterable, Identifiable {
        case contains = "contains", notContains = "does not contain", is_ = "is", isNot = "is not"
        case greater = "is more than", less = "is less than", within = "in the last", notWithin = "not in the last"
        case longer = "is longer than", shorter = "is shorter than", yes = "yes", no = "no"
        var id: String { rawValue }
    }
    var id = UUID()
    var field: Field
    var op: Op
    var text = ""
    var number: Double = 0

    static func ops(_ f: Field) -> [Op] {
        switch f.kind {
        case .text: [.contains, .notContains, .is_, .isNot]
        case .count: [.greater, .less]
        case .days: [.within, .notWithin]
        case .minutes: [.longer, .shorter]
        case .flag: [.yes, .no]
        }
    }
    static func new(_ f: Field) -> SmartRule {
        SmartRule(field: f, op: ops(f)[0], number: f.kind == .days ? 30 : f.kind == .minutes ? 5 : f.kind == .count ? 5 : 0)
    }
}

extension Playlist { var isSmart: Bool { smart != nil } }

// MARK: - Play counts (from the server, all devices)

struct TrackPlays: Codable { var track: Track; var plays: Int; var skips: Int; var last: Int64; var first: Int64 }

@MainActor @Observable final class PlayCounts {
    static let shared = PlayCounts()
    private(set) var byID: [String: TrackPlays] = Dictionary((Store.load([TrackPlays].self, "track-plays") ?? []).map { ($0.track.id, $0) }) { a, _ in a }
    @ObservationIgnored private var fetched = Date.distantPast

    func refresh(force: Bool = false) async {
        guard Cloud.shared.enabled, force || Date().timeIntervalSince(fetched) > 120 else { return }
        fetched = .now
        guard let all: [TrackPlays] = try? await Cloud.shared.trackPlays() else { return }
        byID = Dictionary(all.map { ($0.track.id, $0) }) { a, _ in a }
        Store.save(all, "track-plays")
    }
}

// MARK: - Engine

@MainActor enum SmartEngine {
    struct Info { var track: Track; var plays = 0; var skips = 0; var lastPlayed: Date?; var added: Date?; var loved = false; var downloaded = false }

    /// Every song the app knows about: favorites, your playlists, downloads, history, and everything ever played on any device.
    static func pool() -> [String: Info] {
        let lib = Library.shared, dl = Downloads.shared
        var out: [String: Info] = [:]
        func add(_ t: Track, added: Date? = nil) {
            var i = out[t.id] ?? Info(track: t)
            if let added { i.added = min(i.added ?? added, added) }
            out[t.id] = i
        }
        for (_, p) in PlayCounts.shared.byID {
            add(p.track, added: Date(timeIntervalSince1970: Double(p.first) / 1000))
            out[p.track.id]?.plays = p.plays; out[p.track.id]?.skips = p.skips
            out[p.track.id]?.lastPlayed = Date(timeIntervalSince1970: Double(p.last) / 1000)
        }
        for l in lib.likes.values { add(l.track, added: l.at); out[l.track.id]?.loved = true }
        for p in lib.playlists.values where !p.isSmart { for it in p.items { add(it.track, added: it.added) } }
        for d in dl.items.values { add(d.track, added: d.at); out[d.track.id]?.downloaded = true }
        for t in Player.shared.history where out[t.id] == nil { add(t); out[t.id]?.plays = 1 }
        return out
    }

    static func tracks(_ r: SmartRules, pool: [String: Info]? = nil) -> [Track] {
        let pool = pool ?? self.pool()
        var hits = pool.values.filter { i in
            guard !r.rules.isEmpty else { return true }
            return r.match == .all ? r.rules.allSatisfy { test($0, i) } : r.rules.contains { test($0, i) }
        }
        let far = Date.distantPast
        switch r.order {
        case .mostPlayed: hits.sort { ($0.plays, $0.lastPlayed ?? far) > ($1.plays, $1.lastPlayed ?? far) }
        case .recentlyPlayed: hits.sort { ($0.lastPlayed ?? far) > ($1.lastPlayed ?? far) }
        case .leastRecentlyPlayed: hits.sort { ($0.lastPlayed ?? far) < ($1.lastPlayed ?? far) }
        case .recentlyAdded: hits.sort { ($0.added ?? far) > ($1.added ?? far) }
        case .random:
            // Stable within a day so the list doesn't reshuffle on every redraw.
            let seed = UInt64(Date().timeIntervalSince1970 / 86400)
            func h(_ s: String) -> UInt64 { s.utf8.reduce(1469598103934665603 ^ seed) { ($0 ^ UInt64($1)) &* 1099511628211 } }
            hits.sort { h($0.track.id) < h($1.track.id) }
        case .title: hits.sort { $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending }
        case .artist: hits.sort { ($0.track.artist.lowercased(), $0.track.album ?? "") < ($1.track.artist.lowercased(), $1.track.album ?? "") }
        }
        let t = hits.map(\.track)
        return r.limit.map { Array(t.prefix($0)) } ?? t
    }

    private static func test(_ r: SmartRule, _ i: Info) -> Bool {
        let t = i.track
        func text(_ s: String?) -> Bool {
            let v = (s ?? "").lowercased(), q = r.text.lowercased().trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return true }
            switch r.op {
            case .contains: return v.contains(q)
            case .notContains: return !v.contains(q)
            case .is_: return v == q
            case .isNot: return v != q
            default: return true
            }
        }
        func days(_ d: Date?) -> Bool {
            let inside = d.map { Date().timeIntervalSince($0) <= r.number * 86400 } ?? false
            return r.op == .within ? inside : !inside
        }
        let flag = r.op == .yes
        switch r.field {
        case .artist: return text(t.artist)
        case .title: return text(t.title)
        case .album: return text(t.album)
        case .plays: return r.op == .greater ? Double(i.plays) > r.number : Double(i.plays) < r.number
        case .skips: return r.op == .greater ? Double(i.skips) > r.number : Double(i.skips) < r.number
        case .lastPlayed: return days(i.lastPlayed)
        case .added: return days(i.added)
        case .duration:
            guard let d = t.duration else { return false }
            return r.op == .longer ? d > r.number * 60 : d < r.number * 60
        case .loved: return i.loved == flag
        case .downloaded: return i.downloaded == flag
        case .explicit: return (t.explicit ?? false) == flag
        }
    }

    /// One-tap starting points, like Apple Music's built-in smart playlists.
    static let templates: [(String, String, SmartRules)] = [
        ("Top 25 Most Played", "chart.bar.fill", SmartRules(rules: [.init(field: .plays, op: .greater, number: 0)], limit: 25, order: .mostPlayed)),
        ("Recently Played", "clock.fill", SmartRules(rules: [.init(field: .lastPlayed, op: .within, number: 14)], limit: 100, order: .recentlyPlayed)),
        ("Recently Loved", "heart.fill", SmartRules(rules: [.init(field: .loved, op: .yes), .init(field: .added, op: .within, number: 30)], limit: nil, order: .recentlyAdded)),
        ("Forgotten Favorites", "sparkles", SmartRules(rules: [.init(field: .loved, op: .yes), .init(field: .lastPlayed, op: .notWithin, number: 60)], limit: 50, order: .random)),
        ("Never Skipped", "forward.end.alt", SmartRules(rules: [.init(field: .plays, op: .greater, number: 2), .init(field: .skips, op: .less, number: 1)], limit: 100, order: .mostPlayed)),
        ("Quick Hits", "bolt.fill", SmartRules(rules: [.init(field: .duration, op: .shorter, number: 3), .init(field: .plays, op: .greater, number: 0)], limit: 50, order: .random)),
    ]
}

// MARK: - Editor

struct SmartEdit: Identifiable { let id = UUID(); var playlist: Playlist? }

struct SmartPlaylistEditor: View {
    let edit: SmartEdit
    @Environment(Library.self) var lib
    @Environment(Router.self) var router
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var rules = SmartRules(rules: [.new(.loved)])
    @State private var limited = true

    var body: some View {
        NavigationStack {
            Form {
                if edit.playlist == nil {
                    Section("Start From") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(SmartEngine.templates, id: \.0) { t in
                                    Button { name = t.0; rules = t.2; limited = t.2.limit != nil } label: {
                                        Label(t.0, systemImage: t.1).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(name == t.0 ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 2)
                        }
                    }
                }
                Section { TextField("Name", text: $name) }
                Section {
                    Picker("Match", selection: $rules.match) {
                        Text("All rules").tag(SmartRules.Match.all); Text("Any rule").tag(SmartRules.Match.any)
                    }
                    ForEach($rules.rules) { $r in RuleRow(rule: $r) { rules.rules.removeAll { $0.id == r.id } } }
                    Menu {
                        ForEach(SmartRule.Field.allCases) { f in Button(f.rawValue) { rules.rules.append(.new(f)) } }
                    } label: { Label("Add Rule", systemImage: "plus.circle.fill") }
                } header: { Text("Rules") } footer: { Text("Songs come from your favorites, playlists, downloads and everything you've played on any device.") }
                Section {
                    Picker("Sort", selection: $rules.order) { ForEach(SmartRules.Order.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Limit songs", isOn: $limited)
                    if limited {
                        Stepper(value: Binding(get: { rules.limit ?? 50 }, set: { rules.limit = $0 }), in: 5...1000, step: 5) {
                            LabeledContent("Up to", value: "\(rules.limit ?? 50) songs")
                        }
                    }
                } footer: {
                    let n = SmartEngine.tracks(SmartRules(match: rules.match, rules: rules.rules, limit: limited ? rules.limit : nil, order: rules.order)).count
                    Text("\(n) song\(n == 1 ? "" : "s") match right now. The playlist updates itself as you listen.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(edit.playlist == nil ? "New Smart Playlist" : "Edit Smart Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(edit.playlist == nil ? "Create" : "Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
        .onAppear {
            if let p = edit.playlist, let s = p.smart { name = p.name; rules = s; limited = s.limit != nil }
        }
        .task { await PlayCounts.shared.refresh() }
    }

    private func save() {
        var r = rules
        if !limited { r.limit = nil } else if r.limit == nil { r.limit = 50 }
        let n = name.trimmingCharacters(in: .whitespaces)
        if let p = edit.playlist {
            lib.edit(p.id) { $0.name = n; $0.smart = r }
        } else {
            let p = lib.createPlaylist(n)
            lib.edit(p.id) { $0.smart = r }
            router.open(lib.collection(lib.playlists[p.id] ?? p))
        }
        dismiss()
    }
}

private struct RuleRow: View {
    @Binding var rule: SmartRule
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { rule.field }, set: { f in if f != rule.field { let id = rule.id; rule = .new(f); rule.id = id } })) {
                ForEach(SmartRule.Field.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().fixedSize()
            Picker("", selection: $rule.op) { ForEach(SmartRule.ops(rule.field)) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
            switch rule.field.kind {
            case .text: TextField("Text", text: $rule.text).autocorrectionDisabled()
            case .flag: Spacer()
            default:
                TextField("", value: $rule.number, format: .number).frame(width: 56).multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text(rule.field.kind == .days ? "days" : rule.field.kind == .minutes ? "min" : "").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }.buttonStyle(.borderless)
        }
    }
}
