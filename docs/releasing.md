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
   This runs the tests, builds and signs `dist/Attending-<version>.zip` (plus its `.sig`),
   copies the public files into the public clone, commits, tags `v<version>` and pushes.
   With the GitHub CLI signed in, it also creates the GitHub Release and attaches the zip.
   Otherwise, open the repo's **Releases › Draft a new release** on github.com, pick the tag,
   and upload the zip and its `.sig`. Installed copies see the new version within a day.

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

## Notarization (optional, recommended)

Downloads are signed with a basic ad-hoc signature, so macOS asks people to click
**Open Anyway** in Privacy & Security the first time. With an Apple Developer account
($99/year), sign with a *Developer ID Application* certificate and notarize the zip
(`xcrun notarytool submit dist/Attending-<version>.zip --wait`, then
`xcrun stapler staple build/Attending.app` and re-zip). Then the app opens with no warning.
Notarizing needs full Xcode's tools.
