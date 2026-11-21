<p align="center">
  <img src="https://raw.githubusercontent.com/termux/termux-app/master/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" alt="Termux" width="70">
</p>

<p align="center">
<a href="https://github.com/amrmrkjr/opencode-termux/stargazers"><img src="https://img.shields.io/github/stars/amrmrkjr/opencode-termux?style=for-the-badge&logo=github&label=Stars&color=facc15&labelColor=1a1a2e" alt="Stars"></a>
  <a href="https://github.com/amrmrkjr/opencode-termux/actions"><img src="https://img.shields.io/github/actions/workflow/status/amrmrkjr/opencode-termux/ci.yml?style=for-the-badge&logo=github-actions&label=CI&color=22c55e&labelColor=1a1a2e" alt="CI"></a>
  <a href="https://github.com/amrmrkjr/opencode-termux/releases"><img src="https://img.shields.io/github/v/release/amrmrkjr/opencode-termux?style=for-the-badge&logo=linux&label=Version&color=a855f7&labelColor=1a1a2e" alt="Release"></a>
 <img src="https://img.shields.io/badge/OpenCode-Termux-ec4899?style=for-the-badge&labelColor=1a1a2e" alt="OpenCode">
  <img src="https://img.shields.io/badge/Android-7.0%2B-3b82f6?style=for-the-badge&logo=android&labelColor=1a1a2e" alt="Android">
  <img src="https://img.shields.io/badge/Termux-FDroid-f97316?style=for-the-badge&logo=terminal&labelColor=1a1a2e" alt="Termux">
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

Releases are **pinned** (no "latest" chasing) and every downloaded binary is **SHA-256 verified** before install; a checksum mismatch aborts the install.

After install, these commands are available:

```
opencode                Terminal UI
opencode web            Web interface
opencode-termux-update       Install the latest v2 release (never run `opencode update`)
opencode-termux-install      Pick any OpenCode version from a menu
opencode-termux-bun-update   Install the newest Bun release
opencode-termux-bun-install  Pick any Bun version from a menu
opencode providers           Add API keys
bunx                         Run OpenCode plugins/personas via Bun
```

> **Update safely:** Run `opencode-termux-update` instead of `opencode update`. It installs the latest v2 release from GitHub, verified against the release asset SHA-256, and preserves the launcher. The built-in `opencode update` restores the original ELF interpreter and breaks the Termux wrapper.

**Want an older version?** Run `opencode-termux-install`. It lists every OpenCode release that has a Termux-compatible arm64 binary — tag and release date, 25 per page. Type the number you see and it installs that version with the same SHA-256 verification and launcher repair. You never have to type a version tag. `opencode-termux-update` still moves you to the newest v2 afterwards. For scripts, `opencode-termux-install v1.18.32` skips the menu.

**Bun versions work the same way.** `opencode-termux-bun-update` installs the newest stable Bun release; `opencode-termux-bun-install` shows a numbered menu of all releases with both `bun-linux-aarch64.zip` and `SHASUMS256.txt`. Both swap only `~/.bun/bin/buno` — `bun` and `bunx` keep routing through the Termux wrapper — and verify the zip against that release's SHASUMS256.txt before installing. `opencode-termux-bun-install bun-v1.3.0` skips the menu for scripts.

---

## How It Works

OpenCode ships a glibc-linked binary for linux-arm64, but Termux uses Android's bionic libc. Four mechanisms bridge the gap:

**1. glibc compatibility layer** — the bootstrap installs `glibc-repo`, `glibc`, `patchelf-glibc`, and `binutils-glibc` from Termux's official repository, installed under `$PREFIX/glibc/`. This gives OpenCode the standard glibc ABI it needs.

