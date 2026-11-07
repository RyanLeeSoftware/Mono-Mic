#!/bin/bash
# Shared by installer hooks and the uninstaller. No actions run when sourced.
bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}
check_bundle() {
    local path="$1" expected="$2"
    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ -L "$path" ] || [ "$(bundle_id "$path")" != "$expected" ]; then
            printf 'Refusing to replace or remove an unrelated item: %s\n' "$path" >&2
            return 1
        fi
    fi
}
check_parents() {
    local root="$1" relative
    for relative in Applications Library Library/Audio Library/Audio/Plug-Ins Library/Audio/Plug-Ins/HAL \
        'Library/Application Support' 'Library/Application Support/MonoMic'; do
        if [ -L "$root/$relative" ]; then
            printf 'Refusing to follow a symbolic-link installation directory: %s\n' "$root/$relative" >&2
            return 1
        fi
    done
}
stop_managed_apps() {
    local pid executable app uid
    while read -r pid executable; do
        case "$executable" in
            */Mono\ Mic.app/Contents/MacOS/MonoMic)
                app="${executable%/Contents/MacOS/MonoMic}" ;;
            */Mono\ Mic.app/Contents/Library/LoginItems/Mono\ Mic\ Service.app/Contents/MacOS/MonoMicService)
                app="${executable%/Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService}" ;;
            *) continue ;;
        esac
        [ "$(bundle_id "$app")" = 'local.motu.monomic' ] || continue
        uid=$(/bin/ps -p "$pid" -o uid= 2>/dev/null | /usr/bin/tr -d ' ') || true
        if [ -n "$uid" ]; then /bin/launchctl bootout "gui/$uid/local.motu.monomic.agent" 2>/dev/null || true; fi
        /bin/kill -TERM "$pid" 2>/dev/null || true
    done < <(/bin/ps -axo pid=,comm=)
}
