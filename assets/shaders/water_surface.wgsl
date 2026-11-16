/// High-detail realistic water shader running single-pass in OpenPBR v1.1:
/// - GPU 6-octave Gerstner wave displacement & analytical tangent frame
/// - 4-octave procedural capillary micro-normals with river streamline deflection
/// - Analytical Beer-Lambert column depth tint & shallow bank/rock clarity
/// - Backlit wave-crest subsurface scattering (SSS)
/// - Crisp lacy procedural crest whitecaps + obstacle wakes & opaque foam alpha
/// - Coherent procedural sky/sun reflection matching sky_dome.wgsl + shadow PCF

#include "common/pbr_brdf.wgsl"
#include "common/shadows.wgsl"
#include "common/water_env.wgsl"

@group(1) @binding(0) var<uniform> wu: WaterUniforms;
@group(1) @binding(1) var sceneColorMap: texture_2d<f32>;
@group(1) @binding(2) var sceneDepthMap: texture_depth_2d;
@group(1) @binding(3) var sceneLinearSampler: sampler;

@group(2) @binding(0) var irradianceMap: texture_cube<f32>;
@group(2) @binding(1) var specularMap: texture_cube<f32>;
@group(2) @binding(2) var brdfLut: texture_2d<f32>;
@group(2) @binding(3) var iblSampler: sampler;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldPos: vec3<f32>,
    @location(1) worldNormal: vec3<f32>,
    @location(2) worldTangent: vec3<f32>,
    @location(3) crestFactor: f32,
    @location(4) baseXZ: vec2<f32>,
};

@vertex
fn vs_main(v: VertexInput) -> VertexOutput {
    let time = wu.params0.x;
    let waveScale = wu.params0.y;
    let riverMode = wu.flags0.x;
    let waveCount = min(wu.counts.y, 6u);

    let x0 = v.position.x;
    let z0 = v.position.z;

    // WTR-5: Expand outer skirt toward the atmospheric horizon in Ocean mode while keeping
    // high vertex density in the 28m interaction zone around rocks, buoys, and shoreline.
    var x = x0;
    var z = z0;
    var distAtten = 1.0;
    if (riverMode == 0u) {
        let cheb = max(abs(v.uv.x - 0.5), abs(v.uv.y - 0.5)) * 2.0;
        let tSkirt = clamp((cheb - 0.72) / 0.28, 0.0, 1.0);
        let skirtScale = mix(1.0, 10.714, tSkirt * tSkirt * tSkirt);
        x = x0 * skirtScale;
        z = z0 * skirtScale;
        distAtten = 1.0 - smoothstep(18.0, 125.0, length(vec2<f32>(x, z))) * 0.92;
    }

    var bankMask = 1.0;
    if (riverMode != 0u) {
        let az = abs(z);
        if (az > 4.5) {
            let t = clamp((az - 4.5) / 3.5, 0.0, 1.0);
            bankMask = 1.0 - t * 0.85;
        }
    }

    // Slight turbulent chop boost near mid-channel emergent boulders in river mode.
    var rockChop = 1.0;
    let obsCount = min(wu.counts.x, 16u);
    for (var oi = 0u; oi < obsCount; oi++) {
        let ob = wu.obstacles[oi];
        let d = length(vec2<f32>(x, z) - ob.xy);
        let boost = (1.0 - smoothstep(ob.z * 0.6, ob.z * 2.2, d)) * ob.w;
        rockChop += boost * select(0.20, 0.38, riverMode != 0u);
    }

    var p = vec3<f32>(x, 0.0, z);
    var dPdx = vec3<f32>(1.0, 0.0, 0.0);
    var dPdz = vec3<f32>(0.0, 0.0, 1.0);
    var crestAccum = 0.0;

    for (var i = 0u; i < waveCount; i++) {
        let wa = wu.wavesA[i];
        let wb = wu.wavesB[i];
        let dirX = wa.x;
        let dirZ = wa.y;
        let k = (2.0 * PI) / max(wa.z, 0.1);
        let c = sqrt(9.81 / k) * wb.y;
        let a = wa.w * waveScale * bankMask * rockChop * distAtten;
        let q = wb.x;

        let phase = k * (dirX * x + dirZ * z) - k * c * time;
        let sn = sin(phase);
        let cs = cos(phase);

        let qa = q * a;
        p.x += qa * dirX * cs;
        p.y += a * sn;
        p.z += qa * dirZ * cs;

        // Sharp crests occur at the wave peaks (sn -> 1) and horizontal compression.
        crestAccum += (sn * 0.5 + 0.5) * (0.65 + 0.35 * q);

        let kAmp = k * a;
        let qkAmp = q * kAmp;
        dPdx.x -= qkAmp * dirX * dirX * sn;
        dPdx.y += kAmp * dirX * cs;
        dPdx.z -= qkAmp * dirX * dirZ * sn;

        dPdz.x -= qkAmp * dirX * dirZ * sn;
        dPdz.y += kAmp * dirZ * cs;
        dPdz.z -= qkAmp * dirZ * dirZ * sn;
    }

    let N = normalize(cross(dPdz, dPdx));
    var T = normalize(dPdx);
    T = normalize(T - N * dot(N, T));

    // WTR-6: Gerstner surface Jacobian captures horizontal wave-crest compression/folding.
    let jacobian = dPdx.x * dPdz.z - dPdx.z * dPdz.x;
    let foldCrest = clamp((0.88 - jacobian) * 1.35, 0.0, 1.0);
    let waveCrest = crestAccum / max(f32(waveCount), 1.0);

    var out: VertexOutput;
    out.worldPos = p;
    out.worldNormal = N;
    out.worldTangent = T;
    out.crestFactor = clamp(max(waveCrest, foldCrest), 0.0, 1.0);
    out.baseXZ = vec2<f32>(x, z);
    out.clipPos = frame.viewProj * vec4<f32>(p, 1.0);
    return out;
}

