import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Cloud.self) var cloud
    @Environment(Player.self) var player
    @Environment(Downloads.self) var dl
    @Environment(PluginManager.self) var pm
    @Environment(Library.self) var lib
    @AppStorage("accent") private var accent = Theme.defaultAccent
    @AppStorage("prefetchCellular") private var prefetchCellular = false
    @AppStorage("liveActivity") private var liveActivity = true
    @State private var cacheSize = AudioCache.size
    @State private var cacheLimit = AudioCache.limitMB
    @State private var url = ""
    @State private var token = ""
    @State private var showToken = false
    @State private var confirmClear = false
    @State private var spotifyIn = false

    var body: some View {
        @Bindable var cloud = cloud
        @Bindable var player = player
        @Bindable var dl = dl
        Form {
            Section("Spotify") {
                LabeledContent("Account", value: spotifyIn ? "Logged in" : "Not logged in")
                if let p = pm.plugins.first(where: { $0.has("login") }) {
                    if spotifyIn {
                        Button("Log Out", role: .destructive) { run(p, "logout") }
                    } else {
                        Button("Log In to Spotify") { run(p, "login") }
                    }
                }
                Text("Your login syncs to all your devices through your server, so you only log in once.").font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") { HStack(spacing: 6) { SyncBadge(); Text(statusText).foregroundStyle(.secondary) } }
                TextField("Server URL", text: $url).textContentType(.URL).autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                HStack {
                    if showToken { TextField("Token", text: $token).autocorrectionDisabled() } else { SecureField("Token", text: $token) }
                    Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                }
                if url != cloud.url || token != cloud.token { Button("Save & Connect") { cloud.url = url; cloud.token = token } }
                if let c = cloud.cacheInfo {
                    LabeledContent("Server music cache", value: "\(c.files) songs · \(c.bytes.bytes) of \(c.limit.bytes)")
                    LabeledContent("Server disk free", value: c.diskFree.bytes)
                }
                if let d = cloud.lastSync { LabeledContent("Last sync", value: d.formatted(.relative(presentation: .named))) }
                Button("Sync Now") { Task { await cloud.hello(); await cloud.syncNow() } }.disabled(!cloud.enabled)
                Button("Re-download Everything from Server") { Task { await cloud.resync() } }.disabled(!cloud.enabled)
                if cloud.enabled { PairCode(url: cloud.url, token: cloud.token) }
                #if os(macOS)
                Toggle("Fetch songs for my other devices", isOn: $cloud.helper)
                Text("When YouTube blocks the server, it asks this Mac to fetch the song with yt-dlp and upload it. Songs you play here are shared with the server cache too.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            } header: { Text("Server") } footer: {
                Text("Syncs your favorites, playlists, library, Spotify login, song matches and listening history, and streams music when it isn't cached on this device.")
            }

            if !cloud.devices.isEmpty {
                Section("Devices") {
                    ForEach(cloud.devices) { d in
                        HStack {
                            Image(systemName: d.icon).frame(width: 24)
                            VStack(alignment: .leading) {
                                Text(d.name ?? d.id) + Text(d.id == cloud.deviceID ? "  (this device)" : "").foregroundStyle(.secondary)
                                if let s = d.state, let t = s.current { Text("\(s.playing ? "Playing" : "Paused"): \(t.title) — \(t.artist)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if let l = d.lastSeen { Text(Date(timeIntervalSince1970: Double(l) / 1000).formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary) }
                            if d.id != cloud.deviceID, d.state?.current != nil { Button("Play Here") { player.takeOver(d) }.buttonStyle(.borderless) }
                        }
                    }
                }
            }

            Section("Playback") {
                Toggle("Crossfade", isOn: Binding(get: { player.crossfade > 0 }, set: { player.crossfade = $0 ? 6 : 0 }))
                if player.crossfade > 0 {
                    LabeledContent {
                        HStack {
                            Slider(value: $player.crossfade, in: 1...12, step: 1)
                            Text("\(Int(player.crossfade)) s").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        }
                    } label: { Text("Duration") }
                }
                Toggle("Autoplay similar songs when the queue ends", isOn: $player.autoplay)
                #if os(iOS)
                Toggle("Live Activity on Lock Screen", isOn: $liveActivity)
                    .onChange(of: liveActivity) { if !liveActivity { NowPlayingSurface.shared.endNow() } else { player.nowPlaying() } }
                #endif
                Toggle("Pre-load next songs on cellular", isOn: $prefetchCellular)
                Toggle("Download only on Wi-Fi", isOn: $dl.wifiOnly)
            }

            Section("Storage") {
                LabeledContent("Downloaded", value: "\(dl.items.count) songs · \(dl.totalBytes.bytes)")
                LabeledContent("Cached songs", value: cacheSize.bytes)
                Picker("Cache limit", selection: $cacheLimit) {
                    ForEach([500, 1000, 2048, 5000, 10000], id: \.self) { Text($0 >= 1000 ? "\($0 / 1000) GB" : "\($0) MB").tag($0) }
                }.onChange(of: cacheLimit) { AudioCache.limitMB = cacheLimit; cacheSize = AudioCache.size }
                Button("Clear Cache", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear cached songs?", isPresented: $confirmClear) {
                        Button("Clear Cache", role: .destructive) { AudioCache.clear(); cacheSize = AudioCache.size }
                    } message: { Text("Downloads are kept. Cached songs will stream again next time.") }
            }

            Section("Appearance") {
                Picker("Accent color", selection: $accent) {
                    ForEach(Theme.accents, id: \.0) { a in Label { Text(a.0) } icon: { Circle().fill(a.1).frame(width: 12, height: 12) }.tag(a.0) }
                }
            }

            PluginsSection()

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                LabeledContent("Device", value: cloud.deviceName)
                Link("Lyrics by LRCLIB", destination: URL(string: "https://lrclib.net")!)
                Link("Source code", destination: URL(string: "https://github.com/Qerope/Spotube-SwiftUI")!)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).background(.black)
        .navigationTitle("Settings")
        .onAppear { url = cloud.url; token = cloud.token; cacheSize = AudioCache.size }
        .task(id: pm.revision) {
            if let p = pm.plugins.first(where: { $0.has("loggedIn") }) { spotifyIn = (try? await p.call("loggedIn")) ?? false }
        }
    }

    private var statusText: String {
        switch cloud.status {
        case .online: cloud.pending > 0 ? "Online · \(cloud.pending) pending" : "Online"
        case .connecting: "Connecting…"
        case .offline(let e): "Offline: \(e)"
        case .off: "Not configured"
        }
    }
    private func run(_ p: JSPlugin, _ fn: String) {
        Task {
            let _: String? = try? await p.call(fn, timeout: 900)
            pm.revision += 1
            if fn == "logout" { lib.clearSpotify() } else { await lib.refreshSpotify() }
        }
    }
}

struct PluginsSection: View {
    @Environment(PluginManager.self) var pm
    @State private var url = ""
    @State private var importing = false
    @State private var msg: String?
    var body: some View {
        @Bindable var pm = pm
        Section {
            Picker("Metadata", selection: Binding($pm.metadataID, replacingNilWith: pm.metadata?.id ?? "")) {
                ForEach(pm.plugins.filter { $0.abilities.contains("metadata") }) { Text($0.name).tag($0.id) }
            }
            Picker("Audio source", selection: Binding($pm.audioID, replacingNilWith: pm.audio?.id ?? "")) {
                ForEach(pm.plugins.filter { $0.abilities.contains("audio") }) { Text($0.name).tag($0.id) }
            }
            ForEach(pm.plugins) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text("v\(p.version) · \(p.abilities.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { pm.remove(p) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Install from URL (https://…/plugin.js)", text: $url).autocorrectionDisabled()
                Button("Install") { Task { await install(URL(string: url)) } }.disabled(URL(string: url)?.scheme == nil)
            }
            Button("Install from File…") { importing = true }
            if let msg { Text(msg).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Plugins") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText]) { r in Task { await install(try? r.get()) } }
    }
    private func install(_ u: URL?) async {
        guard let u else { return }
        do { try await pm.install(from: u); msg = "Installed"; url = "" } catch { msg = error.localizedDescription }
    }
}

extension Binding where Value == String {
    init(_ b: Binding<String?>, replacingNilWith d: String) { self.init(get: { b.wrappedValue ?? d }, set: { b.wrappedValue = $0 }) }
}

import CoreImage.CIFilterBuiltins

/// QR code another device scans with its camera to connect to the same server (spotubelite://pair?…).
struct PairCode: View {
    let url: String; let token: String
    @State private var show = false
    var body: some View {
        DisclosureGroup("Connect Another Device", isExpanded: $show) {
            if let img = qr {
                HStack(spacing: 16) {
                    Image(decorative: img, scale: 1).interpolation(.none).resizable().frame(width: 160, height: 160)
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                    Text("Scan with your iPhone's Camera to connect it to your server: favorites, playlists, Spotify login and history sync instantly. The code contains your server token, so keep it private.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        }
    }
    private var qr: CGImage? {
        var c = URLComponents(); c.scheme = "spotubelite"; c.host = "pair"
        c.queryItems = [.init(name: "url", value: url), .init(name: "token", value: token)]
        let f = CIFilter.qrCodeGenerator(); f.message = Data((c.url?.absoluteString ?? "").utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
