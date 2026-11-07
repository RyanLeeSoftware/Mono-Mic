#!/bin/bash
set -euo pipefail
if [ "$EUID" -ne 0 ]; then exec sudo /bin/bash "$0"; fi
target='/Library/Audio/Plug-Ins/HAL/MOTUMonoMic.driver'
if [ ! -e "$target" ]; then exit 0; fi
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")
test "$identifier" = 'local.motu.monomic.driver'
/bin/rm -rf "$target"
/usr/bin/killall coreaudiod || true
printf 'Removed Mono Mic. Core Audio is restarting.\n'
