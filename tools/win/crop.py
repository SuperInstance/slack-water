#!/usr/bin/env python3
"""Crop and nearest-neighbour zoom a PNG, using only the standard library.

Needed because PIL and numpy are both absent, and reading Studio's toolbar by
eye at 1:1 is exactly the kind of guesswork that leads to blind clicking in
somebody's editor.

  usage: crop.py <in.png> <out.png> <x> <y> <w> <h> [zoom]
"""

import struct
import sys
import zlib

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from find_button import read_png  # noqa: E402  (same directory, pure stdlib)


def write_png(path, w, h, rgb):
    raw = bytearray()
    for r in range(h):
        raw.append(0)  # filter type 0: None
        raw += rgb[r * w * 3:(r + 1) * w * 3]

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    x0, y0, cw, ch = (int(v) for v in sys.argv[3:7])
    zoom = int(sys.argv[7]) if len(sys.argv) > 7 else 3

    w, h, nch, px = read_png(src)
    x1, y1 = min(x0 + cw, w), min(y0 + ch, h)
    ow, oh = (x1 - x0) * zoom, (y1 - y0) * zoom

    out = bytearray(ow * oh * 3)
    for oy in range(oh):
        sy = y0 + oy // zoom
        for ox in range(ow):
            sx = x0 + ox // zoom
            i = (sy * w + sx) * nch
            o = (oy * ow + ox) * 3
            out[o] = px[i]
            out[o + 1] = px[i + 1]
            out[o + 2] = px[i + 2]
    write_png(dst, ow, oh, bytes(out))
    print("wrote %s %dx%d (from %d,%d %dx%d zoom %d)"
          % (dst, ow, oh, x0, y0, x1 - x0, y1 - y0, zoom))
    return 0


if __name__ == "__main__":
    sys.exit(main())