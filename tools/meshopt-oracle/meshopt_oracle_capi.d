/// C++ oracle entry points. This module is not part of the engine library.
/// Real symbols are compiled only with `-version=MeshoptOracle`.
module meshopt_oracle_capi;

version (MeshoptOracle)
extern (C) nothrow @nogc {
    ushort meshopt_quantizeHalf(float v);
    float meshopt_quantizeFloat(float v, int n);
    float meshopt_dequantizeHalf(ushort h);
    int meshopt_computePositionExponent(const(float)* minv, const(float)* maxv, int minExp, int maxBits);
    int meshopt_ref_quantizeUnorm(float v, int n);
    int meshopt_ref_quantizeSnorm(float v, int n);
}

version (MeshoptOracle) {

ushort refQuantizeHalf(float v) nothrow @nogc @trusted {
    return meshopt_quantizeHalf(v);
}

float refQuantizeFloat(float v, int n) nothrow @nogc @trusted {
    return meshopt_quantizeFloat(v, n);
}

float refDequantizeHalf(ushort h) nothrow @nogc @trusted {
    return meshopt_dequantizeHalf(h);
}

int refQuantizeUnorm(float v, int n) nothrow @nogc @trusted {
    return meshopt_ref_quantizeUnorm(v, n);
}

int refQuantizeSnorm(float v, int n) nothrow @nogc @trusted {
    return meshopt_ref_quantizeSnorm(v, n);
}

int refPositionExponent(const(float)[3] minv, const(float)[3] maxv, int minExp, int maxBits) nothrow @nogc @trusted {
    return meshopt_computePositionExponent(&minv[0], &maxv[0], minExp, maxBits);
}
} else {
ushort refQuantizeHalf(float) nothrow @nogc {
    return 0;
}

float refQuantizeFloat(float, int) nothrow @nogc {
    return 0;
}

float refDequantizeHalf(ushort) nothrow @nogc {
    return 0;
}

int refQuantizeUnorm(float, int) nothrow @nogc {
    return 0;
}

int refQuantizeSnorm(float, int) nothrow @nogc {
    return 0;
}

int refPositionExponent(const(float)[3], const(float)[3], int, int) nothrow @nogc {
    return 0;
}
}
