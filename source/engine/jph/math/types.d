// Jolt — Math/MathTypes.h port. Forward type aliases.
//
// In Jolt these are `using Vec3Arg = const Vec3` style aliases that pass
// SIMD types through registers. D structs of one SIMD field already pass
// in registers under most ABIs, so the alias is a passthrough.
//
// Source: ref/JoltPhysics/Jolt/Math/MathTypes.h.
module engine.jph.math.types;

import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.uvec4;
import engine.jph.math.quat;
import engine.jph.math.mat44;

@safe:

alias Vec3Arg  = Vec3;
alias Vec4Arg  = Vec4;
alias UVec4Arg = UVec4;
alias QuatArg  = Quat;
alias Mat44Arg = Mat44;
