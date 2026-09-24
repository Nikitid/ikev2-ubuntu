# IKEv2 Manager for Ubuntu

[Русский](README.ru.md)

[![CI](https://github.com/Nikitid/ikev2-ubuntu/actions/workflows/check.yml/badge.svg)](https://github.com/Nikitid/ikev2-ubuntu/actions/workflows/check.yml)
[![Release](https://img.shields.io/github/v/release/Nikitid/ikev2-ubuntu)](https://github.com/Nikitid/ikev2-ubuntu/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`ikev2-manager.sh` is an interactive Bash script that installs and maintains an
IKEv2/IPsec server on Ubuntu. It targets a single server and uses strongSwan
with `swanctl`, ACME certificates, EAP-MSCHAPv2 users and firewall rules.

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

Latest release, with a checksum check:

```bash
curl -fsSLO https://github.com/Nikitid/ikev2-ubuntu/releases/latest/download/ikev2-manager.sh
curl -fsSLO https://github.com/Nikitid/ikev2-ubuntu/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS
sudo bash ikev2-manager.sh
```

Current `main` branch, unchecked:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-ubuntu/main/scripts/ikev2-manager.sh)
```

Review a remote script before running it.

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

## Security

Do not publish `/opt/ikev2-manager` state, passwords, certificates, private
keys, or client bundles, including in an issue: the Support section below says
where a vulnerability goes instead.

## Development

```sh
bash tests/run-tests.sh
```

Linting and releasing: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Documentation

- [Repository map](docs/MAP.md) - how the script and its checks are laid out
- [Third-party licenses](THIRD_PARTY_LICENSES.md)
- [Development](docs/DEVELOPMENT.md) - checks and releasing

## Support

Questions and bug reports go to
[Issues](https://github.com/Nikitid/ikev2-ubuntu/issues/new/choose): pick the form that
fits. Report a vulnerability privately through
[a security advisory](https://github.com/Nikitid/ikev2-ubuntu/security/advisories/new).
English or Russian is fine.

## License

[MIT](LICENSE). Copyright notices for bundled components are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
