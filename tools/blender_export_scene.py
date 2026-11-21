"""Export a Blender scene as a streamed open world for the engine.

Outputs (paths relative to the project root, default ``assets/world``):

    <out>/<name>.scene.json                 root scene (v2): sun/global objects,
                                            chunk manifest, splines asset link
    <out>/<name>/chunks/chunk_<x>_<z>.scene.json   one v2 scene per occupied cell
    <out>/<name>/meshes/<mesh>.glb          one GLB per unique mesh (Y-up)
    <out>/<name>/meshes/<mesh>.asset.json   engine model asset (+ collision)
    <out>/<name>/<name>.splines.json        road / traffic / river splines
    <out>/<name>/export_report.json         per-chunk / per-biome counts
    *.meta                                  deterministic GUID sidecars

Every object is placed in the cell that contains its origin
(``floor(x / cellSize), floor(z / cellSize)`` in engine Y-up space); a
chunk's bounds cover its cell and the full height of its contents. Blender
Z-up is converted to engine Y-up: ``(x, y, z) -> (x, z, -y)``.

Custom properties (Object > Custom Properties) drive engine data:

    ge_physics       "static" | "dynamic" | "kinematic" | "none" (default static for meshes)
    ge_shape         "triangleMesh" | "convexHull" | "primitive" (default triangleMesh,
                     convexHull for dynamic bodies)
    ge_surface       "asphalt" | "concrete" | "dirt" | "gravel" | "grass" | "sand" |
                     "snow" | "ice" | "mud" | "wood" | "metal" | "rubber" -> friction/restitution
    ge_friction, ge_restitution, ge_mass   explicit overrides
    ge_global        true -> root scene (always loaded) instead of a chunk
    ge_biome         free-form tag (defaults to the first "Biome_<name>" collection)
    ge_skip          true -> not exported
    Curves:  ge_role ("road" default | "traffic" | "river" | "rail" | ...),
             ge_width, ge_lanes, ge_speed_limit

Usage (Blender 4.2+ / 5.x):

    blender -b level.blend -P tools/blender_export_scene.py -- --name=level01
    blender -b --factory-startup -P tools/blender_export_scene.py -- --build-test-level

    # Flatpak:
    flatpak run org.blender.Blender -b level.blend -P tools/blender_export_scene.py -- --name=level01

Options (after ``--``):

    --name=NAME           world name (default: .blend name or "world")
    --out=DIR             output dir relative to project root (default assets/world)
    --project-root=DIR    project root (default: current directory)
    --cell-size=M         chunk size in metres (default 256)
    --load-radius=M       WorldStreamer load radius (default 1.5 x cell)
    --unload-radius=M     WorldStreamer unload radius (default 2 x cell)
    --collection=NAME     export only this collection (recursive)
    --build-test-level    replace the scene with the generated multi-biome test level
    --from-json=FILE      no Blender: export a neutral description (see below)
    --dump-json=FILE      also write the neutral description gathered from Blender

The backend (``export_world``) is pure Python so it can be exercised without
Blender: ``python3 tools/blender_export_scene.py --from-json=desc.json``
writes scenes/splines/assets for meshes whose ``.glb`` already exist.
"""

import json
import math
import os
import sys
import uuid

SCENE_FORMAT = "game-engine.scene"
ASSET_FORMAT = "game-engine.asset"
SPLINES_FORMAT = "game-engine.splines"

SURFACES = {
    # name: (friction, restitution)
    "asphalt": (0.9, 0.0),
    "concrete": (0.85, 0.0),
    "dirt": (0.65, 0.0),
    "gravel": (0.6, 0.0),
    "grass": (0.55, 0.0),
    "sand": (0.5, 0.0),
    "snow": (0.3, 0.0),
    "ice": (0.05, 0.0),
    "mud": (0.4, 0.0),
    "wood": (0.6, 0.1),
    "metal": (0.45, 0.05),
    "rubber": (1.0, 0.6),
}

# ---------------------------------------------------------------------------
# Pure backend (no bpy)
# ---------------------------------------------------------------------------


def guid_for(path):
    """Deterministic 32-hex GUID: re-exports keep stable asset identities."""
    return uuid.uuid5(uuid.NAMESPACE_URL, "game-engine:" + path.replace("\\", "/")).hex


