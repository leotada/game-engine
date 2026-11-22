/// Projected deferred-style decals on the forward renderer
/// (`engine.graphics.decals.DecalRenderer`). Each instance is an oriented
/// box (unit cube, back faces only, no depth test); the fragment shader
/// reconstructs the opaque surface from the depth snapshot, projects it
/// into decal space along local Z, and lights the decal albedo / normal
/// with the scene's lights, shadows, IBL and fog. Output is premultiplied.

#include "common/pbr_brdf.wgsl"
#include "common/shadows.wgsl"
#include "common/atmosphere.wgsl"
#include "common/simple_pbr.wgsl"

@group(1) @binding(0) var opaqueDepth: texture_depth_2d;
@group(1) @binding(1) var decalSampler: sampler;
@group(1) @binding(2) var decalAlbedo: texture_2d_array<f32>;
@group(1) @binding(3) var decalNormal: texture_2d_array<f32>;

struct InstanceIn {
    @location(0) m0: vec4<f32>,
    @location(1) m1: vec4<f32>,
    @location(2) m2: vec4<f32>,
    @location(3) m3: vec4<f32>,
    @location(4) i0: vec4<f32>,
    @location(5) i1: vec4<f32>,
    @location(6) i2: vec4<f32>,
    @location(7) i3: vec4<f32>,
    @location(8) tint: vec4<f32>,
    /// x = layer, y = opacity (with fades), z = angle fade start (cos), w = normal strength.
    @location(9) params: vec4<f32>,
    /// x = roughness, y = metallic, z = wetness response, w unused.
    @location(10) params2: vec4<f32>,
};

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) @interpolate(flat) i0: vec4<f32>,
    @location(1) @interpolate(flat) i1: vec4<f32>,
    @location(2) @interpolate(flat) i2: vec4<f32>,
    @location(3) @interpolate(flat) i3: vec4<f32>,
    @location(4) @interpolate(flat) tint: vec4<f32>,
    @location(5) @interpolate(flat) params: vec4<f32>,
    @location(6) @interpolate(flat) params2: vec4<f32>,
    @location(7) @interpolate(flat) axisX: vec3<f32>,
    @location(8) @interpolate(flat) axisY: vec3<f32>,
    @location(9) @interpolate(flat) axisZ: vec3<f32>,
};

const CUBE_CORNERS = array<vec3<f32>, 8>(
    vec3<f32>(-0.5, -0.5, -0.5), vec3<f32>(0.5, -0.5, -0.5),
    vec3<f32>(-0.5, 0.5, -0.5), vec3<f32>(0.5, 0.5, -0.5),
    vec3<f32>(-0.5, -0.5, 0.5), vec3<f32>(0.5, -0.5, 0.5),
    vec3<f32>(-0.5, 0.5, 0.5), vec3<f32>(0.5, 0.5, 0.5));

/// 12 triangles, counter-clockwise seen from outside.
const CUBE_INDICES = array<u32, 36>(
    0u, 2u, 1u, 1u, 2u, 3u,   // -Z
    4u, 5u, 6u, 5u, 7u, 6u,   // +Z
    0u, 4u, 2u, 2u, 4u, 6u,   // -X
    1u, 3u, 5u, 3u, 7u, 5u,   // +X
    0u, 1u, 4u, 1u, 5u, 4u,   // -Y
    2u, 6u, 3u, 3u, 6u, 7u);  // +Y

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, inst: InstanceIn) -> VsOut {
    let model = mat4x4<f32>(inst.m0, inst.m1, inst.m2, inst.m3);
    let corner = CUBE_CORNERS[CUBE_INDICES[vi % 36u]];
    var out: VsOut;
    out.pos = frame.viewProj * model * vec4<f32>(corner, 1.0);
    out.i0 = inst.i0;
    out.i1 = inst.i1;
    out.i2 = inst.i2;
    out.i3 = inst.i3;
    out.tint = inst.tint;
    out.params = inst.params;
    out.params2 = inst.params2;
    out.axisX = normalize(inst.m0.xyz);
    out.axisY = normalize(inst.m1.xyz);
    out.axisZ = normalize(inst.m2.xyz);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let dims = vec2<f32>(textureDimensions(opaqueDepth));
    let pix = vec2<i32>(in.pos.xy);
    let depth = textureLoad(opaqueDepth, pix, 0);
    let uv = in.pos.xy / dims;
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let wh = frame.invViewProj * ndc;
    let P = wh.xyz / wh.w;
    // Derivatives before any discard (uniform control flow).
    let dPx = dpdx(P);
    let dPy = dpdy(P);

    let invModel = mat4x4<f32>(in.i0, in.i1, in.i2, in.i3);
    let local = (invModel * vec4<f32>(P, 1.0)).xyz;
    let duvx = (invModel * vec4<f32>(dPx, 0.0)).xy;
    let duvy = (invModel * vec4<f32>(dPy, 0.0)).xy;
    let a = abs(local);
    if (depth >= 1.0 || a.x > 0.5 || a.y > 0.5 || a.z > 0.5) {
        discard;
    }

    var Ng = cross(dPy, dPx);
    let nlen = length(Ng);
    Ng = select(in.axisZ, Ng / max(nlen, 1e-8), nlen > 1e-10);
    if (dot(Ng, in.axisZ) < 0.0) {
        Ng = -Ng;
    }
    let facing = dot(Ng, in.axisZ);
    let angleFade = smoothstep(in.params.z, min(in.params.z + 0.25, 1.0), facing);
    let edge = (1.0 - smoothstep(0.42, 0.5, max(a.x, a.y))) * (1.0 - smoothstep(0.3, 0.5, a.z));

    let duv = vec2<f32>(local.x + 0.5, 0.5 - local.y);
    let layer = i32(in.params.x);
    let alb = textureSampleGrad(decalAlbedo, decalSampler, duv, layer, duvx * vec2<f32>(1.0, -1.0), duvy * vec2<f32>(1.0, -1.0));
    let alpha = clamp(alb.a * in.tint.a * in.params.y * angleFade * edge, 0.0, 1.0);
    if (alpha < 0.002) {
        discard;
    }
    let tn = textureSampleGrad(decalNormal, decalSampler, duv, layer, duvx * vec2<f32>(1.0, -1.0), duvy * vec2<f32>(1.0, -1.0)).xyz * 2.0 - 1.0;
    // Tangent frame: decal X / Y projected onto the surface.
    let T = normalize(in.axisX - Ng * dot(in.axisX, Ng));
    let B = cross(Ng, T);
    var N = normalize(T * tn.x * in.params.w + B * tn.y * in.params.w + Ng * max(tn.z, 0.2));

    var albedo = alb.rgb * in.tint.rgb;
    var roughness = clamp(in.params2.x, 0.04, 1.0);
    let metallic = clamp(in.params2.y, 0.0, 1.0);
    let wet = clamp(frame.globalWetness, 0.0, 1.0) * smoothstep(0.3, 0.8, Ng.y) * in.params2.z;
    albedo *= mix(1.0, 0.6, wet);
    roughness = mix(roughness, 0.1, wet * 0.85);

    let V = normalize(frame.cameraPos - P);
    var color = shadeSimplePbr(P, N, Ng, V, in.pos.xy, albedo, metallic, roughness, 1.0);
    color = applyFog(color, P);
    return vec4<f32>(color * alpha, alpha);
}
