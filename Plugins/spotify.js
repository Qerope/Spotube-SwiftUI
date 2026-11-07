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
const nameOf = x => x.name || x.profile?.name;
// Handles `{ _uri, data }` wrappers (Liked Songs) and remembers the nearest `addedAt` (for "date added" sorting).
function walk(x, pre, out = [], seen = new Set(), added) {
  if (Array.isArray(x)) x.forEach(y => walk(y, pre, out, seen, added));
  else if (x && typeof x === "object") {
    if (x.addedAt?.isoString) added = x.addedAt.isoString;
    if (typeof x._uri === "string" && x.data && typeof x.data === "object" && !x.data.uri) x = { ...x, data: { ...x.data, uri: x._uri } };
    if (typeof x.uri === "string" && x.uri.startsWith(pre) && nameOf(x)) {
      if (!seen.has(x.uri)) { seen.add(x.uri); out.push(added ? { ...x, __added: added } : x); }
      return out;
    }
    for (const k in x) walk(x[k], pre, out, seen, added);
  }
  return out;
}
const best = s => [...(s || [])].sort((a, b) => (b.width || b.maxWidth || 0) - (a.width || a.maxWidth || 0))[0]?.url;
const art = o => best(o && (o.coverArt?.sources || o.images?.items?.[0]?.sources || o.visuals?.avatarImage?.sources || o.avatarImage?.sources));
const color = o => o?.coverArt?.extractedColors?.colorDark?.hex || o?.images?.items?.[0]?.extractedColors?.colorDark?.hex
  || o?.visuals?.avatarImage?.extractedColors?.colorDark?.hex;
const cap = x => x ? x[0] + x.slice(1).toLowerCase() : null;
const names = a => (a?.items || []).map(x => x.profile?.name).filter(Boolean).join(", ");
const track = (d, album) => ({
  id: d.uri.split(":")[2], title: d.name,
  artist: names(d.artists),
  album: d.albumOfTrack?.name || album?.name, art: art(d.albumOfTrack) || art(album),
  duration: ((d.duration || d.trackDuration)?.totalMilliseconds || 0) / 1000,
  extra: Object.fromEntries(Object.entries({ uri: d.uri, albumUri: d.albumOfTrack?.uri || album?.uri,
    artistUri: d.artists?.items?.[0]?.uri, artistUris: (d.artists?.items || []).map(a => a.uri).filter(Boolean).join(","),
    explicit: d.contentRating?.label === "EXPLICIT" ? "1" : undefined,
    trackNumber: d.trackNumber ? String(d.trackNumber) : undefined, disc: d.discNumber ? String(d.discNumber) : undefined,
    plays: d.playcount ? String(d.playcount) : undefined, addedAt: d.__added }).filter(([, v]) => v)),
});
const albumC = x => ({ id: x.uri, title: x.name, kind: (x.type || "album").toLowerCase(), art: art(x), color: color(x),
  subtitle: [cap(x.type) || "Album", names(x.artists), x.date?.year].filter(Boolean).join(" · ") });
const artistC = x => ({ id: x.uri, title: nameOf(x), subtitle: "Artist", kind: "artist", art: art(x) });
const playlistC = p => ({ id: p.uri, title: p.name, kind: "playlist", subtitle: p.ownerV2?.data?.name ? "Playlist · " + p.ownerV2.data.name : "Playlist",
  art: art(p), color: color(p) });
async function paged(op, vars, limit, album, max = 1000) {
  const out = [];
  for (let offset = 0; offset < max; offset += limit) {
    const page = walk(await gql(op, { ...vars, offset, limit }), "spotify:track:");
    out.push(...page.map(d => track(d, album)));
    if (page.length < limit) break;
  }
  return out;
}
async function libraryOf(filter, pre, map) {
  const out = [];
  for (let offset = 0; offset < 1000; offset += 50) {
    const r = await gql("libraryV3", { filters: [filter], order: null, textFilter: "", features: [], limit: 50, offset, flatten: true,
      expandedFolders: [], folderUri: null, includeFoldersWhenFlattening: true });
    const page = walk(r.data?.me?.libraryV3?.items || r, pre);
    out.push(...page.map(map));
    if (page.length < 50) break;
  }
  return out;
}
const searchVars = (q, limit) => ({ searchTerm: q, offset: 0, limit, numberOfTopResults: 10, includeAudiobooks: false, includePreReleases: false,
  includeLocalConcertsField: false, includeArtistHasConcertsField: false, includeAuthors: false });

