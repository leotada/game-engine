/// Engine sky: fullscreen triangle at the far plane (`lessEqual`, no depth
/// write), drawn after opaque geometry. Reads only `@group(0)` frame data:
/// sun from `dirLight`, `moonDir`, `skyParams` (x = stars, y = exposure),
/// `cloudCoverage`, `time`; the view ray comes from `invViewProj`.
/// Atmospheric fog is applied toward the horizon so the sky meets fogged
/// terrain without a seam.

#include "common/pbr_brdf.wgsl"
#include "common/shadows.wgsl"
#include "common/atmosphere.wgsl"
#include "common/sky_eval.wgsl"

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

fn frameSkyInputs() -> SkyInputs {
    var s: SkyInputs;
    if (frame.skySunDir.w > 0.5) {
        s.sunDir = normalize(frame.skySunDir.xyz);
        s.sunColor = frame.skySunColor.rgb;
    } else {
        s.sunDir = normalize(frame.dirLight.direction);
        s.sunColor = select(vec3<f32>(0.0), frame.dirLight.color, frame.dirEnabled != 0u);
    }
    s.moonDir = frame.moonDir.xyz;
    s.moonIntensity = frame.moonDir.w;
    s.starIntensity = frame.skyParams.x;
    s.cloudCoverage = frame.cloudCoverage;
    s.time = frame.time;
    s.exposure = frame.skyParams.y;
    return s;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let far = frame.invViewProj * vec4<f32>(in.ndc, 1.0, 1.0);
    let dir = normalize(far.xyz / far.w - frame.cameraPos);
    var col = evalSky(dir, frameSkyInputs());
    // Fog along the ray up to the far plane (height falloff keeps the zenith clear).
    let f = fogAmount(frame.cameraPos + dir * frame.cameraFar);
    col = mix(col, fogColorFor(dir), f);
    return vec4<f32>(col, 1.0);
}
