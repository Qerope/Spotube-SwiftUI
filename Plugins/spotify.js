// Spotify metadata plugin (port of sonic-liberation/spotube-plugin-spotify, AGPL-3.0).
// Login: Spotify web login in a webview -> sp_dc cookie -> TOTP-signed web-player token -> GraphQL (pathfinder).
const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const GQL = "https://api-partner.spotify.com/pathfinder/v2/query";
const NUANCES = "https://gist.githubusercontent.com/raw/22ed9c6ba463899e933427f7de1f0eef/nuances.json";
const Q = {
  searchArtists: "0e6f9020a66fe15b93b3bb5c7e6484d1d8cb3775963996eaede72bac4d97e909",
  searchDesktop: "d9f785900f0710b31c07818d617f4f7600c1e21217e80f5b043d1e78d74e6026",
  queryArtistDiscographyAll: "5e07d323febb57b4a56a42abbf781490e58764aa45feb6e3dc0591564fc56599",
  queryArtistOverview: "7f86ff63e38c24973a2842b672abe44c910c1973978dc8a4a0cb648edef34527",
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
  const body = await r.text();
  if (r.status === 401) localStorage.removeItem("tok");
  if (!r.ok) throw new Error(`Spotify ${op}: HTTP ${r.status} ${body.slice(0, 120)}`);
  const j = JSON.parse(body);
  if (j.errors && j.errors.length && !j.data) throw new Error(`Spotify ${op}: ${j.errors.map(e => e.message).join("; ")}`);
  return j;
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
  extra: Object.fromEntries(Object.entries({ uri: d.uri, albumUri: d.albumOfTrack?.uri || album?.uri,
    artistUri: d.artists?.items?.[0]?.uri }).filter(([, v]) => v)),
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
  // Home: Liked Songs; if Spotify rejects that query, fall back to your first playlist.
  // Artists first, then songs.
  async searchAll(q) {
    const vars = { searchTerm: q, offset: 0, limit: 10, numberOfTopResults: 10, includeAudiobooks: false, includePreReleases: false, includeAuthors: false };
    const [ar, tracks] = await Promise.all([gql("searchArtists", vars).catch(e => ({ error: String(e.message || e) })), this.search(q)]);
    const artists = [], seen = new Set();
    (function find(x) {
      if (Array.isArray(x)) return x.forEach(find);
      if (!x || typeof x !== "object") return;
      if (typeof x.uri === "string" && x.uri.startsWith("spotify:artist:") && x.profile?.name) {
        if (!seen.has(x.uri)) { seen.add(x.uri); artists.push({ id: x.uri, title: x.profile.name, subtitle: "Artist",
          art: [...(x.visuals?.avatarImage?.sources || [])].sort((a, b) => (b.width || 0) - (a.width || 0))[0]?.url }); }
        return;
      }
      for (const k in x) find(x[k]);
    })(ar.data);
    return { artists, tracks, error: ar.error };
  },
  // Artist page: top tracks + full discography (albums, singles, compilations), newest first.
  async artist(id) {
    const [o, albums] = await Promise.all([
      gql("queryArtistOverview", { uri: id, locale: "", preReleaseV2: false }),
      (async () => {
        const out = [];
        for (let offset = 0; offset < 300; offset += 50) {
          const page = walk((await gql("queryArtistDiscographyAll", { uri: id, offset, limit: 50, order: "DATE_DESC" })).data, "spotify:album:");
          out.push(...page);
          if (page.length < 50) break;
        }
        return out;
      })().catch(() => []),
    ]);
    const a = o.data?.artistUnion || {}, disc = a.discography || {};
    const cap = x => x ? x[0] + x.slice(1).toLowerCase() : null;
    const rel = albums.length ? albums : walk([disc.popularReleasesAlbums, disc.albums, disc.singles, disc.compilations], "spotify:album:");
    return {
      name: a.profile?.name || "",
      art: (a.visuals?.avatarImage?.sources || []).sort((x, y) => (y.width || 0) - (x.width || 0))[0]?.url,
      tracks: walk(disc.topTracks || {}, "spotify:track:").map(d => track(d)),
      albums: rel.map(x => ({ id: x.uri, title: x.name, subtitle: [cap(x.type), x.date?.year].filter(Boolean).join(" · "), art: art(x) })),
    };
  },
  async home() {
    const errs = [];
    try { const t = await paged("fetchLibraryTracks", {}, 50, null, 100); if (t.length) return t; } catch (e) { errs.push(String(e.message || e)); }
    for (const p of (await this.library()).slice(1, 4)) {
      try { const t = await this.collection(p.id); if (t.length) return t; } catch (e) { errs.push(String(e.message || e)); }
    }
    throw new Error(errs.join(" | ") || "Your library is empty");
  },
  async library() {
    const r = await gql("libraryV3", { filters: ["Playlists"], order: null, textFilter: "", features: [], limit: 50, offset: 0, flatten: true, expandedFolders: [], folderUri: null, includeFoldersWhenFlattening: true });
    return [{ id: "liked", title: "Liked Songs" },
      ...walk(r, "spotify:playlist:").map(p => ({ id: p.uri, title: p.name, subtitle: p.ownerV2?.data?.name, art: art(p) }))];
  },
  async collection(id) {
    if (id === "liked") return paged("fetchLibraryTracks", {}, 50);
    if (id.startsWith("spotify:artist:")) return (await this.artist(id)).tracks;
    if (id.startsWith("spotify:album:")) {
      const out = []; let album = null;
      for (let offset = 0; offset < 500; offset += 50) {
        const u = (await gql("getAlbum", { uri: id, locale: "", offset, limit: 50 })).data?.albumUnion || {};
        album = album || u;
        const page = walk(u.tracksV2 || u.tracks || {}, "spotify:track:");
        out.push(...page.map(d => track(d, album)));
        if (page.length < 50) break;
      }
      return out;
    }
    return paged("fetchPlaylist", { uri: id, enableWatchFeedEntrypoint: false }, 100);
  },
};
