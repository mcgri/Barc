#!/usr/bin/env bash
# Measures whole-process-tree physical footprint (UI + WebContent + GPU + Networking)
# for a Barc.app bundle in a disposable profile so the user's real session is untouched.
# Optionally seeds a multi-tab session (pass URLs as extra args, or uses a built-in test suite).
set -euo pipefail

APP_BUNDLE="${1:?usage: benchmark-memory.sh /path/to/Barc.app [wait_seconds] [url1 url2 ...]}"
WAIT_SECONDS="${2:-12}"
shift $(( $# >= 2 ? 2 : $# ))

TMP_HOME="$(mktemp -d /tmp/barc-bench-XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

APP_SUPPORT="$TMP_HOME/Library/Application Support/io.github.mcgri.Barc"
mkdir -p "$APP_SUPPORT"
REAL_FILTERS="$HOME/Library/Application Support/io.github.mcgri.Barc/filter-lists"
if [ -d "$REAL_FILTERS" ]; then
  cp -R "$REAL_FILTERS" "$APP_SUPPORT/filter-lists"
fi

python3 - "$APP_SUPPORT/session.json" "$@" <<'PY'
import json, sys
out_path = sys.argv[1]
urls = sys.argv[2:]
if urls:
    session = {
        "spaces": [{
            "name": "Benchmark",
            "tabs": [{"url": u, "title": u} for u in urls],
            "activeTabIndex": 0
        }],
        "activeSpaceIndex": 0
    }
    with open(out_path, "w") as f:
        json.dump(session, f)
PY

BEFORE_PIDS="$(ps -axo pid,comm | awk '/com\.apple\.WebKit\./ {print $1}' | tr '\n' ',')"

BIN="$APP_BUNDLE/Contents/MacOS/Barc"
echo "Launching $APP_BUNDLE (wait=${WAIT_SECONDS}s, tabs=$#)..."
HOME="$TMP_HOME" CFFIXED_USER_HOME="$TMP_HOME" \
  BARC_ADBLOCK_RULES_DIR="$REAL_FILTERS" \
  "$BIN" >/dev/null 2>&1 &
BARC_PID=$!

sleep "$WAIT_SECONDS"

python3 - "$BARC_PID" "$APP_BUNDLE" "$TMP_HOME" "$BEFORE_PIDS" <<'PY'
import subprocess, sys, re, os

barc_pid = int(sys.argv[1])
app_bundle = os.path.realpath(sys.argv[2])
tmp_home = sys.argv[3]
before_pids = set(int(x) for x in sys.argv[4].split(",") if x.strip().isdigit())

def footprint_mb(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"phys_footprint:\s+([\d.]+)\s+([KMG]?B)", out)
    peak = re.search(r"phys_footprint_peak:\s+([\d.]+)\s+([KMG]?B)", out)
    def to_mb(match):
        if not match:
            return 0.0
        val, unit = float(match.group(1)), match.group(2)
        mult = {"B": 1/(1024*1024), "KB": 1/1024, "MB": 1.0, "GB": 1024.0}.get(unit, 1.0)
        return val * mult
    return to_mb(m), to_mb(peak)

def active_images(pid):
    vm = subprocess.run(["vmmap", str(pid)], capture_output=True, text=True).stdout
    imgs = set()
    for line in vm.splitlines():
        if not any(tag in line for tag in ("__TEXT", "__DATA")):
            continue
        if any(k in line for k in ("WebKit.framework/Versions/A/WebKit",
                                   "WebCore.framework/Versions/A/WebCore",
                                   "JavaScriptCore.framework/Versions/A/JavaScriptCore",
                                   "libbarc_core.dylib")):
            imgs.add(line.split()[-1])
    return sorted(imgs)

ui_mb, ui_peak = footprint_mb(barc_pid)
print(f"  UI Process        (PID {barc_pid:>6}): {ui_mb:6.1f} MB  (peak {ui_peak:6.1f} MB)")

# Discover child WebKit XPC services belonging to this Barc launch:
# 1) Custom-WebKit bundle XPC services match the app_bundle path directly.
# 2) System-WebKit XPC services match tmp_home or io.github.mcgri.Barc in lsof.
ps_out = subprocess.run(["ps", "-axo", "pid,comm"], capture_output=True, text=True).stdout
xpc_procs = []
for line in ps_out.splitlines()[1:]:
    parts = line.strip().split(None, 1)
    if len(parts) != 2:
        continue
    pid, comm = int(parts[0]), parts[1]
    if pid == barc_pid:
        continue
    if "com.apple.WebKit." not in comm:
        continue
    if app_bundle in comm:
        xpc_procs.append((pid, os.path.basename(comm)))
    elif pid not in before_pids:
        xpc_procs.append((pid, os.path.basename(comm)))

total_mb = ui_mb
total_peak = ui_peak
net_has_rust = False
for pid, name in sorted(xpc_procs, key=lambda x: x[1]):
    mb, pk = footprint_mb(pid)
    total_mb += mb
    total_peak += pk
    imgs = active_images(pid)
    rust_tag = " [libbarc_core.dylib]" if any("libbarc_core.dylib" in i for i in imgs) else ""
    if rust_tag:
        net_has_rust = True
    print(f"  {name:<36} (PID {pid:>6}): {mb:6.1f} MB  (peak {pk:6.1f} MB){rust_tag}")

print(f"  TOTAL WHOLE BROWSER FOOTPRINT: {total_mb:6.1f} MB  (sum of peaks {total_peak:6.1f} MB)")
print("  Loaded WebKit / RustCore images in UI process:")
for img in active_images(barc_pid):
    print(f"    {img}")
PY

kill "$BARC_PID" 2>/dev/null || true
wait "$BARC_PID" 2>/dev/null || true
