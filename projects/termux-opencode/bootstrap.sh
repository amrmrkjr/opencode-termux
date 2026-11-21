#!/data/data/com.termux/files/usr/bin/bash

# bootstrap.sh — Install OpenCode natively on Termux (aarch64)
#
# OpenCode ships a glibc-linked Bun binary for linux-arm64. On Termux it won't
# run directly (missing /lib/ld-linux-aarch64.so.1). This script:
#   1. Installs Termux's glibc runtime + patchelf
#   2. Downloads the pinned official OpenCode linux-arm64 binary
#   3. Verifies every downloaded binary against its pinned SHA-256 checksum
#      before install (mismatch = abort, never installs)
#   4. Patchelf's its interpreter to Termux's glibc loader
#   5. Creates a self-healing launcher at $PREFIX/bin/opencode
#
# Versions are pinned below — no "latest" chasing. To bump to a newer
# release, edit OPENCODE_VERSION/OPENCODE_SHA256 (and BUN_VERSION/BUN_SHA256)
# at the top of this file, then re-run bootstrap.
#
# No root, no proot, no containers. Just a thin compatibility layer.
#
set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────────────────────
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
DIM=$'\033[0;2m'
BOLD=$'\033[1m'
NC=$'\033[0m'
YELLOW=$'\033[0;33m'

info()  { printf "${GREEN}◆${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}  ✓${NC} %s\n" "$*"; }
err()   { printf "${RED}  ✗${NC} %s\n" "$*" >&2; exit 1; }
muted() { printf "${DIM}  %s${NC}\n" "$*"; }
warn()  { printf "${YELLOW}  ⚠${NC} %s\n" "$*"; }

# abort with err unless the file's real SHA-256 matches the pinned one
verify_sha256() {
  local file="$1" expected="$2" label="$3" actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    err "SHA-256 mismatch for $label: expected $expected, got $actual — aborting (tampered download or stale pin)"
  fi
  ok "SHA-256 verified: $label"
}

# ─── Pinned releases (edit these to bump versions) ──────────────────────────
# Every download is verified against the pinned SHA-256 below before install.
# Release sha256sums:
#   OpenCode v2.3.2, asset opencode-linux-arm64.tar.gz — from the release's
#     SHA256SUMS, cross-checked against the GitHub API asset digest.
#     Reviewed here on 2026-11-22.
#   Bun bun-v1.4.5, asset bun-linux-aarch64.zip — from the official
#     SHASUMS256.txt shipped in that release. Verified here on 2026-11-22.
#
# To bump: set both the tag and the matching sha256, then re-run bootstrap.
# `opencode-termux-update` tracks the latest v2 release independently.
OPENCODE_VERSION="v2.3.2"
OPENCODE_SHA256="9d10185acdb72336e086e699ca363a6065f410fd3c1caed0dc8046e95ac06ccb"
BUN_VERSION="bun-v1.4.5"
BUN_SHA256="18656a3bf0ea5641f5796ae4213b75255579a70a0fded2f337933785568cdf84"

# ─── Paths ───────────────────────────────────────────────────────────────────
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
GL="$PREFIX/glibc"
GLD="$GL/lib/ld-linux-aarch64.so.1"
PE="$GL/bin/patchelf"
BIN_DIR="$HOME_DIR/.local/share/opencode-termux/bin"
BIN="$BIN_DIR/opencode"
LAUNCHER="$PREFIX/bin/opencode"
REPO="anomalyco/opencode"

# ─── Sanity checks ──────────────────────────────────────────────────────────
info "Checking environment…"

[ -d "$PREFIX" ] || err "Not a Termux environment (PREFIX not found)."

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ;;
  *) err "Only ARM64 (aarch64) supported — detected $ARCH.";;
esac

# Quick free space check (target ~500MB for binary + glibc)
AVAIL="$(df -k "$PREFIX" | awk 'NR==2{print int($4/1024)}')" || AVAIL=0
if [ "$AVAIL" -gt 0 ] && [ "$AVAIL" -lt 500 ]; then
  err "Low disk space: ${AVAIL}MB free. Need at least 500MB."
fi
ok "ARM64 Termux environment"
ok "${AVAIL}MB free (estimated)"

# ─── Install glibc + patchelf ───────────────────────────────────────────────
info "Installing glibc compatibility layer…"

pkg update -y || warn "pkg update failed — continuing"

# Check if glibc is already fully installed
if [ -x "$GLD" ] && [ -x "$PE" ]; then
  ok "glibc + patchelf already installed"
else
  pkg install -y glibc-repo 2>/dev/null || err "Failed to install glibc-repo"
  pkg update -y || warn "pkg update failed — continuing"
  pkg install -y glibc patchelf-glibc binutils-glibc 2>/dev/null || \
    err "Failed to install glibc packages"
  [ -x "$GLD" ] || err "glibc loader not found at $GLD"
  [ -x "$PE" ]  || err "patchelf not found at $PE"

  # Fix: libc.so may be a linker script (text file) instead of a real ELF.
  # The runtime loader needs a real shared library, not an ld script.
  if head -1 "$GL/lib/libc.so" 2>/dev/null | grep -q 'GNU ld script'; then
    mv "$GL/lib/libc.so" "$GL/lib/libc.so.ldscript"
    ln -sf "libc.so.6" "$GL/lib/libc.so"
    ok "libc.so linker script replaced with symlink to libc.so.6"
  fi

  ok "glibc + patchelf installed"
