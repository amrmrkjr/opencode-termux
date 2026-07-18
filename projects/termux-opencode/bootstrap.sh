#!/data/data/com.termux/files/usr/bin/bash
# bootstrap.sh — Install OpenCode natively on Termux (aarch64)
#
# OpenCode ships a glibc-linked Bun binary for linux-arm64. On Termux it won't
# run directly (missing /lib/ld-linux-aarch64.so.1). This script:
#   1. Installs Termux's glibc runtime + patchelf
#   2. Downloads the official OpenCode linux-arm64 binary
#   3. Patchelf's its interpreter to Termux's glibc loader
#   4. Creates a self-healing launcher at $PREFIX/bin/opencode
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
WORKSPACE="$HOME_DIR/opencode"

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

pkg update -y 2>/dev/null || true

# Check if glibc is already fully installed
if [ -x "$GLD" ] && [ -x "$PE" ]; then
  ok "glibc + patchelf already installed"
else
  pkg install -y glibc-repo 2>/dev/null || err "Failed to install glibc-repo"
  pkg update -y 2>/dev/null || true
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

DEPS=(curl jq tar ripgrep clang make)
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
    git clone --depth 1 https://github.com/tribixbite/bun-on-termux.git "$BUN_TMP" 2>/dev/null || warn "Failed to clone bun-on-termux"
    cd "$BUN_TMP"
    muted "Building Bun wrapper…"
    make install 2>/dev/null || warn "Failed to build bun-on-termux"
    cd "$HOME_DIR"
    rm -rf "$BUN_TMP"
    trap - EXIT
    # Fix shim path (make install puts it at ~/.bun/lib/, wrapper expects ~/.bun/bin/lib/)
    mkdir -p "$BUN_DIR/bin/lib" 2>/dev/null
    [ -f "$BUN_SHIM" ] && ln -sf "$BUN_SHIM" "$BUN_DIR/bin/lib/bun-shim.so" 2>/dev/null || true
  fi

  # Step 2: Download official bun binary
  if [ ! -x "$BUN_BIN" ]; then
    muted "Downloading official Bun binary…"
    BUN_ZIP="$(mktemp).zip"
    curl -fsSL "https://github.com/oven-sh/bun/releases/latest/download/bun-linux-aarch64.zip" -o "$BUN_ZIP" 2>/dev/null || \
      { warn "Failed to download bun"; rm -f "$BUN_ZIP"; }
    if [ -f "$BUN_ZIP" ]; then
      unzip -o "$BUN_ZIP" -d "$HOME_DIR/.bun-tmp" 2>/dev/null || true
      OC_BUN="$(find "$HOME_DIR/.bun-tmp" -name 'bun' -type f 2>/dev/null | head -1)"
      if [ -n "$OC_BUN" ]; then
        install -m755 "$OC_BUN" "$BUN_BIN"
        # Patchelf the bun binary (same as opencode — glibc interpreter)
        unset LD_PRELOAD
        "$PE" --set-interpreter "$GLD" "$BUN_BIN" 2>/dev/null || true
        ok "Bun binary patchelf'd"
      fi
      rm -rf "$HOME_DIR/.bun-tmp" "$BUN_ZIP"
    fi
  fi

  # Step 3: Create launchers
  if [ -x "$BUN_WRAPPER" ]; then
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
  info "Run 'opencode-termux-update' to check for updates"
  info "Skipping download…"
else
  if [ -x "$BIN" ]; then
    muted "Existing binary needs re-patchelf — reinstalling…"
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  URL="https://github.com/$REPO/releases/latest/download/opencode-linux-arm64.tar.gz"
  muted "Downloading from GitHub releases…"
  curl -fsSL "$URL" -o "$TMP/opencode.tar.gz" || err "Download failed"

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
export LD_PRELOAD=""

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
    "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null || true
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
# opencode-termux-update — Safely update OpenCode binary
#
# Downloads the latest linux-arm64 binary and re-applies patchelf.
# Never run `opencode update` directly — it restores the original
# interpreter and breaks the Termux wrapper.
#
set -eu

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
info "Checking for updates…"

TMP="$(mktemp -d)"
trap "rm -rf '$TMP'" EXIT

URL="https://github.com/$REPO/releases/latest/download/opencode-linux-arm64.tar.gz"
muted "Downloading…"
curl -fsSL "$URL" -o "$TMP/opencode.tar.gz" || err "Download failed"

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
  "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null || true
fi

NEW="$("$BIN" --version 2>/dev/null | head -1 || echo "installed")"
info "Updated to: $NEW"

# ─── Note about Bun ─────────────────────────────────────────────────────────
BUN_BIN="$HOME_DIR/.local/share/opencode-termux/bun/bin/bun"
if [ -x "$BUN_BIN" ]; then
  muted "Bun is installed — re-run bootstrap for Bun updates"
fi
UPDATE_SCRIPT

chmod 755 "$UPDATE_SCRIPT"
ok "update script created ($UPDATE_SCRIPT)"

# ─── Create workspace ───────────────────────────────────────────────────────
if [ ! -d "$WORKSPACE" ]; then
  info "Creating workspace at $WORKSPACE…"
  mkdir -p "$WORKSPACE"
  cat > "$WORKSPACE/opencode.json" << 'WORKSPACE_CONFIG'
{
  "$schema": "https://opencode.ai/config.json",
  "terminal": {
    "compact": true,
    "maxTokensPerRequest": 4096,
    "autoApprove": false
  },
  "web": {
    "port": 3000,
    "host": "127.0.0.1"
  }
}
WORKSPACE_CONFIG
  ok "workspace created"
else
  ok "workspace already exists"
fi

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
  printf "  ${GREEN}Workspace:${NC}  %s\n" "$WORKSPACE"
  printf "  ${GREEN}Update:${NC}     %s\n" "$UPDATE_SCRIPT"
  echo ""
  info "${BOLD}Usage${NC}"
  echo ""
  printf '%s\n' "  ${GREEN}opencode${NC}                Terminal UI"
  printf '%s\n' "  ${GREEN}opencode web${NC}            Web interface"
  printf '%s\n' "  ${GREEN}opencode-termux-update${NC}  Safe update (preserves launcher)"
  printf '%s\n' "  ${GREEN}opencode providers${NC}      Add API keys"
  printf '%s\n' "  ${GREEN}bunx${NC}                    Run OpenCode plugins via Bun"
  echo ""
  muted "Never run 'opencode update' directly — use opencode-termux-update instead."
echo ""
