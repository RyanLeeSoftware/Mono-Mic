#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_driver="${1:-$PWD/${MONOMIC_BUILD_DIR:-build.noindex}/MOTUMonoMic.driver}"
if [ "$EUID" -ne 0 ]; then
    printf 'This installs the virtual audio driver and restarts Core Audio.\n'
    exec sudo /bin/bash "$PWD/scripts/install-driver.sh" "$source_driver"
fi
target='/Library/Audio/Plug-Ins/HAL/MOTUMonoMic.driver'
/usr/bin/codesign --verify --strict "$source_driver"
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_driver/Contents/Info.plist")
test "$identifier" = 'local.motu.monomic.driver'
if [ -e "$target" ]; then
    existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")
    test "$existing" = 'local.motu.monomic.driver'
fi
stage=$(/usr/bin/mktemp -d '/Library/Audio/Plug-Ins/HAL/.MOTUMonoMic.XXXXXX')
/usr/bin/ditto "$source_driver" "$stage/MOTUMonoMic.driver"
/usr/sbin/chown -R root:wheel "$stage/MOTUMonoMic.driver"
/bin/chmod -R go-w "$stage/MOTUMonoMic.driver"
if [ -e "$target" ]; then /bin/mv "$target" "$stage/previous.driver"; fi
if ! /bin/mv "$stage/MOTUMonoMic.driver" "$target"; then
    if [ -e "$stage/previous.driver" ]; then /bin/mv "$stage/previous.driver" "$target"; fi
    exit 1
fi
if [ -e "$stage/previous.driver" ]; then
    printf 'Previous driver preserved at %s\n' "$stage/previous.driver"
else
    /bin/rmdir "$stage"
fi
/usr/bin/killall coreaudiod || true
printf 'Installed Mono Mic. Core Audio is restarting.\n'
