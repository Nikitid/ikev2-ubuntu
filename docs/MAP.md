# Repository map

One Bash script and its tests. The map exists because that script is 4399
lines: reading it whole to change ten of them is the thing to avoid.

## The shape of it

`scripts/ikev2-manager.sh` is the whole product - an installer and an
interactive manager for a strongSwan IKEv2 server on Ubuntu LTS. It is
deliberately a single script: it is copied to a fresh server and run there, so
it cannot depend on a repository layout being present.

Sourcing it with `IKEV2_MANAGER_LIB=1` defines the helper functions without
running the installer, which is how `tests/run-tests.sh` reaches them.

## Finding your way inside it

Use the index rather than the file:

```
grep -n <function name> docs/INDEX.md
```

The script's own sections, in the order they appear:

| area | what it covers |
| --- | --- |
| preflight | root check, release support, state directory, error reporting |
| install | packages, strongSwan configuration, certificates, firewall |
| ACME | certificate issue and renewal |
| users | creating, listing and revoking VPN users, client bundles |
| menu | the interactive loop the operator sees |
| state | `state_check` and the non-interactive health report |

## Checks

`tests/run-tests.sh` sources the script and exercises the helpers, then runs
`scripts/check-index.sh`. CI additionally runs `shellcheck` and `shfmt` over
every shell file.

`scripts/gen-index.sh` and `check-index.sh` are vendored from
`repo-templates/templates/shared/` and carry a `# template:` marker; fix them
there, not here.

## Documentation

| file | for |
| --- | --- |
| `AGENTS.md` | the rules of working here |
| `docs/MAP.md` | this file |
| `docs/INDEX.md` | generated function index; grep it |
| `README.md` | operator-facing, Russian |
| `README.en.md` | the English version |
