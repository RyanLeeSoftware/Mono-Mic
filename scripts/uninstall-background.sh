#!/bin/bash
set -euo pipefail
job_path="$HOME/Library/LaunchAgents/local.motu.monomic.agent.plist"
job_domain="gui/$(id -u)"
/bin/launchctl bootout "$job_domain/local.motu.monomic.agent" 2>/dev/null || true
if [ -e "$job_path" ]; then
    test "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$job_path")" = 'local.motu.monomic.agent'
    /bin/rm "$job_path"
fi
printf 'Background helper disabled. Your audio settings and virtual driver are preserved.\n'
