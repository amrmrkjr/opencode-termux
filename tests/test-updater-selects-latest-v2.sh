#!/usr/bin/env bash
# Regression test: opencode-termux-update must select the newest v2.x release
# even when GitHub's /releases/latest endpoint still points at a v1.x release.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/projects/termux-opencode/bootstrap.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Extract the updater exactly as bootstrap.sh generates it.
awk '/^cat > "\$UPDATE_SCRIPT" << .UPDATE_SCRIPT.$/ {inside=1; next} /^UPDATE_SCRIPT$/ {inside=0} inside' \
  "$BOOTSTRAP" > "$TMP/updater"
if [ ! -s "$TMP/updater" ]; then
  echo "FAIL: could not extract generated updater from bootstrap.sh" >&2
  exit 1
fi

mkdir -p "$TMP/bin" "$TMP/prefix/bin" "$TMP/prefix/glibc/bin" \
  "$TMP/home/.local/share/opencode-termux/bin"

# Fake release payload containing a runnable `opencode`.
mkdir -p "$TMP/payload"
printf '#!/bin/sh\necho "opencode 2.3.2"\n' > "$TMP/payload/opencode"
chmod 755 "$TMP/payload/opencode"
tar -czf "$TMP/opencode.tar.gz" -C "$TMP/payload" opencode
DIGEST="sha256:$(sha256sum "$TMP/opencode.tar.gz" | awk '{print $1}')"

# /releases/latest still reports v1.19.6; the releases list also has v2.3.2.
jq -n --arg digest "$DIGEST" '{
  tag_name: "v1.19.6",
  published_at: "2026-11-17T07:21:32Z",
  prerelease: false,
  assets: [{name: "opencode-linux-arm64.tar.gz",
            browser_download_url: "https://example.invalid/v1/opencode-linux-arm64.tar.gz",
            digest: $digest}]
}' > "$TMP/latest.json"

jq -n --arg digest "$DIGEST" '[
  {tag_name: "v1.19.6", published_at: "2026-11-17T07:21:32Z", prerelease: false,
   assets: [{name: "opencode-linux-arm64.tar.gz",
             browser_download_url: "https://example.invalid/v1/opencode-linux-arm64.tar.gz",
             digest: $digest}]},
  {tag_name: "v2.3.2", published_at: "2026-11-18T01:35:12Z", prerelease: false,
   assets: [{name: "opencode-linux-arm64.tar.gz",
             browser_download_url: "https://example.invalid/v2/opencode-linux-arm64.tar.gz",
             digest: $digest}]}
]' > "$TMP/releases.json"

# Stub curl: serve fixtures for the API, copy the payload for asset downloads.
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
  */releases/latest) cat "$FIXTURE_LATEST" ;;
  */releases?per_page=*|*/releases) cat "$FIXTURE_RELEASES" ;;
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
printf '#!/bin/sh\necho "opencode 1.18.32"\n' > \
  "$TMP/home/.local/share/opencode-termux/bin/opencode"
chmod 755 "$TMP/home/.local/share/opencode-termux/bin/opencode"
: > "$TMP/download.log"

set +e
OUTPUT="$(PATH="$TMP/bin:$PATH" \
  PREFIX="$TMP/prefix" HOME="$TMP/home" \
  FIXTURE_LATEST="$TMP/latest.json" FIXTURE_RELEASES="$TMP/releases.json" \
  PAYLOAD="$TMP/opencode.tar.gz" DOWNLOAD_LOG="$TMP/download.log" \
  sh "$TMP/updater" 2>&1)"
STATUS=$?
set -e

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: updater exited $STATUS" >&2
  echo "$OUTPUT" >&2
  exit 1
fi

if ! printf '%s\n' "$OUTPUT" | grep -q 'Latest release: v2\.3\.2'; then
  echo "FAIL: updater did not select the latest v2 release" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi

if ! grep -q 'example.invalid/v2/opencode-linux-arm64.tar.gz' "$TMP/download.log"; then
  echo "FAIL: updater did not download the v2.3.2 asset" >&2
  cat "$TMP/download.log" >&2
  exit 1
fi

if grep -q 'example.invalid/v1/' "$TMP/download.log"; then
  echo "FAIL: updater fell back to a v1 asset" >&2
  cat "$TMP/download.log" >&2
  exit 1
fi

echo "PASS: updater selects and downloads the latest v2 release"
