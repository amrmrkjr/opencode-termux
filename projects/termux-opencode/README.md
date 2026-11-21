# termux-opencode bootstrap

One-command installer for running [OpenCode](https://github.com/anomalyco/opencode) natively on Android via Termux.

## Quick start

**One-liner (no clone needed):**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/amrmrkjr/opencode-termux/main/projects/termux-opencode/bootstrap.sh)"
```

**Or clone and run:**
```bash
git clone https://github.com/amrmrkjr/opencode-termux
cd opencode-termux
bash projects/termux-opencode/bootstrap.sh
```

## What it does

1. **glibc compatibility layer** — installs `glibc-repo`, `glibc`, `patchelf-glibc`, `binutils-glibc`
2. **Deps** — `curl jq tar ripgrep clang make git` (git is required to build the Bun wrapper from `tribixbite/bun-on-termux`), plus Node.js/npm
3. **Downloads the official OpenCode binary** — the `opencode-linux-arm64.tar.gz` tarball for the exact release tag in `bootstrap.sh`, SHA-256 verified before extraction (mismatch aborts the install). The bootstrap pins versions for reproducibility; the generated `opencode-termux-update` now installs the latest v2 release from GitHub (independent of the pinned version).
4. **Patchelf's the interpreter** — sets the binary's dynamic linker to Termux's glibc loader (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`)
5. **Installs Bun** — official binary pinned to `bun-v1.4.5`, SHA-256 verified, stored as `buno`; launchers `bun`/`bunx` route through the `bun-termux` wrapper (or a shell wrapper fallback)
6. **Bun launcher repair pass** — re-links the wrapper shim and re-points `bun`/`bunx` at the wrapper on every run (idempotent), so stale or partial installs self-heal
7. **Creates launcher** — `$PREFIX/bin/opencode` with self-healing patchelf (re-applies after self-update)
8. **Creates update script** — `$PREFIX/bin/opencode-termux-update` installs the latest v2 release from GitHub after verifying its SHA-256. It also creates `$PREFIX/bin/opencode-termux-install`, a numbered menu of every release with an arm64 asset so older versions can be installed without typing a tag.
9. **Configures DNS** — writes `nsswitch.conf` for glibc's NSS resolver

## How it works

Termux uses bionic libc, Android's standard C library. OpenCode ships as a glibc-linked linux-arm64 binary that expects `/lib/ld-linux-aarch64.so.1` — a path that does not exist on Termux. Running the binary as-is produces "No such file or directory" on the ELF interpreter.

The bootstrap resolves this by installing the `glibc-repo` package from Termux's official repository, which provides `glibc`, `patchelf-glibc`, and `binutils-glibc`. These packages install a full glibc runtime tree under `$PREFIX/glibc/`, including `ld-linux-aarch64.so.1` and all required shared libraries (`libc.so.6`, `libm.so.6`, `libpthread.so.0`, etc.). This gives OpenCode the standard glibc ABI it needs. If `libc.so` is shipped as a linker script (a text file) rather than a real shared object, the bootstrap replaces it with a symlink to `libc.so.6`, which the runtime loader requires.

The OpenCode binary's ELF interpreter is rewritten using `patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"`. This changes the `.interp` section so that the kernel loads the binary through Termux's glibc loader instead of the missing system path. No recompilation, no re-linking — just a single ELF header edit.

The launcher at `$PREFIX/bin/opencode` wraps the patchelf'd binary and includes a self-healing mechanism: on every invocation it checks whether the binary's current interpreter still points to the glibc loader. If OpenCode's built-in `update` command replaces the binary (restoring the original interpreter), the launcher detects the mismatch and re-applies patchelf before execution. This means the user never has to manually re-patch after an update.

Termux's `termux-exec` package uses `LD_PRELOAD` to intercept filesystem calls and translate Termux paths. This preload breaks glibc binaries — its symbols in bionic's libc conflict with glibc's. The launcher unsets `LD_PRELOAD` before invoking the binary, ensuring clean dynamic linking against glibc. The same approach is used for the Bun runtime, which is downloaded as an official `bun-linux-aarch64` binary, patchelf'd to the glibc loader, and launched through either a C wrapper (`bun-termux`) or a shell wrapper fallback that also unsets `LD_PRELOAD`.

## File structure after installation

```
~/.local/share/opencode-termux/
├── bin/
│   └── opencode                 Patched ELF binary (glibc interpreter)
└── completions/
    ├── opencode.bash            Bash completion script
    └── opencode.zsh             Zsh completion script

~/.bun/
└── bin/
    ├── bun-termux               Termux wrapper (preferred)
    └── buno                     Official Bun binary (patchelf'd)
```

System-level paths created:

| Path | Purpose |
|------|---------|
| `$PREFIX/bin/opencode` | Launcher entry point |
| `$PREFIX/bin/opencode-termux-update` | Safe update script |
| `$PREFIX/bin/bun` | Bun launcher (if installed) |
| `$PREFIX/bin/bunx` | Bunx launcher (if installed) |
| `$PREFIX/glibc/lib/ld-linux-aarch64.so.1` | glibc dynamic linker |
| `$PREFIX/glibc/bin/patchelf` | ELF patching tool |
| `$PREFIX/glibc/etc/nsswitch.conf` | glibc DNS resolver config |