fi

# ─── Install basic deps ─────────────────────────────────────────────────────
info "Installing dependencies…"

DEPS=(curl jq tar ripgrep clang make git)
MISSING=()
for d in "${DEPS[@]}"; do
  command -v "$d" >/dev/null 2>&1 || MISSING+=("$d")
done
if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "dependencies already installed"
else
  pkg install -y "${MISSING[@]}" 2>/dev/null || err "Failed to install deps: ${MISSING[*]}"
  ok "dependencies installed"
fi

# ─── Install Node.js + npm ──────────────────────────────────────────────────
info "Installing Node.js and npm…"

if command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
  ok "Node.js already installed: $(node --version)"
else
  pkg install -y nodejs npm 2>/dev/null || err "Failed to install nodejs/npm"
  ok "Node.js installed: $(node --version)"
fi

# ─── Install Bun (for plugin system) ────────────────────────────────────────
info "Installing Bun (for OpenCode plugin system)…"

BUN_DIR="$HOME_DIR/.bun"
BUN_WRAPPER="$BUN_DIR/bin/bun-termux"
BUN_BIN="$BUN_DIR/bin/buno"
BUN_SHIM="$BUN_DIR/lib/bun-shim.so"
BUN_LAUNCHER="$PREFIX/bin/bun"
BUNX_LAUNCHER="$PREFIX/bin/bunx"

if [ -x "$BUN_LAUNCHER" ] && "$BUN_LAUNCHER" --version >/dev/null 2>&1; then
  ok "Bun already installed: $("$BUN_LAUNCHER" --version 2>/dev/null || true)"
else
  # Step 1: Build bun-on-termux wrapper + shim (handles Termux filesystem quirks)
  if [ ! -x "$BUN_WRAPPER" ]; then
    BUN_TMP="$(mktemp -d)"
    trap 'rm -rf "$BUN_TMP"' EXIT
    muted "Downloading bun-on-termux…"
    if git clone --depth 1 https://github.com/tribixbite/bun-on-termux.git "$BUN_TMP" 2>/dev/null; then
      cd "$BUN_TMP" || true
      muted "Building Bun wrapper…"
      make install 2>/dev/null || warn "Failed to build bun-on-termux"
      cd "$HOME_DIR" || true
    else
      warn "Failed to clone bun-on-termux — skipping wrapper, using official binary only"
    fi
    rm -rf "$BUN_TMP"
    trap - EXIT
  fi

  # Step 2: Download official bun binary (pinned release, checksum-verified)
  # Stored internally as `buno` — keeps the raw oven-sh binary distinct from the
  # Termux wrapper (`bun-termux`) and the user-facing `bun` launcher.
  if [ ! -x "$BUN_BIN" ]; then
    muted "Downloading official Bun binary ($BUN_VERSION)…"
    BUN_ZIP="$(mktemp).zip"
    if ! curl -fsSL "https://github.com/oven-sh/bun/releases/download/$BUN_VERSION/bun-linux-aarch64.zip" -o "$BUN_ZIP" 2>/dev/null; then
      warn "Failed to download bun"
      rm -f "$BUN_ZIP"
    elif [ -f "$BUN_ZIP" ]; then
      verify_sha256 "$BUN_ZIP" "$BUN_SHA256" "Bun $BUN_VERSION"
      unzip -o "$BUN_ZIP" -d "$HOME_DIR/.bun-tmp" 2>/dev/null || true
      OC_BUN="$(find "$HOME_DIR/.bun-tmp" -name 'bun' -type f 2>/dev/null | head -1)"
      if [ -n "$OC_BUN" ]; then
        install -m755 "$OC_BUN" "$BUN_BIN"
        # Patchelf the bun binary (same as opencode — glibc interpreter)
        unset LD_PRELOAD
        if ! "$PE" --set-interpreter "$GLD" "$BUN_BIN" 2>/dev/null; then
          warn "Failed to patchelf Bun binary"
        else
          ok "Bun binary patchelf'd"
        fi
      fi
      rm -rf "$HOME_DIR/.bun-tmp" "$BUN_ZIP"
    fi
  fi

  # Step 3: (Re)create launchers — idempotent, runs every bootstrap
  # so partial installs self-heal: shim symlink + launcher routing.
  # - Wrapper path: `bun-termux` needs bun-shim.so at ~/.bun/bin/lib/
  #   (make install puts it at ~/.bun/lib/) — relinked on every run.
  # - Launchers must route through the wrapper when it exists; the raw
  #   `buno` binary alone fails with "version `LIBC' not found" via the
  #   termux-exec preload, breaking `bunx skills`/plugins.
  if [ -x "$BUN_WRAPPER" ]; then
    mkdir -p "$BUN_DIR/bin/lib" 2>/dev/null
    [ -f "$BUN_SHIM" ] && ln -sf "$BUN_SHIM" "$BUN_DIR/bin/lib/bun-shim.so" 2>/dev/null || true
    cat > "$BUN_LAUNCHER" << 'BUN_LAUNCHER'
