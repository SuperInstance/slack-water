#!/usr/bin/env python3
"""
soundings -> Roblox terrain heightmap.

Roblox Studio's Terrain editor imports a greyscale image as a heightmap, which
is the only practical way to get REAL bathymetry into the game. This turns a
sounding file (lon/lat/depth) into:

    <out>.png   16-bit greyscale heightmap, ready for Terrain -> Import
    <out>.json  sidecar: bounds, depth range, provenance, import instructions

WHY THIS IS PLAIN PYTHON WITH NO DEPENDENCIES
--------------------------------------------
The sounding data lives on a different computer, and that computer is not
under our control. numpy/Pillow are not installed here (there is no pip and no
ensurepip on this image), so anything that needs them cannot be assumed to run
there either. A pure-stdlib script can be copied onto a machine with nothing
installed and still work, which is the whole point of a pipeline whose input
is on someone else's laptop.

Performance note, stated plainly: the resampler is O(cells x soundings) in
pure Python. A 1024x1024 grid from 100k soundings is far too slow (hours).
This is fine for a few thousand soundings at 512x512, which is typical of a
hand-exported survey sheet. If you have a genuinely large survey, install
numpy on that machine and this file is the reference for what it must produce
-- not a performance model. See docs/BATHYMETRY.md.

DEPTH SIGN CONVENTION
---------------------
Soundings are conventionally POSITIVE DOWN. Roblox's heightmap wants LOW =
LOW. So this script converts depth-down to height-up before encoding, and the
inversion is recorded in the sidecar so nobody has to guess later.
"""

from __future__ import annotations

import json
import math
import os
import struct
import sys
import zlib

# Roblox's terrain heightmap import maps greyscale across the terrain height
# range. These are the bounds this script targets; both are written into the
# sidecar so the Roblox side can be configured to match rather than guessed.


# -----------------------------------------------------------------------------
# Reading soundings
# -----------------------------------------------------------------------------


def _split(line):
    for sep in (",", "\t", ";"):
        if sep in line:
            return [p.strip() for p in line.split(sep)]
    return line.split()


def _is_comment(line):
    s = line.strip()
    return s == "" or s.startswith("#") or s.startswith("//")


def read_soundings(path):
    """Read a sounding file into a list of (lon, lat, depth_down).

    Accepts whitespace-, comma-, or tab-separated columns with lon/lat/depth in
    any of the usual orders. Column order is inferred from value ranges rather
    than trusted from a header: longitudes are negative-ish or > 90, latitudes
    are bounded by 90, and depth is the column that is never negative enough to
    be a coordinate. Columns beyond three are ignored.

    Rows that cannot be parsed are SKIPPED and counted, not silently dropped --
    a survey export with a few malformed lines should not become a quiet,
    wrong map.
    """
    rows, skipped = [], 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            if _is_comment(raw):
                continue
            parts = _split(raw)
            if len(parts) < 3:
                skipped += 1
                continue
            try:
                vals = [float(p) for p in parts[:4]]
            except ValueError:
                skipped += 1
                continue
            if len(vals) < 3:
                skipped += 1
                continue

            lon = lat = depth = None
            # First pass: a value inside +/-90 is latitude; a negative or
            # >90 value is longitude (western hemisphere).
            for v in vals:
                if lat is None and -90.0 <= v <= 90.0 and v != 0.0:
                    lat = v
                elif lon is None and (v < -90.0 or v > 90.0):
                    lon = v
            # Second pass: the first leftover value is depth.
            for v in vals:
                if v == lon or v == lat:
                    continue
                depth = v
                break

            if lon is None or lat is None or depth is None:
                skipped += 1
                continue
            rows.append((lon, lat, depth))
    return rows, skipped


# -----------------------------------------------------------------------------
# Projection
# -----------------------------------------------------------------------------


def to_local(lon, lat, lat0, lon0):
    """Equirectangular local tangent plane, metres.

    The survey areas are tens of km across, where the distortion of this
    projection is far below the resolution of the source soundings. A proper
    transverse-Mercator would be more correct and would buy nothing here.
    """
    m_per_deg_lat = 111132.0
    m_per_deg_lon = 111320.0 * math.cos(math.radians(lat0))
    return ((lon - lon0) * m_per_deg_lon, (lat - lat0) * m_per_deg_lat)


# -----------------------------------------------------------------------------
# Resampling
# -----------------------------------------------------------------------------


def build_grid(points, size):
    """Resample scattered soundings onto a regular grid.

    points: list of (x_m, y_m, depth_down)

    Inverse-distance weighting over the K nearest soundings, which preserves
    real structure far better than nearest-neighbour and does not invent the
    smooth bowl a simple bilinear fit would. Cells with no sounding within
    MAX_RADIUS are marked no-data (None) rather than filled with a guess.
    """
    half = size / 2.0
    span_x = max(p[0] for p in points) - min(p[0] for p in points)
    span_y = max(p[1] for p in points) - min(p[1] for p in points)
    span = max(span_x, span_y) or 1.0
    cell = span / (size - 1)

    max_radius = cell * 3.0
    k = 8

    grid = [[None] * size for _ in range(size)]
    for row in range(size):
        y = -half * cell + row * cell
        for col in range(size):
            x = -half * cell + col * cell
            near = []
            for (px, py, pd) in points:
                d2 = (px - x) ** 2 + (py - y) ** 2
                if d2 <= max_radius * max_radius:
                    near.append((d2, pd))
            if not near:
                continue
            near.sort()
            near = near[:k]
            wsum = 0.0
            vsum = 0.0
            for d2, pd in near:
                w = 1.0 if d2 == 0.0 else 1.0 / d2
                wsum += w
                vsum += w * pd
            grid[row][col] = vsum / wsum
    return grid, cell


