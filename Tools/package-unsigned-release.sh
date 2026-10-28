#!/bin/bash
# Modified for Barc: universal, explicitly unnotarized installer releases, 2026-10-28.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: Tools/package-unsigned-release.sh X.Y.Z [output-directory]" >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Packaging requires macOS and the Xcode command-line tools." >&2
    exit 2
fi
out="${2:-build/release}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
app="$out/Barc.app"
stem="Barc-$version-universal"

# Only the built app is packaged. Browser profiles, the checkout and local
# working material never enter the staging directory.
make bundle BUILD_DIR="$out" ARCHS="arm64 x86_64" DEV_ID=
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$app/Contents/Info.plist"
codesign --force --sign - --identifier io.github.mcgri.Barc --entitlements Resources/Barc.entitlements "$app"
codesign --verify --strict --deep "$app"
lipo "$app/Contents/MacOS/Barc" -verify_arch arm64 x86_64

COPYFILE_DISABLE=1 make pkg BUILD_DIR="$out" INSTALLER_ID= PKG_SUFFIX="-$version-universal"
pkgutil --payload-files "$out/$stem.pkg" > "$out/package-files.txt"
if grep -E '(^|/)(\.git|_local|session\.json|History|Cookies|Login Data)(/|$)' "$out/package-files.txt"; then
    echo "Unexpected private working data in the installer payload." >&2
    exit 1
fi

stage="$(mktemp -d "$out/.dmg-staging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto --noextattr --norsrc "$app" "$stage/Barc.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/INSTALL.txt" <<INSTALL
Barc $version

Requires macOS 14 or later. Supports Apple Silicon and Intel Macs.
Drag Barc.app onto Applications, then open Barc from Applications.

This release is ad-hoc signed, not Developer ID signed or notarized
by Apple. macOS may prevent first launch. See Apple's guidance:
https://support.apple.com/en-us/102445

Source and license: https://github.com/mcgri/Barc
INSTALL
hdiutil create -ov -volname "Barc $version" -fs HFS+ -format UDZO -srcfolder "$stage" "$out/$stem.dmg"
hdiutil verify "$out/$stem.dmg"
(
    cd "$out"
    shasum -a 256 "$stem.dmg" "$stem.pkg" > SHA256SUMS.txt
)
cat > "$out/RELEASE-NOTES.md" <<NOTES
# Barc $version

Barc is a personal fork of [Kylmora](https://github.com/kylmora/kylmora), built for my own taste. My goal is to reduce the browser's footprint while maintaining the original Arc feel.

$(if [[ -f "docs/releases/$version.md" ]]; then cat "docs/releases/$version.md"; fi)

## Download and install

- **$stem.dmg**: open the disk image and drag Barc to Applications.
- **$stem.pkg**: a standard installer that places Barc in Applications.
- **SHA256SUMS.txt**: SHA-256 checksums for both downloads.

Both installers support **Apple Silicon and Intel Macs**, with **macOS 14 or later**. Translation requires macOS 15; extensions require macOS 15.4.

## Signing

This release is **ad-hoc signed and not notarized by Apple**. The installer package is unsigned. macOS may prevent first launch; read [Apple's guidance](https://support.apple.com/en-us/102445) before deciding whether to open it. No security settings are changed by the installer.

## Included

- Arc-style sidebar, address/search launcher, Spaces, Favorites and split views.
- Arc import for supported tabs, folders, history, bookmarks, passwords and website data. Some sites require signing in again.
- Separate website identities for personal and work profiles.

Browser profiles, browsing history, saved passwords, cookies and local migration captures are **not bundled**. Automatic updates are not configured yet; download updates from this release page.

The source is licensed under Apache License 2.0. Original Kylmora notices and third-party licenses are included in the app. This is an independent fork, with no affiliation with Kylmora, Arc or The Browser Company.
NOTES
printf 'Installers ready in %s\n' "$out"
