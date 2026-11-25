/// Linear HDR atmospheric fog: exponential height fog integrated
/// analytically along the camera ray, plus a sun in-scattering lobe.
/// Requires `common/shadows.wgsl` (the `frame` uniforms) to be included first.
///
///   density(h) = fogColorDensity.w * exp(-fogHeight.y * (h - fogHeight.x))
///
/// Applied in the fragment shader before output, so it happens ahead of
/// bloom and tone mapping. `fogColorDensity.w == 0` disables it.

/// Fog opacity in [0, fogHeight.w] for a surface at `worldPos`.
fn fogAmount(worldPos: vec3<f32>) -> f32 {
    let density = frame.fogColorDensity.w;
    if (density <= 0.0) {
        return 0.0;
    }
    let toP = worldPos - frame.cameraPos;
    let dist = length(toP);
    let fogged = max(dist - frame.fogHeight.z, 0.0);
    if (fogged <= 0.0) {
        return 0.0;
    }
    let falloff = max(frame.fogHeight.y, 1e-5);
    // Height of the point where the fogged segment starts, relative to the base.
    let t0 = 1.0 - fogged / max(dist, 1e-4);
    let startH = frame.cameraPos.y + toP.y * t0 - frame.fogHeight.x;
    // Vertical rise over the fogged segment.
    let rise = toP.y * (1.0 - t0);
    let k = falloff * rise;
    var integral = fogged * density * exp(clamp(-falloff * startH, -80.0, 40.0));
    if (abs(k) > 1e-4) {
        integral = integral * (1.0 - exp(clamp(-k, -80.0, 40.0))) / k;
    }
    return clamp(1.0 - exp(-integral), 0.0, frame.fogHeight.w);
}

/// In-scattered fog color seen along `viewDir` (camera → surface).
fn fogColorFor(viewDir: vec3<f32>) -> vec3<f32> {
    var c = frame.fogColorDensity.rgb;
    if (frame.dirEnabled != 0u && frame.fogSun.w > 0.0) {
        let lobe = pow(max(dot(viewDir, normalize(frame.dirLight.direction)), 0.0), frame.fogSun.w);
        c = c + frame.fogSun.rgb * lobe;
    }
    return c;
}

/// Blend `color` (linear HDR) toward the fog color for a surface at `worldPos`.
fn applyFog(color: vec3<f32>, worldPos: vec3<f32>) -> vec3<f32> {
    let f = fogAmount(worldPos);
    if (f <= 0.0) {
        return color;
    }
    let v = normalize(worldPos - frame.cameraPos);
    return mix(color, fogColorFor(v), f);
}

/// Scene alpha of an opaque surface with GTAO: 1 - ambient share of `color`.
fn ambientAlpha(ambient: vec3<f32>, color: vec3<f32>) -> f32 {
    let w = vec3<f32>(0.2126, 0.7152, 0.0722);
    return 1.0 - clamp(dot(ambient, w) / max(dot(color, w), 1e-5), 0.0, 1.0);
}

/// Fog for additive / premultiplied contributions: only attenuates.
fn attenuateByFog(color: vec3<f32>, worldPos: vec3<f32>) -> vec3<f32> {
    return color * (1.0 - fogAmount(worldPos));
}
