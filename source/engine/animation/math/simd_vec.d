/// `core.simd` backend of the 4-wide math (`float4` arithmetic; hardware estimates on x86_64).
module engine.animation.math.simd_vec;

import engine.animation.math.simd_backend;

mixin SimdBackend!true;
