#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode-env.sh
icon_tools="${MONOMIC_BUILD_DIR:-build.noindex}/icon-tools"
mkdir -p "$icon_tools"
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -framework AppKit \
    scripts/make-icon.mm -o "$icon_tools/make-icon"
"$icon_tools/make-icon" "$PWD/resources"
/usr/bin/iconutil -c icns resources/MonoMic.iconset -o resources/MonoMic.icns
printf 'Updated app artwork and menu bar template in resources/.\n'
