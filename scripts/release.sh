#!/bin/zsh
# Builds a release: runs the tests, builds the app, and zips it for GitHub Releases.
#   ./scripts/release.sh            uses the version in VERSION
#   ./scripts/release.sh 1.1.0      sets VERSION first
set -euo pipefail
cd "${0:A:h}/.."
if [[ -n "${1:-}" ]]; then print "$1" > VERSION; fi
version=$(<VERSION)
./scripts/test.sh >/dev/null
# Public identity: the default bundle ID, signed with the release identity so macOS keeps
# people's permissions across updates (create it once with
# ATTENDING_RELEASE=1 SIGN_IDENTITY="Attending Release Signing" ./scripts/create-signing-identity.sh).
identity="Attending Release Signing"
security find-certificate -c "$identity" >/dev/null 2>&1 || { print -u2 "No '$identity' signing identity; permissions will reset on each update"; identity="-"; }
ATTENDING_RELEASE=1 SIGN_IDENTITY="$identity" ./scripts/build-app.sh release >/dev/null 2>&1
mkdir -p dist
zip="dist/Attending-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent build/Attending.app "$zip"
# The in-app updater only installs zips carrying this signature.
swift scripts/sign-release.swift "$zip" >/dev/null
print "Built $zip ($(du -h "$zip" | cut -f1)), sha256 $(shasum -a 256 "$zip" | cut -d' ' -f1)"
