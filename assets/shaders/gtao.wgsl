// Ground-truth ambient occlusion (Jimenez et al. 2016, "Practical Realtime
// Strategies for Accurate Indirect Occlusion"): horizon search per slice,
// fixed 4x4 spatial pattern, depth-aware 4-wide blur that cancels the pattern.
// No temporal data. Depth-only: normals are rebuilt from depth.

struct AoParams {
    // scene rectangle in full-resolution pixels
    viewport: vec4<f32>,
    // tan(half fov) x, tan(half fov) y, near, far
    proj: vec4<f32>,
    // radius (world), intensity, pixels per unit at distance 1 (full res), unused
    a: vec4<f32>,
    // slices, steps per side, resolution divisor, unused
    b: vec4<f32>,
};
@group(0) @binding(0) var<uniform> p: AoParams;
@group(0) @binding(1) var depthTex: texture_depth_2d;
@group(0) @binding(2) var linTex: texture_2d<f32>;
@group(0) @binding(3) var aoTex: texture_2d<f32>;

const PI: f32 = 3.14159265;
const FAR_AWAY: f32 = 1e6;
// Sine of the elevation where an occluder counts fully (1.7 degrees).
const MIN_ELEVATION: f32 = 0.03;

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    let x = f32(i32(vi) / 2) * 4.0 - 1.0;
    let y = f32(i32(vi) % 2) * 4.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}

fn linearize(d: f32) -> f32 {
    if (d >= 1.0) { return FAR_AWAY; }
    return p.proj.z * p.proj.w / (p.proj.w - d * (p.proj.w - p.proj.z));
}

// Full-resolution pixel position (texel centers at .5) of an AO texel.
fn fullPixel(t: vec2<f32>) -> vec2<f32> {
    // Half resolution keeps the top-left texel of each 2x2 block.
    return floor(t) * p.b.z + 0.5;
}

fn viewPos(pixel: vec2<f32>, z: f32) -> vec3<f32> {
    let t = (pixel - p.viewport.xy) / p.viewport.zw;
    return vec3<f32>((t.x * 2.0 - 1.0) * p.proj.x * z, (1.0 - t.y * 2.0) * p.proj.y * z, -z);
}

fn linAt(t: vec2<i32>, mip: i32) -> f32 {
    let size = vec2<i32>(textureDimensions(linTex, mip));
    return textureLoad(linTex, clamp(t, vec2<i32>(0), size - vec2<i32>(1)), mip).r;
}

@fragment
fn fs_linearize(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let t = vec2<i32>(fullPixel(pos.xy));
    return vec4<f32>(linearize(textureLoad(depthTex, t, 0)), 0.0, 0.0, 1.0);
}

// Rotated-grid pick of one of the four texels below: no averaging across edges.
@fragment
fn fs_downsample(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let t = vec2<i32>(pos.xy);
    return vec4<f32>(linAt(t * 2 + vec2<i32>(t.y & 1, t.x & 1), 0), 0.0, 0.0, 1.0);
}

fn aoViewPos(t: vec2<i32>) -> vec3<f32> {
    return viewPos(fullPixel(vec2<f32>(t) + 0.5), linAt(t, 0));
}

fn viewNormal(t: vec2<i32>, c: vec3<f32>) -> vec3<f32> {
    let l = aoViewPos(t - vec2<i32>(1, 0));
    let r = aoViewPos(t + vec2<i32>(1, 0));
    let u = aoViewPos(t - vec2<i32>(0, 1));
    let d = aoViewPos(t + vec2<i32>(0, 1));
    let dx = select(r - c, c - l, abs(l.z - c.z) < abs(r.z - c.z));
    let dy = select(d - c, c - u, abs(u.z - c.z) < abs(d.z - c.z));
    let n = normalize(cross(dy, dx));
    return select(n, -n, dot(n, c) > 0.0);
}

