<!-- Modified for Barc: application identity, branding and legal documentation, 2026-10-23. -->
# Barc

My goal is to copy Arc's UI and UX because I'm too lazy, and maybe too old, to get used to a new browser.

I forked [Kylmora](https://github.com/kylmora/kylmora) to make a browser that fits my needs and the way I work. You're welcome to use Barc, share feedback, contribute, or fork it and make it your own.

Original browser: [Kylmora source code](https://github.com/kylmora/kylmora) and [kylmora.com](https://kylmora.com).

Barc started with Kylmora's source code and full Git history, preserving the original work and its recorded changes. Barc's changes continue from Kylmora commit [`08059591cfc740d3f5f94622a3674ad360abb378`](https://github.com/kylmora/kylmora/commit/08059591cfc740d3f5f94622a3674ad360abb378). The original README is retained unchanged in [UPSTREAM.md](UPSTREAM.md) as historical documentation; its downloads, services and branding describe Kylmora.

## Download and install

Download [Barc 0.0.2](https://github.com/mcgri/Barc/releases/tag/v0.0.2) for **Apple Silicon or Intel Macs running macOS 14 or later**.

- Open the `.dmg` and drag Barc to Applications, or use the `.pkg` installer.
- Version 0.0.2 is ad-hoc signed and **not notarized by Apple**. macOS may prevent first launch; see [Apple's guidance](https://support.apple.com/en-us/102445).
- Browser profiles and migration data are not included. Import your own data after opening Barc.

## Build and run

Requires macOS 14 or later and a Swift 6 toolchain.

```sh
make bundle
make run
```

The app is built at `build/Barc.app` with Barc's B ribbon icon and its own application identity. To run tests:

```sh
make test
```

Local builds are ad-hoc signed. To create universal `.dmg` and `.pkg` installers locally:

```sh
Tools/package-unsigned-release.sh 0.0.2
```

The output is in `build/release/`, with checksums and release notes. Version tags trigger the release workflow. It uses signed/notarized packaging when Barc's signing credentials are configured; otherwise it publishes installers explicitly marked as unnotarized.

## Import from Arc

Open Settings → Import → **Import from Arc…**, choose `~/Library/Application Support/Arc`, then review the detected profiles and data categories. The Arc action under Settings → Sync opens the same importer.

Each Arc profile gets a separate website identity in Barc. Arc Spaces that share a profile keep sharing it. The importer restores supported tabs, nested folders, favourites, archives, full history, bookmarks, saved passwords, cookies, local storage, addresses, search shortcuts and download records. Archived web tabs from deleted Spaces go into a separate Unassigned Arc archive Space. Payment cards stay in Arc.

Use a Space's **Set Profile** menu to select or create a profile. Spaces using the same profile share Favorites and browsing data while keeping their own tab lists and appearance. Deleting a Space keeps its profile and saved data. Switching Spaces needs no browser restart.

Barc reads a private copy of Arc's files, including pending database writes. Existing Barc data is kept. Repeating an import uses source identifiers to avoid duplicating imported records and preserves existing destination passwords, cookies and local-storage values. macOS may ask for access to **Arc Safe Storage** to read encrypted passwords and cookies. If access is declined, the other selected categories can still be imported.

Importing the sidebar restores the selected Arc Spaces' relative order while keeping unrelated Barc Spaces in their current positions. Arc's extended-sRGB Space colours are mapped into Barc's supported colour range.

The search-data option restores a detected default search engine for the imported Spaces, including choices in Arc's Secure Preferences. If the choice cannot be identified, the current Barc choice is kept and noted in the report.

Review the result before relying on imported website sessions. The report lists per-profile counts, verification, skipped records and unavailable data, and is saved under `Arc Imports` in Barc's application-data folder. A session backup is saved before each import.

Some websites require signing in again. Partitioned cookies and partitioned local storage are skipped to preserve their isolation. Cookies without a name cannot be represented by WebKit's public cookie API and are reported as unavailable. Cookie lifetimes are kept, including session-only cookies, which may end when the browser quits. WebKit can reject storage that exceeds its quota. IndexedDB databases, tab-scoped session storage, passkeys, extensions, generic form suggestions and Arc's back/forward stacks, scroll positions and in-page form state remain in Arc. Search shortcuts use Barc's shared engine list; history, passwords, addresses and website data use the matching profile identity.

The [implementation plan](docs/arc-import-plan.md) describes the supported formats and verification requirements.

## Import from Apple Passwords

Open Settings → Passwords → **Import passwords from macOS…**. The dialog opens Apple Passwords and explains how to export all or selected passwords. Choose the exported CSV in Barc to import it into the profile shown in the dialog. Existing logins are kept, and repeated imports skip accounts already stored for the same website and profile.

Imported passwords use Barc's encrypted local vault. This is a one-time copy, with no iCloud synchronization. The exported CSV is unencrypted; delete it after importing. Passkeys and verification codes are not imported. The current local build does not have Apple's browser permission for iCloud passkeys or the iCloud Passwords extension.

Saved-account suggestions work on email-first and password login steps. Click the login field, or press the down arrow while it is focused, to choose an account. Suggestions use only the current profile.

## Barc identity

- App and executable: `Barc`
- Bundle and preferences ID: `io.github.mcgri.Barc`
- Application data: `~/Library/Application Support/io.github.mcgri.Barc/`
- URL schemes: `barc://` and `barc-webapp://`
- Command-line helper: `Tools/barc`, bundled as `Contents/Resources/barc-cli`
- Keychain labels and services, sync folders, native-messaging identifiers and generated web-app identities use Barc's namespace.

Barc can run alongside Kylmora using separate settings and data locations. Rebranding does not import or alter an existing Kylmora profile. Website passwords use Barc's own encrypted vault and do not change another browser's password items.

Website passwords are encrypted with AES-256-GCM in `Passwords/website-passwords.barc` inside Barc's application-data folder. One macOS login-Keychain item protects the random encryption key. A successful unlock is kept in memory for the app session, so an application update can require one vault approval rather than a separate approval for every password. Profile records stay separate. The vault does not use iCloud Keychain sync.

Earlier per-login Keychain entries remain untouched. Records that macOS already permits reading without a prompt are copied into the vault without replacing newer vault values. Reimporting from Arc can restore those source credentials into the vault without approving each older entry. Arc's approved source key is held only in memory for the current import window and cleared when it closes or a different folder is chosen. Repeating an import in that window does not request the source key again.

The icon source is [Resources/Icon/barc-icon.png](Resources/Icon/barc-icon.png). `make icon` packages it into [Resources/Barc.icns](Resources/Barc.icns).

## Updates and support

Barc has no automatic release feed configured yet. Automatic checks default to off, and the update checker returns an explanatory status without contacting Kylmora. Source and future builds belong in [this repository](https://github.com/mcgri/Barc).

Reports and feature requests open editable drafts in [Barc's GitHub issues](https://github.com/mcgri/Barc/issues). Nothing is published until the user submits it on GitHub. Reports do not go to Kylmora's contact service. See [SECURITY.md](SECURITY.md) for vulnerability reporting.

## Following Kylmora development

`origin` refers to [this Barc repository](https://github.com/mcgri/Barc). `upstream` is a name for the [original Kylmora repository](https://github.com/kylmora/kylmora). After cloning Barc, you can add that address and download Kylmora's development history and release tags with:

```sh
git remote add upstream https://github.com/kylmora/kylmora.git
git fetch upstream --tags
```

Run `git remote add` only once per clone. If `upstream` is already configured, use just `git fetch upstream --tags` to refresh it. Fetching does not change Barc's files or merge Kylmora updates. Bringing those changes into Barc is a separate step.

## License, attribution and trademarks

Barc is distributed under the [Apache License 2.0](LICENSE). The original license text is unchanged. Original copyright and attribution notices are preserved, modified source files identify Barc's changes, and [NOTICE](NOTICE) records the upstream attribution and fork changes. `make bundle` includes both `LICENSE` and `NOTICE` in the app's resources; they are linked from Settings → About.

When redistributing Barc, include `LICENSE` and `NOTICE`, retain applicable upstream notices, and mark any files you change. These requirements come from [section 4 of the Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). Any additional third-party components must retain their own required licences and notices.

The folder and Space icon palettes use artwork from [Ionicons](https://github.com/ionic-team/ionicons), copyright Ionic, under the [MIT License](LICENSES/Ionicons.txt). Its license is also included in the app's resources. The Space emoji picker uses names and ordering from [Unicode 15.1](https://unicode.org/Public/emoji/15.1/emoji-test.txt), copyright Unicode, under the [Unicode License V3](LICENSES/Unicode.txt). That license is bundled too. Emoji artwork comes from the macOS system font.

Original browser copyright notice: © 2026 Kylmora · kylmora.com. Barc-specific modifications: © 2026 Barc contributors.

Barc is not an official Kylmora release and is not affiliated with or endorsed by Kylmora, Arc or The Browser Company. Their names and marks belong to their respective owners. The Apache license does not grant rights to use upstream trademarks. The Barc B icon is separate artwork inspired by Arc's visual style; Arc's original icon is not bundled as Barc's icon.

The software is provided without warranties, subject to the terms in `LICENSE`. These notes supplement the license and do not replace or change it.
