#!/usr/bin/env python3
# Modified for Barc: application identity, branding and fork configuration, 2026-10-23.
"""Package the approved Barc PNG as Resources/Barc.icns without changing its artwork.

Requires macOS sips and iconutil. The original PNG and its transparency are
preserved; resized copies live only in a temporary iconset directory.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Resources" / "Icon" / "barc-icon.png"
ICNS = ROOT / "Resources" / "Barc.icns"


def main():
    for tool in ("sips", "iconutil"):
        if shutil.which(tool) is None:
            sys.exit(f"make-icon: {tool} is required")
    if not SOURCE.is_file():
        sys.exit(f"make-icon: missing {SOURCE}")
    with tempfile.TemporaryDirectory() as directory:
        iconset = Path(directory) / "Barc.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = "@2x" if scale == 2 else ""
                destination = iconset / f"icon_{points}x{points}{suffix}.png"
                subprocess.run([
                    "sips", "-z", str(pixels), str(pixels), str(SOURCE), "--out", str(destination)
                ], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True)
    print(f"wrote {ICNS.relative_to(ROOT)} from {SOURCE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