# -----------------------------------------------------------------------------
# PNG encoding (pure stdlib)
# -----------------------------------------------------------------------------


def _chunk(tag, data):
    out = struct.pack(">I", len(data)) + tag + data
    return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png_gray16(path, grid, lo_studs, hi_studs):
    """Write a 16-bit greyscale PNG. Depth is negated to height on the way in.

    NO-DATA IS RESERVED AT 0 AND REAL DATA IS NEVER ALLOWED TO REACH IT.

    The first version of this function used a fixed +/-512 stud range, which
    quietly destroyed the survey: Southeast Alaska soundings run past 3000 m
    (~9800 studs), so every deep cell clamped to the floor of the range and
    encoded as 0 -- byte-identical to "no data here". A map that erases its
    deepest water and calls it unsurveyed is exactly the failure this project
    is supposed to be honest about.

    So the caller fits the range to the actual data and real samples are
    clamped into [1, 65535], leaving 0 unambiguously meaning no-data.
    """
    size = len(grid)
    span = (hi_studs - lo_studs) or 1.0
    raw = bytearray()
    for row in grid:
        raw.append(0)  # filter type 0 (None) per scanline
        for value in row:
            if value is None:
                v = 0
            else:
                # depth_down (m) -> height_up (studs), then normalise.
                height_m = -value * 3.28084
                frac = (height_m - lo_studs) / span
                frac = min(1.0, max(0.0, frac))
                v = int(round(frac * 65535.0))
                if v == 0:
                    v = 1  # never collide with the no-data sentinel
            raw += struct.pack(">H", v)

    ihdr = struct.pack(">IIBBBBB", size, size, 16, 0, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += _chunk(b"IHDR", ihdr)
    png += _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += _chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        print("usage: heightmap.py <soundings> <outbase> [grid_size]", file=sys.stderr)
        return 2
    src = argv[1]
    outbase = argv[2]
    size = int(argv[3]) if len(argv) > 3 else 512

    if not os.path.exists(src):
        print("heightmap: no such file: %s" % src, file=sys.stderr)
        return 1

    rows, skipped = read_soundings(src)
    if not rows:
        print("heightmap: no soundings parsed from %s" % src, file=sys.stderr)
        return 1

    lat0 = sum(r[1] for r in rows) / len(rows)
    lon0 = sum(r[0] for r in rows) / len(rows)
    points = []
    for (lo, la, d) in rows:
        x, y = to_local(lo, la, lat0, lon0)
        points.append((x, y, d))

    grid, cell = build_grid(points, size)
    depths = [v for row in grid for v in row if v is not None]
    nodata = sum(1 for row in grid for v in row if v is None)

    # Fit the encoding range to the data. Deep Southeast Alaska soundings run
    # to several thousand metres, so a fixed range would clip the most
    # interesting part of the survey. 5% margin keeps the extremes off the
    # 0 and 65535 edges, which are reserved.
    lo_studs = -max(depths) * 3.28084 * 1.05
    hi_studs = -min(depths) * 3.28084 * 1.05
    if hi_studs <= lo_studs:
        hi_studs = lo_studs + 1.0

    png_path = outbase + ".png"
    json_path = outbase + ".json"
    write_png_gray16(png_path, grid, lo_studs, hi_studs)

    sidecar = {
        "provenance": {
            "surveyed": True,
            "source_file": os.path.basename(src),
            "soundings": len(rows),
            "skipped_rows": skipped,
            "depth_units": "metres",
            "depth_convention": "positive down",
            "note": "Derived from a supplied sounding file. Confirm the source "
            "is survey data before shipping.",
        },
        "grid": {
            "size": size,
            "cell_metres": round(cell, 3),
            "cell_studs": round(cell * 3.28084, 3),
            "no_data_cells": nodata,
            "no_data_policy": "no-data cells encode as 0 (black) in the PNG "
            "and are listed here; they were NOT interpolated",
        },
        "bounds": {
            "centre_lat": lat0,
            "centre_lon": lon0,
            "min_depth_m": round(min(depths), 2),
            "max_depth_m": round(max(depths), 2),
            "min_depth_studs": round(-max(depths) * 3.28084, 2),
            "max_depth_studs": round(-min(depths) * 3.28084, 2),
        },
        "roblox_import": {
            "encoded_height_min_studs": round(lo_studs, 2),
            "encoded_height_max_studs": round(hi_studs, 2),
            "no_data_sentinel_png_value": 0,
            "steps": [
                "Studio: View -> Terrain (or Workspace > Terrain in Explorer)",
                "Terrain Editor -> Import (or the heightmap import command)",
                f"Select {os.path.basename(png_path)}",
                "NOTE: this mapping has NOT been verified against Roblox's "
                "importer. The greyscale-to-height range Roblox applies must be "
                "checked by eye on a known deep point before trusting the map.",
            ],
        },
    }
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(sidecar, fh, indent=2)

    print("wrote %s (%dx%d) and %s" % (png_path, size, size, json_path))
    print("  soundings      : %d (skipped %d unreadable rows)" % (len(rows), skipped))
    print("  depth range    : %.1f .. %.1f m" % (min(depths), max(depths)))
    print("  cell size      : %.1f m (%.1f studs)" % (cell, cell * 3.28084))
    print("  no-data cells  : %d of %d" % (nodata, size * size))
    print("")
    print("The Roblox import mapping is UNVERIFIED -- check it against a known")
    print("deep sounding in Studio before trusting the result.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))