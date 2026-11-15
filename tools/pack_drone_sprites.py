#!/usr/bin/env python3
"""Pack rendered drone frames (hull / glow / shadow) into Factorio sprite sheets.

Usage:
  pip install pillow numpy
  python3 pack_drone_sprites.py --hull renders/hull --glow renders/glow --shadow renders/shadow \
      --out graphics/entity --mod-root . --mod WePlayAttackDrones --scale 0.5 --split-banks 5

  (run it from the mod's folder so the paths come out as __WePlayAttackDrones__/graphics/entity/...)

Each folder holds one PNG per frame. Files are read in sorted name order, so Flamenco's
zero-padded numbering (0001.png ...) works as-is. Any pass can be left out.

What it does per pass:
  * clears faint pixels below --alpha-threshold (shadow-catcher haze, render noise), then
    crops every frame to the union bounding box of all frames (keeps the pivot math exact)
  * hull:   kept as-is (needs Film > Transparent)
  * glow:   black-background emission -> white with alpha = brightness, so in-game tint gives exact colors
  * shadow: if the render has alpha, keeps alpha and makes it black; otherwise treats it as a
            shadow-catcher image (white = no shadow) and uses darkness as alpha
  * packs into sheets no bigger than 8192 px, splitting into several files if needed
  * writes <out>/drone-animations.lua with ready-made "animation" prototypes and their shifts
"""
import argparse
import glob
import math
import os
import sys

import numpy as np
from PIL import Image

MAX_SHEET = 8192


def load_frames(folder):
    files = sorted(glob.glob(os.path.join(folder, "*.png")))
    if not files:
        sys.exit(f"No PNGs found in {folder}")
    return files


def convert(kind, img):
    a = np.asarray(img.convert("RGBA")).astype(np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3]
    if kind == "glow":
        v = rgb.max(axis=-1) * alpha
        out = np.dstack([np.ones_like(v), np.ones_like(v), np.ones_like(v), v])
    elif kind == "shadow":
        if alpha.min() < 0.99:                       # transparent film: shadow lives in alpha
            sh = alpha
        else:                                        # shadow catcher pass: white = no shadow
            sh = 1.0 - rgb.mean(axis=-1)
        out = np.dstack([np.zeros_like(sh), np.zeros_like(sh), np.zeros_like(sh), sh])
    else:
        out = a
    return (np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8)


