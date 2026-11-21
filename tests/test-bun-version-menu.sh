#!/usr/bin/env bash
# opencode-termux-bun-install must list only releases installable on Termux and
# hand the chosen tag to the Bun updater, with no tag typing required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/projects/termux-opencode/bootstrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^cat > "\$BUN_INSTALL_SCRIPT" << .BUN_INSTALL_SCRIPT.$/ {inside=1; next} /^BUN_INSTALL_SCRIPT$/ {inside=0} inside' \
  "$BOOTSTRAP" > "$TMP/install"
if [ ! -s "$TMP/install" ]; then
  echo "FAIL: could not extract generated Bun installer from bootstrap.sh" >&2
  exit 1
fi

jq -n '[
  {tag_name: "bun-v1.4.4", published_at: "2026-10-22T08:00:00Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip"}, {name: "SHASUMS256.txt"}]},
  {tag_name: "bun-v1.4.5", published_at: "2026-11-19T08:47:28Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip"}, {name: "SHASUMS256.txt"}]},
  {tag_name: "bun-v1.4.0-no-sums", published_at: "2026-07-01T00:00:00Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip"}]}
] + [
  range(1;24) | . as $i | {
    tag_name: ("bun-v1.3." + ($i|tostring)),
    published_at: ("2026-05-" + (if $i < 10 then "0" else "" end) + ($i|tostring) + "T00:00:00Z"),
    prerelease: false,
    assets: [{name: "bun-linux-aarch64.zip"}, {name: "SHASUMS256.txt"}]
  }
]' > "$TMP/page1.json"

jq -n '[
  {tag_name: "bun-v1.2.9", published_at: "2026-02-09T00:00:00Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip"}, {name: "SHASUMS256.txt"}]},
  {tag_name: "bun-v1.2.8", published_at: "2026-02-08T00:00:00Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip"}, {name: "SHASUMS256.txt"}]}
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
case "$url" in
  *"releases?per_page=100&page=1") cat "$PAGE1" ;;
  *"releases?per_page=100&page=2") cat "$PAGE2" ;;
  *"releases?per_page=100&page="*) printf '[]\n' ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"

cat > "$TMP/prefix/bin/opencode-termux-bun-update" <<'STUB'
#!/bin/sh
printf '%s\n' "${BUN_VERSION:-<unset>}" > "$SELECT_LOG"
STUB
chmod 755 "$TMP/prefix/bin/opencode-termux-bun-update"

: > "$TMP/selected1"
: > "$TMP/selected2"

# Interactive: page 2, pick displayed item 26 -> bun-v1.2.9.
set +e
printf 'n\n26\n' | PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  PAGE1="$TMP/page1.json" PAGE2="$TMP/page2.json" \
  SELECT_LOG="$TMP/selected1" sh "$TMP/install" > "$TMP/out" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: Bun installer exited $STATUS" >&2
  cat "$TMP/out" >&2
  exit 1
fi

grep -q 'Available Bun versions' "$TMP/out" || {
  echo "FAIL: Bun menu was not shown" >&2; cat "$TMP/out" >&2; exit 1; }
grep -m1 -E '^  1\) ' "$TMP/out" | grep -q 'bun-v1\.4\.5' || {
  echo "FAIL: newest release must sort first by full timestamp" >&2; cat "$TMP/out" >&2; exit 1; }
grep -m1 -E '^  2\) ' "$TMP/out" | grep -q 'bun-v1\.4\.4' || {
  echo "FAIL: second release sorted incorrectly" >&2; exit 1; }
grep -q 'bun-v1\.2\.9' "$TMP/out" || {
  echo "FAIL: second page was not shown" >&2; cat "$TMP/out" >&2; exit 1; }
if grep -q 'bun-v1\.4\.0-no-sums' "$TMP/out"; then
  echo "FAIL: release without SHASUMS256.txt was listed" >&2; exit 1
fi
[ "$(cat "$TMP/selected1")" = "bun-v1.2.9" ] || {
  echo "FAIL: wrong tag handed to Bun updater: $(cat "$TMP/selected1")" >&2; exit 1; }

# Direct tag argument skips the menu.
set +e
PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  PAGE1="$TMP/page1.json" PAGE2="$TMP/page2.json" \
  SELECT_LOG="$TMP/selected2" sh "$TMP/install" bun-v1.3.10 > "$TMP/out2" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: direct-tag Bun installer exited $STATUS" >&2
  cat "$TMP/out2" >&2
  exit 1
fi
[ "$(cat "$TMP/selected2")" = "bun-v1.3.10" ] || {
  echo "FAIL: direct tag was not passed to Bun updater: $(cat "$TMP/selected2")" >&2; exit 1; }

echo "PASS: Bun version menu lists installable releases and hands off the chosen tag"
