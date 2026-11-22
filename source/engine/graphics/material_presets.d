/// Material presets for surfaces near water: dry stone and its wet, mossy and
/// submerged variants (OpenPBR coat = water film, fuzz = moss). Each variant
/// starts from a dry base, so it keeps the base's texture flags and IOR.
///
/// ```d
/// auto dry = dryStoneParams();                   // textured albedo/normal/MR/AO
/// auto wet = wetSurfaceParams(dry);              // splash zone
/// auto sub = submergedSurfaceParams(dry);        // under water
/// wet.flags |= MaterialFlags.waterWetCaustics;   // optional wave-contact marks
/// ```
///
/// `openPbr = false` returns a cheaper look without coat or fuzz (for the
/// classic PBR path or low settings). See docs/water-guide.md.
module engine.graphics.material_presets;

import engine.graphics.material : MaterialFlags, MaterialParams;

@safe:

/// Rough natural stone. Expects linear albedo, normal, metallic-roughness and
/// occlusion textures (all four flags set).
MaterialParams dryStoneParams() pure nothrow @nogc {
    MaterialParams p;
    p.baseColor = [1.0f, 0.98f, 0.95f];
    p.baseDiffuseRoughness = 0.85f;
    p.specularRoughness = 0.95f;
    p.specularIor = 1.52f;
    p.flags = MaterialFlags.normal | MaterialFlags.metallicRoughness | MaterialFlags.occlusion;
    return p;
}

/// `dry` covered by a thin water film: darker, glossier, clear coat (IOR 1.333).
MaterialParams wetSurfaceParams(MaterialParams dry, bool openPbr = true) pure nothrow @nogc {
    MaterialParams p = dry;
    if (openPbr) {
        p.baseColor = [0.95f, 0.96f, 0.98f];
        p.baseDiffuseRoughness = 0.65f;
        p.specularRoughness = 0.52f;
        p.coatWeight = 0.90f;
        p.coatRoughness = 0.065f;
        p.coatIor = 1.333f;
        p.coatColor = [0.90f, 0.94f, 0.97f];
        p.coatDarkening = 0.72f;
    }
    return p;
}

/// Damp moss over `dry` (use a moss albedo/MR texture): green fuzz sheen and
/// a faint water coat.
MaterialParams mossSurfaceParams(MaterialParams dry, bool openPbr = true) pure nothrow @nogc {
    MaterialParams p = dry;
    p.baseColor = [1.0f, 1.0f, 1.0f];
    if (openPbr) {
        p.baseDiffuseRoughness = 0.82f;
        p.specularRoughness = 0.90f;
        p.coatWeight = 0.12f;
        p.coatRoughness = 0.24f;
        p.coatIor = 1.333f;
        p.coatDarkening = 0.45f;
        p.fuzzWeight = 0.28f;
        p.fuzzColor = [0.20f, 0.28f, 0.11f];
        p.fuzzRoughness = 0.78f;
    } else {
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.85f;
    }
    return p;
}

/// `dry` permanently under water: cool algae tint, smooth saturated coat.
MaterialParams submergedSurfaceParams(MaterialParams dry, bool openPbr = true) pure nothrow @nogc {
    MaterialParams p = dry;
    if (openPbr) {
        p.baseColor = [0.88f, 0.96f, 0.94f];
        p.baseDiffuseRoughness = 0.55f;
        p.specularRoughness = 0.42f;
        p.coatWeight = 0.95f;
        p.coatRoughness = 0.05f;
        p.coatIor = 1.333f;
        p.coatColor = [0.76f, 0.92f, 0.90f];
        p.coatDarkening = 0.72f;
    } else {
        p.baseColor = [0.88f, 0.86f, 0.82f];
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.85f;
    }
    return p;
}

unittest {
    immutable dry = dryStoneParams();
    assert(dry.flags & MaterialFlags.normal);

    // Variants keep the dry texture flags and IOR, and add a water coat.
    MaterialParams custom = dry;
    custom.flags |= MaterialFlags.waterWetCaustics;
    immutable wet = wetSurfaceParams(custom);
    assert(wet.flags == custom.flags && wet.specularIor == 1.52f);
    assert(wet.coatWeight > 0.5f && wet.specularRoughness < dry.specularRoughness);

    immutable sub = submergedSurfaceParams(dry);
    assert(sub.coatWeight > wet.coatWeight && sub.coatIor == 1.333f);

    immutable moss = mossSurfaceParams(dry);
    assert(moss.fuzzWeight > 0.0f);

    // Without OpenPBR there is no coat or fuzz.
    assert(wetSurfaceParams(dry, false).coatWeight == dry.coatWeight);
    assert(mossSurfaceParams(dry, false).fuzzWeight == dry.fuzzWeight);
    assert(submergedSurfaceParams(dry, false).coatWeight == dry.coatWeight);
}
