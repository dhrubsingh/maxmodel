#!/usr/bin/env python3
"""Trim only a fresh staged app, before signing. Original build inputs stay intact."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
assert app.suffix == ".app" and (app / "Contents/MacOS/MaxModel").is_file()
engine = app / "Contents/Resources/engine"


def size():
    return sum(p.stat().st_size for p in app.rglob("*") if p.is_file() and not p.is_symlink())


before = size()
# Follow the actual loader dependency graph, including versioned symlink chains.
# Runtime backends in this pinned build are linked directly, not discovered plugins.
keep = set()
visited = set()


def retain(path):
    assert path.parent == engine, f"Unexpected runtime path: {path}"
    while path.is_symlink():
        keep.add(path)
        path = path.parent / os.readlink(path)
        assert path.parent == engine, f"Library symlink escapes runtime: {path}"
    assert path.is_file(), f"Missing runtime dependency: {path}"
    keep.add(path)
    if path in visited:
        return
    visited.add(path)
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
            retain(engine / dependency.split("/", 1)[1])
        else:
            assert dependency.startswith(("/usr/lib/", "/System/Library/")), dependency


retain(engine / "llama-server")
removed = []
for path in sorted(engine.iterdir()):
    if (path.suffix == ".dylib" or path.name == "llama") and path not in keep:
        removed.append(path.name)
        path.unlink()

# Strip local/debug symbols, keeping exported symbols and runtime functionality.
# Signing occurs afterwards. Metal kernels/resources and upstream notices remain.
for path in [app / "Contents/MacOS/MaxModel", engine / "hearth-engine-guardian", *sorted(visited)]:
    subprocess.run(["xcrun", "strip", "-S", "-x", str(path)], check=True)

# Original notices ship as real files. Sharing them through symlinks saved ~2 MB but broke
# license reads when the app ran from an iCloud-synced folder, which blocked model loading.
linked = 0

print(json.dumps({"beforeBytes": before, "afterBytes": size(), "noticeCopiesShared": linked,
                  "removedRuntimeFiles": removed}, indent=2))
