#!/usr/bin/env python3
"""Build local GitHub release assets. Nothing is published or installed."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RELEASE_VERSION = "0.8.0-beta.1"
SOURCE_DIRECTORIES = ("src", "driver", "resources", "vendor", "scripts", "tests", "packaging", "docs")
SOURCE_FILES = ("README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md", ".gitignore")


def run(*args, capture=False, env=None):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None, env=env)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_files():
    selected = [ROOT / name for name in SOURCE_FILES]
    for name in SOURCE_DIRECTORIES + ("MonoMic.xcodeproj",):
        for path in (ROOT / name).rglob("*"):
            if not path.is_file():
                continue
            if any(part in {"xcuserdata", "__pycache__", ".DS_Store"} or part.endswith(".noindex")
                   for part in path.relative_to(ROOT).parts):
                continue
            if path.suffix in {".pyc", ".profraw", ".p12", ".mobileprovision", ".provisionprofile", ".xcuserstate"}:
                continue
            if path.is_symlink():
                raise RuntimeError(f"Source archive may not follow a symlink: {path}")
            selected.append(path)
    for path in selected:
        if not path.is_file():
            raise RuntimeError(f"Missing release source: {path}")
    return sorted(set(selected))


def archive_source(destination, version):
    prefix = f"MonoMic-{version}-source"
    selected = source_files()
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in selected:
            archive.write(path, f"{prefix}/{path.relative_to(ROOT).as_posix()}")
    return {str(path.relative_to(ROOT)): sha256(path) for path in selected}


def sign_code(path, identity, entitlements=None):
    command = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime"]
    command += ["--timestamp=none"] if identity == "-" else ["--timestamp"]
    if entitlements:
        command += ["--entitlements", str(entitlements)]
    run(*command, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--unsigned", action="store_true", help="Explicitly build an unsigned, unnotarized preview installer.")
    parser.add_argument("--skip-build", action="store_true", help="Reuse existing Release products in MONOMIC_BUILD_DIR.")
    parser.add_argument("--skip-tests", action="store_true", help="Reuse an already-tested build; the manifest records this.")
    parser.add_argument("--version", default=RELEASE_VERSION)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", args.version):
        parser.error("Use a semantic release version, for example 0.8.0-beta.1.")
    application_identity = os.environ.get("MONOMIC_APPLICATION_IDENTITY", "")
    installer_identity = os.environ.get("MONOMIC_INSTALLER_IDENTITY", "")
    notary_profile = os.environ.get("MONOMIC_NOTARY_PROFILE", "")
    if not args.unsigned:
        if not application_identity.startswith("Developer ID Application:"):
            parser.error("Set MONOMIC_APPLICATION_IDENTITY to a Developer ID Application identity, or use --unsigned for a preview.")
        if not installer_identity.startswith("Developer ID Installer:") or not notary_profile:
            parser.error("Signed releases require MONOMIC_INSTALLER_IDENTITY and MONOMIC_NOTARY_PROFILE.")
    build = Path(os.environ.get("MONOMIC_BUILD_DIR", "build-release.noindex")).resolve()
    build.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, MONOMIC_BUILD_DIR=str(build), MONOMIC_CONFIGURATION="Release")
    if not args.skip_tests:
        run("/bin/bash", "scripts/test.sh", env=env)
    if not args.skip_build:
        run("/bin/bash", "scripts/build.sh", env=env)
    app = build / "Mono Mic.app"
    driver = build / "MOTUMonoMic.driver"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    bundle_version = args.version.split("-", 1)[0]
    if info["CFBundleShortVersionString"] != bundle_version:
        raise RuntimeError("Release version and the built app version do not match.")
    destination = (args.output or ROOT / "dist" / args.version).resolve()
    if destination.exists() and any(destination.iterdir()):
        raise RuntimeError(f"Refusing to overwrite existing release assets: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    status = "UNSIGNED" if args.unsigned else "notarized"
    basename = f"MonoMic-{args.version}-macOS-{status}"
    with tempfile.TemporaryDirectory(prefix="release-staging.", dir=build) as temporary:
        staging = Path(temporary)
        output = staging / "assets"
        output.mkdir()
        payload = staging / "payload"
        staged_app = payload / "Applications/Mono Mic.app"
        staged_driver = payload / "Library/Audio/Plug-Ins/HAL/MOTUMonoMic.driver"
        for source, target in [(app, staged_app), (driver, staged_driver)]:
            target.parent.mkdir(parents=True, exist_ok=True)
            run("/usr/bin/ditto", source, target)
        support = payload / "Library/Application Support/MonoMic"
        support.mkdir(parents=True)
        shutil.copy2(ROOT / "scripts/uninstall.sh", support / "Uninstall Mono Mic.command")
        shutil.copy2(ROOT / "packaging/pkg-scripts/common.sh", support / "common.sh")
        for path in support.iterdir():
            path.chmod(0o755)
        resources = staged_app / "Contents/Resources"
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", resources / "THIRD_PARTY_NOTICES.txt")
        (resources / "SOURCE.txt").write_text(
            f"Mono Mic {args.version}\nComplete corresponding source and build/install scripts are in "
            f"MonoMic-{args.version}-source.zip, provided alongside this installer in the same GitHub release.\n"
            "See LICENSE and THIRD_PARTY_NOTICES.txt for license and attribution information.\n")
        identity = "-" if args.unsigned else application_identity
        helper = staged_app / "Contents/Library/LoginItems/Mono Mic Service.app"
        sign_code(helper, identity, ROOT / "resources/MonoMic.entitlements")
        sign_code(staged_app, identity, ROOT / "resources/MonoMic.entitlements")
        sign_code(staged_driver, identity)
        architectures = {}
        for name, executable in {
            "settings": staged_app / "Contents/MacOS/MonoMic",
            "service": helper / "Contents/MacOS/MonoMicService",
            "driver": staged_driver / "Contents/MacOS/MOTUMonoMic",
        }.items():
            architectures[name] = run("/usr/bin/lipo", "-archs", executable, capture=True).stdout.split()
            if set(architectures[name]) != {"arm64", "x86_64"}:
                raise RuntimeError(f"{name} must contain both arm64 and x86_64.")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged_app)
        run("/usr/bin/codesign", "--verify", "--strict", staged_driver)
        components = staging / "components.plist"
        run("/usr/bin/pkgbuild", "--analyze", "--root", payload, components)
        settings = plistlib.loads(components.read_bytes())
        def configure(items):
            for item in items:
                item.update(BundleIsRelocatable=False, BundleHasStrictIdentifier=True, BundleOverwriteAction="upgrade")
                configure(item.get("ChildBundles", []))
        configure(settings)
        components.write_bytes(plistlib.dumps(settings))
        hooks = staging / "scripts"
        shutil.copytree(ROOT / "packaging/pkg-scripts", hooks)
        for path in hooks.iterdir():
            path.chmod(0o755)
        component = staging / "MonoMic-components.pkg"
        run("/usr/bin/pkgbuild", "--root", payload, "--component-plist", components,
            "--identifier", "local.motu.monomic.package", "--version", bundle_version,
            "--install-location", "/", "--ownership", "recommended", "--scripts", hooks, component)
        installer_resources = staging / "resources"
        shutil.copytree(ROOT / "packaging/resources", installer_resources)
        shutil.copy2(ROOT / "LICENSE", installer_resources / "LICENSE.txt")
        if args.unsigned:
            welcome = installer_resources / "welcome.html"
            welcome.write_text(welcome.read_text().replace("<h2>Mono Mic</h2>",
                "<h2>Mono Mic — unsigned preview</h2><p><b>This preview has not been Developer ID signed or notarized by Apple. It is intended for developer testing.</b></p>"))
        distribution = ET.Element("installer-gui-script", {"minSpecVersion": "2"})
        ET.SubElement(distribution, "title").text = "Mono Mic" + (" — Unsigned Preview" if args.unsigned else "")
        ET.SubElement(distribution, "welcome", {"file": "welcome.html"})
        ET.SubElement(distribution, "license", {"file": "LICENSE.txt"})
        ET.SubElement(distribution, "conclusion", {"file": "conclusion.html"})
        ET.SubElement(distribution, "options", {"customize": "never", "rootVolumeOnly": "true", "hostArchitectures": "arm64,x86_64"})
        ET.SubElement(distribution, "domains", {"enable_localSystem": "true", "enable_currentUserHome": "false", "enable_anywhere": "false"})
        volume = ET.SubElement(distribution, "volume-check")
        allowed = ET.SubElement(volume, "allowed-os-versions")
        ET.SubElement(allowed, "os-version", {"min": "13.0"})
        outline = ET.SubElement(distribution, "choices-outline")
        ET.SubElement(outline, "line", {"choice": "monomic"})
        choice = ET.SubElement(distribution, "choice", {"id": "monomic", "visible": "false", "title": "Mono Mic"})
        ET.SubElement(choice, "pkg-ref", {"id": "local.motu.monomic.package"})
        ET.SubElement(distribution, "pkg-ref", {"id": "local.motu.monomic.package", "version": bundle_version}).text = component.name
        distribution_path = staging / "Distribution.xml"
        ET.ElementTree(distribution).write(distribution_path, encoding="utf-8", xml_declaration=True)
        package = output / f"{basename}.pkg"
        command = ["/usr/bin/productbuild", "--distribution", distribution_path, "--package-path", staging,
                   "--resources", installer_resources]
        if not args.unsigned:
            command += ["--sign", installer_identity, "--timestamp"]
        run(*command, package)
        notarized = False
        if not args.unsigned:
            result = run("/usr/bin/xcrun", "notarytool", "submit", package, "--keychain-profile", notary_profile,
                         "--wait", "--output-format", "json", capture=True)
            submission = json.loads(result.stdout)
            (output / "notarization.json").write_text(json.dumps(submission, indent=2) + "\n")
            if submission.get("status") != "Accepted":
                raise RuntimeError("Notarization was not accepted; inspect notarization.json before distributing.")
            run("/usr/bin/xcrun", "stapler", "staple", package)
            run("/usr/bin/xcrun", "stapler", "validate", package)
            run("/usr/sbin/spctl", "--assess", "--type", "install", "--verbose=2", package)
            notarized = True
        run(sys.executable, "tests/release_tests.py", "--package", package)
        source_hashes = archive_source(output / f"MonoMic-{args.version}-source.zip", args.version)
        with zipfile.ZipFile(output / f"MonoMic-{args.version}-uninstall.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for source, name in [(ROOT / "scripts/uninstall.sh", "Uninstall Mono Mic.command"),
                                 (ROOT / "packaging/pkg-scripts/common.sh", "common.sh"),
                                 (ROOT / "LICENSE", "LICENSE"), (ROOT / "docs/INSTALLATION.md", "README.md")]:
                info_zip = zipfile.ZipInfo(f"MonoMic-uninstall/{name}")
                info_zip.external_attr = (0o100755 if name.endswith((".command", ".sh")) else 0o100644) << 16
                archive.writestr(info_zip, source.read_bytes())
        manifest = {"version": args.version, "bundleVersion": info["CFBundleVersion"],
                    "createdUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    "developerIDSigned": not args.unsigned, "notarized": notarized,
                    "releaseType": "unsigned developer preview" if args.unsigned else "notarized beta",
                    "minimumMacOS": "13.0", "architectures": architectures,
                    "unitTestsRun": not args.skip_tests, "packageFixtureTests": "Passed",
                    "sourceSHA256": source_hashes,
                    "assets": {p.name: sha256(p) for p in sorted(output.iterdir()) if p.is_file()}}
        (output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        notes = ("# Mono Mic " + args.version + "\n\n" +
                 ("**Unsigned developer preview. This installer is not Developer ID signed or Apple notarized.**\n\n" if args.unsigned else "Developer ID signed and Apple notarized.\n\n") +
                 "Requires macOS 13 or later; Intel and Apple silicon.\n\n"
                 "Install the .pkg, then open Mono Mic from Applications, choose your interface/input, and allow microphone access. "
                 "Select Mono Mic in your voice app. Settings can be closed while the service runs.\n\n"
                 "Installation briefly restarts macOS audio. Other BlackHole devices and saved audio settings are preserved.\n\n"
                 "Complete corresponding source and build scripts are in the matching source.zip asset. "
                 "See LICENSE and THIRD_PARTY_NOTICES.md in that archive.\n\n"
                 "Uninstall with /Library/Application Support/MonoMic/Uninstall Mono Mic.command or the paired files in uninstall.zip. "
                 "Saved audio settings are kept.\n\n"
                 "Beta validation is strongest on MOTU UltraLite-mk5; other interfaces, Intel runtime behavior and all supported macOS versions still need wider testing.\n")
        (output / "RELEASE_NOTES.md").write_text(notes)
        (output / "SHA256SUMS").write_text("".join(f"{sha256(p)}  {p.name}\n" for p in sorted(output.iterdir()) if p.is_file() and p.name != "SHA256SUMS"))
        with zipfile.ZipFile(output / f"MonoMic-{args.version}-source.zip") as archive:
            assert archive.testzip() is None
            assert not any(".noindex/" in n or "/xcuserdata/" in n for n in archive.namelist())
        # Expose a release directory only after every requested check passes.
        with tempfile.TemporaryDirectory(prefix=".release-assets.", dir=destination.parent) as prepared_directory:
            prepared = Path(prepared_directory) / "assets"
            shutil.copytree(output, prepared)
            if destination.exists():
                destination.rmdir()
            prepared.rename(destination)
        print(f"Release assets prepared: {destination}")
        print("Unsigned preview; public signing/notarization remains pending." if args.unsigned else "Signing, notarization and package checks passed.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Release preparation stopped: {error}", file=sys.stderr)
        raise SystemExit(1)
