// iTunes Search API: metadata + 30s preview audio. Also works as audio fallback for any
// metadata plugin (looks the track up by title + artist).
const map = r => ({ id: String(r.trackId), title: r.trackName, artist: r.artistName, album: r.collectionName,
  art: (r.artworkUrl100 || "").replace("100x100", "600x600"), duration: 30, extra: { preview: r.previewUrl } });
const find = async (q, n = 50) => (await (await fetch("https://itunes.apple.com/search?media=music&entity=song&limit=" + n + "&term=" + encodeURIComponent(q))).json()).results.filter(x => x.previewUrl);
const plugin = {
  name: "iTunes (previews)", version: "1.1", author: "spotube-lite", abilities: ["metadata", "audio"],
  async search(q) { return (await find(q)).map(map); },
  async home() { return this.search("top hits"); },
  async stream(t) {
    if (t.extra && t.extra.preview) return t.extra.preview;
    const r = (await find(t.title + " " + t.artist.split(",")[0], 5))[0];
    if (!r) throw new Error("No preview found");
    return r.previewUrl;
  },
};
