"""Lyd server: device sync, listening history/stats and a yt-dlp audio cache.

Everything lives in one SQLite database (DATA_DIR/db/spotube.db) so it can be mined later:
  devices      every device that ever connected + its latest player state (handoff)
  tracks       catalog of every track the apps have seen
  plays        one row per listen (who/where/how long/skipped/context), the basis for stats
  entities     synced documents: likes, playlists, saved albums/artists, plugin data (matches, logins), settings
  searches     search history
  cache_files  audio cache index (LRU by last stream)
  audio_log    every audio request (cache hit, latency, errors)
  commands     remote commands between devices (e.g. "pause" when another device takes over)
"""
import asyncio
import hashlib
import json
import logging
import os
import re
import secrets
import shutil
import sqlite3
import threading
import time
from collections import Counter, defaultdict
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, Response
from pydantic import BaseModel

VERSION = "1.1.0"
STARTED = time.time()
DATA = Path(os.environ.get("DATA_DIR", "/data"))
CACHE = DATA / "cache"
DBDIR = DATA / "db"
TOKEN = os.environ.get("SPOTUBE_TOKEN", "")
CACHE_LIMIT = int(float(os.environ.get("CACHE_LIMIT_GB", "0")) * 1e9)
MIN_FREE = int(float(os.environ.get("MIN_FREE_GB", "2")) * 1e9)
ACCEL = os.environ.get("ACCEL_PREFIX")  # nginx internal location serving CACHE, e.g. /spotube-cache/
YTDLP = os.environ.get("YTDLP", "yt-dlp")
PROXY = os.environ.get("YTDLP_PROXY", "")  # e.g. socks5://127.0.0.1:40000 (Cloudflare WARP) if YouTube blocks the server IP
COOKIES = DATA / "cookies.txt"            # optional Netscape cookies file for yt-dlp
HELPER_WAIT = 45                           # seconds to wait for a Mac helper to fetch a song YouTube refused us
STREAM_KEY = hashlib.sha256(f"{TOKEN}:audio".encode()).hexdigest()[:32] if TOKEN else ""
VID = re.compile(r"^[A-Za-z0-9_-]{11}$")

log = logging.getLogger("spotube")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
now = lambda: int(time.time() * 1000)

for d in (CACHE, DBDIR):
    d.mkdir(parents=True, exist_ok=True)
os.chmod(DBDIR, 0o700)

SCHEMA = """
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY, name TEXT, platform TEXT, app_version TEXT,
  first_seen INTEGER, last_seen INTEGER, last_ip TEXT, state TEXT, state_at INTEGER);
CREATE TABLE IF NOT EXISTS tracks(id TEXT PRIMARY KEY, title TEXT, artist TEXT, album TEXT, art TEXT, duration REAL,
  extra TEXT, first_seen INTEGER, last_seen INTEGER);
CREATE TABLE IF NOT EXISTS plays(id INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT UNIQUE, track_id TEXT, device_id TEXT,
  started_at INTEGER, ended_at INTEGER, listened REAL, duration REAL, completed INTEGER, skipped INTEGER, source TEXT,
  context_id TEXT, context_title TEXT, context_art TEXT, shuffle INTEGER, repeat TEXT, autoplay INTEGER, tz_offset INTEGER);
CREATE INDEX IF NOT EXISTS plays_started ON plays(started_at);
CREATE INDEX IF NOT EXISTS plays_track ON plays(track_id);
CREATE TABLE IF NOT EXISTS entities(kind TEXT, key TEXT, value TEXT, updated_at INTEGER, deleted INTEGER DEFAULT 0,
  seq INTEGER, device_id TEXT, PRIMARY KEY(kind, key));
CREATE INDEX IF NOT EXISTS entities_seq ON entities(seq);
CREATE TABLE IF NOT EXISTS searches(id INTEGER PRIMARY KEY AUTOINCREMENT, q TEXT, device_id TEXT, at INTEGER);
CREATE TABLE IF NOT EXISTS cache_files(video_id TEXT PRIMARY KEY, bytes INTEGER, created_at INTEGER, last_access INTEGER, hits INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS audio_log(id INTEGER PRIMARY KEY AUTOINCREMENT, video_id TEXT, device_id TEXT, at INTEGER,
  cache_hit INTEGER, ms INTEGER, error TEXT);
CREATE TABLE IF NOT EXISTS commands(id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT, cmd TEXT, args TEXT,
  from_device TEXT, created_at INTEGER, done INTEGER DEFAULT 0);
"""


class DB:
    def __init__(self, path: Path):
        self.c = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.c.row_factory = sqlite3.Row
        self.lock = threading.RLock()
        self.c.executescript(SCHEMA)

    def q(self, sql: str, args=()) -> list[sqlite3.Row]:
        with self.lock:
            return self.c.execute(sql, args).fetchall()

    def one(self, sql: str, args=()) -> Optional[sqlite3.Row]:
        r = self.q(sql, args)
        return r[0] if r else None

    def tx(self):
        return _Tx(self)

    def next_seq(self) -> int:
        r = self.one("SELECT value FROM meta WHERE key='seq'")
        s = (int(r["value"]) if r else 0) + 1
        self.c.execute("INSERT OR REPLACE INTO meta VALUES('seq', ?)", (str(s),))
        return s


