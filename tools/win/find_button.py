#!/usr/bin/env python3
"""Find a Roblox Studio toolbar button by COLOUR in a captured window image.

Split out from the click step so each half can be verified independently.

  usage: find_button.py <probe.png> <probe.json> <play|stop>

Prints "SCREEN <x> <y>" and exits 0, or exits 1 if no button was found.
Refusing to guess is deliberate: clicking a random spot in someone's editor is
worse than doing nothing at all.
"""

import json
import struct
import sys
import zlib


def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a png"
    pos, idat = 8, b""
    w = h = depth = ctype = 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        body = d[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
        elif tag == b"IDAT":
            idat += body
        pos += 12 + ln
    raw = zlib.decompress(idat)
    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    stride = w * nch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for r in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[r * stride:(r + 1) * stride] = line
        prev = line
    return w, h, nch, bytes(out)


def main():
    png, metapath, which = sys.argv[1], sys.argv[2], sys.argv[3]
    m = json.load(open(metapath, encoding="utf-8-sig"))
    w, h, nch, px = read_png(png)

    if which == "stop":
        test = lambda r, g, b: r > 190 and g < 90 and b < 80
    else:
        test = lambda r, g, b: b > 200 and g > 110 and r < 110

    xs, ys = [], []
    for y in range(0, min(h, 230)):          # toolbar band only
        row = y * w * nch
        for x in range(w):
            i = row + x * nch
            if test(px[i], px[i + 1], px[i + 2]):
                xs.append(x); ys.append(y)

    if len(xs) < 12:
        print("NOTFOUND %d px" % len(xs))
        return 1

    cx, cy = int(sum(xs) / len(xs)), int(sum(ys) / len(ys))
    sx, sy = m["originX"] + cx, m["originY"] + cy
    print("SCREEN %d %d  (image %d,%d from %d px)" % (sx, sy, cx, cy, len(xs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())