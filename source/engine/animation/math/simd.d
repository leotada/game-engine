/// 4-wide float/int vectors and 4x4 matrices: compile-time backend selection.
///
/// * `simd_vec` (`core.simd`) on DMD x86_64 and on LDC;
/// * `simd_ref` (scalar) elsewhere, or everywhere with `version(EngineAnimScalarMath)`.
///
/// Both expose the identical API (see `simd_backend`).
module engine.animation.math.simd;

version (EngineAnimScalarMath) {
    public import engine.animation.math.simd_ref;
} else version (D_SIMD) {
    public import engine.animation.math.simd_vec;
} else version (LDC) {
    public import engine.animation.math.simd_vec;
} else {
    public import engine.animation.math.simd_ref;
}
