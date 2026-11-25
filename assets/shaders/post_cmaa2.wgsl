// Conservative Morphological Anti-Aliasing 2 (Filip Strugar, Intel, 2018).
// WGSL port of CMAA2.hlsl v2.3 (https://github.com/GameTechDev/CMAA2),
// Apache License 2.0, see docs/third-party-licenses.md. Changes: single sample
// only, LDR display-encoded input, edges packed per 2x2 quad in one r32uint
// texel, list heads in a storage buffer, bounds checks on every list. Colors
// are blended in an approximately linear space (square of the display value).

struct Params {
    size: vec2<u32>,
    threshold: f32,
    unused: f32,
};
struct Control {
    candidates: atomic<u32>,
    locations: atomic<u32>,
    items: atomic<u32>,
    // Element count of the pass that runs next.
    count: atomic<u32>,
};
@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var srcTex: texture_2d<f32>;
@group(0) @binding(2) var edgesOut: texture_storage_2d<r32uint, write>;
@group(0) @binding(3) var edgesIn: texture_2d<u32>;
@group(0) @binding(4) var<storage, read_write> candidates: array<u32>;
@group(0) @binding(5) var<storage, read_write> locations: array<u32>;
@group(0) @binding(6) var<storage, read_write> items: array<vec2<u32>>;
@group(0) @binding(7) var<storage, read_write> heads: array<atomic<u32>>;
@group(0) @binding(8) var<storage, read_write> control: Control;
@group(0) @binding(9) var<storage, read_write> args: array<u32>;
@group(0) @binding(10) var dstTex: texture_storage_2d<rgba8unorm, write>;

const EMPTY: u32 = 0xFFFFFFFFu;
const CONTRAST: f32 = 0.10;  // local contrast adaptation
const BLURINESS: f32 = 0.10; // simple shapes
const MAX_LINE: f32 = 86.0;
const SYMMETRY: f32 = 0.22;
const DAMPENING: f32 = 0.15;
const KERNEL: u32 = 16u;
const ITEM_SLM: u32 = 768u;

fn loadEncoded(q: vec2<i32>) -> vec3<f32> {
    return textureLoad(srcTex, clamp(q, vec2<i32>(0), vec2<i32>(p.size) - 1), 0).rgb;
}

fn loadColor(q: vec2<i32>) -> vec3<f32> {
    let c = loadEncoded(q);
    return c * c;
}

fn quadIndex(quad: vec2<u32>) -> u32 { return quad.y * ((p.size.x + 1u) / 2u) + quad.x; }

// --- Edge detection, one invocation per 2x2 quad -------------------------

var<workgroup> slmH: array<vec4<f32>, 256>;
var<workgroup> slmV: array<vec4<f32>, 256>;

// (vertical edge right of the pixel, horizontal edge below it) per neighbor
// of the quad; index [x + 1][y + 1] with x, y in -1..2.
var<private> nb: array<array<vec2<f32>, 4>, 4>;

fn contrastV(x: i32, y: i32) -> f32 {
    return max(max(nb[x + 1][y].y, nb[x + 1][y + 1].y), max(nb[x + 2][y].y, nb[x + 2][y + 1].y)) * CONTRAST;
}

fn contrastH(x: i32, y: i32) -> f32 {
    return max(max(nb[x][y + 1].x, nb[x + 1][y + 1].x), max(nb[x][y + 2].x, nb[x + 1][y + 2].x)) * CONTRAST;
}

fn slmEdge(addr: u32, i: u32) -> vec2<f32> { return vec2<f32>(slmV[addr][i], slmH[addr][i]); }

fn over(v: f32, contrast: f32) -> f32 { return select(0.0, 1.0, v - contrast > p.threshold); }

