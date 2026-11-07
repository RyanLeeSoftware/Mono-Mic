#!/bin/bash
# Source this from project scripts; do not change the user's global xcode-select.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    selected_developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null || true)
    if [ -x "$selected_developer_dir/usr/bin/xcodebuild" ]; then
        export DEVELOPER_DIR="$selected_developer_dir"
    elif [ -x '/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild' ]; then
        export DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer'
    else
        printf 'Install full Xcode, or set DEVELOPER_DIR to its Contents/Developer folder.\n' >&2
        return 1
    fi
fi
