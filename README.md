# Mono Mic

A lightweight native macOS helper for routing one audio interface input to
**Mono Mic**, a real one-channel virtual audio device for Discord/Vencord.
The virtual driver is a separately named mono build of BlackHole; existing
BlackHole devices are not replaced. All audio stays on the Mac.

## GitHub release installation

The release installer places the app in `/Applications` and installs its virtual
audio driver. Open Mono Mic after installation to register the service for your
user account, choose an interface/input, and allow microphone access. Settings
stay closed when the service starts at login.

Initial developer preview packages are explicitly **unsigned and unnotarized**.
See [installation and uninstall instructions](docs/INSTALLATION.md) and the
[release build guide](docs/RELEASING.md). Build an unsigned preview locally with
`bash scripts/release.sh --unsigned`. These steps prepare local assets; publishing
to GitHub is separate.

## Development installation from source

1. Set your audio interface to the rate you want to use. Mono Mic automatically
   follows it without changing the interface's rate. Supported rates are 8,
   16, 22.05, 24, 32, 44.1, 48, 88.2, 96, 176.4 and 192 kHz.
2. Install the driver once: `bash scripts/install-driver.sh`. macOS requires an
   administrator password. Installation briefly restarts Core Audio.
3. Run `bash scripts/install-background.sh` to install **Mono Mic** in your user
   Applications folder and enable its per-user login service. Open Mono Mic once
   to allow microphone access and choose your interface, input and buffer size.
   Changes are saved and applied automatically; there is no Start/Stop button.
4. Buffers are listed as **32 samples**, **64 samples**, **128 samples**, or **256 samples**.
   The **Mic gain** slider ranges from -36 to +12 dB and is saved automatically.
   0 dB keeps the original level; negative values reduce it. Gain changes apply
   live with a short ramp, without restarting capture or adding audio latency.
   In Discord → Voice & Video → Input Device select
   **Mono Mic**. For the first listening test, disable automatic gain,
   noise suppression and echo cancellation, and use headphones.
5. Close or quit the settings app whenever you like. The separate audio service
   continues running and restarts after a crash. **Run service at startup**
   controls whether it starts automatically when you log in; it never opens
   settings. The checkbox saves immediately and affects the next login without
   interrupting your current microphone session. Reopening Mono Mic starts the
   service manually even when startup is unchecked. App updates preserve this choice.
   The installed app and service live on the internal drive, so the project drive
   does not need to be mounted. The settings window has standard close, minimize
   and zoom buttons; closing it quits settings and removes its running Dock icon.
   The service keeps a microphone icon in the menu bar, with status information
   and **Open Settings…**. It does not have a Dock icon. **Quit** in that
   menu stops capture and removes the menu bar icon. It stays stopped for the
   current session until you reopen Mono Mic. Your startup choice remains saved,
   and unexpected service failures still restart it after it has been started.

Inputs use the device's channel names, without a USB prefix. Identical names get
an input-number suffix so they can be distinguished. Loopback channels can make
Core Audio channel numbers differ from physical socket numbers; use the channel
names and verify the meter against your actual source. Device UID, input and buffer are saved in
`~/Library/Application Support/MonoMic/settings.plist`. If the saved interface
is unplugged, the service waits for it and resumes automatically. It does not
fall back to another microphone. If a rate change alters other channel counts,
the selected input can continue when its unique name remains at the same index.
A changed, removed, reordered or ambiguous selected input requires confirmation.

## Latency and resources

- An on-demand native AppKit settings window and a separate menu bar audio
  service using two Apple HAL audio units; no Electron or network stack.
- Captures one selected channel as Float32, preserving unity gain.
- Requests 32, 64, 128 or 256 samples per buffer. Actual sizes are displayed.
- The capture format and virtual device use the interface's actual nominal rate.
  There is no fixed-rate conversion to 48 kHz. Small adaptive interpolation
  remains necessary because the physical device and virtual driver have separate
  clocks; receiving applications may also perform their own conversion.
- A preallocated 32 KiB single-producer/single-consumer ring uses lock-free
  atomics. The callbacks do not allocate, log, access files, or take app locks.
- The bridge targets **two blocks plus two lookahead samples**, including when
  callback timing is missing or stale. With valid timing, the target
  accounts for the position between capture callbacks, so it is distinct from
  raw queued samples. At 48 kHz the normalized target is about **5.4 ms at
  128 samples**, **2.7 ms at 64 samples**, or **1.4 ms at 32 samples**.
  Device, Core Audio and receiving-app buffers add further latency.
