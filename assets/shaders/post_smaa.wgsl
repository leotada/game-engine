// SMAA 1x: Enhanced Subpixel Morphological Antialiasing (Jimenez et al. 2012).
// WGSL port of SMAA.hlsl (https://github.com/iryoku/smaa), MIT license, see
// docs/third-party-licenses.md. Preset "high". Colors are blended in an
// approximately linear space (square of the display value).

struct Params {
    // 1/width, 1/height, width, height
    rt: vec4<f32>,
    // edge threshold, unused
    a: vec4<f32>,
};
@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var tex0: texture_2d<f32>; // color / edges / color
@group(0) @binding(3) var tex1: texture_2d<f32>; // - / area table / weights
@group(0) @binding(4) var tex2: texture_2d<f32>; // - / search table / -

const MAX_STEPS: f32 = 16.0;
const MAX_STEPS_DIAG: f32 = 8.0;
const CORNER: f32 = 0.75; // 1 - corner rounding (25%)
const AREA_PIXEL: vec2<f32> = vec2<f32>(1.0 / 160.0, 1.0 / 80.0);

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4<f32> {
    let x = f32(i32(vi) / 2) * 4.0 - 1.0;
    let y = f32(i32(vi) % 2) * 4.0 - 1.0;
    return vec4<f32>(x, y, 0.0, 1.0);
}

fn lumaAt(q: vec2<i32>) -> f32 {
    let size = vec2<i32>(textureDimensions(tex0));
    return dot(textureLoad(tex0, clamp(q, vec2<i32>(0), size - 1), 0).rgb, vec3<f32>(0.2126, 0.7152, 0.0722));
}

@fragment
fn fs_edges(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(pos.xy);
    let L = lumaAt(q);
    let left = lumaAt(q + vec2<i32>(-1, 0));
    let top = lumaAt(q + vec2<i32>(0, -1));
    let delta = abs(vec2<f32>(L) - vec2<f32>(left, top));
    var edges = step(vec2<f32>(p.a.x), delta);
    if (edges.x + edges.y == 0.0) { return vec4<f32>(0.0); }
    let right = lumaAt(q + vec2<i32>(1, 0));
    let bottom = lumaAt(q + vec2<i32>(0, 1));
    var maxDelta = max(delta, abs(vec2<f32>(L) - vec2<f32>(right, bottom)));
    let left2 = lumaAt(q + vec2<i32>(-2, 0));
    let top2 = lumaAt(q + vec2<i32>(0, -2));
    maxDelta = max(maxDelta, abs(vec2<f32>(left, top) - vec2<f32>(left2, top2)));
    let finalDelta = max(maxDelta.x, maxDelta.y);
    // Local contrast adaptation, factor 2.
    edges = edges * step(vec2<f32>(finalDelta), 2.0 * delta);
    return vec4<f32>(edges, 0.0, 0.0);
}

fn edgeAt(uv: vec2<f32>) -> vec2<f32> { return textureSampleLevel(tex0, samp, uv, 0.0).rg; }

fn decodeDiag2(e: vec2<f32>) -> vec2<f32> {
    return round(vec2<f32>(e.x * abs(5.0 * e.x - 5.0 * 0.75), e.y));
}

fn decodeDiag4(e: vec4<f32>) -> vec4<f32> {
    return round(vec4<f32>(e.x * abs(5.0 * e.x - 5.0 * 0.75), e.y, e.z * abs(5.0 * e.z - 5.0 * 0.75), e.w));
}

struct Diag { d: vec2<f32>, e: vec2<f32> };

fn searchDiag1(uv: vec2<f32>, dir: vec2<f32>) -> Diag {
    var coord = vec4<f32>(uv, -1.0, 1.0);
    var e = vec2<f32>(0.0);
    while (coord.z < MAX_STEPS_DIAG - 1.0 && coord.w > 0.9) {
        coord = vec4<f32>(coord.xy + p.rt.xy * dir, coord.z + 1.0, coord.w);
        e = edgeAt(coord.xy);
        coord.w = dot(e, vec2<f32>(0.5));
    }
    return Diag(coord.zw, e);
}

