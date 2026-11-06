// YouTube audio source mirroring NewPipeExtractor (what Spotube's "NewPipe YouTube" plugin uses):
// InnerTube WEB search -> best match by duration / "Topic" channel -> ANDROID client
// visitor_id + reel/reel_item_watch player response -> direct m4a audio URL.
const AV = "21.03.36";
const AUA = `com.google.android.youtube/${AV} (Linux; U; Android 15; US) gzip`;
const GAPIS = "https://youtubei.googleapis.com/youtubei/v1/";
const android = vd => ({
  client: { clientName: "ANDROID", clientVersion: AV, clientScreen: "WATCH", platform: "MOBILE", osName: "Android",
    osVersion: "15", androidSdkVersion: 35, hl: "en", gl: "US", utcOffsetMinutes: 0, ...(vd ? { visitorData: vd } : {}) },
  request: { internalExperimentFlags: [], useSsl: true }, user: { lockedSafetyMode: false },
});
const rnd = n => Array.from({ length: n }, () => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"[Math.floor(Math.random() * 64)]).join("");
const aHeaders = { "User-Agent": AUA, "X-Goog-Api-Format-Version": "2", "X-YouTube-Client-Name": "3", "X-YouTube-Client-Version": AV };
async function post(url, body, headers = {}) {
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`YouTube ${url.split("/v1/")[1].split("?")[0]}: HTTP ${r.status}`);
  return r.json();
}

async function visitorData() {
  const c = JSON.parse(localStorage.getItem("vd") || "null");
  if (c && Date.now() - c.at < 6 * 3600e3) return c.v;
  const j = await post(GAPIS + "visitor_id?prettyPrint=false", { context: android() }, aHeaders);
  const v = j.responseContext?.visitorData;
  if (!v) throw new Error("Could not get visitorData");
  localStorage.setItem("vd", JSON.stringify({ v, at: Date.now() }));
  return v;
}
async function player(id) {
  const vd = await visitorData(), cpn = rnd(16);
  const j = await post(`${GAPIS}reel/reel_item_watch?prettyPrint=false&t=${rnd(12)}&id=${id}&$fields=playerResponse`, {
    context: android(vd),
    playerRequest: { videoId: id, cpn, contentCheckOk: true, racyCheckOk: true },
    disablePlayerResponse: false,
  }, { ...aHeaders, "X-Goog-Visitor-Id": vd });
  return { p: j.playerResponse || j, cpn };
}

const secs = s => (s || "").split(":").reduce((a, b) => a * 60 + Number(b), 0);
const norm = s => (s || "").toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ").trim();
// Versions people almost never want unless the Spotify title asks for them.
const VARIANTS = ["live", "concert", "tour", "instrumental", "karaoke", "cover", "remix", "sped up", "slowed", "reverb", "8d", "nightcore",
  "acoustic", "piano", "lofi", "lo fi", "edit", "extended", "mashup", "reaction", "tutorial", "lesson", "demo", "rehearsal", "session", "unplugged", "version", "mix", "bass boosted", "clean"];

// YouTube Music "Songs" search (what Spotube uses): official audio tracks with artist + duration.
function musicSongs(x, out = []) {
  if (Array.isArray(x)) x.forEach(y => musicSongs(y, out));
  else if (x && typeof x === "object") {
    const m = x.musicResponsiveListItemRenderer;
    if (m) {
      const col = i => (m.flexColumns?.[i]?.musicResponsiveListItemFlexColumnRenderer?.text?.runs || []).map(r => r.text);
      const id = m.playlistItemData?.videoId || m.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId;
      const meta = col(1), dur = meta.find(t => /^\d+(:\d\d)+$/.test(t));
      if (id) out.push({ id, title: col(0).join(""), channel: meta.filter(t => t !== " • " && t !== dur).join(" "), len: secs(dur), music: true });
    } else for (const k in x) musicSongs(x[k], out);
  }
  return out;
}
function videos(x, out = []) {
  if (Array.isArray(x)) x.forEach(y => videos(y, out));
  else if (x && typeof x === "object") {
    if (x.videoRenderer) {
      const v = x.videoRenderer;
      out.push({ id: v.videoId, title: (v.title?.runs || []).map(r => r.text).join(""), len: secs(v.lengthText?.simpleText),
        channel: (v.ownerText?.runs || []).map(r => r.text).join("") });
    } else for (const k in x) videos(x[k], out);
  }
  return out;
}

