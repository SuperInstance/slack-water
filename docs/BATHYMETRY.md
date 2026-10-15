# Bathymetry — real soundings in, honest depths out

> ## ⚠️ The depths in the game right now are a PLACEHOLDER
>
> **The current in-game bathymetry (`shared/bathy/fallback-depth.json`) is
> procedurally generated. It is NOT real survey data.** It was produced by a
> documented formula and a fixed seed in `pipeline/bathy/fallback.luau` —
> plausible Southeast-Alaska-shaped water, invented. It carries
> `surveyed: false` and `provenance: "grown"`, and every sample taken from it
> says so. It exists so the game runs today. It must never be shown to a
> player as a chart of the real seafloor.
>
> The real decade of Sitka-area soundings lives on another machine. The
> moment it is exported and converted (below), this placeholder can be
> replaced — nothing else in the game needs to change.

---

## What exists

| Piece | Path | What it is |
| --- | --- | --- |
| Converter CLI | `pipeline/bathy/convert.sh` | sounding text file → `shared/bathy/<name>.json` |
| Converter core | `pipeline/bathy/convert.luau` | format detection, unit conversion, IDW gridding (pure Luau, testable) |
| JSON encoder | `pipeline/bathy/json.luau` | the standalone `luau` CLI has no JSON library, so the pipeline brings its own encoder (encode only — decoding happens in Roblox or with ordinary tools) |
| Fallback generator | `pipeline/bathy/fallback.luau` + `bake.luau` | the documented procedural placeholder |
| Runtime sampler | `src/Shared/Ocean/Bathymetry.luau` | pure Luau, `depthAt(x, z)` + provenance query |
| Baked fallback | `shared/bathy/fallback-depth.json` | the committed placeholder grid |
| Tests | `tests/run-bathy.sh` | unit tests + end-to-end CLI exercise |

## Exporting the data from the source machine

You need one text file per survey area. Columns, in any order if there is a
header row: **longitude/easting, latitude/northing, depth**.

Accepted formats (all three are exercised by committed fixtures):

- **NOAA-style XYZ** — whitespace-separated `lon lat depth`, one sounding per
  line, no header. Lines starting with `#` or `//` are ignored.
- **CSV with a header** — comma-separated; the header names the columns.
  Recognised names (case/punctuation-insensitive): `lon`, `long`, `longitude`,
  `easting`, `x`; `lat`, `latitude`, `northing`, `y`; `depth`, `dep`,
  `depth_m`, `depth_ft`, `depth_fm`, `sounding`, `z`.
- **Tab-separated (TSV)** with a header — the default export of most GIS tools.

If the file has a header with recognisable names, column order does not
matter. If it has **no** header, columns are assumed to be `lon lat depth` in
that order — the converter says so in its output, check it.

Typical exports that already fit:

```bash
# GDAL: any raster (GEBCO, SRTM15+, a multibeam GeoTIFF) to XYZ triples
gdal_translate -of XYZ input.tif output.xyz

# NOAA NGS / NCEI text exports are usually already lon,lat,depth CSV

# QGIS: layer -> Export -> Save Features As... -> "CSV" or "XYZ"
```

Things to decide **before** exporting, because the converter will not guess
them for you:

1. **Depth units** — metres, feet, or fathoms. You must pass `--units`.
2. **Sign convention** — positive-down is the default; if the export is
   positive-up (GEBCO NetCDF style, depths negative), pass `--depth-sign up`.
3. **Coordinates** — lon/lat degrees or projected metres. Detected and
   reported automatically; override with `--coords` if the survey is small
   enough to be ambiguous (a local-metres grid whose numbers are all under
   180).

Copy the file anywhere in this repo (e.g. `pipeline/bathy/fixtures/` or your
home directory) and run the converter.

## Converting

```bash
# metres, geographic degrees, and these ARE real soundings:
./pipeline/bathy/convert.sh ~/exports/sitka-2014-2024.xyz \
    --units m \
    --surveyed \
    --source "Owner's multibeam + CSB soundings, Sitka Sound, 2014-2024" \
    --cell 25 \
    --anchor-lon -135.43 --anchor-lat 57.05

# fathoms from a decades-old CSB export, positive-up depths, no assertion yet:
./pipeline/bathy/convert.sh ~/exports/old-csb.csv \
    --units fm --depth-sign up --cell 50
```

Output lands in `shared/bathy/<name>.json` (name defaults to the input file
name). Useful flags: `--cell METRES` (grid resolution, default 50),
`--radius CELLS` (how far a grid node will reach for soundings before giving
up and marking no-data, default 3), `--studs-per-metre` (world scale,
default 1), `--timestamp` (pin the timestamp for reproducible output).

**`--surveyed` is an assertion, not a verification.** The converter cannot
check that a file contains real soundings. The flag records that the operator
asserted it — the source file, the description, and the timestamp travel with
the grid forever. Without the flag the output is `surveyed: false` and the
description says so. Default is off precisely so that laziness fails safe.

### Reading the output

Every output file carries:

- `surveyed` / `provenance` — `"measured"` only when `--surveyed` was given;
  otherwise `"grown"`.
- `description` — a human-readable sentence stating what this grid is.
- `grid` — `cols`, `rows`, `cellSize` (studs), `minX`/`minZ`, `values`
  (row-major integers, decimetres via `valueScale: 0.1`; `-32768` is the
  no-data sentinel), `fallbackDepth`.
