#!/usr/bin/env bash
# Builds an installable arm64 release (Barc.app, .pkg, .dmg, SHA256SUMS.txt)
# containing RustCore (libbarc_core.dylib) and custom-compiled WebKit frameworks.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: Tools/package-custom-webkit-release.sh X.Y.Z [output-directory]" >&2
  exit 2
fi

out="${2:-build/releases/$version}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
app="$out/Barc.app"
stem="Barc-$version-arm64"
build_number="${BUILD_NUMBER:-$(( $(git rev-list --count HEAD 2>/dev/null || echo 303) + 1 ))}"

unset RAM_LOG
VERSION="$version" BUILD_NUMBER="$build_number" \
  ./Tools/bundle-custom-webkit.sh "$app"

# Ensure the local RAM history log is not present in the shipped binary.
if grep -q "barc-local-ram-log" "$app/Contents/MacOS/Barc-bin"; then
  echo "error: local RAM history log found in release binary; refusing to package." >&2
  exit 1
fi

echo "Verifying strict deep code signature..."
codesign --verify --strict --deep "$app"

echo "Building installer package ($stem.pkg)..."
COPYFILE_DISABLE=1 pkgbuild \
  --component "$app" \
  --install-location /Applications \
  --identifier io.github.mcgri.Barc \
  --version "$version" \
  "$out/$stem.pkg"

pkgutil --payload-files "$out/$stem.pkg" > "$out/package-files.txt"
if grep -E '(^|/)(\.git|_local|session\.json|History|Cookies|Login Data)(/|$)' "$out/package-files.txt"; then
  echo "error: unexpected private working data in installer payload." >&2
  exit 1
fi

echo "Building disk image ($stem.dmg)..."
stage="$(mktemp -d "$out/.dmg-staging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto --noextattr --norsrc "$app" "$stage/Barc.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/INSTALL.txt" <<INSTALL
Barc $version (Apple Silicon, Custom WebKit + RustCore)

Requires macOS 15+ on Apple Silicon (arm64).
Drag Barc.app onto Applications, then open Barc from Applications.

Includes:
- Custom-compiled WebKit (libpas 50 ms scavenger, 0-cap WebProcessCache,
  1.15x x 1.35x GPU tile coverage, 16 MB MemoryCache cap).
- Embedded RustCore (Brave adblock-rust in WebKit NetworkProcess + LZ4
  out-of-line interactionState blobs).

This local build is ad-hoc signed, not Developer ID signed or notarized.
INSTALL

hdiutil create -ov -volname "Barc $version" -fs HFS+ -format UDZO -srcfolder "$stage" "$out/$stem.dmg"
hdiutil verify "$out/$stem.dmg"

(
  cd "$out"
  shasum -a 256 "$stem.dmg" "$stem.pkg" > SHA256SUMS.txt
)

echo "Installable release $version (build $build_number) ready in $out:"
ls -lh "$out/$stem.dmg" "$out/$stem.pkg" "$out/SHA256SUMS.txt"