class _Tx:
    def __init__(self, db: DB):
        self.db = db

    def __enter__(self):
        self.db.lock.acquire()
        self.db.c.execute("BEGIN IMMEDIATE")
        return self.db.c

    def __exit__(self, et, *_):
        self.db.c.execute("ROLLBACK" if et else "COMMIT")
        self.db.lock.release()


db = DB(DBDIR / "spotube.db")
if "helper" not in [r["name"] for r in db.q("PRAGMA table_info(devices)")]:
    db.q("ALTER TABLE devices ADD COLUMN helper INTEGER DEFAULT 0")


def upsert_track(c, t: dict):
    if not isinstance(t, dict) or not t.get("id"):
        return
    ts = now()
    c.execute("""INSERT INTO tracks(id,title,artist,album,art,duration,extra,first_seen,last_seen) VALUES(?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET title=excluded.title, artist=excluded.artist, album=coalesce(excluded.album, album),
      art=coalesce(excluded.art, art), duration=coalesce(excluded.duration, duration), extra=coalesce(excluded.extra, extra),
      last_seen=excluded.last_seen""",
              (t["id"], t.get("title"), t.get("artist"), t.get("album"), t.get("art"), t.get("duration"),
               json.dumps(t.get("extra")) if t.get("extra") else None, ts, ts))


# ---------------------------------------------------------------- auth / app

def auth(request: Request):
    h = request.headers.get("authorization", "")
    tok = h[7:] if h.lower().startswith("bearer ") else request.query_params.get("k", "")
    if not TOKEN:
        raise HTTPException(401, "server has no token")
    # Audio URLs carry a derived stream key instead of the API token (they end up in logs / player caches).
    if request.url.path.startswith("/v1/audio/") and request.method in ("GET", "HEAD") and secrets.compare_digest(tok, STREAM_KEY):
        return True
    if not secrets.compare_digest(tok, TOKEN):
        raise HTTPException(401, "bad token")
    return True


ytdlp_version = ""
yt = {"blocked_until": 0.0, "last_ok": 0, "last_error": "", "last_error_at": 0, "server": 0, "helper": 0, "failed": 0}
BLOCK_SECONDS = 1800  # after YouTube bot-checks the server, go to a Mac helper first for this long