def blender_to_engine_vec(v):
    x, y, z = v
    return [x, z, -y]


def blender_to_engine_quat(q):
    """Blender (w, x, y, z) -> engine [x, y, z, w] under the Z-up -> Y-up basis change."""
    w, x, y, z = q
    return [x, z, -y, w]


def blender_to_engine_scale(s):
    x, y, z = s
    return [x, z, y]


def cell_of(pos, cell_size):
    return (int(math.floor(pos[0] / cell_size)), int(math.floor(pos[2] / cell_size)))


def _num(v):
    """Compact float for JSON (avoid -0.0 and float noise)."""
    f = float(v)
    if abs(f) < 1e-9:
        return 0
    r = round(f, 6)
    return int(r) if r == int(r) and abs(r) < 1e15 else r


def _vec(v):
    return [_num(c) for c in v]


def resolve_physics(obj):
    """Engine physics block for an object description, or None."""
    phys = obj.get("physics", "static" if obj.get("mesh") else "none")
    if phys in (None, "none", False):
        return None
    if phys not in ("static", "dynamic", "kinematic"):
        raise ValueError("%s: ge_physics must be static|dynamic|kinematic|none, got %r" % (obj["name"], phys))
    shape = obj.get("shape") or ("convexHull" if phys == "dynamic" else "triangleMesh")
    if shape not in ("triangleMesh", "convexHull", "primitive"):
        raise ValueError("%s: ge_shape must be triangleMesh|convexHull|primitive" % obj["name"])
    warnings = []
    if phys != "static" and shape == "triangleMesh":
        warnings.append("%s: triangleMesh is static-only; using convexHull" % obj["name"])
        shape = "convexHull"
    friction, restitution = 0.5, 0.0
    surface = obj.get("surface")
    if surface:
        if surface not in SURFACES:
            raise ValueError("%s: unknown ge_surface %r (known: %s)" % (obj["name"], surface, ", ".join(sorted(SURFACES))))
        friction, restitution = SURFACES[surface]
    if "friction" in obj:
        friction = float(obj["friction"])
    if "restitution" in obj:
        restitution = float(obj["restitution"])
    block = {
        "enabled": True,
        "motion": phys,
        "shape": shape,
        "friction": _num(friction),
        "restitution": _num(restitution),
        "mass": _num(obj.get("mass", 1.0)),
        "linearDamping": 0,
        "angularDamping": 0,
        "maxHullVertices": 64,
    }
    return block, warnings


class _SceneBuilder:
    """Accumulates one ``*.scene.json`` (strings table + entities)."""

    def __init__(self, name):
        self.name = name
        self.strings = []
        self._index = {}
        self.entities = []
        self.asset_links = []
        self._linked = set()
        self.y_min = None
        self.y_max = None

    def string(self, s):
        if s not in self._index:
            self._index[s] = len(self.strings)
            self.strings.append(s)
        return self._index[s]

    def link(self, guid, path, kind):
        if (guid, kind) in self._linked:
            return
        self._linked.add((guid, kind))
        self.asset_links.append({"guid": guid, "path": self.string(path), "kind": kind})

    def add_entity(self, ent, y_range):
        ent["id"] = len(self.entities) + 1
        self.entities.append(ent)
        lo, hi = y_range
        self.y_min = lo if self.y_min is None else min(self.y_min, lo)
        self.y_max = hi if self.y_max is None else max(self.y_max, hi)

    def to_json(self, settings=None, cell_bounds=None, chunks=None):
        root = {
            "format": SCENE_FORMAT,
            "version": 2,
            "meta": {"name": self.name, "units": "meters"},
            "strings": self.strings,
            "settings": settings or {"gravity": [0, -9.81, 0], "iblPreset": "procedural_default"},
            "entities": self.entities,
        }
        if cell_bounds is not None:
            root["cellBounds"] = cell_bounds
        if self.asset_links:
            root["assetLinks"] = self.asset_links
        if chunks is not None:
            root["chunks"] = chunks
        return root


