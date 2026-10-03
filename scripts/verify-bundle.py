#!/usr/bin/env python3
"""Check a staged/extracted distribution, including all original license bytes."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[1]
bundle = app / "Contents/Resources/Hearth_HearthCore.bundle"
notices = bundle / "model-notices"
originals = root / "Sources/HearthCore/model-notices"
count = 0
for original in originals.rglob("*"):
    if not original.is_file():
        continue
    packaged = notices / original.relative_to(originals)
    assert packaged.resolve().is_relative_to(notices), f"Notice link escaped bundle: {packaged}"
    assert original.read_bytes() == packaged.read_bytes(), f"Modified notice: {original}"
    count += 1
models = json.loads((bundle / "catalog.json").read_text())
evidence_path = bundle / "recommendation-evidence.json"
assert evidence_path.read_bytes() == (root / "Sources/HearthCore/recommendation-evidence.json").read_bytes(), "Recommendation evidence changed during packaging"
evidence = json.loads(evidence_path.read_text())
assert {row["modelID"] for row in evidence["models"]} == {model["id"] for model in models}
digests = {model["id"]: model["sha256"] for model in models}
for row in evidence["models"]:
    assert row["modelSHA256"] == digests[row["modelID"]], "Recommendation does not match exact downloadable weights"
    for metric in row["metrics"]:
        assert 0 <= metric["value"] <= 100 and metric["sourceURL"].startswith("https://")
        assert re.fullmatch("[a-f0-9]{64}", metric["sourceSHA256"])
for model in models:
    for notice in model["noticeFiles"]:
        packaged = notices / model["id"] / notice["filename"]
        assert hashlib.sha256(packaged.read_bytes()).hexdigest() == notice["sha256"]

engine = app / "Contents/Resources/engine"
frameworks = app / "Contents/Frameworks"
sparkle = frameworks / "Sparkle.framework/Versions/B"
architecture = json.loads((engine / "version.json").read_text())["architecture"]
architecture = "x86_64" if architecture == "x64" else architecture
binaries = [app / "Contents/MacOS/MaxModel", engine / "llama-server", engine / "hearth-engine-guardian"]
binaries += [p for p in engine.glob("*.dylib") if not p.is_symlink()]
binaries += [sparkle / "Sparkle", sparkle / "Autoupdate", sparkle / "Updater.app/Contents/MacOS/Updater", *sparkle.glob("XPCServices/*.xpc/Contents/MacOS/*")]
assert (app / "Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt").is_file(), "Missing Sparkle license"
for path in binaries:
    subprocess.run(["lipo", str(path), "-verify_arch", architecture], check=True)
    headers = subprocess.check_output(["otool", "-l", str(path)], text=True)
    for minimum in re.findall(r"\bminos ([\d.]+)", headers):
        assert tuple(map(int, minimum.split("."))) <= (14, 0, 0), f"Requires newer macOS: {path}: {minimum}"
    dependencies = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in dependencies.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            # Apple's Swift support libraries are provided by macOS 14, not bundled.
            if dependency.startswith("@rpath/libswift"):
                continue
            relative = dependency.split("/", 1)[1]
            home = frameworks if relative.startswith("Sparkle.framework/") else engine
            library = home / relative
            assert library.exists() and library.resolve().is_relative_to(home), f"Missing dependency: {library}"
        else:
            assert dependency.startswith(("/usr/lib/", "/System/Library/")), dependency
print(f"Verified {len(models)} configurations, {count} original notice documents, {len(binaries)} {architecture} binaries (macOS 14 compatible deployment targets).")
