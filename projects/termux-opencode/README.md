# termux-opencode bootstrap

One-command installer for running [OpenCode](https://github.com/anomalyco/opencode) natively on Android via Termux.

## Quick start

```bash
git clone https://github.com/amrmrkjr/opencode-termux
cd opencode-termux
bash projects/termux-opencode/bootstrap.sh
```

## What it does

1. **glibc compatibility layer** — installs `glibc-repo`, `glibc`, `patchelf-glibc`, `binutils-glibc`
2. **Downloads official OpenCode binary** — the `opencode-linux-arm64.tar.gz` from GitHub releases
3. **Patchelf's the interpreter** — sets the binary's dynamic linker to Termux's glibc loader (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`)
4. **Creates launcher** — `$PREFIX/bin/opencode` with self-healing patchelf (re-applies after self-update)
5. **Creates update script** — `$PREFIX/bin/opencode-termux-update` for safe binary updates
6. **Configures DNS** — writes `nsswitch.conf` for glibc's NSS resolver
7. **Creates workspace** — `~/opencode/` with Termux-optimized config

## How it works

Termux uses bionic libc, Android's standard C library. OpenCode ships as a glibc-linked linux-arm64 binary that expects `/lib/ld-linux-aarch64.so.1` — a path that does not exist on Termux. Running the binary as-is produces "No such file or directory" on the ELF interpreter.

The bootstrap resolves this by installing the `glibc-repo` package from Termux's official repository, which provides `glibc`, `patchelf-glibc`, and `binutils-glibc`. These packages install a full glibc runtime tree under `$PREFIX/glibc/`, including `ld-linux-aarch64.so.1` and all required shared libraries (`libc.so.6`, `libm.so.6`, `libpthread.so.0`, etc.). This gives OpenCode the standard glibc ABI it needs.

The OpenCode binary's ELF interpreter is rewritten using `patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"`. This changes the `.interp` section so that the kernel loads the binary through Termux's glibc loader instead of the missing system path. No recompilation, no re-linking — just a single ELF header edit.

The launcher at `$PREFIX/bin/opencode` wraps the patchelf'd binary and includes a self-healing mechanism: on every invocation it checks whether the binary's current interpreter still points to the glibc loader. If OpenCode's built-in `update` command replaces the binary (restoring the original interpreter), the launcher detects the mismatch and re-applies patchelf before execution. This means the user never has to manually re-patch after an update.

Termux's `termux-exec` package uses `LD_PRELOAD` to intercept filesystem calls and translate Termux paths. This preload breaks glibc binaries — its symbols in bionic's libc conflict with glibc's. The launcher unsets `LD_PRELOAD` before invoking the binary, ensuring clean dynamic linking against glibc. The same approach is used for the Bun runtime, which is downloaded as an official `bun-linux-aarch64` binary, patchelf'd to the glibc loader, and launched through either a C wrapper (`bun-termux`) or a shell wrapper fallback that also unsets `LD_PRELOAD`.

## File structure after installation

```
~/.local/share/opencode-termux/
├── bin/
│   └── opencode                 Patched ELF binary (glibc interpreter)
├── completions/
│   ├── opencode.bash            Bash completion script
│   └── opencode.zsh             Zsh completion script
├── launcher.sh                  -> $PREFIX/bin/opencode (symlink reference)
└── bun/                         Bun runtime (if installed)
    ├── bin/
    │   └── bun                  Patched bun binary (glibc interpreter)
    └── bin/
        └── bunx                 Bun package runner (symlink)
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

## Configuration

The bootstrap creates a workspace directory at `~/opencode/` with a minimal, Termux-optimized `opencode.json`:

```json
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
```

> **Note:** If you see a "Configuration is invalid / Unrecognized keys" error, remove the `terminal` and `web` keys — newer OpenCode versions have dropped them. The config will still work with just the `$schema` field.

## Commands (after install)

| Command | Description |
|---------|-------------|
| `opencode` | Terminal UI |
| `opencode web` | Web interface |
| `opencode-termux-update` | Safe binary update (preserves launcher) |
| `opencode providers` | Add API keys |

Never run `opencode update` directly — it restores the original interpreter and breaks the wrapper. Use `opencode-termux-update` instead.

## Uninstall

```bash
bash projects/termux-opencode/uninstall.sh
```

Removes OpenCode binary, launcher, update script, and optionally workspace and glibc packages.

## Requirements

- Termux from [F-Droid](https://f-droid.org/packages/com.termux/) (not Play Store)
- ARM64 (aarch64) device
- ~500 MB free space

## Support

If this helps you, consider [buying me a coffee](https://ko-fi.com/m3jdtt).
