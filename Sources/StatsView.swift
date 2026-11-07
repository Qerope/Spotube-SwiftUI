import SwiftUI
import Charts

/// "Replay": listening stats across all your devices, from the server's play history.
struct StatsView: View {
    @Environment(Cloud.self) var cloud
    @Environment(Player.self) var player
    @Environment(Router.self) var router
    @AppStorage("stats.days") private var days = 30
    @State private var stats: Stats?
    @State private var err: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Picker("Period", selection: $days) {
                    Text("Week").tag(7); Text("Month").tag(30); Text("Year").tag(365); Text("All Time").tag(0)
                }.pickerStyle(.segmented).padding(.horizontal, Theme.gutter)
                if let s = stats {
                    if s.plays == 0 { EmptyState(title: "No Listening Yet", icon: "chart.bar", message: "Play some music and your stats will show up here.") }
                    else { content(s) }
                } else if let err {
                    EmptyState(title: cloud.enabled ? "Couldn't Load Stats" : "Server Needed", icon: "chart.bar.xaxis",
                               message: cloud.enabled ? err : "Replay uses your Spotube server's listening history. Set it up in Settings → Server.")
                } else { ProgressView().frame(maxWidth: .infinity).padding(60) }
            }.padding(.vertical, 16)
        }
        .scrollContentBackground(.hidden).background(.black)
        .navigationTitle("Replay")
        .task(id: days) { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func content(_ s: Stats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            tile("\(Int(s.minutes).formatted())", "Minutes Listened", "clock")
            tile("\(s.plays.formatted())", "Plays", "play.circle")
            tile("\(s.uniqueTracks.formatted())", "Different Songs", "music.note")
            tile("\(s.uniqueArtists.formatted())", "Artists", "music.microphone")
            tile("\(Int(s.skipRate * 100))%", "Skipped", "forward")
        }.padding(.horizontal, Theme.gutter)

        if s.byDay.count > 1 {
            card("Minutes per Day") {
                Chart(s.byDay, id: \.day) { d in
                    BarMark(x: .value("Day", Self.date(d.day) ?? .now, unit: .day), y: .value("Minutes", d.minutes)).foregroundStyle(.tint).cornerRadius(2)
                }.frame(height: 180)
            }
        }
        card("When You Listen") {
            Chart(Array(s.byHour.enumerated()), id: \.offset) { h, m in
                BarMark(x: .value("Hour", h), y: .value("Minutes", m)).foregroundStyle(.tint.opacity(0.85)).cornerRadius(2)
            }
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { v in AxisValueLabel { Text(Self.hour(v.as(Int.self) ?? 0)) } } }
            .frame(height: 150)
        }

        if !s.topTracks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Top Songs").font(.title2.bold())
                    Spacer()
                    Button { player.play(s.topTracks.map(\.track), context: PlayContext(id: "mix:replay", title: "Replay")) } label: { Label("Play All", systemImage: "play.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.tint)
                }
                ForEach(Array(s.topTracks.prefix(25).enumerated()), id: \.offset) { i, t in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
                        TrackRow(t: t.track, showAlbum: false, trailing: "\(t.plays) plays · \(Int(t.minutes)) min") {
                            player.play(s.topTracks.map(\.track), at: i, context: PlayContext(id: "mix:replay", title: "Replay"))
                        }
                    }
                }
            }.padding(.horizontal, Theme.gutter)
        }
        if !s.topArtists.isEmpty {
            Shelf(title: "Top Artists") {
                ForEach(Array(s.topArtists.prefix(20).enumerated()), id: \.offset) { i, a in
                    Button { if let id = a.id { router.open(Collection(id: id, title: a.name, subtitle: "Artist", kind: "artist")) } } label: {
                        VStack(spacing: 6) {
                            Art(url: a.id.flatMap { Catalog.cachedArtist($0)?.art }, size: 120, radius: 60)
                            Text("\(i + 1). \(a.name)").font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(Int(a.minutes)) min").font(.caption).foregroundStyle(.secondary)
                        }.frame(width: 124)
                    }.buttonStyle(PressStyle()).foregroundStyle(.primary)
                }
            }
        }
        if !s.topAlbums.isEmpty {
            Shelf(title: "Top Albums") {
                ForEach(Array(s.topAlbums.prefix(20).enumerated()), id: \.offset) { i, a in
                    VStack(alignment: .leading, spacing: 6) {
                        Art(url: a.art, size: 140)
                        Text("\(i + 1). \(a.title)").font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(a.artist) · \(a.plays) plays").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(width: 140)
                }
            }
        }
        if s.byDevice.count > 1 {
            card("Devices") {
                Chart(s.byDevice, id: \.device) { d in
                    SectorMark(angle: .value("Minutes", d.minutes), innerRadius: .ratio(0.6), angularInset: 2).foregroundStyle(by: .value("Device", d.device))
                }.frame(height: 180)
            }
        }
    }

    private func tile(_ v: String, _ l: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(v).font(.title.bold()).minimumScaleFactor(0.6).lineLimit(1)
            Text(l).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func card<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.title3.bold()); c() }
            .padding(16).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, Theme.gutter)
    }
    private static func date(_ s: String) -> Date? { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.date(from: s) }
    private static func hour(_ h: Int) -> String { h == 0 ? "12a" : h < 12 ? "\(h)a" : h == 12 ? "12p" : "\(h - 12)p" }

    private func load() async {
        guard cloud.enabled else { err = "No server"; return }
        if stats == nil || stats?.days != days { stats = Store.load(Stats.self, "stats-\(days)") }
        do { let s = try await cloud.stats(days: days); stats = s; err = nil; Store.save(s, "stats-\(days)") }
        catch { if stats == nil { err = error.localizedDescription } }
    }
}
