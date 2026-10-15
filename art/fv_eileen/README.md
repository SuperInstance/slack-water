# The F/V Eileen

The boat you fish from, modelled from the owner's own photographs.

## Why this exists

The world used to put a 24x24 brown slab in the water and call it a deck. It
existed so nobody fell out of the world, and that was its entire purpose. A
fishing game whose boat is a box is not a fishing game.

## What was built from the photographs, and what was not

Photographs supplied by the owner on 2026-10-15.

**Taken from the photos (high confidence):**
- White topsides over dark antifouling, with a sheer stripe along the deck edge.
- "EILEEN" in black serif capitals on the bow.
- Two-tier superstructure: a main deckhouse with a row of windows, and a
  smaller raised pilothouse forward of it with raked front windows.
- A spreader mast on the pilothouse roof with a cross-tree and running rigging.
- Open working deck aft, net reel under tarp, four green net floats and an
  orange buoy hung outboard on the rail.
- Ladder to the pilothouse, power block on the mast.

**Estimated, and worth correcting:**
- **LOA 58 ft.** No photograph contains a usable scale reference. This is the
  single number most likely to be wrong, and it drives every other dimension.
- The sheer curve and bow flare are eyeballed off the broadside shot, not taken
  from a line plan.
- Draft is set so the waterline lands on y = 0, which is what the tide-riding
  code requires.

## Known defects in this pass

Stated rather than hidden:

- The boundary between the antifouling and the white topsides renders as a
  jagged edge. That is a material-split artifact — the split is per-face and
  the surface is curved, so the boundary follows whole polygons. It needs a
  proper vertex-group or texture, not a face-average test.
- The deck still reads as a flat plate laid over the hull rather than a
  bulwarked working deck.
- Bottom shading shows some stepping around amidships.

None of these are the hull silhouette being wrong, but none of them should be
called finished either.

## Files

| File | What it is |
| --- | --- |
| `build_eileen.py` | Builds and exports the boat. Run headless. |
| `render_views.py` | Orthographic views for silhouette comparison. |
| `fveileen.fbx` | Roblox import format. |
| `fveileen.glb` | Alternative, smaller. |
| `fveileen.blend` | Editable source. |
| `view_*.png` | Rendered views. |

## Rebuilding

```bash
~/.local/blender-5.2.2-linux-x64/blender --background --factory-startup \
  --python build_eileen.py
```

## Units and the tide

1 Blender unit = 1 stud, and 1 stud = 1 foot (Roblox's avatar is ~5 studs).

**The origin is on the centreline at the waterline, deliberately.**
`WorldGen` calls `OceanSurface.ride(model)` to move the whole boat with the
tide. That only works if the pivot is where the boat actually floats, so if
anyone re-exports this mesh they must not recentre it.

## Current state

1268 triangles, 8 materials. That is deliberately tiny — Roblox is ~80% mobile
players, and this is one object in a world that also animates a 676-tile ocean.