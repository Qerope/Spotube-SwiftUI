// Spotify metadata plugin (port of sonic-liberation/spotube-plugin-spotify, AGPL-3.0).
// Login: Spotify web login in a webview -> sp_dc cookie -> TOTP-signed web-player token -> GraphQL (pathfinder).
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const GQL = "https://api-partner.spotify.com/pathfinder/v2/query";
const NUANCES = "https://gist.githubusercontent.com/raw/22ed9c6ba463899e933427f7de1f0eef/nuances.json";
const Q = {
  searchTracks: "bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428",
  libraryV3: "390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455",
  fetchLibraryTracks: "087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240",
  fetchPlaylist: "cd2275433b29f7316176e7b5b5e098ae7744724e1a52d63549c76636b3257749",
  getAlbum: "b9bfabef66ed756e5e13f68a942deb60bd4125ec1f1be8cc42769dc0259b4b10",
};

function b32hex(s) {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"; let bits = "", hex = "";
  for (const c of s.toUpperCase().replace(/=+$/, "")) { const v = A.indexOf(c); if (v >= 0) bits += v.toString(2).padStart(5, "0"); }
  for (let i = 0; i + 8 <= bits.length; i += 8) hex += parseInt(bits.slice(i, i + 8), 2).toString(16).padStart(2, "0");
  return hex;
}
async function totp(secret) {
  const t = (await (await fetch("https://open.spotify.com/api/server-time", { headers: { "User-Agent": UA } })).json()).serverTime;
  const h = crypto.hmac("sha1", b32hex(secret), Math.floor(t / 30).toString(16).padStart(16, "0"));
  const o = parseInt(h.slice(-1), 16);
  return String((parseInt(h.substr(o * 2, 8), 16) & 0x7fffffff) % 1e6).padStart(6, "0");
}
async function token() {
  const c = JSON.parse(localStorage.getItem("tok") || "null");
  if (c && c.exp - Date.now() > 60000) return c.t;
  const dc = localStorage.getItem("sp_dc");
  if (!dc) throw new Error("Not logged in. Plugins → Spotify → Log in");
  for (const bust of [false, true]) {
    const ns = await (await fetch(NUANCES + (bust ? "?t=" + Date.now() : ""))).json();
    const n = ns.reduce((a, b) => (b.v > a.v ? b : a));
    const otp = await totp(n.s);
    const r = await fetch(`https://open.spotify.com/api/token?reason=transport&productType=web-player&totp=${otp}&totpServer=${otp}&totpVer=${n.v}`,
      { headers: { "User-Agent": UA, Cookie: "sp_dc=" + dc } });
    if (r.ok) {
      const j = await r.json();
      localStorage.setItem("tok", JSON.stringify({ t: j.accessToken, exp: j.accessTokenExpirationTimestampMs }));
      return j.accessToken;
    }
  }
  throw new Error("Spotify token request failed (sp_dc expired? log in again)");
}
async function gql(op, variables) {
  const r = await fetch(GQL, {
    method: "POST",
    headers: { Authorization: "Bearer " + await token(), "Content-Type": "application/json", Accept: "application/json",
      "app-platform": "WebPlayer", "User-Agent": UA, Cookie: "sp_dc=" + localStorage.getItem("sp_dc") },
    body: JSON.stringify({ variables, operationName: op, extensions: { persistedQuery: { version: 1, sha256Hash: Q[op] } } }),
  });
  if (!r.ok) throw new Error(`Spotify ${op} failed: ${r.status}`);
  return r.json();
}
// Collect every object whose uri starts with `pre` (robust to GraphQL wrapper shapes).
function walk(x, pre, out = [], seen = new Set()) {
  if (Array.isArray(x)) x.forEach(y => walk(y, pre, out, seen));
  else if (x && typeof x === "object") {
    if (typeof x.uri === "string" && x.uri.startsWith(pre) && x.name) { if (!seen.has(x.uri)) { seen.add(x.uri); out.push(x); } return out; }
    for (const k in x) walk(x[k], pre, out, seen);
  }
  return out;
}
const art = o => { const s = (o && (o.coverArt?.sources || o.images?.items?.[0]?.sources)) || []; return [...s].sort((a, b) => (b.width || 0) - (a.width || 0))[0]?.url; };
const track = (d, album) => ({
  id: d.uri.split(":")[2], title: d.name,
  artist: (d.artists?.items || []).map(a => a.profile?.name).filter(Boolean).join(", "),
  album: d.albumOfTrack?.name || album?.name, art: art(d.albumOfTrack) || art(album),
  duration: ((d.duration || d.trackDuration)?.totalMilliseconds || 0) / 1000,
  extra: { uri: d.uri },
});
async function paged(op, vars, limit, album, max = 1000) {
  const out = [];
  for (let offset = 0; offset < max; offset += limit) {
    const page = walk(await gql(op, { ...vars, offset, limit }), "spotify:track:");
    out.push(...page.map(d => track(d, album)));
    if (page.length < limit) break;
  }
  return out;
}

const plugin = {
  name: "Spotify", version: "1.0.0", author: "spotube-lite (port of Sonic Liberation)", abilities: ["metadata", "authentication"],
  async login() {
    const v = await webview.cookie("https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F", "sp_dc");
    localStorage.setItem("sp_dc", v); localStorage.removeItem("tok");
    await token(); return "ok";
  },
  async logout() { localStorage.removeItem("sp_dc"); localStorage.removeItem("tok"); return "ok"; },
  async search(q) {
    const r = await gql("searchTracks", { searchTerm: q, offset: 0, limit: 50, numberOfTopResults: 20, includeAudiobooks: false, includePreReleases: false, includeAuthors: false });
    return walk(r, "spotify:track:").map(d => track(d));
  },
  async home() { return (await paged("fetchLibraryTracks", {}, 50, null, 100)); },
  async library() {
    const r = await gql("libraryV3", { filters: ["Playlists"], order: null, textFilter: "", features: [], limit: 50, offset: 0, flatten: true, expandedFolders: [], folderUri: null, includeFoldersWhenFlattening: true });
    return [{ id: "liked", title: "Liked Songs" },
      ...walk(r, "spotify:playlist:").map(p => ({ id: p.uri, title: p.name, subtitle: p.ownerV2?.data?.name, art: art(p) }))];
  },
  async collection(id) {
    if (id === "liked") return paged("fetchLibraryTracks", {}, 50);
    if (id.startsWith("spotify:album:")) return paged("getAlbum", { uri: id, locale: "" }, 50, null, 500);
    return paged("fetchPlaylist", { uri: id, enableWatchFeedEntrypoint: false }, 100);
  },
};
