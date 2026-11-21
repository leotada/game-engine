/// Runtime HDR IBL (`engine.gpu.ibl_dynamic.DynamicIbl`): renders the engine
/// sky into an rgba16float environment cube, then convolves irradiance and
/// GGX-prefiltered specular mips. One entry point per amortized step.
///
/// Cube faces are written through `texture_storage_2d_array` views (6 layers).

#include "common/sky_eval.wgsl"

struct IblParams {
    /// xyz = sun direction, w = moon intensity.
    sunDir: vec4<f32>,
    /// xyz = sun color, w = star intensity.
    sunColor: vec4<f32>,
    /// xyz = moon direction, w = cloud coverage.
    moonDir: vec4<f32>,
    /// x = time, y = exposure, z = roughness, w = output face size.
    misc: vec4<f32>,
};

@group(0) @binding(0) var<uniform> P: IblParams;
@group(0) @binding(1) var srcCube: texture_cube<f32>;
@group(0) @binding(2) var srcSampler: sampler;
@group(0) @binding(3) var dst: texture_storage_2d_array<rgba16float, write>;

const PI: f32 = 3.14159265;

/// Face direction for `uv` in [-1, 1] (v down), matching the CPU upload order
/// +X, -X, +Y, -Y, +Z, -Z.
fn cubeFaceDir(face: u32, uv: vec2<f32>) -> vec3<f32> {
    let u = uv.x;
    let v = uv.y;
    var d = vec3<f32>(-u, -v, -1.0);
    switch (face) {
        case 0u: { d = vec3<f32>(1.0, -v, -u); }
        case 1u: { d = vec3<f32>(-1.0, -v, u); }
        case 2u: { d = vec3<f32>(u, 1.0, v); }
        case 3u: { d = vec3<f32>(u, -1.0, -v); }
        case 4u: { d = vec3<f32>(u, -v, 1.0); }
        default: {}
    }
    return d;
}

fn texelDir(id: vec3<u32>, size: u32) -> vec3<f32> {
    let uv = (vec2<f32>(id.xy) + vec2<f32>(0.5)) / f32(size) * 2.0 - vec2<f32>(1.0);
    return normalize(cubeFaceDir(id.z, uv));
}

fn hammersley(i: u32, n: u32) -> vec2<f32> {
    return vec2<f32>(f32(i) / f32(n), f32(reverseBits(i)) * 2.3283064365386963e-10);
}

fn tangentFrame(N: vec3<f32>, h: vec3<f32>) -> vec3<f32> {
    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, 1.0), abs(N.z) < 0.999);
    let t = normalize(cross(up, N));
    let b = cross(N, t);
    return normalize(t * h.x + b * h.y + N * h.z);
}

@compute @workgroup_size(8, 8, 1)
fn cs_sky(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = u32(P.misc.w);
    if (id.x >= size || id.y >= size) {
        return;
    }
    var s: SkyInputs;
    s.sunDir = P.sunDir.xyz;
    s.sunColor = P.sunColor.xyz;
    s.moonDir = P.moonDir.xyz;
    s.moonIntensity = P.sunDir.w;
    s.starIntensity = P.sunColor.w;
    s.cloudCoverage = P.moonDir.w;
    s.time = P.misc.x;
    s.exposure = P.misc.y;
    // The HDR sun disc would alias in a 64² cube and blow up the specular
    // mips: clamp radiance (direct sun comes from the directional light).
    let c = min(evalSky(texelDir(id, size), s), vec3<f32>(6.0));
    textureStore(dst, vec2<i32>(id.xy), i32(id.z), vec4<f32>(c, 1.0));
}

@compute @workgroup_size(8, 8, 1)
fn cs_irradiance(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = u32(P.misc.w);
    if (id.x >= size || id.y >= size) {
        return;
    }
    let N = texelDir(id, size);
    let n = 128u;
    var sum = vec3<f32>(0.0);
    for (var i = 0u; i < n; i++) {
        let xi = hammersley(i, n);
        let phi = 2.0 * PI * xi.x;
        let cosT = sqrt(1.0 - xi.y);
        let sinT = sqrt(xi.y);
        let L = tangentFrame(N, vec3<f32>(cos(phi) * sinT, sin(phi) * sinT, cosT));
        sum += textureSampleLevel(srcCube, srcSampler, L, 0.0).rgb;
    }
    textureStore(dst, vec2<i32>(id.xy), i32(id.z), vec4<f32>(sum / f32(n), 1.0));
}

@compute @workgroup_size(8, 8, 1)
fn cs_specular(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = u32(P.misc.w);
    if (id.x >= size || id.y >= size) {
        return;
    }
    let R = texelDir(id, size);
    let roughness = P.misc.z;
    if (roughness < 0.01) {
        textureStore(dst, vec2<i32>(id.xy), i32(id.z), vec4<f32>(textureSampleLevel(srcCube, srcSampler, R, 0.0).rgb, 1.0));
        return;
    }
    let a = roughness * roughness;
    let n = 64u;
    var sum = vec3<f32>(0.0);
    var weight = 0.0;
    for (var i = 0u; i < n; i++) {
        let xi = hammersley(i, n);
        let phi = 2.0 * PI * xi.x;
        let cosT = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
        let sinT = sqrt(1.0 - cosT * cosT);
        let H = tangentFrame(R, vec3<f32>(cos(phi) * sinT, sin(phi) * sinT, cosT));
        let L = normalize(2.0 * dot(R, H) * H - R);
        let ndl = dot(R, L);
        if (ndl > 0.0) {
            sum += textureSampleLevel(srcCube, srcSampler, L, 0.0).rgb * ndl;
            weight += ndl;
        }
    }
    textureStore(dst, vec2<i32>(id.xy), i32(id.z), vec4<f32>(sum / max(weight, 1e-4), 1.0));
}
