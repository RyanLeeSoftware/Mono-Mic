# GitHub releases

Release preparation builds local artifacts. It does not create a repository,
upload source, publish a release, install a driver, or change the running app.

## Build an unsigned preview

Full Xcode and its macOS SDK are required on the build Mac. End users do not need
Xcode or Python to install the resulting package.

```sh
bash scripts/release.sh --unsigned
```

The command runs XCTest, builds universal Release products, creates the installer,
tests the packaged hooks and uninstaller in temporary installation roots, and
creates an allowlisted source archive. Results go into `dist/0.8.0-beta.1/`.
The directory must be empty to avoid silently overwriting a prior release.
`--skip-tests` and `--skip-build` can reuse a build during packaging development;
the release manifest records whether XCTest was run by that invocation.

Assets include the clearly labeled unsigned `.pkg`, matching source `.zip`,
standalone uninstaller `.zip`, release notes, a manifest and `SHA256SUMS`.
The package includes only the app, its HAL driver, and its uninstall files.
It does not include saved settings, microphone recordings, development backups,
Xcode user state, signing certificates or build diagnostics.

The fixture checks execute the real packaged installer hooks and uninstall
script against temporary roots. They do not exercise a real administrator
installation or a reboot/login on a clean Mac. Those remain release acceptance
checks, along with testing other interfaces and supported Macs.

## Signing and notarization

Public Developer ID distribution requires Apple Developer Program membership.
An Apple Development certificate is not a substitute. Once enrolled, create
Developer ID Application and Developer ID Installer identities through Apple,
and store notarization credentials in a Keychain profile using `notarytool`.
Do not add passwords, certificates or private keys to the source repository.

```sh
export MONOMIC_APPLICATION_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export MONOMIC_INSTALLER_IDENTITY='Developer ID Installer: YOUR NAME (TEAMID)'
export MONOMIC_NOTARY_PROFILE='monomic-notary'
bash scripts/release.sh --output dist/0.8.0-beta.1-signed
```

Signed mode signs the nested service, settings app and driver in order, creates
a Developer ID Installer-signed package, submits it to Apple's notary service,
requires an Accepted result, staples and validates the package ticket, and runs
Gatekeeper assessment. It stops on signing/notarization failure. These paths
cannot be fully validated until the required certificates and membership exist.

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates),
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Publish to GitHub

1. Review the release diff and version the complete source. Include the vendored
   BlackHole revision and modification notes. Use a tag matching the release,
   initially `v0.8.0-beta.1`.
2. Verify the package on a clean Mac/user account: install, microphone permission,
   interface selection, app closure, service-only startup, updates, unplug/replug,
   sleep/wake, and uninstall. Test Intel runtime and additional interfaces before
   claiming broad compatibility.
3. Create a **draft prerelease** in the intended GitHub repository. Attach the
   installer, source archive, uninstaller, notes, manifest and checksums together.
4. An unsigned preview must stay clearly identified as unsigned and unnotarized.
   Never label it Developer ID signed or Gatekeeper-ready. For a signed release,
   confirm `developerIDSigned` and `notarized` are both true in the manifest.
5. Keep the matching corresponding source available alongside each distributed
   binary. Review the draft and downloads before publishing it.

The source archive includes build/install scripts and avoids generated personal
validation data. Preserve `LICENSE`, `THIRD_PARTY_NOTICES.md` and all upstream
copyright notices. See the [GNU source-distribution FAQ](https://www.gnu.org/licenses/gpl-faq.en.html#DistributeExtendedBinary).