#!/data/data/com.termux/files/usr/bin/sh
exec ~/.bun/bin/bun-termux "$@"
BUN_LAUNCHER
    chmod 755 "$BUN_LAUNCHER"

    cat > "$BUNX_LAUNCHER" << 'BUNX_LAUNCHER'
#!/data/data/com.termux/files/usr/bin/sh
exec ~/.bun/bin/bun-termux x "$@"
BUNX_LAUNCHER
    chmod 755 "$BUNX_LAUNCHER"
    ok "Bun installed: $("$BUN_LAUNCHER" --version 2>/dev/null || true)"
  elif [ -x "$BUN_BIN" ]; then
    # Fallback: shell wrappers (no C wrapper, but handles basic Termux quirks)
    cat > "$BUN_LAUNCHER" << 'BUN_LAUNCHER'
#!/data/data/com.termux/files/usr/bin/sh
unset LD_PRELOAD
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export TMPDIR="${TMPDIR:-$HOME/.bun/tmp}"
mkdir -p "$TMPDIR" "$BUN_INSTALL/tmp/fake-root" 2>/dev/null || true
exec "$BUN_INSTALL/bin/buno" "$@"
BUN_LAUNCHER
    chmod 755 "$BUN_LAUNCHER"

    cat > "$BUNX_LAUNCHER" << 'BUNX_LAUNCHER'
#!/data/data/com.termux/files/usr/bin/sh
unset LD_PRELOAD
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export TMPDIR="${TMPDIR:-$HOME/.bun/tmp}"
mkdir -p "$TMPDIR" "$BUN_INSTALL/tmp/fake-root" 2>/dev/null || true
exec "$BUN_INSTALL/bin/buno" x "$@"
BUNX_LAUNCHER
    chmod 755 "$BUNX_LAUNCHER"
    ok "Bun installed (shell wrapper fallback)"
  else
    warn "Bun installation failed — plugins won't load automatically"
  fi
fi

# ─── Bun launcher repair (heal stale installs, always runs) ─────────────────
# The Step 3 launcher block above is skipped when the "already installed" early
# exit fires. Re-point launchers at the wrapper if a wrapper now exists but the
# launchers were written for the raw binary (pre-1.1.1 installs), and re-link
# the shim where the wrapper expects it.
if [ -x "$BUN_WRAPPER" ]; then
  mkdir -p "$BUN_DIR/bin/lib" 2>/dev/null
  [ -f "$BUN_SHIM" ] && ln -sf "$BUN_SHIM" "$BUN_DIR/bin/lib/bun-shim.so" 2>/dev/null || true
  if ! head -1 "$BUN_LAUNCHER" 2>/dev/null | grep -q 'bun-termux'; then
    cat > "$BUN_LAUNCHER" << 'BUN_LAUNCHER'
#!/data/data/com.termux/files/usr/bin/sh
exec ~/.bun/bin/bun-termux "$@"
BUN_LAUNCHER
    chmod 755 "$BUN_LAUNCHER"

    cat > "$BUNX_LAUNCHER" << 'BUNX_LAUNCHER'
#!/data/data/com.termux/files/usr/bin/sh
exec ~/.bun/bin/bun-termux x "$@"
BUNX_LAUNCHER
    chmod 755 "$BUNX_LAUNCHER"
    ok "Bun launchers repaired (wrapper)"
  fi
fi

# ─── DNS fix (nsswitch.conf) ────────────────────────────────────────────────
# glibc's NSS resolver needs /etc/nsswitch.conf. Termux doesn't ship one.
info "Configuring DNS…"

mkdir -p "$GL/etc"
if ! grep -q '^hosts:' "$GL/etc/nsswitch.conf" 2>/dev/null; then
  printf '%s\n' 'hosts: files dns' > "$GL/etc/nsswitch.conf"
  ok "nsswitch.conf configured"
else
  ok "nsswitch.conf already configured"
fi

# ─── SSL cert path ──────────────────────────────────────────────────────────
# Ensure Termux certs are available (needed for HTTPS to AI providers)
if [ ! -f "$PREFIX/etc/tls/cert.pem" ]; then
  pkg install -y ca-certificates 2>/dev/null || true
fi

# ─── Download OpenCode ──────────────────────────────────────────────────────
info "Downloading OpenCode…"

mkdir -p "$BIN_DIR"

if [ -x "$BIN" ] && [ "$("$PE" --print-interpreter "$BIN" 2>/dev/null)" = "$GLD" ]; then
  ok "OpenCode already installed (patchelf'd for glibc)"
  info "Run 'opencode-termux-update' to install the latest release if needed"
  info "Skipping download…"
else
  if [ -x "$BIN" ]; then
    muted "Existing binary needs re-patchelf — reinstalling…"
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  URL="https://github.com/$REPO/releases/download/$OPENCODE_VERSION/opencode-linux-arm64.tar.gz"
  muted "Downloading $OPENCODE_VERSION from GitHub releases…"
  curl -fsSL "$URL" -o "$TMP/opencode.tar.gz" || err "Download failed"

  verify_sha256 "$TMP/opencode.tar.gz" "$OPENCODE_SHA256" "OpenCode $OPENCODE_VERSION"

  muted "Extracting…"
  tar xzf "$TMP/opencode.tar.gz" -C "$TMP" || err "Extraction failed"

  OC="$(find "$TMP" -maxdepth 2 -type f -name 'opencode' | head -1)"
  [ -n "$OC" ] || err "opencode binary not found in archive"

  install -m755 "$OC" "$BIN"
  rm -rf "$TMP"
  trap - EXIT

  ok "binary downloaded"