@compute @workgroup_size(16, 16, 1)
fn cs_edges(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_id) local: vec3<u32>) {
    let quad = vec2<i32>(group.xy * 14u + local.xy) - 1;
    let px = quad * 2;
    let addr = local.x + local.y * KERNEL;
    let w = vec3<f32>(0.299, 0.587, 0.114);
    let l00 = dot(loadEncoded(px), w);
    let l10 = dot(loadEncoded(px + vec2<i32>(1, 0)), w);
    let l20 = dot(loadEncoded(px + vec2<i32>(2, 0)), w);
    let l01 = dot(loadEncoded(px + vec2<i32>(0, 1)), w);
    let l11 = dot(loadEncoded(px + vec2<i32>(1, 1)), w);
    let l21 = dot(loadEncoded(px + vec2<i32>(2, 1)), w);
    let l02 = dot(loadEncoded(px + vec2<i32>(0, 2)), w);
    let l12 = dot(loadEncoded(px + vec2<i32>(1, 2)), w);
    let V = vec4<f32>(abs(l00 - l10), abs(l10 - l20), abs(l01 - l11), abs(l11 - l21));
    let H = vec4<f32>(abs(l00 - l01), abs(l10 - l11), abs(l01 - l02), abs(l11 - l12));
    slmV[addr] = V;
    slmH[addr] = H;
    workgroupBarrier();
    if (local.x == 0u || local.y == 0u || local.x == KERNEL - 1u || local.y == KERNEL - 1u) { return; }
    let size = vec2<i32>(p.size);
    if (any(px >= size)) { return; }
    var packed = 0u;
    let top = slmH[addr - KERNEL].zw;
    let left = slmV[addr - 1u].yw;
    if (any(V + H > vec4<f32>(0.0)) || any(top + left > vec2<f32>(0.0))) {
        atomicStore(&heads[quadIndex(vec2<u32>(quad))], EMPTY);
        let up = addr - KERNEL;
        let down = addr + KERNEL;
        nb[0][0] = slmEdge(up - 1u, 3u);
        nb[1][0] = slmEdge(up, 2u);
        nb[2][0] = slmEdge(up, 3u);
        nb[3][0] = slmEdge(up + 1u, 2u);
        nb[0][1] = slmEdge(addr - 1u, 1u);
        nb[0][2] = slmEdge(addr - 1u, 3u);
        nb[3][1] = slmEdge(addr + 1u, 0u);
        nb[3][2] = slmEdge(addr + 1u, 2u);
        nb[0][3] = slmEdge(down - 1u, 1u);
        nb[1][3] = slmEdge(down, 0u);
        nb[2][3] = slmEdge(down, 1u);
        for (var i = 0u; i < 4u; i++) { nb[1u + (i & 1u)][1u + (i >> 1u)] = vec2<f32>(V[i], H[i]); }
        let t = vec2<f32>(over(top.x, contrastH(0, -1)), over(top.y, contrastH(1, -1)));
        let lf = vec2<f32>(over(left.x, contrastV(-1, 0)), over(left.y, contrastV(-1, 1)));
        // right, bottom, left, top
        var ce: array<vec4<f32>, 4>;
        for (var i = 0; i < 4; i++) {
            let x = i & 1;
            let y = i >> 1;
            ce[i].x = over(V[i], contrastV(x, y));
            ce[i].y = over(H[i], contrastH(x, y));
        }
        ce[0].z = lf.x;
        ce[1].z = ce[0].x;
        ce[2].z = lf.y;
        ce[3].z = ce[2].x;
        ce[0].w = t.x;
        ce[1].w = t.y;
        ce[2].w = ce[0].y;
        ce[3].w = ce[1].y;
        for (var i = 0u; i < 4u; i++) {
            let e = ce[i];
            let q = vec2<u32>(px) + vec2<u32>(i & 1u, i >> 1u);
            if (any(q >= p.size)) { continue; }
            if (e.x * e.y + e.y * e.z + e.z * e.w + e.w * e.x != 0.0) {
                let k = atomicAdd(&control.candidates, 1u);
                if (k < arrayLength(&candidates)) { candidates[k] = (q.x << 18u) | q.y; }
            }
            packed |= u32(dot(e, vec4<f32>(1.0, 2.0, 4.0, 8.0))) << (i * 4u);
        }
    }
    textureStore(edgesOut, quad, vec4<u32>(packed, 0u, 0u, 0u));
}