/// Evaluates analytical streamline deflection + wakes around boulders and piers.
fn evalRiverFlowAndWake(xz: vec2<f32>, riverMode: u32, time: f32,
                        obstacles: array<vec4<f32>, 16>, obsCount: u32) -> vec3<f32> {
    var flow = select(vec2<f32>(0.22, 0.14), vec2<f32>(1.35, 0.0), riverMode != 0u);
    var wakeMask = 0.0;
    var contactMask = 0.0;

    if (riverMode != 0u) {
        // Poiseuille-like channel profile: fastest in center, calmer near banks.
        let centerFactor = clamp(1.0 - pow(abs(xz.y) / 6.8, 2.0) * 0.55, 0.35, 1.05);
        flow.x *= centerFactor;
    }

    let cnt = min(obsCount, 16u);
    for (var i = 0u; i < cnt; i++) {
        let ob = obstacles[i];
        let rel = xz - ob.xy;
        let r = max(ob.z, 0.25);
        let dist = length(rel);

        // Tangential streamline deflection around cylindrical rock/pier approximation.
        if (dist > 0.05 && dist < r * 3.2) {
            let dir = rel / dist;
            let falloff = (r * r) / max(dist * dist, r * r * 0.35);
            flow -= dir * dot(flow, dir) * min(falloff, 0.92) * ob.w;
        }

        // Organic bubbly contact collar right at the rock/pier waterline.
        let jitter = (valueNoise2(xz * 3.1 + vec2<f32>(time * 0.35, -time * 0.2)) - 0.5) * r * 0.32;
        let ring = 1.0 - smoothstep(r * 0.45, r * 0.94, dist + jitter);
        contactMask = max(contactMask, ring * ob.w);

        // Downstream +X turbulent V-wake + oscillating vortex ripples behind river obstacles.
        if (riverMode != 0u && rel.x > -r * 0.20 && rel.x < r * 4.8) {
            let downT = clamp((rel.x + r * 0.20) / (r * 4.8), 0.0, 1.0);
            let wakeHalfW = r * (0.58 + downT * 0.92);
            let vRipple = 0.72 + 0.28 * sin(rel.x * 5.2 - abs(rel.y) * 4.0 - time * 6.5);
            let zFit = 1.0 - smoothstep(wakeHalfW * 0.28, wakeHalfW, abs(rel.y));
            let axialFade = (1.0 - downT) * smoothstep(0.0, 0.14, downT + 0.08);
            wakeMask = max(wakeMask, zFit * axialFade * ob.w * 0.92 * vRipple);
        }
    }

    return vec3<f32>(flow.x, flow.y, clamp(max(contactMask, wakeMask), 0.0, 1.0));
}

