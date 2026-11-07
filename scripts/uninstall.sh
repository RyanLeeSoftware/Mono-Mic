#!/bin/bash
set -euo pipefail
script_directory="$(cd "$(dirname "$0")" && pwd -P)"
if [ -f "$script_directory/common.sh" ]; then
    source "$script_directory/common.sh"
else
    source "$script_directory/../packaging/pkg-scripts/common.sh"
fi
volume=/; dry_run=false; confirmed=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --volume) [ "$#" -ge 2 ] || exit 2; volume="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        --yes) confirmed=true; shift ;;
        *) printf 'Usage: %s [--dry-run] [--yes] [--volume /mounted/volume]\n' "$0" >&2; exit 2 ;;
    esac
done
[[ "$volume" = /* ]] || { printf 'The volume path must be absolute.\n' >&2; exit 2; }
root="$(cd "$volume" && pwd -P)"; root="${root%/}"
check_parents "$root"
app="$root/Applications/Mono Mic.app"
driver="$root/Library/Audio/Plug-Ins/HAL/MOTUMonoMic.driver"
support="$root/Library/Application Support/MonoMic"
check_bundle "$app" 'local.motu.monomic'
check_bundle "$driver" 'local.motu.monomic.driver'
if $dry_run; then
    printf 'Would remove Mono Mic.app, its Mono Mic driver and installed uninstaller from: %s\n' "${root:-/}"
    printf 'On the running system, Mono Mic login agents and old user-local app copies are also removed.\nAudio settings and other BlackHole devices are preserved.\n'
    exit 0
fi
if ! $confirmed; then
    printf 'Uninstall Mono Mic and its virtual driver? Audio will briefly stop. Saved audio settings are kept. [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) printf 'Cancelled.\n'; exit 0 ;; esac
fi
if [ -z "$root" ] && [ "$EUID" -ne 0 ]; then
    exec /usr/bin/sudo /bin/bash "$0" --yes
fi
had_driver=false; [ ! -d "$driver" ] || had_driver=true
if [ -z "$root" ]; then
    stop_managed_apps
    while read -r username uid; do
        [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 500 ] || continue
        home_directory=$(/usr/bin/dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null) || continue
        home_directory="${home_directory#NFSHomeDirectory: }"
        [[ "$home_directory" = /* ]] || continue
        job="$home_directory/Library/LaunchAgents/local.motu.monomic.agent.plist"
        if [ -f "$job" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$job" 2>/dev/null)" = 'local.motu.monomic.agent' ]; then
            /bin/launchctl bootout "gui/$uid/local.motu.monomic.agent" 2>/dev/null || true
            /bin/rm "$job"
        fi
        legacy="$home_directory/Applications/Mono Mic.app"
        if [ ! -L "$legacy" ] && [ "$(bundle_id "$legacy")" = 'local.motu.monomic' ]; then /bin/rm -rf "$legacy"; fi
    done < <(/usr/bin/dscl . -list /Users UniqueID)
fi
/bin/rm -rf "$app" "$driver"
/bin/rm -f "$support/Uninstall Mono Mic.command" "$support/common.sh"
/bin/rmdir "$support" 2>/dev/null || true
if [ -z "$root" ]; then
    /usr/sbin/pkgutil --forget local.motu.monomic.package >/dev/null 2>&1 || true
    if $had_driver; then /usr/bin/killall coreaudiod 2>/dev/null || true; fi
fi
printf 'Mono Mic uninstalled. Saved audio settings and other virtual audio drivers were preserved.\n'