// --- Indirect arguments ---------------------------------------------------

@compute @workgroup_size(1)
fn cs_args_process() {
    let n = min(atomicLoad(&control.candidates), arrayLength(&candidates));
    args[0] = (n + 127u) / 128u;
    args[1] = 1u;
    args[2] = 1u;
    atomicStore(&control.count, n);
}

@compute @workgroup_size(1)
fn cs_args_apply() {
    let n = min(atomicLoad(&control.locations), arrayLength(&locations));
    args[0] = 1u;
    args[1] = (n + 31u) / 32u;
    args[2] = 1u;
    atomicStore(&control.count, n);
    atomicStore(&control.candidates, 0u);
    atomicStore(&control.locations, 0u);
    atomicStore(&control.items, 0u);
}

// --- Shapes ---------------------------------------------------------------

fn edgeBits(q: vec2<i32>) -> u32 {
    if (any(q < vec2<i32>(0)) || any(q >= vec2<i32>(p.size))) { return 0u; }
    let shift = u32((q.y & 1) * 2 + (q.x & 1)) * 4u;
    return (textureLoad(edgesIn, q / 2, 0).r >> shift) & 15u;
}

fn edgeFlags(q: vec2<i32>) -> vec4<f32> {
    let b = edgeBits(q);
    return vec4<f32>(f32(b & 1u), f32((b >> 1u) & 1u), f32((b >> 2u) & 1u), f32((b >> 3u) & 1u));
}

// Stored display-encoded with 11/11/10 bits.
fn packColor(linear: vec3<f32>) -> u32 {
    let c = sqrt(clamp(linear, vec3<f32>(0.0), vec3<f32>(1.0)));
    let v = vec3<u32>(c * vec3<f32>(2047.0, 2047.0, 1023.0) + 0.5);
    return v.x | (v.y << 11u) | (v.z << 22u);
}

fn unpackColor(v: u32) -> vec3<f32> {
    let c = vec3<f32>(f32(v & 2047u), f32((v >> 11u) & 2047u), f32(v >> 22u)) / vec3<f32>(2047.0, 2047.0, 1023.0);
    return c * c;
}

fn storeSample(q: vec2<i32>, color: vec3<f32>, complexShape: bool) {
    if (any(q < vec2<i32>(0)) || any(q >= vec2<i32>(p.size))) { return; }
    let k = atomicAdd(&control.items, 1u);
    if (k >= arrayLength(&items)) { return; }
    let quad = vec2<u32>(q) / 2u;
    let offset = u32((q.y & 1) * 2 + (q.x & 1));
    let header = (offset << 30u) | select(0u, 1u << 26u, complexShape);
    let previous = atomicExchange(&heads[quadIndex(quad)], k | header);
    items[k] = vec2<u32>(previous, packColor(color));
    if (previous == EMPTY) {
        let l = atomicAdd(&control.locations, 1u);
        if (l < arrayLength(&locations)) { locations[l] = (quad.x << 16u) | quad.y; }
    }
}

fn simpleShape(e: vec4<f32>, l: vec4<f32>, r: vec4<f32>, t: vec4<f32>, b: vec4<f32>) -> vec4<f32> {
    var fromRight = e.x;
    var fromBelow = e.y;
    var fromLeft = e.z;
    var fromAbove = e.w;
    var blur = BLURINESS;
    let count = dot(e, vec4<f32>(1.0));
    let around = dot(l.zyw + r.xyw + t.xzw + b.xyz, vec3<f32>(1.0));
    if (count == 2.0) {
        blur *= 0.75;
        let k = 0.9;
        fromRight += k * (e.y * t.x * (1.0 - l.y) + e.w * b.x * (1.0 - l.w));
        fromBelow += k * (e.z * r.y * (1.0 - t.z) + e.x * l.y * (1.0 - t.x));
        fromLeft += k * (e.w * b.z * (1.0 - r.w) + e.y * t.z * (1.0 - r.y));
        fromAbove += k * (e.x * l.w * (1.0 - b.x) + e.z * r.w * (1.0 - b.z));
    }
    blur *= clamp(1.30 - around / 10.0, 0.0, 1.0);
    return vec4<f32>(fromLeft, fromAbove, fromRight, fromBelow) * blur;
}

