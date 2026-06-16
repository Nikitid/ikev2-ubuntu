# IKEv2 Manager

![License](https://img.shields.io/github/license/Nikitid/ikev2-manager)
[![Build status](https://img.shields.io/github/actions/workflow/status/Nikitid/ikev2-manager/check.yml?branch=main&label=Build)](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml)
[![ShellCheck](https://img.shields.io/github/actions/workflow/status/Nikitid/ikev2-manager/check.yml?branch=main&label=ShellCheck)](https://github.com/Nikitid/ikev2-manager/actions/workflows/check.yml)

Interactive Bash manager for deploying and maintaining an IKEv2 VPN server on **Ubuntu 22.04 / 24.04**.

The script focuses on a practical single-server setup: strongSwan with `swanctl`, ACME certificates, basic firewall/NAT rules, VPN user management, and local client configuration export. It also includes optional management menus for MTProxy and 3x-ui on the same host.

## Features

- Install and reconfigure an IKEv2 VPN server
- Configure strongSwan / `swanctl`
- Issue and install certificates through `acme.sh`
- Support `dns-01` and `http-01` ACME validation modes
- Manage VPN users with username, password, group, and platform labels
- Export local client bundles for Windows, iOS, macOS, and Ubuntu
- Configure IPv4 forwarding and iptables NAT rules
- Keep ESP proposals compatible with Apple CHILD_SA rekeying (prevents periodic disconnects)
- IPv6 modes: leak protection (default), full IPv6 via NAT66, or IPv4-only
- Reapply firewall rules and reissue certificates from the menu
- Show service status, diagnostics, recent logs, and client info
- Uninstall managed VPN files, firewall rules, ACME bindings, and strongSwan packages
- Optional MTProxy installation and management
- Optional 3x-ui installation and management through the official installer

## Supported Systems

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- root access
- systemd
- iptables-based firewall management
- public domain name for the VPN server

## Quick Install

Run the latest version from `main`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/main/scripts/ikev2-manager.sh)
```

Run a tagged release:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Nikitid/ikev2-manager/v1.0.1/scripts/ikev2-manager.sh)
```

## Notes

- The script must be run as root.
- For `http-01` certificate validation, TCP port `80` must be reachable from the internet.
- For `dns-01`, you need an `acme.sh` DNS provider name and its required API credentials.
- External cloud firewalls or security groups must allow UDP `500` and UDP `4500` for IKEv2.
- IPv6 modes: `block` (default) hands clients a ULA address and a `::/0` selector, then drops their IPv6 on the server — dual-stack clients cannot leak IPv6 around the tunnel; `nat` gives clients working IPv6 through NAT66 (the host needs a global IPv6 address); `off` keeps the old IPv4-only behavior and leaks IPv6 on dual-stack clients.
- The script writes managed state under `/opt/ikev2-manager` (root-only, `chmod 700`).
- VPN user passwords are stored in plaintext in `/opt/ikev2-manager/users.db` — this is required by EAP-MSCHAPv2, which needs the original password on the server.
- Exported client bundles under `/opt/ikev2-manager/exports` contain plaintext credentials; treat them as secrets when copying off the server.
- VPN configuration is generated at `/etc/swanctl/swanctl.conf`.
- Firewall rules are applied through iptables and persisted when `iptables-save` is available.
- Existing installs with older ESP proposal lists are automatically expanded with Apple-compatible rekey proposals when the manager reloads configuration.

## Development

```bash
bash -n scripts/ikev2-manager.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```