fn searchDiag2(uv: vec2<f32>, dir: vec2<f32>) -> Diag {
    var coord = vec4<f32>(uv.x + 0.25 * p.rt.x, uv.y, -1.0, 1.0);
    var e = vec2<f32>(0.0);
    while (coord.z < MAX_STEPS_DIAG - 1.0 && coord.w > 0.9) {
        coord = vec4<f32>(coord.xy + p.rt.xy * dir, coord.z + 1.0, coord.w);
        e = decodeDiag2(edgeAt(coord.xy));
        coord.w = dot(e, vec2<f32>(0.5));
    }
    return Diag(coord.zw, e);
}

fn areaDiag(dist: vec2<f32>, e: vec2<f32>) -> vec2<f32> {
    var uv = 20.0 * e + dist;
    uv = AREA_PIXEL * uv + 0.5 * AREA_PIXEL;
    uv.x += 0.5;
    return textureSampleLevel(tex1, samp, uv, 0.0).rg;
}

fn diagWeights(uv: vec2<f32>, e: vec2<f32>) -> vec2<f32> {
    var weights = vec2<f32>(0.0);
    var d = vec4<f32>(0.0);
    if (e.x > 0.0) {
        let r = searchDiag1(uv, vec2<f32>(-1.0, 1.0));
        d.x = r.d.x + select(0.0, 1.0, r.e.y > 0.9);
        d.z = r.d.y;
    }
    let r1 = searchDiag1(uv, vec2<f32>(1.0, -1.0));
    d.y = r1.d.x;
    d.w = r1.d.y;
    if (d.x + d.y > 2.0) {
        let c = vec4<f32>(-d.x + 0.25, d.x, d.y, -d.y - 0.25) * p.rt.xyxy + uv.xyxy;
        let a = textureSampleLevel(tex0, samp, c.xy, 0.0, vec2<i32>(-1, 0)).rg;
        let b = textureSampleLevel(tex0, samp, c.zw, 0.0, vec2<i32>(1, 0)).rg;
        let dec = decodeDiag4(vec4<f32>(a, b));
        let cs = vec4<f32>(dec.y, dec.x, dec.w, dec.z);
        var cc = 2.0 * cs.xz + cs.yw;
        cc = select(cc, vec2<f32>(0.0), d.zw >= vec2<f32>(0.9));
        weights += areaDiag(d.xy, cc);
    }
    let r2 = searchDiag2(uv, vec2<f32>(-1.0, -1.0));
    d.x = r2.d.x;
    d.z = r2.d.y;
    d.y = 0.0;
    d.w = 0.0;
    if (textureSampleLevel(tex0, samp, uv, 0.0, vec2<i32>(1, 0)).r > 0.0) {
        let r3 = searchDiag2(uv, vec2<f32>(1.0, 1.0));
        d.y = r3.d.x + select(0.0, 1.0, r3.e.y > 0.9);
        d.w = r3.d.y;
    }
    if (d.x + d.y > 2.0) {
        let c = vec4<f32>(-d.x, -d.x, d.y, d.y) * p.rt.xyxy + uv.xyxy;
        let cx = textureSampleLevel(tex0, samp, c.xy, 0.0, vec2<i32>(-1, 0)).g;
        let cy = textureSampleLevel(tex0, samp, c.xy, 0.0, vec2<i32>(0, -1)).r;
        let czw = textureSampleLevel(tex0, samp, c.zw, 0.0, vec2<i32>(1, 0)).gr;
        var cc = 2.0 * vec2<f32>(cx, czw.x) + vec2<f32>(cy, czw.y);
        cc = select(cc, vec2<f32>(0.0), d.zw >= vec2<f32>(0.9));
        weights += areaDiag(d.xy, cc).gr;
    }
    return weights;
}

