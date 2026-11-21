/// Terrain depth-only pass for directional shadow views (cascades). Group 0
/// is the scene's per-view light VP (dynamic offset), group 1 the terrain
/// params + heightmap.

#include "common/terrain_common.wgsl"

struct LightUniforms {
    lightViewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> light: LightUniforms;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, @location(0) inst: vec4<f32>) -> @builtin(position) vec4<f32> {
    let v = terrainVertex(vi, inst);
    return light.lightViewProj * vec4<f32>(v.worldPos, 1.0);
}
