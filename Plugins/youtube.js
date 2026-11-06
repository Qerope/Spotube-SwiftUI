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
function videos(x, out = []) {
  if (Array.isArray(x)) x.forEach(y => videos(y, out));
  else if (x && typeof x === "object") {
    if (x.videoRenderer) {
      const v = x.videoRenderer;
      out.push({ id: v.videoId, len: secs(v.lengthText?.simpleText), channel: (v.ownerText?.runs || []).map(r => r.text).join("") });
    } else for (const k in x) videos(x[k], out);
  }
  return out;
}
async function match(t) {
  const cached = localStorage.getItem("m:" + t.id);
  if (cached) return cached;
  const artist = t.artist.split(",")[0].trim();
  const r = await post("https://www.youtube.com/youtubei/v1/search?prettyPrint=false",
    { context: { client: { clientName: "WEB", clientVersion: "2.20260101.00.00", hl: "en", gl: "US" } }, query: `${artist} - ${t.title}`, params: "EgIQAQ==" });
  const vs = videos(r).slice(0, 10);
  if (!vs.length) throw new Error("No YouTube match");
  const score = v => (t.duration ? Math.abs(v.len - t.duration) : 0) - (/ - Topic$/.test(v.channel) ? 15 : 0)
    - (v.channel.toLowerCase().includes(artist.toLowerCase()) ? 5 : 0);
  const best = vs.reduce((a, b) => (score(b) < score(a) ? b : a)).id;
  localStorage.setItem("m:" + t.id, best);
  return best;
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
  name: "YouTube (NewPipe)", version: "2.1.0", author: "spotube-lite", abilities: ["audio"],
  // Returns { url, headers } so the player sends the same User-Agent the stream was issued for.
  async stream(t) {
    const id = await match(t), errs = [];
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
    localStorage.removeItem("m:" + t.id);
    throw new Error("YouTube: " + errs.join("; "));
  },
};
