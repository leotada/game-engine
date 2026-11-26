/// Hex-tiling: hides the repetition of a tiling texture (Mikkelsen 2022, "Practical Real-Time
/// Hex-Tiling", JCGT 11(3)). The UV plane is cut into hexagons about a third of a texture wide;
/// each pixel blends three reads, one per nearby hexagon, each with its own random offset and
/// rotation. The weights favor the brighter read (contrast-preserving), so the blend does not
/// wash the texture out. Normal reads are rotated back with `hexToUvFrame`.

struct HexTiles {
    uv0: vec2<f32>,
    uv1: vec2<f32>,
    uv2: vec2<f32>,
    /// (cos, sin) of the rotation of each read.
    rot0: vec2<f32>,
    rot1: vec2<f32>,
    rot2: vec2<f32>,
    /// Barycentric weights of the three hexagons.
    w: vec3<f32>,
};

/// Three uniform values in [0, 1) for an integer lattice point.
fn hexHash(p: vec2<f32>) -> vec3<f32> {
    var h = (bitcast<u32>(i32(p.x)) * 1597334677u) ^ (bitcast<u32>(i32(p.y)) * 3812015801u);
    h = h ^ (h >> 16u);
    h = h * 2246822519u;
    h = h ^ (h >> 13u);
    h = h * 3266489917u;
    h = h ^ (h >> 16u);
    let b = h * 747796405u + 2891336453u;
    let c = b * 747796405u + 2891336453u;
    return vec3<f32>(vec3<u32>(h, b, c) >> vec3<u32>(8u)) / 16777216.0;
}

/// Rotate `v` by the angle whose (cos, sin) is `cs`.
fn hexRotate(v: vec2<f32>, cs: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(cs.x * v.x - cs.y * v.y, cs.y * v.x + cs.x * v.y);
}

/// A tangent-space XY read from a rotated tile, back in the frame of the unrotated UV
/// (normal map +Y along +V). For a +Y along -V frame (glTF / MikkTSpace), pass `vec2(cs.x, -cs.y)`.
fn hexToUvFrame(xy: vec2<f32>, cs: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(cs.x * xy.x + cs.y * xy.y, -cs.y * xy.x + cs.x * xy.y);
}

fn hexRotation(v: vec2<f32>, rotation: f32) -> vec2<f32> {
    let a = (hexHash(v).z * 2.0 - 1.0) * 3.14159265 * rotation;
    return vec2<f32>(cos(a), sin(a));
}

fn hexTileUv(uv: vec2<f32>, v: vec2<f32>, cs: vec2<f32>) -> vec2<f32> {
    let cen = vec2<f32>(v.x + 0.5 * v.y, 0.8660254 * v.y) * 0.28867513;
    return hexRotate(uv - cen, cs) + cen + hexHash(v).xy;
}

/// The three reads of `uv`. `rotation` is the largest turn as a fraction of half a turn
/// (1 = any angle, 0 = offsets only, for textures with a direction).
fn hexTiles(uv: vec2<f32>, rotation: f32) -> HexTiles {
    let s = uv * 3.4641016;
    let sk = vec2<f32>(s.x - 0.57735027 * s.y, 1.15470054 * s.y);
    let base = floor(sk);
    let f = sk - base;
    let z = 1.0 - f.x - f.y;
    let sg = step(0.0, -z);
    let s2 = 2.0 * sg - 1.0;
    let v0 = base + vec2<f32>(sg, sg);
    let v1 = base + vec2<f32>(sg, 1.0 - sg);
    let v2 = base + vec2<f32>(1.0 - sg, sg);
    var t: HexTiles;
    t.w = max(vec3<f32>(-z * s2, sg - f.y * s2, sg - f.x * s2), vec3<f32>(0.0));
    t.rot0 = hexRotation(v0, rotation);
    t.rot1 = hexRotation(v1, rotation);
    t.rot2 = hexRotation(v2, rotation);
    t.uv0 = hexTileUv(uv, v0, t.rot0);
    t.uv1 = hexTileUv(uv, v1, t.rot1);
    t.uv2 = hexTileUv(uv, v2, t.rot2);
    return t;
}