const plugin = {
  name: "Spotify", version: "2.1.0", author: "spotube-lite (port of Sonic Liberation)", abilities: ["metadata", "authentication"],
  async login() {
    const v = await webview.cookie("https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F", "sp_dc");
    localStorage.setItem("sp_dc", v); localStorage.removeItem("tok");
    await token(); return "ok";
  },
  async logout() { localStorage.removeItem("sp_dc"); localStorage.removeItem("tok"); return "ok"; },
  async loggedIn() { return !!localStorage.getItem("sp_dc"); },
  async search(q) {
    const r = await gql("searchTracks", { ...searchVars(q, 50), numberOfTopResults: 20 });
    return walk(r, "spotify:track:").map(d => track(d));
  },
  // Everything at once: top result, songs, artists, albums, playlists.
  async searchAll(q) {
    try {
      const d = (await gql("searchDesktop", searchVars(q, 20))).data?.searchV2 || {};
      const top = walk(d.topResultsV2, "spotify:")[0];
      return {
        top: top ? { id: top.uri, type: top.uri.split(":")[1] } : null,
        tracks: walk(d.tracksV2, "spotify:track:").map(x => track(x)),
        artists: walk(d.artists, "spotify:artist:").map(artistC),
        albums: walk(d.albumsV2, "spotify:album:").map(albumC),
        playlists: walk(d.playlists, "spotify:playlist:").map(playlistC),
      };
    } catch (e) {
      const [ar, tracks] = await Promise.all([gql("searchArtists", searchVars(q, 10)).catch(e => ({ error: String(e.message || e) })), this.search(q)]);
      return { artists: walk(ar.data || {}, "spotify:artist:").map(artistC), tracks, albums: [], playlists: [], error: ar.error };
    }
  },
  // Artist page: top tracks, discography by type, related artists, bio and stats.
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
    const rel = albums.length ? albums : walk([disc.popularReleasesAlbums, disc.albums, disc.singles, disc.compilations], "spotify:album:");
    return {
      name: a.profile?.name || "",
      art: best(a.visuals?.avatarImage?.sources),
      header: best(a.headerImage?.data?.sources || a.visuals?.headerImage?.sources),
      color: color(a),
      bio: (a.profile?.biography?.text || "").replace(/<[^>]+>/g, ""),
      monthlyListeners: a.stats?.monthlyListeners || 0, followers: a.stats?.followers || 0,
      topCities: (a.stats?.topCities?.items || []).map(c => `${c.city}, ${c.country}`),
      tracks: walk(disc.topTracks || {}, "spotify:track:").map(d => track(d)),
      albums: rel.map(albumC),
      related: walk(a.relatedContent?.relatedArtists || {}, "spotify:artist:").map(artistC),
      appearsOn: walk(a.relatedContent?.appearsOn || {}, "spotify:album:").map(albumC),
    };
  },
  // Discovery: the newest releases of these artists ([{id, name}], one light request each), newest first.
  async releases(artists, days = 120) {
    const since = Date.now() - days * 864e5, out = [], seen = new Set();
    for (let i = 0; i < artists.length; i += 6) {
      const batch = artists.slice(i, i + 6);
      const pages = await Promise.all(batch.map(a =>
        gql("queryArtistDiscographyAll", { uri: a.id, offset: 0, limit: 6, order: "DATE_DESC" })
          .then(r => walk(r.data, "spotify:album:").map(x => [a, x])).catch(() => [])));
      for (const [a, x] of pages.flat()) {
        const t = Date.parse(x.date?.isoString || "");
        // Same release in several editions/markets: keep one per artist + title.
        const key = a.id + "|" + (x.name || "").toLowerCase();
        if (!(t >= since) || t > Date.now() + 864e5 || seen.has(x.uri) || seen.has(key) || x.date?.precision !== "DAY") continue;
        seen.add(x.uri); seen.add(key);
        out.push({ ...albumC(x), subtitle: [a.name, cap(x.type) || "Album"].filter(Boolean).join(" · "), released: x.date.isoString });
      }
    }
    return out.sort((a, b) => b.released.localeCompare(a.released));
  },
  // Autoplay: this artist's top songs mixed with songs from related artists.
  async radio(t) {
    const id = t.extra?.artistUri;
    if (!id) return [];
    const me = await this.artist(id);
    const others = [...me.related].sort(() => Math.random() - 0.5).slice(0, 4);
    const more = await Promise.all(others.map(r => this.artist(r.id).then(p => p.tracks.slice(0, 5)).catch(() => [])));
    const mix = [...me.tracks.slice(0, 6), ...more.flat()];
    return mix.filter(x => x.id !== t.id).sort(() => Math.random() - 0.5);
  },
  async library() {
    const r = await gql("libraryV3", { filters: ["Playlists"], order: null, textFilter: "", features: [], limit: 50, offset: 0, flatten: true, expandedFolders: [], folderUri: null, includeFoldersWhenFlattening: true });
    return [{ id: "liked", title: "Liked Songs", subtitle: "Spotify", kind: "playlist" },
      ...walk(r, "spotify:playlist:").map(playlistC)];
  },
  async libraryAlbums() { return libraryOf("Albums", "spotify:album:", albumC); },
  async libraryArtists() { return libraryOf("Artists", "spotify:artist:", artistC); },
  // Header info + tracks for an album / playlist / Liked Songs.
  async details(id) {
    if (id === "liked") return { id, title: "Liked Songs", subtitle: "Spotify", kind: "playlist", tracks: await paged("fetchLibraryTracks", {}, 50) };
    if (id.startsWith("spotify:artist:")) { const a = await this.artist(id); return { id, title: a.name, kind: "artist", art: a.art, tracks: a.tracks }; }
    if (id.startsWith("spotify:album:")) {
      const out = []; let album = null;
      for (let offset = 0; offset < 500; offset += 50) {
        const u = (await gql("getAlbum", { uri: id, locale: "", offset, limit: 50 })).data?.albumUnion || {};
        album = album || u;
        const page = walk(u.tracksV2 || u.tracks || {}, "spotify:track:");
        out.push(...page.map(d => track(d, album)));
        if (page.length < 50) break;
      }
      const a = album || {};
      return { id, title: a.name, kind: (a.type || "album").toLowerCase(), art: art(a), color: color(a),
        subtitle: names(a.artists), artistId: a.artists?.items?.[0]?.uri, year: a.date?.isoString?.slice(0, 4),
        label: a.label, copyright: (a.copyright?.items || []).map(c => c.text).join(" · "), tracks: out,
        more: walk(a.moreAlbumsByArtist || {}, "spotify:album:").filter(x => x.uri !== id).map(albumC) };
    }
    const out = []; let meta = null;
    for (let offset = 0; offset < 2000; offset += 100) {
      const r = await gql("fetchPlaylist", { uri: id, offset, limit: 100, enableWatchFeedEntrypoint: false });
      meta = meta || r.data?.playlistV2;
      const page = walk(r.data?.playlistV2?.content || r, "spotify:track:");
      out.push(...page.map(d => track(d)));
      if (page.length < 100) break;
    }
    const p = meta || {};
    return { id, title: p.name, kind: "playlist", art: art(p), color: color(p), subtitle: p.ownerV2?.data?.name,
      description: (p.description || "").replace(/<[^>]+>/g, ""), followers: p.followers, tracks: out };
  },
  async collection(id) { return (await this.details(id)).tracks; },
  async home() { return (await this.details("liked")).tracks.slice(0, 100); },
};
