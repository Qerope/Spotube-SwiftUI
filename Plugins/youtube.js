// YouTube audio source (same approach as NewPipe): InnerTube search -> best match by duration/"Topic"
// channel -> player API (ANDROID_VR client, which returns direct, unciphered stream URLs) -> m4a audio.
const VR = "1.62.27";
const VR_UA = `com.google.android.apps.youtube.vr.oculus/${VR} (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip`;
const yt = async (ep, body, headers = {}) => {
  const r = await fetch(`https://www.youtube.com/youtubei/v1/${ep}?prettyPrint=false`,
    { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`YouTube ${ep} failed: ${r.status}`);
  return r.json();
};
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
  const r = await yt("search", { context: { client: { clientName: "WEB", clientVersion: "2.20250101.00.00", hl: "en" } },
    query: `${artist} - ${t.title}`, params: "EgIQAQ==" });
  const vs = videos(r).slice(0, 10);
  if (!vs.length) throw new Error("No YouTube match");
  const score = v => (t.duration ? Math.abs(v.len - t.duration) : 0) - (/ - Topic$/.test(v.channel) ? 15 : 0)
    - (v.channel.toLowerCase().includes(artist.toLowerCase()) ? 5 : 0);
  const best = vs.reduce((a, b) => (score(b) < score(a) ? b : a)).id;
  localStorage.setItem("m:" + t.id, best);
  return best;
}
const plugin = {
  name: "YouTube", version: "1.0.0", author: "spotube-lite", abilities: ["audio"],
  async stream(t) {
    const id = await match(t);
    const p = await yt("player", {
      context: { client: { clientName: "ANDROID_VR", clientVersion: VR, deviceMake: "Oculus", deviceModel: "Quest 3",
        androidSdkVersion: 32, osName: "Android", osVersion: "12L", hl: "en", gl: "US" } },
      videoId: id, contentCheckOk: true, racyCheckOk: true,
    }, { "User-Agent": VR_UA });
    const st = p.playabilityStatus?.status;
    if (st !== "OK") { localStorage.removeItem("m:" + t.id); throw new Error("YouTube: " + (p.playabilityStatus?.reason || st)); }
    const a = (p.streamingData?.adaptiveFormats || []).filter(f => f.url && f.mimeType.startsWith("audio/mp4"));
    if (!a.length) throw new Error("No playable audio stream");
    return a.reduce((x, y) => (y.bitrate > x.bitrate ? y : x)).url;
  },
};
