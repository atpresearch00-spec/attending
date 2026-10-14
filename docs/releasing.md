# Releasing updates

The app is developed in a private working repo, which also holds notes that aren't
published (listed in `.publicignore`). Each release is copied into a separate clone of the
public GitHub repo as one clean commit, and tagged.

## Every update

1. **Make the change and try it on your Mac:**
   ```sh
   ./scripts/build-app.sh release && ./scripts/install-app.sh
   ```
2. **Pick the new version number** in `VERSION`: `1.0.1` for fixes, `1.1.0` for new features.
3. **Add a section to `CHANGELOG.md`** describing what's new.
4. **Commit in the working repo:**
   ```sh
   git add -A && git commit -m "Short summary"
   ```
5. **Publish:**
   ```sh
   ./scripts/publish.sh "Short release notes"
   ```
   This runs the tests, builds and signs `dist/Attending-<version>.zip` (plus its `.sig`) and `.dmg`,
   copies the public files into the public clone, commits, tags `v<version>` and pushes.
   With the GitHub CLI signed in, it also creates the GitHub Release and attaches the zip.
   Otherwise, open the repo's **Releases › Draft a new release** on github.com, pick the tag,
   and upload the zip, its `.sig` and the `.dmg`. Installed copies see the new version within a day.

## Keys to back up

Two things on your Mac make updates work. If you lose them, people's copies can't update
themselves anymore, so copy both somewhere safe, like an encrypted USB drive or a password manager.

- **`~/.config/attending/release-signing-key`** signs each release zip
  (`scripts/sign-release.swift`). The app only installs updates signed by this key.
- **The "Attending Release Signing" identity** in your login keychain signs the app itself,
  so macOS keeps people's permissions (Accessibility, Camera, Calendar) across updates.
  To back it up, export it from Keychain Access as a .p12 file.

## First-time setup

1. Create an empty repository on github.com (no README, no license).
2. Clone it to `~/Developer/Attending`, or set `PUBLIC_REPO` to another path.
3. Sign in once so pushes work: install the [GitHub CLI](https://cli.github.com), then run
   `gh auth login` and `gh auth setup-git`.
4. Create the release signing identity (once):
   `ATTENDING_RELEASE=1 SIGN_IDENTITY="Attending Release Signing" ./scripts/create-signing-identity.sh`.
5. Run `./scripts/publish.sh "First public release"`.

## Notarization (recommended)

Without it, macOS asks people to click **Open Anyway** in Privacy & Security the first time,
which is where most install problems come from. Homebrew also only lists notarized apps.
With an Apple Developer account ($99/year), `scripts/release.sh` signs with your Developer ID
and notarizes the zip and the DMG automatically. Set it up once:

1. **Join the Apple Developer Program** at developer.apple.com (as an individual).
2. **Create a Developer ID Application certificate:** developer.apple.com › Certificates ›
   + › *Developer ID Application*, following the steps to make a certificate request with
   Keychain Access, then double-click the downloaded certificate to install it.
   `security find-identity -v -p codesigning` should list it.
3. **Make an app-specific password** at account.apple.com › Sign-In and Security.
4. **Save the notary credentials** in your keychain (it asks for that password):
   ```sh
   xcrun notarytool store-credentials attending-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```
   Your team ID is on developer.apple.com › Membership.

From then on `./scripts/release.sh` (and `publish.sh`) prints "Signed with Developer ID … and
notarized." Every build already uses the hardened runtime and the entitlements in
`scripts/Attending.entitlements` (camera, microphone for the visualizer, calendars,
location, Apple Events), so nothing changes in the app itself.

**One thing to expect:** the first notarized release is signed by a different certificate
than earlier ones, so macOS asks people once more for Accessibility, Camera and Calendar
after that update. Mention it in the release notes.

## Homebrew (after notarization)

People can then install with `brew install --cask med-abdullah/tap/attending`:

1. Create a public repository on github.com named `homebrew-tap`.
2. Clone it to `~/Developer/homebrew-tap` (or set `HOMEBREW_TAP`).

`publish.sh` then writes `Casks/attending.rb` from `packaging/homebrew/attending.rb` with the
new version and checksum, and pushes it, but only for notarized releases.