- Settings show **Resulting Latency** as an estimated input-to-Mono-Mic delay,
  including the selected input stream's device latency and safety offset,
  the smoothed actual bridge queue occupancy, and the virtual output buffer and reported latency.
  The queue already contains the input block, which is not added twice.
  The estimate uses actual queue occupancy so reducing a normalized target alone
  cannot produce a misleading latency reduction. It excludes receiving-app buffering and network delay;
  it is not an acoustic round-trip measurement. Missing driver timing is shown
  as unavailable. Detailed queue and dropout counters remain in `--status`.
- Tiny adaptive interpolation corrects clock drift between the physical device
  and virtual device. Proportional/integral queue control learns sustained clock
  mismatch while accounting for callback arrival timing. A bounded atomic
  snapshot transfers the input timing without waiting for the capture thread.
  Startup discards excess queued
  samples before playback begins. The helper reports underruns, overruns,
  resyncs, the normalized queue target (`queueTargetFrames`), the smoothed raw
  queue occupancy (`queueLatencyFrames`) and current correction in parts per million.
- A bounded backlog is discarded after a scheduling stall rather than allowing
  latency to accumulate indefinitely.
- The post-gain dBFS meter animates at 30 Hz with fast attack and smooth release.
  One small shared-memory page carries its level using lock-free atomics, so
  animation does not require high-frequency IPC or file access. Animation pauses
  while the window is hidden or minimized; no meter UI runs when settings is quit.
- Health checks run every two seconds with timer tolerance. Status requests
  are sent only while the settings window is visible. The service uses AppKit's
  event loop for its menu bar and normal autorelease-pool handling.
- Device removal, sleep-related stalls and audio configuration changes trigger
  reconnection using the saved settings. Sample-rate notifications immediately
  trigger reconnection and an asynchronous virtual-device rate change. The
  two-second health check also retries after a failed or aborted change. A rate
  change can briefly interrupt audio while Core Audio reconfigures its clients.
  Buffer settings are restored on a graceful service shutdown
  when they still match the helper's requested values.

The driver exposes Float32 mono at the selected interface's sample rate. It avoids the multi-channel-to-mono
conversion implicated in the Discord issue; it does not force the entire macOS
audio system to use integer audio. Actual Discord call quality needs a listening
test on the user's hardware.

## Build and validate

Open **MonoMic.xcodeproj** in Xcode. The project contains native targets for the
settings app, menu bar service, virtual driver, shared audio engine, XCTest
bundle, and developer tools. It builds without a package manager or external
project generator and supports macOS 13 or later.

| Shared scheme | Development workflow |
| --- | --- |
| **Mono Mic** | Cmd-R opens settings; Cmd-B also builds the embedded service, driver and tools. Cmd-U runs the tests. |
| **Mono Mic Service** | Close installed settings and quit the installed service from its menu first, then Cmd-R debugs the audio service. Open Settings opens the neighboring development app. |
| **Mono Mic Tests** | Cmd-U runs the existing latency, pipeline, audio-control, driver and settings checks as five XCTest cases. |
| **Audio Probe** | Cmd-R prints Core Audio devices and their input channels. |

The settings scheme communicates with a running service. To debug audio-engine
changes, use **Mono Mic Service** after quitting the installed instance; both use
the same saved settings and a lock prevents simultaneous capture. After stopping
the debug service, reopen the installed Mono Mic app to resume the login service.
The service has its own small entry point and does not compile the settings UI.

Debug builds include symbols and support the Xcode debugger. Use the Release
configuration or Product → Profile for CPU and latency measurements. Local builds
use ad-hoc signing; configure your development team under Signing & Capabilities
when setting up certificate-based signing. Microphone access may be requested
for a newly signed development service. Tests keep assertions enabled in both
configurations and optimize the C++ clock simulations.
The test bundle targets macOS 14 or later to match current Xcode's XCTest
framework; the app and driver retain their macOS 13 minimum.

Native products are in `build.noindex/xcode/Debug` or `Release`, so development
copies stay out of macOS app searches. Builds do not install the app or driver.
To install a specific Debug build after building it in Xcode:

```sh
bash scripts/install-background.sh "$PWD/build.noindex/xcode/Debug/Mono Mic.app"
bash scripts/install-driver.sh "$PWD/build.noindex/xcode/Debug/MOTUMonoMic.driver"
```

Driver installation requires administrator authorization and restarts Core Audio.
The command-line scripts now use the same Xcode project:

```sh
bash scripts/build.sh
bash scripts/test.sh
build.noindex/audio-probe
```

