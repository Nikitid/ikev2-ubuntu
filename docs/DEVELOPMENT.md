# Development

## Checks

```bash
bash -n scripts/ikev2-manager.sh
shellcheck scripts/ikev2-manager.sh tests/run-tests.sh
shfmt -i 2 -bn -ci -d scripts/ikev2-manager.sh tests/run-tests.sh
bash tests/run-tests.sh
```

CI runs the same set on every push, over every shell file.

## Release

Push a `vX.Y.Z` tag that matches `SCRIPT_VERSION` in
`scripts/ikev2-manager.sh`. The release workflow runs the tests, attaches
`ikev2-manager.sh` and `SHA256SUMS`, and publishes notes made by
`scripts/release-notes.sh` from the commit subjects since the previous tag.
