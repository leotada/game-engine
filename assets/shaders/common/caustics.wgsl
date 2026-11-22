/// Sun caustics on any surface under water: animated, chromatically dispersed
/// Voronoi light webs projected along the sun direction, for fragments below
/// the level of a water body with caustics enabled (`WaterBody.causticsStrength`).
/// Used by `textured3d_pbr.wgsl` and `common/simple_pbr.wgsl` (terrain, decals).
///
/// Requires `common/shadows.wgsl` (frame uniforms) and `common/waves.wgsl`.

fn causticHash22(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// One Voronoi cell-edge layer (single sample -> organic light web).
fn causticVoronoiLayer(uv: vec2<f32>) -> f32 {
    let i = floor(uv);
    let f = fract(uv);
    var md1 = 8.0;
    var md2 = 8.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let g = vec2<f32>(f32(x), f32(y));
            let o = 0.5 + 0.42 * sin(causticHash22(i + g) * 6.283185 + vec2<f32>(0.0, 1.57));
            let r = g + o - f;
            let d = dot(r, r);
            if (d < md1) {
                md2 = md1;
                md1 = d;
            } else if (d < md2) {
                md2 = d;
            }
        }
    }
    let edge = sqrt(md2) - sqrt(md1);
    let soft = smoothstep(0.0, 0.72, 1.0 - edge * 1.05);
    return pow(soft, 2.2) * 0.75 + soft * 0.25;
}

/// RGB caustic pattern at `rel` (position relative to the water level, so
/// `-rel.y` is the depth). `flowUv` scrolls the pattern with the current.
fn causticPatternRgb(rel: vec3<f32>, sunDir: vec3<f32>, time: f32, flowUv: vec2<f32>) -> vec3<f32> {
    let refractShift = (sunDir.xz / max(abs(sunDir.y) + 0.35, 0.35)) * (-rel.y * 0.45);
    let p = rel.xz + refractShift;
    // Smooth organic wave distortion breaks rigid straight Voronoi cell walls.
    let warp = vec2<f32>(
        sin(p.y * 1.25 + time * 1.15) + cos(p.x * 0.80 - time * 0.85),
        cos(p.x * 1.20 - time * 1.05) + sin(p.y * 0.85 + time * 0.75)
    ) * 0.30;

    let baseUv = (p + warp) * 1.35 + flowUv;
    let uv2    = (p - warp * 0.7) * 2.05 - flowUv * vec2<f32>(0.65, 1.15);

    let disp = vec2<f32>(0.014, 0.009);
    let cR = 0.58 * causticVoronoiLayer(baseUv + disp) + 0.42 * causticVoronoiLayer(uv2 - disp);
    let cG = 0.58 * causticVoronoiLayer(baseUv)        + 0.42 * causticVoronoiLayer(uv2);
    let cB = 0.58 * causticVoronoiLayer(baseUv - disp) + 0.42 * causticVoronoiLayer(uv2 + disp);
    return max(vec3<f32>(cR, cG, cB) - vec3<f32>(0.30), vec3<f32>(0.0)) * 1.15;
}

/// Caustic light factor at `P` (normal `N`, sun direction `sunDir`, toward the
/// sun), already multiplied by the sun `shadow`. Multiply by the sun radiance
/// and the surface albedo. Zero above the water, outside every body, or when
/// caustics are off. Cheap tests run first; the pattern (six Voronoi layers)
/// is only evaluated where it can show.
fn waterCausticsAt(P: vec3<f32>, N: vec3<f32>, sunDir: vec3<f32>, shadow: f32) -> vec3<f32> {
    if (shadow <= 0.001 || N.y <= 0.0) {
        return vec3<f32>(0.0);
    }
    let found = waterBodyAt(P.xz);
    if (found < 0) {
        return vec3<f32>(0.0);
    }
    let bi = u32(found);
    let level = waterLevel(bi);
    let depth = level - P.y;
    if (depth <= 0.20 || (waterFlags(bi) & WATER_FLAG_CAUSTICS) == 0u) {
        return vec3<f32>(0.0);
    }
    let misc = waterData.bodies[bi].misc;   // x = reach, y = strength, z = flow speed
    let t = frame.time;
    var flowUv = vec2<f32>(t * 0.22, t * 0.14);   // slow ocean drift
    var channelMask = 1.0;
    if (misc.z > 0.0) {
        // River: scroll with the current along the channel, fade on the banks.
        let ch = waterData.bodies[bi].channelB;
        let dir = ch.zw;
        let perp = vec2<f32>(-dir.y, dir.x);
        flowUv = -dir * (t * 0.652 * misc.z) + perp * (sin(t * 0.7) * 0.08);
        let halfWidth = waterData.bodies[bi].channelA.y;
        if (halfWidth > 0.0) {
            channelMask = smoothstep(halfWidth + 2.7, halfWidth + 0.3, waterChannelDistance(bi, P.xz));
            if (channelMask <= 0.0) {
                return vec3<f32>(0.0);
            }
        }
    }
    let pattern = causticPatternRgb(P - vec3<f32>(0.0, level, 0.0), sunDir, t, flowUv);
    let depthFocus = smoothstep(0.20, 0.85, depth);
    let waveEnergy = 0.65 + 0.35 * waterData.bodies[bi].surface.y;
    return pattern * (N.y * channelMask * depthFocus * waveEnergy * misc.y * shadow);
}
