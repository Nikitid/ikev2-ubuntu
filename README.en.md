# ikev2-ubuntu

[Русский](README.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Checks](https://github.com/Nikitid/ikev2-ubuntu/actions/workflows/check.yml/badge.svg)](https://github.com/Nikitid/ikev2-ubuntu/actions/workflows/check.yml)

Interactive Bash manager for installing and maintaining an IKEv2/IPsec server
on Ubuntu. It targets a single-server setup based on strongSwan with `swanctl`,
ACME certificates, EAP-MSCHAPv2 users, and firewall rules.

## Status

Ubuntu 22.04, 24.04 and 26.04 LTS are supported. The current stable release
is `v1.5.0`.

## Features

- IKEv2 server installation, reinstallation, and removal;
- ACME certificates through `acme.sh` with `dns-01` or `http-01`;
- VPN user management and client configuration export;
- IPv4 full tunnel, IPv6 leak protection, or NAT66;
- optional VPN client isolation and inbound firewall restrictions;
- egress policy that keeps clients away from cloud metadata, private
  networks and the host itself;
- diagnostics, logs, active sessions, service control, and certificate
  renewal;
- daily certificate expiry check reported to the journal;
- optional MTProto proxy management ([telemt](https://github.com/telemt/telemt),
  TELEMT Public License).

## Requirements

- Ubuntu 22.04, 24.04 or 26.04 LTS;
- `root` access;
- systemd and iptables;
- a public domain name pointing to the server.

## Installation

Pinned stable release:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-ubuntu/v1.5.0/scripts/ikev2-manager.sh)
```

Current `main` branch:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-ubuntu/main/scripts/ikev2-manager.sh)
```

Review remote scripts before running them and prefer a pinned release tag.

## Usage and configuration

The script opens an interactive menu. Managed state is stored under
`/opt/ikev2-manager`.

- Allow UDP ports `500` and `4500` in any external firewall.
- `http-01` requires inbound TCP port `80` while issuing a certificate and on
  every unattended renewal; inbound hardening keeps that port open in this
  mode.
- `dns-01` requires credentials for the selected DNS provider.
- VPN passwords and exported client bundles contain secrets.

### Non-interactive commands

```bash
ikev2-manager.sh --check        # state report, non-zero exit on a problem
ikev2-manager.sh --reconcile    # regenerate managed files, reapply state
ikev2-manager.sh --diagnostics  # full diagnostics report
ikev2-manager.sh --version
```

`--check` is suitable for monitoring: it fails when the service is down, the
certificate expires within 21 days, firewall rules are missing, or generated
files are stale.

### Egress policy

`internet-only` (default) drops traffic from the client pool to cloud
metadata (`169.254.0.0/16`), private ranges and to services on the VPN host
itself; configured client DNS servers stay reachable. Services on the VPN
host that clients still need (SSH over the tunnel, the MTProto proxy) are
listed as host ports. `open` restores the previous behaviour of routing
everything. The policy can be changed in Service menu -> Inbound hardening /
client isolation / egress policy.

### Upgrading

Generated files carry the version that produced them. On the first start
after an upgrade the manager regenerates the firewall script, sysctl and
certificate helpers and reapplies them, so a configuration change made in an
older version cannot stay unapplied. The same can be triggered with
`--reconcile`.

### Windows error 13801 after certificate renewal

New Let's Encrypt chains may contain multiple intermediate certificates. The
manager loads them as untrusted intermediate certificates and loads the system
root as the trust anchor. This makes strongSwan send the complete chain in
IKE_AUTH. After updating an existing installation, reissue the certificate
from the service menu and check `Loaded CA chain files` in diagnostics.

## Development

```bash
bash -n scripts/ikev2-manager.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```

See [AGENTS.md](AGENTS.md) for repository-specific working rules.

## Security

Do not publish `/opt/ikev2-manager` state, passwords, certificates, private
keys, or client bundles. Report a vulnerability through a private security
advisory on GitHub.

## License

[MIT](LICENSE). Copyright notices for bundled components are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
