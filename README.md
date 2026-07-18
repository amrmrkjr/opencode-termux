<p align="center">
  <img src="https://raw.githubusercontent.com/termux/termux-app/master/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="Termux" width="70">
</p>

<p align="center">
  <a href="https://github.com/amrmrkjr/opencode-termux/stargazers"><img src="https://img.shields.io/github/stars/amrmrkjr/opencode-termux?style=for-the-badge&logo=github&label=Stars&color=facc15&labelColor=1a1a2e" alt="Stars"></a>
  <a href="https://github.com/amrmrkjr/opencode-termux/actions"><img src="https://img.shields.io/github/actions/workflow/status/amrmrkjr/opencode-termux/ci.yml?style=for-the-badge&logo=github-actions&label=CI&color=22c55e&labelColor=1a1a2e" alt="CI"></a>
  <a href="https://github.com/amrmrkjr/opencode-termux/releases"><img src="https://img.shields.io/github/v/release/amrmrkjr/opencode-termux?style=for-the-badge&logo=linux&label=Version&color=a855f7&labelColor=1a1a2e" alt="Release"></a>
  <img src="https://img.shields.io/badge/OpenCode-1.17%2B-ec4899?style=for-the-badge&labelColor=1a1a2e" alt="OpenCode">
  <img src="https://img.shields.io/badge/Android-11%2B-3b82f6?style=for-the-badge&logo=android&labelColor=1a1a2e" alt="Android">
  <img src="https://img.shields.io/badge/Termux-FDroid-f97316?style=for-the-badge&logo=terminal&labelColor=1a1a2e" alt="Termux">
  <img src="https://img.shields.io/badge/ARM64-aarch64-06b6d4?style=for-the-badge&labelColor=1a1a2e" alt="ARM64">
  <img src="https://img.shields.io/badge/license-MIT-64748b?style=for-the-badge&labelColor=1a1a2e" alt="MIT">
</p>

<h1 align="center">OpenCode on Termux</h1>
<p align="center"><b>Run OpenCode natively on Android — no root, no proot, no containers.</b></p>

<p align="center">
  <code>bash -c "$(curl -fsSL https://raw.githubusercontent.com/amrmrkjr/opencode-termux/main/projects/termux-opencode/bootstrap.sh)"</code>
</p>

---

## Quick Start

Open Termux and run one of these:

**One-liner (no clone needed):**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/amrmrkjr/opencode-termux/main/projects/termux-opencode/bootstrap.sh)"
```

**Or clone and run:**
```bash
git clone https://github.com/amrmrkjr/opencode-termux.git
cd opencode-termux
bash projects/termux-opencode/bootstrap.sh
```

That's it. The bootstrap installs everything you need — glibc compatibility layer, the OpenCode binary, plus Bun for plugin support.

After install, these commands are available:

```
opencode               Terminal UI
opencode web           Web interface
opencode-termux-update Safe update (never run `opencode update`)
opencode providers     Add API keys
```

> **Update safely:** Run `opencode-termux-update` instead of `opencode update`. The built-in update restores the original ELF interpreter and breaks the Termux wrapper.

---

## How It Works

OpenCode ships a glibc-linked binary for linux-arm64, but Termux uses Android's bionic libc. Three mechanisms bridge the gap:

**1. glibc compatibility layer** — Termux packages provide `glibc`, `patchelf-glibc`, and `binutils-glibc` from its official repository, installed under `$PREFIX/glibc/`. This gives OpenCode the standard glibc ABI it needs.

**2. Patchelf** — the bootstrap rewrites the binary's ELF interpreter (`/lib/ld-linux-aarch64.so.1`) to Termux's glibc loader (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`). One header edit, no recompilation.

**3. Self-healing launcher** — the wrapper at `$PREFIX/bin/opencode` checks on every invocation whether the binary's interpreter still points to glibc. If `opencode update` replaces the binary (restoring the original interpreter), the launcher detects the mismatch and re-applies patchelf before execution. You never need to re-patch manually.

Termux's `termux-exec` package uses `LD_PRELOAD` to intercept filesystem calls. This breaks glibc binaries. The launcher unsets `LD_PRELOAD` before invoking the binary, ensuring clean dynamic linking.

---

## Requirements

- **Termux** from [F-Droid](https://f-droid.org/packages/com.termux/) — the Play Store version is outdated and won't work
- **ARM64** (aarch64) device
- **~500 MB** free space
- **Internet** on first run

---

## After Installation

The bootstrap creates the following structure:

```
~/.local/share/opencode-termux/
├── bin/opencode                  Patched OpenCode binary
├── completions/                  Shell completions (bash/zsh/fish)
├── launcher.sh                   Wrapper script entry point
└── bun/                          Bun runtime (plugin system)

~/opencode/                       Default workspace
└── opencode.json                 Workspace config
```

System-level paths:

| Path | Purpose |
|------|---------|
| `$PREFIX/bin/opencode` | Launcher entry point |
| `$PREFIX/bin/opencode-termux-update` | Safe update script |
| `$PREFIX/bin/bun` | Bun launcher |
| `$PREFIX/bin/bunx` | Bunx launcher |

---

## FAQ

**Why does OpenCode need glibc on Termux?**
OpenCode ships a glibc-linked binary, but Termux uses Android's bionic libc. The glibc compatibility layer bridges this mismatch.

**Can I use `opencode update`?**
No. It restores the original ELF interpreter, which breaks the Termux wrapper. Use `opencode-termux-update`.

**Does this work on any Android device?**
ARM64 only, Android 11+ recommended. Install Termux from F-Droid, not the Play Store.

**How do I uninstall?**
Run `bash projects/termux-opencode/uninstall.sh` from the cloned repo.

**What about root?**
No root needed. Everything runs in Termux's standard userspace.

---

## Uninstall

```bash
bash projects/termux-opencode/uninstall.sh
```

Removes the OpenCode binary, launcher, update script, and optionally the workspace and glibc packages.

---

## Troubleshooting

**`opencode` command not found**
Restart the Termux session or run `source ~/.bashrc` to reload your PATH.

**glibc error on launch**
Run `opencode-termux-update` to re-patch the binary.

**Configuration error / unrecognized keys**
Check `~/opencode/opencode.json` for invalid keys and remove them.

**Bun won't compile**
The bootstrap falls back to a shell wrapper automatically. No action needed.

---

## License

**MIT** — see [LICENSE](LICENSE).

## Support

<a href="https://ko-fi.com/m3jdtt"><img src="https://img.shields.io/badge/Buy_me_a_coffee-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white" alt="Ko-fi"></a>
