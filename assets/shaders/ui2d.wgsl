struct UiUniforms {
    screenSize: vec2<f32>,
    _pad0: vec2<f32>,
    clipCircle: vec4<f32>, // (cx, cy, radius, enabled > 0.5)
};
@group(0) @binding(0) var<uniform> uiU: UiUniforms;
@group(0) @binding(1) var uiSampler: sampler;
@group(0) @binding(2) var uiTexture: texture_2d<f32>;

struct UiVertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
    @location(3) rectParams: vec4<f32>,
    @location(4) localPos: vec2<f32>,
    @location(5) borderColor: vec4<f32>,
    @location(6) mode: f32,
};

struct UiVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) rectParams: vec4<f32>,
    @location(3) localPos: vec2<f32>,
    @location(4) borderColor: vec4<f32>,
    @location(5) mode: f32,
};

@vertex
fn vs_ui(in: UiVertexInput) -> UiVertexOutput {
    let ndc = vec2<f32>(
        in.position.x / uiU.screenSize.x * 2.0 - 1.0,
        1.0 - in.position.y / uiU.screenSize.y * 2.0
    );
    var out: UiVertexOutput;
    out.clipPos = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    out.rectParams = in.rectParams;
    out.localPos = in.localPos;
    out.borderColor = in.borderColor;
    out.mode = in.mode;
    return out;
}

@fragment
fn fs_ui(in: UiVertexOutput) -> @location(0) vec4<f32> {
    var circleClipAlpha = 1.0;
    if (uiU.clipCircle.w > 0.5 && uiU.clipCircle.z > 0.0) {
        let dCircle = length(in.clipPos.xy - uiU.clipCircle.xy) - uiU.clipCircle.z;
        circleClipAlpha = smoothstep(0.5, -0.5, dCircle);
        if (circleClipAlpha <= 0.0) {
            discard;
        }
    }

    if (in.mode < 0.5) {
        // Mode 0: Solid / Rounded Rectangle (or capsule line) with SDF antialiasing
        let halfSize = in.rectParams.xy * 0.5;
        let r = min(in.rectParams.z, min(halfSize.x, halfSize.y));
        let borderW = in.rectParams.w;
        let q = abs(in.localPos) - halfSize + vec2<f32>(r, r);
        let dist = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
        let alpha = clamp(0.5 - dist, 0.0, 1.0) * circleClipAlpha;
        if (alpha <= 0.0) {
            discard;
        }

        var col = in.color;
        if (borderW > 0.0) {
            let innerDist = dist + borderW;
            let borderFactor = clamp(innerDist + 0.5, 0.0, 1.0);
            col = mix(in.color, in.borderColor, borderFactor);
        }
        return vec4<f32>(col.rgb, col.a * alpha);
    } else if (in.mode < 1.5) {
        // Mode 1: Font glyph (R8 SDF when rectParams.x > 0, else bitmap alpha mask)
        let alphaMask = textureSample(uiTexture, uiSampler, in.uv).r;
        if (in.rectParams.x > 0.0) {
            // SDF baked via FreeType/SDL3_ttf with onedge=128/255 (0.50196078),
            // pixel_dist_scale=16/255 -> 255/16 = 15.9375.
            let sdPx = (alphaMask - 0.50196078) * 15.9375 * in.rectParams.x;
            let fillT = clamp(sdPx + 0.5, 0.0, 1.0);
            let outlineW = in.rectParams.w;
            if (outlineW > 0.0) {
                let outerAlpha = clamp(sdPx + outlineW + 0.5, 0.0, 1.0) * in.borderColor.a;
                let finalAlpha = mix(outerAlpha, in.color.a, fillT) * circleClipAlpha;
                if (finalAlpha <= 0.005) {
                    discard;
                }
                let finalRgb = mix(in.borderColor.rgb, in.color.rgb, fillT);
                return vec4<f32>(finalRgb, finalAlpha);
            }
            let finalA = in.color.a * fillT * circleClipAlpha;
            if (finalA <= 0.005) {
                discard;
            }
            return vec4<f32>(in.color.rgb, finalA);
        } else {
            let finalA = in.color.a * alphaMask * circleClipAlpha;
            if (finalA <= 0.01) {
                discard;
            }
            return vec4<f32>(in.color.rgb, finalA);
        }
    } else if (in.mode < 2.5) {
        // Mode 2: RGBA Texture / Image with optional rounded-corner SDF mask
        let tex = textureSample(uiTexture, uiSampler, in.uv);
        var outCol = tex * in.color;
        if (in.rectParams.z > 0.0) {
            let halfSize = in.rectParams.xy * 0.5;
            let r = min(in.rectParams.z, min(halfSize.x, halfSize.y));
            let q = abs(in.localPos) - halfSize + vec2<f32>(r, r);
            let dist = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
            let alpha = clamp(0.5 - dist, 0.0, 1.0);
            if (alpha <= 0.0) {
                discard;
            }
            outCol.a = outCol.a * alpha;
        }
        outCol.a = outCol.a * circleClipAlpha;
        if (outCol.a <= 0.0) {
            discard;
        }
        return outCol;
    } else if (in.mode < 3.5) {
        // Mode 3: Flat solid triangle / polygon
        let finalA = in.color.a * circleClipAlpha;
        if (finalA <= 0.001) {
            discard;
        }
        return vec4<f32>(in.color.rgb, finalA);
    } else {
        // Mode 4: Analytical SDF circle / ring / arc
        // localPos = pixel offset from center
        // rectParams = (innerR, outerR, startAngleRad, sweepAngleRad)
        let r = length(in.localPos);
        let outerDist = r - in.rectParams.y;
        let innerDist = in.rectParams.x - r;
        let radialDist = select(outerDist, max(outerDist, innerDist), in.rectParams.x > 0.0);

        var dist = radialDist;
        let sweep = abs(in.rectParams.w);
        if (sweep < 6.283) {
            let twoPi = 6.2831853;
            let pi = 3.14159265;
            let halfSweep = sweep * 0.5;
            var dAng = atan2(in.localPos.y, in.localPos.x) - (in.rectParams.z + halfSweep);
            dAng = dAng - twoPi * floor((dAng + pi) / twoPi);
            let clampedDiff = clamp(abs(dAng) - halfSweep, -1.5707963, 1.5707963);
            let angDist = r * sin(clampedDiff);
            dist = max(radialDist, angDist);
        }

        let alpha = clamp(0.5 - dist, 0.0, 1.0) * circleClipAlpha;
        if (alpha <= 0.0) {
            discard;
        }
        return vec4<f32>(in.color.rgb, in.color.a * alpha);
    }
}
