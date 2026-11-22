#!/usr/bin/env bash
# On GitHub HTTP 403 the Bun menu must explain the rate limit, support
# GITHUB_TOKEN, and reuse a cached release list instead of failing blindly.
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

mkdir -p "$TMP/bin" "$TMP/prefix/bin" "$TMP/home"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -eu
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) printf '%s\n' "$2" >> "$HEADER_LOG"; shift 2 ;;
    -w|-D|-o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$API_LOG"
printf '%s\n' '{"message":"API rate limit exceeded"}'
printf '\n403'
STUB
chmod 755 "$TMP/bin/curl"

cat > "$TMP/prefix/bin/opencode-termux-bun-update" <<'STUB'
#!/bin/sh
printf '%s\n' "${BUN_VERSION:-<unset>}" > "$SELECT_LOG"
STUB
chmod 755 "$TMP/prefix/bin/opencode-termux-bun-update"

: > "$TMP/api1.log"
: > "$TMP/headers1.log"
: > "$TMP/selected1"

# Scenario 1: rate-limited with no cache -> actionable error, one API call.
set +e
GITHUB_TOKEN="testtoken" PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  API_LOG="$TMP/api1.log" HEADER_LOG="$TMP/headers1.log" SELECT_LOG="$TMP/selected1" \
  sh "$TMP/install" > "$TMP/out1" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -eq 0 ]; then
  echo "FAIL: 403 was treated as success" >&2; cat "$TMP/out1" >&2; exit 1
fi
if ! grep -qi 'rate limit' "$TMP/out1"; then
  echo "FAIL: error did not explain the rate limit" >&2; cat "$TMP/out1" >&2; exit 1
fi
if ! grep -q 'GITHUB_TOKEN' "$TMP/out1"; then
  echo "FAIL: error did not mention GITHUB_TOKEN" >&2; cat "$TMP/out1" >&2; exit 1
fi
grep -q 'Authorization: Bearer testtoken' "$TMP/headers1.log" || {
  echo "FAIL: GITHUB_TOKEN was not sent to GitHub" >&2; cat "$TMP/headers1.log" >&2; exit 1; }
[ "$(wc -l < "$TMP/api1.log")" -eq 1 ] || {
  echo "FAIL: kept paging after 403" >&2; cat "$TMP/api1.log" >&2; exit 1; }

# Scenario 2: a fresh cache avoids the API completely.
CACHE_DIR="$TMP/home/.cache/opencode-termux"
mkdir -p "$CACHE_DIR"
jq -n '[{tag: "bun-v1.3.0", date: "2026-06-01", ts: "2026-06-01T00:00:00Z", pre: false}]' \
  > "$CACHE_DIR/bun-versions.json"
date +%s > "$CACHE_DIR/bun-versions.ts"
: > "$TMP/api2.log"
: > "$TMP/selected2"
set +e
printf '1\n' | PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  API_LOG="$TMP/api2.log" HEADER_LOG="$TMP/headers1.log" SELECT_LOG="$TMP/selected2" \
  sh "$TMP/install" > "$TMP/out2" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: fresh cache did not satisfy the Bun menu" >&2; cat "$TMP/out2" >&2; exit 1
fi
grep -q 'Available Bun versions' "$TMP/out2" || {
  echo "FAIL: Bun menu not rendered from cache" >&2; cat "$TMP/out2" >&2; exit 1; }
[ "$(cat "$TMP/selected2")" = "bun-v1.3.0" ] || {
  echo "FAIL: wrong cached tag selected: $(cat "$TMP/selected2")" >&2; exit 1; }
[ ! -s "$TMP/api2.log" ] || {
  echo "FAIL: fresh cache still called the API" >&2; cat "$TMP/api2.log" >&2; exit 1; }

# Scenario 3: a stale cache is still used when the API is rate-limited.
echo "$(( $(date +%s) - 90000 ))" > "$CACHE_DIR/bun-versions.ts"
: > "$TMP/api3.log"
: > "$TMP/selected3"
set +e
printf '1\n' | PATH="$TMP/bin:$PATH" PREFIX="$TMP/prefix" HOME="$TMP/home" \
  API_LOG="$TMP/api3.log" HEADER_LOG="$TMP/headers1.log" SELECT_LOG="$TMP/selected3" \
  sh "$TMP/install" > "$TMP/out3" 2>&1
STATUS=$?
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: stale cache was not used during a 403" >&2; cat "$TMP/out3" >&2; exit 1
fi
grep -qi 'cached' "$TMP/out3" || {
  echo "FAIL: stale-cache fallback was not announced" >&2; cat "$TMP/out3" >&2; exit 1; }
[ "$(cat "$TMP/selected3")" = "bun-v1.3.0" ] || {
  echo "FAIL: wrong tag selected from stale cache" >&2; exit 1; }

echo "PASS: Bun menu handles rate limits, tokens, and cached lists"