// x = inverted Z score, y = Z score
fn detectZ(e: vec4<f32>, m1: vec4<f32>, p1: vec4<f32>, p2: vec4<f32>) -> vec2<f32> {
    var inv = e.x * e.y * p1.w;
    inv *= 2.0 + (m1.y + p2.w) - (e.w + p1.y) - 0.7 * (p2.y + m1.w + e.z + p1.x);
    var nor = e.x * e.w * p1.y;
    nor *= 2.0 + (m1.w + p2.y) - (e.y + p1.w) - 0.7 * (p2.w + m1.y + e.z + p1.x);
    return vec2<f32>(inv, nor);
}

fn lineLengths(q: vec2<i32>, horizontal: bool, inverted: bool, stepRight: vec2<i32>) -> vec2<f32> {
    var left = select(4u, 8u, horizontal);
    var right = select(1u, 2u, horizontal);
    if (inverted) {
        let t = left;
        left = right;
        right = t;
    }
    var goLeft = true;
    var goRight = true;
    var lenL = 1.0;
    var lenR = 1.0;
    loop {
        let eL = edgeBits(q - stepRight * i32(lenL));
        let eR = edgeBits(q + stepRight * (i32(lenR) + 1));
        goLeft = goLeft && (eL & left) == left;
        goRight = goRight && (eR & right) == right;
        lenL += select(0.0, 1.0, goLeft);
        lenR += select(0.0, 1.0, goRight);
        var longest = max(lenL, lenR);
        if (!goLeft && !goRight) { longest = MAX_LINE; }
        if (longest >= min(MAX_LINE, 1.25 * min(lenL, lenR) - 0.25)) { break; }
    }
    return vec2<f32>(lenL, lenR);
}

var<workgroup> slmCount: atomic<u32>;
var<workgroup> slmItems: array<vec2<u32>, ITEM_SLM>;

fn blendItem(q: vec2<i32>, horizontal: bool, inverted: bool, i: i32, src: i32, k: f32) {
    let stepRight = select(vec2<i32>(0, -1), vec2<i32>(1, 0), horizontal);
    var dir = select(vec2<i32>(-1, 0), vec2<i32>(0, -1), horizontal);
    if (inverted) { dir = -dir; }
    let at = q + stepRight * i;
    storeSample(at, mix(loadColor(at), loadColor(at + dir * src), k), true);
}

fn blendZ(q: vec2<i32>, horizontal: bool, inverted: bool, quality: f32, lenL: f32, lenR: f32) {
    let leftOdd = SYMMETRY * (lenL % 2.0);
    let rightOdd = SYMMETRY * (lenR % 2.0);
    let dampen = clamp((lenL + lenR - quality) * DAMPENING, 0.0, 1.0);
    let from0 = -floor((lenL + 1.0) / 2.0) + 1.0;
    let to0 = floor((lenR + 1.0) / 2.0);
    let count = u32(to0 - from0 + 1.0);
    let slot = atomicAdd(&slmCount, count);
    let shared_ = slot + count <= ITEM_SLM;
    let lerpStep = 1.0 / (to0 - from0 + 1.0 - leftOdd - rightOdd);
    let lerpFrom = (0.5 - leftOdd - from0) * lerpStep;
    for (var n = 0u; n < count; n++) {
        let i = from0 + f32(n);
        let second = select(0.0, 1.0, i > 0.0);
        let src = 1.0 - second * 2.0;
        let k = clamp(((lerpStep * i + lerpFrom) * src + second) * dampen, 0.0, 1.0);
        if (shared_) {
            slmItems[slot + n] = vec2<u32>(
                (u32(q.x) << 18u) | u32(q.y),
                select(0u, 1u << 31u, horizontal) | select(0u, 1u << 30u, inverted)
                    | (u32(i32(i) + 256) << 20u) | (u32(i32(src) + 256) << 10u) | u32(k * 1023.0 + 0.5));
        } else {
            blendItem(q, horizontal, inverted, i32(i), i32(src), k);
        }
    }
}

