#!/usr/bin/env bash
# GitHub returns HTTP 422 once release pagination passes its 1000-result cap.
# The Bun version menu must treat that as end-of-list, not a fatal error.
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

jq -n '[range(0;100) | {
  tag_name: ("bun-v1.3." + tostring),
  published_at: ("2026-05-" + (if (28 - (. % 28)) < 10 then "0" else "" end) + ((28 - (. % 28)) | tostring) + "T" + (if (23 - ((. / 28) | floor)) < 10 then "0" else "" end) + ((23 - ((. / 28) | floor)) | tostring) + ":00:00Z"),
  prerelease: false,
  assets: [{name: "bun-linux-aarch64.zip"}, {name: "SHASUMS256.txt"}]
}]' > "$TMP/page1.json"

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
  *"page=1") cat "$PAGE1"; printf '\n200' ;;
  *"page="*) printf '\n422' ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"

cat > "$TMP/prefix/bin/opencode-termux-bun-update" <<'STUB'
#!/bin/sh
printf '%s\n' "${BUN_VERSION:-<unset>}" > "$SELECT_LOG"
STUB
chmod 755 "$TMP/prefix/bin/opencode-termux-bun-update"

: > "$TMP/api.log"
: > "$TMP/selected"

set +e
printf '1\n' | PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  PAGE1="$TMP/page1.json" API_LOG="$TMP/api.log" SELECT_LOG="$TMP/selected" \
  sh "$TMP/install" > "$TMP/out" 2>&1
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: Bun installer treated GitHub's 1000-result cap as fatal" >&2
  cat "$TMP/out" >&2
  exit 1
fi
grep -q 'Available Bun versions' "$TMP/out" || {
  echo "FAIL: Bun menu was not rendered" >&2; cat "$TMP/out" >&2; exit 1; }
[ "$(cat "$TMP/selected")" = "bun-v1.3.0" ] || {
  echo "FAIL: wrong tag selected: $(cat "$TMP/selected")" >&2; exit 1; }
if grep -q 'page=3' "$TMP/api.log"; then
  echo "FAIL: installer kept paging past the GitHub cap" >&2
  cat "$TMP/api.log" >&2
  exit 1
fi

echo "PASS: Bun menu stops cleanly at GitHub's 1000-result cap"
