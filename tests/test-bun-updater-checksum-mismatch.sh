#!/usr/bin/env bash
# A tampered Bun zip must be rejected before buno is replaced or patchelf runs.
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
printf '#!/bin/sh\necho "bun 1.4.4"\n' > "$TMP/payload/bun-linux-aarch64/bun"
chmod 755 "$TMP/payload/bun-linux-aarch64/bun"
(cd "$TMP/payload" && python3 -m zipfile -c "$TMP/bun.zip" bun-linux-aarch64/bun)
printf '%s  bun-linux-aarch64.zip\n' \
  "0000000000000000000000000000000000000000000000000000000000000000" > "$TMP/SHASUMS256.txt"

jq -n '[{
  tag_name: "bun-v1.4.4",
  published_at: "2026-10-22T00:00:00Z",
  prerelease: false,
  assets: [
    {name: "bun-linux-aarch64.zip", browser_download_url: "https://example.invalid/bad/bun-linux-aarch64.zip"},
    {name: "SHASUMS256.txt", browser_download_url: "https://example.invalid/bad/SHASUMS256.txt"}
  ]
}]' > "$TMP/releases.json"

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
case "$url" in
  *"releases?per_page=100"*) cat "$API_PAGE" ;;
  *bun-linux-aarch64.zip) cp "$PAYLOAD" "$out" ;;
  *SHASUMS256.txt) cp "$SUMS" "$out" ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"
cat > "$TMP/prefix/glibc/bin/patchelf" <<'STUB'
#!/bin/sh
printf 'called\n' >> "$PATCH_LOG"
STUB
chmod 755 "$TMP/prefix/glibc/bin/patchelf"
printf '#!/bin/sh\necho "existing"\n' > "$TMP/home/.bun/bin/buno"
chmod 755 "$TMP/home/.bun/bin/buno"
: > "$TMP/patch.log"

set +e
OUTPUT="$(PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  API_PAGE="$TMP/releases.json" PAYLOAD="$TMP/bun.zip" SUMS="$TMP/SHASUMS256.txt" \
  PATCH_LOG="$TMP/patch.log" sh "$TMP/updater" 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "FAIL: checksum mismatch was ignored" >&2
  echo "$OUTPUT" >&2
  exit 1
fi
printf '%s\n' "$OUTPUT" | grep -qi 'sha-256\|checksum' || {
  echo "FAIL: error did not mention checksum verification" >&2; echo "$OUTPUT" >&2; exit 1; }
[ "$("$TMP/home/.bun/bin/buno")" = "existing" ] || {
  echo "FAIL: existing buno was replaced despite the bad checksum" >&2; exit 1; }
[ ! -s "$TMP/patch.log" ] || {
  echo "FAIL: patchelf ran despite the bad checksum" >&2; exit 1; }

echo "PASS: Bun updater aborts on checksum mismatch before touching buno"
