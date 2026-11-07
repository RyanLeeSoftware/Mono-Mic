#!/usr/bin/env python3
"""Exercise the actual packaged hooks in disposable installation roots."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def run(*args, succeeds=True):
    result = subprocess.run([str(a) for a in args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (result.returncode == 0) != succeeds:
        raise AssertionError(f"Unexpected result for {args}: {result.stdout}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="monomic-package-tests.") as temporary:
        base = Path(temporary)
        expanded = base / "expanded"
        run("/usr/sbin/pkgutil", "--expand-full", args.package.resolve(), expanded)
        app = next(p for p in expanded.rglob("Mono Mic.app") if p.parent.name == "Applications")
        payload = app.parent.parent
        hooks = next(p for p in expanded.rglob("preinstall") if p.parent.name == "Scripts").parent
        assert (hooks / "common.sh").is_file()
        assert (hooks / "postinstall").is_file()
        driver = payload / "Library/Audio/Plug-Ins/HAL/MOTUMonoMic.driver"
        assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"] == "local.motu.monomic"
        assert plistlib.loads((driver / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"] == "local.motu.monomic.driver"
        assert (app / "Contents/Resources/SOURCE.txt").is_file()
        assert (app / "Contents/Resources/THIRD_PARTY_NOTICES.txt").is_file()
        volume = base / "fresh-volume"
        volume.mkdir()
        run("/bin/bash", hooks / "preinstall", "package", "/", volume)
        run("/usr/bin/ditto", payload, volume)
        run("/bin/bash", hooks / "postinstall", "package", "/", volume)
        # The privileged package must not register a root/console user's service.
        assert not list(volume.rglob("local.motu.monomic.agent.plist"))
        run("/bin/bash", hooks / "preinstall", "package", "/", volume)
        run("/usr/bin/ditto", payload, volume)
        run("/bin/bash", hooks / "postinstall", "package", "/", volume)
        unrelated = volume / "Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver/keep.txt"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("other driver must survive")
        settings = volume / "Users/test/Library/Application Support/MonoMic/settings.plist"
        settings.parent.mkdir(parents=True)
        settings.write_text("saved settings must survive")
        support = volume / "Library/Application Support/MonoMic"
        uninstaller = support / "Uninstall Mono Mic.command"
        run("/bin/bash", uninstaller, "--dry-run", "--volume", volume)
        assert (volume / "Applications/Mono Mic.app").is_dir()
        run("/bin/bash", uninstaller, "--yes", "--volume", volume)
        assert not (volume / "Applications/Mono Mic.app").exists()
        assert not (volume / "Library/Audio/Plug-Ins/HAL/MOTUMonoMic.driver").exists()
        assert not uninstaller.exists()
        assert unrelated.read_text() == "other driver must survive"
        assert settings.read_text() == "saved settings must survive"
        # Unrelated bundles and symbolic-link parents fail before any removal.
        rejected = base / "unrelated-volume"
        fake = rejected / "Applications/Mono Mic.app/Contents/Info.plist"
        fake.parent.mkdir(parents=True)
        fake.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.application"}))
        run("/bin/bash", hooks / "preinstall", "package", "/", rejected, succeeds=False)
        assert fake.is_file()
        root_script = Path(__file__).resolve().parents[1] / "scripts/uninstall.sh"
        run("/bin/bash", root_script, "--yes", "--volume", rejected, succeeds=False)
        assert fake.is_file()
        linked = base / "linked-volume"
        linked.mkdir()
        (linked / "Applications").symlink_to(rejected / "Applications", target_is_directory=True)
        run("/bin/bash", hooks / "preinstall", "package", "/", linked, succeeds=False)
        run("/bin/bash", root_script, "--yes", "--volume", linked, succeeds=False)
        assert fake.is_file()
    print(json.dumps({"result": "Passed", "checks": ["package contents", "fresh install hooks", "upgrade hooks",
        "no root login agent", "uninstall dry-run", "uninstall removal", "preserve saved settings", "preserve other drivers",
        "reject unrelated bundles", "reject symlink parents"], "hostAudioSystemTouched": False}, indent=2))


if __name__ == "__main__":
    main()
