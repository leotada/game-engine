"""Generate sculpted, UV-unwrapped rock glTF meshes headlessly with Blender 5.2+.

Outputs into assets/models/:
  - rock_cliff.gltf   (+ rock_cliff.bin)
  - rock_boulder.gltf (+ rock_boulder.bin)
  - rock_cobble.gltf  (+ rock_cobble.bin)

Usage:
  blender -b --factory-startup -P tools/blender_generate_rocks.py
"""

import math
import os
import random
import bmesh
import bpy
from mathutils import Vector, noise


ROCK_SPECS = [
    {
        "name": "rock_cliff",
        "seed": 1337,
        "subdivisions": 5,
        "base_scale": Vector((1.08, 0.96, 1.18)),
        "plane_count": 16,
        "plane_dist_range": (0.72, 0.96),
        "scrape_weight": 0.90,
        "voronoi_weight": 0.22,
        "turb_weight": 0.14,
        "strata_weight": 0.14,
        "strata_freq": 8.5,
        "bottom_flatten": 0.58,
    },
    {
        "name": "rock_boulder",
        "seed": 4201,
        "subdivisions": 5,
        "base_scale": Vector((1.12, 0.94, 0.88)),
        "plane_count": 15,
        "plane_dist_range": (0.74, 0.96),
        "scrape_weight": 0.84,
        "voronoi_weight": 0.20,
        "turb_weight": 0.12,
        "strata_weight": 0.06,
        "strata_freq": 6.5,
        "bottom_flatten": 0.64,
    },
    {
        "name": "rock_cobble",
        "seed": 9007,
        "subdivisions": 4,
        "base_scale": Vector((1.16, 0.88, 0.58)),
        "plane_count": 12,
        "plane_dist_range": (0.80, 0.98),
        "scrape_weight": 0.60,
        "voronoi_weight": 0.10,
        "turb_weight": 0.08,
        "strata_weight": 0.02,
        "strata_freq": 5.0,
        "bottom_flatten": 0.72,
    },
]


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)


def fibonacci_directions(count, rng):
    """Return roughly uniform sphere directions with deterministic jitter."""
    dirs = []
    golden_angle = math.pi * (3.0 - math.sqrt(5.0))
    for i in range(count):
        y = 1.0 - (i / float(count - 1)) * 2.0
        radius = math.sqrt(max(0.0, 1.0 - y * y))
        theta = golden_angle * i
        base = Vector((math.cos(theta) * radius, math.sin(theta) * radius, y))
        jitter = Vector((
            rng.uniform(-0.32, 0.32),
            rng.uniform(-0.32, 0.32),
            rng.uniform(-0.28, 0.28),
        ))
        d = base + jitter
        if d.length > 1e-4:
            d.normalize()
        dirs.append(d)
    return dirs


