#!/usr/bin/env python3
"""Write release.json for the download site and one Sparkle appcast per architecture.

Usage: release-metadata.py --repo OWNER/NAME --out DIR [--notarized]
           --arm ZIP 'sparkle:edSignature="..." length="..."'
           --intel ZIP 'sparkle:edSignature="..." length="..."'

The signature strings are `sign_update` output for each ZIP. Appcasts are written unsigned;
sign them afterwards with `sign_update` so the app accepts them (SURequireSignedFeed).
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--repo", required=True)
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--notarized", action="store_true")
parser.add_argument("--arm", nargs=2, metavar=("ZIP", "SIGNATURE"), required=True)
parser.add_argument("--intel", nargs=2, metavar=("ZIP", "SIGNATURE"), required=True)
args = parser.parse_args()

info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
minimum = info["LSMinimumSystemVersion"]
tag = f"v{version}"
now = datetime.now(timezone.utc).replace(microsecond=0)
release_url = f"https://github.com/{args.repo}/releases/tag/{tag}"


def download(zip_path, signature):
    path = Path(zip_path)
    match = re.fullmatch(r'\s*sparkle:edSignature="([A-Za-z0-9+/=]+)"\s+length="(\d+)"\s*', signature)
    assert match, f"Unexpected sign_update output for {path.name}: {signature!r}"
    assert int(match[2]) == path.stat().st_size, f"Signed length does not match {path.name}"
    return {"name": path.name, "url": f"https://github.com/{args.repo}/releases/download/{tag}/{path.name}",
            "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "edSignature": match[1]}


downloads = {"appleSilicon": download(*args.arm), "intel": download(*args.intel)}


def appcast(item, hardware):
    requirement = f"\n      <sparkle:hardwareRequirements>{hardware}</sparkle:hardwareRequirements>" if hardware else ""
    notes = f'<p>MaxModel {escape(version)} is ready. <a href="{escape(release_url)}">See what changed</a>.</p>'
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MaxModel</title>
    <link>https://github.com/{escape(args.repo)}</link>
    <item>
      <title>MaxModel {escape(version)}</title>
      <pubDate>{format_datetime(now)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>{requirement}
      <description><![CDATA[{notes}]]></description>
      <enclosure url={quoteattr(item["url"])} length="{item["bytes"]}" type="application/octet-stream" sparkle:edSignature={quoteattr(item["edSignature"])}/>
    </item>
  </channel>
</rss>
"""


args.out.mkdir(parents=True, exist_ok=True)
(args.out / "appcast.xml").write_text(appcast(downloads["appleSilicon"], "arm64"))
(args.out / "appcast-intel.xml").write_text(appcast(downloads["intel"], None))
release = {"version": version, "build": build, "tag": tag, "published": now.isoformat().replace("+00:00", "Z"),
           "notarized": args.notarized, "minimumSystemVersion": minimum, "releaseURL": release_url,
           "downloads": {key: {k: v for k, v in value.items() if k != "edSignature"} for key, value in downloads.items()}}
(args.out / "release.json").write_text(json.dumps(release, indent=2) + "\n")
print(json.dumps(release, indent=2))
