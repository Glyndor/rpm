# rpm

[![CI](https://github.com/Glyndor/rpm/actions/workflows/tests.yml/badge.svg)](https://github.com/Glyndor/rpm/actions/workflows/tests.yml)

The RPM package repository for Glyndor's products, to be served at
`rpm.glyndor.net`.

## Status

This channel does not publish anything yet. There is no package to install and no
repository to add, so this page has no install commands. I will document the
installation here when the channel starts to publish.

What the repository holds today is its CI and the public key it will be signed with.

## Signing key

The packages and the repository metadata will be signed with an OpenPGP Ed25519 key
that belongs to this channel alone. Its public half is `keyring/glyndor-rpm-key.asc`, and its
fingerprint is:

```text
FA78 C216 E917 65E1 950A 2927 8903 DA0D 602C 7E28
```

Check a key you are handed against this fingerprint before you trust it. The
repository tests fail if the key in `keyring/` is not the one written here.

## Contributing

The guide is in [CONTRIBUTING.md](CONTRIBUTING.md). Pull requests are invitation-only;
issues are open to everyone.

## License

[MIT](LICENSE)
