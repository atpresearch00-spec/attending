#!/bin/zsh
# Publishes the current version to the public GitHub repo.
#
# This working repo keeps private notes (listed in .publicignore); the public repo gets
# only the rest, as one clean commit per release, tagged v<version>. If the GitHub CLI
# (gh) is installed and signed in, it also creates the GitHub Release with the app zip.
#
#   ./scripts/publish.sh "What changed in this release"
#
# PUBLIC_REPO (default ~/Developer/Attending) is a clone of the public GitHub repo.
set -euo pipefail
cd "${0:A:h}/.."
notes=${1:?Usage: ./scripts/publish.sh "release notes"}
public=${PUBLIC_REPO:-$HOME/Developer/Attending}
version=$(<VERSION)
[[ -d "$public/.git" ]] || { print -u2 "No public repo at $public. See docs/releasing.md for first-time setup."; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "Commit your changes first."; exit 1; }

./scripts/release.sh
# Copy tracked files except the private ones, replacing the public tree.
files=("${(@f)$(git ls-files)}")
ignored=("${(@f)$(grep -v '^#' .publicignore | sed '/^$/d')}")
( cd "$public" && git rm -rq --ignore-unmatch . >/dev/null )
for f in $files; do
  skip=0
  for pattern in $ignored; do [[ "$f" == ${~pattern}* || "$f" == ${~pattern} ]] && { skip=1; break; }; done
  (( skip )) && continue
  mkdir -p "$public/${f:h}"
  cp -p "$f" "$public/$f"
done
cd "$public"
git add -A
git commit -qm "Attending $version" -m "$notes" || print "Nothing new to commit"
git tag -f "v$version" >/dev/null
git push -q origin HEAD
git push -qf origin "v$version"
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  assets=("$OLDPWD/dist/Attending-$version.zip" "$OLDPWD/dist/Attending-$version.zip.sig" "$OLDPWD/dist/Attending-$version.dmg")
  gh release create "v$version" $assets --title "Attending $version" --notes "$notes" 2>/dev/null \
    || gh release upload "v$version" $assets --clobber
  print "Released v$version on GitHub"
else
  print "Pushed v$version. Upload dist/Attending-$version.zip, its .sig and the .dmg as a GitHub Release (see docs/releasing.md)."
fi

# Homebrew: with a clone of the tap (HOMEBREW_TAP, default ~/Developer/homebrew-tap), bump
# the cask. Only notarized releases go there; Homebrew users would otherwise hit Gatekeeper.
tap=${HOMEBREW_TAP:-$HOME/Developer/homebrew-tap}
cd "$OLDPWD"
if [[ -d "$tap/.git" ]]; then
  if xcrun stapler validate -q build/Attending.app 2>/dev/null; then
    sha=$(shasum -a 256 "dist/Attending-$version.zip" | cut -d' ' -f1)
    mkdir -p "$tap/Casks"
    sed -e "s/version \"VERSION\"/version \"$version\"/" -e "s/sha256 \"SHA256\"/sha256 \"$sha\"/" packaging/homebrew/attending.rb > "$tap/Casks/attending.rb"
    ( cd "$tap" && git add Casks/attending.rb && git commit -qm "attending $version" && git push -q ) && print "Updated the Homebrew cask to $version"
  else
    print "Skipped the Homebrew cask: this release isn't notarized."
  fi
fi