/// 4-octave animated procedural capillary wavelets (dual-advected in river mode).
fn evalCapillaryOffset(xz: vec2<f32>, flowVel: vec2<f32>, time: f32,
                       riverMode: u32, waveScale: f32) -> vec2<f32> {
    var dH = vec2<f32>(0.0);

    if (riverMode != 0u) {
        // Dual-phase flow advection prevents UV stretch while preserving directional current.
        let phaseDur = 2.6;
        let p0 = fract(time / phaseDur);
        let p1 = fract(p0 + 0.5);
        let blendW = abs(2.0 * p0 - 1.0);

        let uvA = (xz - flowVel * (p0 * phaseDur)) * vec2<f32>(0.85, 1.35);
        let uvB = (xz - flowVel * (p1 * phaseDur)) * vec2<f32>(0.85, 1.35) + vec2<f32>(3.7, 7.1);

        let e = 0.035;
        let fA = fbm2(uvA * 1.55) * 0.65 + fbm2(uvA * 3.8 + vec2<f32>(time * 0.4, -time * 0.25)) * 0.35;
        let fAx = fbm2((uvA + vec2<f32>(e, 0.0)) * 1.55) * 0.65 + fbm2((uvA + vec2<f32>(e, 0.0)) * 3.8 + vec2<f32>(time * 0.4, -time * 0.25)) * 0.35;
        let fAz = fbm2((uvA + vec2<f32>(0.0, e)) * 1.55) * 0.65 + fbm2((uvA + vec2<f32>(0.0, e)) * 3.8 + vec2<f32>(time * 0.4, -time * 0.25)) * 0.35;

        let fB = fbm2(uvB * 1.55) * 0.65 + fbm2(uvB * 3.8 + vec2<f32>(-time * 0.3, time * 0.35)) * 0.35;
        let fBx = fbm2((uvB + vec2<f32>(e, 0.0)) * 1.55) * 0.65 + fbm2((uvB + vec2<f32>(e, 0.0)) * 3.8 + vec2<f32>(-time * 0.3, time * 0.35)) * 0.35;
        let fBz = fbm2((uvB + vec2<f32>(0.0, e)) * 1.55) * 0.65 + fbm2((uvB + vec2<f32>(0.0, e)) * 3.8 + vec2<f32>(-time * 0.3, time * 0.35)) * 0.35;

        let gA = vec2<f32>(fAx - fA, fAz - fA) / e;
        let gB = vec2<f32>(fBx - fB, fBz - fB) / e;
        dH = mix(gA, gB, blendW) * (0.042 + 0.025 * waveScale);
    } else {
        // Multi-directional crossing ocean capillary ripples (spatial freq 2.1 -> 14.5 rad/m).
        let dirs = array<vec2<f32>, 4>(
            vec2<f32>( 0.89,  0.45),
            vec2<f32>(-0.52,  0.85),
            vec2<f32>( 0.31, -0.95),
            vec2<f32>(-0.91, -0.41)
        );
        let freqs = array<f32, 4>(2.3, 4.9, 9.4, 16.2);
        let speeds = array<f32, 4>(1.8, 2.7, 3.9, 5.1);
        let amps = array<f32, 4>(0.026, 0.015, 0.0085, 0.0045);

        let gust = 0.65 + 0.55 * valueNoise2(xz * 0.22 + vec2<f32>(time * 0.12, -time * 0.08));
        for (var i = 0; i < 4; i++) {
            let wPhase = dot(xz, dirs[i]) * freqs[i] - time * speeds[i];
            // Slight domain warp makes ripples organic rather than rigid plane waves.
            let warp = valueNoise2(xz * (freqs[i] * 0.35) + vec2<f32>(time * 0.4, 1.7)) * 1.6;
            let ds = cos(wPhase + warp) * freqs[i] * amps[i] * gust;
            dH += dirs[i] * ds;
        }
        dH *= 0.65 + 0.45 * waveScale;
    }
    return dH;
}