fn searchLength(e: vec2<f32>, offset: f32) -> f32 {
    let scale = vec2<f32>(66.0 * 0.5 - 1.0, -33.0 + 1.0) / vec2<f32>(64.0, 16.0);
    let bias = vec2<f32>(66.0 * offset + 0.5, 33.0 - 0.5) / vec2<f32>(64.0, 16.0);
    return textureSampleLevel(tex2, samp, scale * e + bias, 0.0).r;
}

fn searchX(uv0: vec2<f32>, end: f32, dir: f32) -> f32 {
    var uv = uv0;
    var e = vec2<f32>(0.0, 1.0);
    while ((end - uv.x) * dir > 0.0 && e.y > 0.8281 && e.x == 0.0) {
        e = edgeAt(uv);
        uv.x += dir * 2.0 * p.rt.x;
    }
    let offset = -(255.0 / 127.0) * searchLength(e, select(0.0, 0.5, dir > 0.0)) + 3.25;
    return uv.x - dir * p.rt.x * offset;
}

fn searchY(uv0: vec2<f32>, end: f32, dir: f32) -> f32 {
    var uv = uv0;
    var e = vec2<f32>(1.0, 0.0);
    while ((end - uv.y) * dir > 0.0 && e.x > 0.8281 && e.y == 0.0) {
        e = edgeAt(uv);
        uv.y += dir * 2.0 * p.rt.y;
    }
    let offset = -(255.0 / 127.0) * searchLength(e.yx, select(0.0, 0.5, dir > 0.0)) + 3.25;
    return uv.y - dir * p.rt.y * offset;
}

fn area(dist: vec2<f32>, e1: f32, e2: f32) -> vec2<f32> {
    let uv = 16.0 * round(4.0 * vec2<f32>(e1, e2)) + dist;
    return textureSampleLevel(tex1, samp, AREA_PIXEL * uv + 0.5 * AREA_PIXEL, 0.0).rg;
}

fn cornerRounding(d: vec2<f32>) -> vec2<f32> {
    let lr = step(d.xy, d.yx);
    return CORNER * lr / (lr.x + lr.y);
}

