# Spotube Lite (SwiftUI)
Minimal native iOS clone of Spotube, pure-black OLED UI, JS plugins (JavaScriptCore).
Build: `brew install xcodegen && xcodegen && open SpotubeLite.xcodeproj`

## Plugins
One `.js` file defining `const plugin = {...}`; install from URL or Files in the Plugins tab.
- `abilities`: `"metadata"` → `search(q)`, optional `home()` returning `[{id,title,artist,album?,art?,duration?,extra?}]`
- `"audio"` → `stream(track)` returning a playable URL
- Globals: `fetch`, `localStorage`. See `Plugins/itunes.js`.