def _entity_for(obj, builder, mesh_assets, warnings):
    ent = {
        "name": builder.string(obj["name"]),
        "parent": 0,
        "transform": {
            "pos": _vec(obj["position"]),
            "rot": _vec(obj.get("rotation", [0, 0, 0, 1])),
            "scale": _vec(obj.get("scale", [1, 1, 1])),
        },
    }
    mesh = obj.get("mesh")
    if mesh:
        asset = mesh_assets[mesh]
        ent["visual"] = {
            "asset": builder.string(asset["path"]),
            "assetGuid": asset["guid"],
            "kind": "mesh",
            "halfExtents": _vec(asset["halfExtents"]),
        }
        builder.link(asset["guid"], asset["path"], "model")
        phys = resolve_physics(obj)
        if phys:
            block, w = phys
            warnings.extend(w)
            ent["physics"] = block
    light = obj.get("light")
    if light:
        ent["light"] = {
            "type": light["type"],
            "color": _vec(light.get("color", [1, 1, 1])),
            "intensity": _num(light.get("intensity", 1)),
            "range": _num(light.get("range", 10)),
            "innerConeDeg": _num(light.get("innerConeDeg", 15)),
            "outerConeDeg": _num(light.get("outerConeDeg", 25)),
            "castShadows": bool(light.get("castShadows", False)),
        }
    return ent


def _y_range(obj, mesh_assets):
    """Vertical extent of an object (engine Y), from its world bounds when known."""
    if "boundsMin" in obj and "boundsMax" in obj:
        return obj["boundsMin"][1], obj["boundsMax"][1]
    y = obj["position"][1]
    mesh = obj.get("mesh")
    if mesh:
        h = mesh_assets[mesh]["halfExtents"]
        s = obj.get("scale", [1, 1, 1])
        r = math.sqrt((h[0] * s[0]) ** 2 + (h[1] * s[1]) ** 2 + (h[2] * s[2]) ** 2)
        return y - r, y + r
    return y, y


def write_json(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, separators=(",", ":"))
        f.write("\n")


def write_meta(path, importer, rel=None):
    """Sidecar with a GUID derived from the project-relative path `rel`
    (kept when the sidecar already exists), so re-exports and other machines
    produce the same asset identities."""
    meta_path = path + ".meta"
    rel = rel or path
    data = None
    if os.path.exists(meta_path):
        try:
            with open(meta_path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = None
    if not data or "guid" not in data:
        data = {"guid": guid_for(rel), "importer": importer, "settings": {}}
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4)
            f.write("\n")
    return data["guid"]


def model_asset_json(name, glb_path, hull_points):
    collision = {"triangleMesh": {"source": "render"}}
    if hull_points:
        collision["convexHull"] = {"maxVertexCount": 64, "points": [_vec(p) for p in hull_points]}
    return {
        "format": ASSET_FORMAT,
        "version": 2,
        "kind": "model",
        "meta": {"name": name},
        "render": {"source": glb_path, "primitive": None},
        "materials": [],
        "collision": collision,
    }


