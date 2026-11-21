"""Unit tests for the pure backend of tools/blender_export_scene.py (no Blender).

Run: python3 -m unittest tools/test_blender_export_scene.py
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import blender_export_scene as bx  # noqa: E402


class ExportWorldTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, "assets/w/t/meshes"))
        with open(os.path.join(self.root, "assets/w/t/meshes/rock.glb"), "wb") as f:
            f.write(b"glTF")

    def tearDown(self):
        shutil.rmtree(self.root)

    def read(self, rel):
        with open(os.path.join(self.root, rel), encoding="utf-8") as f:
            return json.load(f)

    def desc(self, **extra):
        d = {
            "name": "t",
            "meshes": {"rock": {"glb": "assets/w/t/meshes/rock.glb", "halfExtents": [1, 1, 1],
                                "hullPoints": [[-1, -1, -1], [1, 1, 1], [1, -1, 1]]}},
            "objects": [
                {"name": "sun", "position": [0, 50, 0], "light": {"type": "directional", "intensity": 3}},
                {"name": "a", "position": [10, 0, 10], "mesh": "rock", "surface": "ice"},
                {"name": "b", "position": [300, 2, 20], "mesh": "rock", "physics": "dynamic",
                 "shape": "triangleMesh", "mass": 5},
                {"name": "c", "position": [-5, 0, 600], "mesh": "rock", "global": True},
            ],
            "splines": [{"name": "road", "kind": "catmullRom", "width": 7,
                         "points": [[0, 0, 0], [100, 0, 0], [200, 0, 50]]}],
        }
        d.update(extra)
        return d

    def test_chunks_root_and_splines(self):
        r = bx.export_world(self.desc(), self.root, "assets/w", 256, log=lambda m: None)
        self.assertEqual([c["coord"] for c in r["chunks"]], [[0, 0], [1, 0]])
        root = self.read("assets/w/t.scene.json")
        self.assertEqual(root["version"], 2)
        self.assertEqual(root["chunks"]["loadRadius"], 384)
        self.assertEqual(len(root["entities"]), 2)  # sun + global rock
        self.assertEqual([l["kind"] for l in root["assetLinks"]], ["model", "splines"])
        chunk = self.read("assets/w/t/chunks/chunk_1_0.scene.json")
        ent = chunk["entities"][0]
        self.assertEqual(ent["physics"]["shape"], "convexHull")  # dynamic mesh coerced
        self.assertEqual(ent["physics"]["mass"], 5)
        self.assertEqual(chunk["cellBounds"]["min"][0], 256)
        self.assertEqual(len(r["warnings"]), 1)
        c0 = self.read("assets/w/t/chunks/chunk_0_0.scene.json")
        self.assertEqual(c0["entities"][0]["physics"]["friction"], bx.SURFACES["ice"][0])
        splines = self.read("assets/w/t/t.splines.json")
        self.assertEqual(splines["splines"][0]["width"], 7)
        asset = self.read("assets/w/t/meshes/rock.asset.json")
        self.assertEqual(asset["render"]["source"], "assets/w/t/meshes/rock.glb")
        self.assertEqual(len(asset["collision"]["convexHull"]["points"]), 3)

    def test_guids_are_stable_across_reexports(self):
        bx.export_world(self.desc(), self.root, "assets/w", 256, log=lambda m: None)
        g1 = self.read("assets/w/t/meshes/rock.asset.json.meta")["guid"]
        bx.export_world(self.desc(), self.root, "assets/w", 256, log=lambda m: None)
        self.assertEqual(self.read("assets/w/t/meshes/rock.asset.json.meta")["guid"], g1)
        self.assertEqual(g1, bx.guid_for("assets/w/t/meshes/rock.asset.json"))

    def test_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            bx.export_world(self.desc(objects=[{"name": "x", "position": [0, 0, 0], "mesh": "rock",
                                                 "surface": "lava"}]), self.root, "assets/w", 256,
                            log=lambda m: None)
        with self.assertRaises(ValueError):
            bx.export_world(self.desc(), self.root, "assets/w", 256, load_radius=500, unload_radius=100,
                            log=lambda m: None)
        bad = self.desc(splines=[{"name": "b", "kind": "bezier", "points": [[0, 0, 0], [1, 0, 0]]}])
        r = bx.export_world(bad, self.root, "assets/w", 256, log=lambda m: None)
        self.assertEqual(r["splines"], 0)

    def test_axis_conversion(self):
        self.assertEqual(bx.blender_to_engine_vec((1, 2, 3)), [1, 3, -2])
        self.assertEqual(bx.blender_to_engine_scale((1, 2, 3)), [1, 3, 2])
        # 90° about Blender Z (up) is 90° about engine Y.
        import math
        s = math.sin(math.pi / 4)
        q = bx.blender_to_engine_quat((s, 0, 0, s))
        self.assertAlmostEqual(q[1], s)
        self.assertAlmostEqual(q[3], s)
        self.assertEqual(bx.cell_of([-1, 0, 257], 256), (-1, 1))


if __name__ == "__main__":
    unittest.main()
