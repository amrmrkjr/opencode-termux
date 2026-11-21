#!/usr/bin/env bash
# GitHub returns HTTP 422 once release pagination passes its 1000-result cap.
# The OpenCode version menu must treat that as end-of-list, not a fatal error.
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

# A full page means the loop would normally ask for page 2, where GitHub 422s.
jq -n '[range(0;100) | {
  tag_name: ("v1.0." + tostring),
  published_at: ("2026-01-" + (if (28 - (. % 28)) < 10 then "0" else "" end) + ((28 - (. % 28)) | tostring) + "T" + (if (23 - ((. / 28) | floor)) < 10 then "0" else "" end) + ((23 - ((. / 28) | floor)) | tostring) + ":00:00Z"),
  prerelease: false,
  assets: [{name: "opencode-linux-arm64.tar.gz"}]
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

cat > "$TMP/prefix/bin/opencode-termux-update" <<'STUB'
#!/bin/sh
printf '%s\n' "${OPENCODE_VERSION:-<unset>}" > "$SELECT_LOG"
STUB
chmod 755 "$TMP/prefix/bin/opencode-termux-update"

: > "$TMP/api.log"
: > "$TMP/selected"

set +e
printf '1\n' | PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  PAGE1="$TMP/page1.json" API_LOG="$TMP/api.log" SELECT_LOG="$TMP/selected" \
  sh "$TMP/install" > "$TMP/out" 2>&1
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: installer treated GitHub's 1000-result cap as fatal" >&2
  cat "$TMP/out" >&2
  exit 1
fi
grep -q 'Available OpenCode versions' "$TMP/out" || {
  echo "FAIL: menu was not rendered" >&2; cat "$TMP/out" >&2; exit 1; }
[ "$(cat "$TMP/selected")" = "v1.0.0" ] || {
  echo "FAIL: wrong tag selected: $(cat "$TMP/selected")" >&2; exit 1; }
if grep -q 'page=3' "$TMP/api.log"; then
  echo "FAIL: installer kept paging past the GitHub cap" >&2
  cat "$TMP/api.log" >&2
  exit 1
fi

echo "PASS: OpenCode menu stops cleanly at GitHub's 1000-result cap"
