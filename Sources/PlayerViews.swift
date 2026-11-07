import SwiftUI
import AVKit
#if os(iOS)
import MediaPlayer
#endif

// MARK: - Mini players

#if os(macOS)
/// Bottom bar on the Mac.
struct MiniPlayerBar: View {
    @Environment(Player.self) var p
    @Environment(Router.self) var router
    @Environment(Library.self) var lib
    var body: some View {
        @Bindable var p = p
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                Button { router.showFull = true } label: { Art(url: p.current?.art, size: 50) }.buttonStyle(PressStyle()).help("Now Playing")
                VStack(alignment: .leading, spacing: 2) {
                    if let t = p.current { TrackLinks(t: t) }
                    status
                }
                if let t = p.current {
                    Button { lib.toggleLike(t) } label: { Image(systemName: lib.isLiked(t) ? "heart.fill" : "heart").foregroundStyle(lib.isLiked(t) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) }
                        .help("Love")
                }
            }.frame(width: 300, alignment: .leading)
            VStack(spacing: 2) {
                HStack(spacing: 24) {
                    ShuffleButton(); Button { p.prev() } label: { Image(systemName: "backward.fill") }
                    PlayPauseButton(size: 34)
                    Button { p.next() } label: { Image(systemName: "forward.fill") }; RepeatButton()
                }
                SeekBar(compact: true).frame(maxWidth: 560)
            }.frame(maxWidth: .infinity)
            HStack(spacing: 14) {
                Button { router.showFull = true; router.panel = .lyrics } label: { Image(systemName: "quote.bubble") }.help("Lyrics")
                Button { router.showQueue.toggle() } label: { Image(systemName: "list.bullet").foregroundStyle(router.showQueue ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)) }.help("Up Next")
                RoutePicker().frame(width: 22, height: 22).help("AirPlay")
                VolumeControl().frame(width: 110)
            }
        }
        .buttonStyle(.plain).font(.title3)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
    @ViewBuilder private var status: some View {
        if p.loading { Text("Loading…").font(.caption2).foregroundStyle(.secondary) }
        else if let e = p.error { Text(e).font(.caption2).foregroundStyle(e.hasPrefix("via") ? Color.secondary : Color.red).lineLimit(1).help(e) }
        else if let s = p.sleepAt { Text("Sleep in \(Int(s.timeIntervalSinceNow / 60) + 1) min").font(.caption2).foregroundStyle(.secondary) }
    }
}
#endif

