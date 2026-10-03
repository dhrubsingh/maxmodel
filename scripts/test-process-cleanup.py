#!/usr/bin/env python3
"""Kill only the test harness; verify its model engine also exits after a crash."""
import os
import pathlib
import re
import signal
import subprocess
import time

root = pathlib.Path(__file__).resolve().parents[1]
env = os.environ.copy()
env["HEARTH_ENGINE_PATH"] = str(root / "dist/MaxModel.app/Contents/Resources/engine/llama-server")
process = subprocess.Popen([str(root / ".build/release/hearth-smoke"), "--hold"], cwd=root, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
engine_pid = None
try:
    for line in process.stdout:
        print(line.rstrip(), flush=True)
        match = re.search(r"ENGINE pid=(\d+)", line)
        if match:
            engine_pid = int(match.group(1))
            break
    if not engine_pid:
        raise RuntimeError("Engine did not start: " + process.stderr.read())
    process.kill()
    process.wait(timeout=5)
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        status = subprocess.run(["ps", "-o", "stat=", "-p", str(engine_pid)], capture_output=True, text=True)
        if status.returncode != 0 or status.stdout.strip().startswith("Z"):
            print("PASS: engine stopped automatically after parent crash")
            break
        time.sleep(0.1)
    else:
        raise RuntimeError("Engine remained running after parent crash")
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=5)
    if engine_pid:
        try:
            os.kill(engine_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