fn processCandidate(id: u32) {
    let q = vec2<i32>(vec2<u32>(id >> 18u, id & 0x3FFFu));
    let e = edgeFlags(q);
    let l = edgeFlags(q + vec2<i32>(-1, 0));
    let r = edgeFlags(q + vec2<i32>(1, 0));
    let b = edgeFlags(q + vec2<i32>(0, 1));
    let t = edgeFlags(q + vec2<i32>(0, -1));
    let v = simpleShape(e, l, r, t, b);
    var color = loadColor(q) * (1.0 - dot(v, vec4<f32>(1.0)));
    if (v.x > 0.0) { color += v.x * loadColor(q + vec2<i32>(-1, 0)); }
    if (v.y > 0.0) { color += v.y * loadColor(q + vec2<i32>(0, -1)); }
    if (v.z > 0.0) { color += v.z * loadColor(q + vec2<i32>(1, 0)); }
    if (v.w > 0.0) { color += v.w * loadColor(q + vec2<i32>(0, 1)); }
    storeSample(q, color, false);

    var horizontal = true;
    let h = detectZ(e, l, r, edgeFlags(q + vec2<i32>(2, 0)));
    var score = max(h.x, h.y);
    var inverted = h.x > h.y;
    let top2 = edgeFlags(q + vec2<i32>(0, -2));
    let vs = detectZ(e.wxyz, b.wxyz, t.wxyz, top2.wxyz);
    if (max(vs.x, vs.y) > score) {
        score = max(vs.x, vs.y);
        horizontal = false;
        inverted = vs.x > vs.y;
    }
    if (score <= 0.0) { return; }
    let quality = floor(clamp(4.0 - score, 0.0, 3.0));
    let stepRight = select(vec2<i32>(0, -1), vec2<i32>(1, 0), horizontal);
    let len = lineLengths(q, horizontal, inverted, stepRight) - quality;
    if (len.x + len.y >= 5.0) { blendZ(q, horizontal, inverted, quality, len.x, len.y); }
}

// 128 invocations; some devices cap one dimension at 64.
@compute @workgroup_size(64, 2)
fn cs_process(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_index) local: u32) {
    if (local == 0u) { atomicStore(&slmCount, 0u); }
    workgroupBarrier();
    let index = group.x * 128u + local;
    if (index < atomicLoad(&control.count)) { processCandidate(candidates[index]); }
    workgroupBarrier();
    let total = min(ITEM_SLM, atomicLoad(&slmCount));
    for (var i = local; i < total; i += 128u) {
        let it = slmItems[i];
        blendItem(vec2<i32>(vec2<u32>(it.x >> 18u, it.x & 0x3FFFu)), (it.y >> 31u) != 0u, ((it.y >> 30u) & 1u) != 0u,
                  i32((it.y >> 20u) & 1023u) - 256, i32((it.y >> 10u) & 1023u) - 256, f32(it.y & 1023u) / 1023.0);
    }
}

// --- Resolve --------------------------------------------------------------

@compute @workgroup_size(4, 32)
fn cs_apply(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.y >= atomicLoad(&control.count)) { return; }
    let loc = locations[gid.y];
    let quad = vec2<u32>(loc >> 16u, loc & 0xFFFFu);
    let q = quad * 2u + vec2<u32>(gid.x & 1u, gid.x >> 1u);
    var node = atomicLoad(&heads[quadIndex(quad)]);
    var sum = vec4<f32>(0.0);
    for (var i = 0; i < 32 && node != EMPTY; i++) {
        let it = items[node & 0x03FFFFFFu];
        if ((node >> 30u) == gid.x) {
            let w = select(0.8, 1.8, ((node >> 26u) & 1u) != 0u);
            sum += vec4<f32>(unpackColor(it.y) * w, w);
        }
        node = it.x;
    }
    if (sum.w == 0.0 || any(q >= p.size)) { return; }
    textureStore(dstTex, q, vec4<f32>(sqrt(sum.rgb / sum.w), 1.0));
}
