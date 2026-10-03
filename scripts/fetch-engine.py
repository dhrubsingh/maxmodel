#!/usr/bin/env python3
"""Fetch one pinned upstream runtime. No package-manager or runtime installation."""
import hashlib
import argparse
import json
import pathlib
import platform
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
TAG = "b11146"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--arch", choices=["arm64", "x64"], default="arm64" if platform.machine() == "arm64" else "x64")
parser.add_argument("--dest", type=pathlib.Path, default=ROOT / "vendor/llama")
options = parser.parse_args()
ARCH = options.arch
HASHES = {
    "arm64": "1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711",
    "x64": "305f0e3a17d2c01eb205cd0a62128357f1ec3b55329cb084d94e5ec0115d7a3b",
}
dest = options.dest.resolve()
dest.mkdir(parents=True, exist_ok=True)
archive = ROOT / f".build/downloads/llama-{TAG}-{ARCH}.tar.gz"
archive.parent.mkdir(parents=True, exist_ok=True)
url = f"https://github.com/ggml-org/llama.cpp/releases/download/{TAG}/llama-{TAG}-bin-macos-{ARCH}.tar.gz"
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != HASHES[ARCH]:
    print(f"Downloading {TAG} for {ARCH}…", flush=True)
    urllib.request.urlretrieve(url, archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == HASHES[ARCH], "Runtime checksum mismatch"
with tarfile.open(archive) as tar:
    for member in tar.getmembers():
        if not member.isfile():
            continue
        name = pathlib.PurePosixPath(member.name).name
        if name in ("llama-server", "llama") or name.endswith((".dylib", ".metallib")):
            # Flatten upstream bin/ and lib/ into the app's engine directory.
            target = dest / name
            target.write_bytes(tar.extractfile(member).read())
            target.chmod(0o755)
    for member in tar.getmembers():
        if member.issym() and member.name.endswith('.dylib'):
            target = dest / pathlib.PurePosixPath(member.name).name
            link_name = pathlib.PurePosixPath(member.linkname).name
            if target.is_symlink():
                target.unlink()
            if not target.exists():
                target.symlink_to(link_name)
    for target in dest.glob('*.dylib'):
        assert target.exists(), f"Broken library link: {target}"
license_url = f"https://raw.githubusercontent.com/ggml-org/llama.cpp/{TAG}/LICENSE"
urllib.request.urlretrieve(license_url, dest / "LICENSE")
(dest / "version.json").write_text(json.dumps({"tag": TAG, "archiveSHA256": HASHES[ARCH], "architecture": ARCH}, indent=2))
assert (dest / "llama-server").exists(), "Upstream archive is missing llama-server"
print(f"Verified engine: {dest / 'llama-server'}", flush=True)