@fragment
fn fs_ao(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let t = vec2<i32>(pos.xy);
    let z = linAt(t, 0);
    if (z >= FAR_AWAY) { return vec4<f32>(1.0); }
    let c = aoViewPos(t);
    let V = normalize(-c);
    let N = viewNormal(t, c);
    // Screen radius in AO texels.
    let maxTexels = 160.0 / p.b.z;
    let radiusTexels = min(p.a.x * p.a.z / z / p.b.z, maxTexels);
    if (radiusTexels < 1.0) { return vec4<f32>(1.0); }
    // Effective world radius after the pixel clamp.
    let radius = radiusTexels * z * p.b.z / p.a.z;
    let falloffStart = radius * 0.4;
    let falloffScale = 1.0 / (radius - falloffStart);

    // Fixed 4x4 pattern: every slice angle and step offset once per block.
    let x = t.x & 3;
    let y = t.y & 3;
    let rotation = f32((((x + y) & 3) << 2) + x) / 16.0;
    let jitter = 0.25 * f32((y - x) & 3) + 0.125;

    let slices = i32(p.b.x);
    let steps = i32(p.b.y);
    var visibility = 0.0;
    for (var s = 0; s < slices; s++) {
        let phi = (f32(s) + rotation) * PI / f32(slices);
        let dir = vec2<f32>(cos(phi), sin(phi));
        // Texture y points down, view y up.
        let dirView = vec3<f32>(dir.x, -dir.y, 0.0);
        let ortho = dirView - V * dot(dirView, V);
        let axis = normalize(cross(ortho, V));
        let projN = N - axis * dot(N, axis);
        let projLen = length(projN);
        let cosN = clamp(dot(projN, V) / max(projLen, 1e-4), -1.0, 1.0);
        let n = sign(dot(ortho, projN)) * acos(cosN);
        var horizon = vec2<f32>(0.0);
        for (var side = 0; side < 2; side++) {
            let sgn = select(1.0, -1.0, side == 1);
            // Below this the sample is behind the surface's own hemisphere.
            let low = cos(n + sgn * PI * 0.5);
            var h = low;
            for (var i = 0; i < steps; i++) {
                let f = (f32(i) + jitter) / f32(steps);
                let dist = max(f * f * radiusTexels, f32(i) + 1.0);
                let o = dir * dist * sgn;
                let mip = clamp(i32(log2(max(dist, 1.0)) - 3.0), 0, i32(textureNumLevels(linTex)) - 1);
                let q = vec2<i32>(round(o)) + t;
                let mipSize = vec2<i32>(textureDimensions(linTex, mip));
                let qm = clamp(q >> vec2<u32>(u32(mip)), vec2<i32>(0), mipSize - vec2<i32>(1));
                let sz = linAt(qm, mip);
                if (sz >= FAR_AWAY) { continue; }
                // Position the sample where its depth was taken, not where it was asked for.
                let at = mipTexel(qm, mip);
                let delta = viewPos(fullPixel(vec2<f32>(at) + 0.5), sz) - c;
                let len = max(length(delta), 1e-5);
                // Samples sit on texel centers, off the exact slice direction: without
                // a minimum elevation, coplanar points at grazing angles occlude.
                let elevation = clamp(dot(delta, N) / (len * MIN_ELEVATION), 0.0, 1.0);
                let w = clamp(1.0 - (len - falloffStart) * falloffScale, 0.0, 1.0) * elevation;
                h = max(h, mix(low, dot(delta / len, V), w));
            }
            horizon[side] = h;
        }
        let h0 = -acos(clamp(horizon.y, -1.0, 1.0));
        let h1 = acos(clamp(horizon.x, -1.0, 1.0));
        let sinN = sin(n);
        let arc0 = (cosN + 2.0 * h0 * sinN - cos(2.0 * h0 - n)) * 0.25;
        let arc1 = (cosN + 2.0 * h1 * sinN - cos(2.0 * h1 - n)) * 0.25;
        visibility += projLen * (arc0 + arc1);
    }
    visibility = max(visibility / f32(slices), 0.0);
    // Fade out instead of popping when the radius shrinks to a texel.
    let fade = clamp(radiusTexels - 1.0, 0.0, 1.0);
    return vec4<f32>(mix(1.0, visibility, fade));
}

// Mip-0 texel whose depth `fs_downsample` carried into `t` at `mip`.
fn mipTexel(t: vec2<i32>, mip: i32) -> vec2<i32> {
    var q = t;
    for (var m = mip; m > 0; m--) { q = q * 2 + vec2<i32>(q.y & 1, q.x & 1); }
    return q;
}

fn aoLoad(t: vec2<i32>) -> f32 {
    let size = vec2<i32>(textureDimensions(aoTex));
    return textureLoad(aoTex, clamp(t, vec2<i32>(0), size - vec2<i32>(1)), 0).r;
}

// Weight of a neighbor: distance from the tangent plane estimated by the
// depth slope along the blur axis, so grazing floors still blur.
fn blur(pos: vec2<f32>, axis: vec2<i32>) -> f32 {
    let t = vec2<i32>(pos);
    let z = linAt(t, 0);
    if (z >= FAR_AWAY) { return 1.0; }
    let a = linAt(t - axis, 0);
    let b = linAt(t + axis, 0);
    let da = z - a;
    let db = b - z;
    let slope = select(db, da, abs(da) < abs(db));
    let tolerance = 0.01 * z + abs(slope) * 0.5;
    var sum = 0.0;
    var weight = 0.0;
    for (var i = -2; i <= 2; i++) {
        let q = t + axis * i;
        let box = select(1.0, 0.5, abs(i) == 2);
        let w = box * clamp(2.0 - abs(linAt(q, 0) - (z + slope * f32(i))) / tolerance, 0.0, 1.0);
        sum += aoLoad(q) * w;
        weight += w;
    }
    return sum / max(weight, 1e-4);
}

@fragment
fn fs_blur_x(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    return vec4<f32>(blur(pos.xy, vec2<i32>(1, 0)));
}

@fragment
fn fs_blur_y(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    return vec4<f32>(blur(pos.xy, vec2<i32>(0, 1)));
}

fn finalAo(pixel: vec2<f32>) -> f32 {
    let div = i32(p.b.z);
    let fp = vec2<i32>(pixel);
    let d = textureLoad(depthTex, fp, 0);
    if (d >= 1.0) { return 1.0; }
    if (div <= 1) { return aoLoad(fp); }
    // Depth-aware upsample of the four nearest half-resolution texels.
    let z = linearize(d);
    let base = fp / div;
    let odd = fp - base * div;
    var sum = 0.0;
    var weight = 0.0;
    for (var j = 0; j <= odd.y; j++) {
        for (var i = 0; i <= odd.x; i++) {
            let q = base + vec2<i32>(i, j);
            let w = 1.0 / (abs(linAt(q, 0) - z) / z + 1e-3);
            sum += aoLoad(q) * w;
            weight += w;
        }
    }
    return sum / weight;
}

// Draw 1, alpha only: a = ao + a * (1 - ao). The scene alpha holds
// 1 - (ambient part of the color), so only that part is darkened.
@fragment
fn fs_composite_alpha(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let ao = pow(clamp(finalAo(pos.xy), 0.0, 1.0), p.a.y);
    return vec4<f32>(0.0, 0.0, 0.0, ao);
}

// Draw 2: color *= a, then a = 1.
@fragment
fn fs_composite_color(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    if (textureLoad(depthTex, vec2<i32>(pos.xy), 0) >= 1.0) { discard; }
    return vec4<f32>(0.0, 0.0, 0.0, 1.0);
}
