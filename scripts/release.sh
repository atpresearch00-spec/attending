#!/bin/zsh
# Builds a release: runs the tests, builds and signs the app, and packages it for GitHub
# Releases as a zip (what the in-app updater and Homebrew install) and a DMG (what people
# download).
#   ./scripts/release.sh            uses the version in VERSION
#   ./scripts/release.sh 1.1.0      sets VERSION first
#
# With an Apple Developer account, it signs with your Developer ID and notarizes both, so
# Attending opens with no warning. One-time setup (docs/releasing.md):
#   1. Install a "Developer ID Application" certificate (Xcode › Settings › Accounts, or developer.apple.com).
#   2. xcrun notarytool store-credentials attending-notary --apple-id YOU --team-id TEAM
#      (it asks for an app-specific password and keeps it in your keychain).
set -euo pipefail
cd "${0:A:h}/.."
if [[ -n "${1:-}" ]]; then print "$1" > VERSION; fi
version=$(<VERSION)
./scripts/test.sh >/dev/null

# Signing: Developer ID when installed, otherwise the self-made release identity, which at
# least keeps people's permissions across updates (create it once with
# ATTENDING_RELEASE=1 SIGN_IDENTITY="Attending Release Signing" ./scripts/create-signing-identity.sh).
developer=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
profile=${NOTARY_PROFILE:-attending-notary}
if [[ -n "$developer" ]]; then
  identity="$developer"
else
  identity="Attending Release Signing"
  security find-certificate -c "$identity" >/dev/null 2>&1 || { print -u2 "No '$identity' signing identity; permissions will reset on each update"; identity="-"; }
fi
notarize=0
if [[ -n "$developer" ]]; then
  if xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1; then notarize=1
  else print -u2 "Developer ID found, but no notary profile '$profile' yet; skipping notarization (see docs/releasing.md)."; fi
fi

ATTENDING_RELEASE=1 SIGN_IDENTITY="$identity" ./scripts/build-app.sh release >/dev/null 2>&1
app=build/Attending.app
mkdir -p dist
zip="dist/Attending-$version.zip"
dmg="dist/Attending-$version.dmg"
rm -f "$zip" "$zip.sig" "$dmg"

submit() {
  print "Notarizing ${1:t} (usually a few minutes)…"
  local out
  out=$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --timeout 30m 2>&1) || true
  # A rejected submission can still exit 0; the status line says, and the log says why.
  [[ "$out" == *"status: Accepted"* ]] || { print -u2 "$out"; print -u2 "Notarization wasn't accepted. See: xcrun notarytool log <id> --keychain-profile $profile"; exit 1; }
}

ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
if (( notarize )); then
  submit "$zip"
  # Staple the ticket to the app so it opens offline too, then zip the stapled copy.
  xcrun stapler staple -q "$app"
  rm -f "$zip"; ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
fi

# The DMG: the app beside an Applications shortcut, so installing is one drag.
staging=$(mktemp -d)
ditto "$app" "$staging/Attending.app"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "Attending" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$staging"
[[ "$identity" != "-" ]] && codesign --force --sign "$identity" --identifier app.attending.Attending.dmg ${developer:+--timestamp} "$dmg"
if (( notarize )); then
  submit "$dmg"
  xcrun stapler staple -q "$dmg"
fi

# The in-app updater only installs zips carrying this signature.
swift scripts/sign-release.swift "$zip" >/dev/null
print "Built $zip ($(du -h "$zip" | cut -f1)) and $dmg ($(du -h "$dmg" | cut -f1))"
print "zip sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
(( notarize )) && print "Signed with $developer and notarized." || print "Not notarized: people will see the Open Anyway step."