def sculpt_rock(spec):
    rng = random.Random(spec["seed"])
    seed_offset = Vector((
        rng.uniform(-50.0, 50.0),
        rng.uniform(-50.0, 50.0),
        rng.uniform(-50.0, 50.0),
    ))

    bpy.ops.mesh.primitive_ico_sphere_add(
        subdivisions=spec["subdivisions"],
        radius=1.0,
        location=(0.0, 0.0, 0.0),
    )
    obj = bpy.context.active_object
    obj.name = spec["name"]
    mesh = obj.data

    bm = bmesh.new()
    bm.from_mesh(mesh)

    planes = []
    for d in fibonacci_directions(spec["plane_count"], rng):
        dist = rng.uniform(*spec["plane_dist_range"])
        planes.append((d, dist))

    base_scale = spec["base_scale"]
    scrape_w = spec["scrape_weight"]
    voronoi_w = spec["voronoi_weight"]
    turb_w = spec["turb_weight"]
    strata_w = spec["strata_weight"]
    strata_freq = spec["strata_freq"]
    bottom_flat = spec["bottom_flatten"]

    for v in bm.verts:
        p = v.co.copy()
        d = p.normalized()

        # Broad natural rock asymmetry before scraping cleavage planes.
        macro = noise.noise(p * 1.15 + seed_offset)
        p *= 1.0 + macro * 0.22

        # Planar fracture cuts (simulates Blender Scrape/Flatten chisel faces).
        for plane_no, plane_dist in planes:
            excess = p.dot(plane_no) - plane_dist
            if excess > 0.0:
                p -= plane_no * (excess * scrape_w)

        # Voronoi fracture seams & concave chipping.
        v_dists, _ = noise.voronoi(p * 1.65 + seed_offset * 0.5, distance_metric="DISTANCE")
        ridge = max(0.0, min(1.0, (v_dists[1] - v_dists[0]) * 1.4))
        fracture = (ridge - 0.35) * voronoi_w

        # Stepped horizontal/tilted sedimentary strata.
        strata_arg = (p.z + 0.14 * p.x) * strata_freq + noise.noise(p * 1.6 + seed_offset) * 1.8
        strata_raw = math.sin(strata_arg)
        strata = (strata_raw * 0.45 if strata_raw > 0.0 else strata_raw * 1.1) * strata_w

        # Secondary turbulent rock grain & crag detail along the outward vector.
        t_vec = noise.turbulence_vector(p * 2.15 + seed_offset, 3, False)
        radial_n = (noise.noise(p * 3.8 + seed_offset) - 0.5) * turb_w * 0.45

        radial_dir = p.normalized() if p.length > 1e-4 else d
        p += radial_dir * (fracture + strata + radial_n)
        p += t_vec * (turb_w * 0.42)

        # Apply characteristic archetype proportions.
        p.x *= base_scale.x
        p.y *= base_scale.y
        p.z *= base_scale.z

        # Flatten and flare base slightly so outcrops anchor solidly in soil/bed.
        if p.z < -0.24:
            depth = -0.24 - p.z
            p.z = -0.24 - depth * (1.0 - bottom_flat)
            flare = 1.0 + depth * bottom_flat * 0.24
            p.x *= flare
            p.y *= flare

        v.co = p

    # Recenter horizontally around X/Y = 0 and normalize footprint radius near ~0.95.
    avg_xy = Vector((0.0, 0.0, 0.0))
    for v in bm.verts:
        avg_xy.x += v.co.x
        avg_xy.y += v.co.y
    inv_n = 1.0 / max(len(bm.verts), 1)
    avg_xy.x *= inv_n
    avg_xy.y *= inv_n
    for v in bm.verts:
        v.co.x -= avg_xy.x
        v.co.y -= avg_xy.y

    mean_r = sum(v.co.length for v in bm.verts) * inv_n
    if mean_r > 1e-4:
        norm_scale = 0.95 / mean_r
        for v in bm.verts:
            v.co *= norm_scale

    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()

    for poly in mesh.polygons:
        poly.use_smooth = True

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    # Cube projection UVs prevent any polar pinch across top and side faces.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.cube_project(cube_size=1.2, correct_aspect=True, scale_to_bounds=False)
    bpy.ops.mesh.quads_convert_to_tris()
    bpy.ops.object.mode_set(mode="OBJECT")

    return obj


def export_rock(obj, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    gltf_path = os.path.join(out_dir, f"{obj.name}.gltf")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    bpy.ops.export_scene.gltf(
        filepath=gltf_path,
        export_format="GLTF_SEPARATE",
        use_selection=True,
        export_tangents=True,
        export_normals=True,
        export_texcoords=True,
        export_materials="NONE",
        export_yup=True,
    )
    print(f"Exported Blender rock: {gltf_path} ({len(obj.data.vertices)} verts, {len(obj.data.polygons)} tris)")


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(repo_root, "assets", "models")

    for spec in ROCK_SPECS:
        clear_scene()
        obj = sculpt_rock(spec)
        export_rock(obj, out_dir)


if __name__ == "__main__":
    main()
