#!/usr/bin/env bash
# opencode-termux-bun-update must install the newest non-prerelease Bun release,
# verify its zip against that release's SHASUMS256.txt, swap buno, re-apply
# patchelf, and relink the wrapper shim without touching bun/bunx launchers.
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

mkdir -p "$TMP/bin" "$TMP/prefix/bin" "$TMP/prefix/glibc/bin" \
  "$TMP/home/.bun/bin/lib" "$TMP/home/.bun/lib"

# Real bun-linux-aarch64.zip layout: bun-linux-aarch64/bun.
mkdir -p "$TMP/payload/bun-linux-aarch64"
printf '#!/bin/sh\necho "bun 1.4.4"\n' > "$TMP/payload/bun-linux-aarch64/bun"
chmod 755 "$TMP/payload/bun-linux-aarch64/bun"
(cd "$TMP/payload" && python3 -m zipfile -c "$TMP/bun.zip" bun-linux-aarch64/bun)

EXPECTED="$(sha256sum "$TMP/bun.zip" | awk '{print $1}')"
cat > "$TMP/SHASUMS256.txt" <<EOF
0000000000000000000000000000000000000000000000000000000000000000  bun-darwin-aarch64.zip
$EXPECTED  bun-linux-aarch64.zip
EOF

# Newest prerelease must be ignored; v1.4.4 is the newest stable release.
jq -n '[
  {tag_name: "bun-v2.0.0-pre", published_at: "2026-11-21T00:00:00Z", prerelease: true,
   assets: [{name: "bun-linux-aarch64.zip", browser_download_url: "https://example.invalid/pre/bun-linux-aarch64.zip"},
            {name: "SHASUMS256.txt", browser_download_url: "https://example.invalid/pre/SHASUMS256.txt"}]},
  {tag_name: "bun-v1.4.3", published_at: "2026-10-10T00:00:00Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip", browser_download_url: "https://example.invalid/old/bun-linux-aarch64.zip"},
            {name: "SHASUMS256.txt", browser_download_url: "https://example.invalid/old/SHASUMS256.txt"}]},
  {tag_name: "bun-v1.4.4", published_at: "2026-10-22T00:00:00Z", prerelease: false,
   assets: [{name: "bun-linux-aarch64.zip", browser_download_url: "https://example.invalid/new/bun-linux-aarch64.zip"},
            {name: "SHASUMS256.txt", browser_download_url: "https://example.invalid/new/SHASUMS256.txt"}]}
]' > "$TMP/releases.json"

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
  */releases/tags/*) cat "$FIXTURE_TAG" ;;
  *bun-linux-aarch64.zip)
    printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
    cp "$PAYLOAD" "$out"
    ;;
  *SHASUMS256.txt)
    printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
    cp "$SUMS" "$out"
    ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"

cat > "$TMP/prefix/glibc/bin/patchelf" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PATCH_LOG"
STUB
chmod 755 "$TMP/prefix/glibc/bin/patchelf"

printf '#!/bin/sh\nexit 0\n' > "$TMP/home/.bun/bin/bun-termux"
chmod 755 "$TMP/home/.bun/bin/bun-termux"
printf 'shim\n' > "$TMP/home/.bun/lib/bun-shim.so"
printf '#!/bin/sh\necho launcher\n' > "$TMP/prefix/bin/bun"
printf '#!/bin/sh\necho bunx\n' > "$TMP/prefix/bin/bunx"
cp "$TMP/prefix/bin/bun" "$TMP/bun.before"
cp "$TMP/prefix/bin/bunx" "$TMP/bunx.before"
: > "$TMP/download.log"
: > "$TMP/patch.log"

set +e
OUTPUT="$(PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  API_PAGE="$TMP/releases.json" FIXTURE_TAG="$TMP/releases.json" \
  PAYLOAD="$TMP/bun.zip" SUMS="$TMP/SHASUMS256.txt" \
  DOWNLOAD_LOG="$TMP/download.log" PATCH_LOG="$TMP/patch.log" \
  sh "$TMP/updater" 2>&1)"
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: Bun updater exited $STATUS" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

printf '%s\n' "$OUTPUT" | grep -q 'bun-v1\.4\.4' || {
  echo "FAIL: updater did not select the newest stable release" >&2; echo "$OUTPUT" >&2; exit 1; }

grep -q 'example.invalid/new/bun-linux-aarch64.zip' "$TMP/download.log" || {
  echo "FAIL: newest release zip was not downloaded" >&2; cat "$TMP/download.log" >&2; exit 1; }
grep -q 'example.invalid/new/SHASUMS256.txt' "$TMP/download.log" || {
  echo "FAIL: newest release checksum file was not downloaded" >&2; exit 1; }
if grep -q 'example.invalid/old/\|example.invalid/pre/' "$TMP/download.log"; then
  echo "FAIL: updater downloaded an older or prerelease asset" >&2; exit 1
fi

[ -x "$TMP/home/.bun/bin/buno" ] || { echo "FAIL: buno was not installed" >&2; exit 1; }
[ "$("$TMP/home/.bun/bin/buno")" = "bun 1.4.4" ] || {
  echo "FAIL: wrong binary installed as buno" >&2; exit 1; }
grep -q -- "--set-interpreter $TMP/prefix/glibc/lib/ld-linux-aarch64.so.1 $TMP/home/.bun/bin/buno" "$TMP/patch.log" || {
  echo "FAIL: patchelf was not re-applied to buno" >&2; cat "$TMP/patch.log" >&2; exit 1; }

[ "$(readlink "$TMP/home/.bun/bin/lib/bun-shim.so")" = "$TMP/home/.bun/lib/bun-shim.so" ] || {
  echo "FAIL: wrapper shim symlink was not restored" >&2; exit 1; }
cmp -s "$TMP/prefix/bin/bun" "$TMP/bun.before" || {
  echo "FAIL: bun launcher was modified" >&2; exit 1; }
cmp -s "$TMP/prefix/bin/bunx" "$TMP/bunx.before" || {
  echo "FAIL: bunx launcher was modified" >&2; exit 1; }

echo "PASS: Bun updater installs newest stable release and repairs the install"
