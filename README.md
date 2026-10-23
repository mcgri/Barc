# Barc

Barc is a fork of [Kylmora](https://github.com/kylmora/kylmora), a native macOS browser built with Swift, AppKit and the system WebKit engine.

This repository starts with the complete upstream source and Git history. Browser behaviour and the app's internal Kylmora name are unchanged in this initial fork. The original documentation is preserved in [UPSTREAM.md](UPSTREAM.md).

## Build locally

Requires macOS 14 or later and a Swift 6 toolchain.

```sh
make bundle
```

The initial fork produces `build/Kylmora.app`. Running it uses Kylmora's existing application identity and data locations. Give Barc its own application identity before running it alongside an existing Kylmora installation.

```sh
make test
```

Local builds are ad-hoc signed. Public distribution requires a separate signing and release setup.

## Repository setup

- `origin`: https://github.com/mcgri/Barc.git
- `upstream`: https://github.com/kylmora/kylmora.git
- Initial upstream commit: `08059591cfc740d3f5f94622a3674ad360abb378`

New clones can add the upstream remote with:

```sh
git remote add upstream https://github.com/kylmora/kylmora.git
git fetch upstream --tags
```

Upstream release tags are available in the original local checkout. Barc's own releases and branding have not been configured yet.

## License and attribution

The inherited source remains under [Apache License 2.0](LICENSE). Original copyright and attribution notices are preserved. This is an independent fork and is not an official Kylmora release.