fi

# ─── Patchelf interpreter ───────────────────────────────────────────────────
info "Patching binary interpreter…"

# termux-exec preload breaks glibc binaries — unset it
unset LD_PRELOAD

CURRENT_INTERP="$("$PE" --print-interpreter "$BIN" 2>/dev/null || echo "")"
if [ "$CURRENT_INTERP" != "$GLD" ]; then
  "$PE" --set-interpreter "$GLD" "$BIN" || err "patchelf failed"
  ok "interpreter set to $GLD"
else
  ok "interpreter already correct"
fi

# ─── Create launcher ────────────────────────────────────────────────────────
info "Creating launcher at $LAUNCHER…"

cat > "$LAUNCHER" << 'LAUNCHER_SCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
# opencode — Termux launcher
#
# Loads the patchelf'd OpenCode binary through glibc's dynamic linker.
# After `opencode update` (which replaces the binary), re-applies patchelf
# to keep the glibc interpreter.
#
set -eu

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
BIN="$HOME_DIR/.local/share/opencode-termux/bin/opencode"
GLD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
PE="$PREFIX/glibc/bin/patchelf"

if [ ! -f "$BIN" ]; then
  echo "opencode: binary not found at $BIN" >&2
  echo "opencode: re-run the bootstrap script to install." >&2
  exit 1
fi

# termux-exec preload breaks glibc binaries — unset it
unset LD_PRELOAD

# Re-patchelf if self-update restored the original interpreter
if [ -x "$PE" ]; then
  CURRENT_INTERP="$("$PE" --print-interpreter "$BIN" 2>/dev/null || echo "")"
  if [ "$CURRENT_INTERP" != "$GLD" ]; then
    if ! "$PE" --set-interpreter "$GLD" "$BIN"; then
      echo "opencode: warning: failed to re-apply patchelf — re-run bootstrap" >&2
    fi
  fi
fi

export SSL_CERT_FILE="${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
exec "$BIN" "$@"
LAUNCHER_SCRIPT

chmod 755 "$LAUNCHER"
ok "launcher created"

# ─── Shell completions ──────────────────────────────────────────────────────
info "Setting up shell completions…"

COMP_DIR="$HOME_DIR/.local/share/opencode-termux/completions"
mkdir -p "$COMP_DIR"

# Bash — generate if missing, source in .bashrc (create if absent)
if command -v bash >/dev/null 2>&1; then
  if [ ! -s "$COMP_DIR/opencode.bash" ]; then
    muted "Generating bash completions…"
    "$LAUNCHER" completion bash > "$COMP_DIR/opencode.bash" 2>/dev/null || \
    "$LAUNCHER" completion > "$COMP_DIR/opencode.bash" 2>/dev/null || true
    BASH_RC="$HOME_DIR/.bashrc"
    [ -f "$BASH_RC" ] || touch "$BASH_RC"
    if [ -s "$COMP_DIR/opencode.bash" ]; then
      grep -q "opencode.bash" "$BASH_RC" 2>/dev/null || \
        printf '\n# OpenCode completions\nsource %s\n' "$COMP_DIR/opencode.bash" >> "$BASH_RC"
    fi
  fi
  ok "bash completions ready"
fi

# Zsh
if command -v zsh >/dev/null 2>&1; then
  if [ ! -s "$COMP_DIR/opencode.zsh" ]; then
    muted "Generating zsh completions…"
    "$LAUNCHER" completion zsh > "$COMP_DIR/opencode.zsh" 2>/dev/null || true
    ZSH_RC="$HOME_DIR/.zshrc"
    [ -f "$ZSH_RC" ] || touch "$ZSH_RC"
    if [ -s "$COMP_DIR/opencode.zsh" ]; then
      grep -q "opencode.zsh" "$ZSH_RC" 2>/dev/null || \
        printf '\n# OpenCode completions\nsource %s\n' "$COMP_DIR/opencode.zsh" >> "$ZSH_RC"
    fi
  fi
  ok "zsh completions ready"
fi

# Fish
if command -v fish >/dev/null 2>&1; then
  FISH_COMP_DIR="$HOME_DIR/.config/fish/completions"
  if [ ! -s "$FISH_COMP_DIR/opencode.fish" ]; then
    muted "Generating fish completions…"
    mkdir -p "$FISH_COMP_DIR"
    "$LAUNCHER" completion fish > "$FISH_COMP_DIR/opencode.fish" 2>/dev/null || true
  fi
  ok "fish completions ready"
fi

# ─── Create update script ───────────────────────────────────────────────────
info "Creating update script…"

UPDATE_SCRIPT="$PREFIX/bin/opencode-termux-update"
cat > "$UPDATE_SCRIPT" << 'UPDATE_SCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
# opencode-termux-update — Install the latest OpenCode v2 release
#
# Resolves the newest v2.x tagged release from GitHub, downloads its
# linux-arm64 asset, verifies it against the SHA-256 digest GitHub publishes
# for the asset, and re-applies patchelf. Pre-releases are never picked up.
# GitHub's /releases/latest can point at the v1 line, so the full release
# list is filtered by tag instead.
# Never run `opencode update` directly — it restores the original
# interpreter and breaks the Termux wrapper.
#
set -eu

