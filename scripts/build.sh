#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode-env.sh
build_dir="${MONOMIC_BUILD_DIR:-build.noindex}"
configuration="${MONOMIC_CONFIGURATION:-Release}"
case "$configuration" in Debug|Release) ;; *) printf 'Use MONOMIC_CONFIGURATION=Debug or Release.\n' >&2; exit 2 ;; esac
mkdir -p "$build_dir"
build_dir="$(cd "$build_dir" && pwd -P)"
/usr/bin/xcodebuild -quiet -project MonoMic.xcodeproj -scheme 'Mono Mic' \
    -configuration "$configuration" -destination "platform=macOS,arch=$(/usr/bin/uname -m)" \
    -derivedDataPath "$build_dir/DerivedData" "SYMROOT=$build_dir/xcode" build
# Export the historical installer paths from Xcode's configuration-specific products.
python3 - "$build_dir/xcode/$configuration" "$build_dir" <<'PYTHON'
from pathlib import Path
import plistlib,shutil,subprocess,sys,tempfile
products,destination=map(Path,sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='.export.',dir=destination) as staging:
    staging=Path(staging)
    for name,identifier in [('Mono Mic.app','local.motu.monomic'),('MOTUMonoMic.driver','local.motu.monomic.driver')]:
        source=products/name
        target=destination/name
        if target.exists():
            with (target/'Contents/Info.plist').open('rb') as f:
                if plistlib.load(f).get('CFBundleIdentifier')!=identifier:
                    raise RuntimeError(f'Refusing to replace an unrelated bundle: {target}')
        prepared=staging/name
        subprocess.run(['/usr/bin/ditto',str(source),str(prepared)],check=True)
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(prepared)],check=True)
        previous=staging/(name+'.previous')
        if target.exists(): target.rename(previous)
        try: prepared.rename(target)
        except Exception:
            if previous.exists(): previous.rename(target)
            raise
        print('Built:',target)
    for name in ['audio-probe','audio-device-control']:
        shutil.copy2(products/name,destination/name)
PYTHON
