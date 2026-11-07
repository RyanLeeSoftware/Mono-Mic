#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode-env.sh
build_dir="${MONOMIC_BUILD_DIR:-build.noindex}"
mkdir -p "$build_dir/TestResults"
build_dir="$(cd "$build_dir" && pwd -P)"
result_bundle="$build_dir/TestResults/$(date +%Y%m%d-%H%M%S)-$$.xcresult"
/usr/bin/xcodebuild -quiet -project MonoMic.xcodeproj -scheme 'Mono Mic Tests' \
    -configuration Debug -destination "platform=macOS,arch=$(/usr/bin/uname -m)" \
    -derivedDataPath "$build_dir/DerivedData" "SYMROOT=$build_dir/xcode" \
    -resultBundlePath "$result_bundle" test
printf 'Test results: %s\n' "$result_bundle"
if [ "${MONOMIC_LIVE_RATE_TEST:-0}" = 1 ]; then
    cp "$build_dir/xcode/Debug/audio-device-control" "$build_dir/audio-device-control"
    MONOMIC_BUILD_DIR="$build_dir" python3 tests/rate_follow_live.py
fi