#if os(iOS)
/// Tab bar accessory on iPhone (iOS 26 style).
struct MiniPlayerAccessory: View {
    @Environment(Player.self) var p
    @Environment(Router.self) var router
    @Environment(\.tabViewBottomAccessoryPlacement) var placement
    var body: some View {
        HStack(spacing: 12) {
            Art(url: p.current?.art, size: 34, radius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(p.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                if placement != .inline {
                    Text(p.loading ? "Loading…" : p.error ?? p.current?.artist ?? "").font(.caption).foregroundStyle(p.error != nil && p.error?.hasPrefix("via") == false ? .red : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            PlayPauseButton(size: 22, filled: false)
            if placement != .inline { Button { p.next() } label: { Image(systemName: "forward.fill") }.font(.title3) }
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { router.showFull = true }
        .buttonStyle(.plain)
    }
}
#endif

/// Title + artist that jump to the album / artist.
struct TrackLinks: View {
    @Environment(Router.self) var router
    let t: Track
    var titleFont: Font = .body
    var center = false
    var body: some View {
        VStack(alignment: center ? .center : .leading, spacing: 2) {
            Button { if let a = t.albumLink { router.open(a) } } label: { Text(t.title).font(titleFont).lineLimit(1) }
                .buttonStyle(.plain).disabled(t.albumLink == nil).help(t.album.map { "Go to \($0)" } ?? "")
            Button { if let a = t.artistLink { router.open(a) } } label: { Text(t.artist).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                .buttonStyle(.plain).disabled(t.artistLink == nil).help("Go to artist")
        }
    }
}

// MARK: - Controls

struct PlayPauseButton: View {
    @Environment(Player.self) var p
    var size: CGFloat = 34
    var filled = true
    var body: some View {
        Button { p.toggle() } label: {
            ZStack {
                if p.loading { ProgressView().controlSize(size > 40 ? .large : .small) }
                else {
                    Image(systemName: filled ? (p.playing ? "pause.circle.fill" : "play.circle.fill") : (p.playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: size)).contentTransition(.symbolEffect(.replace))
                }
            }.frame(width: size + 4, height: size + 4)
        }
        .buttonStyle(.plain).keyboardShortcut(.init("p"), modifiers: [.command, .option])
        .sensoryFeedback(.impact(weight: .light), trigger: p.playing)
    }
}

struct ShuffleButton: View {
    @Environment(Player.self) var p
    var body: some View {
        Button { p.shuffle.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(p.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) }
            .help(p.shuffle ? "Shuffle on" : "Shuffle off").buttonStyle(.plain)
    }
}
struct RepeatButton: View {
    @Environment(Player.self) var p
    var body: some View {
        Button { p.cycleRepeat() } label: {
            Image(systemName: p.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(p.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        }.help("Repeat: \(p.repeatMode.rawValue)").buttonStyle(.plain)
    }
}
struct AutoplayButton: View {
    @Environment(Player.self) var p
    var body: some View {
        Button { p.autoplay.toggle() } label: { Image(systemName: "infinity").foregroundStyle(p.autoplay ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)) }
            .help(p.autoplay ? "Autoplay on: keeps playing similar songs" : "Autoplay off").buttonStyle(.plain)
    }
}

/// Apple Music style scrubber: thin bar that thickens while dragging; elapsed / remaining below.
struct SeekBar: View {
    @Environment(Player.self) var p
    var compact = false
    @State private var drag: Double?
    var body: some View {
        let d = max(p.duration ?? 1, 1)
        let v = min(drag ?? p.progress, d)
        let bar = GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(drag == nil ? Color.white.opacity(0.75) : .white).frame(width: max(0, g.size.width * v / d))
            }
            .frame(height: drag == nil ? (compact ? 4 : 6) : (compact ? 7 : 11))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag = max(0, min(d, Double($0.location.x / g.size.width) * d)) }
                .onEnded { _ in if let x = drag { p.seek(x) }; drag = nil })
            .animation(.spring(duration: 0.25), value: drag == nil)
        }
        .frame(height: 18)
        if compact {
            HStack(spacing: 8) {
                Text(v.mmss).frame(width: 42, alignment: .trailing)
                bar
                Text("-" + (d - v).mmss).frame(width: 42, alignment: .leading)
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 4) {
                bar
                HStack { Text(v.mmss); Spacer(); Text("-" + (d - v).mmss) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

struct VolumeControl: View {
    @Environment(Player.self) var p
    var body: some View {
        #if os(iOS)
        SystemVolume().frame(height: 30)
        #else
        @Bindable var p = p
        HStack(spacing: 8) {
            Image(systemName: p.volume == 0 ? "speaker.slash.fill" : "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: $p.volume, in: 0...1).controlSize(.mini)
        }
        #endif
    }
}

#if os(iOS)
/// The system volume slider (hardware volume, AirPlay aware).
struct SystemVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { let v = MPVolumeView(); v.showsVolumeSlider = true; v.tintColor = .white; return v }
    func updateUIView(_: MPVolumeView, context: Context) {}
}
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.tintColor = .white; v.prioritizesVideoDevices = false; return v }
    func updateUIView(_: AVRoutePickerView, context: Context) {}
}
#else
struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView { let v = AVRoutePickerView(); v.isRoutePickerButtonBordered = false; return v }
    func updateNSView(_: AVRoutePickerView, context: Context) {}
}
#endif

struct SleepTimerMenu: View {
    @Environment(Player.self) var p
    var body: some View {
        Menu {
            if p.sleepAt != nil || p.sleepEndOfTrack { Button("Turn Off Timer") { p.setSleep(minutes: nil) } }
            ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in Button("\(m) minutes") { p.setSleep(minutes: m) } }
            Button("End of Current Song") { p.setSleepEndOfTrack() }
        } label: {
            Image(systemName: p.sleepAt != nil || p.sleepEndOfTrack ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(p.sleepAt != nil || p.sleepEndOfTrack ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .menuIndicator(.hidden).fixedSize().help("Sleep Timer")
    }
}

// MARK: - Now Playing

struct FullPlayer: View {
    @Environment(Player.self) var p
    @Environment(Router.self) var router
    @Environment(Library.self) var lib
    @State private var bg: Color = .black
    @State private var dragY: CGFloat = 0

    var body: some View {
        @Bindable var router = router
        ZStack {
            background
            #if os(macOS)
            HStack(spacing: 0) {
                VStack(spacing: 22) {
                    HStack {
                        Button { router.showFull = false } label: { Image(systemName: "chevron.down").font(.title2) }.keyboardShortcut(.escape, modifiers: [])
                        Spacer()
                        if let c = p.context { Text("Playing from \(c.title)").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        Spacer()
                        SleepTimerMenu()
                    }
                    Spacer(minLength: 0)
                    artwork(maxSide: 420)
                    titleRow
                    SeekBar()
                    controls
                    HStack(spacing: 26) { ShuffleButton(); RepeatButton(); AutoplayButton(); RoutePicker().frame(width: 24, height: 24); VolumeControl().frame(width: 140) }.font(.title3)
                    if let e = p.error { Text(e).font(.caption).foregroundStyle(e.hasPrefix("via") ? Color.secondary : Color.red) }
                    Spacer(minLength: 0)
                }
                .padding(36).frame(minWidth: 460, maxWidth: 620)
                VStack(spacing: 0) {
                    Picker("", selection: $router.panel) {
                        Text("Lyrics").tag(PlayerPanel.lyrics); Text("Up Next").tag(PlayerPanel.queue)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.top, 30)
                    if router.panel == .queue { QueuePanel() } else { LyricsView() }
                }
                .frame(maxWidth: .infinity)
                .onAppear { if router.panel == .art { router.panel = .lyrics } }
            }
            .buttonStyle(.plain)
            #else
            VStack(spacing: 18) {
                Capsule().fill(.white.opacity(0.4)).frame(width: 40, height: 5).padding(.top, 8)
                    .onTapGesture { router.showFull = false }
                switch router.panel {
                case .art: Spacer(minLength: 0); artwork(maxSide: 360); Spacer(minLength: 0)
                case .lyrics: compactHeader; LyricsView()
                case .queue: compactHeader; QueuePanel()
                }
                if router.panel == .art { titleRow }
                SeekBar()
                controls
                VolumeControl().padding(.horizontal, 4)
                HStack {
                    Button { withAnimation(.spring) { router.panel = router.panel == .lyrics ? .art : .lyrics } } label: {
                        Image(systemName: router.panel == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                    }
                    Spacer()
                    RoutePicker().frame(width: 44, height: 44)
                    Spacer()
                    SleepTimerMenu()
                    Spacer()
                    Button { withAnimation(.spring) { router.panel = router.panel == .queue ? .art : .queue } } label: {
                        Image(systemName: router.panel == .queue ? "list.bullet.circle.fill" : "list.bullet")
                    }
                }
                .font(.title2).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 24).padding(.bottom, 6)
            }
            .padding(.horizontal, 26)
            .buttonStyle(.plain)
            .offset(y: dragY)
            .gesture(DragGesture().onChanged { dragY = max(0, $0.translation.height) }
                .onEnded { v in if v.translation.height > 140 || v.predictedEndTranslation.height > 400 { router.showFull = false }; withAnimation(.spring) { dragY = 0 } })
            #endif
        }
        .foregroundStyle(.white)
        #if os(iOS)
        .presentationBackground(.black)
        #endif
        .task(id: p.current?.art) { if let a = p.current?.art, let c = await ImageStore.shared.color(a) { withAnimation(.easeInOut(duration: 0.6)) { bg = c } } }
    }

    private var background: some View {
        ZStack {
            Color.black
            LinearGradient(colors: [bg.opacity(0.95), bg.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
            Art(url: p.current?.art, size: nil, radius: 0, square: false).scaleEffect(1.4).blur(radius: 90).opacity(0.5)
            Color.black.opacity(0.25)
        }.ignoresSafeArea()
    }

    private func artwork(maxSide: CGFloat) -> some View {
        Art(url: p.current?.art, size: nil, radius: 14)
            .frame(maxWidth: maxSide, maxHeight: maxSide)
            .scaleEffect(p.playing || p.loading ? 1 : 0.82)
            .shadow(color: .black.opacity(p.playing ? 0.55 : 0.3), radius: p.playing ? 30 : 14, y: 14)
            .animation(.spring(duration: 0.5, bounce: 0.3), value: p.playing)
            .contextMenu { if let t = p.current { TrackMenu(t: t) } }
            #if os(iOS)
            .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                if abs(v.translation.width) > abs(v.translation.height) { v.translation.width < 0 ? p.next() : p.prev() }
            })
            #endif
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            if let t = p.current { TrackLinks(t: t, titleFont: .title2.bold()) }
            Spacer()
            if let t = p.current {
                Button { lib.toggleLike(t) } label: { Image(systemName: lib.isLiked(t) ? "heart.fill" : "heart").font(.title2) }
                    .foregroundStyle(lib.isLiked(t) ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.85)))
                    .sensoryFeedback(.success, trigger: lib.isLiked(t))
                Menu { TrackMenu(t: t) } label: { Image(systemName: "ellipsis.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.85)) }
                    .menuIndicator(.hidden).fixedSize()
            }
        }
    }

    #if os(iOS)
    private var compactHeader: some View {
        HStack(spacing: 12) {
            Art(url: p.current?.art, size: 58, radius: 8)
            if let t = p.current { TrackLinks(t: t, titleFont: .headline) }
            Spacer()
            if let t = p.current {
                Button { lib.toggleLike(t) } label: { Image(systemName: lib.isLiked(t) ? "heart.fill" : "heart").font(.title3) }
                    .foregroundStyle(lib.isLiked(t) ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.85)))
            }
        }
    }
    #endif

    private var controls: some View {
        HStack {
            Spacer()
            Button { p.prev() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
            Spacer()
            PlayPauseButton(size: 64)
            Spacer()
            Button { p.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
            Spacer()
        }
        .overlay(alignment: .leading) {
            #if os(iOS)
            ShuffleButton().font(.title3)
            #endif
        }
        .overlay(alignment: .trailing) {
            #if os(iOS)
            RepeatButton().font(.title3)
            #endif
        }
    }
}

// MARK: - Lyrics

struct LyricsView: View {
    @Environment(Player.self) var p
    @State private var lyrics = Lyrics.shared
    var body: some View {
        Group {
            if lyrics.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if lyrics.missing {
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("Lyrics for this song aren't available."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let active = lyrics.synced ? lyrics.lines.lastIndex { ($0.time ?? 0) <= p.progress + 0.3 } : nil
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(lyrics.lines) { l in
                                Text(l.text.isEmpty ? "♪" : l.text)
                                    .font(.system(size: lyrics.synced ? 28 : 22, weight: .bold))
                                    .foregroundStyle(.white.opacity(!lyrics.synced || l.id == active ? 1 : 0.35))
                                    .blur(radius: lyrics.synced && active != nil && abs(l.id - (active ?? 0)) > 2 ? 0.6 : 0)
                                    .scaleEffect(l.id == active ? 1.02 : 1, anchor: .leading)
                                    .animation(.easeOut(duration: 0.3), value: active)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if let t = l.time { p.seek(t) } }
                                    .id(l.id)
                            }
                            Text("Lyrics from LRCLIB").font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                        }.padding(.vertical, 120).padding(.horizontal, 24)
                    }
                    .onChange(of: active) { if let a = active { withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(a, anchor: UnitPoint(x: 0, y: 0.35)) } } }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                }
            }
        }
        .task(id: p.current?.id) { await lyrics.load(p.current) }
    }
}

// MARK: - Queue

struct QueuePanel: View {
    @Environment(Player.self) var p
    @Environment(Router.self) var router
    var body: some View {
        List {
            if let t = p.current {
                Section {
                    QueueRow(t: t, now: true)
                } header: {
                    HStack {
                        Text(p.context.map { "Playing from \($0.title)" } ?? "Now Playing").lineLimit(1)
                        Spacer()
                        HStack(spacing: 16) { ShuffleButton(); RepeatButton(); AutoplayButton() }.font(.body)
                    }
                }
            }
            Section {
                ForEach(Array(p.upcoming.enumerated()), id: \.offset) { off, t in
                    let i = p.index + 1 + off
                    QueueRow(t: t).contentShape(Rectangle())
                        .onTapGesture { p.jump(to: i) }
                        .contextMenu { Button("Play Now") { p.jump(to: i) }; Button("Remove from Queue", role: .destructive) { p.remove(at: i) }; Divider(); TrackMenu(t: t) }
                        .listRowBackground(Color.clear)
                }
                .onMove { from, to in p.move(from: IndexSet(from.map { $0 + p.index + 1 }), to: to + p.index + 1) }
                .onDelete { s in s.map { $0 + p.index + 1 }.sorted(by: >).forEach { p.remove(at: $0) } }
            } header: {
                HStack {
                    Text("Up Next")
                    Spacer()
                    if !p.upcoming.isEmpty { Button("Clear") { p.clearUpcoming() }.buttonStyle(.borderless).foregroundStyle(.tint) }
                }
            } footer: {
                if p.upcoming.isEmpty { Text(p.autoplay ? "Autoplay will keep the music going with similar songs." : "Nothing queued.").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .overlay { if p.current == nil { ContentUnavailableView("Queue is Empty", systemImage: "list.bullet") } }
    }
}

struct QueueRow: View {
    let t: Track; var now = false
    @Environment(Player.self) var p
    var body: some View {
        HStack(spacing: 12) {
            Art(url: t.art, size: 40)
                .overlay { if now { Color.black.opacity(0.45).overlay { NowPlayingBars(playing: p.playing) }.clipShape(RoundedRectangle(cornerRadius: 4)) } }
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).lineLimit(1).foregroundStyle(now ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                Text(t.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = t.duration { Text(d.mmss).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Choose version (YouTube match)

struct VersionPicker: View {
    let t: Track
    @Environment(\.dismiss) var dismiss
    @Environment(Router.self) var router
    @State private var items: [Candidate] = []
    @State private var err: String?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items) { c in
                        Button {
                            Task { await AudioFix.choose(t, c); router.flash("Using “\(c.title)”"); dismiss() }
                        } label: {
                            HStack(spacing: 12) {
                                Art(url: "https://i.ytimg.com/vi/\(c.id)/mqdefault.jpg", size: 54, radius: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).lineLimit(2)
                                    Text([c.channel, c.duration.map { $0.mmss }, c.music ? "YouTube Music" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if c.current { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                else if c.score < 0 { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Different length") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                } header: {
                    Text("“\(t.title)” · \(t.artist)\(t.duration.map { " · " + $0.mmss } ?? "")")
                } footer: {
                    Text("Best match first. Your choice is remembered and synced to your other devices.")
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if let err { ContentUnavailableView("Couldn't search YouTube", systemImage: "exclamationmark.triangle", description: Text(err)) }
            }
            .navigationTitle("Choose Version")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                defer { loading = false }
                guard let p = PluginManager.shared.audio, p.has("candidates"), let arg = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) else {
                    err = "The audio plugin can't list versions"; return
                }
                do { items = try await p.call("candidates", [arg]) } catch { err = error.localizedDescription }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
    }
}
