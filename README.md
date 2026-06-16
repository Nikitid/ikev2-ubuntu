# IKEv2 Manager

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Build](https://img.shields.io/github/actions/workflow/status/Nikitid/ikev2-manager/check.yml?branch=main&label=build)](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml)
[![ShellCheck](https://img.shields.io/github/actions/workflow/status/Nikitid/ikev2-manager/check.yml?branch=main&label=shellcheck)](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml)

Interactive Bash manager for deploying and maintaining an IKEv2/IPsec VPN server on Ubuntu.

It installs and manages a practical single-server setup based on strongSwan with `swanctl`, ACME certificates, EAP-MSCHAPv2 users, firewall/NAT rules, and local client bundle export.

## Features

- IKEv2 server install, reinstall, and cleanup
- strongSwan / `swanctl` configuration
- ACME certificates through `acme.sh`
- `dns-01` and `http-01` certificate validation
- VPN users with username, password, group, and platform labels
- Local client bundles for Windows, iOS, macOS, and Ubuntu
- IPv4 full-tunnel NAT
- IPv6 leak protection, NAT66, or IPv4-only mode
- Apple-compatible ESP proposals for stable CHILD_SA rekeying
- TCP MSS clamping for tunneled traffic
- Optional VPN client isolation
- Optional inbound firewall hardening
- Diagnostics, logs, service control, and certificate renewal
- Optional MTProxy and 3x-ui management

## Supported Systems

- Ubuntu 22.04 LTS or 24.04 LTS
- root access
- systemd
- iptables
- public domain name for the VPN server

## Install

Latest `main`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/main/scripts/ikev2-manager.sh)
```

Pinned release:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/v1.2.0/scripts/ikev2-manager.sh)
```

## Notes

- Open UDP `500` and UDP `4500` in any external firewall or cloud security group.
- For `http-01`, TCP `80` must be reachable while issuing the certificate.
- For `dns-01`, provide the selected `acme.sh` DNS provider credentials.
- Managed state is stored under `/opt/ikev2-manager`.
- VPN passwords and exported client bundles contain secrets. Keep them private.
- Existing installs with older ESP proposal lists are automatically updated for Apple rekey compatibility when configuration is regenerated.

## Development

```bash
bash -n scripts/ikev2-manager.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```
