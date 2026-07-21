# PBR sample assets

- `pbr_cube.gltf` + `pbr_cube.bin` — unit cube with POSITION/NORMAL/TEXCOORD_0
- `pbr_cube_albedo.bmp` — checker base color
- `pbr_cube_mr.bmp` — metallic-roughness (G≈0.3 roughness, B≈0.9 metallic)

Load with `loadGltfPbr(gpu, "assets/models/pbr_cube.gltf", layout, sampler)`.