@fragment
fn fs_weights(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = pos.xy * p.rt.xy;
    var weights = vec4<f32>(0.0);
    var e = textureLoad(tex0, vec2<i32>(pos.xy), 0).rg;
    if (e.x + e.y == 0.0) { return weights; }
    let o0 = p.rt.xyxy * vec4<f32>(-0.25, -0.125, 1.25, -0.125) + uv.xyxy;
    let o1 = p.rt.xyxy * vec4<f32>(-0.125, -0.25, -0.125, 1.25) + uv.xyxy;
    let o2 = p.rt.xxyy * (vec4<f32>(-2.0, 2.0, -2.0, 2.0) * MAX_STEPS) + vec4<f32>(o0.xz, o1.yw);
    if (e.y > 0.0) { // edge at north
        let dw = diagWeights(uv, e);
        if (dw.x == -dw.y) {
            let x0 = searchX(o0.xy, o2.x, -1.0);
            let x1 = searchX(o0.zw, o2.y, 1.0);
            let y = o1.y;
            let d = abs(round(p.rt.zz * vec2<f32>(x0, x1) - pos.xx));
            let e1 = edgeAt(vec2<f32>(x0, y)).r;
            let e2 = textureSampleLevel(tex0, samp, vec2<f32>(x1, y), 0.0, vec2<i32>(1, 0)).r;
            var w = area(sqrt(d), e1, e2);
            let r = cornerRounding(d);
            var f = vec2<f32>(1.0);
            f.x -= r.x * textureSampleLevel(tex0, samp, vec2<f32>(x0, uv.y), 0.0, vec2<i32>(0, 1)).r;
            f.x -= r.y * textureSampleLevel(tex0, samp, vec2<f32>(x1, uv.y), 0.0, vec2<i32>(1, 1)).r;
            f.y -= r.x * textureSampleLevel(tex0, samp, vec2<f32>(x0, uv.y), 0.0, vec2<i32>(0, -2)).r;
            f.y -= r.y * textureSampleLevel(tex0, samp, vec2<f32>(x1, uv.y), 0.0, vec2<i32>(1, -2)).r;
            w *= clamp(f, vec2<f32>(0.0), vec2<f32>(1.0));
            weights = vec4<f32>(w, weights.zw);
        } else {
            weights = vec4<f32>(dw, weights.zw);
            e.x = 0.0; // skip vertical processing
        }
    }
    if (e.x > 0.0) { // edge at west
        let y0 = searchY(o1.xy, o2.z, -1.0);
        let y1 = searchY(o1.zw, o2.w, 1.0);
        let x = o0.x;
        let d = abs(round(p.rt.ww * vec2<f32>(y0, y1) - pos.yy));
        let e1 = edgeAt(vec2<f32>(x, y0)).g;
        let e2 = textureSampleLevel(tex0, samp, vec2<f32>(x, y1), 0.0, vec2<i32>(0, 1)).g;
        var w = area(sqrt(d), e1, e2);
        let r = cornerRounding(d);
        var f = vec2<f32>(1.0);
        f.x -= r.x * textureSampleLevel(tex0, samp, vec2<f32>(uv.x, y0), 0.0, vec2<i32>(1, 0)).g;
        f.x -= r.y * textureSampleLevel(tex0, samp, vec2<f32>(uv.x, y1), 0.0, vec2<i32>(1, 1)).g;
        f.y -= r.x * textureSampleLevel(tex0, samp, vec2<f32>(uv.x, y0), 0.0, vec2<i32>(-2, 0)).g;
        f.y -= r.y * textureSampleLevel(tex0, samp, vec2<f32>(uv.x, y1), 0.0, vec2<i32>(-2, 1)).g;
        w *= clamp(f, vec2<f32>(0.0), vec2<f32>(1.0));
        weights = vec4<f32>(weights.xy, w);
    }
    return weights;
}

fn loadSquared(q: vec2<i32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(tex0));
    let c = textureLoad(tex0, clamp(q, vec2<i32>(0), size - 1), 0).rgb;
    return c * c;
}

@fragment
fn fs_blend(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let q = vec2<i32>(pos.xy);
    let size = vec2<i32>(textureDimensions(tex0));
    let right = textureLoad(tex1, min(q + vec2<i32>(1, 0), size - 1), 0).a;
    let bottom = textureLoad(tex1, min(q + vec2<i32>(0, 1), size - 1), 0).g;
    let own = textureLoad(tex1, q, 0);
    // x = right, y = bottom, z = left, w = top
    let a = vec4<f32>(select(0.0, right, q.x + 1 < size.x), select(0.0, bottom, q.y + 1 < size.y), own.z, own.x);
    if (dot(a, vec4<f32>(1.0)) < 1e-5) { return vec4<f32>(textureLoad(tex0, q, 0).rgb, 1.0); }
    let c = loadSquared(q);
    var color: vec3<f32>;
    if (max(a.x, a.z) > max(a.y, a.w)) {
        let w = a.xz / (a.x + a.z);
        color = w.x * mix(c, loadSquared(q + vec2<i32>(1, 0)), a.x) + w.y * mix(c, loadSquared(q - vec2<i32>(1, 0)), a.z);
    } else {
        let w = a.yw / (a.y + a.w);
        color = w.x * mix(c, loadSquared(q + vec2<i32>(0, 1)), a.y) + w.y * mix(c, loadSquared(q - vec2<i32>(0, 1)), a.w);
    }
    return vec4<f32>(sqrt(color), 1.0);
}