/// Evaluates lacy multi-scale organic sea-foam coverage in [0, 1].
fn evalFoamPattern(xz: vec2<f32>, flowVel: vec2<f32>, time: f32,
                   crestFactor: f32, obstacleWake: f32, waterDepth: f32,
                   waveScale: f32, riverMode: u32) -> f32 {
    let fUv1 = xz * 2.2 - flowVel * (time * 0.45);
    let fUv2 = xz * 5.8 - flowVel * (time * 0.72) + vec2<f32>(5.3, -2.8);
    let nCoarse = fbm2(fUv1);
    let nLace   = 1.0 - abs(fbm2(fUv2) * 2.0 - 1.0);
    // Zero constant floor so clear water gaps stay 100% transparent between lacy bubble filaments.
    let bubbleTex = clamp(nCoarse * 0.62 + pow(nLace, 2.0) * 0.68 - 0.16, 0.0, 1.0);

    // 1. Steep wave crest whitecaps (scarce in calm, breaking in rough/stormy).
    let crestThresh = mix(0.84, 0.64, clamp((waveScale - 0.35) / 1.4, 0.0, 1.0));
    let crestMask = smoothstep(crestThresh, crestThresh + 0.15, crestFactor)
                  * clamp(waveScale * 0.78, 0.0, 1.25);

    // 2. Rock & pier wakes / collars.
    let wakeBoost = smoothstep(0.14, 0.80, obstacleWake);

    // 3. Riverbank shallow shoreline foam rim.
    let shoreBand = select(0.0, 1.0 - smoothstep(0.04, 0.34, waterDepth), riverMode != 0u);

    let foamEnergy = max(crestMask, max(wakeBoost * 0.95, shoreBand * 0.82));
    return clamp(smoothstep(0.20, 0.46, foamEnergy * bubbleTex), 0.0, 1.0);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let time       = wu.params0.x;
    let waveScale  = wu.params0.y;
    let nearZ      = max(wu.params0.z, 0.01);
    let farZ       = max(wu.params0.w, nearZ + 1.0);
    let riverMode  = wu.flags0.x;
    let useOpenPbr = wu.flags0.y != 0u;
    let transparent = wu.flags0.z != 0u;
    let lowSun     = wu.flags0.w;
    let enableRefraction = wu.counts.z != 0u;
    let enableSsr        = wu.counts.w != 0u;

    let toCam = frame.cameraPos - in.worldPos;
    let camDist = length(toCam);
    let V = toCam / max(camDist, 1e-4);

    // 1. Analytical river streamline flow + obstacle contact/wake signals.
    let flowWake = evalRiverFlowAndWake(in.worldPos.xz, riverMode, time, wu.obstacles, wu.counts.x);
    let flowVel = flowWake.xy;
    let obstacleWake = flowWake.z;

    // 2. Procedural capillary normal perturbation with distance anti-aliasing + roughness AA.
    let rawSlope = evalCapillaryOffset(in.worldPos.xz, flowVel, time, riverMode, waveScale);
    let aaAtten = 1.0 / (1.0 + camDist * 0.065 + camDist * camDist * 0.0045);
    let slope = rawSlope * aaAtten;

    let N_macro = normalize(in.worldNormal);
    let N = normalize(N_macro + vec3<f32>(-slope.x, 0.0, -slope.y));
    var T = in.worldTangent;
    T = normalize(T - N * dot(N, T));
    let B = cross(N, T);
    let NdotV = max(dot(N, V), 0.001);

    // 3. Column depth, screen-space refraction & Beer-Lambert spectral absorption.
    let bedY = evalRiverBedY(in.worldPos.xz, riverMode, wu.obstacles, wu.counts.x);
    var verticalDepth = max(in.worldPos.y - bedY, 0.03);
    var rayDepth = min(verticalDepth / max(abs(V.y), 0.25), 4.5);

    var refractedBg = vec3<f32>(0.0);
    var rawRayThickness = rayDepth;
    var geomContact = 0.0;
    let depthDims = vec2<i32>(textureDimensions(sceneDepthMap, 0));
    let dimsF = vec2<f32>(depthDims);
    let baseUv = in.clipPos.xy / max(dimsF, vec2<f32>(1.0));
    let centerPix = clamp(vec2<i32>(in.clipPos.xy), vec2<i32>(0), depthDims - vec2<i32>(1));
    let waterLinZ = linearizeDepth(in.clipPos.z, nearZ, farZ);

    if (enableRefraction) {
        let rawBgDepth = textureLoad(sceneDepthMap, centerPix, 0);
        let bgLinZ = select(linearizeDepth(rawBgDepth, nearZ, farZ), waterLinZ + 6.0, rawBgDepth >= 0.9995);
        rawRayThickness = max(bgLinZ - waterLinZ, 0.0);
        verticalDepth = rawRayThickness * max(abs(V.y), 0.22);

        let refractScale = clamp(rawRayThickness * 0.26, 0.0, 0.036) / max(waterLinZ * 0.14, 0.65);
        let refrUv = clamp(baseUv + N.xz * refractScale, vec2<f32>(0.002), vec2<f32>(0.998));
        let refrPix = clamp(vec2<i32>(refrUv * dimsF), vec2<i32>(0), depthDims - vec2<i32>(1));
        let refrRawDepth = textureLoad(sceneDepthMap, refrPix, 0);
        let refrLinZ = select(linearizeDepth(refrRawDepth, nearZ, farZ), waterLinZ + 6.0, refrRawDepth >= 0.9995);

        // Reject refracted pixels belonging to foreground geometry sitting above the water surface.
        let validRefr = refrLinZ >= waterLinZ - 0.02;
        let finalUv = select(baseUv, refrUv, validRefr);
        let chosenRayZ = select(rawRayThickness, max(refrLinZ - waterLinZ, 0.0), validRefr);
        rayDepth = min(chosenRayZ, 6.0);

        // Subtle chromatic dispersion across R/G/B refraction offsets in clear shallows.
        let uvDelta = (finalUv - baseUv) * 0.08;
        let cR = textureSampleLevel(sceneColorMap, sceneLinearSampler, clamp(finalUv + uvDelta, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).r;
        let cG = textureSampleLevel(sceneColorMap, sceneLinearSampler, finalUv, 0.0).g;
        let cB = textureSampleLevel(sceneColorMap, sceneLinearSampler, clamp(finalUv - uvDelta, vec2<f32>(0.001), vec2<f32>(0.999)), 0.0).b;
        refractedBg = max(vec3<f32>(cR, cG, cB), vec3<f32>(0.0));

        // Geometry-exact 3D shoreline contact band hugging emergent rocks, piers, and embankments
        // (strictly 0..8-11 cm at the true surface intersection so deeper submerged boulders stay clear).
        let shoreBandDepth = select(0.08, 0.11, riverMode != 0u);
        geomContact = (1.0 - smoothstep(0.005, shoreBandDepth, verticalDepth)) * select(0.86, 0.95, riverMode != 0u);
    }

    // Absorption coefficients: red absorbs fastest, blue/cyan travels deepest.
    let sigma = select(
        vec3<f32>(1.65, 0.56, 0.34), // Ocean: turquoise shallows -> deep Atlantic navy
        vec3<f32>(1.35, 0.44, 0.52), // River: crisp clear mineral aqua -> alpine emerald
        riverMode != 0u
    );
    let transmittance = exp(-sigma * rayDepth);

    let shallowCol = select(vec3<f32>(0.03, 0.20, 0.26), vec3<f32>(0.05, 0.24, 0.20), riverMode != 0u);
    let deepCol    = select(vec3<f32>(0.008, 0.052, 0.115), vec3<f32>(0.015, 0.095, 0.090), riverMode != 0u);
    let waterVolumeCol = mix(deepCol, shallowCol, transmittance.g);

    // 4. Crisp lacy procedural foam mask (crest whitecaps + geometry contacts + wakes).
    let foamMask = evalFoamPattern(
        in.worldPos.xz, flowVel, time, in.crestFactor, max(obstacleWake, geomContact), verticalDepth, waveScale, riverMode);

    let foamColor = vec3<f32>(0.92, 0.94, 0.96);
    let bodyScatterWeight = select(vec3<f32>(1.0), vec3<f32>(1.0) - transmittance * 0.72, enableRefraction);
    let baseColor = mix(waterVolumeCol * bodyScatterWeight, foamColor, foamMask);

    // 5. OpenPBR v1.1 vs Legacy PBR parameter assignment (supports [4] A/B toggle).
    var roughness = select(0.08, select(0.075, 0.12, riverMode != 0u), useOpenPbr);
    let distRoughBoost = (1.0 - aaAtten) * 0.22;
    roughness = clamp(mix(roughness + distRoughBoost, 0.84, foamMask), 0.025, 0.95);
    let lutBase = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, roughness)).rg;
    let directionalAlbedo = lutBase.r + lutBase.g;

    let fuzzWeight = select(0.0, mix(0.14, 0.88, foamMask), useOpenPbr);
    let fuzzRough  = 0.68;
    let fuzzE = clamp(0.15 + 0.35 * pow(1.0 - NdotV, 2.0) * fuzzRough, 0.0, 0.95);

    var coatW = select(0.0, 0.92 * (1.0 - foamMask), useOpenPbr);
    let coatR = 0.022;
    let coatColor = select(vec3<f32>(0.70, 0.92, 1.00), vec3<f32>(0.76, 0.96, 0.92), riverMode != 0u);

    var pbrIn: OpenPbrEvalInput;
    pbrIn.N = N;
    pbrIn.T = T;
    pbrIn.B = B;
    pbrIn.V = V;
    pbrIn.baseColor = baseColor;
    pbrIn.metalness = 0.0;
    pbrIn.diffuseRoughness = mix(0.18, 0.82, foamMask);
    pbrIn.specularWeight = mix(1.0, 0.35, foamMask);
    pbrIn.specularRoughness = roughness;
    pbrIn.specularColor = vec3<f32>(1.0);
    pbrIn.specularIor = select(1.50, 1.333, useOpenPbr);
    pbrIn.specularAnisotropy = select(0.0, select(0.20, 0.45, riverMode != 0u) * (1.0 - foamMask), useOpenPbr);
    pbrIn.coatWeight = coatW;
    pbrIn.coatColor = coatColor;
    pbrIn.coatRoughness = coatR;
    pbrIn.coatIor = 1.333;
    pbrIn.coatDarkening = select(0.0, 1.0, useOpenPbr);
    pbrIn.fuzzWeight = fuzzWeight;
    pbrIn.fuzzColor = vec3<f32>(0.92, 0.97, 1.0);
    pbrIn.fuzzRoughness = fuzzRough;
    pbrIn.thinFilmWeight = 0.0;
    pbrIn.thinFilmThickness = 500.0;
    pbrIn.thinFilmIor = 1.4;
    pbrIn.directionalAlbedo = directionalAlbedo;
    pbrIn.fuzzAlbedo = fuzzE;

    var direct = vec3<f32>(0.0);
    var dirShadow = 1.0;
    var sunL = vec3<f32>(0.0, 1.0, 0.0);
    var sunRad = vec3<f32>(1.0);
    if (frame.dirEnabled != 0u) {
        sunL = normalize(frame.dirLight.direction);
        sunRad = frame.dirLight.color * frame.dirLight.intensity;
        if (frame.dirLight.castShadows != 0u) {
            dirShadow = sampleDirShadowPCF(in.worldPos, N, sunL);
        }
        direct += evalOpenPbrDirect(pbrIn, sunL, sunRad) * dirShadow;
    }

    let sc = min(frame.spotCount, 4u);
    for (var i = 0u; i < sc; i++) {
        let sl = frame.spots[i];
        let toLight = sl.position - in.worldPos;
        let dist = length(toLight);
        if (dist >= sl.range) {
            continue;
        }
        let L = toLight / dist;
        let theta = dot(normalize(-sl.direction), L);
        let epsilon = max(sl.innerConeCos - sl.outerConeCos, 0.001);
        let cone = clamp((theta - sl.outerConeCos) / epsilon, 0.0, 1.0);
        if (cone <= 0.0) {
            continue;
        }
        let atten = rangeAttenuation(dist, sl.range) * cone * cone;
        let shadow = sampleSpotShadowPCF(sl.shadowSlot, sl.viewProj, in.worldPos, N, L);
        direct += evalOpenPbrDirect(pbrIn, L, sl.color * sl.intensity * atten) * shadow;
    }

    // 6. Coherent sky + solar glitter IBL matching the visible sky_dome.
    let f0Dielectric = dielectricF0UnderCoat(
        pbrIn.specularIor, pbrIn.coatIor, coatW, pbrIn.specularWeight, pbrIn.specularColor);
    var F_ibl = fresnelSchlickRoughness(NdotV, f0Dielectric, roughness);
    let kD_ibl = vec3<f32>(1.0) - F_ibl;
    let baseAlbedoIbl = applyCoatDarkening(baseColor, pbrIn.coatIor, coatW, pbrIn.coatDarkening);
    let irradiance = textureSample(irradianceMap, iblSampler, N).rgb;
    let diffuseIbl = kD_ibl * irradiance * baseAlbedoIbl;

    var iblNormal = N;
    if (abs(pbrIn.specularAnisotropy) > 0.001) {
        let anisoDir = B;
        let anisoTangent = cross(anisoDir, V);
        let bentNormal = normalize(cross(anisoTangent, anisoDir));
        iblNormal = normalize(mix(N, bentNormal, abs(pbrIn.specularAnisotropy) * 0.45));
    }
    let R = reflect(-V, iblNormal);
    let mip = roughness * SPECULAR_MIPS;
    let iblSpec = textureSampleLevel(specularMap, iblSampler, R, mip).rgb;
    var procSky = evalWaterSky(R, sunL, frame.dirLight.color, lowSun, time);

    // WTR-4: Screen-Space Reflections raymarch against opaque snapshot color & depth.
    var ssrColor = vec3<f32>(0.0);
    var ssrWeight = 0.0;
    if (enableSsr && R.y > 0.025 && camDist < 34.0) {
        let maxDist = 14.0;
        let stepLen = maxDist / 16.0;
        let ign = fract(52.9829189 * fract(dot(in.clipPos.xy, vec2<f32>(0.06711056, 0.00583715))));
        var tPrev = 0.10 + stepLen * 0.45 * ign;
        for (var s = 0; s < 16; s++) {
            let tCur = tPrev + stepLen;
            let rayP = in.worldPos + R * tCur;
            if (rayP.y < 0.02) {
                tPrev = tCur;
                continue;
            }
            let clip = frame.viewProj * vec4<f32>(rayP, 1.0);
            if (clip.w <= 0.05) {
                break;
            }
            let ndc = clip.xyz / clip.w;
            let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
            if (uv.x <= 0.002 || uv.x >= 0.998 || uv.y <= 0.002 || uv.y >= 0.998 || ndc.z <= 0.0 || ndc.z >= 1.0) {
                break;
            }
            let sPix = clamp(vec2<i32>(uv * dimsF), vec2<i32>(0), depthDims - vec2<i32>(1));
            let sRawZ = textureLoad(sceneDepthMap, sPix, 0);
            if (sRawZ < 0.9992) {
                let sceneLin = linearizeDepth(sRawZ, nearZ, farZ);
                let rayLin = linearizeDepth(ndc.z, nearZ, farZ);
                let diff = rayLin - sceneLin;
                if (diff > 0.02 && diff < (0.28 + 0.05 * tCur)) {
                    // 3-step binary refinement between tPrev and tCur.
                    var lo = tPrev;
                    var hi = tCur;
                    var bestUv = uv;
                    for (var b = 0; b < 3; b++) {
                        let mid = (lo + hi) * 0.5;
                        let mClip = frame.viewProj * vec4<f32>(in.worldPos + R * mid, 1.0);
                        let mNdc = mClip.xyz / max(mClip.w, 0.05);
                        let mUv = clamp(vec2<f32>(mNdc.x * 0.5 + 0.5, 0.5 - mNdc.y * 0.5), vec2<f32>(0.002), vec2<f32>(0.998));
                        let mPix = clamp(vec2<i32>(mUv * dimsF), vec2<i32>(0), depthDims - vec2<i32>(1));
                        let mRawZ = textureLoad(sceneDepthMap, mPix, 0);
                        let mSceneLin = linearizeDepth(mRawZ, nearZ, farZ);
                        let mRayLin = linearizeDepth(mNdc.z, nearZ, farZ);
                        if (mRayLin > mSceneLin && mRawZ < 0.9992) {
                            hi = mid;
                            bestUv = mUv;
                        } else {
                            lo = mid;
                        }
                    }
                    ssrColor = max(textureSampleLevel(sceneColorMap, sceneLinearSampler, bestUv, 0.0).rgb, vec3<f32>(0.0));
                    let edgeFade = smoothstep(0.0, 0.10, min(bestUv.x, 1.0 - bestUv.x))
                                 * smoothstep(0.0, 0.12, min(bestUv.y, 1.0 - bestUv.y));
                    let roughFade = 1.0 - smoothstep(0.10, 0.45, roughness);
                    let distFade = (1.0 - smoothstep(8.0, maxDist, tCur)) * (1.0 - smoothstep(22.0, 34.0, camDist));
                    ssrWeight = edgeFade * roughFade * distFade * (1.0 - foamMask);
                    break;
                }
            }
            tPrev = tCur;
        }
    }
    procSky = mix(procSky, ssrColor, ssrWeight);

    // Low-roughness liquid reflects sharp procedural sky & sun disc; rough foam falls back to IBL.
    let prefiltered = mix(procSky, iblSpec, clamp(roughness * 1.4, 0.0, 0.85));
    let E_o = clamp(directionalAlbedo, 0.05, 1.0);
    let msScale = vec3<f32>(1.0) + f0Dielectric * ((1.0 - E_o) / E_o);
    let specularIbl = prefiltered * (F_ibl * lutBase.r + lutBase.g) * msScale;
    var ambient = diffuseIbl + specularIbl;

    var coatFresnelMax = 0.0;
    if (coatW > 0.001) {
        let f0Coat = vec3<f32>(dielectricF0Scalar(pbrIn.coatIor));
        let Fc_ibl = fresnelSchlickRoughness(NdotV, f0Coat, coatR) * coatW;
        coatFresnelMax = Fc_ibl.r;
        let coatLut = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, coatR)).rg;
        let coatRefl = reflect(-V, N);
        let coatSky = mix(evalWaterSky(coatRefl, sunL, frame.dirLight.color, lowSun, time), ssrColor, ssrWeight * 0.92);
        let coatIblSpec = textureSampleLevel(specularMap, iblSampler, coatRefl, coatR * SPECULAR_MIPS).rgb;
        let coatEnv = mix(coatSky, coatIblSpec, 0.12);
        let f90Coat = max(1.0 - coatR, f0Coat.x);
        let coatEnvBrdf = (f0Coat * coatLut.r + vec3<f32>(f90Coat * coatLut.g)) * coatW;
        let horizonOcclusion = clamp(coatRefl.y * 0.65 + 0.55, 0.18, 1.0);
        let coatSpecIbl = coatEnv * coatEnvBrdf * horizonOcclusion;
        let coatTransIbl = mix(
            vec3<f32>(1.0),
            pow(max(coatColor, vec3<f32>(0.001)), vec3<f32>(1.0 / max(NdotV, 0.05))),
            coatW
        );
        ambient = ambient * coatTransIbl * (vec3<f32>(1.0) - Fc_ibl) + coatSpecIbl;
    }

    if (fuzzWeight > 0.001) {
        let fuzzTrans = clamp(1.0 - fuzzWeight * fuzzE, 0.0, 1.0);
        let fuzzIbl = fuzzWeight * irradiance * pbrIn.fuzzColor * fuzzE;
        ambient = ambient * fuzzTrans + fuzzIbl;
    }

    // 7. Subtle backlit wave-crest Subsurface Scattering (SSS) under high peaking ocean swells.
    let backLit = pow(clamp(dot(V, normalize(-sunL + N * 0.35)), 0.0, 1.0), 6.0);
    let crestThin = smoothstep(0.14, 0.46, in.worldPos.y + in.crestFactor * 0.16)
                  * select(1.0, 0.12, riverMode != 0u);
    let sssTint = select(vec3<f32>(0.02, 0.15, 0.18), vec3<f32>(0.03, 0.16, 0.14), riverMode != 0u);
    let sss = sssTint * sunRad * (0.15 + 0.85 * dirShadow) * backLit * crestThin * (1.0 - foamMask) * 0.28;

    let baseFresnelMax = max(F_ibl.r, max(F_ibl.g, F_ibl.b));
    let viewReflectance = clamp(baseFresnelMax + coatFresnelMax * (1.0 - baseFresnelMax), 0.0, 1.0);

    var color = max(direct + ambient + sss, vec3<f32>(0.0));
    var outAlpha = 1.0;

    if (enableRefraction && transparent) {
        // Real Single-Layer Water optical composition: attenuated refracted scene behind surface,
        // with Fresnel sky/SSR reflection & foam layered on top and 3cm meniscus edge feathering.
        let refrVis = (1.0 - viewReflectance * 0.85) * (1.0 - foamMask);
        color += refractedBg * transmittance * refrVis;
        outAlpha = clamp(smoothstep(0.0, 0.03, rawRayThickness), 0.0, 1.0);
        outAlpha = max(outAlpha, foamMask);
    } else if (transparent) {
        let oceanDepthAlpha = clamp(0.32 + 0.60 * (1.0 - exp(-rayDepth * 0.85)), 0.32, 0.92);
        let riverDepthAlpha = clamp(1.0 - exp(-rayDepth * 0.65), 0.22, 0.86);
        let depthAlpha = select(oceanDepthAlpha, riverDepthAlpha, riverMode != 0u);
        let waterAlpha = mix(depthAlpha, 1.0, viewReflectance * 0.92);
        outAlpha = mix(waterAlpha, 0.97, foamMask);
    }

    // Gentle distant horizon haze blending seamlessly into sky_dome (extended ocean reach in WTR-5).
    let fogFactor = select(
        smoothstep(26.0, 115.0, camDist) * 0.92,
        smoothstep(20.0, 56.0, camDist) * 0.35,
        riverMode != 0u
    );
    let fogCol = evalWaterSky(normalize(-toCam), sunL, frame.dirLight.color, lowSun, time);
    color = mix(color, fogCol, fogFactor);

    return vec4<f32>(color, outAlpha);
}
