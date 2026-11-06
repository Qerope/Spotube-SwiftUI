// Sample plugin: iTunes Search API metadata + 30s preview audio.
// Plugin API: const plugin = { name, version, author, abilities: ["metadata"|"audio"], search(q), home(), stream(track) }
// Globals: fetch(url,{method,headers,body}) -> {status,ok,text(),json()}, localStorage.getItem/setItem
const map = r => ({ id: String(r.trackId), title: r.trackName, artist: r.artistName, album: r.collectionName,
  art: (r.artworkUrl100 || "").replace("100x100", "600x600"), duration: 30, extra: { preview: r.previewUrl } });
const plugin = {
  name: "iTunes (previews)", version: "1.0", author: "spotube-lite", abilities: ["metadata", "audio"],
  async search(q) {
    const r = await fetch("https://itunes.apple.com/search?media=music&entity=song&limit=50&term=" + encodeURIComponent(q));
    return (await r.json()).results.filter(x => x.previewUrl).map(map);
  },
  async home() { return this.search(localStorage.getItem("lastHome") || "top hits"); },
  async stream(t) { return t.extra.preview; },
};
