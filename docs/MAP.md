# Repository map

One Bash script and its tests.

## The shape of it

`scripts/ikev2-manager.sh` is the whole product - an installer and an
interactive manager for a strongSwan IKEv2 server on Ubuntu LTS. It is
deliberately a single script: it is copied to a fresh server and run there, so
it cannot depend on a repository layout being present.

Sourcing it with `IKEV2_MANAGER_LIB=1` defines the helper functions without
running the installer, which is how `tests/run-tests.sh` reaches them.

## Finding your way inside it

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
`scripts/check-readme.sh`. CI additionally runs `shellcheck` and `shfmt` over
every shell file.

`scripts/release-notes.sh` and `scripts/check-readme.sh` carry a `# template:`
marker: they are shared with the sibling repositories, so fix them at the
source rather than here.

## Documentation

| file | for |
| --- | --- |
| `docs/MAP.md` | this file |
| `docs/DEVELOPMENT.md` | checks and releasing |
| `README.md` | user-facing, English |
| `README.ru.md` | the Russian version |
