Upstream: see UPSTREAM. License: GPL-3.0 (LICENSE).

Local changes in BlackHole.c:
- A mono device's preferred stereo pair points to channel 1 twice, rather than
  advertising a nonexistent channel 2.
- A mono channel is labeled Mono, rather than Left.

The separately compiled configuration in driver/MonoDriver.c uses one channel,
11 standard rates from 8 to 192 kHz, a unique bundle ID, device UID and factory
UUID, and a distinct name. The helper requests the selected interface's nominal
rate and waits for Core Audio to complete the asynchronous driver change.
The existing BlackHole 2ch installation is not replaced.
The device is displayed as Mono Mic. Its original MOTUMonoMic_UID and bundle
identifier remain stable across this display-name change.