# termux-exec preload breaks glibc binaries — unset it before the very
# first binary invocation (version detection included)
unset LD_PRELOAD

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
BIN_DIR="$HOME_DIR/.local/share/opencode-termux/bin"
BIN="$BIN_DIR/opencode"
GLD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
PE="$PREFIX/glibc/bin/patchelf"
REPO="anomalyco/opencode"

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;2m'
NC='\033[0m'

info()  { printf "${GREEN}◆${NC} %s\n" "$*"; }
err()   { printf "${RED}  ✗${NC} %s\n" "$*" >&2; exit 1; }
muted() { printf "${DIM}  %s${NC}\n" "$*"; }

# Get current version
CURRENT="unknown"
if [ -x "$BIN" ]; then
  CURRENT="$("$BIN" --version 2>/dev/null | head -1 || echo "unknown")"
fi

info "Current version: $CURRENT"

command -v jq >/dev/null 2>&1 || err "jq is required — re-run bootstrap.sh to install it"

# Resolve an explicitly requested tag, or the newest v2 release by default.
if [ -n "${OPENCODE_VERSION:-}" ]; then
  TAG="$OPENCODE_VERSION"
  muted "Resolving requested release $TAG…"
  REL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$TAG" || err "Release $TAG not found in $REPO")"
  info "Requested release: $TAG"
else
  muted "Querying GitHub API for the latest v2 release…"
  API="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" || err "Failed to query GitHub API")"
  REL="$(printf '%s' "$API" | jq -c '[.[] | select(.prerelease == false) | select(.tag_name | startswith("v2."))] | sort_by(.published_at) | last')"
  TAG="$(printf '%s' "$REL" | jq -r '.tag_name // empty')"
  [ -n "$TAG" ] && [ "$TAG" != "null" ] || err "No v2 release found for $REPO"
  info "Latest release: $TAG"
fi

ASSET="$(printf '%s' "$REL" | jq -c '[.assets[] | select(.name == "opencode-linux-arm64.tar.gz")][0]')"
[ -n "$ASSET" ] && [ "$ASSET" != "null" ] || err "Asset opencode-linux-arm64.tar.gz not found in $TAG"
URL="$(printf '%s' "$ASSET" | jq -r '.browser_download_url')"
DIGEST="$(printf '%s' "$ASSET" | jq -r '.digest // empty')"
if [ -n "${OPENCODE_VERSION:-}" ] && [ -z "$DIGEST" ]; then
  err "No SHA-256 digest published for $TAG — refusing to install unverified"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

muted "Downloading $TAG…"
curl -fsSL "$URL" -o "$TMP/opencode.tar.gz" || err "Download failed"

# Verify the asset against the SHA-256 digest GitHub publishes for it
ACTUAL="$(sha256sum "$TMP/opencode.tar.gz" | awk '{print $1}')"
if [ -n "$DIGEST" ]; then
  EXPECTED="${DIGEST#sha256:}"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    err "SHA-256 mismatch for $TAG: expected $EXPECTED, got $ACTUAL — aborting (tampered download)"
  fi
  muted "SHA-256 verified"
fi

tar xzf "$TMP/opencode.tar.gz" -C "$TMP" || err "Extraction failed"
OC="$(find "$TMP" -maxdepth 2 -type f -name 'opencode' | head -1)"
[ -n "$OC" ] || err "Binary not found in archive"

mkdir -p "$BIN_DIR"
install -m755 "$OC" "$BIN"
rm -rf "$TMP"
trap - EXIT

# termux-exec preload breaks glibc binaries — unset it
unset LD_PRELOAD

# Re-apply patchelf
if [ -x "$PE" ]; then
  "$PE" --set-interpreter "$GLD" "$BIN" || err "patchelf failed"
fi

NEW="$("$BIN" --version 2>/dev/null | head -1 || echo "installed")"
info "Updated to latest release: $NEW"
UPDATE_SCRIPT

chmod 755 "$UPDATE_SCRIPT"
ok "update script created ($UPDATE_SCRIPT)"

# ─── Create version installer ───────────────────────────────────────────────
info "Creating version installer…"

INSTALL_SCRIPT="$PREFIX/bin/opencode-termux-install"
cat > "$INSTALL_SCRIPT" << 'INSTALL_SCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
# opencode-termux-install — Pick an OpenCode release to install
#
# Shows a numbered menu of releases that have a Termux-compatible arm64
# asset, then hands the chosen tag to opencode-termux-update. An exact tag
# can be passed as an argument to skip the menu.
set -eu

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
UPDATE="$PREFIX/bin/opencode-termux-update"
REPO="anomalyco/opencode"
PAGE_SIZE=25

GREEN='\033[0;32m'
DIM='\033[0;2m'
NC='\033[0m'
info()  { printf "${GREEN}◆${NC} %s\n" "$*"; }
muted() { printf "${DIM}  %s${NC}\n" "$*"; }
err()   { printf "\033[0;31m  ✗${NC} %s\n" "$*" >&2; exit 1; }