**2. Patchelf** — the bootstrap rewrites the binary's ELF interpreter (`/lib/ld-linux-aarch64.so.1`) to Termux's glibc loader (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`). One header edit, no recompilation.

**3. Self-healing launcher** — the wrapper at `$PREFIX/bin/opencode` checks on every invocation whether the binary's interpreter still points to glibc. If `opencode update` replaces the binary (restoring the original interpreter), the launcher detects the mismatch and re-applies patchelf before execution. You never need to re-patch manually.

Termux's `termux-exec` package uses `LD_PRELOAD` to intercept filesystem calls. This breaks glibc binaries. The launcher unsets `LD_PRELOAD` before invoking the binary, ensuring clean dynamic linking.

**4. Bun, handled the same way** — Bun is installed as a patchelf'd official binary stored as `buno`, launched through a C wrapper (`bun-termux`) built from `bun-on-termux`, or a shell wrapper fallback. The bootstrap re-links the wrapper shim and re-points the `bun`/`bunx` launchers at the wrapper on **every** run (idempotent), so stale or partial installs self-heal.

---

## Requirements

- **Termux** from [F-Droid](https://f-droid.org/packages/com.termux/) — the Play Store version is outdated and won't work
- **ARM64** (aarch64) device **required for the OpenCode bootstrap** (enforced by the bootstrap)
- **Android 7.0+** minimum for Termux
- **~500 MB** free space (checked by the bootstrap)
- **Internet** on first run

---

## After Installation

The bootstrap creates the following structure:

```
~/.local/share/opencode-termux/
├── bin/opencode                  Patched OpenCode binary
└── completions/                  Shell completions (bash/zsh/fish)

~/.bun/
└── bin/
    ├── bun-termux                Termux wrapper (preferred)
    └── buno                      Official Bun binary (patchelf'd)
```

System-level paths:

| Path | Purpose |
|------|---------|
| `$PREFIX/bin/opencode` | Launcher entry point |
| `$PREFIX/bin/opencode-termux-update` | Safe update script |
| `$PREFIX/bin/opencode-termux-install` | Version picker / installer |
| `$PREFIX/bin/opencode-termux-bun-update` | Bun update script |
| `$PREFIX/bin/opencode-termux-bun-install` | Bun version picker / installer |
| `$PREFIX/bin/bun` | Bun launcher |
| `$PREFIX/bin/bunx` | Bunx launcher |

---

## FAQ

**Why does OpenCode need glibc on Termux?**
OpenCode ships a glibc-linked binary, but Termux uses Android's bionic libc. The glibc compatibility layer bridges this mismatch.

**Can I use `opencode update`?**
No. It restores the original ELF interpreter, which breaks the Termux wrapper. Use `opencode-termux-update`, which installs the latest v2 release from GitHub after verifying its SHA-256.

**How do I upgrade OpenCode?**
Releases are pinned in `projects/termux-opencode/bootstrap.sh`. To bump: edit `OPENCODE_VERSION`, `OPENCODE_SHA256` (and `BUN_VERSION`, `BUN_SHA256` for Bun) at the top of that file (matching a real release tag and its asset sha256), then re-run the bootstrap. The generated `opencode-termux-update` now installs the latest v2 release from GitHub (it no longer uses the pinned version from bootstrap).

**How do I install an older version?**
Run `opencode-termux-install`, pick a release from the numbered list, and it installs that exact tag. Only releases with an `opencode-linux-arm64.tar.gz` asset are listed. Its checksum is read from that release's GitHub metadata and verified before install. To stay on an old version, simply don't run `opencode-termux-update` — that command always goes to the newest v2.

**How do I change the Bun version?**
Run `opencode-termux-bun-install` and pick from the numbered list, or run `opencode-termux-bun-update` to go to the newest stable release. Only `~/.bun/bin/buno` is replaced; the `bun`/`bunx` launchers and wrapper stay as they are. The zip is checked against the release's SHASUMS256.txt before install. Pinned versions stay in `bootstrap.sh` for clean installs; these commands change only the currently installed Bun.

**Does this work on any Android device?**

**Does this work on any Android device?**
ARM64 (aarch64) only for the OpenCode bootstrap; Termux itself runs on additional architectures.

**How do I uninstall?**
Run `bash projects/termux-opencode/uninstall.sh` from the cloned repo.

**What about root?**
No root needed. Everything runs in Termux's standard userspace.

---

## Uninstall

```bash
bash projects/termux-opencode/uninstall.sh
```

Removes the OpenCode binary, launcher, update script, Bun and its launchers, and completions. It also prompts to purge the glibc package stack and to remove the `~/opencode` workspace. The workspace hook in `.bashrc`/`.zshrc` is stripped on uninstall.

---

## Troubleshooting

**`opencode` command not found**
Restart the Termux session or run `source ~/.bashrc` to reload your PATH.

**glibc error on launch**
Run `opencode-termux-update` to re-install the latest v2 release and re-apply patchelf.

**Bun/bunx fail or plugins won't load**
Re-run the bootstrap. Its Bun-launcher repair pass re-links the shim and re-points `bun`/`bunx` at the wrapper on every run, so stale installs self-heal. A git clone failure (needed to build the `bun-termux` wrapper) falls back to the official binary with shell wrappers automatically.

**LD_PRELOAD errors after an update**
The launcher and update script unset `LD_PRELOAD` themselves (termux-exec's preload breaks glibc binaries). If a raw `buno` invocation fails with a linker error, use `bun`/`bunx` (the launchers) instead of calling `~/.bun/bin/buno` directly.

---

## License

**MIT** — see [LICENSE](LICENSE).

## Support

<a href="https://ko-fi.com/m3jdtt"><img src="https://img.shields.io/badge/Buy_me_a_coffee-FF5E5B?style=flat-square&logo=ko-fi&logoColor=white" alt="Ko-fi"></a>
