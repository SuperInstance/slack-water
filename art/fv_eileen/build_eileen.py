"""
The F/V Eileen — modelled from Casey's own photographs.

Built to be lofted like a real hull rather than assembled from boxes, because
the whole point of using the actual boat is that the silhouette is right when
you see her from the water.

REFERENCE
---------
Photographs supplied by the owner (2026-10-15, Downloads). What was actually
used from them, and what was inferred:

  FROM THE PHOTOS (high confidence):
    - White topsides over dark antifouling, with a sheer stripe/rubbing
      strake running the full length at deck edge.
    - "EILEEN" in black serif capitals on the bow and on the house.
    - TWO-tier superstructure: a main deckhouse with a row of rectangular
      windows, and a smaller raised pilothouse set forward of it with raked
      front windows.
    - A spreader mast on the pilothouse roof, with a cross-tree, stays and
      running rigging.
    - Open working deck AFT of the deckhouse.
    - Net reel under a tarpaulin on the after deck, four green net floats
      and a red/orange buoy hung outboard on the rail.
    - Ladder up the side to the pilothouse.

  INFERRED / APPROXIMATE (stated rather than hidden):
    - Exact LOA. Photographs show her against a car and a known-draft hull
      but carry no scale reference, so LOA is ESTIMATED at 58 ft and is the
      single number most worth correcting.
    - Sheer curve and the amount of bow flare are eyeballed from the
      broadside shot, not measured from a line plan.
    - Draft is set so the waterline sits at y=0, which is what the ocean
      surface and the tide-riding code expect.

UNITS
-----
1 Blender unit = 1 stud, and 1 stud = 1 foot. That is Roblox's own working
scale (the avatar is ~5 studs), and it happens to make the 58 ft estimate
land on 58 units, so the numbers below read like the real thing.

The origin is on the CENTRELINE AT THE WATERLINE. WorldGen calls
OceanSurface.ride(model) to move the whole boat with the tide; that only
works if the pivot is where the boat actually floats.
"""

import bpy
import math
import os
import sys

# -----------------------------------------------------------------------------
# Dimensions (studs == feet). Change LOA here and everything follows.
# -----------------------------------------------------------------------------

LOA = 58.0          # length overall, ESTIMATED from photos
BEAM = 16.0         # max beam, estimated
FREEBOARD_MID = 4.4 # deck height above waterline amidships
FREEBOARD_BOW = 6.4 # sheer rise forward
FREEBOARD_STERN = 5.0
DRAFT = 5.2         # keel below waterline

STATIONS = 17       # fore-aft loft stations
SECTION_PTS = 11    # points per station from keel to sheer

OUT_DIR = os.path.dirname(os.path.abspath(__file__))


# -----------------------------------------------------------------------------
# Hull surface functions
# -----------------------------------------------------------------------------


def station_param(i):
    """0 at the transom, 1 at the stem."""
    return i / float(STATIONS - 1)


def half_beam(u):
    """Plan-view half-width at station u (0 transom .. 1 stem).

    Full and rounded through the working middle, slightly tucked at the
    transom, fine at the stem — which is what the photographs show.
    """
    if u < 0.34:
        # transom to shoulder: widens out smoothly
        t = u / 0.34
        return BEAM * 0.5 * (0.84 + 0.16 * math.sin(t * math.pi * 0.5))
    t = (u - 0.34) / 0.66
    # shoulder to stem: fine taper, held fuller for longer (working boat)
    return BEAM * 0.5 * (1.0 - 0.95 * (t ** 2.6))


def sheer(u):
    """Deck-edge height — the classic sheer curve, low amidships, up both ends."""
    if u <= 0.55:
        t = u / 0.55
        return FREEBOARD_STERN + (FREEBOARD_MID - FREEBOARD_STERN) * (t ** 1.4)
    t = (u - 0.55) / 0.45
    return FREEBOARD_MID + (FREEBOARD_BOW - FREEBOARD_MID) * (t ** 1.8)