/// Final blend weights from the three color reads. `contrast` 0 = plain barycentric blend,
/// 1 = the brightest read wins near hexagon edges (0.6 is the paper's default).
fn hexWeights(t: HexTiles, c0: vec3<f32>, c1: vec3<f32>, c2: vec3<f32>, contrast: f32) -> vec3<f32> {
    let lw = vec3<f32>(0.299, 0.587, 0.114);
    let d = mix(vec3<f32>(1.0), vec3<f32>(dot(c0, lw), dot(c1, lw), dot(c2, lw)), contrast);
    let w = d * pow(t.w, vec3<f32>(7.0));
    return w / max(w.x + w.y + w.z, 1e-6);
}

struct HexReads {
    r0: vec4<f32>,
    r1: vec4<f32>,
    r2: vec4<f32>,
};

fn hexSample(tex: texture_2d<f32>, smp: sampler, t: HexTiles, gx: vec2<f32>, gy: vec2<f32>) -> HexReads {
    var r: HexReads;
    r.r0 = textureSampleGrad(tex, smp, t.uv0, hexRotate(gx, t.rot0), hexRotate(gy, t.rot0));
    r.r1 = textureSampleGrad(tex, smp, t.uv1, hexRotate(gx, t.rot1), hexRotate(gy, t.rot1));
    r.r2 = textureSampleGrad(tex, smp, t.uv2, hexRotate(gx, t.rot2), hexRotate(gy, t.rot2));
    return r;
}

fn hexSampleArray(tex: texture_2d_array<f32>, smp: sampler, layer: i32, t: HexTiles,
                  gx: vec2<f32>, gy: vec2<f32>) -> HexReads {
    var r: HexReads;
    r.r0 = textureSampleGrad(tex, smp, t.uv0, layer, hexRotate(gx, t.rot0), hexRotate(gy, t.rot0));
    r.r1 = textureSampleGrad(tex, smp, t.uv1, layer, hexRotate(gx, t.rot1), hexRotate(gy, t.rot1));
    r.r2 = textureSampleGrad(tex, smp, t.uv2, layer, hexRotate(gx, t.rot2), hexRotate(gy, t.rot2));
    return r;
}

fn hexBlend(r: HexReads, w: vec3<f32>) -> vec4<f32> {
    return r.r0 * w.x + r.r1 * w.y + r.r2 * w.z;
}

/// Tangent-space normal from three normal-map reads (0..1 encoded), in the unrotated UV frame.
/// `flipFrame` for maps whose +Y runs along -V (glTF / MikkTSpace meshes).
fn hexBlendNormal(r: HexReads, t: HexTiles, w: vec3<f32>, flipFrame: bool) -> vec3<f32> {
    let k = select(1.0, -1.0, flipFrame);
    let n0 = r.r0.xyz * 2.0 - 1.0;
    let n1 = r.r1.xyz * 2.0 - 1.0;
    let n2 = r.r2.xyz * 2.0 - 1.0;
    let xy = hexToUvFrame(n0.xy, vec2<f32>(t.rot0.x, t.rot0.y * k)) * w.x
           + hexToUvFrame(n1.xy, vec2<f32>(t.rot1.x, t.rot1.y * k)) * w.y
           + hexToUvFrame(n2.xy, vec2<f32>(t.rot2.x, t.rot2.y * k)) * w.z;
    return vec3<f32>(xy, n0.z * w.x + n1.z * w.y + n2.z * w.z);
}

/// Smooth value noise in [0, 1] (macro variation, per-object offsets).
fn hexValueNoise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = p - i;
    let u = f * f * (3.0 - 2.0 * f);
    let a = hexHash(i).x;
    let b = hexHash(i + vec2<f32>(1.0, 0.0)).x;
    let c = hexHash(i + vec2<f32>(0.0, 1.0)).x;
    let d = hexHash(i + vec2<f32>(1.0, 1.0)).x;
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
