#!/usr/bin/env python3
"""List rendered frames that can't be read (truncated, corrupt or empty PNGs).

Usage:
  python tools/check_frames.py renders/loaded/diffuse renders/loaded/shadow

Checks every *.png in each folder, fully decoding each one, and prints the
broken ones so you can re-render just those frames.
"""
import glob
import os
import sys

from PIL import Image


def check(folder):
    files = sorted(glob.glob(os.path.join(folder, "*.png")))
    bad = []
    for f in files:
        try:
            if os.path.getsize(f) == 0:
                raise OSError("empty file")
            with Image.open(f) as img:
                img.verify()          # checks the PNG's structure and checksums
            with Image.open(f) as img:
                img.convert("RGBA").load()  # and that the pixels actually decode
        except Exception as e:  # noqa: BLE001 - report anything that fails to decode
            bad.append((f, e))
    print(f"{folder}: {len(files)} frames, {len(bad)} broken")
    for f, e in bad:
        print(f"  {os.path.basename(f)}  ({e})")
    return bad


def main():
    folders = sys.argv[1:]
    if not folders:
        sys.exit(__doc__)
    total = sum(len(check(folder)) for folder in folders)
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