def keel(u):
    """Bottom of the hull: flat-ish amidships with smooth rocker fore and aft.

    The first version used `abs(u - 0.42)` clamped by max(), which put a hard
    kink into the keel line — the rendered profile showed a visible sawtooth
    along the bottom. A plain parabola has no such discontinuity.
    """
    v = (u - 0.45) / 0.62
    return -DRAFT * (1.0 - 0.62 * v * v)


def deadrise(u):
    """How V'd the bottom is. Flat aft, sharp forward. Smooth, no clamp kink."""
    return 0.45 + 0.95 * max(0.0, (u - 0.30) / 0.70) ** 1.5


def section_point(u, t):
    """One point on a station section. t: 0 keel, 1 sheer."""
    hb = half_beam(u)
    kb = keel(u)
    sh = sheer(u)
    # exponent < 1 gives a fuller, more barge-like bottom; > 1 gives a V
    e = 0.55 + 0.75 * deadrise(u)
    # y across the beam, z up the section
    y = hb * (t ** (1.0 / e))
    z = kb + (sh - kb) * (t ** e)
    return y, z


def build_hull():
    """Loft the stations into a closed hull, mirrored to port."""
    verts = []
    faces = []
    ring = []

    for i in range(STATIONS):
        u = station_param(i)
        x = -LOA * 0.5 + u * LOA
        for j in range(SECTION_PTS):
            t = j / float(SECTION_PTS - 1)
            y, z = section_point(u, t)
            # starboard down the section, then mirror back up the port side
            verts.append((x, y, z))
        for j in range(SECTION_PTS - 2, 0, -1):
            t = j / float(SECTION_PTS - 1)
            y, z = section_point(u, t)
            verts.append((x, -y, z))

    n = (SECTION_PTS * 2) - 2  # points per full ring (centreline counted once)
    ring = list(range(n))

    for i in range(STATIONS - 1):
        a = i * n
        b = (i + 1) * n
        for j in range(n):
            j2 = (j + 1) % n
            faces.append((a + j, a + j2, b + j2, b + j))

    # transom cap
    faces.append(tuple(range(n - 1, -1, -1)))
    # stem cap
    last = (STATIONS - 1) * n
    faces.append(tuple(range(last, last + n)))

    mesh = bpy.data.meshes.new("Hull")
    mesh.from_pydata(verts, [], faces)
    mesh.validate()
    mesh.update()
    obj = bpy.data.objects.new("Hull", mesh)
    bpy.context.collection.objects.link(obj)
    return obj


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

DECK_Z = 0.0


def box(name, loc, size, mat=None, rot=None):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    o = bpy.context.object
    o.name = name
    o.scale = size
    if rot:
        o.rotation_euler = rot
    bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
    if mat:
        o.data.materials.append(mat)
    return o


def cyl(name, loc, radius, depth, mat=None, rot=None, verts=12):
    bpy.ops.mesh.primitive_cylinder_add(
        radius=radius, depth=depth, vertices=verts, location=loc
    )
    o = bpy.context.object
    o.name = name
    if rot:
        o.rotation_euler = rot
    if mat:
        o.data.materials.append(mat)
    return o


