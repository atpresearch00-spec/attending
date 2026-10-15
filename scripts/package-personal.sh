#!/bin/bash
# Build an ad-hoc signed personal installer without the upstream update signing key.
set -euo pipefail
cd "$(dirname "$0")/.."
release_version=${1:?Usage: package-personal.sh 1.1.0-gita.1}
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-gita\.[0-9]+$ ]] || { echo "Invalid personal release version" >&2; exit 1; }
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "Build on an Apple silicon Mac" >&2; exit 1; }

# A distinct bundle ID disables the upstream updater and separates preferences.
ATTENDING_RELEASE=1 BUNDLE_ID=app.atpresearch.Attending SIGN_IDENTITY=- ./scripts/build-app.sh release
app="$PWD/build/Attending.app"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
codesign --force --options runtime --entitlements scripts/Attending.entitlements --sign - "$app"
plutil -lint "$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")" == app.atpresearch.Attending ]]
for binary in "$app/Contents/MacOS/Attending" "$app/Contents/MacOS/attending-bridge" "$app/Contents/Resources/libAttendingMedia.dylib"; do
  [[ "$(lipo -archs "$binary")" == arm64 ]]
done
codesign --verify --deep --strict --verbose=2 "$app"

mkdir -p dist
dmg="$PWD/dist/Attending-$release_version.dmg"
zip="$PWD/dist/Attending-$release_version.zip"
[[ ! -e "$dmg" && ! -e "$zip" ]] || { echo "Output already exists; use a clean build directory" >&2; exit 1; }
staging=$(mktemp -d)
mount_dir=$(mktemp -d)
mounted=0
cleanup() {
  if [[ "$mounted" == 1 ]]; then hdiutil detach -quiet "$mount_dir" || true; fi
  rm -rf "$staging" "$mount_dir"
}
trap cleanup EXIT
ditto "$app" "$staging/Attending.app"
ln -s /Applications "$staging/Applications"
cp docs/personal-install.txt "$staging/READ-ME.txt"
cp LICENSE "$staging/LICENSE.txt"
hdiutil create -quiet -volname 'Attending — Gita' -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$dmg"
mounted=1
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]]
cmp "$app/Contents/MacOS/Attending" "$mount_dir/Attending.app/Contents/MacOS/Attending"
cmp "$app/Contents/Info.plist" "$mount_dir/Attending.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$mount_dir/Attending.app"

# Launch the packaged app through its diagnostic path, without requesting permissions.
python3 - "$mount_dir/Attending.app/Contents/MacOS/Attending" <<'PY'
import subprocess, sys
result = subprocess.run([sys.argv[1], '--diagnostics'], capture_output=True, text=True, timeout=30, check=True)
assert 'own build' in result.stdout and 'macOS ' in result.stdout, result.stdout + result.stderr
print(result.stdout)
print('PASS: packaged app launches and reports personal-build diagnostics')
PY
hdiutil detach -quiet "$mount_dir"
mounted=0
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

python3 - "$release_version" <<'PY'
import json, pathlib, plistlib, subprocess, sys
version = sys.argv[1]
info = plistlib.loads(pathlib.Path('build/Attending.app/Contents/Info.plist').read_bytes())
manifest = {
    'release': version,
    'source_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'app_version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'bundle_id': info['CFBundleIdentifier'],
    'architecture': 'arm64',
    'minimum_macos': info['LSMinimumSystemVersion'],
    'configuration': 'release',
    'signing': 'ad-hoc',
    'notarized': False,
    'checks': ['core', 'bridge', 'approvals', 'fake Codex transport', 'bundle signature', 'DMG integrity and mount', 'packaged diagnostic launch'],
}
pathlib.Path(f'dist/Attending-{version}-build.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
(cd dist && shasum -a 256 "Attending-$release_version.dmg" "Attending-$release_version.zip" "Attending-$release_version-build.json" > SHA256SUMS.txt)
echo "PASS: release app, disk image, diagnostic launch and checksums verified"
