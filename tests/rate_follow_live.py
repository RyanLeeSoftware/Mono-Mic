"""Opt-in macOS integration check using an idle BlackHole 2ch as test input.

Temporarily pauses our launch agent; runs the installed service with isolated
settings; restores the test device rate and the original agent in finally.
Never changes the selected physical interface's rate or saved settings.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = Path(os.environ.get("MONOMIC_BUILD_DIR", "build.noindex"))
CONTROL = ROOT / BUILD_DIR / "audio-device-control"
APP = Path.home() / "Applications/Mono Mic.app"
CLI = APP / "Contents/MacOS/MonoMic"
SERVICE = APP / "Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService"
SETTINGS = Path.home() / "Library/Application Support/MonoMic/settings.plist"
SOURCE = "BlackHole2ch_UID"
JOB = f"gui/{os.getuid()}/local.motu.monomic.agent"


def run(*args):
    return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.PIPE)


def status():
    return json.loads(run(CLI, "--status"))


def wait_for(predicate, seconds=15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            last = status()
            if predicate(last):
                return last
        except (subprocess.CalledProcessError, json.JSONDecodeError):
            pass
        time.sleep(0.15)
    raise AssertionError(f"Timed out waiting for audio: {last}")


def interrupted(signum, frame):
    raise KeyboardInterrupt()


signal.signal(signal.SIGTERM, interrupted)
before = status()
assert before["running"] and before["inputUID"] != SOURCE
original_hash = hashlib.sha256(SETTINGS.read_bytes()).hexdigest()
source = json.loads(run(CONTROL, SOURCE))
if source["running"]:
    raise SystemExit("Skipped: BlackHole 2ch is in use by another application.")
agent = None
with tempfile.TemporaryDirectory(prefix="monomic-rate-test-") as directory:
    path = Path(directory) / "settings.plist"
    path.write_bytes(plistlib.dumps({"version": 1, "inputUID": SOURCE,
        "inputName": source["name"], "inputChannel": 0, "channelLayout": source["channels"],
        "bufferFrames": before["bufferFrames"], "gainDb": before["gainDb"]}))
    with (Path(directory) / "agent.log").open("w") as log:
        try:
            run(CLI, "--quit-service")
            env = dict(os.environ, MONOMIC_SETTINGS_PATH=str(path))
            agent = subprocess.Popen([str(SERVICE), "--agent"], env=env, stdout=log, stderr=log)
            wait_for(lambda s: s["running"] and s["inputUID"] == SOURCE)
            for rate in [44100, 88200, 96000, 176400, 192000, 48000]:
                run(CONTROL, SOURCE, rate)
                first = wait_for(lambda s: s["running"] and s["inputUID"] == SOURCE and s["sampleRate"] == rate)
                time.sleep(0.5)
                second = status()
                assert second["pid"] == first["pid"] and second["running"]
                assert second["sampleRate"] == rate
                assert second["capturedFrames"] > first["capturedFrames"]
                assert second["renderedFrames"] > first["renderedFrames"]
                assert second["callbackError"] == 0 and second["underruns"] == 0 and second["overruns"] == 0
                virtual = json.loads(run(CONTROL, "MOTUMonoMic_UID"))
                assert virtual["rate"] == rate
                print(f"Live {rate} Hz: both devices match; capture/render advancing; no callback errors or dropouts.", flush=True)
        finally:
            if agent:
                agent.terminate()
                try:
                    agent.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    agent.kill()
                    agent.wait()
            try:
                run(CONTROL, SOURCE, source["rate"])
            finally:
                run("/bin/launchctl", "kickstart", JOB)
                restored = wait_for(lambda s: s["running"] and s["inputUID"] == before["inputUID"] and s["sampleRate"] == before["sampleRate"])
                assert hashlib.sha256(SETTINGS.read_bytes()).hexdigest() == original_hash
                print(f"Restored original route at {restored['sampleRate']} Hz; saved settings unchanged.", flush=True)
