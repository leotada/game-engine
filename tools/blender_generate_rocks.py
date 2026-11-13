"""Generate sculpted rock glTF meshes and Cycles-baked PBR maps in Blender 5.2+.

Outputs into assets/models/:
  Meshes (GLTF_SEPARATE + MikkTSpace tangents + Y-up + Smart UV):
    - rock_cliff.gltf/.bin
    - rock_boulder.gltf/.bin
    - rock_cobble.gltf/.bin
  Baked linear 24-bit BMP PBR textures:
    - rock_cliff_{albedo,moss_albedo,normal,mr,moss_mr,ao}.bmp
    - rock_boulder_{albedo,moss_albedo,normal,mr,moss_mr,ao}.bmp
    - rock_cobble_{albedo,normal,mr,ao}.bmp

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
        "base_scale": Vector((1.08, 0.94, 1.18)),
        "plane_count": 24,
        "plane_dist_range": (0.70, 0.94),
        "scrape_weight": 0.95,
        "voronoi_crack_weight": 0.035,
        "micro_disp_weight": 0.024,
        "strata_weight": 0.11,
        "strata_freq": 8.5,
        "bottom_flatten": 0.62,
        "albedo_res": 1024,
        "aux_res": 512,
        "bake_moss": True,
        "tone": "granite",
    },
    {
        "name": "rock_boulder",
        "seed": 4201,
        "subdivisions": 5,
        "base_scale": Vector((1.12, 0.92, 0.88)),
        "plane_count": 20,
        "plane_dist_range": (0.72, 0.95),
        "scrape_weight": 0.90,
        "voronoi_crack_weight": 0.025,
        "micro_disp_weight": 0.020,
        "strata_weight": 0.05,
        "strata_freq": 6.5,
        "bottom_flatten": 0.65,
        "albedo_res": 1024,
        "aux_res": 512,
        "bake_moss": True,
        "tone": "slate_granite",
    },
    {
        "name": "rock_cobble",
        "seed": 9007,
        "subdivisions": 4,
        "base_scale": Vector((1.16, 0.88, 0.56)),
        "plane_count": 14,
        "plane_dist_range": (0.80, 0.98),
        "scrape_weight": 0.62,
        "voronoi_crack_weight": 0.03,
        "micro_disp_weight": 0.015,
        "strata_weight": 0.015,
        "strata_freq": 5.0,
        "bottom_flatten": 0.72,
        "albedo_res": 512,
        "aux_res": 512,
        "bake_moss": False,
        "tone": "river_cobble",
    },
]


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for col in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
        for item in list(col):
            if item.users == 0:
                col.remove(item)


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
            rng.uniform(-0.28, 0.28),
            rng.uniform(-0.28, 0.28),
            rng.uniform(-0.24, 0.24),
        ))
        d = base + jitter
        if d.length > 1e-4:
            d.normalize()
        dirs.append(d)
    return dirs


def smoothstep(edge0, edge1, x):
    t = max(0.0, min(1.0, (x - edge0) / max(edge1 - edge0, 1e-6)))
    return t * t * (3.0 - 2.0 * t)


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
    crack_w = spec["voronoi_crack_weight"]
    micro_w = spec["micro_disp_weight"]
    strata_w = spec["strata_weight"]
    strata_freq = spec["strata_freq"]
    bottom_flat = spec["bottom_flatten"]

    for v in bm.verts:
        p = v.co.copy()
        d = p.normalized()

        # Broad natural asymmetry before planar cleavage cuts.
        macro = noise.noise(p * 0.88 + seed_offset)
        p *= 1.0 + macro * 0.20

        # Planar fracture cuts: flat/chiseled stone faces with clean ridges.
        for plane_no, plane_dist in planes:
            excess = p.dot(plane_no) - plane_dist
            if excess > 0.0:
                p -= plane_no * (excess * scrape_w)

        # Sparse primary Voronoi rock fracture seams.
        v_dists, _ = noise.voronoi(p * 1.45 + seed_offset * 0.5, distance_metric="DISTANCE")
        seam_dist = max(0.0, v_dists[1] - v_dists[0])
        crack_groove = -(1.0 - smoothstep(0.0, 0.11, seam_dist)) * crack_w

        # Tilted bedding-plane strata ledges.
        strata_coord = (p.z * 0.88 + p.x * 0.30 + p.y * 0.16) * strata_freq
        strata_coord += noise.noise(p * 1.2 + seed_offset) * 0.95
        strata_step = math.sin(strata_coord)
        strata_disp = (strata_step * 0.35 if strata_step > 0.0 else strata_step * 0.90) * strata_w

        hf = (noise.noise(p * 3.0 + seed_offset) - 0.5) * micro_w

        radial_dir = p.normalized() if p.length > 1e-4 else d
        p += radial_dir * (crack_groove + strata_disp + hf)

        p.x *= base_scale.x
        p.y *= base_scale.y
        p.z *= base_scale.z

        # Flatten and flare base slightly so outcrops anchor solidly in soil/bed.
        if p.z < -0.24:
            depth = -0.24 - p.z
            p.z = -0.24 - depth * (1.0 - bottom_flat)
            flare = 1.0 + depth * bottom_flat * 0.22
            p.x *= flare
            p.y *= flare

        v.co = p

    # Recenter horizontally around X/Y = 0 and normalize mean radius near ~0.95.
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

    # Non-overlapping Smart UV Project so baked 3D maps have zero seams or overlap.
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66.0), island_margin=0.015)
    bpy.ops.mesh.quads_convert_to_tris()
    bpy.ops.object.mode_set(mode="OBJECT")

    return obj


def mix_in(node, name):
    return next(s for s in node.inputs if s.enabled and s.name == name)


def mix_out(node, name="Result"):
    return next(s for s in node.outputs if s.enabled and s.name == name)


def make_mix(nt, data_type, blend_type="MIX", factor=0.5):
    n = nt.nodes.new("ShaderNodeMix")
    n.data_type = data_type
    if data_type == "RGBA":
        n.blend_type = blend_type
    mix_in(n, "Factor").default_value = factor
    return n


def build_rock_shader_material(spec):
    """Build a 3D Object-space realistic granite/slate shader network for baking."""
    mat = bpy.data.materials.new(f"Mat_{spec['name']}")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()

    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    emit = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    tex_coord = nt.nodes.new("ShaderNodeTexCoord")
    geom = nt.nodes.new("ShaderNodeNewGeometry")
    sep_obj = nt.nodes.new("ShaderNodeSeparateXYZ")
    sep_nrm = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tex_coord.outputs["Object"], sep_obj.inputs["Vector"])
    nt.links.new(geom.outputs["Normal"], sep_nrm.inputs["Vector"])

    # Palette tuned in TRUE LINEAR reflectance for rgba8Unorm: rich mountain granite/slate tones.
    tone = spec["tone"]
    if tone == "granite":
        dark_tone  = (0.048, 0.045, 0.042, 1.0)
        mid_tone   = (0.095, 0.088, 0.079, 1.0)
        warm_tone  = (0.142, 0.118, 0.094, 1.0)
        crack_mix  = 0.55
        bump_str   = 0.85
    elif tone == "slate_granite":
        dark_tone  = (0.038, 0.040, 0.043, 1.0)
        mid_tone   = (0.082, 0.080, 0.078, 1.0)
        warm_tone  = (0.125, 0.106, 0.088, 1.0)
        crack_mix  = 0.45
        bump_str   = 0.78
    else:  # river_cobble
        dark_tone  = (0.046, 0.046, 0.047, 1.0)
        mid_tone   = (0.094, 0.088, 0.078, 1.0)
        warm_tone  = (0.138, 0.118, 0.096, 1.0)
        crack_mix  = 0.08
        bump_str   = 0.36

    # Offset seed coordinate per rock type so textures look distinct.
    offset_map = nt.nodes.new("ShaderNodeMapping")
    offset_map.inputs["Location"].default_value = (
        spec["seed"] * 0.013, spec["seed"] * 0.021, spec["seed"] * 0.007
    )
    nt.links.new(tex_coord.outputs["Object"], offset_map.inputs["Vector"])

    # Stretched strata coordinates (compressed vertically -> horizontal geological layering).
    strata_map = nt.nodes.new("ShaderNodeMapping")
    strata_map.inputs["Scale"].default_value = (1.0, 1.0, 3.6)
    strata_map.inputs["Rotation"].default_value = (0.18, -0.22, 0.0)
    nt.links.new(offset_map.outputs["Vector"], strata_map.inputs["Vector"])

    # 1. Primary layered geological rock texture (multi-octave fractal noise, NO round dots).
    strata_noise = nt.nodes.new("ShaderNodeTexNoise")
    strata_noise.inputs["Scale"].default_value = 3.8
    strata_noise.inputs["Detail"].default_value = 10.0
    strata_noise.inputs["Roughness"].default_value = 0.64
    nt.links.new(strata_map.outputs["Vector"], strata_noise.inputs["Vector"])

    base_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_b = base_ramp.color_ramp
    cr_b.elements[0].position = 0.30
    cr_b.elements[0].color = dark_tone
    e_b_mid = cr_b.elements.new(0.55)
    e_b_mid.color = mid_tone
    cr_b.elements[1].position = 0.78
    cr_b.elements[1].color = warm_tone
    nt.links.new(strata_noise.outputs["Factor"], base_ramp.inputs["Factor"])

    # 2. High-frequency natural stone grit (subtle fine mineral crystals, never polka dots).
    grit_noise = nt.nodes.new("ShaderNodeTexNoise")
    grit_noise.inputs["Scale"].default_value = 42.0
    grit_noise.inputs["Detail"].default_value = 12.0
    grit_noise.inputs["Roughness"].default_value = 0.72
    nt.links.new(offset_map.outputs["Vector"], grit_noise.inputs["Vector"])

    grit_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_gr = grit_ramp.color_ramp
    cr_gr.elements[0].position = 0.32
    cr_gr.elements[0].color = (0.76, 0.76, 0.78, 1.0)
    cr_gr.elements[1].position = 0.72
    cr_gr.elements[1].color = (1.22, 1.20, 1.16, 1.0)
    nt.links.new(grit_noise.outputs["Factor"], grit_ramp.inputs["Factor"])

    gritty_stone = make_mix(nt, "RGBA", blend_type="MULTIPLY", factor=1.0)
    nt.links.new(base_ramp.outputs["Color"], mix_in(gritty_stone, "A"))
    nt.links.new(grit_ramp.outputs["Color"], mix_in(gritty_stone, "B"))

    # 3. Intermittent broken hairline fracture cracks (masked so polygons never close!).
    crack_warp = nt.nodes.new("ShaderNodeTexNoise")
    crack_warp.inputs["Scale"].default_value = 3.1
    crack_warp.inputs["Detail"].default_value = 6.0
    crack_warp.inputs["Roughness"].default_value = 0.65
    nt.links.new(offset_map.outputs["Vector"], crack_warp.inputs["Vector"])

    crack_vec = make_mix(nt, "VECTOR", factor=0.28)
    nt.links.new(offset_map.outputs["Vector"], mix_in(crack_vec, "A"))
    nt.links.new(crack_warp.outputs["Color"], mix_in(crack_vec, "B"))

    crack_voro = nt.nodes.new("ShaderNodeTexVoronoi")
    crack_voro.feature = "DISTANCE_TO_EDGE"
    crack_voro.inputs["Scale"].default_value = 1.85
    crack_voro.inputs["Detail"].default_value = 4.0
    crack_voro.inputs["Roughness"].default_value = 0.60
    nt.links.new(mix_out(crack_vec), crack_voro.inputs["Vector"])

    # Invert edge distance -> 1.0 right along seam, 0.0 away from seam.
    crack_line = nt.nodes.new("ShaderNodeValToRGB")
    cr_c = crack_line.color_ramp
    cr_c.elements[0].position = 0.0
    cr_c.elements[0].color = (1.0, 1.0, 1.0, 1.0)
    cr_c.elements[1].position = 0.022
    cr_c.elements[1].color = (0.0, 0.0, 0.0, 1.0)
    nt.links.new(crack_voro.outputs["Distance"], crack_line.inputs["Factor"])

    # Break up crack continuity so seams fade in/out organically instead of mud tiles.
    crack_gate_noise = nt.nodes.new("ShaderNodeTexNoise")
    crack_gate_noise.inputs["Scale"].default_value = 2.1
    crack_gate_noise.inputs["Detail"].default_value = 4.0
    nt.links.new(offset_map.outputs["Vector"], crack_gate_noise.inputs["Vector"])

    crack_gate_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_cg = crack_gate_ramp.color_ramp
    cr_cg.elements[0].position = 0.45
    cr_cg.elements[0].color = (0.0, 0.0, 0.0, 1.0)
    cr_cg.elements[1].position = 0.68
    cr_cg.elements[1].color = (crack_mix, crack_mix, crack_mix, 1.0)
    nt.links.new(crack_gate_noise.outputs["Factor"], crack_gate_ramp.inputs["Factor"])

    crack_amt = nt.nodes.new("ShaderNodeMath")
    crack_amt.operation = "MULTIPLY"
    crack_amt.use_clamp = True
    nt.links.new(crack_line.outputs["Color"], crack_amt.inputs[0])
    nt.links.new(crack_gate_ramp.outputs["Color"], crack_amt.inputs[1])

    # Invert back to crack_factor (1 = intact rock, 0.45 = crevice seam) for bump & albedo.
    crack_inv = nt.nodes.new("ShaderNodeMath")
    crack_inv.operation = "SUBTRACT"
    crack_inv.use_clamp = True
    crack_inv.inputs[0].default_value = 1.0
    nt.links.new(crack_amt.outputs["Value"], crack_inv.inputs[1])

    crevice_color = make_mix(nt, "RGBA", blend_type="MIX", factor=0.0)
    nt.links.new(crack_amt.outputs["Value"], mix_in(crevice_color, "Factor"))
    nt.links.new(mix_out(gritty_stone), mix_in(crevice_color, "A"))
    mix_in(crevice_color, "B").default_value = (0.022, 0.021, 0.021, 1.0)

    # 4. Subtle curvature edge wear & concave crevice shading via Pointiness.
    edge_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_e = edge_ramp.color_ramp
    cr_e.elements[0].position = 0.45
    cr_e.elements[0].color = (0.68, 0.68, 0.70, 1.0)
    e_mid_e = cr_e.elements.new(0.50)
    e_mid_e.color = (1.0, 1.0, 1.0, 1.0)
    cr_e.elements[1].position = 0.56
    cr_e.elements[1].color = (1.28, 1.24, 1.18, 1.0)
    nt.links.new(geom.outputs["Pointiness"], edge_ramp.inputs["Factor"])

    rock_shaded = make_mix(nt, "RGBA", blend_type="MULTIPLY", factor=1.0)
    nt.links.new(mix_out(crevice_color), mix_in(rock_shaded, "A"))
    nt.links.new(edge_ramp.outputs["Color"], mix_in(rock_shaded, "B"))

    # 5. Damp lower skirt darkening (Z < -0.10 in object space).
    wl_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_w = wl_ramp.color_ramp
    cr_w.elements[0].position = 0.0
    cr_w.elements[0].color = (0.64, 0.66, 0.68, 1.0)
    cr_w.elements[1].position = 1.0
    cr_w.elements[1].color = (1.0, 1.0, 1.0, 1.0)
    wl_map = nt.nodes.new("ShaderNodeMapRange")
    wl_map.inputs["From Min"].default_value = -0.35
    wl_map.inputs["From Max"].default_value = 0.15
    nt.links.new(sep_obj.outputs["Z"], wl_map.inputs["Value"])
    nt.links.new(wl_map.outputs["Result"], wl_ramp.inputs["Factor"])

    base_rock_albedo = make_mix(nt, "RGBA", blend_type="MULTIPLY", factor=1.0)
    nt.links.new(mix_out(rock_shaded), mix_in(base_rock_albedo, "A"))
    nt.links.new(wl_ramp.outputs["Color"], mix_in(base_rock_albedo, "B"))

    # 6. Per-pixel roughness map (G channel): smoother water-worn facets, rougher grit & cracks.
    rough_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_r = rough_ramp.color_ramp
    cr_r.elements[0].position = 0.28
    cr_r.elements[0].color = (0.46, 0.46, 0.46, 1.0)
    cr_r.elements[1].position = 0.75
    cr_r.elements[1].color = (0.86, 0.86, 0.86, 1.0)
    nt.links.new(grit_noise.outputs["Factor"], rough_ramp.inputs["Factor"])

    rough_with_cracks = make_mix(nt, "RGBA", blend_type="MIX", factor=0.0)
    nt.links.new(crack_amt.outputs["Value"], mix_in(rough_with_cracks, "Factor"))
    nt.links.new(rough_ramp.outputs["Color"], mix_in(rough_with_cracks, "A"))
    mix_in(rough_with_cracks, "B").default_value = (0.95, 0.95, 0.95, 1.0)

    sep_rough = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(mix_out(rough_with_cracks), sep_rough.inputs["Color"])
    comb_mr = nt.nodes.new("ShaderNodeCombineColor")
    comb_mr.inputs["Red"].default_value = 1.0
    nt.links.new(sep_rough.outputs["Green"], comb_mr.inputs["Green"])
    comb_mr.inputs["Blue"].default_value = 0.0

    # 7. Multi-scale 3D Bump (strata ledges + fine stone grit + broken fracture seams) -> Tangent Normal.
    bump_strata = nt.nodes.new("ShaderNodeBump")
    bump_strata.inputs["Strength"].default_value = bump_str * 0.55
    bump_strata.inputs["Distance"].default_value = 0.028
    nt.links.new(strata_noise.outputs["Factor"], bump_strata.inputs["Height"])

    bump_grit = nt.nodes.new("ShaderNodeBump")
    bump_grit.inputs["Strength"].default_value = bump_str * 0.45
    bump_grit.inputs["Distance"].default_value = 0.010
    nt.links.new(grit_noise.outputs["Factor"], bump_grit.inputs["Height"])
    nt.links.new(bump_strata.outputs["Normal"], bump_grit.inputs["Normal"])

    bump_cracks = nt.nodes.new("ShaderNodeBump")
    bump_cracks.inputs["Strength"].default_value = bump_str * 0.75
    bump_cracks.inputs["Distance"].default_value = 0.038
    nt.links.new(crack_inv.outputs["Value"], bump_cracks.inputs["Height"])
    nt.links.new(bump_grit.outputs["Normal"], bump_cracks.inputs["Normal"])
    nt.links.new(bump_cracks.outputs["Normal"], bsdf.inputs["Normal"])

    # 8. Rich patchy moss clinging ONLY to upward surfaces & damp pockets (never uniform green).
    nrm_z_map = nt.nodes.new("ShaderNodeMapRange")
    nrm_z_map.inputs["From Min"].default_value = 0.05
    nrm_z_map.inputs["From Max"].default_value = 0.62
    nt.links.new(sep_nrm.outputs["Z"], nrm_z_map.inputs["Value"])

    moss_noise = nt.nodes.new("ShaderNodeTexNoise")
    moss_noise.inputs["Scale"].default_value = 4.2
    moss_noise.inputs["Detail"].default_value = 8.0
    moss_noise.inputs["Roughness"].default_value = 0.72
    nt.links.new(offset_map.outputs["Vector"], moss_noise.inputs["Vector"])

    moss_patch_ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr_mp = moss_patch_ramp.color_ramp
    cr_mp.elements[0].position = 0.44
    cr_mp.elements[0].color = (0.0, 0.0, 0.0, 1.0)
    cr_mp.elements[1].position = 0.56
    cr_mp.elements[1].color = (1.0, 1.0, 1.0, 1.0)
    nt.links.new(moss_noise.outputs["Factor"], moss_patch_ramp.inputs["Factor"])

    moss_height_map = nt.nodes.new("ShaderNodeMapRange")
    moss_height_map.inputs["From Min"].default_value = -0.22
    moss_height_map.inputs["From Max"].default_value = 0.05
    nt.links.new(sep_obj.outputs["Z"], moss_height_map.inputs["Value"])

    moss_mul1 = nt.nodes.new("ShaderNodeMath")
    moss_mul1.operation = "MULTIPLY"
    moss_mul1.use_clamp = True
    nt.links.new(nrm_z_map.outputs["Result"], moss_mul1.inputs[0])
    nt.links.new(moss_patch_ramp.outputs["Color"], moss_mul1.inputs[1])

    moss_mask = nt.nodes.new("ShaderNodeMath")
    moss_mask.operation = "MULTIPLY"
    moss_mask.use_clamp = True
    nt.links.new(moss_mul1.outputs["Value"], moss_mask.inputs[0])
    nt.links.new(moss_height_map.outputs["Result"], moss_mask.inputs[1])

    moss_color_noise = nt.nodes.new("ShaderNodeTexNoise")
    moss_color_noise.inputs["Scale"].default_value = 28.0
    moss_color_noise.inputs["Detail"].default_value = 8.0
    moss_color_noise.inputs["Roughness"].default_value = 0.75
    nt.links.new(offset_map.outputs["Vector"], moss_color_noise.inputs["Vector"])

    moss_palette = nt.nodes.new("ShaderNodeValToRGB")
    cr_mpl = moss_palette.color_ramp
    cr_mpl.elements[0].position = 0.25
    cr_mpl.elements[0].color = (0.022, 0.048, 0.012, 1.0)  # deep forest moss shadow
    cr_mpl.elements[1].position = 0.78
    cr_mpl.elements[1].color = (0.062, 0.105, 0.024, 1.0)  # natural olive moss clumps
    nt.links.new(moss_color_noise.outputs["Factor"], moss_palette.inputs["Factor"])

    moss_rock_albedo = make_mix(nt, "RGBA", blend_type="MIX", factor=0.0)
    nt.links.new(moss_mask.outputs["Value"], mix_in(moss_rock_albedo, "Factor"))
    nt.links.new(mix_out(base_rock_albedo), mix_in(moss_rock_albedo, "A"))
    nt.links.new(moss_palette.outputs["Color"], mix_in(moss_rock_albedo, "B"))

    # Moss roughness = 0.95 matte velvety, stone roughness kept where exposed.
    moss_mr = make_mix(nt, "RGBA", blend_type="MIX", factor=0.0)
    nt.links.new(moss_mask.outputs["Value"], mix_in(moss_mr, "Factor"))
    nt.links.new(comb_mr.outputs["Color"], mix_in(moss_mr, "A"))
    mix_in(moss_mr, "B").default_value = (1.0, 0.95, 0.0, 1.0)

    bake_tex = nt.nodes.new("ShaderNodeTexImage")
    nt.nodes.active = bake_tex

    return {
        "mat": mat,
        "nt": nt,
        "out": out,
        "bsdf": bsdf,
        "emit": emit,
        "bake_tex": bake_tex,
        "albedo_out": mix_out(base_rock_albedo),
        "moss_albedo_out": mix_out(moss_rock_albedo),
        "mr_out": comb_mr.outputs["Color"],
        "moss_mr_out": mix_out(moss_mr),
    }


def save_bake_image(obj, info, res, out_path, bake_type, samples=1, emit_socket=None):
    nt = info["nt"]
    out = info["out"]
    emit = info["emit"]
    bsdf = info["bsdf"]
    bake_tex = info["bake_tex"]

    for link in list(out.inputs["Surface"].links):
        nt.links.remove(link)

    if bake_type == "EMIT":
        for link in list(emit.inputs["Color"].links):
            nt.links.remove(link)
        nt.links.new(emit_socket, emit.inputs["Color"])
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    else:
        nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    bpy.context.scene.cycles.samples = samples
    img = bpy.data.images.new(os.path.basename(out_path), width=res, height=res)
    img.colorspace_settings.name = "Non-Color"
    bake_tex.image = img

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.bake(type=bake_type)

    img.filepath_raw = out_path
    img.file_format = "BMP"
    img.save()
    bpy.data.images.remove(img)


def configure_cycles():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.use_denoising = False
    scene.render.bake.margin = 8
    scene.render.bake.use_clear = True
    scene.world.light_settings.distance = 0.65


def export_rock_gltf(obj, out_dir):
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
    os.makedirs(out_dir, exist_ok=True)

    for spec in ROCK_SPECS:
        clear_scene()
        configure_cycles()
        obj = sculpt_rock(spec)
        export_rock_gltf(obj, out_dir)

        info = build_rock_shader_material(spec)
        obj.data.materials.append(info["mat"])

        name = spec["name"]
        ares = spec["albedo_res"]
        xres = spec["aux_res"]

        save_bake_image(obj, info, ares, os.path.join(out_dir, f"{name}_albedo.bmp"),
                        "EMIT", samples=1, emit_socket=info["albedo_out"])
        save_bake_image(obj, info, ares, os.path.join(out_dir, f"{name}_normal.bmp"),
                        "NORMAL", samples=1)
        save_bake_image(obj, info, xres, os.path.join(out_dir, f"{name}_mr.bmp"),
                        "EMIT", samples=1, emit_socket=info["mr_out"])
        save_bake_image(obj, info, xres, os.path.join(out_dir, f"{name}_ao.bmp"),
                        "AO", samples=16)

        if spec["bake_moss"]:
            save_bake_image(obj, info, ares, os.path.join(out_dir, f"{name}_moss_albedo.bmp"),
                            "EMIT", samples=1, emit_socket=info["moss_albedo_out"])
            save_bake_image(obj, info, xres, os.path.join(out_dir, f"{name}_moss_mr.bmp"),
                            "EMIT", samples=1, emit_socket=info["moss_mr_out"])

        print(f"Baked PBR textures for {name} (albedo/normal {ares}px, mr/ao {xres}px)")


if __name__ == "__main__":
    main()
