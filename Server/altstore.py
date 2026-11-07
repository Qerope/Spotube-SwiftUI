#!/usr/bin/env python3
"""Adds a release to the AltStore source served at https://qerope.me/spotube/altstore/source.json.

Run on the server by release.sh after it uploads the .ipa:
  altstore.py <ipa file name in data/altstore> <version> <build> <release notes file>
Keeps the newest 5 versions and deletes older .ipa files.
"""
import datetime
import json
import os
import sys
from pathlib import Path

BASE = "https://qerope.me/spotube/altstore/"
DIR = Path(__file__).resolve().parent / "data" / "altstore"
KEEP = 5

ipa, version, build, notes_file = sys.argv[1:5]
notes = Path(notes_file).read_text().strip() if os.path.exists(notes_file) else ""
src_path = DIR / "source.json"
src = json.loads(src_path.read_text()) if src_path.exists() else {}
src.update({
    "name": "Spotube Lite",
    "identifier": "me.qerope.spotube.source",
    "subtitle": "Your music, everywhere.",
    "description": "Spotube Lite builds, straight from the release script.",
    "iconURL": BASE + "icon.png",
    "website": "https://github.com/Qerope/Spotube-SwiftUI",
    "tintColor": "#FA2D48",
})
apps = src.get("apps") or [{}]
app = apps[0]
app.update({
    "name": "Spotube Lite",
    "bundleIdentifier": "dev.qerope.SpotubeLite",
    "developerName": "Qerope",
    "subtitle": "Spotify catalog, YouTube audio, synced everywhere.",
    "localizedDescription": "A fast, Apple Music-style player: your Spotify library and playlists, audio from YouTube, "
                            "offline downloads, synced lyrics, Replay stats, and seamless handoff between your devices through your own server.",
    "iconURL": BASE + "icon.png",
    "tintColor": "#FA2D48",
    "category": "entertainment",
    "screenshotURLs": [],
    "appPermissions": {"entitlements": [], "privacy": {
        "NSLocalNetworkUsageDescription": "Used for AirPlay and streaming from your Spotube server."}},
})
versions = [v for v in app.get("versions", []) if v.get("version") != version]
versions.insert(0, {
    "version": version,
    "buildVersion": str(build),
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes or f"Spotube Lite {version}",
    "downloadURL": BASE + ipa,
    "size": (DIR / ipa).stat().st_size,
    "minOSVersion": "26.0",
})
for old in versions[KEEP:]:
    (DIR / old["downloadURL"].rsplit("/", 1)[-1]).unlink(missing_ok=True)
app["versions"] = versions[:KEEP]
# Legacy (AltStore 1.x) fields mirror the newest version.
app.update({k: versions[0][v] for k, v in [("version", "version"), ("versionDate", "date"), ("versionDescription", "localizedDescription"),
                                            ("downloadURL", "downloadURL"), ("size", "size")]})
src["apps"] = [app]
src.setdefault("news", [])
tmp = src_path.with_suffix(".tmp")
tmp.write_text(json.dumps(src, indent=2))
tmp.replace(src_path)
print(f"AltStore source updated: {version} ({len(app['versions'])} versions kept)")
