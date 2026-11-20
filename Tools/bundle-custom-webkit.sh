#!/usr/bin/env bash
# Bundles Barc-CustomWebKit.app with RustCore (libbarc_core.dylib) and custom-compiled WebKit frameworks + XPC services.
# Uses a tiny native Mach-O trampoline in Contents/MacOS/Barc to configure DYLD_FRAMEWORK_PATH + __XPC_DYLD_FRAMEWORK_PATH
# (the canonical macOS WebKit override mechanism so transitive system libs like libswiftWebKit.dylib and XPC services
# all bind cleanly to our custom-built WebKit without duplicate Objective-C classes or version mismatches).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEBKIT_BUILD="${WEBKIT_BUILD:-/Volumes/DiskC/browsermigration/barc-webkit/WebKitBuild/Release}"
RUST_DYLIB="$ROOT_DIR/RustCore/target/release/libbarc_core.dylib"
APP_BUNDLE="${1:-$ROOT_DIR/build/Barc-CustomWebKit.app}"
ENTITLEMENTS="$ROOT_DIR/Resources/Barc.entitlements"
BUNDLE_ID="io.github.mcgri.Barc"

if [ ! -f "$RUST_DYLIB" ]; then
  echo "Building RustCore..."
  cargo build --release --manifest-path "$ROOT_DIR/RustCore/Cargo.toml"
fi

if [ ! -f "$WEBKIT_BUILD/WebKit.framework/Versions/A/WebKit" ]; then
  echo "error: custom WebKit build not found at $WEBKIT_BUILD/WebKit.framework/Versions/A/WebKit" >&2
  exit 1
fi

echo "Building fresh base Barc bundle into $APP_BUNDLE..."
unset SDKROOT
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  make -C "$ROOT_DIR" bundle APP_BUNDLE="$APP_BUNDLE"

FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

echo "Copying RustCore (libbarc_core.dylib)..."
cp -f "$RUST_DYLIB" "$FRAMEWORKS/libbarc_core.dylib"
install_name_tool -id "@rpath/libbarc_core.dylib" "$FRAMEWORKS/libbarc_core.dylib"

CUSTOM_FRAMEWORKS=(
  JavaScriptCore
  WebGPU
  WebInspectorUI
  WebCore
  WebKitLegacy
  WebKit
)

echo "Copying custom WebKit frameworks from $WEBKIT_BUILD..."
for name in "${CUSTOM_FRAMEWORKS[@]}"; do
  fw="${name}.framework"
  if [ -d "$WEBKIT_BUILD/$fw" ]; then
    rm -rf "$FRAMEWORKS/$fw"
    ditto "$WEBKIT_BUILD/$fw" "$FRAMEWORKS/$fw"
    # Strip Headers / PrivateHeaders / Modules to keep app size compact
    rm -rf "$FRAMEWORKS/$fw/Headers" "$FRAMEWORKS/$fw/PrivateHeaders" "$FRAMEWORKS/$fw/Modules" \
           "$FRAMEWORKS/$fw/Versions/A/Headers" "$FRAMEWORKS/$fw/Versions/A/PrivateHeaders" "$FRAMEWORKS/$fw/Versions/A/Modules" 2>/dev/null || true
  fi
done

# Materialize XPCServices inside WebKit.framework (in WebKitBuild they are symlinks to ../../../../com.apple.WebKit.*.xpc)
XPC_DIR="$FRAMEWORKS/WebKit.framework/Versions/A/XPCServices"
mkdir -p "$XPC_DIR"
echo "Materializing custom WebKit XPC services..."
for xpc_src in "$WEBKIT_BUILD"/com.apple.WebKit.*.xpc; do
  [ -d "$xpc_src" ] || continue
  xpc_name="$(basename "$xpc_src")"
  rm -rf "$XPC_DIR/$xpc_name"
  ditto "$xpc_src" "$XPC_DIR/$xpc_name"
done