def export_world(desc, project_root=".", out_dir="assets/world", cell_size=256.0,
                 load_radius=None, unload_radius=None, log=print):
    """Write a chunked world from a neutral description.

    ``desc`` = {
      "name": str,
      "meshes": {key: {"glb": project-relative .glb path (already written),
                       "halfExtents": [hx,hy,hz], "hullPoints": [[x,y,z], ...]}},
      "objects": [{"name", "position", "rotation" [x,y,z,w], "scale", "mesh"?,
                   "light"?, "physics"?, "shape"?, "surface"?, "friction"?,
                   "restitution"?, "mass"?, "global"?, "biome"?,
                   "boundsMin"?, "boundsMax"?}],
      "splines": [{"name", "role", "kind", "closed", "width", "lanes",
                   "speedLimit", "points": [[x,y,z], ...]}],
      "settings": optional scene settings object,
    }
    All coordinates are engine Y-up. Returns the export report dict.
    """
    name = desc["name"]
    if cell_size <= 0:
        raise ValueError("cell size must be > 0")
    load_radius = load_radius if load_radius is not None else cell_size * 1.5
    unload_radius = unload_radius if unload_radius is not None else cell_size * 2.0
    if unload_radius < load_radius:
        raise ValueError("unload radius must be >= load radius (hysteresis)")

    def abs_path(rel):
        return os.path.join(project_root, rel)

    world_dir = out_dir.rstrip("/") + "/" + name
    warnings = []

    # 1. Model assets (one per unique mesh).
    mesh_assets = {}
    for key, mesh in sorted(desc.get("meshes", {}).items()):
        glb = mesh["glb"]
        if not os.path.exists(abs_path(glb)):
            raise FileNotFoundError("mesh %r: render source %s does not exist" % (key, glb))
        write_meta(abs_path(glb), "gltf", glb)
        asset_path = os.path.splitext(glb)[0] + ".asset.json"
        write_json(abs_path(asset_path), model_asset_json(key, glb, mesh.get("hullPoints")))
        guid = write_meta(abs_path(asset_path), "asset", asset_path)
        mesh_assets[key] = {"path": asset_path, "guid": guid,
                            "halfExtents": mesh.get("halfExtents", [0.5, 0.5, 0.5])}

    # 2. Split objects into the root scene and per-cell chunk scenes.
    root = _SceneBuilder(name)
    chunks = {}
    biomes = {}
    for obj in desc.get("objects", []):
        if obj.get("mesh") and obj["mesh"] not in mesh_assets:
            raise ValueError("%s references unknown mesh %r" % (obj["name"], obj["mesh"]))
        is_global = obj.get("global") or (obj.get("light", {}).get("type") == "directional")
        if is_global:
            target = root
        else:
            coord = cell_of(obj["position"], cell_size)
            target = chunks.get(coord)
            if target is None:
                target = chunks[coord] = _SceneBuilder("%s_chunk_%d_%d" % (name, coord[0], coord[1]))
        target.add_entity(_entity_for(obj, target, mesh_assets, warnings), _y_range(obj, mesh_assets))
        b = obj.get("biome") or "default"
        biomes[b] = biomes.get(b, 0) + 1

    # 3. Chunk scenes + manifest.
    items = []
    report_chunks = []
    for (cx, cz) in sorted(chunks):
        sb = chunks[(cx, cz)]
        lo_y = math.floor(sb.y_min) - 1.0
        hi_y = math.ceil(sb.y_max) + 1.0
        bounds = {"min": _vec([cx * cell_size, lo_y, cz * cell_size]),
                  "max": _vec([(cx + 1) * cell_size, hi_y, (cz + 1) * cell_size])}
        rel = "%s/chunks/chunk_%d_%d.scene.json" % (world_dir, cx, cz)
        write_json(abs_path(rel), sb.to_json(cell_bounds=bounds))
        write_meta(abs_path(rel), "scene", rel)
        items.append({"coord": [cx, cz], "bounds": bounds, "scenePath": rel})
        report_chunks.append({"coord": [cx, cz], "entities": len(sb.entities), "scenePath": rel})

    # 4. Splines.
    splines_rel = None
    spline_items = []
    for s in desc.get("splines", []):
        kind = s.get("kind", "catmullRom")
        pts = s["points"]
        if kind == "bezier":
            ok = len(pts) >= 3 and len(pts) % 3 == 0 if s.get("closed") else len(pts) >= 4 and (len(pts) - 1) % 3 == 0
        else:
            ok = len(pts) >= 2
        if not ok:
            warnings.append("spline %s: invalid point count %d for %s; skipped" % (s["name"], len(pts), kind))
            continue
        spline_items.append({
            "name": s["name"], "role": s.get("role", "road"), "kind": kind,
            "closed": bool(s.get("closed", False)), "alpha": _num(s.get("alpha", 0.5)),
            "width": _num(s.get("width", 8)), "lanes": int(s.get("lanes", 2)),
            "speedLimit": _num(s.get("speedLimit", 0)), "points": [_vec(p) for p in pts],
        })
    if spline_items:
        splines_rel = "%s/%s.splines.json" % (world_dir, name)
        write_json(abs_path(splines_rel), {"format": SPLINES_FORMAT, "version": 1, "splines": spline_items})
        root.link(write_meta(abs_path(splines_rel), "splines", splines_rel), splines_rel, "splines")

    # 5. Root scene.
    root_rel = "%s/%s.scene.json" % (out_dir.rstrip("/"), name)
    manifest = {"cellSize": _num(cell_size), "loadRadius": _num(load_radius),
                "unloadRadius": _num(unload_radius), "items": items}
    write_json(abs_path(root_rel), root.to_json(settings=desc.get("settings"), chunks=manifest))
    write_meta(abs_path(root_rel), "scene", root_rel)

    report = {
        "name": name, "rootScene": root_rel, "cellSize": cell_size,
        "chunks": report_chunks, "rootEntities": len(root.entities),
        "meshes": len(mesh_assets), "splines": len(spline_items),
        "splinesPath": splines_rel, "biomes": biomes, "warnings": warnings,
    }
    write_json(abs_path("%s/export_report.json" % world_dir), report)
    for w in warnings:
        log("warning: " + w)
    log("exported %s: %d chunks, %d root entities, %d meshes, %d splines -> %s"
        % (name, len(items), len(root.entities), len(mesh_assets), len(spline_items), root_rel))
    return report


