"""
Render orthographic views of the boat so the silhouette can be compared
against the reference photograph, side by side.

This exists because a hull built from maths is not the same as a hull that
looks right. The broadside view is the one that matters: it is what a player
sees from the water, and it is directly comparable to the boatyard photo.

Uses the Workbench engine deliberately — it is CPU-only and takes under a
second per frame. Cycles/EEVEE would need a GPU and would tell us nothing
extra about whether the SHAPE is correct.
"""

import bpy
import math
import os

OUT_DIR = os.path.dirname(os.path.abspath(__file__))


def look_at(obj, target):
    d = (obj.location - target).normalized()
    obj.rotation_euler = d.to_track_quat("Z", "Y").to_euler()


def render_view(name, direction, resolution=(1600, 1000), ortho_scale=72.0):
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x = resolution[0]
    scene.render.resolution_y = resolution[1]
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.filepath = os.path.join(OUT_DIR, name + ".png")

    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "MATERIAL"
    scene.display.shading.show_shadows = True
    scene.display.shading.show_cavity = True

    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = ortho_scale
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.collection.objects.link(cam)
    cam.location = direction
    look_at(cam, bpy.data.objects["FVEileen"].location)
    scene.camera = cam

    bpy.ops.render.render(write_still=True)
    print("rendered %s -> %s" % (name, scene.render.filepath))
    bpy.data.objects.remove(cam)


def main():
    bpy.ops.import_scene.fbx(
        filepath=os.path.join(OUT_DIR, "fveileen.fbx"),
        automatic_bone_orientation=False,
    )
    boat = bpy.data.objects.get("FVEileen")
    if boat is None:
        boat = bpy.context.active_object
    boat.name = "FVEileen"

    # broadside starboard — compare against the boatyard photo
    render_view("view_broadside", (0.0, -90.0, 8.0))
    # bow
    render_view("view_bow", (90.0, 0.0, 6.0), resolution=(1100, 1100))
    # three-quarter from above — checks the deck layout and the rig
    render_view("view_quarter", (60.0, -70.0, 42.0))


if __name__ == "__main__":
    main()