#!/usr/bin/env bash
# opencode-termux-install must list installable versions from GitHub and hand
# the chosen tag to the updater, with no tag typing and no typo risk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/projects/termux-opencode/bootstrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^cat > "\$INSTALL_SCRIPT" << .INSTALL_SCRIPT.$/ {inside=1; next} /^INSTALL_SCRIPT$/ {inside=0} inside' \
  "$BOOTSTRAP" > "$TMP/install"
if [ ! -s "$TMP/install" ]; then
  echo "FAIL: could not extract generated installer from bootstrap.sh" >&2
  exit 1
fi

# Page 1: 25 installable releases plus one that cannot run on Termux.
jq -n '[
  {tag_name: "v2.3.1", published_at: "2026-11-18T00:17:57Z", prerelease: false,
   assets: [{name: "opencode-linux-arm64.tar.gz"}]},
  {tag_name: "v2.3.2", published_at: "2026-11-18T01:35:12Z", prerelease: false,
   assets: [{name: "opencode-linux-arm64.tar.gz"}]}
] + [
  range(1;25) | . as $i | {
    tag_name: ("v1.18." + ($i|tostring)),
    published_at: ("2026-08-" + (if $i < 10 then "0" else "" end) + ($i|tostring) + "T00:00:00Z"),
    prerelease: false,
    assets: [{name: "opencode-linux-arm64.tar.gz"}]
  }
] + [
  {tag_name: "v1.0.92-noasset", published_at: "2025-11-22T03:31:39Z", prerelease: false,
   assets: [{name: "README.md"}]}
]' > "$TMP/page1.json"

# Page 2: two older installable releases, so "next page" can be exercised.
jq -n '[
  {tag_name: "v1.0.94", published_at: "2025-11-20T00:00:00Z", prerelease: false,
   assets: [{name: "opencode-linux-arm64.tar.gz"}]},
  {tag_name: "v1.0.93", published_at: "2025-11-19T00:00:00Z", prerelease: false,
   assets: [{name: "opencode-linux-arm64.tar.gz"}]}
]' > "$TMP/page2.json"

mkdir -p "$TMP/bin" "$TMP/prefix/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eu
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$API_LOG"
case "$url" in
  *"releases?per_page=100&page=1") cat "$PAGE1"; printf '\n200' ;;
  *"releases?per_page=100&page=2") cat "$PAGE2"; printf '\n200' ;;
  *"releases?per_page=100&page="*) printf '[]\n200' ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"

cat > "$TMP/prefix/bin/opencode-termux-update" <<'STUB'
#!/bin/sh
printf '%s\n' "${OPENCODE_VERSION:-<unset>}" > "$SELECT_LOG"
STUB
chmod 755 "$TMP/prefix/bin/opencode-termux-update"

: > "$TMP/api.log"
: > "$TMP/selected1"
: > "$TMP/selected2"

# Interactive: go to page 2, pick displayed item 27 -> v1.0.94.
set +e
printf 'n\n27\n' | PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  PAGE1="$TMP/page1.json" PAGE2="$TMP/page2.json" API_LOG="$TMP/api.log" \
  SELECT_LOG="$TMP/selected1" sh "$TMP/install" > "$TMP/out" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: installer exited $STATUS" >&2
  cat "$TMP/out" >&2
  exit 1
fi

if ! grep -q 'Available OpenCode versions' "$TMP/out"; then
  echo "FAIL: menu was not shown" >&2
  cat "$TMP/out" >&2
  exit 1
fi
if ! grep -m1 -E '^  1\) ' "$TMP/out" | grep -q 'v2\.3\.2'; then
  echo "FAIL: newest release must sort first even when published the same day" >&2
  cat "$TMP/out" >&2
  exit 1
fi
if ! grep -m1 -E '^  2\) ' "$TMP/out" | grep -q 'v2\.3\.1'; then
  echo "FAIL: second release sorted incorrectly" >&2
  exit 1
fi
if ! grep -q 'v1\.0\.94' "$TMP/out"; then
  echo "FAIL: second page was not shown" >&2
  cat "$TMP/out" >&2
  exit 1
fi
if grep -q 'v1\.0\.92-noasset' "$TMP/out"; then
  echo "FAIL: release without an arm64 asset was listed" >&2
  exit 1
fi
if [ "$(cat "$TMP/selected1")" != "v1.0.94" ]; then
  echo "FAIL: wrong tag handed to updater: $(cat "$TMP/selected1")" >&2
  exit 1
fi

# Direct tag argument skips the menu entirely.
set +e
PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  PAGE1="$TMP/page1.json" PAGE2="$TMP/page2.json" API_LOG="$TMP/api.log" \
  SELECT_LOG="$TMP/selected2" sh "$TMP/install" v1.18.32 > "$TMP/out2" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: direct-tag installer exited $STATUS" >&2
  cat "$TMP/out2" >&2
  exit 1
fi
if [ "$(cat "$TMP/selected2")" != "v1.18.32" ]; then
  echo "FAIL: direct tag was not passed to updater: $(cat "$TMP/selected2")" >&2
  exit 1
fi

echo "PASS: version menu lists installable releases and hands off the chosen tag"
