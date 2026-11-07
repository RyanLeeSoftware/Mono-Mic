# Changes

## 0.8.0-beta.1

- Package the universal settings app and mono virtual driver for GitHub releases.
- Let new users install without an existing saved audio configuration.
- Register the login service for the user opening the app, rather than the
  administrator/Installer account.
- Ask new users to choose an interface instead of applying a MOTU-specific input.
- Preserve audio and startup settings during upgrades.
- Move an older user-local development app to Trash once the installed service
  starts routing audio.
- Include an uninstaller, matching source archive, third-party notices, checksums
  and a release manifest.
- Provide Developer ID signing/notarization tooling; initial preview installers
  remain unsigned until the required Apple membership and certificates exist.

Beta limits: live hardware validation is strongest on MOTU UltraLite-mk5.
Broader compatibility and clean-Mac installation testing remain outstanding.