## Environment variables

The bootstrap does not export environment variables globally. Instead, the launcher script sets these at invocation time:

| Variable | Value | Purpose |
|----------|-------|---------|
| `LD_PRELOAD` | *(unset)* | Prevents termux-exec from interposing glibc syscall wrappers |
| `SSL_CERT_FILE` | `$PREFIX/etc/tls/cert.pem` | Points OpenCode at Termux's CA certificates for HTTPS API calls |

**Shell integration:**

- **Bash**: completion script sourced from `~/.local/share/opencode-termux/completions/opencode.bash` via `~/.bashrc`
- **Zsh**: completion script sourced from `~/.local/share/opencode-termux/completions/opencode.zsh` via `~/.zshrc`
- **Fish**: completion script installed to `~/.config/fish/completions/opencode.fish`

**Bun environment** (when installed via shell wrapper fallback):

| Variable | Value | Purpose |
|----------|-------|---------|
| `BUN_INSTALL` | `$HOME/.bun` | Bun runtime root |
| `TMPDIR` | `$HOME/.bun/tmp` | Temporary directory for Bun operations |

## Commands (after install)

| Command | Description |
|---------|-------------|
| `opencode` | Terminal UI |
| `opencode web` | Web interface |
| `opencode-termux-update` | Install the latest v2 release from GitHub (SHA-256 verified, preserves launcher) |
| `opencode-termux-install` | Pick any available version from a numbered menu (or pass an exact tag) |
| `opencode-termux-bun-update` | Install the newest stable Bun release (SHA-256 verified, preserves launchers) |
| `opencode-termux-bun-install` | Pick any Bun version from a numbered menu (or pass an exact tag) |
| `opencode providers` | Add API keys |
| `bun` / `bunx` | Run OpenCode plugins via Bun |

Never run `opencode update` directly — it restores the original interpreter and breaks the wrapper. Use `opencode-termux-update`, which installs the latest v2 release from GitHub after verifying its SHA-256. To bump the pinned version in bootstrap (for reproducibility only), edit `OPENCODE_VERSION`/`OPENCODE_SHA256` (and `BUN_VERSION`/`BUN_SHA256` for Bun) at the top of `bootstrap.sh` and re-run bootstrap.

To install an older release, run `opencode-termux-install`. It fetches all upstream releases, keeps only those with an `opencode-linux-arm64.tar.gz` asset, and shows them newest-first with release dates (25 per page, `n`/`p` to navigate, `q` to quit). Type the number shown and the chosen tag is handed to the updater's exact-tag path, which reads that release's asset digest from GitHub and verifies the download before installing. Pass a tag directly — `opencode-termux-install v1.18.32` — to skip the menu. Running plain `opencode-termux-update` afterwards still moves to the newest v2.

Bun uses the same pair of commands: `opencode-termux-bun-update` installs the newest stable Bun release, while `opencode-termux-bun-install` lists releases that have both `bun-linux-aarch64.zip` and `SHASUMS256.txt`. Both download the zip and that release's checksum file, verify with `sha256sum`, replace only `~/.bun/bin/buno`, re-apply patchelf, and restore the wrapper's `bun-shim.so` symlink. The `bun` and `bunx` launchers are never rewritten. Set `BUN_VERSION=<tag>` on the update command (or pass the tag to the installer) to pin an exact release. The bootstrap's `BUN_VERSION`/`BUN_SHA256` pins still control clean installs only.

## Troubleshooting

**`opencode` command not found** — restart the Termux session or run `source ~/.bashrc` to reload PATH.

**glibc error on launch** — run `opencode-termux-update` to re-install the latest v2 release and re-apply patchelf.

**Bun/bunx fail or plugins won't load** — re-run the bootstrap. Its Bun-launcher repair pass re-links the wrapper shim and re-points `bun`/`bunx` at the wrapper on every run, so stale installs self-heal. If the `bun-on-termux` clone fails, the bootstrap falls back to shell wrappers automatically.

**LD_PRELOAD errors after an update** — the launcher and update script unset `LD_PRELOAD` themselves (termux-exec's preload breaks glibc binaries). Use the `bun`/`bunx` launchers rather than calling `~/.bun/bin/buno` directly.

## Uninstall

```bash
bash projects/termux-opencode/uninstall.sh
```

Removes the OpenCode binary, launcher, update script, Bun and its launchers, and completions. It also prompts to purge the glibc package stack (interactive `y` defaults to keep on EOF/unattended runs). The bootstrap no longer creates a workspace or adds shell hooks.

## Requirements

- Termux from [F-Droid](https://f-droid.org/packages/com.termux/) (not Play Store)
- ARM64 (aarch64) device **required for the OpenCode bootstrap** (enforced by the bootstrap)
- Android 7.0+ minimum for Termux
- ~500 MB free space (checked by the bootstrap)
- Internet on first run

## Support

If this helps you, consider [buying me a coffee](https://ko-fi.com/m3jdtt).
