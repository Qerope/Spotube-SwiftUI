# Spotube Lite (SwiftUI)
Minimal native **macOS** (and iOS) client inspired by [Spotube](https://github.com/KRTirtho/spotube): pure-black OLED UI,
JavaScript plugins (JavaScriptCore), Spotify metadata + YouTube audio, just like Spotube 6's default setup.

Build: `brew install xcodegen && xcodegen && open SpotubeLite.xcodeproj` (scheme *SpotubeLite*, destination *My Mac*).

## Bundled plugins (`Plugins/`)
| Plugin | Abilities | Notes |
|---|---|---|
| `spotify.js` | metadata, authentication | Port of [spotube-plugin-spotify](https://github.com/sonic-liberation/spotube-plugin-spotify) (AGPL-3.0). Plugins → Spotify → **Log in** (web login → `sp_dc` → TOTP token → GraphQL). Search, Liked Songs, your playlists. |
| `youtube.js` | audio | InnerTube search, match by duration/"Topic" channel. On macOS the audio is fetched by **yt-dlp** (decodes YouTube's signature/`n` param like NewPipeExtractor; needs `brew install yt-dlp deno`, done by `install-latest.sh`), cached in `~/Library/Caches/audio`, next track pre-fetched. Direct InnerTube streams are only a fallback (YouTube caps them at ~1 MB without a poToken). |
| `itunes.js` | metadata, audio | 30 s previews; automatic audio fallback when YouTube fails. |

## Features
- **Home**: handoff ("Playing on MacBook Pro → Play Here"), Recently Played across devices, Made for You mixes (Favorites, Replay, Rediscover, artist stations), Top Songs, your playlists / albums / top artists.
- **Search**: live as you type, top result, songs / artists / albums / playlists / your library scopes, recent searches (synced).
- **Library**: Playlists (yours + Spotify), Artists, Albums, Favorite Songs, Downloaded, Recently Played; sort + filter everywhere. Create / rename / reorder / delete playlists, drag songs onto sidebar playlists (Mac).
- **Pages**: album (year, label, more by artist), playlist (description, saves), artist (header, monthly listeners, top songs, albums / singles / appears on, fans also like, bio). Add to Library, download all, share.
- **Songs**: love, play next / last, add to playlist, download, start station, go to artist / album, share, *Choose Version* (pick the YouTube upload), *Wrong Song* (blocklist and rematch). Swipe actions on iPhone.
- **Player**: Apple Music-style Now Playing with artwork colours, synced lyrics (LRCLIB, tap a line to seek), Up Next (reorder / remove / clear), shuffle / repeat / autoplay radio, sleep timer, AirPlay, lock screen / CarPlay Now Playing / AirPods controls (incl. Love), skips unplayable songs, pauses when headphones are removed.
- **Offline**: downloads + an LRU cache of everything you play; pages you opened load offline.
- **Replay**: minutes, plays, top songs / artists / albums, listening by day / hour / device.
- Mac: sidebar, bottom player, menu-bar player, Space = play/pause, ⌘←/→, ⌘L love, ⌘F search, ⌘U up next.

## Server (`Server/`)
FastAPI + SQLite + yt-dlp in Docker at `https://qerope.me/spotube` (deploy: `Server/deploy.sh`).
- Syncs favourites, playlists, saved albums/artists, the Spotify login and YouTube matches between devices (last writer wins), plus device state for handoff.
- Records every listen (device, duration, skipped, context) and searches in `/opt/spotube/data/db/spotube.db` for stats.
- Streams audio when a device can't run yt-dlp (iPhone): cache that fills the free disk (keeps 2 GB free, drops the longest-unplayed songs first), served by nginx with Range support.
- YouTube blocks many datacenter IPs. The Mac app therefore acts as a helper: it uploads every song it plays, and fetches songs on request. Alternatives: set `YTDLP_PROXY` (e.g. Cloudflare WARP) in `docker-compose.yml`, or drop a `cookies.txt` into `/opt/spotube/data/`.
- Connecting a device: `Config/server.json` (`{"url","token"}`, gitignored) is bundled into local builds; release builds never contain it. Pair other devices with the QR code in Settings → Server → Connect Another Device.

## Player
Shuffle, repeat (off / all / one), autoplay (continues with the artist's popular songs when the queue ends),
queue panel (reorder, remove, play next / add to queue), volume, seek, menu-bar player, media keys and Now Playing.
Tracks are resolved once and cached; the next two and previous track are pre-fetched, so skipping is instant.
Queue, position and modes are restored on launch.

## Plugin API
A plugin is one `.js` file defining `const plugin = { name, version, author, abilities, ... }`. Install via URL or file in the Plugins page.
- **metadata**: `radio(track)` (optional, autoplay) → tracks, `search(q)`, `searchAll(q)` → `{artists, tracks}`, `home()`, `library()` → `[{id,title,subtitle?,art?}]`, `collection(id)` → tracks, `artist(id)` → `{name, art, tracks, albums}`
- **audio**: `stream(track)` → playable URL, or `{url, headers?, key?}` (`key` = cache key); optional `matched`, `candidates`, `choose`, `rematch`
- **authentication**: `login()`, `logout()`
- Track: `{id,title,artist,album?,art?,duration?(s),extra?:{string:string}}`
- Host globals: `fetch(url,{method,headers,body})`, `localStorage`, `crypto.hmac(algo,keyHex,dataHex)`, `webview.cookie(url,name)`, `ytdlp.audio(youtubeUrl)` → cached file URL (macOS), `server.available()` / `server.audio(videoId)` → `{url, key}`

Spotube 6's own `.smplug` plugins are Kotlin/Zipline (QuickJS bytecode) and can't be loaded directly; the bundled JS ports cover the same features.

## Release & install
- `./release.sh [x.y.z] [-m "msg"]`: commit, push, build the macOS `.app` (zip) and unsigned iOS `.ipa`, publish a GitHub release.
- `./install-latest.sh [--force] [vX.Y.Z]`: `git pull`, download both assets, install the Mac app into `/Applications` with quarantine removed, put the `.ipa` in `~/Downloads`.
- App icon is generated by `swift scripts/make-icon.swift Sources/Assets.xcassets/AppIcon.appiconset`.
