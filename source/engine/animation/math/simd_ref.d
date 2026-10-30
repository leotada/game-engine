/// Scalar reference backend of the 4-wide math (plain per-lane arithmetic).
module engine.animation.math.simd_ref;

import engine.animation.math.simd_backend;

mixin SimdBackend!false;