def pack(kind, folder, args):
    files = load_frames(folder)
    print(f"[{kind}] {len(files)} frames from {folder}")
    threshold = args.alpha_threshold
    frames = []
    for f in files:
        fr = convert(kind, Image.open(f))
        fr[fr[..., 3] < threshold] = 0               # drop haze so it can't block the trim
        frames.append(fr)
    h0, w0 = frames[0].shape[:2]
    if any(fr.shape[:2] != (h0, w0) for fr in frames):
        sys.exit(f"[{kind}] frames are not all the same size")

    # union bounding box of visible pixels
    vis = np.zeros((h0, w0), bool)
    for fr in frames:
        vis |= fr[..., 3] > 0
    if not vis.any():
        sys.exit(f"[{kind}] every frame is empty")
    ys, xs = np.nonzero(vis)
    x0, x1 = max(xs.min() - 1, 0), min(xs.max() + 2, w0)
    y0, y1 = max(ys.min() - 1, 0), min(ys.max() + 2, h0)
    w, h = x1 - x0, y1 - y0

    # shift: crop center vs. original render center (the pivot), in tiles
    px_to_tile = args.scale / 32.0
    shift_x = ((x0 + x1) / 2 - w0 / 2) * px_to_tile
    shift_y = ((y0 + y1) / 2 - h0 / 2) * px_to_tile

    if len(frames) % args.split_banks:
        sys.exit(f"[{kind}] {len(frames)} frames don't split evenly into {args.split_banks} banks")
    per_bank = len(frames) // args.split_banks
    if per_bank > 255:
        sys.exit(f"[{kind}] {per_bank} frames per animation; Factorio allows 255. Use --split-banks.")

    rel = os.path.relpath(args.out, args.mod_root).replace("\\", "/") if args.mod_root else args.out.replace("\\", "/")
    rel = rel.strip("./") if rel.startswith("./") else rel
    base = f"__{args.mod}__/{rel}/"
    extra = {
        "hull": "",
        "glow": '    draw_as_glow = true,\n    blend_mode = "additive",\n',
        "shadow": "    draw_as_shadow = true,\n",
    }[kind]
    os.makedirs(args.out, exist_ok=True)

    lua = ""
    for b in range(args.split_banks):
        chunk_frames = frames[b * per_bank:(b + 1) * per_bank]
        suffix = f"-{b}" if args.split_banks > 1 else ""
        cols = min(len(chunk_frames), MAX_SHEET // w)
        rows_per_file = MAX_SHEET // h
        total_rows = math.ceil(len(chunk_frames) / cols)
        n_files = math.ceil(total_rows / rows_per_file)
        rows_per_file = math.ceil(total_rows / n_files)     # balance the files
        per_file = cols * rows_per_file
        names = []
        for fi in range(n_files):
            chunk = chunk_frames[fi * per_file:(fi + 1) * per_file]
            rows = math.ceil(len(chunk) / cols)
            sheet = np.zeros((rows * h, cols * w, 4), np.uint8)
            for i, fr in enumerate(chunk):
                r, c = divmod(i, cols)
                sheet[r * h:(r + 1) * h, c * w:(c + 1) * w] = fr[y0:y1, x0:x1]
            name = f"drone-{kind}{suffix}" + (f"-part{fi + 1}" if n_files > 1 else "") + ".png"
            Image.fromarray(sheet, "RGBA").save(os.path.join(args.out, name), optimize=True)
            names.append(name)
            print(f"[{kind}]   {name}: {sheet.shape[1]}x{sheet.shape[0]}")
        if n_files == 1:
            file_line = f'    filename = "{base}{names[0]}",\n'
        else:
            file_line = ("    filenames = {\n" + "".join(f'      "{base}{n}",\n' for n in names)
                         + "    },\n" + f"    lines_per_file = {rows_per_file},\n")
        lua += (
            "  {\n"
            '    type = "animation",\n'
            f'    name = "{args.name}-{kind}{suffix}",\n'
            f"{file_line}"
            f"    width = {w},\n    height = {h},\n"
            f"    frame_count = {len(chunk_frames)},\n    line_length = {cols},\n"
            f"    shift = {{{shift_x:.4f}, {shift_y:.4f}}},\n"
            f"    scale = {args.scale},\n"
            '    priority = "medium",\n'
            f"{extra}"
            "  },\n"
        )
    print(f"[{kind}] cropped {w0}x{h0} -> {w}x{h}, shift = ({shift_x:.3f}, {shift_y:.3f}) tiles")
    if w * h > 0.8 * w0 * h0:
        print(f"[{kind}]   WARNING: the crop barely shrank the frames. Something faint covers most of "
              f"the frame (shadow-catcher haze?). Try a higher --alpha-threshold.")
    return lua


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--hull")
    p.add_argument("--glow")
    p.add_argument("--shadow")
    p.add_argument("--out", required=True, help="output folder for sheets (inside your mod)")
    p.add_argument("--mod", default="WePlayAttackDrones", help="mod folder name for __mod__/ paths")
    p.add_argument("--mod-root", help="path to the mod's root folder, so Lua paths come out relative to it")
    p.add_argument("--name", default="wp-attack-drone", help="prototype name prefix")
    p.add_argument("--scale", type=float, default=0.5, help="in-game sprite scale")
    p.add_argument("--split-banks", type=int, default=1,
                   help="split the frames into this many animations, one per bank (named <name>-<kind>-0, -1, ...). "
                        "Factorio animations can't have more than 255 frames, so 5 banks x 64 headings needs --split-banks 5")
    p.add_argument("--alpha-threshold", type=int, default=16,
                   help="pixels with alpha below this (0-255) are cleared before trimming (default 16)")
    args = p.parse_args()

    lua = ("-- generated by pack_drone_sprites.py\n"
           + ("-- one animation per bank: <name>-<kind>-<bank>, frame = heading (0-based)\n" if args.split_banks > 1
              else "-- frame index = bank * headings + heading (0-based)\n")
           + "-- draw with animation_speed = 0, animation_offset = frame\ndata:extend({\n")
    for kind in ("hull", "glow", "shadow"):
        folder = getattr(args, kind)
        if folder:
            lua += pack(kind, folder, args)
    lua += "})\n"
    path = os.path.join(args.out, "drone-animations.lua")
    with open(path, "w") as f:
        f.write(lua)
    print("wrote", path)


if __name__ == "__main__":
    main()
