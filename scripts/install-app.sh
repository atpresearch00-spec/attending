#!/bin/zsh
# Install locally without changing Gatekeeper, adding a daemon, or enabling login automatically.
set -euo pipefail
cd "${0:A:h}/.."
source_app="$PWD/build/Attending.app"
destination="/Applications/Attending.app"
[[ -x "$source_app/Contents/MacOS/Attending" ]] || { print -u2 'Build Attending first with scripts/build-app.sh release'; exit 1; }
# A public release build (scripts/release.sh) carries the default bundle ID; installing it
# over a personal build would reset settings and permissions, so rebuild with local.env.
if [[ -f scripts/local.env ]]; then
  expected=$(source scripts/local.env; print "${BUNDLE_ID:-}")
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    print "Rebuilding with scripts/local.env (found $actual, expected $expected)"
    ./scripts/build-app.sh release >/dev/null 2>&1
  fi
fi
codesign --verify --deep --strict "$source_app"
mkdir -p "/Applications"
staging=$(mktemp -d "/Applications/.attending-install.XXXXXX")
trap 'rmdir "$staging" 2>/dev/null || true' EXIT
ditto "$source_app" "$staging/Attending.app"
codesign --verify --deep --strict "$staging/Attending.app"
if [[ -e "$destination" ]]; then
  backup="/Applications/Attending.previous.$(date +%Y%m%d%H%M%S).app"
  [[ ! -e "$backup" ]] || { print -u2 'Backup path already exists'; exit 1; }
  mv "$destination" "$backup"
fi
mv "$staging/Attending.app" "$destination"
# Keep only the newest backup; older ones go to the Trash (recoverable), not rm. Names carry the install timestamp; (On) sorts them newest first.
backups=(/Applications/Attending.previous.*.app(NOn))
for old in ${backups[2,-1]}; do mv "$old" ~/.Trash/; done
print "$destination"
