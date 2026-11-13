/// Procedural atmospheric sky dome with clouds, solar disc, and sun halo.
/// Rendered at far depth (`z = 0.999999`, `lessEqual`, no depth write) behind opaque geometry.

#include "common/pbr_brdf.wgsl"
#include "common/shadows.wgsl"
#include "common/water_env.wgsl"

@group(1) @binding(0) var<uniform> wu: WaterUniforms;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) ndc: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    var out: VsOut;
    let x = f32(i32(vi) / 2) * 4.0 - 1.0;
    let y = f32(i32(vi) % 2) * 4.0 - 1.0;
    out.pos = vec4<f32>(x, y, 0.999999, 1.0);
    out.ndc = vec2<f32>(x, y);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let tanHalfFov = wu.camForward.w;
    let aspect = wu.camRight.w;
    let rayDir = normalize(
        wu.camForward.xyz
        + wu.camRight.xyz * (in.ndc.x * aspect * tanHalfFov)
        + wu.camUp.xyz * (in.ndc.y * tanHalfFov)
    );
    let sunDir = normalize(frame.dirLight.direction);
    let col = evalWaterSky(rayDir, sunDir, frame.dirLight.color, wu.flags0.w, wu.params0.x);
    return vec4<f32>(col, 1.0);
}
