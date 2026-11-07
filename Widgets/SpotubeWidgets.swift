import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let red = Color(red: 250 / 255, green: 45 / 255, blue: 72 / 255)

@main struct SpotubeWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
    }
}

// MARK: - Live Activity (Lock Screen + Dynamic Island)

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { ctx in
            LockScreenActivity(s: ctx.state).activityBackgroundTint(.black.opacity(0.55)).activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { ArtView(data: s.art, size: 56, radius: 10).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.trailing) { Bars(playing: s.playing).frame(width: 22, height: 18).padding(.trailing, 8).padding(.top, 8) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(1)
                        Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Progress(s: s)
                        Controls(playing: s.playing).font(.title2)
                    }.padding(.horizontal, 6)
                }
            } compactLeading: {
                ArtView(data: s.art, size: 22, radius: 5)
            } compactTrailing: {
                Bars(playing: s.playing).frame(width: 16, height: 12)
            } minimal: {
                ArtView(data: s.art, size: 22, radius: 11)
            }
            .keylineTint(red)
            .widgetURL(URL(string: "spotubelite://nowplaying"))
        }
    }
}

private struct LockScreenActivity: View {
    let s: NowPlayingAttributes.ContentState
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtView(data: s.art, size: 52, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.headline).lineLimit(1)
                    Text(s.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Controls(playing: s.playing).font(.title3)
            }
            Progress(s: s)
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

private struct Progress: View {
    let s: NowPlayingAttributes.ContentState
    var body: some View {
        Group {
            if s.playing, let start = s.start, s.duration > 0 {
                ProgressView(timerInterval: start...start.addingTimeInterval(s.duration), countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: min(s.position, max(s.duration, 1)), total: max(s.duration, 1))
            }
        }
        .progressViewStyle(.linear).tint(.white.opacity(0.9)).labelsHidden()
    }
}

private struct Controls: View {
    let playing: Bool
    var body: some View {
        HStack(spacing: 22) {
            Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
            Button(intent: TogglePlaybackIntent()) { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 26) }
            Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain).foregroundStyle(.white)
    }
}

private struct ArtView: View {
    let data: Data?; let size: CGFloat; let radius: CGFloat
    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { ZStack { LinearGradient(colors: [red, .pink.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").foregroundStyle(.white) } }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Little equalizer like Apple Music's (static: Live Activities can't animate freely).
private struct Bars: View {
    let playing: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([0.55, 1.0, 0.7, 0.85], id: \.self) { h in
                Capsule().fill(red).frame(maxHeight: .infinity).scaleEffect(y: playing ? h : 0.2, anchor: .bottom)
            }
        }
    }
}

// MARK: - Home / Lock Screen widget

struct NowPlayingEntry: TimelineEntry {
    var date: Date
    var snap: SharedPlayer.Snapshot?
    var art: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snap: .init(title: "Song", artist: "Artist", playing: true, position: 40, duration: 200, updated: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) { completion(entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))  // the app reloads it when the song changes
    }
    private func entry() -> NowPlayingEntry {
        let art = SharedPlayer.artURL.flatMap { try? Data(contentsOf: $0) }.flatMap { UIImage(data: $0) }
        return NowPlayingEntry(date: .now, snap: SharedPlayer.load(), art: art)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { e in
            NowPlayingWidgetView(e: e).containerBackground(for: .widget) { WidgetBackground(art: e.art) }
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing in Spotube Lite, with controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

private struct WidgetBackground: View {
    let art: UIImage?
    @Environment(\.widgetFamily) var family
    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryCircular, .accessoryInline: AccessoryWidgetBackground().opacity(0)
        default:
            ZStack {
                Color.black
                if let art { Image(uiImage: art).resizable().scaledToFill().blur(radius: 30).opacity(0.55) }
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

struct NowPlayingWidgetView: View {
    let e: NowPlayingEntry
    @Environment(\.widgetFamily) var family
    var body: some View {
        let s = e.snap
        Group {
            switch family {
            case .accessoryInline:
                Label(s.map { "\($0.title) · \($0.artist)" } ?? "Spotube Lite", systemImage: s?.playing == true ? "waveform" : "music.note")
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: s?.playing == true ? "waveform" : "music.note").font(.title3)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label(s?.playing == true ? "Now Playing" : "Spotube Lite", systemImage: s?.playing == true ? "waveform" : "music.note")
                        .font(.caption2.weight(.semibold)).widgetAccentable()
                    Text(s?.title ?? "Nothing playing").font(.headline).lineLimit(1)
                    Text(s?.artist ?? "Open the app to play music").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            case .systemMedium:
                HStack(spacing: 14) {
                    art(110)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s?.playing == true ? "NOW PLAYING" : "LAST PLAYED").font(.caption2.weight(.bold)).foregroundStyle(red)
                        Text(s?.title ?? "Nothing playing").font(.headline).lineLimit(2)
                        Text(s?.artist ?? "Open Spotube Lite").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if s != nil { Controls(playing: s?.playing == true).font(.title3) }
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        art(62)
                        Spacer()
                        if s != nil {
                            Button(intent: TogglePlaybackIntent()) {
                                Image(systemName: s?.playing == true ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30)).foregroundStyle(.white, red)
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(s?.title ?? "Nothing playing").font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(s?.artist ?? "Open Spotube Lite").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .widgetURL(URL(string: "spotubelite://nowplaying"))
    }
    private func art(_ size: CGFloat) -> some View {
        Group {
            if let a = e.art { Image(uiImage: a).resizable().scaledToFill() }
            else { ZStack { LinearGradient(colors: [red, .pink.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing); Image(systemName: "music.note").font(.title).foregroundStyle(.white) } }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).shadow(radius: 6)
    }
}
