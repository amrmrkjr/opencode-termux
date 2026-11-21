#!/usr/bin/env bash
# The updater must install the exact tag passed via OPENCODE_VERSION, using
# that release's own published asset digest, instead of the newest v2 release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/projects/termux-opencode/bootstrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

awk '/^cat > "\$UPDATE_SCRIPT" << .UPDATE_SCRIPT.$/ {inside=1; next} /^UPDATE_SCRIPT$/ {inside=0} inside' \
  "$BOOTSTRAP" > "$TMP/updater"
if [ ! -s "$TMP/updater" ]; then
  echo "FAIL: could not extract generated updater from bootstrap.sh" >&2
  exit 1
fi

mkdir -p "$TMP/bin" "$TMP/prefix/bin" "$TMP/prefix/glibc/bin" \
  "$TMP/home/.local/share/opencode-termux/bin"

mkdir -p "$TMP/payload"
printf '#!/bin/sh\necho "opencode 1.18.32"\n' > "$TMP/payload/opencode"
chmod 755 "$TMP/payload/opencode"
tar -czf "$TMP/opencode.tar.gz" -C "$TMP/payload" opencode
DIGEST="sha256:$(sha256sum "$TMP/opencode.tar.gz" | awk '{print $1}')"

jq -n --arg digest "$DIGEST" '{
  tag_name: "v1.18.32",
  published_at: "2026-09-25T00:00:00Z",
  prerelease: false,
  assets: [{name: "opencode-linux-arm64.tar.gz",
            browser_download_url: "https://example.invalid/old/opencode-linux-arm64.tar.gz",
            digest: $digest}]
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
case "$url" in
  */releases/tags/*) cat "$FIXTURE_TAG" ;;
  https://example.invalid/*)
    printf '%s\n' "$url" >> "$DOWNLOAD_LOG"
    cp "$PAYLOAD" "$out"
    ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
STUB
chmod 755 "$TMP/bin/curl"

printf '#!/bin/sh\nexit 0\n' > "$TMP/prefix/glibc/bin/patchelf"
chmod 755 "$TMP/prefix/glibc/bin/patchelf"
: > "$TMP/download.log"

set +e
OUTPUT="$(PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  OPENCODE_VERSION="v1.18.32" FIXTURE_TAG="$TMP/tag.json" \
  PAYLOAD="$TMP/opencode.tar.gz" DOWNLOAD_LOG="$TMP/download.log" \
  sh "$TMP/updater" 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: updater exited $STATUS" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

if ! printf '%s\n' "$OUTPUT" | grep -q 'v1\.18\.32'; then
  echo "FAIL: updater did not report the requested tag" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

if ! grep -q 'example.invalid/old/opencode-linux-arm64.tar.gz' "$TMP/download.log"; then
  echo "FAIL: updater did not download the requested tag's asset" >&2
  cat "$TMP/download.log" >&2
  exit 1
fi

echo "PASS: updater installs the exact requested tag"
