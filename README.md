# ikev2-manager

[![Build status](https://img.shields.io/github/actions/workflow/status/Nikitid/ikev2-manager-dev/check.yml?branch=main&label=Build)](https://github.com/Nikitid/ikev2-manager-dev/actions/workflows/check.yml)
[![ShellCheck](https://img.shields.io/github/actions/workflow/status/Nikitid/ikev2-manager-dev/check.yml?branch=main&label=ShellCheck)](https://github.com/Nikitid/ikev2-manager-dev/actions/workflows/check.yml)

## Development

Install ShellCheck locally:

```bash
sudo apt-get update
sudo apt-get install -y shellcheck
```

Install shfmt locally:

```bash
curl -fsSL -o shfmt https://github.com/mvdan/sh/releases/download/v3.13.1/shfmt_v3.13.1_linux_amd64
chmod +x shfmt
sudo mv shfmt /usr/local/bin/shfmt
```

Run checks manually:

```bash
shellcheck scripts/ikev2-manager.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh
```
