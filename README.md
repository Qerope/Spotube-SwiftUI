# Spotube Lite (SwiftUI)
Minimal native **macOS** (and iOS) client inspired by [Spotube](https://github.com/KRTirtho/spotube): pure-black OLED UI,
JavaScript plugins (JavaScriptCore), Spotify metadata + YouTube audio, just like Spotube 6's default setup.

Build: `brew install xcodegen && xcodegen && open SpotubeLite.xcodeproj` (scheme *SpotubeLite*, destination *My Mac*).

## Bundled plugins (`Plugins/`)
| Plugin | Abilities | Notes |
|---|---|---|
| `spotify.js` | metadata, authentication | Port of [spotube-plugin-spotify](https://github.com/sonic-liberation/spotube-plugin-spotify) (AGPL-3.0). Plugins → Spotify → **Log in** (web login → `sp_dc` → TOTP token → GraphQL). Search, Liked Songs, your playlists. |
| `youtube.js` | audio | NewPipe-style InnerTube search + match by duration/"Topic" channel → m4a stream. YouTube may answer "Sign in to confirm you're not a bot" on some networks. |
| `itunes.js` | metadata, audio | 30 s previews; automatic audio fallback when YouTube fails. |

## Plugin API
A plugin is one `.js` file defining `const plugin = { name, version, author, abilities, ... }`. Install via URL or file in the Plugins page.
- **metadata**: `search(q)`, `home()`, `library()` → `[{id,title,subtitle?,art?}]`, `collection(id)` → tracks
- **audio**: `stream(track)` → playable URL (m4a/mp3/HLS)
- **authentication**: `login()`, `logout()`
- Track: `{id,title,artist,album?,art?,duration?(s),extra?:{string:string}}`
- Host globals: `fetch(url,{method,headers,body})`, `localStorage`, `crypto.hmac(algo,keyHex,dataHex)`, `webview.cookie(url,name)`

Spotube 6's own `.smplug` plugins are Kotlin/Zipline (QuickJS bytecode) and can't be loaded directly; the bundled JS ports cover the same features.