// Lower is better. Hard rejects return Infinity.
function score(t, v) {
  const want = norm(t.title), got = norm(v.title), chan = norm(v.channel);
  const artists = t.artist.split(",").map(norm).filter(Boolean);
  let s = 0;
  if (t.duration && v.len) {
    const d = Math.abs(v.len - t.duration);
    if (d > 20) return Infinity;            // different cut (live, extended, ...)
    s += d * 2;
  }
  for (const w of VARIANTS) if (new RegExp(`\\b${w}\\b`).test(got) && !new RegExp(`\\b${w}\\b`).test(want)) s += 60;
  const words = want.replace(/\b(feat|ft|with)\b.*$/, "").split(" ").filter(w => w.length > 1);
  const missing = words.filter(w => !got.includes(w)).length;
  s += words.length ? (missing / words.length) * 50 : 0;
  if (artists.some(a => chan.includes(a) || got.includes(a))) s -= 15; else s += 25;
  if (/ - topic$/.test(chan) || v.music) s -= 10;  // official audio
  return s;
}

async function match(t) {
  const key = "m2:" + t.id, cached = localStorage.getItem(key);
  if (cached) return cached;
  const artist = t.artist.split(",")[0].trim();
  const q = `${artist} ${t.title}`;
  let cands = [];
  try {
    const r = await post("https://music.youtube.com/youtubei/v1/search?prettyPrint=false",
      { context: { client: { clientName: "WEB_REMIX", clientVersion: "1.20260101.01.00", hl: "en", gl: "US" } }, query: q, params: "EgWKAQIIAWoKEAoQAxAEEAkQBQ==" },
      { Origin: "https://music.youtube.com", Referer: "https://music.youtube.com/" });
    cands = musicSongs(r).slice(0, 10);
  } catch (e) {}
  let best = cands.map(v => [score(t, v), v]).sort((a, b) => a[0] - b[0])[0];
  if (!best || best[0] > 40) {   // nothing convincing on YouTube Music: try regular YouTube
    const r = await post("https://www.youtube.com/youtubei/v1/search?prettyPrint=false",
      { context: { client: { clientName: "WEB", clientVersion: "2.20260101.00.00", hl: "en", gl: "US" } }, query: `${artist} - ${t.title} audio`, params: "EgIQAQ==" });
    const more = videos(r).slice(0, 15).map(v => [score(t, v), v]);
    best = [...(best ? [best] : []), ...more].sort((a, b) => a[0] - b[0])[0];
  }
  if (!best || best[0] === Infinity) throw new Error("No matching YouTube upload");
  localStorage.setItem(key, best[1].id);
  return best[1].id;
}

// Plain /player clients that return direct (unciphered) stream URLs; tried in order, then the reel endpoint.
const CLIENTS = [
  [{ clientName: "ANDROID", clientVersion: "20.10.38", androidSdkVersion: 30, osName: "Android", osVersion: "11" },
    "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"],
  [{ clientName: "IOS", clientVersion: "20.10.4", deviceMake: "Apple", deviceModel: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82" },
    "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"],
];
const audioOf = p => (p.streamingData?.adaptiveFormats || []).filter(f => f.url && f.mimeType.startsWith("audio/mp4"));

const plugin = {
  name: "YouTube (NewPipe)", version: "2.2.0", author: "spotube-lite", abilities: ["audio"],
  // Returns { url, headers } so the player sends the same User-Agent the stream was issued for.
  async stream(t) {
    const id = await match(t), errs = [];
    // macOS: yt-dlp decodes YouTube's signature/"n" parameter (like NewPipeExtractor) -> full song, cached file.
    if (globalThis.ytdlp) {
      try { return await ytdlp.audio("https://www.youtube.com/watch?v=" + id); }
      catch (e) { errs.push("yt-dlp: " + e.message); }
    }
    for (const [c, ua] of CLIENTS) {
      try {
        const p = await post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
          { context: { client: { ...c, hl: "en", gl: "US" } }, videoId: id, contentCheckOk: true, racyCheckOk: true }, { "User-Agent": ua });
        const a = audioOf(p);
        if (p.playabilityStatus?.status === "OK" && a.length)
          return { url: a.reduce((x, y) => (y.bitrate > x.bitrate ? y : x)).url, headers: { "User-Agent": ua } };
        errs.push(`${c.clientName}: ${p.playabilityStatus?.reason || p.playabilityStatus?.status || "no audio"}`);
      } catch (e) { errs.push(`${c.clientName}: ${e.message}`); }
    }
    try {
      const { p, cpn } = await player(id), a = audioOf(p);
      if (a.length) return { url: a.reduce((x, y) => (y.bitrate > x.bitrate ? y : x)).url + "&cpn=" + cpn, headers: { "User-Agent": AUA } };
      errs.push("reel: " + (p.playabilityStatus?.reason || "no audio"));
    } catch (e) { errs.push("reel: " + e.message); localStorage.removeItem("vd"); }
    localStorage.removeItem("m2:" + t.id);
    throw new Error("YouTube: " + errs.join("; "));
  },
};
