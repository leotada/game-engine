const PI: f32 = 3.14159265359;
const SPECULAR_MIPS: f32 = 4.0;
const SHADOW_NEAR: f32 = 0.1;

struct OpenPbrEvalInput {
    N: vec3<f32>,
    T: vec3<f32>,
    B: vec3<f32>,
    V: vec3<f32>,
    baseColor: vec3<f32>,
    metalness: f32,
    diffuseRoughness: f32,
    specularWeight: f32,
    specularRoughness: f32,
    specularColor: vec3<f32>,
    specularIor: f32,
    specularAnisotropy: f32,
    coatWeight: f32,
    coatColor: vec3<f32>,
    coatRoughness: f32,
    coatIor: f32,
    coatDarkening: f32,
    fuzzWeight: f32,
    fuzzColor: vec3<f32>,
    fuzzRoughness: f32,
    thinFilmWeight: f32,
    thinFilmThickness: f32,
    thinFilmIor: f32,
    directionalAlbedo: f32,
    fuzzAlbedo: f32,
};

fn distributionGGX(NdotH: f32, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 1e-6);
}

fn distributionGGXAniso(NdotH: f32, TdotH: f32, BdotH: f32, ax: f32, ay: f32) -> f32 {
    let a2 = ax * ay;
    let d = vec3<f32>(ay * TdotH, ax * BdotH, a2 * NdotH);
    let d2 = dot(d, d);
    let b2 = a2 / max(d2, 1e-7);
    return (1.0 / PI) * a2 * b2 * b2;
}

fn geometrySchlickGGX(NdotX: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return NdotX / (NdotX * (1.0 - k) + k);
}

