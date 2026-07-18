#!/data/data/com.termux/files/usr/bin/bash
# uninstall.sh — Remove OpenCode Termux bootstrap
#
# Safely removes everything installed by bootstrap.sh:
#   - OpenCode binary and data
#   - Launcher and update script
#   - glibc packages (optional)
#   - Workspace directory (optional)
#
set -euo pipefail

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
DIM=$'\033[0;2m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { printf "${GREEN}◆${NC} %s\n" "$*"; }
warn()  { printf "${RED}  ⚠${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}  ✓${NC} %s\n" "$*"; }
muted() { printf "${DIM}  %s${NC}\n" "$*"; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
BIN_DIR="$HOME_DIR/.local/share/opencode-termux"
LAUNCHER="$PREFIX/bin/opencode"
UPDATE_SCRIPT="$PREFIX/bin/opencode-termux-update"
WORKSPACE="$HOME_DIR/opencode"

echo ""
info "${BOLD}OpenCode Termux — Uninstall${NC}"
echo ""
muted "This will remove OpenCode and all its components."
echo ""

# ─── Step 1: Remove launcher ────────────────────────────────────────────────
info "Removing launcher…"
if [ -f "$LAUNCHER" ] || [ -L "$LAUNCHER" ]; then
  rm -f "$LAUNCHER"
  ok "removed $LAUNCHER"
else
  muted "not found"
fi

# ─── Step 2: Remove update script ───────────────────────────────────────────
info "Removing update script…"
if [ -f "$UPDATE_SCRIPT" ]; then
  rm -f "$UPDATE_SCRIPT"
  ok "removed $UPDATE_SCRIPT"
else
  muted "not found"
fi

# ─── Step 3: Remove Bun ─────────────────────────────────────────────────────
BUN_LAUNCHER="$PREFIX/bin/bun"
BUNX_LINK="$PREFIX/bin/bunx"
BUN_DIR="$HOME_DIR/.bun"
if [ -f "$BUN_LAUNCHER" ] || [ -L "$BUN_LAUNCHER" ]; then
  info "Removing Bun launcher…"
  rm -f "$BUN_LAUNCHER"
  ok "removed $BUN_LAUNCHER"
fi
if [ -f "$BUNX_LINK" ] || [ -L "$BUNX_LINK" ]; then
  rm -f "$BUNX_LINK"
  ok "removed $BUNX_LINK"
fi
if [ -d "$BUN_DIR" ]; then
  rm -rf "$BUN_DIR"
  ok "removed $BUN_DIR"
fi

# ─── Step 4: Remove shell completions ───────────────────────────────────────
info "Removing shell completions…"
COMP_DIR="$HOME_DIR/.local/share/opencode-termux/completions"
if [ -d "$COMP_DIR" ]; then
  rm -rf "$COMP_DIR"
  ok "removed completion files"
fi

# Remove source lines from shell configs
for rc in ".bashrc" ".zshrc"; do
  RC_FILE="$HOME_DIR/$rc"
  if [ -f "$RC_FILE" ]; then
    sed -i '/opencode\.\(bash\|zsh\)/d' "$RC_FILE" 2>/dev/null || true
  fi
done

# Remove fish completion
FISH_COMP_DIR="$HOME_DIR/.config/fish/completions"
FISH_COMP_FILE="$FISH_COMP_DIR/opencode.fish"
if [ -f "$FISH_COMP_FILE" ]; then
  rm -f "$FISH_COMP_FILE"
  ok "removed fish completion"
fi

# ─── Step 5: Remove binary and data ─────────────────────────────────────────
info "Removing OpenCode binary and data…"
if [ -d "$BIN_DIR" ]; then
  rm -rf "$BIN_DIR"
  ok "removed $BIN_DIR"
else
  muted "not found"
fi

# ─── Step 6: Optionally remove workspace ────────────────────────────────────
if [ -d "$WORKSPACE" ]; then
  echo ""
  printf '%s' "${DIM}  Remove workspace at ${BOLD}$WORKSPACE${DIM}? [y/N] ${NC}"
  read -r RESP
  case "$RESP" in
    y|Y|yes|YES)
      rm -rf "$WORKSPACE"
      ok "removed $WORKSPACE"
      ;;
    *)
      muted "kept $WORKSPACE"
      ;;
  esac
fi

# ─── Step 7: Optionally remove glibc packages ───────────────────────────────
echo ""
printf '%s' "${DIM}  Remove glibc packages (glibc, patchelf-glibc, binutils-glibc)? [y/N] ${NC}"
read -r RESP
case "$RESP" in
  y|Y|yes|YES)
    info "Removing glibc packages…"
    # Normal removal first
    pkg remove -y glibc patchelf-glibc binutils-glibc glibc-repo 2>/dev/null || true
    # Force purge leftover glibc-* dependency packages (common after repeated install/uninstall)
    dpkg --purge --force-all 2>/dev/null \
      glibc patchelf-glibc binutils-glibc glibc-repo \
      glibc-runner attr-glibc binutils-libs-glibc brotli-glibc gcc-libs-glibc \
      json-c-glibc libblkid-glibc libbz2-glibc libcap-ng-glibc libjansson-glibc \
      liblz4-glibc liblzma-glibc libnghttp2-glibc libsmartcols-glibc \
      libunistring-glibc libuuid-glibc libxcrypt-glibc ncurses-glibc perl-glibc \
      termux-exec-glibc zlib-glibc bash-glibc coreutils-glibc libacl-glibc \
      libgmp-glibc libcap-glibc libpam-glibc strace-glibc libpsl-glibc \
      krb5-glibc util-linux-glibc libcurl-glibc libdb-glibc libpcap-glibc \
      libssh2-glibc openssl-glibc readline-glibc zstd-glibc libdebuginfod-glibc \
      libelf-glibc libevent-glibc libidn2-glibc libunwind-glibc libverto-glibc \
      linux-api-headers-glibc ca-certificates-glibc e2fsprogs-glibc gdbm-glibc \
      bash-completion-glibc libacl-glibc || true
    # Remove the glibc directory and any stale symlinks
    rm -rf /data/data/com.termux/files/usr/glibc
    rm -f /data/data/com.termux/files/usr/include/asm
    ok "glibc packages removed"
    ;;
  *)
    muted "kept glibc packages"
    ;;
esac

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Uninstall complete${NC}"
echo ""
muted "OpenCode and related files have been removed."
echo ""