# ---------------------------------------------------------------------------
# Blender frontend
# ---------------------------------------------------------------------------


def _bpy():
    import bpy  # noqa: F401  (only available inside Blender)
    return bpy


def _prop(obj, key, default=None):
    try:
        return obj[key] if key in obj.keys() else default
    except (TypeError, AttributeError):
        return default


def _biome_of(obj):
    b = _prop(obj, "ge_biome")
    if b:
        return str(b)
    for coll in obj.users_collection:
        if coll.name.startswith("Biome_"):
            return coll.name[len("Biome_"):]
    return None


def _objects_to_export(bpy, collection_name):
    if collection_name:
        coll = bpy.data.collections.get(collection_name)
        if coll is None:
            raise ValueError("collection %r not found" % collection_name)
        objs = list(coll.all_objects)
    else:
        objs = list(bpy.context.scene.objects)
    return [o for o in objs if not _prop(o, "ge_skip", False) and o.visible_get()]


def _mesh_key(obj):
    """Objects sharing mesh data and without modifiers share one GLB."""
    if obj.modifiers:
        return "obj_" + obj.name
    return obj.data.name


def _safe_name(s):
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in s).strip("_") or "mesh"


def _export_mesh_glb(bpy, obj, glb_abs):
    """Export `obj`'s geometry at identity transform to a Y-up GLB."""
    tmp = obj.copy()
    tmp.data = obj.data
    bpy.context.scene.collection.objects.link(tmp)
    for o in bpy.context.view_layer.objects:
        o.select_set(False)
    tmp.parent = None
    tmp.matrix_world = tmp.matrix_world.Identity(4)
    tmp.select_set(True)
    bpy.context.view_layer.objects.active = tmp
    os.makedirs(os.path.dirname(glb_abs), exist_ok=True)
    try:
        bpy.ops.export_scene.gltf(
            filepath=glb_abs, export_format="GLB", use_selection=True,
            export_yup=True, export_apply=True, export_tangents=True,
            export_animations=False, export_cameras=False, export_lights=False)
    finally:
        bpy.data.objects.remove(tmp, do_unlink=True)