fn geometrySmith(NdotV: f32, NdotL: f32, roughness: f32) -> f32 {
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

fn visibilitySmithGGXAniso(
    NdotV: f32, TdotV: f32, BdotV: f32,
    NdotL: f32, TdotL: f32, BdotL: f32,
    ax: f32, ay: f32
) -> f32 {
    let lambdaV = NdotL * length(vec3<f32>(ax * TdotV, ay * BdotV, NdotV));
    let lambdaL = NdotV * length(vec3<f32>(ax * TdotL, ay * BdotL, NdotL));
    return 0.5 / max(lambdaV + lambdaL, 1e-5);
}

fn fresnelSchlick(cosTheta: f32, F0: vec3<f32>) -> vec3<f32> {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

fn fresnelSchlickRoughness(cosTheta: f32, F0: vec3<f32>, roughness: f32) -> vec3<f32> {
    return F0 + (max(vec3<f32>(1.0 - roughness), F0) - F0)
         * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

fn dielectricF0Scalar(ior: f32) -> f32 {
    let r0 = (ior - 1.0) / max(ior + 1.0, 1.001);
    return clamp(r0 * r0, 0.0, 1.0);
}

fn dielectricF0UnderCoat(specIor: f32, coatIor: f32, coatWeight: f32, specWeight: f32, specColor: vec3<f32>) -> vec3<f32> {
    let topIor = mix(1.0, coatIor, clamp(coatWeight, 0.0, 1.0));
    let eta = specIor / max(topIor, 1.001);
    let r0 = (eta - 1.0) / max(eta + 1.0, 1.001);
    let f0 = clamp(r0 * r0 * specWeight, 0.0, 1.0);
    return f0 * specColor;
}

/// OpenPBR Eq. 24: F82-tint Lazanyi-Schlick conductor Fresnel.
fn fresnelF82Conductor(cosTheta: f32, f0: vec3<f32>, f82Tint: vec3<f32>) -> vec3<f32> {
    let mu = clamp(cosTheta, 0.0, 1.0);
    let oneMinusMu = 1.0 - mu;
    let oneMinusMu5 = pow(oneMinusMu, 5.0);
    let fSchlick = f0 + (vec3<f32>(1.0) - f0) * oneMinusMu5;
    let oneMinusMuBar5 = pow(6.0 / 7.0, 5.0);
    let fSchlickBar = f0 + (vec3<f32>(1.0) - f0) * oneMinusMuBar5;
    // 7 * (7/6)^6 = 17.6512028
    let b = fSchlickBar * (vec3<f32>(1.0) - clamp(f82Tint, vec3<f32>(0.0), vec3<f32>(1.0))) * 17.6512028;
    return clamp(fSchlick - b * mu * oneMinusMu * oneMinusMu5, vec3<f32>(0.0), vec3<f32>(1.0));
}

/// Belcour & Barla (2017) analytical Airy thin-film iridescence over RGB bands.
fn evalThinFilmIridescence(cosThetaI: f32, dNm: f32, filmIor: f32, baseF0: vec3<f32>) -> vec3<f32> {
    let ior = max(filmIor, 1.001);
    let sin2ThetaT = (1.0 - cosThetaI * cosThetaI) / (ior * ior);
    let cosThetaT = sqrt(max(1.0 - sin2ThetaT, 0.0));
    let opd = 2.0 * ior * max(dNm, 0.0) * cosThetaT;
    let lambdas = vec3<f32>(650.0, 510.0, 475.0);
    let phi = (2.0 * PI * opd) / lambdas + vec3<f32>(PI);
    let r12 = dielectricF0Scalar(ior);
    let r23 = clamp(baseF0, vec3<f32>(0.001), vec3<f32>(0.999));
    let rs = sqrt(r12 * r23);
    let cosPhi = cos(phi);
    let num = vec3<f32>(r12) + r23 + 2.0 * rs * cosPhi;
    let den = vec3<f32>(1.0) + r12 * r23 + 2.0 * rs * cosPhi;
    return clamp(num / max(den, vec3<f32>(0.001)), vec3<f32>(0.0), vec3<f32>(1.0));
}

/// OpenPBR qualitative Oren-Nayar (Fujii) diffuse BRDF.
fn evalDiffuseFujiiOrenNayar(
    NdotL: f32, NdotV: f32, LdotV: f32,
    diffuseRoughness: f32, baseAlbedo: vec3<f32>
) -> vec3<f32> {
    if (diffuseRoughness <= 0.001) {
        return baseAlbedo / PI;
    }
    let s = LdotV - NdotL * NdotV;
    let stinv = select(1.0, max(NdotL, NdotV), s > 0.0);
    let sigma = clamp(diffuseRoughness, 0.0, 1.0);
    let A = vec3<f32>(1.0 - 0.5 * (sigma / (sigma + 0.33))) + 0.17 * baseAlbedo * (sigma / (sigma + 0.13));
    let B = 0.45 * (sigma / (sigma + 0.09));
    return (baseAlbedo / PI) * max(A + vec3<f32>(B * (s / max(stinv, 0.001))), vec3<f32>(0.0));
}

fn distributionCharlie(NdotH: f32, roughness: f32) -> f32 {
    let r = max(roughness, 0.04);
    let invR = 1.0 / r;
    let cos2h = NdotH * NdotH;
    let sin2h = max(1.0 - cos2h, 1e-6);
    return (2.0 + invR) * pow(sin2h, invR * 0.5) / (2.0 * PI);
}

fn visibilityAshikhmin(NdotV: f32, NdotL: f32) -> f32 {
    return 1.0 / max(4.0 * (NdotL + NdotV - NdotL * NdotV), 1e-5);
}

/// OpenPBR Eq. 43: Coat roughening of underlying base specular lobe.
fn coatRoughenBase(baseRoughness: f32, coatRoughness: f32, coatWeight: f32) -> f32 {
    if (coatWeight <= 0.001) {
        return baseRoughness;
    }
    let b4 = pow(1.0 - clamp(baseRoughness, 0.0, 1.0), 4.0);
    let c4 = pow(1.0 - clamp(coatRoughness, 0.0, 1.0), 4.0);
    let widened = pow(max(1.0 - b4 * c4, 0.0), 0.25);
    return mix(baseRoughness, widened, clamp(coatWeight, 0.0, 1.0));
}

/// OpenPBR coat internal-reflection darkening (OpenPBR v1.1 Sec. 5.4 Eq. 48).
fn applyCoatDarkening(albedo: vec3<f32>, coatIor: f32, coatWeight: f32, coatDarkening: f32) -> vec3<f32> {
    let factor = clamp(coatWeight * coatDarkening, 0.0, 1.0);
    if (factor <= 0.001) {
        return albedo;
    }
    let f0 = dielectricF0Scalar(coatIor);
    let kr = clamp(1.0 - (1.0 - f0) / max(coatIor * coatIor, 1.001), 0.0, 0.99);
    let internalDark = (albedo * (1.0 - kr)) / max(vec3<f32>(1.0) - albedo * kr, vec3<f32>(0.01));
    return mix(albedo, internalDark, factor);
}

fn evalOpenPbrDirect(in: OpenPbrEvalInput, L: vec3<f32>, radiance: vec3<f32>) -> vec3<f32> {
    let N = in.N;
    let V = in.V;
    let NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) {
        return vec3<f32>(0.0);
    }

    let H = normalize(V + L);
    let NdotV = max(dot(N, V), 0.001);
    let NdotH = max(dot(N, H), 0.0);
    let HdotV = max(dot(H, V), 0.0);
    let LdotV = dot(L, V);

    // 1. Base substrate: dielectric + conductor F82 + thin-film + multi-scattering GGX
    let f0Dielectric = dielectricF0UnderCoat(
        in.specularIor, in.coatIor, in.coatWeight, in.specularWeight, in.specularColor
    );
    let f0Base = mix(f0Dielectric, in.baseColor, in.metalness);

    var fDielectric = fresnelSchlick(HdotV, f0Dielectric);
    var fConductor = fresnelF82Conductor(HdotV, in.baseColor, in.specularColor);
    var F_base = mix(fDielectric, fConductor, in.metalness);

    if (in.thinFilmWeight > 0.001) {
        let fFilm = evalThinFilmIridescence(HdotV, in.thinFilmThickness, in.thinFilmIor, f0Base);
        F_base = mix(F_base, fFilm, clamp(in.thinFilmWeight, 0.0, 1.0));
    }

    var specTerm: vec3<f32>;
    if (abs(in.specularAnisotropy) > 0.001) {
        let a = clamp(in.specularAnisotropy, -0.99, 0.99);
        let k = 1.0 - abs(a);
        let s = sqrt(2.0 / (1.0 + k * k));
        let alpha = in.specularRoughness * in.specularRoughness;
        let alphaLong = max(alpha * s, 0.0016);
        let alphaShort = max(alpha * k * s, 0.0016);
        let ax = select(alphaShort, alphaLong, a >= 0.0);
        let ay = select(alphaLong, alphaShort, a >= 0.0);

        let TdotH = dot(in.T, H);
        let BdotH = dot(in.B, H);
        let TdotV = dot(in.T, V);
        let BdotV = dot(in.B, V);
        let TdotL = dot(in.T, L);
        let BdotL = dot(in.B, L);

        let D = distributionGGXAniso(NdotH, TdotH, BdotH, ax, ay);
        let Vis = visibilitySmithGGXAniso(NdotV, TdotV, BdotV, NdotL, TdotL, BdotL, ax, ay);
        specTerm = D * Vis * F_base;
    } else {
        let D = distributionGGX(NdotH, in.specularRoughness);
        let G = geometrySmith(NdotV, NdotL, in.specularRoughness);
        specTerm = (D * G * F_base) / max(4.0 * NdotV * NdotL, 0.001);
    }

    // Multi-scattering GGX compensation via LUT directional albedo
    let E_o = clamp(in.directionalAlbedo, 0.05, 1.0);
    let msScale = vec3<f32>(1.0) + f0Base * ((1.0 - E_o) / E_o);
    let baseSpecular = min(specTerm * msScale, vec3<f32>(16.0));

    let kD = (vec3<f32>(1.0) - F_base) * (1.0 - in.metalness);
    let baseAlbedo = applyCoatDarkening(in.baseColor, in.coatIor, in.coatWeight, in.coatDarkening);
    let baseDiffuse = kD * evalDiffuseFujiiOrenNayar(NdotL, NdotV, LdotV, in.diffuseRoughness, baseAlbedo);
    var slab = baseDiffuse + baseSpecular;

    // 2. Coat slab (dielectric GGX + Beer-Lambert absorption tint)
    if (in.coatWeight > 0.001) {
        let coatW = clamp(in.coatWeight, 0.0, 1.0);
        let coatR = clamp(in.coatRoughness, 0.04, 1.0);
        let f0Coat = vec3<f32>(dielectricF0Scalar(in.coatIor));
        let Fc = fresnelSchlick(HdotV, f0Coat) * coatW;
        let Dc = distributionGGX(NdotH, coatR);
        let Gc = geometrySmith(NdotV, NdotL, coatR);
        let coatSpec = min((Dc * Gc * Fc) / max(4.0 * NdotV * NdotL, 0.001), vec3<f32>(16.0));
        let pathLen = 0.5 / max(NdotV, 0.05) + 0.5 / max(NdotL, 0.05);
        let coatTrans = mix(vec3<f32>(1.0), pow(max(in.coatColor, vec3<f32>(0.001)), vec3<f32>(pathLen)), coatW);
        slab = slab * coatTrans * (vec3<f32>(1.0) - Fc) + coatSpec;
    }

    // 3. Fuzz / Sheen top slab (Charlie NDF + Ashikhmin visibility)
    if (in.fuzzWeight > 0.001) {
        let fuzzW = clamp(in.fuzzWeight, 0.0, 1.0);
        let fuzzR = clamp(in.fuzzRoughness, 0.04, 1.0);
        let Df = distributionCharlie(NdotH, fuzzR);
        let Vf = visibilityAshikhmin(NdotV, NdotL);
        let fuzzSpec = min(in.fuzzColor * Df * Vf, vec3<f32>(8.0)) * fuzzW;
        let fuzzTrans = clamp(1.0 - fuzzW * in.fuzzAlbedo, 0.0, 1.0);
        slab = slab * fuzzTrans + fuzzSpec;
    }

    return slab * radiance * NdotL;
}

/// Legacy signature preserved for shader preprocessing tests.
fn evalBRDF(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, albedo: vec3<f32>,
            metallic: f32, roughness: f32, radiance: vec3<f32>) -> vec3<f32> {
    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, 1.0), abs(N.x) > 0.9);
    let T = normalize(cross(up, N));
    let B = cross(N, T);
    var inp: OpenPbrEvalInput;
    inp.N = N;
    inp.T = T;
    inp.B = B;
    inp.V = V;
    inp.baseColor = albedo;
    inp.metalness = metallic;
    inp.diffuseRoughness = 0.0;
    inp.specularWeight = 1.0;
    inp.specularRoughness = roughness;
    inp.specularColor = vec3<f32>(1.0);
    inp.specularIor = 1.5;
    inp.specularAnisotropy = 0.0;
    inp.coatWeight = 0.0;
    inp.coatColor = vec3<f32>(1.0);
    inp.coatRoughness = 0.1;
    inp.coatIor = 1.6;
    inp.coatDarkening = 1.0;
    inp.fuzzWeight = 0.0;
    inp.fuzzColor = vec3<f32>(1.0);
    inp.fuzzRoughness = 0.5;
    inp.thinFilmWeight = 0.0;
    inp.thinFilmThickness = 500.0;
    inp.thinFilmIor = 1.4;
    inp.directionalAlbedo = 1.0;
    inp.fuzzAlbedo = 0.0;
    return evalOpenPbrDirect(inp, L, radiance);
}

/// Per-light attenuation: `exponent <= 0` keeps the default curve, otherwise
/// `pow(1 - d/r, exponent)` (reaches the full range, no inverse-square).
fn lightAttenuation(distance: f32, range: f32, exponent: f32) -> f32 {
    if (exponent > 0.0) {
        return pow(clamp(1.0 - distance / max(range, 0.001), 0.0, 1.0), exponent);
    }
    return rangeAttenuation(distance, range);
}

fn rangeAttenuation(distance: f32, range: f32) -> f32 {
    let x = clamp(1.0 - pow(distance / max(range, 0.001), 4.0), 0.0, 1.0);
    return (x * x) / (distance * distance + 1.0);
}
