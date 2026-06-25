# IKEv2 Manager

[Русский](README.md)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Checks](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml/badge.svg)](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml)

Interactive Bash manager for installing and maintaining an IKEv2/IPsec server
on Ubuntu. It targets a single-server setup based on strongSwan with `swanctl`,
ACME certificates, EAP-MSCHAPv2 users, and firewall rules.

## Status

Ubuntu 22.04 LTS and 24.04 LTS are supported. The current stable release is
`v1.3.0`.

## Features

- IKEv2 server installation, reinstallation, and removal;
- ACME certificates through `acme.sh` with `dns-01` or `http-01`;
- VPN user management and client configuration export;
- IPv4 full tunnel, IPv6 leak protection, or NAT66;
- optional VPN client isolation and inbound firewall restrictions;
- diagnostics, logs, service control, and certificate renewal;
- optional MTProto proxy management ([mtproto.zig](https://github.com/sleep3r/mtproto.zig) by Aleksandr Kalashnikov, MIT) and 3x-ui.

## Requirements

- Ubuntu 22.04 LTS or 24.04 LTS;
- `root` access;
- systemd and iptables;
- a public domain name pointing to the server.

## Installation

Pinned stable release:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/v1.3.0/scripts/ikev2-manager.sh)
```

Current `main` branch:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/main/scripts/ikev2-manager.sh)
```

Review remote scripts before running them and prefer a pinned release tag.

## Usage and configuration

The script opens an interactive menu. Managed state is stored under
`/opt/ikev2-manager`.

- Allow UDP ports `500` and `4500` in any external firewall.
- `http-01` requires inbound TCP port `80` while issuing a certificate.
- `dns-01` requires credentials for the selected DNS provider.
- VPN passwords and exported client bundles contain secrets.

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
keys, or client bundles. See [SECURITY.md](SECURITY.md) for vulnerability
reporting guidance.

## License

[MIT](LICENSE). Copyright notices for bundled components are in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
