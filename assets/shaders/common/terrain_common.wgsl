/// Shared terrain vertex logic (`engine.terrain.renderer`). The grid template
/// has no vertex buffer: `vertex_index < G` is a grid point of the chunk,
/// `G + i` the same point lowered as a skirt. Vertices geomorph toward the
/// next LOD near the end of their LOD band (collapsing odd vertices onto
/// their lower even neighbor reproduces the coarse mesh exactly).

struct TerrainParams {
    /// xyz = world position of sample (0,0), w = cell size.
    origin: vec4<f32>,
    /// samplesX, samplesZ, chunkCells, skirt depth.
    grid: vec4<f32>,
    /// lod0 distance, morph fraction, lod count, hysteresis.
    lod: vec4<f32>,
    /// xyz = camera position for geomorphing (shared by shadow views).
    camera: vec4<f32>,
    uvScale0: vec4<f32>,
    uvScale1: vec4<f32>,
    heightBlend0: vec4<f32>,
    heightBlend1: vec4<f32>,
    triplanar0: vec4<f32>,
    triplanar1: vec4<f32>,
    /// layer count, blend depth, far detile scale, normal strength.
    misc: vec4<f32>,
    /// Hex-tiling largest rotation per layer (fraction of half a turn); negative = off.
    hexRotation0: vec4<f32>,
    hexRotation1: vec4<f32>,
    /// Macro variation: brightness amount, roughness amount, frequency (1/m), saturation amount.
    macroVar: vec4<f32>,
};

@group(1) @binding(0) var<uniform> tp: TerrainParams;
@group(1) @binding(2) var heightTex: texture_2d<f32>;

fn terrainHeight(sx: i32, sz: i32) -> f32 {
    let mx = i32(tp.grid.x) - 1;
    let mz = i32(tp.grid.y) - 1;
    return textureLoad(heightTex, vec2<i32>(clamp(sx, 0, mx), clamp(sz, 0, mz)), 0).r;
}

struct TerrainVertex {
    worldPos: vec3<f32>,
    /// Surface position (skirts keep the unlowered point for shading, so
    /// T-junction slivers do not sample shadows from below the ground).
    shadePos: vec3<f32>,
    /// Continuous sample-space coordinates (for normal / splat lookups).
    samplePos: vec2<f32>,
};

fn terrainVertex(vi: u32, inst: vec4<f32>) -> TerrainVertex {
    let cells = u32(tp.grid.z);
    let V = cells + 1u;
    let G = V * V;
    let skirt = vi >= G;
    let li = vi % G;
    let g = vec2<f32>(f32(li % V), f32(li / V));
    let lod = u32(inst.z);
    let s = f32(1u << lod);
    let cell = tp.origin.w;

    let base = inst.xy;
    var sp = base + g;
    var h = terrainHeight(i32(sp.x), i32(sp.y));

    let lodCount = u32(tp.lod.z);
    if (lod + 1u < lodCount) {
        let world0 = tp.origin.xyz + vec3<f32>(sp.x * cell, 0.0, sp.y * cell);
        let dist = distance(tp.camera.xyz, vec3<f32>(world0.x, h, world0.z));
        // Finish morphing before the hysteresis margin so a neighbor that is
        // already coarser always meets fully morphed border vertices.
        let bandEnd = tp.lod.x * s * (1.0 - tp.lod.w);
        let bandStart = bandEnd * (1.0 - tp.lod.y);
        let k = clamp((dist - bandStart) / max(bandEnd - bandStart, 1e-3), 0.0, 1.0);
        if (k > 0.0) {
            let s2 = 2.0 * s;
            let snapped = base + g - (g - floor(g / s2) * s2);
            let hc = terrainHeight(i32(snapped.x), i32(snapped.y));
            sp = mix(sp, snapped, k);
            h = mix(h, hc, k);
        }
    }
    var out: TerrainVertex;
    out.shadePos = tp.origin.xyz + vec3<f32>(sp.x * cell, 0.0, sp.y * cell);
    out.shadePos.y = h;
    out.worldPos = out.shadePos;
    if (skirt) {
        out.worldPos.y = h - tp.grid.w * s;
    }
    out.samplePos = sp;
    return out;
}
