# Repository Guidelines

## Scope

This repository contains a Bash manager for an IKEv2 server on supported Ubuntu
LTS releases. Keep changes compatible with the existing single-script design.

## Start of Work

- Read `docs/MAP.md` first. Locate a function with
  `grep -n <name> docs/INDEX.md` rather than reading the manager script whole:
  it is 4399 lines.
- Run `git status -sb` and preserve unrelated changes.

## Structure

- `scripts/ikev2-manager.sh` — installer and interactive manager.
- `tests/run-tests.sh` — tests for sourceable helper functions.
- `docs/INDEX.md` — generated function index; regenerate with
  `scripts/gen-index.sh` after adding or renaming a function.
- `.github/workflows/check.yml` — shell validation in GitHub Actions.

## Working rules

- Inspect the existing implementation before editing; avoid broad refactors.
- Keep repository-facing documentation concise, neutral, and free of marketing
  language or automation-tool attribution.
- Do not commit credentials, ACME provider tokens, VPN passwords, certificates,
  private keys, exports, or files from `/opt/ikev2-manager`.
- Treat firewall, routing, certificate, user database, and uninstall paths as
  security-sensitive.
- Preserve support for the Ubuntu releases listed in
  `SUPPORTED_UBUNTU_VERSIONS` unless the task changes it.
- Generated artifacts (firewall script, sysctl, certificate helpers) must
  carry the `GENERATED_TAG` version marker so an upgrade can detect and
  regenerate files written by an older version.
- Firewall rules must stay idempotent (check-then-act) and must never persist
  the ambient ruleset: other software owns rules on the same host.

## Validation

Run the checks relevant to the change:

```bash
bash -n scripts/ikev2-manager.sh tests/run-tests.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```

If a required local tool is unavailable, report which check was not run.