def mat(name, color, rough=0.6, metallic=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (color[0], color[1], color[2], 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metallic
    return m


# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)

    M_WHITE = mat("Eileen_White", (0.86, 0.87, 0.86), rough=0.45)
    M_BOOT = mat("Antifouling", (0.055, 0.075, 0.11), rough=0.85)
    M_DECK = mat("Deck_Wood", (0.42, 0.33, 0.24), rough=0.9)
    M_GOLD = mat("Trim_Gold", (0.72, 0.62, 0.36), rough=0.5)
    M_STEEL = mat("Steel", (0.55, 0.56, 0.58), rough=0.4, metallic=0.85)
    M_DARK = mat("Rigging", (0.12, 0.12, 0.13), rough=0.8)
    M_GREEN = mat("Net_Float_Green", (0.09, 0.45, 0.20), rough=0.7)
    M_ORANGE = mat("Buoy_Orange", (0.85, 0.28, 0.06), rough=0.7)

    parts = []

    # --- hull ---------------------------------------------------------------
    hull = build_hull()
    parts.append(hull)

    # Split the hull at the waterline so the antifouling is its own material
    # and reads correctly when the tide lifts and drops her.
    hull.data.materials.append(M_WHITE)
    hull.data.materials.append(M_BOOT)
    for poly in hull.data.polygons:
        avg_z = sum(hull.data.vertices[v].co.z for v in poly.vertices) / len(poly.vertices)
        poly.material_index = 1 if avg_z < 0.0 else 0
    shade_smooth(hull)

    # --- deck ---------------------------------------------------------------
    deck = box(
        "Deck",
        (0.0, 0.0, FREEBOARD_MID - 0.25),
        (LOA * 0.97, BEAM * 0.86, 0.5),
        M_DECK,
    )
    parts.append(deck)

    # --- bulwark / rail -----------------------------------------------------
    # A low bulwark round the working deck, open at the transom.
    for side in (-1, 1):
        parts.append(
            box(
                "Bulwark_%s" % ("P" if side > 0 else "S"),
                (1.5, side * BEAM * 0.44, FREEBOARD_MID + 0.45),
                (LOA * 0.62, 0.4, 0.9),
                M_WHITE,
            )
        )

    # --- main deckhouse -----------------------------------------------------
    HOUSE_X = -8.0
    parts.append(
        box(
            "Deckhouse",
            (HOUSE_X, 0.0, FREEBOARD_MID + 1.5),
            (17.0, BEAM * 0.78, 3.0),
            M_WHITE,
        )
    )
    # windows: a row along each side, and across the front
    for side in (-1, 1):
        for k in range(5):
            parts.append(
                box(
                    "HouseWindow_%s%d" % ("P" if side > 0 else "S", k),
                    (HOUSE_X - 6.4 + k * 3.2, side * (BEAM * 0.78 * 0.5 + 0.06), FREEBOARD_MID + 1.9),
                    (2.1, 0.12, 1.1),
                    M_DARK,
                )
            )

    # --- raised pilothouse (forward of the deckhouse, per the photos) -------
    PH_X = 7.0
    PH_Z = FREEBOARD_MID + 3.0 + 1.35
    parts.append(box("Pilothouse", (PH_X, 0.0, PH_Z), (11.0, BEAM * 0.66, 2.7), M_WHITE))
    # raked front windows — angled in, as they are on the real boat
    for side in (-1, 1):
        parts.append(
            box(
                "PilotWindowFront_%s" % ("P" if side > 0 else "S"),
                (PH_X + 4.6, side * 1.7, PH_Z + 0.15),
                (1.5, 2.9, 1.25),
                M_DARK,
                rot=(0.0, math.radians(-22.0), 0.0),
            )
        )
        for k in range(2):
            parts.append(
                box(
                    "PilotWindowSide_%s%d" % ("P" if side > 0 else "S", k),
                    (PH_X - 1.6 - k * 3.0, side * (BEAM * 0.66 * 0.5 + 0.06), PH_Z + 0.2),
                    (2.2, 0.12, 1.15),
                    M_DARK,
                )
            )

    # --- spreader mast on the pilothouse roof -------------------------------
    MAST_BASE = PH_Z + 1.35
    parts.append(cyl("Mast", (PH_X + 1.0, 0.0, MAST_BASE + 9.0), 0.28, 18.0, M_WHITE))
    parts.append(
        box("MastCrosstree", (PH_X + 1.0, 0.0, MAST_BASE + 15.5), (0.30, 7.5, 0.30), M_WHITE)
    )
    parts.append(
        box("MastCrosstreeLow", (PH_X + 1.0, 0.0, MAST_BASE + 13.0), (0.26, 5.0, 0.26), M_WHITE)
    )

    # --- deck gear ----------------------------------------------------------
    # Net reel under a tarpaulin, on the after deck.
    parts.append(
        box("NetReelTarp", (-17.0, 0.0, FREEBOARD_MID + 1.3), (9.0, BEAM * 0.62, 2.6), M_DARK)
    )
    # A-frame at the transom for hauling the net.
    for side in (-1, 1):
        parts.append(
            box(
                "AFrame_%s" % ("P" if side > 0 else "S"),
                (-LOA * 0.44, side * 2.6, FREEBOARD_MID + 4.2),
                (0.35, 0.35, 8.4),
                M_STEEL,
                rot=(math.radians(side * 7.0), 0.0, 0.0),
            )
        )
    parts.append(box("AFrameTop", (-LOA * 0.44, 0.0, FREEBOARD_MID + 8.3), (0.35, 5.6, 0.35), M_STEEL))

    # Green net floats, hung outboard along the rail — four of them.
    for k in range(4):
        parts.append(
            cyl(
                "NetFloat_%d" % k,
                (6.0 + k * 2.4, -(BEAM * 0.5 + 0.5), FREEBOARD_MID + 0.9),
                0.75, 1.5, M_GREEN,
                rot=(math.radians(90.0), 0.0, 0.0),
                verts=10,
            )
        )
    # The orange buoy.
    parts.append(
        cyl("Buoy", (10.5, BEAM * 0.5 + 0.6, FREEBOARD_MID + 1.6), 0.95, 2.0, M_ORANGE, verts=12)
    )

    # Power block on the mast, as seen in the photos.
    parts.append(
        box("PowerBlock", (PH_X + 1.0, 4.2, MAST_BASE + 11.0), (1.2, 0.9, 1.6), M_STEEL)
    )

    # --- name boards --------------------------------------------------------
    for side in (-1, 1):
        parts.append(
            box(
                "NameBoard_%s" % ("P" if side > 0 else "S"),
                (LOA * 0.34, side * (BEAM * 0.5 - 0.2), FREEBOARD_MID + 1.4),
                (7.0, 0.12, 0.9),
                M_GOLD,
            )
        )

    # --- join into one mesh per material and tidy ---------------------------
    bpy.ops.object.select_all(action="DESELECT")
    for o in parts:
        o.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()

    boat = bpy.context.object
    boat.name = "FVEileen"

    # Origin on the centreline at the waterline — the tide-riding pivot.
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    bpy.context.scene.cursor.location = (0.0, 0.0, 0.0)
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")

    # --- report -------------------------------------------------------------
    tris = sum(len(p.vertices) - 2 for p in boat.data.polygons)
    print("F/V Eileen built: %d objects -> 1 mesh" % len(parts))
    print("  LOA      : %.1f studs" % LOA)
    print("  beam     : %.1f studs" % BEAM)
    print("  triangles: %d" % tris)
    print("  materials: %d" % len(boat.data.materials))

    # --- export -------------------------------------------------------------
    fbx = os.path.join(OUT_DIR, "fveileen.fbx")
    bpy.ops.export_scene.fbx(
        filepath=fbx,
        use_selection=False,
        apply_scale_options="FBX_SCALE_UNITS",
        object_types={"MESH"},
        mesh_smooth_type="FACE",
        path_mode="COPY",
    )
    print("  wrote    : %s (%.1f KB)" % (fbx, os.path.getsize(fbx) / 1024.0))

    glb = os.path.join(OUT_DIR, "fveileen.glb")
    bpy.ops.export_scene.gltf(
        filepath=glb, export_format="GLB", use_selection=False,
    )
    print("  wrote    : %s (%.1f KB)" % (glb, os.path.getsize(glb) / 1024.0))

    blend = os.path.join(OUT_DIR, "fveileen.blend")
    bpy.ops.wm.save_as_mainfile(filepath=blend)
    print("  wrote    : %s" % blend)


def shade_smooth(obj):
    for poly in obj.data.polygons:
        poly.use_smooth = True


if __name__ == "__main__":
    main()