async def refresh_ytdlp_version():
    global ytdlp_version
    try:
        p = await asyncio.create_subprocess_exec(YTDLP, "--version", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(p.communicate(), 20)
        ytdlp_version = out.decode().strip()
    except Exception:  # noqa
        pass


async def updater():
    """Keep yt-dlp current: YouTube changes break old versions."""
    while True:
        try:
            p = await asyncio.create_subprocess_exec("pip", "install", "-q", "-U", "--no-cache-dir", "yt-dlp",
                                                     stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
            _, err = await asyncio.wait_for(p.communicate(), 300)
            log.info("yt-dlp update exit %s %s", p.returncode, err.decode()[-200:] if err else "")
        except Exception as e:  # noqa
            log.warning("yt-dlp update failed: %s", e)
        await refresh_ytdlp_version()
        await asyncio.sleep(24 * 3600)


@asynccontextmanager
async def lifespan(_):
    t = asyncio.create_task(updater())
    await refresh_ytdlp_version()
    # Files on disk but not indexed (e.g. DB reset) get indexed; index rows without files are dropped.
    files = {p.stem: p for p in CACHE.glob("*.m4a") if "." not in p.stem}
    with db.tx() as c:
        for r in c.execute("SELECT video_id FROM cache_files").fetchall():
            if r["video_id"] not in files:
                c.execute("DELETE FROM cache_files WHERE video_id=?", (r["video_id"],))
        for vid, p in files.items():
            c.execute("INSERT OR IGNORE INTO cache_files VALUES(?,?,?,?,0)", (vid, p.stat().st_size, now(), now()))
    for p in [*CACHE.glob("*.dl*"), *CACHE.glob("*.up*")]:
        p.unlink(missing_ok=True)
    yield
    t.cancel()


app = FastAPI(title="Lyd server", version=VERSION, lifespan=lifespan)


@app.get("/health")
def health():
    return {"ok": True, "version": VERSION}


# ---------------------------------------------------------------- devices / handoff

class Hello(BaseModel):
    id: str
    name: str = ""
    platform: str = ""
    appVersion: str = ""


@app.post("/v1/hello", dependencies=[Depends(auth)])
def hello(h: Hello, request: Request):
    ip = request.headers.get("x-forwarded-for", request.client.host if request.client else "").split(",")[0].strip()
    ts = now()
    with db.tx() as c:
        c.execute("""INSERT INTO devices(id,name,platform,app_version,first_seen,last_seen,last_ip) VALUES(?,?,?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name, platform=excluded.platform, app_version=excluded.app_version,
          last_seen=excluded.last_seen, last_ip=excluded.last_ip""", (h.id, h.name, h.platform, h.appVersion, ts, ts, ip))
    return {"time": ts, "version": VERSION, "streamKey": STREAM_KEY, "commands": take_commands(h.id), "devices": devices_list(), "cache": cache_info()}


def devices_list():
    out = []
    for r in db.q("SELECT * FROM devices ORDER BY last_seen DESC"):
        d = dict(r)
        d["state"] = json.loads(d["state"]) if d["state"] else None
        out.append(d)
    return out


@app.get("/v1/devices", dependencies=[Depends(auth)])
def devices():
    return devices_list()


class StateIn(BaseModel):
    device: str
    state: dict


@app.put("/v1/state", dependencies=[Depends(auth)])
def put_state(s: StateIn):
    with db.tx() as c:
        c.execute("UPDATE devices SET state=?, state_at=?, last_seen=? WHERE id=?", (json.dumps(s.state), now(), now(), s.device))
    return {"ok": True}


class Command(BaseModel):
    target: str
    cmd: str
    args: dict = {}
    sender: str = ""


@app.post("/v1/command", dependencies=[Depends(auth)])
def command(c: Command):
    with db.tx() as x:
        x.execute("INSERT INTO commands(device_id,cmd,args,from_device,created_at) VALUES(?,?,?,?,?)",
                  (c.target, c.cmd, json.dumps(c.args), c.sender, now()))
    notify(c.target)
    return {"ok": True}


waiters: dict[str, asyncio.Event] = {}


def notify(device: str):
    if device in waiters:
        waiters[device].set()


def take_commands(device: str) -> list[dict]:
    with db.tx() as c:
        rows = [dict(r) for r in c.execute("SELECT id, cmd, args, from_device, created_at FROM commands WHERE device_id=? AND done=0 AND created_at>?",
                                           (device, now() - 120_000)).fetchall()]
        c.execute("UPDATE commands SET done=1 WHERE device_id=? AND done=0", (device,))
    for r in rows:
        r["args"] = json.loads(r["args"]) if r["args"] else {}
    return rows


@app.get("/v1/commands/wait", dependencies=[Depends(auth)])
async def wait_commands(device: str, timeout: int = 25, helper: bool = False):
    """Long-poll: returns as soon as a command for `device` arrives (or after `timeout` s with [])."""
    db.q("UPDATE devices SET last_seen=?, helper=? WHERE id=?", (now(), int(helper), device))
    ev = waiters.setdefault(device, asyncio.Event())
    if not (cmds := take_commands(device)):
        ev.clear()
        try:
            await asyncio.wait_for(ev.wait(), min(timeout, 50))
        except asyncio.TimeoutError:
            pass
        cmds = take_commands(device)
    db.q("UPDATE devices SET last_seen=? WHERE id=?", (now(), device))
    return cmds


# ---------------------------------------------------------------- sync (last-writer-wins documents)

class Change(BaseModel):
    kind: str
    key: str
    value: Any = None
    updatedAt: int
    deleted: bool = False


class SyncIn(BaseModel):
    device: str
    since: int = 0
    changes: list[Change] = []


@app.post("/v1/sync", dependencies=[Depends(auth)])
def sync(s: SyncIn):
    applied = 0
    with db.tx() as c:
        for ch in s.changes:
            cur = c.execute("SELECT updated_at FROM entities WHERE kind=? AND key=?", (ch.kind, ch.key)).fetchone()
            if cur and cur["updated_at"] > ch.updatedAt:
                continue  # we already have something newer
            seq = db.next_seq()
            c.execute("INSERT OR REPLACE INTO entities(kind,key,value,updated_at,deleted,seq,device_id) VALUES(?,?,?,?,?,?,?)",
                      (ch.kind, ch.key, json.dumps(ch.value), ch.updatedAt, int(ch.deleted), seq, s.device))
            if isinstance(ch.value, dict):
                upsert_track(c, ch.value.get("track"))
                for t in ch.value.get("tracks") or []:
                    upsert_track(c, t)
            applied += 1
        rows = c.execute("SELECT * FROM entities WHERE seq>? ORDER BY seq", (s.since,)).fetchall()
        top = c.execute("SELECT value FROM meta WHERE key='seq'").fetchone()
    return {
        "seq": int(top["value"]) if top else 0, "applied": applied,
        "changes": [{"kind": r["kind"], "key": r["key"], "value": json.loads(r["value"]) if r["value"] else None,
                     "updatedAt": r["updated_at"], "deleted": bool(r["deleted"])} for r in rows],
    }


# ---------------------------------------------------------------- events / history / stats

class Event(BaseModel):
    type: str
    uid: str = ""
    device: str = ""
    track: Optional[dict] = None
    startedAt: int = 0
    endedAt: int = 0
    listened: float = 0
    duration: float = 0
    completed: bool = False
    skipped: bool = False
    source: str = ""
    contextId: str = ""
    contextTitle: str = ""
    contextArt: str = ""
    shuffle: bool = False
    repeat: str = ""
    autoplay: bool = False
    tzOffset: int = 0
    q: str = ""


@app.post("/v1/events", dependencies=[Depends(auth)])
def events(evs: list[Event]):
    with db.tx() as c:
        for e in evs:
            if e.type == "play" and e.track:
                upsert_track(c, e.track)
                c.execute("""INSERT OR IGNORE INTO plays(uid,track_id,device_id,started_at,ended_at,listened,duration,completed,skipped,
                  source,context_id,context_title,context_art,shuffle,repeat,autoplay,tz_offset) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                          (e.uid or secrets.token_hex(8), e.track["id"], e.device, e.startedAt, e.endedAt, e.listened, e.duration,
                           int(e.completed), int(e.skipped), e.source, e.contextId, e.contextTitle, e.contextArt, int(e.shuffle),
                           e.repeat, int(e.autoplay), e.tzOffset))
            elif e.type == "search" and e.q.strip():
                c.execute("INSERT INTO searches(q,device_id,at) VALUES(?,?,?)", (e.q.strip(), e.device, e.startedAt or now()))
    return {"ok": True, "count": len(evs)}


def track_row(r) -> dict:
    return {"id": r["id"], "title": r["title"], "artist": r["artist"], "album": r["album"], "art": r["art"],
            "duration": r["duration"], "extra": json.loads(r["extra"]) if r["extra"] else None}


@app.get("/v1/plays/tracks", dependencies=[Depends(auth)])
def track_plays():
    """Per-song listening summary for every song ever played (smart playlists, sorting by plays)."""
    rows = db.q("""SELECT t.*, count(*) plays, coalesce(sum(p.skipped),0) skips, max(p.started_at) last, min(p.started_at) first
        FROM plays p JOIN tracks t ON t.id=p.track_id GROUP BY p.track_id""")
    return [{"track": track_row(r), "plays": r["plays"], "skips": r["skips"], "last": r["last"], "first": r["first"]} for r in rows]


@app.get("/v1/history", dependencies=[Depends(auth)])
def history(limit: int = 100):
    """Most recent listens across all devices, one row per track (latest first)."""
    rows = db.q("""SELECT t.*, p.started_at, p.device_id, p.context_id, p.context_title, p.context_art FROM plays p
      JOIN tracks t ON t.id=p.track_id
      WHERE p.id IN (SELECT max(id) FROM plays GROUP BY track_id) ORDER BY p.started_at DESC LIMIT ?""", (min(limit, 1000),))
    return [{"track": track_row(r), "at": r["started_at"], "device": r["device_id"],
             "context": {"id": r["context_id"], "title": r["context_title"], "art": r["context_art"]} if r["context_id"] else None}
            for r in rows]


@app.get("/v1/searches", dependencies=[Depends(auth)])
def searches(limit: int = 20):
    return [r["q"] for r in db.q("SELECT q, max(at) a FROM searches GROUP BY lower(q) ORDER BY a DESC LIMIT ?", (limit,))]


@app.get("/v1/stats", dependencies=[Depends(auth)])
def stats(days: int = 30):
    since = now() - days * 86400_000 if days > 0 else 0
    rows = db.q("""SELECT p.*, t.title, t.artist, t.album, t.art, t.duration AS tdur, t.extra FROM plays p
      LEFT JOIN tracks t ON t.id=p.track_id WHERE p.started_at>=? ORDER BY p.started_at""", (since,))
    tracks, artists, albums = defaultdict(lambda: [0, 0.0]), defaultdict(lambda: [0, 0.0]), defaultdict(lambda: [0, 0.0])
    meta, art_of, by_hour, by_day, by_device, by_weekday = {}, {}, [0.0] * 24, Counter(), Counter(), [0.0] * 7
    total, skips = 0.0, 0
    for r in rows:
        mins = (r["listened"] or 0) / 60
        total += mins
        skips += r["skipped"] or 0
        tracks[r["track_id"]][0] += 1
        tracks[r["track_id"]][1] += mins
        meta[r["track_id"]] = r
        a = (r["artist"] or "").split(", ")[0]
        if a:
            artists[a][0] += 1
            artists[a][1] += mins
            ex = json.loads(r["extra"]) if r["extra"] else {}
            if ex.get("artistUri"):
                art_of[a] = ex["artistUri"]
        if r["album"]:
            k = (r["album"], a)
            albums[k][0] += 1
            albums[k][1] += mins
        local = (r["started_at"] or 0) / 1000 + (r["tz_offset"] or 0)
        tm = time.gmtime(local)
        by_hour[tm.tm_hour] += mins
        by_weekday[tm.tm_wday] += mins
        by_day[time.strftime("%Y-%m-%d", tm)] += mins
        by_device[r["device_id"] or "?"] += mins
    names = {r["id"]: r["name"] for r in db.q("SELECT id, name FROM devices")}
    top = lambda d, n: sorted(d.items(), key=lambda kv: (-kv[1][1], -kv[1][0]))[:n]
    return {
        "days": days, "minutes": round(total, 1), "plays": len(rows), "uniqueTracks": len(tracks), "uniqueArtists": len(artists),
        "skipRate": round(skips / len(rows), 3) if rows else 0,
        "topTracks": [{"track": track_row({**dict(meta[k]), "id": k, "duration": meta[k]["tdur"]}), "plays": v[0], "minutes": round(v[1], 1)}
                      for k, v in top(tracks, 50)],
        "topArtists": [{"name": k, "id": art_of.get(k), "plays": v[0], "minutes": round(v[1], 1)} for k, v in top(artists, 25)],
        "topAlbums": [{"title": k[0], "artist": k[1], "plays": v[0], "minutes": round(v[1], 1),
                       "art": next((m["art"] for m in meta.values() if m["album"] == k[0]), None)} for k, v in top(albums, 25)],
        "byHour": [round(x, 1) for x in by_hour], "byWeekday": [round(x, 1) for x in by_weekday],
        "byDay": [{"day": d, "minutes": round(m, 1)} for d, m in sorted(by_day.items())],
        "byDevice": [{"device": names.get(d, d), "minutes": round(m, 1)} for d, m in by_device.most_common()],
    }


# ---------------------------------------------------------------- audio cache

inflight: dict[str, asyncio.Task] = {}


def cache_info():
    r = db.one("SELECT count(*) n, coalesce(sum(bytes),0) b FROM cache_files")
    free = shutil.disk_usage(CACHE).free
    # No fixed cap: the cache may grow into all free disk space except MIN_FREE.
    room = r["b"] + max(0, free - MIN_FREE)
    limit = min(CACHE_LIMIT, room) if CACHE_LIMIT else room
    return {"files": r["n"], "bytes": r["b"], "limit": limit, "diskFree": free}


def evict(keep: str = ""):
    """Drop least-recently-streamed files until under the cap and the disk keeps MIN_FREE free."""
    total = db.one("SELECT coalesce(sum(bytes),0) b FROM cache_files")["b"]
    for r in db.q("SELECT video_id, bytes FROM cache_files ORDER BY last_access ASC"):
        if (not CACHE_LIMIT or total <= CACHE_LIMIT) and shutil.disk_usage(CACHE).free >= MIN_FREE:
            break
        if r["video_id"] == keep or r["video_id"] in inflight:
            continue
        (CACHE / f"{r['video_id']}.m4a").unlink(missing_ok=True)
        db.q("DELETE FROM cache_files WHERE video_id=?", (r["video_id"],))
        total -= r["bytes"]
        log.info("evicted %s (%d bytes)", r["video_id"], r["bytes"])


async def _download(vid: str) -> Path:
    """Server yt-dlp first; when YouTube refuses the server (datacenter IPs get bot-checked), any online
    Mac helper fetches the song and uploads it. While blocked, helpers are asked first to save the wait."""
    dst, tmp = CACHE / f"{vid}.m4a", CACHE / f"{vid}.dl.m4a"
    if time.time() < yt["blocked_until"] and await via_helper(vid):
        yt["helper"] += 1
        return dst
    extra = (["--proxy", PROXY] if PROXY else []) + (["--cookies", str(COOKIES)] if COOKIES.exists() else [])
    p = await asyncio.create_subprocess_exec(
        YTDLP, "-q", "--no-warnings", "--no-playlist", "--no-part", "--force-overwrites", "-N", "4", *extra,
        "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]", "--ppa", "FixupM4a:-movflags +faststart",
        "-o", str(tmp), f"https://www.youtube.com/watch?v={vid}",
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
    try:
        _, err = await asyncio.wait_for(p.communicate(), 150)
    except asyncio.TimeoutError:
        p.kill()
        err = b"ERROR: yt-dlp timed out"
    if p.returncode != 0 or not tmp.exists():
        msg = [l for l in err.decode(errors="replace").splitlines() if "ERROR" in l]
        tmp.unlink(missing_ok=True)
        detail = (msg[-1] if msg else f"yt-dlp exit {p.returncode}")[:300]
        yt["last_error"], yt["last_error_at"] = detail, now()
        if "not a bot" in detail or "Sign in" in detail or "HTTP Error 429" in detail:
            yt["blocked_until"] = time.time() + BLOCK_SECONDS
        if dst.exists() or await via_helper(vid):
            yt["helper"] += 1
            return dst
        yt["failed"] += 1
        raise HTTPException(502, detail + ("" if helpers_online() else " (no Mac helper online)"))
    tmp.replace(dst)
    index(vid, dst)
    yt["server"] += 1
    yt["last_ok"] = now()
    yt["blocked_until"] = 0
    return dst


def index(vid: str, dst: Path):
    db.q("INSERT OR REPLACE INTO cache_files VALUES(?,?,?,?,0)", (vid, dst.stat().st_size, now(), now()))
    evict(keep=vid)


def helpers_online() -> list[str]:
    """Macs that can run yt-dlp and are long-polling right now, most recently seen first."""
    return [r["id"] for r in db.q("SELECT id FROM devices WHERE helper=1 AND last_seen>? ORDER BY last_seen DESC", (now() - 90_000,))]


async def via_helper(vid: str) -> bool:
    """YouTube refused the server (datacenter IP): ask an online Mac to fetch the song and upload it."""
    dst = CACHE / f"{vid}.m4a"
    helpers = helpers_online()
    if not helpers:
        return False
    with db.tx() as c:
        for h in helpers:
            c.execute("INSERT INTO commands(device_id,cmd,args,from_device,created_at) VALUES(?,?,?,?,?)",
                      (h, "fetch", json.dumps({"videoId": vid}), "server", now()))
    for h in helpers:
        notify(h)
    for _ in range(HELPER_WAIT * 4):
        if dst.exists():
            return True
        await asyncio.sleep(0.25)
    return False


@app.put("/v1/audio/{vid}", dependencies=[Depends(auth)])
async def upload(vid: str, request: Request):
    """A device that fetched a song itself (Mac with yt-dlp) shares it with the server cache."""
    if not VID.match(vid):
        raise HTTPException(400, "bad video id")
    dst = CACHE / f"{vid}.m4a"
    if dst.exists():
        return {"stored": False, "reason": "exists"}
    tmp = CACHE / f"{vid}.up{secrets.token_hex(4)}.m4a"
    size = 0
    with open(tmp, "wb") as f:
        async for chunk in request.stream():
            size += len(chunk)
            if size > 80_000_000:
                f.close(); tmp.unlink(missing_ok=True)
                raise HTTPException(413, "too large")
            f.write(chunk)
    with open(tmp, "rb") as f:
        head = f.read(12)
    if size < 10_000 or head[4:8] != b"ftyp":
        tmp.unlink(missing_ok=True)
        raise HTTPException(400, "not an m4a file")
    tmp.replace(dst)
    index(vid, dst)
    return {"stored": True, "bytes": size}


@app.get("/v1/audio/{vid}/exists", dependencies=[Depends(auth)])
def exists(vid: str):
    return {"exists": VID.match(vid) is not None and (CACHE / f"{vid}.m4a").exists()}


async def ensure(vid: str) -> tuple[Path, bool]:
    dst = CACHE / f"{vid}.m4a"
    if dst.exists():
        return dst, True
    t = inflight.get(vid)
    if not t:
        t = asyncio.create_task(_download(vid))
        inflight[vid] = t
        t.add_done_callback(lambda _: inflight.pop(vid, None))
    return await asyncio.shield(t), False


@app.api_route("/v1/audio/{vid}", methods=["GET", "HEAD"], dependencies=[Depends(auth)])
async def audio(vid: str, request: Request, d: str = ""):
    if not VID.match(vid):
        raise HTTPException(400, "bad video id")
    t0 = time.time()
    rng = request.headers.get("range", "")
    first = not rng or rng.startswith("bytes=0-")
    try:
        path, hit = await ensure(vid)
    except HTTPException as e:
        db.q("INSERT INTO audio_log(video_id,device_id,at,cache_hit,ms,error) VALUES(?,?,?,?,?,?)",
             (vid, d, now(), 0, int((time.time() - t0) * 1000), str(e.detail)))
        raise
    if first:
        db.q("UPDATE cache_files SET last_access=?, hits=hits+1 WHERE video_id=?", (now(), vid))
        db.q("INSERT INTO audio_log(video_id,device_id,at,cache_hit,ms) VALUES(?,?,?,?,?)",
             (vid, d, now(), int(hit), int((time.time() - t0) * 1000)))
    if ACCEL:
        return Response(headers={"X-Accel-Redirect": f"{ACCEL}{vid}.m4a", "Content-Type": "audio/mp4",
                                 "Cache-Control": "private, max-age=86400"})
    return FileResponse(path, media_type="audio/mp4")


@app.post("/v1/audio/{vid}/prefetch", dependencies=[Depends(auth)], status_code=202)
async def prefetch(vid: str, bg: BackgroundTasks, wait: bool = False, d: str = ""):
    """Warm the cache. With wait=1 it returns once the file is ready (or the real error), so the
    player can stream it instantly afterwards instead of timing out inside AVPlayer."""
    if not VID.match(vid):
        raise HTTPException(400, "bad video id")
    if wait:
        t0 = time.time()
        try:
            path, hit = await ensure(vid)
        except HTTPException as e:
            db.q("INSERT INTO audio_log(video_id,device_id,at,cache_hit,ms,error) VALUES(?,?,?,?,?,?)",
                 (vid, d, now(), 0, int((time.time() - t0) * 1000), str(e.detail)))
            raise
        return {"ready": True, "bytes": path.stat().st_size, "cached": hit}

    async def run():
        try:
            await ensure(vid)
        except Exception as e:  # noqa
            log.info("prefetch %s failed: %s", vid, e)
    bg.add_task(run)
    return {"queued": True}


@app.get("/v1/cache", dependencies=[Depends(auth)])
def cache():
    return cache_info()


# ---------------------------------------------------------------- dashboard (https://…/spotube/dashboard?k=TOKEN)

def _ago(ms) -> str:
    if not ms:
        return "never"
    s = max(0, (now() - int(ms)) / 1000)
    return "just now" if s < 45 else f"{int(s // 60)} min ago" if s < 3600 else f"{int(s // 3600)} h ago" if s < 86400 else f"{int(s // 86400)} d ago"


def _gb(b) -> str:
    return f"{b / 1e9:.2f} GB" if b >= 1e8 else f"{b / 1e6:.1f} MB"


def _e(x) -> str:
    import html
    return html.escape(str(x if x is not None else ""))


def cached_songs() -> list[dict]:
    """Cached files with the song they belong to (via the synced YouTube matches), most recently streamed first."""
    titles = {}
    for r in db.q("""SELECT e.value v, t.title, t.artist FROM entities e JOIN tracks t ON e.key = 'youtube/m2:' || t.id
                     WHERE e.kind='plugin' AND e.key LIKE 'youtube/m2:%' AND e.deleted=0"""):
        try:
            titles.setdefault(json.loads(r["v"]), (r["title"], r["artist"]))
        except Exception:  # noqa
            pass
    return [{**dict(r), "title": titles.get(r["video_id"], (None, None))[0], "artist": titles.get(r["video_id"], (None, None))[1]}
            for r in db.q("SELECT video_id, bytes, created_at, last_access, hits FROM cache_files ORDER BY last_access DESC")]


def dashboard_data() -> dict:
    day, week = now() - 86_400_000, now() - 7 * 86_400_000
    c = cache_info()
    disk = shutil.disk_usage(CACHE)
    online = set(helpers_online())
    devs = []
    for d in devices_list():
        st = d.get("state") or {}
        cur = st.get("current") or {}
        devs.append({"name": d["name"] or d["id"], "platform": d["platform"], "version": d["app_version"], "ip": d["last_ip"],
                     "seen": d["last_seen"], "online": (d["last_seen"] or 0) > now() - 90_000, "helper": d["id"] in online,
                     "playing": bool(st.get("playing")) and (d.get("state_at") or 0) > now() - 600_000,
                     "track": f"{cur.get('title', '')} — {cur.get('artist', '')}" if cur else ""})
    a = db.one("SELECT count(*) n, sum(cache_hit) hits, avg(ms) ms, sum(error IS NOT NULL) errs FROM audio_log WHERE at>?", (day,))
    return {
        "cache": c, "disk": {"total": disk.total, "used": disk.used, "free": disk.free},
        "devices": devs,
        "audio24": {"requests": a["n"], "hits": a["hits"] or 0, "avgMs": int(a["ms"] or 0), "errors": a["errs"] or 0},
        "audioLog": [dict(r) for r in db.q("""SELECT l.video_id, l.at, l.cache_hit, l.ms, l.error, coalesce(d.name, l.device_id) dev
            FROM audio_log l LEFT JOIN devices d ON d.id=l.device_id ORDER BY l.id DESC LIMIT 25""")],
        "plays": {"day": db.one("SELECT count(*) n FROM plays WHERE started_at>?", (day,))["n"],
                  "week": db.one("SELECT count(*) n FROM plays WHERE started_at>?", (week,))["n"],
                  "total": db.one("SELECT count(*) n FROM plays")["n"],
                  "hoursWeek": round((db.one("SELECT coalesce(sum(listened),0) s FROM plays WHERE started_at>?", (week,))["s"]) / 3600, 1)},
        "recentPlays": [dict(r) for r in db.q("""SELECT p.started_at, p.listened, p.skipped, t.title, t.artist, coalesce(d.name, p.device_id) dev
            FROM plays p LEFT JOIN tracks t ON t.id=p.track_id LEFT JOIN devices d ON d.id=p.device_id ORDER BY p.started_at DESC LIMIT 15""")],
        "topWeek": [dict(r) for r in db.q("""SELECT t.title, t.artist, count(*) n FROM plays p JOIN tracks t ON t.id=p.track_id
            WHERE p.started_at>? GROUP BY p.track_id ORDER BY n DESC LIMIT 10""", (week,))],
        "entities": {r["kind"]: r["n"] for r in db.q("SELECT kind, count(*) n FROM entities WHERE deleted=0 GROUP BY kind")},
        "db": sum(p.stat().st_size for p in DBDIR.glob("*")),
        "cached": cached_songs(),
        "youtube": {**yt, "blocked": time.time() < yt["blocked_until"], "ytdlp": ytdlp_version, "proxy": bool(PROXY), "cookies": COOKIES.exists()},
        "server": {"version": VERSION, "uptime": int(time.time() - STARTED)},
    }


@app.get("/v1/dashboard", dependencies=[Depends(auth)])
def dashboard_json():
    return dashboard_data()


@app.get("/dashboard", response_class=HTMLResponse)
def dashboard(request: Request, k: str = ""):
    # Opening it once with ?k=TOKEN stores a cookie and drops the token from the URL (and from browser history on refresh).
    if TOKEN and k and secrets.compare_digest(k, TOKEN):
        r = Response(status_code=303, headers={"Location": "dashboard"})
        r.set_cookie("spotube_dash", hashlib.sha256(f"{TOKEN}:dash".encode()).hexdigest(), max_age=90 * 86400, path="/spotube/",
                     httponly=True, secure=True, samesite="strict")
        return r
    ck = request.cookies.get("spotube_dash", "")
    if not TOKEN or not secrets.compare_digest(ck, hashlib.sha256(f"{TOKEN}:dash".encode()).hexdigest()):
        return HTMLResponse("<!doctype html><meta name=viewport content='width=device-width'><body style='font:16px system-ui;background:#000;color:#ccc;padding:40px'>"
                            "Add <code>?k=YOUR_TOKEN</code> to the URL.</body>", status_code=401)
    d = dashboard_data()
    c, dk, y, a, pl = d["cache"], d["disk"], d["youtube"], d["audio24"], d["plays"]
    pct = lambda x, t: min(100, round(100 * x / t)) if t else 0
    up = d["server"]["uptime"]
    hit = f"{round(100 * a['hits'] / a['requests'])}%" if a["requests"] else "–"
    helpers = sum(1 for x in d["devices"] if x["helper"])
    if y["blocked"]:
        yts, ytc = f"Blocked on server · {'using ' + str(helpers) + ' Mac helper' + ('s' if helpers != 1 else '') if helpers else 'no Mac helper online!'}", "warn" if helpers else "bad"
    else:
        yts, ytc = ("OK · last server download " + _ago(y["last_ok"])) if y["last_ok"] else "Not tried yet", "dim"
    rows = lambda items, f: "".join(f(i) for i in items) or "<tr><td class=dim colspan=9>Nothing yet</td></tr>"
    dev_rows = rows(d["devices"], lambda x: f"""<tr><td><span class='dot {"on" if x["online"] else ""}'></span>{_e(x["name"])}</td>
        <td class=dim>{_e(x["platform"])} {_e(x["version"])}</td><td>{"<span class=pill>helper</span>" if x["helper"] else ""}</td>
        <td>{("▶ " if x["playing"] else "") + _e(x["track"])}</td><td class='dim r'>{_ago(x["seen"])}</td></tr>""")
    log_rows = rows(d["audioLog"], lambda r: f"""<tr><td class=dim>{_ago(r["at"])}</td><td><a href='https://youtu.be/{_e(r["video_id"])}'>{_e(r["video_id"])}</a></td>
        <td>{_e(r["dev"])}</td><td>{"<span class='pill bad'>error</span> " + _e(r["error"]) if r["error"] else ("<span class=pill>cache</span>" if r["cache_hit"] else "<span class='pill warn'>fetched</span>")}</td>
        <td class='dim r'>{r["ms"]} ms</td></tr>""")
    play_rows = rows(d["recentPlays"], lambda r: f"""<tr><td class=dim>{_ago(r["started_at"])}</td><td>{_e(r["title"])}<div class=dim>{_e(r["artist"])}</div></td>
        <td>{_e(r["dev"])}</td><td class='dim r'>{int((r["listened"] or 0) // 60)}:{int((r["listened"] or 0) % 60):02d}{" · skipped" if r["skipped"] else ""}</td></tr>""")
    cache_rows = rows(d["cached"], lambda r: f"""<tr><td>{_e(r["title"] or "Unknown song")}<div class=dim>{_e(r["artist"] or "")}
        <a class=dim href='https://youtu.be/{_e(r["video_id"])}'>{_e(r["video_id"])}</a></div></td>
        <td class='dim r'>{_gb(r["bytes"])}</td><td class='dim r'>{r["hits"]} plays</td><td class='dim r'>{_ago(r["last_access"])}</td></tr>""")
    top_rows = rows(d["topWeek"], lambda r: f"<tr><td>{_e(r['title'])}<div class=dim>{_e(r['artist'])}</div></td><td class='r'>{r['n']}</td></tr>")
    ent = " · ".join(f"{v} {_e(k)}" for k, v in sorted(d["entities"].items())) or "none"
    return f"""<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=20><title>Spotube Server</title><style>
:root{{--bg:#0b0b0d;--card:#17171a;--line:#2a2a2e;--fg:#f2f2f4;--dim:#8e8e93;--red:#fa2d48;--ok:#30d158;--warn:#ffb340}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;padding:24px 16px}}
main{{max-width:1100px;margin:auto}}h1{{font-size:26px;margin:0 0 4px}}h2{{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--dim);margin:0 0 12px}}
.sub{{color:var(--dim);margin-bottom:22px}}.grid{{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));margin-bottom:14px}}
.card{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px;overflow:auto}}.big{{font-size:26px;font-weight:700}}
.bar{{height:8px;background:#2c2c30;border-radius:4px;margin:10px 0 6px;overflow:hidden}}.bar i{{display:block;height:100%;background:var(--red)}}
table{{width:100%;border-collapse:collapse}}td{{padding:7px 6px;border-top:1px solid var(--line);vertical-align:top}}tr:first-child td{{border-top:0}}
.dim{{color:var(--dim)}}.r{{text-align:right;white-space:nowrap}}a{{color:var(--fg)}}.ok{{color:var(--ok)}}.warn{{color:var(--warn)}}.bad{{color:var(--red)}}
.pill{{font-size:11px;padding:1px 7px;border-radius:9px;background:#2c2c30;color:var(--dim);white-space:nowrap}}.pill.warn{{color:var(--warn)}}.pill.bad{{color:var(--red)}}
.dot{{display:inline-block;width:8px;height:8px;border-radius:50%;background:#48484a;margin-right:8px}}.dot.on{{background:var(--ok)}}
.two{{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));margin-bottom:14px}}
</style></head><body><main>
<h1>Spotube Server</h1><div class=sub>v{VERSION} · up {up // 86400}d {up % 86400 // 3600}h {up % 3600 // 60}m · yt-dlp {_e(y["ytdlp"])} · refreshes every 20 s</div>
<div class=grid>
 <div class=card><h2>Music cache</h2><div class=big>{_gb(c["bytes"])}</div><div class=bar><i style="width:{pct(c["bytes"], c["limit"])}%"></i></div><div class=dim>{c["files"]} songs · room for {_gb(c["limit"])} (disk minus {_gb(MIN_FREE)} reserve)</div></div>
 <div class=card><h2>Disk</h2><div class=big>{_gb(dk["free"])} free</div><div class=bar><i style="width:{pct(dk["used"], dk["total"])}%"></i></div><div class=dim>{_gb(dk["used"])} of {_gb(dk["total"])} used · DB {_gb(d["db"])}</div></div>
 <div class=card><h2>YouTube</h2><div class="big {ytc}" style="font-size:18px">{_e(yts)}</div><div class=dim style="margin-top:8px">{y["server"]} by server · {y["helper"]} by Mac helpers · {y["failed"]} failed (since restart)</div>
  {f'<div class=dim style="margin-top:6px">Last error {_ago(y["last_error_at"])}: {_e(y["last_error"][:140])}</div>' if y["last_error"] else ""}</div>
 <div class=card><h2>Streaming · 24 h</h2><div class=big>{a["requests"]}</div><div class=dim>requests · {hit} from cache · avg {a["avgMs"]} ms · {a["errors"]} errors</div></div>
 <div class=card><h2>Listening</h2><div class=big>{pl["day"]} <span class=dim style="font-size:14px;font-weight:400">today</span></div><div class=dim>{pl["week"]} plays · {pl["hoursWeek"]} h this week · {pl["total"]} all time</div></div>
 <div class=card><h2>Synced data</h2><div class=dim>{ent}</div></div>
</div>
<div class="card" style="margin-bottom:14px"><h2>Devices</h2><table>{dev_rows}</table></div>
<div class=two><div class=card><h2>Recent plays</h2><table>{play_rows}</table></div><div class=card><h2>Top songs · 7 days</h2><table>{top_rows}</table></div></div>
<div class=card style="margin-bottom:14px"><h2>Audio requests</h2><table>{log_rows}</table></div>
<div class=card><h2>Cached songs · {c["files"]} · oldest-streamed are removed first</h2><table>{cache_rows}</table></div>
</main></body></html>"""
