// GPU culling, LOD selection and compaction for one StaticInstanceBuffer and
// one view (engine.gpu.static_cull). Mirrors collectVisibleRuns on the CPU.
//   cs_cull     one workgroup per 64-instance block: visibility + LOD
//   cs_sum      one invocation per group: block offsets and indirect records
//   cs_scatter  one workgroup per block: copy visible instances, in order
// The output order is the input order, so coplanar surfaces never flicker.

const LOD_CULLED: u32 = 255u;
const FLAG_DISTANCE: u32 = 1u;
const FLAG_RECEIVER: u32 = 2u;
const FLAG_SHADOW: u32 = 4u;

struct CullView {
    planes: array<vec4<f32>, 6>,
    slicePlanes: array<vec4<f32>, 6>,
    // xyz = surface to light, w = receiver drop
    sweep: vec4<f32>,
    // xyz = camera position, w = LOD bias
    camera: vec4<f32>,
    // x = pixels covered by one world unit at distance 1
    params: vec4<f32>,
    flags: vec4<u32>,
}

struct Block { group: u32, first: u32, count: u32, pad: u32 }

// Culling volume of one instance: box, sphere radius and largest axis scale.
struct Meta { center: vec3<f32>, scale: f32, extents: vec3<f32>, radius: f32 }

struct Group {
    first: u32, count: u32, firstBlock: u32, blockCount: u32,
    firstArg: u32, lodLevels: u32, baseVertex: u32, pad: u32,
    maxDistance: f32, minPixels: f32, meshScale: f32, displacement: f32,
    errors: array<vec4<f32>, 2>,
    // (first index, index count) per LOD
    color: array<vec2<u32>, 8>,
    shadow: array<vec2<u32>, 8>,
}

struct Instance { m: array<vec4<f32>, 6> }

@group(0) @binding(0) var<uniform> view: CullView;
@group(1) @binding(0) var<storage, read> blocks: array<Block>;
@group(1) @binding(1) var<storage, read> metas: array<Meta>;
@group(1) @binding(2) var<storage, read> groups: array<Group>;
@group(1) @binding(3) var<storage, read_write> lods: array<u32>;
// Per block and LOD: instance count (cs_cull), then output offset (cs_sum).
@group(1) @binding(4) var<storage, read_write> blockLods: array<u32>;
// Indexed indirect records, 5 words each.
@group(1) @binding(5) var<storage, read_write> args: array<u32>;
@group(1) @binding(6) var<storage, read> instances: array<Instance>;
@group(1) @binding(7) var<storage, read_write> visible: array<Instance>;

fn boxOutside(plane: vec4<f32>, bmin: vec3<f32>, bmax: vec3<f32>) -> bool {
    let p = select(bmin, bmax, plane.xyz >= vec3<f32>(0.0));
    return dot(plane.xyz, p) + plane.w < 0.0;
}

fn pixels(size: f32, d: f32) -> f32 {
    return size * view.params.x / max(d, 1e-4);
}

fn classify(g: u32, m: Meta) -> u32 {
    let extents = m.extents + vec3<f32>(groups[g].displacement);
    let bmin = m.center - extents;
    let bmax = m.center + extents;
    for (var i = 0u; i < 6u; i++) {
        if (boxOutside(view.planes[i], bmin, bmax)) { return LOD_CULLED; }
    }
    if ((view.flags.x & FLAG_RECEIVER) != 0u) {
        let len = ((bmax.y - bmin.y) + view.sweep.w) / max(view.sweep.y, 0.05);
        let d = -view.sweep.xyz * len;
        let smin = min(bmin, bmin + d);
        let smax = max(bmax, bmax + d);
        for (var i = 0u; i < 6u; i++) {
            if (boxOutside(view.slicePlanes[i], smin, smax)) { return LOD_CULLED; }
        }
    }
    let d = length(max(abs(view.camera.xyz - m.center) - m.extents, vec3<f32>(0.0)));
    if ((view.flags.x & FLAG_DISTANCE) != 0u) {
        let maxDistance = groups[g].maxDistance;
        if (maxDistance > 0.0 && d > maxDistance) { return LOD_CULLED; }
        let minPixels = groups[g].minPixels;
        if (minPixels > 0.0 && d > m.radius && pixels(2.0 * m.radius, d) < minPixels) { return LOD_CULLED; }
    }
    var lod = 0u;
    let levels = groups[g].lodLevels;
    for (var i = 1u; i < levels; i++) {
        let e = groups[g].errors[i / 4u][i % 4u];
        if (pixels(e * groups[g].meshScale * m.scale, d) * view.camera.w <= 1.0) { lod = i; }
    }
    return lod;
}

var<workgroup> counts: array<atomic<u32>, 8>;

@compute @workgroup_size(64)
fn cs_cull(@builtin(workgroup_id) wid: vec3<u32>, @builtin(local_invocation_index) li: u32) {
    // wgpu-native does not zero workgroup memory here: clear it explicitly.
    if (li < 8u) { atomicStore(&counts[li], 0u); }
    workgroupBarrier();
    let b = blocks[wid.x];
    if (li < b.count) {
        let lod = classify(b.group, metas[b.first + li]);
        lods[b.first + li] = lod;
        if (lod != LOD_CULLED) { atomicAdd(&counts[lod], 1u); }
    }
    workgroupBarrier();
    if (li < 8u) { blockLods[wid.x * 8u + li] = atomicLoad(&counts[li]); }
}

@compute @workgroup_size(64)
fn cs_sum(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= arrayLength(&groups)) { return; }
    let g = gid.x;
    var next = groups[g].first;
    let levels = max(groups[g].lodLevels, 1u);
    let shadow = (view.flags.x & FLAG_SHADOW) != 0u;
    for (var lod = 0u; lod < levels; lod++) {
        let start = next;
        for (var i = 0u; i < groups[g].blockCount; i++) {
            let slot = (groups[g].firstBlock + i) * 8u + lod;
            let n = blockLods[slot];
            blockLods[slot] = next;
            next += n;
        }
        let range = select(groups[g].color[lod], groups[g].shadow[lod], shadow);
        let a = (groups[g].firstArg + lod) * 5u;
        args[a] = range.y;
        args[a + 1u] = next - start;
        args[a + 2u] = range.x;
        args[a + 3u] = groups[g].baseVertex;
        args[a + 4u] = start;
    }
}

var<workgroup> lane: array<u32, 64>;

@compute @workgroup_size(64)
fn cs_scatter(@builtin(workgroup_id) wid: vec3<u32>, @builtin(local_invocation_index) li: u32) {
    let b = blocks[wid.x];
    var lod = LOD_CULLED;
    if (li < b.count) { lod = lods[b.first + li]; }
    lane[li] = lod;
    workgroupBarrier();
    if (lod == LOD_CULLED) { return; }
    var rank = 0u;
    for (var i = 0u; i < li; i++) {
        if (lane[i] == lod) { rank++; }
    }
    visible[blockLods[wid.x * 8u + lod] + rank] = instances[b.first + li];
}