[ -x "$UPDATE" ] || err "opencode-termux-update not found — re-run bootstrap.sh"
command -v jq >/dev/null 2>&1 || err "jq is required — re-run bootstrap.sh"

if [ "$#" -gt 0 ]; then
  TAG="$1"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  : > "$TMP/pages"

  # Fetch all release pages (upstream has ~900; cap at 20 to avoid runaway).
  # GitHub returns HTTP 422 once pagination passes its 1000-result window —
  # that means "no more results", not a failed request.
  page=1
  while [ "$page" -le 20 ]; do
    response="$(curl -sS -w '\n%{http_code}' "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page" || err "Failed to query GitHub API")"
    status="$(printf '%s\n' "$response" | tail -1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    case "$status" in
      200) ;;
      422) break ;;
      *) err "Failed to query GitHub API (HTTP $status)" ;;
    esac
    count="$(printf '%s' "$body" | jq 'length')"
    [ "$count" -gt 0 ] || break
    printf '%s\n' "$body" >> "$TMP/pages"
    page=$((page + 1))
  done

  # Keep only releases with an opencode-linux-arm64.tar.gz asset.
  jq -s 'add | [
    .[]
    | select(any(.assets[]?; .name == "opencode-linux-arm64.tar.gz"))
    | . as $rel
    | {tag: .tag_name,
       ts: ($rel.published_at // $rel.created_at // ""),
       date: (($rel.published_at // $rel.created_at // "") | .[0:10]),
       pre: .prerelease}
  ] | sort_by(.ts) | reverse' "$TMP/pages" > "$TMP/list"

  TOTAL="$(jq 'length' "$TMP/list")"
  [ "$TOTAL" -gt 0 ] || err "No installable OpenCode releases found for $REPO"

  START=1
  while :; do
    END=$((START + PAGE_SIZE - 1))
    [ "$END" -le "$TOTAL" ] || END="$TOTAL"
    echo ""
    info "Available OpenCode versions ($START–$END of $TOTAL)"
    echo ""
    jq -r --argjson s "$START" --argjson e "$END" '
      .[$s - 1:$e] | to_entries[] |
      "  \(.key + $s)) \(.value.tag)  \(.value.date)\(if .value.pre then "  (pre-release)" else "" end)"
    ' "$TMP/list"
    echo ""
    muted "[n]ext page  [p]revious page  [q]uit  or type a number"
    printf 'Select version: '
    read -r CHOICE || exit 0
    case "$CHOICE" in
      q|Q) exit 0 ;;
      n|N)
        if [ "$END" -lt "$TOTAL" ]; then START=$((END + 1)); else muted "Already on the last page"; fi
        ;;
      p|P)
        if [ "$START" -gt 1 ]; then
          CUR=$(( (START - 1) / PAGE_SIZE + 1 ))
          START=$(( (CUR - 2) * PAGE_SIZE + 1 ))
          [ "$START" -gt 0 ] || START=1
        else
          muted "Already on the first page"
        fi
        ;;
      ''|*[!0-9]*) muted "Enter a number, n, p, or q" ;;
      *)
        if [ "$CHOICE" -ge "$START" ] && [ "$CHOICE" -le "$END" ]; then
          TAG="$(jq -r ".[$CHOICE - 1].tag" "$TMP/list")"
          break
        fi
        muted "Number out of range (choose $START–$END)"
        ;;
    esac
  done
fi

muted "Installing $TAG…"
export OPENCODE_VERSION="$TAG"
exec "$UPDATE"
INSTALL_SCRIPT

chmod 755 "$INSTALL_SCRIPT"
ok "version installer created ($INSTALL_SCRIPT)"

# ─── Create Bun update script ───────────────────────────────────────────────
info "Creating Bun update script…"

BUN_UPDATE_SCRIPT="$PREFIX/bin/opencode-termux-bun-update"
cat > "$BUN_UPDATE_SCRIPT" << 'BUN_UPDATE_SCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
# opencode-termux-bun-update — Install a Bun release
#
# By default installs the newest stable Bun release. If BUN_VERSION is set,
# that exact tag is installed instead (used by opencode-termux-bun-install).
# The bun-linux-aarch64.zip is verified against that release's SHASUMS256.txt
# before it replaces ~/.bun/bin/buno. The bun/bunx launchers are untouched.
set -eu

# termux-exec preload breaks glibc binaries — unset it before any binary call
unset LD_PRELOAD

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
BUN_DIR="$HOME_DIR/.bun"
BUN_BIN="$BUN_DIR/bin/buno"
BUN_WRAPPER="$BUN_DIR/bin/bun-termux"
BUN_SHIM="$BUN_DIR/lib/bun-shim.so"
GLD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
PE="$PREFIX/glibc/bin/patchelf"
REPO="oven-sh/bun"
ASSET_NAME="bun-linux-aarch64.zip"
SUMS_NAME="SHASUMS256.txt"

GREEN='\033[0;32m'
RED='\033[0;31m'
DIM='\033[0;2m'
NC='\033[0m'
info()  { printf "${GREEN}◆${NC} %s\n" "$*"; }
err()   { printf "${RED}  ✗${NC} %s\n" "$*" >&2; exit 1; }
muted() { printf "${DIM}  %s${NC}\n" "$*"; }

