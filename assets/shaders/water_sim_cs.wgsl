/// WTR-6 Compute Shader: 256x256 JONSWAP directional capillary spectrum +
/// semi-Lagrangian ping-pong advected obstacle wake & foam persistence.

#include "common/water_env.wgsl"

@group(0) @binding(0) var<uniform> wu: WaterUniforms;
@group(0) @binding(1) var prevSimTex: texture_2d<f32>;
@group(0) @binding(2) var simSampler: sampler;
@group(0) @binding(3) var nextSimTex: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn cs_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x >= 256u || gid.y >= 256u) {
        return;
    }

    let time = wu.params0.x;
    let waveScale = wu.params0.y;
    let riverMode = wu.flags0.x;
    let halfSpan = max(wu.camUp.w, 14.0);
    let span = halfSpan * 2.0;

    let uv = (vec2<f32>(gid.xy) + vec2<f32>(0.5)) / 256.0;
    let xz = (uv - vec2<f32>(0.5)) * span;

    // 1. Directional JONSWAP short-chop wave spectrum (12 modes, non-repeating spread).
    var slopeX = 0.0;
    var slopeZ = 0.0;
    var crestAccum = 0.0;
    let goldenAngle = 2.39996323;
    let windBias = select(vec2<f32>(0.76, 0.48), vec2<f32>(0.94, 0.12), riverMode != 0u);
    for (var m = 0u; m < 12u; m++) {
        let fm = f32(m);
        let theta = fm * goldenAngle + 0.35;
        let dirRaw = vec2<f32>(cos(theta), sin(theta)) * 0.55 + windBias * 0.65;
        let dir = normalize(dirRaw);
        // Wavenumber progression k from 1.8 to 18.0 rad/m (wavelength ~3.5m down to ~0.35m).
        let k = 1.8 * pow(1.23, fm);
        let omega = sqrt(9.81 * k);
        // JONSWAP-like energy peak weighting.
        let kp = 4.2;
        let rel = kp / k;
        let specAmp = 0.011 * waveScale * pow(k / 1.8, -1.35) * exp(-1.25 * rel * rel);
        let phase = dot(xz, dir) * k - omega * time + fm * 1.37;
        let cs = cos(phase);
        let sn = sin(phase);
        let dH = k * specAmp * cs;
        slopeX += dir.x * dH;
        slopeZ += dir.y * dH;
        crestAccum += max(sn, 0.0) * (specAmp * 28.0);
    }

    // 2. Tangential flow velocity deflected around channel obstacles.
    var flow = select(vec2<f32>(0.24, 0.14), vec2<f32>(1.45, 0.0), riverMode != 0u);
    if (riverMode != 0u) {
        let bankAtten = clamp(1.0 - pow(abs(xz.y) / 6.8, 2.0) * 0.55, 0.35, 1.05);
        flow.x *= bankAtten;
    }

    var injectFoam = clamp((crestAccum - 0.55) * 0.45, 0.0, 0.65) * clamp(waveScale * 0.7, 0.25, 1.2);
    var injectWake = 0.0;
    let obsCount = min(wu.counts.x, 16u);
    for (var i = 0u; i < obsCount; i++) {
        let ob = wu.obstacles[i];
        let rel = xz - ob.xy;
        let r = max(ob.z, 0.25);
        let dist = length(rel);
        if (dist > 0.05 && dist < r * 3.4) {
            let nDir = rel / dist;
            let falloff = (r * r) / max(dist * dist, r * r * 0.35);
            flow -= nDir * dot(flow, nDir) * min(falloff, 0.92) * ob.w;
        }
        // Bow collision ring + downstream turbulent shear wake source.
        let bow = 1.0 - smoothstep(r * 0.55, r * 1.15, dist);
        let shearSide = 1.0 - smoothstep(r * 0.35, r * 1.15, abs(abs(rel.y) - r * 0.62));
        let behind = select(0.0, (1.0 - smoothstep(0.0, r * 1.6, rel.x)) * step(-r * 0.3, rel.x), riverMode != 0u);
        let wakeSrc = max(bow * 0.65, shearSide * behind * 0.72) * ob.w;
        injectFoam = max(injectFoam, wakeSrc);
        injectWake = max(injectWake, sin(dist * 7.5 - time * 6.5) * bow * 0.5 * ob.w);
    }

    // 3. Semi-Lagrangian advection back-trace into previous simulation step.
    let dtSim = 1.0 / 60.0;
    let prevUv = clamp(uv - (flow * dtSim) / span, vec2<f32>(0.002), vec2<f32>(0.998));
    let prevState = textureSampleLevel(prevSimTex, simSampler, prevUv, 0.0);

    let decayFoam = select(0.955, 0.968, riverMode != 0u);
    let foam = clamp(max(prevState.b * decayFoam, injectFoam), 0.0, 1.0);
    let wakeH = clamp(prevState.a * 0.94 + injectWake * 0.25, -0.5, 0.5);

    textureStore(nextSimTex, vec2<i32>(gid.xy), vec4<f32>(slopeX, slopeZ, foam, wakeH));
}