def _mesh_stats(obj):
    """Local-space half extents and up to 128 hull points, engine Y-up."""
    me = obj.data
    if not me.vertices:
        return [0.5, 0.5, 0.5], []
    pts = [blender_to_engine_vec(tuple(v.co)) for v in me.vertices]
    lo = [min(p[i] for p in pts) for i in range(3)]
    hi = [max(p[i] for p in pts) for i in range(3)]
    half = [max((hi[i] - lo[i]) * 0.5, 0.01) for i in range(3)]
    step = max(1, len(pts) // 128)
    return half, pts[::step][:128]


def _world_bounds(obj):
    corners = [blender_to_engine_vec(tuple(obj.matrix_world @ _vector(c))) for c in obj.bound_box]
    return ([min(c[i] for c in corners) for i in range(3)],
            [max(c[i] for c in corners) for i in range(3)])


def _vector(c):
    from mathutils import Vector
    return Vector(c)


def _light_desc(obj):
    lamp = obj.data
    color = list(lamp.color)
    if lamp.type == "SUN":
        return {"type": "directional", "color": color, "intensity": float(lamp.energy),
                "castShadows": True}
    if lamp.type in ("POINT", "SPOT"):
        d = {"type": "point" if lamp.type == "POINT" else "spot", "color": color,
             # Blender watts -> engine intensity (rough photometric match).
             "intensity": float(lamp.energy) / 100.0,
             "range": float(lamp.cutoff_distance) if getattr(lamp, "use_custom_distance", False)
             else max(5.0, math.sqrt(max(float(lamp.energy), 1.0)) * 2.0),
             "castShadows": bool(getattr(lamp, "use_shadow", False))}
        if lamp.type == "SPOT":
            outer = math.degrees(lamp.spot_size) * 0.5
            d["outerConeDeg"] = outer
            d["innerConeDeg"] = outer * (1.0 - float(lamp.spot_blend))
        return d
    return None


def _curve_splines(obj):
    out = []
    mw = obj.matrix_world
    role = str(_prop(obj, "ge_role", "road"))
    for i, sp in enumerate(obj.data.splines):
        name = obj.name if len(obj.data.splines) == 1 else "%s_%d" % (obj.name, i)
        entry = {"name": name, "role": role, "closed": bool(sp.use_cyclic_u),
                 "width": float(_prop(obj, "ge_width", 8.0)),
                 "lanes": int(_prop(obj, "ge_lanes", 2)),
                 "speedLimit": float(_prop(obj, "ge_speed_limit", 0.0))}
        if sp.type == "BEZIER":
            bp = sp.bezier_points
            pts = []
            n = len(bp)
            for k in range(n):
                pts.append(bp[k].co)
                if k + 1 < n or sp.use_cyclic_u:
                    nxt = bp[(k + 1) % n]
                    pts.append(bp[k].handle_right)
                    pts.append(nxt.handle_left)
            entry["kind"] = "bezier"
            entry["points"] = [blender_to_engine_vec(tuple(mw @ p)) for p in pts]
        else:
            entry["kind"] = "catmullRom"
            entry["points"] = [blender_to_engine_vec(tuple(mw @ _vector(p.co[:3]))) for p in sp.points]
        out.append(entry)
    return out


def gather_blender_scene(name, project_root, out_dir, collection=None, log=print):
    """Read the open Blender scene into the neutral description (writes GLBs)."""
    bpy = _bpy()
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    world_dir = out_dir.rstrip("/") + "/" + name
    desc = {"name": name, "meshes": {}, "objects": [], "splines": []}
    exported = {}
    for obj in _objects_to_export(bpy, collection):
        if obj.type == "CURVE":
            desc["splines"].extend(_curve_splines(obj))
            continue
        pos = blender_to_engine_vec(tuple(obj.matrix_world.to_translation()))
        rot = blender_to_engine_quat(tuple(obj.matrix_world.to_quaternion()))
        scale = blender_to_engine_scale(tuple(obj.matrix_world.to_scale()))
        entry = {"name": obj.name, "position": pos, "rotation": rot, "scale": scale}
        biome = _biome_of(obj)
        if biome:
            entry["biome"] = biome
        if _prop(obj, "ge_global", False):
            entry["global"] = True
        if obj.type == "MESH":
            key = _mesh_key(obj)
            if key not in exported:
                rel = "%s/meshes/%s.glb" % (world_dir, _safe_name(key))
                _export_mesh_glb(bpy, obj, os.path.join(project_root, rel))
                half, hull = _mesh_stats(obj)
                desc["meshes"][key] = {"glb": rel, "halfExtents": half, "hullPoints": hull}
                exported[key] = rel
            entry["mesh"] = key
            bmin, bmax = _world_bounds(obj)
            entry["boundsMin"], entry["boundsMax"] = bmin, bmax
            for src, dst in (("ge_physics", "physics"), ("ge_shape", "shape"), ("ge_surface", "surface"),
                             ("ge_friction", "friction"), ("ge_restitution", "restitution"), ("ge_mass", "mass")):
                v = _prop(obj, src)
                if v is not None:
                    entry[dst] = v if not hasattr(v, "to_dict") else v.to_dict()
        elif obj.type == "LIGHT":
            light = _light_desc(obj)
            if light is None:
                log("warning: %s: unsupported light type %s; skipped" % (obj.name, obj.data.type))
                continue
            entry["light"] = light
        elif obj.type != "EMPTY":
            continue
        else:
            continue  # empties carry no engine data (hierarchy is flattened)
        desc["objects"].append(entry)
    return desc


def build_test_level():
    """Replace the scene with a 3 x 3 cell multi-biome test level (768 m x 768 m).

    Biomes: forest (NW), desert (S), snow (NE), each with its own props and
    surfaces; a Bezier main road crossing the map, a closed traffic loop, a
    poly-line river and a sun.
    """
    bpy = _bpy()
    import random
    from mathutils import Vector

    random.seed(8)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    def collection(name):
        c = bpy.data.collections.new(name)
        scene.collection.children.link(c)
        return c

    def mesh_object(name, mesh, coll, loc, rot_z=0.0, scale=1.0, **props):
        o = bpy.data.objects.new(name, mesh)
        coll.objects.link(o)
        o.location = loc
        o.rotation_euler = (0, 0, rot_z)
        o.scale = (scale, scale, scale)
        for k, v in props.items():
            o[k] = v
        return o

    def make_mesh(name, kind, size):
        import bmesh
        bm = bmesh.new()
        if kind == "cube":
            bmesh.ops.create_cube(bm, size=1.0)
            bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
        elif kind == "cone":
            bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=size[0], radius2=0.0, depth=size[2])
            bmesh.ops.translate(bm, vec=Vector((0, 0, size[2] * 0.5)), verts=bm.verts)
        elif kind == "ico":
            bmesh.ops.create_icosphere(bm, subdivisions=2, radius=size[0])
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        return me

    pine = make_mesh("pine_tree", "cone", (2.0, 2.0, 9.0))
    rock = make_mesh("boulder", "ico", (1.6, 1.6, 1.6))
    cactus = make_mesh("cactus", "cube", (0.6, 0.6, 4.0))
    dune = make_mesh("dune_block", "cube", (14.0, 9.0, 2.5))
    snow_rock = make_mesh("snow_rock", "ico", (2.4, 2.4, 2.4))
    cabin = make_mesh("cabin", "cube", (8.0, 6.0, 4.0))
    crate = make_mesh("crate", "cube", (1.0, 1.0, 1.0))

    forest = collection("Biome_forest")
    desert = collection("Biome_desert")
    snow = collection("Biome_snow")
    roads = collection("Roads")
    env = collection("Environment")

    # Blender XY is the ground plane (engine XZ with z = -y). Cells are 256 m;
    # keep everything inside x in [0, 768), engine z in [0, 768) => blender y in (-768, 0].
    def ground(x, y_engine):
        return (x, -y_engine, 0.0)

    for i in range(40):  # forest: cells (0..1, 0..1)
        x, z = random.uniform(10, 500), random.uniform(10, 300)
        mesh_object("pine_%02d" % i, pine, forest, ground(x, z), random.uniform(0, 6.28),
                    random.uniform(0.8, 1.3), ge_surface="wood")
    for i in range(12):
        x, z = random.uniform(10, 500), random.uniform(10, 300)
        mesh_object("forest_rock_%02d" % i, rock, forest, ground(x, z), random.uniform(0, 6.28),
                    random.uniform(0.7, 1.5), ge_surface="gravel")
    for i in range(20):  # desert: south strip, cells (0..2, 2)
        x, z = random.uniform(10, 760), random.uniform(530, 760)
        mesh_object("cactus_%02d" % i, cactus, desert, ground(x, z), 0.0, 1.0, ge_surface="sand")
    for i in range(6):
        x, z = random.uniform(30, 730), random.uniform(540, 740)
        mesh_object("dune_%02d" % i, dune, desert, ground(x, z), random.uniform(0, 3.14), 1.0,
                    ge_surface="sand")
    for i in range(15):  # snow: north-east, cell (2, 0..1)
        x, z = random.uniform(530, 760), random.uniform(10, 480)
        mesh_object("snow_rock_%02d" % i, snow_rock, snow, ground(x, z), random.uniform(0, 6.28),
                    random.uniform(0.6, 1.4), ge_surface="snow")
    mesh_object("cabin", cabin, snow, ground(640, 300), 0.4, 1.0, ge_surface="wood")
    mesh_object("ice_lake", dune, snow, ground(600, 150), 0.0, 1.0, ge_surface="ice")
    for i in range(4):  # dynamic props next to the cabin
        mesh_object("crate_%d" % i, crate, snow, (650 + i * 1.5, -310, 0.5), 0.0, 1.0,
                    ge_physics="dynamic", ge_mass=20.0, ge_surface="wood")

    # Main road: Bezier from the forest (west) to the snow (east), through the middle cells.
    curve = bpy.data.curves.new("main_road", "CURVE")
    curve.dimensions = "3D"
    sp = curve.splines.new("BEZIER")
    road_pts = [(5, -380, 0.1), (250, -340, 0.6), (520, -420, 1.2), (760, -380, 0.4)]
    sp.bezier_points.add(len(road_pts) - 1)
    for bp, co in zip(sp.bezier_points, road_pts):
        bp.co = co
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    road = bpy.data.objects.new("main_road", curve)
    road["ge_role"] = "road"
    road["ge_width"] = 9.0
    road["ge_lanes"] = 2
    road["ge_speed_limit"] = 22.2
    roads.objects.link(road)

    # Traffic loop around the desert town (closed Bezier).
    loop_curve = bpy.data.curves.new("desert_loop", "CURVE")
    loop_curve.dimensions = "3D"
    lp = loop_curve.splines.new("BEZIER")
    loop_pts = [(300, -600, 0.1), (420, -600, 0.1), (420, -700, 0.1), (300, -700, 0.1)]
    lp.bezier_points.add(len(loop_pts) - 1)
    for bp, co in zip(lp.bezier_points, loop_pts):
        bp.co = co
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    lp.use_cyclic_u = True
    loop = bpy.data.objects.new("desert_loop", loop_curve)
    loop["ge_role"] = "traffic"
    loop["ge_width"] = 6.0
    loop["ge_lanes"] = 1
    loop["ge_speed_limit"] = 8.3
    roads.objects.link(loop)

    # River: poly line (exported as Catmull-Rom).
    river_curve = bpy.data.curves.new("forest_river", "CURVE")
    river_curve.dimensions = "3D"
    rp = river_curve.splines.new("POLY")
    river_pts = [(120, -20, -0.5), (160, -120, -0.5), (140, -220, -0.6), (200, -300, -0.7), (180, -360, -0.8)]
    rp.points.add(len(river_pts) - 1)
    for p, co in zip(rp.points, river_pts):
        p.co = (co[0], co[1], co[2], 1.0)
    river = bpy.data.objects.new("forest_river", river_curve)
    river["ge_role"] = "river"
    river["ge_width"] = 14.0
    river["ge_lanes"] = 0
    roads.objects.link(river)

    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("Sun", sun_data)
    sun.rotation_euler = (math.radians(50), 0, math.radians(30))
    env.objects.link(sun)
    lamp_data = bpy.data.lights.new("CabinLamp", "POINT")
    lamp_data.energy = 800.0
    lamp = bpy.data.objects.new("cabin_lamp", lamp_data)
    lamp.location = (640, -300, 5.0)
    snow.objects.link(lamp)
    bpy.context.view_layer.update()