command -v jq >/dev/null 2>&1 || err "jq is required — re-run bootstrap.sh to install it"
command -v unzip >/dev/null 2>&1 || err "unzip is required — re-run bootstrap.sh to install it"

# Resolve an explicitly requested tag, or the newest installable stable release.
if [ -n "${BUN_VERSION:-}" ]; then
  TAG="$BUN_VERSION"
  muted "Resolving requested release $TAG…"
  REL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/$TAG" || err "Release $TAG not found in $REPO")"
  info "Requested release: $TAG"
else
  muted "Querying GitHub API for the latest Bun release…"
  API="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=100" || err "Failed to query GitHub API")"
  REL="$(printf '%s' "$API" | jq -c '[.[] | select(.prerelease == false) | select(any(.assets[]?; .name == "bun-linux-aarch64.zip") and any(.assets[]?; .name == "SHASUMS256.txt"))] | sort_by(.published_at) | last')"
  TAG="$(printf '%s' "$REL" | jq -r '.tag_name // empty')"
  [ -n "$TAG" ] && [ "$TAG" != "null" ] || err "No installable Bun release found for $REPO"
  info "Latest release: $TAG"
fi

ZIP_URL="$(printf '%s' "$REL" | jq -r --arg n "$ASSET_NAME" '[.assets[] | select(.name == $n)][0].browser_download_url // empty')"
SUMS_URL="$(printf '%s' "$REL" | jq -r --arg n "$SUMS_NAME" '[.assets[] | select(.name == $n)][0].browser_download_url // empty')"
[ -n "$ZIP_URL" ] || err "Asset $ASSET_NAME not found in $TAG"
[ -n "$SUMS_URL" ] || err "Asset $SUMS_NAME not found in $TAG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

muted "Downloading $TAG…"
curl -fsSL "$ZIP_URL" -o "$TMP/bun.zip" || err "Download failed"
curl -fsSL "$SUMS_URL" -o "$TMP/SHASUMS256.txt" || err "Failed to download $SUMS_NAME"

EXPECTED="$(awk -v name="$ASSET_NAME" '$2 == name {print $1; exit}' "$TMP/SHASUMS256.txt")"
[ -n "$EXPECTED" ] || err "No SHA-256 checksum for $ASSET_NAME in $TAG — refusing to install unverified"
ACTUAL="$(sha256sum "$TMP/bun.zip" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED" ] || err "SHA-256 mismatch for $TAG: expected $EXPECTED, got $ACTUAL — aborting (tampered download)"
muted "SHA-256 verified"

unzip -oq "$TMP/bun.zip" -d "$TMP" || err "Extraction failed"
BUN_EXE="$(find "$TMP" -type f -name bun | head -1)"
[ -n "$BUN_EXE" ] || err "Bun binary not found in archive"

mkdir -p "$BUN_DIR/bin"
install -m755 "$BUN_EXE" "$BUN_BIN"
rm -rf "$TMP"
trap - EXIT

# Re-apply the glibc interpreter after the binary swap.
unset LD_PRELOAD
if [ -x "$PE" ]; then
  "$PE" --set-interpreter "$GLD" "$BUN_BIN" || err "patchelf failed"
else
  muted "patchelf not found — re-run bootstrap.sh to repair the glibc layer"
fi

# The wrapper expects the shim at ~/.bun/bin/lib/bun-shim.so.
if [ -x "$BUN_WRAPPER" ]; then
  mkdir -p "$BUN_DIR/bin/lib"
  [ -f "$BUN_SHIM" ] && ln -sf "$BUN_SHIM" "$BUN_DIR/bin/lib/bun-shim.so" || true
fi

NEW="$("$BUN_BIN" --version 2>/dev/null | head -1 || echo "installed")"
info "Bun updated to $TAG: $NEW"
BUN_UPDATE_SCRIPT

chmod 755 "$BUN_UPDATE_SCRIPT"
ok "Bun update script created ($BUN_UPDATE_SCRIPT)"

# ─── Create Bun version installer ───────────────────────────────────────────
info "Creating Bun version installer…"

BUN_INSTALL_SCRIPT="$PREFIX/bin/opencode-termux-bun-install"
cat > "$BUN_INSTALL_SCRIPT" << 'BUN_INSTALL_SCRIPT'
#!/data/data/com.termux/files/usr/bin/sh
# opencode-termux-bun-install — Pick a Bun release to install
#
# Shows a numbered menu of releases that have both bun-linux-aarch64.zip and
# SHASUMS256.txt, then hands the chosen tag to opencode-termux-bun-update.
# An exact tag can be passed as an argument to skip the menu.
set -eu

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
UPDATE="$PREFIX/bin/opencode-termux-bun-update"
REPO="oven-sh/bun"
PAGE_SIZE=25

GREEN='\033[0;32m'
DIM='\033[0;2m'
NC='\033[0m'
info()  { printf "${GREEN}◆${NC} %s\n" "$*"; }
muted() { printf "${DIM}  %s${NC}\n" "$*"; }
err()   { printf "\033[0;31m  ✗${NC} %s\n" "$*" >&2; exit 1; }

