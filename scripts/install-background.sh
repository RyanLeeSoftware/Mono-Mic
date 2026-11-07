#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="${1:-$PWD/${MONOMIC_BUILD_DIR:-build.noindex}/Mono Mic.app}"
app_target="$HOME/Applications/Mono Mic.app"
job_path="$HOME/Library/LaunchAgents/local.motu.monomic.agent.plist"
job_domain="gui/$(id -u)"
job_label='local.motu.monomic.agent'
binary_relative='Contents/MacOS/MonoMic'
service_relative='Contents/Library/LoginItems/Mono Mic Service.app/Contents/MacOS/MonoMicService'
lsregister='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
backup_root="$HOME/Library/Application Support/MonoMic/Backups.noindex"
/usr/bin/codesign --verify --strict "$source_app"
/usr/bin/codesign --verify --strict "$source_app/Contents/Library/LoginItems/Mono Mic Service.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" = 'local.motu.monomic'
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/MonoMic" "$backup_root"
if [ -e "$app_target" ]; then
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_target/Contents/Info.plist")" = 'local.motu.monomic'
fi
# Import the previous app's selected device/channel and the user's 64-frame choice.
# Existing settings always take precedence, including future buffer changes.
"$source_app/$binary_relative" --migrate 64
/bin/launchctl bootout "$job_domain/$job_label" 2>/dev/null || true
# Stop only our earlier audio/UI processes before handing the device to the agent.
python3 - "$source_app/$binary_relative" "$PWD/build/Mono Mic.app/$binary_relative" "$app_target/$binary_relative" <<'PY'
import os,signal,subprocess,sys,time
paths=set(sys.argv[1:])
for line in subprocess.check_output(['/bin/ps','-axo','pid=,comm='],text=True).splitlines():
    pieces=line.strip().split(None,1)
    if len(pieces)==2 and pieces[1] in paths:
        try: os.kill(int(pieces[0]),signal.SIGTERM)
        except ProcessLookupError: pass
time.sleep(0.25)
PY
# Keep staging and rollback copies outside application discovery.
stage=$(/usr/bin/mktemp -d "$backup_root/install.XXXXXX")
/usr/bin/ditto "$source_app" "$stage/Mono Mic.app"
if [ -e "$app_target" ]; then /bin/mv "$app_target" "$stage/previous.app"; fi
if ! /bin/mv "$stage/Mono Mic.app" "$app_target"; then
    if [ -e "$stage/previous.app" ]; then /bin/mv "$stage/previous.app" "$app_target"; fi
    exit 1
fi
if [ ! -e "$stage/previous.app" ]; then /bin/rmdir "$stage"; fi
# Only the installed settings app should appear in macOS app lists.
"$lsregister" -u "$source_app/Contents/Library/LoginItems/Mono Mic Service.app" >/dev/null 2>&1 || true
"$lsregister" -u "$source_app" >/dev/null 2>&1 || true
if [ -e "$stage/previous.app" ]; then
    "$lsregister" -u "$stage/previous.app/Contents/Library/LoginItems/Mono Mic Service.app" >/dev/null 2>&1 || true
    "$lsregister" -u "$stage/previous.app" >/dev/null 2>&1 || true
fi
"$lsregister" -f "$app_target"
python3 - "$job_path" "$app_target/$service_relative" "$HOME/Library/Logs/MonoMic" <<'PY'
import os,plistlib,sys
path,binary,logs=sys.argv[1:]
run_at_startup=True
if os.path.exists(path):
    with open(path,'rb') as f: previous=plistlib.load(f)
    if previous.get('Label')!='local.motu.monomic.agent':
        raise RuntimeError('Refusing to replace an unrelated login agent.')
    run_at_startup=previous.get('RunAtLoad',True)
job={'Label':'local.motu.monomic.agent','ProgramArguments':[binary,'--agent'],
     'RunAtLoad':run_at_startup,'KeepAlive':{'AfterInitialDemand':True,'SuccessfulExit':False},'ThrottleInterval':10,
     'LimitLoadToSessionType':'Aqua','ProcessType':'Interactive',
     'StandardOutPath':logs+'/agent.log','StandardErrorPath':logs+'/agent-error.log'}
temporary=path+'.new'
with open(temporary,'wb') as f: plistlib.dump(job,f)
os.chmod(temporary,0o644)
os.replace(temporary,path)
PY
/usr/bin/plutil -lint "$job_path"
/bin/launchctl enable "$job_domain/$job_label"
/bin/launchctl bootstrap "$job_domain" "$job_path"
/bin/launchctl kickstart "$job_domain/$job_label"
printf 'Installed %s\nBackground service started; startup preference preserved.\n' "$app_target"
