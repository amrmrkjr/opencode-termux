#!/usr/bin/env bash
# With BUN_VERSION set, opencode-termux-bun-update must resolve that exact tag
# via the release-by-tag API and install its assets, never the newest release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/projects/termux-opencode/bootstrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^cat > "\$BUN_UPDATE_SCRIPT" << .BUN_UPDATE_SCRIPT.$/ {inside=1; next} /^BUN_UPDATE_SCRIPT$/ {inside=0} inside' \
  "$BOOTSTRAP" > "$TMP/updater"
if [ ! -s "$TMP/updater" ]; then
  echo "FAIL: could not extract generated Bun updater from bootstrap.sh" >&2
  exit 1
fi

mkdir -p "$TMP/bin" "$TMP/prefix/bin" "$TMP/prefix/glibc/bin" "$TMP/home/.bun/bin"

mkdir -p "$TMP/payload/bun-linux-aarch64"
printf '#!/bin/sh\necho "bun 1.3.0"\n' > "$TMP/payload/bun-linux-aarch64/bun"
chmod 755 "$TMP/payload/bun-linux-aarch64/bun"
(cd "$TMP/payload" && python3 -m zipfile -c "$TMP/bun.zip" bun-linux-aarch64/bun)
EXPECTED="$(sha256sum "$TMP/bun.zip" | awk '{print $1}')"
printf '%s  bun-linux-aarch64.zip\n' "$EXPECTED" > "$TMP/SHASUMS256.txt"

jq -n --arg sum "sha256:$EXPECTED" '{
  tag_name: "bun-v1.3.0",
  published_at: "2026-06-01T00:00:00Z",
  prerelease: false,
  assets: [
    {name: "bun-linux-aarch64.zip",
     browser_download_url: "https://example.invalid/pinned/bun-linux-aarch64.zip",
     digest: $sum},
    {name: "SHASUMS256.txt",
     browser_download_url: "https://example.invalid/pinned/SHASUMS256.txt"}
  ]
}' > "$TMP/tag.json"

cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eu
url=""
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$API_LOG"
case "$url" in
  */releases/tags/bun-v1.3.0) cat "$FIXTURE_TAG" ;;
  *bun-linux-aarch64.zip) cp "$PAYLOAD" "$out" ;;
  *SHASUMS256.txt) cp "$SUMS" "$out" ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$TMP/prefix/glibc/bin/patchelf"
chmod 755 "$TMP/prefix/glibc/bin/patchelf"
: > "$TMP/api.log"

set +e
OUTPUT="$(PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  BUN_VERSION="bun-v1.3.0" FIXTURE_TAG="$TMP/tag.json" \
  PAYLOAD="$TMP/bun.zip" SUMS="$TMP/SHASUMS256.txt" API_LOG="$TMP/api.log" \
  sh "$TMP/updater" 2>&1)"
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: pinned Bun updater exited $STATUS" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

printf '%s\n' "$OUTPUT" | grep -q 'bun-v1\.3\.0' || {
  echo "FAIL: updater did not report the requested tag" >&2; echo "$OUTPUT" >&2; exit 1; }
grep -q 'example.invalid/pinned/bun-linux-aarch64.zip' "$TMP/api.log" || {
  echo "FAIL: requested tag's zip was not downloaded" >&2; cat "$TMP/api.log" >&2; exit 1; }
grep -q 'example.invalid/pinned/SHASUMS256.txt' "$TMP/api.log" || {
  echo "FAIL: requested tag's checksum file was not downloaded" >&2; exit 1; }
if grep -q 'releases?per_page=' "$TMP/api.log"; then
  echo "FAIL: exact-tag path queried the latest-release list" >&2; cat "$TMP/api.log" >&2; exit 1
fi
[ -x "$TMP/home/.bun/bin/buno" ] && [ "$("$TMP/home/.bun/bin/buno")" = "bun 1.3.0" ] || {
  echo "FAIL: requested version was not installed as buno" >&2; exit 1; }

echo "PASS: Bun updater installs the exact requested tag"
