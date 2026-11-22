/// `SkyInputs` from the frame uniforms: the visible sky (`sky.wgsl`) and every
/// surface that reflects it (water) evaluate `evalSky` with the same inputs,
/// so reflections match the sky exactly.
///
/// Requires `common/shadows.wgsl` (frame uniforms) and `common/sky_eval.wgsl`.

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

/// Engine sky radiance along `dir` for the current frame.
fn frameSky(dir: vec3<f32>) -> vec3<f32> {
    return evalSky(dir, frameSkyInputs());
}
