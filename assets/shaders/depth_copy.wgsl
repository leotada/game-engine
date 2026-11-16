#include "common/fullscreen_vs.wgsl"

@group(0) @binding(0) var srcDepth: texture_depth_2d;

@fragment
fn fs_main(in: VsOut) -> @builtin(frag_depth) f32 {
    return textureLoad(srcDepth, vec2<i32>(in.pos.xy), 0);
}
