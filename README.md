<!-- Modified for Barc: application identity, branding and legal documentation, 2026-10-23. -->
# Barc

Barc is an independent fork of [Kylmora](https://github.com/kylmora/kylmora), a native macOS browser built with Swift, AppKit and the system WebKit engine. It provides one window with Spaces, each with its own website identity.

The full upstream Git history is preserved. This fork began at Kylmora commit [`08059591cfc740d3f5f94622a3674ad360abb378`](https://github.com/kylmora/kylmora/commit/08059591cfc740d3f5f94622a3674ad360abb378). The original README is retained unchanged in [UPSTREAM.md](UPSTREAM.md) as historical documentation; its downloads, services and branding describe Kylmora.

## Build and run

Requires macOS 14 or later and a Swift 6 toolchain.

```sh
make bundle
make run
```

The app is built at `build/Barc.app`, using the approved B ribbon icon. To run tests:

```sh
make test
```

Local builds are ad-hoc signed. Signed and notarized releases need Barc's own signing credentials and release configuration.

## Barc identity

- App and executable: `Barc`
- Bundle and preferences ID: `io.github.mcgri.Barc`
- Application data: `~/Library/Application Support/io.github.mcgri.Barc/`
- URL schemes: `barc://` and `barc-webapp://`
- Command-line helper: `Tools/barc`, bundled as `Contents/Resources/barc-cli`
- Keychain labels and services, sync folders, native-messaging identifiers and generated web-app identities use Barc's namespace.

Barc uses its own data locations. Rebranding does not import or alter an existing Kylmora profile. Website passwords saved by Barc use a dedicated Keychain path so saving or deleting a Barc login does not change another browser's item.

The icon source is [Resources/Icon/barc-icon.png](Resources/Icon/barc-icon.png). `make icon` packages it into [Resources/Barc.icns](Resources/Barc.icns).

## Updates and support

Barc has no automatic release feed configured yet. Automatic checks default to off, and the update checker returns an explanatory status without contacting Kylmora. Source and future builds belong in [this repository](https://github.com/mcgri/Barc).

Reports and feature requests open editable drafts in [Barc's GitHub issues](https://github.com/mcgri/Barc/issues). Nothing is published until the user submits it on GitHub. Reports do not go to Kylmora's contact service. See [SECURITY.md](SECURITY.md) for vulnerability reporting.

The local checkout has `origin` pointing to `https://github.com/mcgri/Barc.git` and `upstream` pointing to `https://github.com/kylmora/kylmora.git`. Other clones can add the upstream remote with:

```sh
git remote add upstream https://github.com/kylmora/kylmora.git
git fetch upstream --tags
```

## License, attribution and trademarks

Barc is distributed under the [Apache License 2.0](LICENSE). The original license text is unchanged. Original copyright and attribution notices are preserved, modified source files identify Barc's changes, and [NOTICE](NOTICE) records the upstream attribution and fork changes. `make bundle` includes both `LICENSE` and `NOTICE` in the app's resources; they are linked from Settings → About.

Original browser copyright notice: © 2026 Kylmora · kylmora.com. Barc-specific modifications: © 2026 Barc contributors.

Barc is not an official Kylmora release and is not affiliated with or endorsed by Kylmora, Arc or The Browser Company. Their names and marks belong to their respective owners. The Apache license does not grant rights to use upstream trademarks. The Barc B icon is separate artwork inspired by Arc's visual style; Arc's original icon is not bundled as Barc's icon.

The software is provided without warranties, subject to the terms in `LICENSE`. These notes supplement the license and do not replace or change it.
