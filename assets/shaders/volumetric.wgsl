// Single-scattering volumetric light: ray march in the opaque depth buffer at
// half or quarter resolution, fixed 4x4 spatial jitter cancelled by a
// depth-aware blur, depth-aware upsample. No temporal data.

#include "common/shadows.wgsl"

struct VolParams {
    // scene rectangle in full-resolution pixels
    viewport: vec4<f32>,
    // tan(half fov) x, tan(half fov) y, near, far
    proj: vec4<f32>,
    // extinction at the base height, height falloff, base height, anisotropy
    a: vec4<f32>,
    // max distance, steps, resolution divisor, attenuate (0 or 1)
    b: vec4<f32>,
    // albedo * intensity, sun scale
    c: vec4<f32>,
    // ambient radiance, local light scale
    d: vec4<f32>,
};
@group(1) @binding(0) var<uniform> p: VolParams;
@group(1) @binding(1) var depthTex: texture_depth_2d;
@group(1) @binding(2) var scatterTex: texture_2d<f32>;

const FAR_AWAY: f32 = 1e6;
// Near plane of the cube shadow maps, read by `common/shadows.wgsl`.
const SHADOW_NEAR: f32 = 0.1;
const INV_4PI: f32 = 0.07957747;

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

// Full-resolution texel read by a low-resolution texel (center of its block).
fn fullTexel(t: vec2<i32>) -> vec2<i32> {
    let div = i32(p.b.z);
    let size = vec2<i32>(textureDimensions(depthTex));
    return min(t * div + vec2<i32>(div / 2), size - vec2<i32>(1));
}

fn lowDepth(t: vec2<i32>) -> f32 {
    return linearize(textureLoad(depthTex, fullTexel(t), 0));
}

fn phase(cosTheta: f32, g: f32) -> f32 {
    let k = 1.0 + g * g - 2.0 * g * cosTheta;
    return INV_4PI * (1.0 - g * g) / max(k * sqrt(k), 1e-4);
}

fn density(y: f32) -> f32 {
    return p.a.x * exp(clamp(-p.a.y * (y - p.a.z), -40.0, 3.0));
}

// Same falloff as the surface shading (`common/pbr_brdf.wgsl`).
fn falloff(dist: f32, range: f32, exponent: f32) -> f32 {
    if (exponent > 0.0) {
        return pow(clamp(1.0 - dist / max(range, 0.001), 0.0, 1.0), exponent);
    }
    let x = clamp(1.0 - pow(dist / max(range, 0.001), 4.0), 0.0, 1.0);
    return (x * x) / (dist * dist + 1.0);
}

fn pointScatter(l: PointLight, pos: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    let v = l.position - pos;
    let dist = length(v);
    if (dist >= l.range || dist <= 1e-5) { return vec3<f32>(0.0); }
    let e = l.intensity * falloff(dist, l.range, l.attenuation) * phase(dot(dir, v / dist), p.a.w);
    return l.color * e * pointShadowTap(l, pos);
}

fn spotScatter(l: SpotLight, pos: vec3<f32>, dir: vec3<f32>) -> vec3<f32> {
    let v = l.position - pos;
    let dist = length(v);
    if (dist >= l.range || dist <= 1e-5) { return vec3<f32>(0.0); }
    let L = v / dist;
    let theta = dot(normalize(-l.direction), L);
    let cone = clamp((theta - l.outerConeCos) / max(l.innerConeCos - l.outerConeCos, 0.001), 0.0, 1.0);
    if (cone <= 0.0) { return vec3<f32>(0.0); }
    let soft = select(cone * cone, pow(cone, l.angleAttenuation), l.angleAttenuation > 0.0);
    let e = l.intensity * falloff(dist, l.range, l.attenuation) * soft * phase(dot(dir, L), p.a.w);
    return l.color * e * spotShadowTap(l, pos);
}

fn localScatter(pos: vec3<f32>, dir: vec3<f32>, pixel: vec2<f32>) -> vec3<f32> {
    var sum = vec3<f32>(0.0);
    let pMax = arrayLength(&pointLights);
    let sMax = arrayLength(&spotLights);
    if ((frame.clusteredFlags & 1u) != 0u) {
        let rec = clusterGrid[clusterIndexAt(pos, pixel)];
        for (var k = 0u; k < rec.pointCount; k++) {
            let i = clusterLightIndices[rec.offset + k];
            if (i < pMax) { sum += pointScatter(pointLights[i], pos, dir); }
        }
        for (var k = 0u; k < rec.spotCount; k++) {
            let i = clusterLightIndices[rec.offset + rec.pointCount + k];
            if (i < sMax) { sum += spotScatter(spotLights[i], pos, dir); }
        }
        return sum;
    }
    for (var i = 0u; i < min(frame.pointCount, pMax); i++) { sum += pointScatter(pointLights[i], pos, dir); }
    for (var i = 0u; i < min(frame.spotCount, sMax); i++) { sum += spotScatter(spotLights[i], pos, dir); }
    return sum;
}