- `provenanceBlock` — source file and description, conversion timestamp,
  detected format and delimiter, column mapping and how it was decided,
  units and sign actually used, cell size, input bounds and output world
  bounds, georeference (anchor, scale, north axis), counts of
  used/skipped/clamped soundings, no-data policy and coverage fraction.

Cells with no sounding inside the search radius are **no-data, never zero** —
zero would invent dry rock where nobody measured. The sampler reports them
honestly (below).

## The provenance story

The vocabulary is shared with `src/Shared/Ocean/Chart.luau` (`measured` /
`grown`) rather than being a second system:

- The **converter** writes `surveyed` + `provenance` into the JSON, per the
  operator's assertion.
- **`Bathymetry.fromGrid`** re-verifies on load and applies the same distrust
  rule as `Chart.loadFromChart`: `measured` is only believed when the document
  *also* says `surveyed: true`. An unrecognised provenance word, or a
  contradictory combination, is downgraded to `grown` — a hostile or buggy
  file cannot smuggle itself in as surveyed.
- **`Bathymetry.sample(field, x, z)`** is where it reaches the game. It
  returns `{ depth, provenance, surveyed, noData, inBounds }`. A sample is
  `surveyed: true` only when it came from real data: inside the footprint,
  interpolated only between valid nodes, on a grid asserted as measured.
  Coverage holes and out-of-bounds queries return the grid's documented
  `fallbackDepth` with `provenance: "grown"` — a boring, honest number.
- `Bathymetry.coverage(field)` is the fraction of cells with real data, the
  bathymetric counterpart of `Chart.coverage` — worth surfacing in the UI as
  "this chart is 60% surveyed".

**Client duty:** the client never computes depth; it renders what
`sample()`/`describe()` report. Anything showing a depth to a player should
read `provenance`/`surveyed` and present placeholder water as placeholder
(e.g. "estimated depths" on the chart legend).

## Getting a grid into Roblox (not yet solved — by design)

Roblox cannot read files at runtime, and this work deliberately stops at the
contract. `Bathymetry.fromGrid(decoded)` takes the **already-decoded JSON
table**. Whoever wires it up (a future change, not this one) has three sane
options:

1. Commit the JSON as a rojo-sourced `ModuleScript` returning the table
   (a build step converts JSON → Luau, like `tests/fixtures/worker-snapshot`
   does by hand).
2. Serve it from the Worker and `JSONDecode` on the server.
3. Paste it into a ModuleScript by hand for testing.

Whichever is chosen, the server owns it: the client receives sampled results,
never the grid (same rule as the economy).

## Performance and memory (measured, not estimated)

From `luau pipeline/bathy/bench.luau` on this machine (WSL2, standalone luau
CLI; Roblox's VM will differ, but the ratios hold):

```
grid: 1000x1000 nodes (cell 2 studs)
heap for the 1000000-value array: 16.0 MB (16.8 bytes/cell)
heap added by fromGrid (field table, adopts array in place): 0.00 MB
depthAt: 200000 calls in 0.094s — 0.47 us/call
sample(): 50000 calls in 0.047s — 0.93 us/call (allocation included)
```

- Storage is one flat row-major array — ~16 bytes/cell, so 1000×1000 is
  ~16 MB and the 2,500,000-cell hard cap (`Bathymetry.MAX_CELLS`) is ~40 MB.
  Nested or sparse tables would cost 2–3× that plus an extra indirection per
  sample (rationale in `Bathymetry.luau`).
- The committed fallback grid is 76×76 (16-stud cells over the 1200×1200
  world) — 26 KB of JSON, negligible at runtime.
- A real survey at 25 m cells over a 10 km × 10 km ground is 401×401 nodes —
  ~2.6 MB, ~0.5 µs per sample. The grid JSON at that size is ~1 MB; at
  1000×1000 the JSON is ~6 MB, which matters for option (1)/(2) above but not
  for sampling.

## Testing

```bash
./tests/run-bathy.sh
```

44 unit tests (`tests/bathy-tests.luau`) plus end-to-end runs of
`convert.sh` on the three committed fixtures, byte-identical-reconversion
checks, and verification that the committed fallback JSON re-bakes from
source. The runner is standalone; wire it into `tests/run.sh` when the other
in-flight changes land.

## Honest status

- **Exercised by tests:** XYZ/CSV/TSV detection, header-name column mapping,
  metres/fathoms/feet conversion (including exact cross-checks: 10 fm and
  60 ft both land on 18.3 m), positive-up sign handling, above-datum
  clamping, explicit no-data cells, IDW exact node hits, bilinear maths
  (nodes, centres, monotonicity, continuity, exact plane reproduction),
  out-of-bounds/NaN behaviour, provenance upgrade/downgrade, the fallback's
  honesty fields, byte-level determinism of converter and bake.
- **Implemented but NOT tested against real data:** none of the owner's
  actual exports have gone through this pipeline — there are none on this
  machine. The first real conversion should be read closely (format report,
  column mapping, depth range, coverage fraction) before `--surveyed` is
  asserted.
- **Not tested at all:** rendering or behaviour inside Roblox/Studio. This is
  a CLI-side pipeline plus a pure Luau module; nothing here has been run in a
  live game.