[ -x "$UPDATE" ] || err "opencode-termux-bun-update not found — re-run bootstrap.sh"
command -v jq >/dev/null 2>&1 || err "jq is required — re-run bootstrap.sh"

if [ "$#" -gt 0 ]; then
  TAG="$1"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  : > "$TMP/pages"

  # GitHub returns HTTP 422 once pagination passes its 1000-result window —
  # that means "no more results", not a failed request.
  page=1
  while [ "$page" -le 20 ]; do
    response="$(curl -sS -w '\n%{http_code}' "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page" || err "Failed to query GitHub API")"
    status="$(printf '%s\n' "$response" | tail -1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    case "$status" in
      200) ;;
      422) break ;;
      *) err "Failed to query GitHub API (HTTP $status)" ;;
    esac
    count="$(printf '%s' "$body" | jq 'length')"
    [ "$count" -gt 0 ] || break
    printf '%s\n' "$body" >> "$TMP/pages"
    page=$((page + 1))
  done

  # Only releases with both the arm64 zip and its checksum can be installed.
  jq -s 'add | [
    .[]
    | select(any(.assets[]?; .name == "bun-linux-aarch64.zip"))
    | select(any(.assets[]?; .name == "SHASUMS256.txt"))
    | . as $rel
    | {tag: .tag_name,
       ts: ($rel.published_at // $rel.created_at // ""),
       date: (($rel.published_at // $rel.created_at // "") | .[0:10]),
       pre: .prerelease}
  ] | sort_by(.ts) | reverse' "$TMP/pages" > "$TMP/list"

  TOTAL="$(jq 'length' "$TMP/list")"
  [ "$TOTAL" -gt 0 ] || err "No installable Bun releases found for $REPO"

  START=1
  while :; do
    END=$((START + PAGE_SIZE - 1))
    [ "$END" -le "$TOTAL" ] || END="$TOTAL"
    echo ""
    info "Available Bun versions ($START–$END of $TOTAL)"
    echo ""
    jq -r --argjson s "$START" --argjson e "$END" '
      .[$s - 1:$e] | to_entries[] |
      "  \(.key + $s)) \(.value.tag)  \(.value.date)\(if .value.pre then "  (pre-release)" else "" end)"
    ' "$TMP/list"
    echo ""
    muted "[n]ext page  [p]revious page  [q]uit  or type a number"
    printf 'Select version: '
    read -r CHOICE || exit 0
    case "$CHOICE" in
      q|Q) exit 0 ;;
      n|N)
        if [ "$END" -lt "$TOTAL" ]; then START=$((END + 1)); else muted "Already on the last page"; fi
        ;;
      p|P)
        if [ "$START" -gt 1 ]; then
          CUR=$(( (START - 1) / PAGE_SIZE + 1 ))
          START=$(( (CUR - 2) * PAGE_SIZE + 1 ))
          [ "$START" -gt 0 ] || START=1
        else
          muted "Already on the first page"
        fi
        ;;
      ''|*[!0-9]*) muted "Enter a number, n, p, or q" ;;
      *)
        if [ "$CHOICE" -ge "$START" ] && [ "$CHOICE" -le "$END" ]; then
          TAG="$(jq -r ".[$CHOICE - 1].tag" "$TMP/list")"
          break
        fi
        muted "Number out of range (choose $START–$END)"
        ;;
    esac
  done
fi

muted "Installing $TAG…"
export BUN_VERSION="$TAG"
exec "$UPDATE"
BUN_INSTALL_SCRIPT

chmod 755 "$BUN_INSTALL_SCRIPT"
ok "Bun version installer created ($BUN_INSTALL_SCRIPT)"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Install complete${NC}"
echo ""
  printf "  ${GREEN}Binary:${NC}     %s\n" "$BIN"
  printf "  ${GREEN}Launcher:${NC}   %s\n" "$LAUNCHER"
  NODE_V="$(node --version 2>/dev/null || echo 'not installed')"
  printf "  ${GREEN}Node.js:${NC}    %s\n" "$NODE_V"
  BUN_V="$("$PREFIX/bin/bun" --version 2>/dev/null || echo 'not installed')"
  printf "  ${GREEN}Bun:${NC}        %s\n" "$BUN_V"
  printf "  ${GREEN}Update:${NC}     %s\n" "$UPDATE_SCRIPT"
  printf "  ${GREEN}Bun update:${NC} %s\n" "$BUN_UPDATE_SCRIPT"
  echo ""
  info "${BOLD}Usage${NC}"
  echo ""
  printf '%s\n' "  ${GREEN}opencode${NC}                Terminal UI"
  printf '%s\n' "  ${GREEN}opencode web${NC}            Web interface"
  printf '%s\n' "  ${GREEN}opencode-termux-update${NC}  Safe update (preserves launcher)"
  printf '%s\n' "  ${GREEN}opencode-termux-install${NC} Pick any version from a menu"
  printf '%s\n' "  ${GREEN}opencode-termux-bun-update${NC}   Install the newest Bun release"
  printf '%s\n' "  ${GREEN}opencode-termux-bun-install${NC} Pick any Bun version from a menu"
  printf '%s\n' "  ${GREEN}opencode providers${NC}      Add API keys"
  printf '%s\n' "  ${GREEN}bunx${NC}                    Run OpenCode plugins via Bun"
  echo ""
