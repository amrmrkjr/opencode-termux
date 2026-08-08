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
3. **Downloads the pinned official OpenCode binary** — the `opencode-linux-arm64.tar.gz` tarball for the exact release tag in `bootstrap.sh`, SHA-256 verified before extraction (mismatch aborts the install)
4. **Patchelf's the interpreter** — sets the binary's dynamic linker to Termux's glibc loader (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`)
5. **Installs Bun** — official binary pinned to `bun-v1.3.14`, SHA-256 verified, stored as `buno`; launchers `bun`/`bunx` route through the `bun-termux` wrapper (or a shell wrapper fallback)
6. **Bun launcher repair pass** — re-links the wrapper shim and re-points `bun`/`bunx` at the wrapper on every run (idempotent), so stale or partial installs self-heal
7. **Creates launcher** — `$PREFIX/bin/opencode` with self-healing patchelf (re-applies after self-update)
8. **Creates update script** — `$PREFIX/bin/opencode-termux-update` installs the pinned release after verifying its SHA-256
9. **Configures DNS** — writes `nsswitch.conf` for glibc's NSS resolver

## Version pinning & checksums

OpenCode and Bun are **pinned to exact release tags** — the bootstrap never chases "latest". Each download is verified against its pinned SHA-256 before anything is extracted or installed; a mismatch aborts with an error.

| Component | Pinned value | Source of the hash |
|-----------|-------------|--------------------|
| OpenCode | v1.18.15 (`OPENCODE_VERSION` / `OPENCODE_SHA256`) | GitHub API asset digest for the pinned tag (no SHA256SUMS asset is shipped) |
| Bun | bun-v1.3.14 (`BUN_VERSION` / `BUN_SHA256`) | Official `SHASUMS256.txt` shipped in the pinned Bun release |

To bump to a newer release: edit `OPENCODE_VERSION`/`OPENCODE_SHA256` (and `BUN_VERSION`/`BUN_SHA256` for Bun) at the top of `bootstrap.sh` using that release's real tag and asset sha256, then re-run bootstrap. The generated `opencode-termux-update` continues to install whatever is pinned.

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
| `opencode-termux-update` | Install the pinned release (SHA-256 verified, preserves launcher) |
| `opencode providers` | Add API keys |
| `bun` / `bunx` | Run OpenCode plugins via Bun |

Never run `opencode update` directly — it restores the original interpreter and breaks the wrapper. Use `opencode-termux-update`, which installs the exact pinned version after verifying its SHA-256. To bump the pinned version, edit `OPENCODE_VERSION`/`OPENCODE_SHA256` (and `BUN_VERSION`/`BUN_SHA256` for Bun) at the top of `bootstrap.sh` and re-run bootstrap.

## Troubleshooting

**`opencode` command not found** — restart the Termux session or run `source ~/.bashrc` to reload PATH.

**glibc error on launch** — run `opencode-termux-update` to re-install the pinned release and re-apply patchelf.

**Bun/bunx fail or plugins won't load** — re-run the bootstrap. Its Bun-launcher repair pass re-links the wrapper shim and re-points `bun`/`bunx` at the wrapper on every run, so stale installs self-heal. If the `bun-on-termux` clone fails, the bootstrap falls back to shell wrappers automatically.

**LD_PRELOAD errors after an update** — the launcher and update script unset `LD_PRELOAD` themselves (termux-exec's preload breaks glibc binaries). Use the `bun`/`bunx` launchers rather than calling `~/.bun/bin/buno` directly.

## Uninstall

```bash
bash projects/termux-opencode/uninstall.sh
```

Removes the OpenCode binary, launcher, update script, Bun and its launchers, and completions. It also prompts to purge the glibc package stack (interactive `y` defaults to keep on EOF/unattended runs) and to remove the `~/opencode` workspace. The workspace hook in `.bashrc`/`.zshrc` is stripped on uninstall.

## Requirements

- Termux from [F-Droid](https://f-droid.org/packages/com.termux/) (not Play Store)
- ARM64 (aarch64) device (enforced by the bootstrap)
- Android 11+ recommended
- ~500 MB free space (checked by the bootstrap)
- Internet on first run

## Support

If this helps you, consider [buying me a coffee](https://ko-fi.com/m3jdtt).