def _parse_args(argv):
    args = {}
    for a in argv:
        if not a.startswith("--"):
            raise SystemExit("unexpected argument %r" % a)
        k, _, v = a[2:].partition("=")
        args[k] = v if _ else True
    return args


def main(argv):
    args = _parse_args(argv)
    project_root = args.get("project-root", os.getcwd())
    out_dir = args.get("out", "assets/world")
    cell = float(args.get("cell-size", 256))
    load_r = float(args["load-radius"]) if "load-radius" in args else None
    unload_r = float(args["unload-radius"]) if "unload-radius" in args else None

    if "from-json" in args:
        with open(args["from-json"], encoding="utf-8") as f:
            desc = json.load(f)
        if "name" in args:
            desc["name"] = args["name"]
    else:
        bpy = _bpy()
        if args.get("build-test-level"):
            build_test_level()
            default_name = "ow8_test_level"
        else:
            blend = bpy.data.filepath
            default_name = os.path.splitext(os.path.basename(blend))[0] if blend else "world"
        name = args.get("name", default_name)
        desc = gather_blender_scene(name, project_root, out_dir, args.get("collection"))
        if "dump-json" in args:
            write_json(args["dump-json"], desc)
    report = export_world(desc, project_root, out_dir, cell, load_r, unload_r)
    return 0 if report else 1


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else sys.argv[1:]
    try:
        code = main(argv)
    except Exception as exc:  # noqa: BLE001 — report and fail the Blender batch run
        import traceback
        traceback.print_exc()
        print("blender_export_scene: error: %s" % exc, file=sys.stderr)
        code = 1
    sys.exit(code)