`build.sh` defaults to Release and exports app, driver and tools to `build.noindex`
for the existing installers. Use `MONOMIC_CONFIGURATION=Debug` for a Debug export.
`test.sh` runs XCTest and saves a result bundle under `build.noindex/TestResults`;
the same results are available in Xcode's Test navigator. Full Xcode is required.
The scripts locate `/Applications/Xcode.app` when the active command-line tools
selection points to the standalone tools; `DEVELOPER_DIR` can select another
installation. They do not change the global developer-tools selection.

The app icon uses a handheld dynamic mic and cable on a Discord Blurple
(`#5865F2`) tile, with a monochrome version of the same silhouette in the menu bar.
The app icon is `resources/MonoMic.icns`, with its full-resolution preview in
`resources/MonoMic.png`. The matching 18-point menu bar artwork is a vector PDF,
`resources/MenuBarIcon.pdf`; AppKit treats it as a template for light, dark and
selected menu bar appearances. Both use the same original microphone silhouette
in `scripts/make-icon.mm`. Run `bash scripts/build-icons.sh` to regenerate the
iconset, ICNS, PNG and PDF after editing the artwork. Regular Xcode builds consume
the saved assets without regenerating them. Local builds are not notarized for distribution.
Installer rollback copies live in
`~/Library/Application Support/MonoMic/Backups.noindex`, so macOS app searches
show the installed app instead of additional development and backup copies.
The background installer copies the app into `~/Applications/Mono Mic.app` and
creates `~/Library/LaunchAgents/local.motu.monomic.agent.plist`. No administrator
password is needed for this per-user service. Its microphone permission is
handled by macOS. The audio process is bundled as **Mono Mic Service.app** inside
the settings app and has its own accessory-app identity, so opening settings
does not activate a hidden audio process. Allow **Mono Mic Service** microphone
access when prompted. Its menu also provides **Microphone Permissions…** if
access needs to be restored. A newly rebuilt ad-hoc binary may need permission
again. Settings itself no longer requests microphone access.

Read the background service's counters and current configuration without
opening the settings window or recording audio:

```sh
"$HOME/Applications/Mono Mic.app/Contents/MacOS/MonoMic" --status
```

The same graceful quit action is available for local lifecycle checks:

```sh
"$HOME/Applications/Mono Mic.app/Contents/MacOS/MonoMic" --quit-service
```

Tests cover unity gain, clipping, invalid input samples, ring overflow recovery,
concurrent publication, ten-minute independent-clock simulations at ±100 and
±350 ppm, delayed callbacks at multiple phases and mismatched buffer sizes,
timing-aware and conservative modes, unavailable timing and concurrent timing publication,
mono device metadata, exact driver ring-buffer wraparound, and persistence
of the interface/input, buffer and gain choices. Audio control tests also verify
attenuation, gain ramps without stream resets, meter ballistics, and meter data
exchange between separate processes. Driver tests exercise rate transitions and
mono formats at all 11 supported rates; gain ramps and latency are checked at
each rate, and additional drift simulations cover 44.1, 96 and 192 kHz.
POSIX shared-memory tests require a normal
macOS process context rather than a sandbox that denies shared memory.

An optional live rate-following test requires the updated app and driver to be
installed, Mono Mic running, and an idle BlackHole 2ch device:

```sh
MONOMIC_LIVE_RATE_TEST=1 bash scripts/test.sh
```

It temporarily pauses the login agent and runs the installed service with
isolated settings and BlackHole as its source. It checks matching device rates,
advancing capture/render counters and error counters at 44.1, 88.2, 96, 176.4,
192 and 48 kHz, then restores BlackHole's original rate and the original agent.
It does not change the selected physical interface's rate or saved settings.

## Remove

Run `bash scripts/uninstall-background.sh` to disable the login service. This
preserves the app, selected settings and driver. To also remove the virtual
device, run `bash scripts/uninstall-driver.sh`; Core Audio briefly restarts.

## Source and license

The original Mono Mic application/project code is GPL-3.0-or-later. Its BlackHole
component is governed by the upstream GNU GPL version 3 license and notices.
See [third-party notices](THIRD_PARTY_NOTICES.md). BlackHole is Copyright © 2019 Existential Audio
Inc.; see `vendor/BlackHole/LICENSE`, `UPSTREAM` and `MODIFICATIONS.md` for its
pinned revision and the mono metadata changes. The app and driver embed the
license. The driver configuration and identity are in `driver/MonoDriver.c`.