// Every 4x4 block holds the 16 offsets once.
fn jitter(t: vec2<i32>) -> f32 {
    let x = u32(t.x) & 3u;
    let y = u32(t.y) & 3u;
    let bayer = array<u32, 16>(0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u);
    return (f32(bayer[y * 4u + x]) + 0.5) / 16.0;
}

// Denser steps near the camera.
fn stepDistance(x: f32, tMax: f32) -> f32 {
    return tMax * mix(x, x * x, 0.5);
}

/// rgb = in-scattered light, a = transmittance.
@fragment
fn fs_march(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let t = vec2<i32>(pos.xy);
    let pixel = vec2<f32>(fullTexel(t)) + 0.5;
    let uv = (pixel - p.viewport.xy) / p.viewport.zw;
    if (any(uv < vec2<f32>(-0.05)) || any(uv > vec2<f32>(1.05))) { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let far = frame.invViewProj * vec4<f32>(ndc, 1.0, 1.0);
    let dir = normalize(far.xyz / far.w - frame.cameraPos);
    let z = lowDepth(t);
    let tMax = min(z / max(dot(dir, frame.cameraForward), 1e-3), p.b.x);

    let steps = i32(p.b.y);
    let inv = 1.0 / p.b.y;
    let j = jitter(t);
    let sunOn = frame.dirEnabled != 0u && p.c.w > 0.0;
    let localOn = (frame.pointCount | frame.spotCount) != 0u && p.d.w > 0.0;
    let L = normalize(frame.dirLight.direction);
    let sun = frame.dirLight.color * frame.dirLight.intensity * p.c.w * phase(dot(dir, L), p.a.w);

    var scatter = vec3<f32>(0.0);
    var trans = 1.0;
    var t0 = 0.0;
    for (var i = 0; i < steps; i++) {
        let t1 = stepDistance((f32(i) + 1.0) * inv, tMax);
        let ds = t1 - t0;
        let pos3 = frame.cameraPos + dir * (t0 + ds * j);
        t0 = t1;
        let sigma = density(pos3.y);
        if (sigma <= 1e-7) { continue; }
        var light = p.d.rgb;
        if (sunOn) { light += sun * dirShadowTap(pos3); }
        if (localOn) { light += localScatter(pos3, dir, pixel) * p.d.w; }
        let tr = exp(-sigma * ds);
        scatter += trans * (1.0 - tr) * light;
        trans *= tr;
    }
    return vec4<f32>(scatter * p.c.rgb, trans);
}

fn blur(t: vec2<i32>, axis: vec2<i32>) -> vec4<f32> {
    let size = vec2<i32>(textureDimensions(scatterTex));
    let z = lowDepth(t);
    var sum = vec4<f32>(0.0);
    var weight = 0.0;
    // Two 4-wide boxes (a tent): cancels the jitter and leaves no block edges.
    for (var i = -3; i <= 3; i++) {
        let q = clamp(t + axis * i, vec2<i32>(0), size - vec2<i32>(1));
        let w = select(0.0, 4.0 - abs(f32(i)), abs(min(lowDepth(q), p.b.x) - min(z, p.b.x)) < 0.1 * min(z, p.b.x));
        sum += textureLoad(scatterTex, q, 0) * w;
        weight += w;
    }
    return sum / weight;
}

@fragment
fn fs_blur_x(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    return blur(vec2<i32>(pos.xy), vec2<i32>(1, 0));
}

@fragment
fn fs_blur_y(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    return blur(vec2<i32>(pos.xy), vec2<i32>(0, 1));
}

/// Blended as `color * a + rgb`.
@fragment
fn fs_composite(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let div = i32(p.b.z);
    let fp = vec2<i32>(pos.xy);
    let size = vec2<i32>(textureDimensions(scatterTex));
    let z = min(linearize(textureLoad(depthTex, fp, 0)), p.b.x);
    let low = (vec2<f32>(fp) - f32(div / 2)) / f32(div);
    let base = vec2<i32>(floor(low));
    let f = fract(low);
    var sum = vec4<f32>(0.0);
    var weight = 0.0;
    for (var k = 0; k < 4; k++) {
        let o = vec2<i32>(k & 1, k >> 1);
        let q = clamp(base + o, vec2<i32>(0), size - vec2<i32>(1));
        let b = mix(1.0 - f, f, vec2<f32>(o));
        let dz = abs(min(lowDepth(q), p.b.x) - z) / z;
        // Depth decides across edges, the bilinear weight inside a surface.
        let w = (b.x * b.y + 1e-3) / (1.0 + 4e4 * dz * dz * dz);
        sum += textureLoad(scatterTex, q, 0) * w;
        weight += w;
    }
    let r = sum / weight;
    return vec4<f32>(r.rgb, mix(1.0, r.a, p.b.w));
}
