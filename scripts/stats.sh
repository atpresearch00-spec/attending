#!/bin/zsh
# Download and traffic numbers for the public repo, from the GitHub CLI.
#   ./scripts/stats.sh
# Installs are DMG downloads (zip before there was a DMG); .sig downloads after the first
# release are in-app updates. Views and clones cover the last 14 days (GitHub's limit).
set -euo pipefail
repo=${REPO:-med-abdullah/attending}
gh api "repos/$repo/releases?per_page=100" --jq '
  (map(select(.draft | not)) | sort_by(.published_at)) as $all
  | $all | to_entries[] | .key as $i | .value
  | (.assets | map(select(.name | endswith(".dmg"))) | map(.download_count) | add // null) as $dmg
  | (.assets | map(select(.name | endswith(".zip"))) | map(.download_count) | add // 0) as $zip
  | (.assets | map(select(.name | endswith(".zip.sig"))) | map(.download_count) | add // 0) as $sig
  | "\(.tag_name)  \(.published_at[:10])  installs \($dmg // $zip)  " + (if $i == 0 then "wrong file (.sig) \($sig)" else "updates \($sig)" end)'
gh api "repos/$repo/releases?per_page=100" --jq '
  map(select(.draft | not)) | map(
    (.assets | map(select(.name | endswith(".dmg"))) | map(.download_count) | add) //
    (.assets | map(select(.name | endswith(".zip"))) | map(.download_count) | add // 0)) | add // 0 | "total installs \(.)"'
gh api "repos/$repo" --jq '"stars \(.stargazers_count)  forks \(.forks_count)  watchers \(.subscribers_count)"'
gh api "repos/$repo/traffic/views" --jq '"views (14 days) \(.count), unique \(.uniques)"' 2>/dev/null || print "views: needs push access"
gh api "repos/$repo/traffic/clones" --jq '"clones (14 days) \(.count), unique \(.uniques)"' 2>/dev/null || true
gh api "repos/$repo/traffic/popular/referrers" --jq '"top referrers: " + (map("\(.referrer) \(.uniques)") | join(", "))' 2>/dev/null || true
