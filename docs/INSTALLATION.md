# Install Mono Mic

Mono Mic requires macOS 13 or later. Release installers contain both Intel
and Apple silicon code. An audio interface with Core Audio input support is
required for interface routing; not every interface has been tested.

## Unsigned previews

The first developer preview is **not Developer ID signed or Apple notarized**.
Its filename includes `UNSIGNED`, and the installer identifies it as a preview.
macOS may block a downloaded unsigned installer. This is not a polished public
installer yet. You can build the source locally with Xcode instead. Do not
disable Gatekeeper or other macOS security protections to install it.

## Installation

1. Download the `.pkg` from the same GitHub release as its source archive and
   `SHA256SUMS`. Verify downloaded files with `shasum -a 256 -c SHA256SUMS` when
   all the listed assets are present, or compare the individual file's SHA-256.
2. Open the installer and complete macOS administrator authorization. It installs
   `/Applications/Mono Mic.app`, the Mono Mic HAL driver, and the uninstaller.
   macOS audio briefly stops while audio devices reload.
3. Open **Mono Mic** from Applications. Choose your audio interface and the input
   carrying your microphone. First launch registers the background service for
   your own account. No service is registered for the Installer's root account.
4. Allow microphone access for Mono Mic Service when macOS asks. Choose a buffer
   supported by the interface. Start with 128 samples if you are unsure; smaller
   buffers reduce latency but give the system less scheduling headroom.
5. Choose **Mono Mic** as the input in Discord or another voice app. You can close
   settings while the service runs. **Run service at startup** starts the service
   at login while settings stay closed. It saves immediately and controls the
   next login; unchecking it does not stop the current microphone session.

Settings save automatically. Existing interface, input, buffer, gain and startup
choices are preserved during upgrades. A changed input-channel layout may need
confirmation. The app follows the interface's sample rate; the interface and
virtual device still require small clock-drift correction.

## Upgrading a development installation

The GitHub installer uses `/Applications`, whereas early development builds
used `~/Applications`. Open the new app in `/Applications` after installing so
it can update your user service to the new location. Once the new service is
routing audio, the app moves the older development copy to Trash. Your saved
audio choices stay in `~/Library/Application Support/MonoMic/settings.plist`.

## Uninstalling

Open `/Library/Application Support/MonoMic/Uninstall Mono Mic.command` and confirm
the uninstall. Terminal requests administrator authorization. Alternatively,
extract the release's `uninstall.zip` and keep `Uninstall Mono Mic.command` and
`common.sh` together before opening the command file.

The uninstaller removes the app, its own HAL driver, its login agents and old
user-local Mono Mic app copies. Audio briefly stops. It keeps saved audio
settings and other BlackHole devices. The `--dry-run` option lists the planned
removal without changing anything.

## Beta testing limits

Live testing has focused on a MOTU UltraLite-mk5. Broader interface, Intel Mac,
macOS-version, sleep/wake and reconnect testing is still needed. Mono Mic adds
no noise suppression or echo cancellation; these are controlled by your voice
app. Its current linear clock interpolator can slightly attenuate treble, so
the route is not bit-perfect.
