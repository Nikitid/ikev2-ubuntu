# Repository Guidelines

## Scope

This repository contains a Bash manager for an IKEv2 server on supported Ubuntu
LTS releases. Keep changes compatible with the existing single-script design.

## Structure

- `scripts/ikev2-manager.sh` — installer and interactive manager.
- `tests/run-tests.sh` — tests for sourceable helper functions.
- `.github/workflows/check.yml` — shell validation in GitHub Actions.

## Working rules

- Inspect the existing implementation before editing; avoid broad refactors.
- Keep repository-facing documentation concise, neutral, and free of marketing
  language or automation-tool attribution.
- Do not commit credentials, ACME provider tokens, VPN passwords, certificates,
  private keys, exports, or files from `/opt/ikev2-manager`.
- Treat firewall, routing, certificate, user database, and uninstall paths as
  security-sensitive.
- Preserve support for Ubuntu 22.04 and 24.04 unless the task changes it.

## Validation

Run the checks relevant to the change:

```bash
bash -n scripts/ikev2-manager.sh tests/run-tests.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```

If a required local tool is unavailable, report which check was not run.
