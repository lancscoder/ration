# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Development

```sh
make test   # unit tests
make run    # build build/Ration.app and launch it
```

Ground rules the code follows; please keep to them:

- **Read-only credentials.** Ration never refreshes Claude Code's OAuth token and never writes to the Keychain.
- **No secrets or content in logs.** Log with `os.Logger`; never log tokens, prompts or message content.
- **No third-party dependencies** unless they're clearly worth it. Open an issue first.

## Releases

Every merge to `main` publishes a release through GitHub Actions (`.github/workflows/ci.yml`). Changes that only touch Markdown files, the licence, `packaging/` or `.github/` don't.

1. The workflow runs the tests on macOS.
2. `scripts/next-version.sh` picks the version. The `VERSION` file holds the minimum. If it's ahead of the latest `v*` tag it's used as is; otherwise the latest tag's patch number goes up by one. To release a new minor or major version, change `VERSION` in your pull request (e.g. to `1.2.0`).
3. `make package cask` builds `Ration.app` as a release build, zips it, signs the zip and writes the Homebrew cask.
4. The workflow creates the tag and the GitHub release, with generated notes and these assets: `Ration-<version>.zip`, `Ration-<version>.zip.sig` and `ration.rb`.

Installed copies pick the release up within a day.

### The update signing key

Ration only installs updates signed with the maintainer's Ed25519 key. The public half is `UpdateConfig.publicKey` in `Sources/RationCore/Updates.swift`. The private half lives:

- in the `UPDATE_SIGNING_KEY` repository secret, for CI;
- at `~/.config/ration/update-signing-key` on the maintainer's Mac, for local `make release`, plus an offline backup.

It is never committed. Tools for it:

```sh
swift scripts/update-signing.swift generate <key-file>      # new key pair; prints the public key
swift scripts/update-signing.swift public <key-file>        # print the public key
swift scripts/update-signing.swift sign <key-file> <file>   # writes <file>.sig
```

If the key ever has to change, ship a release signed with the **old** key that contains the **new** public key, then switch the secret. Otherwise existing installs refuse every later update and their users have to update by hand once.

### Homebrew

Each release includes the cask (`ration.rb`). Copy it into `Casks/ration.rb` in [lancscoder/homebrew-tap](https://github.com/lancscoder/homebrew-tap). The cask sets `auto_updates true`, because the app updates itself.