# Copy companion dylibs built by WebKit (libwebrtc.dylib, libANGLE-shared.dylib)
for dylib in "$WEBKIT_BUILD"/*.dylib; do
  [ -e "$dylib" ] || continue
  base="$(basename "$dylib")"
  case "$base" in
    *TestSupport*|*TestingInterop*|*DumpRenderTree*|*TestRunner*) continue ;;
  esac
  cp -f "$dylib" "$FRAMEWORKS/$base"
done

# Build a tiny native Mach-O launcher trampoline at Contents/MacOS/Barc that sets
# DYLD_FRAMEWORK_PATH / __XPC_DYLD_FRAMEWORK_PATH to Contents/Frameworks and execs Barc-bin.
echo "Compiling native custom-WebKit launcher trampoline..."
mv "$APP_BUNDLE/Contents/MacOS/Barc" "$APP_BUNDLE/Contents/MacOS/Barc-bin"

TMP_SRC="$(mktemp -d /tmp/barc-launcher-XXXXXX)"
trap 'rm -rf "$TMP_SRC"' EXIT

cat > "$TMP_SRC/launcher.c" <<'EOF'
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void prepend_env(const char *name, const char *value) {
    const char *existing = getenv(name);
    if (existing && existing[0]) {
        size_t len = strlen(value) + 1 + strlen(existing) + 1;
        char *buf = malloc(len);
        if (buf) {
            snprintf(buf, len, "%s:%s", value, existing);
            setenv(name, buf, 1);
            free(buf);
        }
    } else {
        setenv(name, value, 1);
    }
}

int main(int argc, char **argv) {
    char raw_path[PATH_MAX];
    uint32_t size = sizeof(raw_path);
    if (_NSGetExecutablePath(raw_path, &size) != 0) {
        fprintf(stderr, "Barc launcher: failed to resolve executable path\n");
        return 1;
    }

    char resolved[PATH_MAX];
    const char *exec_path = realpath(raw_path, resolved) ? resolved : raw_path;

    char dir_buf[PATH_MAX];
    strncpy(dir_buf, exec_path, sizeof(dir_buf) - 1);
    dir_buf[sizeof(dir_buf) - 1] = '\0';
    char macos_dir[PATH_MAX];
    strncpy(macos_dir, dirname(dir_buf), sizeof(macos_dir) - 1);
    macos_dir[sizeof(macos_dir) - 1] = '\0';

    char contents_buf[PATH_MAX];
    strncpy(contents_buf, macos_dir, sizeof(contents_buf) - 1);
    contents_buf[sizeof(contents_buf) - 1] = '\0';
    char contents_dir[PATH_MAX];
    strncpy(contents_dir, dirname(contents_buf), sizeof(contents_dir) - 1);
    contents_dir[sizeof(contents_dir) - 1] = '\0';

    char frameworks_dir[PATH_MAX];
    snprintf(frameworks_dir, sizeof(frameworks_dir), "%s/Frameworks", contents_dir);

    char rust_dylib[PATH_MAX];
    snprintf(rust_dylib, sizeof(rust_dylib), "%s/libbarc_core.dylib", frameworks_dir);

    char target_bin[PATH_MAX];
    snprintf(target_bin, sizeof(target_bin), "%s/Barc-bin", macos_dir);

    prepend_env("DYLD_FRAMEWORK_PATH", frameworks_dir);
    prepend_env("__XPC_DYLD_FRAMEWORK_PATH", frameworks_dir);
    prepend_env("DYLD_LIBRARY_PATH", frameworks_dir);
    prepend_env("__XPC_DYLD_LIBRARY_PATH", frameworks_dir);
    setenv("WEBKIT_UNSET_DYLD_FRAMEWORK_PATH", "YES", 1);
    setenv("BARC_CUSTOM_WEBKIT", "1", 1);
    setenv("BARC_RUST_CORE_DYLIB", rust_dylib, 1);
    setenv("__XPC_BARC_RUST_CORE_DYLIB", rust_dylib, 1);

    const char *rules_dir = getenv("BARC_ADBLOCK_RULES_DIR");
    if (rules_dir && rules_dir[0]) {
        setenv("__XPC_BARC_ADBLOCK_RULES_DIR", rules_dir, 1);
    }

    argv[0] = target_bin;
    execv(target_bin, argv);
    perror("Barc launcher: execv failed");
    return 127;
}
EOF

XCODE_SDK="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun clang -O2 -arch arm64 -mmacosx-version-min=15.0 -isysroot "$XCODE_SDK" \
  "$TMP_SRC/launcher.c" -o "$APP_BUNDLE/Contents/MacOS/Barc"
strip -x "$APP_BUNDLE/Contents/MacOS/Barc"

# Sign strictly inside-out, preserving XPC service entitlements (such as allow-jit on WebContent)
echo "Signing nested dylibs, XPC services, frameworks, executables, and app bundle..."
codesign --force --sign - "$FRAMEWORKS/libbarc_core.dylib"
for dylib in "$FRAMEWORKS"/libANGLE-shared.dylib "$FRAMEWORKS"/libwebrtc.dylib; do
  [ -f "$dylib" ] && codesign --force --sign - "$dylib"
done

WK_SWIFT="$FRAMEWORKS/WebKit.framework/Versions/A/Frameworks/libWebKitSwift.dylib"
[ -f "$WK_SWIFT" ] && codesign --force --sign - "$WK_SWIFT"

for xpc in "$XPC_DIR"/*.xpc; do
  [ -d "$xpc" ] || continue
  xpc_name="$(basename "$xpc")"
  ent_file="$TMP_SRC/${xpc_name}.entitlements"
  codesign -d --entitlements - --xml "$xpc" > "$ent_file" 2>/dev/null || true
  if [ -s "$ent_file" ] && grep -q "<plist" "$ent_file"; then
    codesign --force --sign - --entitlements "$ent_file" "$xpc"
  else
    codesign --force --sign - "$xpc"
  fi
done

for name in "${CUSTOM_FRAMEWORKS[@]}"; do
  [ -d "$FRAMEWORKS/${name}.framework" ] && codesign --force --sign - "$FRAMEWORKS/${name}.framework"
done

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
fi

codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/Barc-bin"
codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo "Done! Built self-contained custom-WebKit + RustCore bundle at:"
du -sh "$APP_BUNDLE"
