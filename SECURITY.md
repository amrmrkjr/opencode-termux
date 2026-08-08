# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.** Use GitHub's private vulnerability reporting instead:

1. Go to **Security** → **Report a vulnerability** (direct link: `https://github.com/amrmrkjr/opencode-termux/security/advisories/new`)
2. Describe the issue — what it is, how to reproduce, and the impact
3. Keep it focused; add proof-of-concept or logs if helpful

Reports are acknowledged within a few days.

## Scope

This repository contains the OpenCode installer for Termux (Android): installation scripts, environment setup, and documentation under `projects/`. Security-relevant items:

- Anything in the installer scripts that downloads or executes code
- Leaked secrets or tokens
- A malicious or compromised dependency in the install path

## Supported versions

`main` is the only supported branch. Releases are tagged (`v*`); fixes land on `main` and are released as new tags. The latest release is the only supported release.

## Security features

- Secret scanning with push protection
- Dependabot alerts + security updates for GitHub Actions
- CodeQL analysis on every push
- Private vulnerability reporting (this policy)
- Branch protection: force-push and branch deletion are blocked on `main`