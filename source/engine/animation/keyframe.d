// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/animation_keyframe.h @ 744eb9d
/// Compressed keyframe formats.
module engine.animation.keyframe;

@safe:

/// Offsets to previous keyframes are stored on 16 bits.
enum uint kMaxPreviousOffset = (1 << 16) - 1;

/// Translation / scale key: three IEEE binary16 components.
struct Float3Key {
    ushort[3] values;
}

/// Rotation key (smallest-three compression). 48 bits: 2 bits index of the largest component,
/// 1 sign bit of the largest component, then the 3 smallest components on 15 bits each.
struct QuaternionKey {
    ushort[3] values;

    enum int kBits = 15;
    enum int kiScale = (1 << kBits) - 1;
    enum float kfScale = cast(float) kiScale;
}

pure nothrow @nogc {
    void pack(int largest, int sign, const int[3] cpnt, out QuaternionKey key) {
        immutable ulong packed = (largest & 0x3) | ((sign & 0x1) << 2)
            | (cast(ulong)(cpnt[0] & 0x7fff) << 3)
            | (cast(ulong)(cpnt[1] & 0x7fff) << 18)
            | (cast(ulong)(cpnt[2] & 0x7fff) << 33);
        key.values[0] = packed & 0xffff;
        key.values[1] = (packed >> 16) & 0xffff;
        key.values[2] = (packed >> 32) & 0xffff;
    }

    void unpack(const QuaternionKey key, out int largest, out int sign, out int[3] cpnt) {
        immutable uint packed = (cast(uint) key.values[0] >> 3)
            | (cast(uint) key.values[1] << 13)
            | (cast(uint) key.values[2] << 29);
        largest = key.values[0] & 0x3;
        sign = (key.values[0] >> 2) & 0x1;
        cpnt[0] = packed & 0x7fff;
        cpnt[1] = (packed >> 15) & 0x7fff;
        cpnt[2] = key.values[2] >> 1;
    }
}

unittest {
    foreach (largest; 0 .. 4) {
        foreach (sign; 0 .. 2) {
            immutable int[3] c = [0x7fff, 0x1234, 0x0001];
            QuaternionKey k;
            pack(largest, sign, c, k);
            int l, s;
            int[3] o;
            unpack(k, l, s, o);
            assert(l == largest && s == sign && o == c);
        }
    }
    // Component extremes survive the 48-bit packing.
    foreach (a; [0, 1, 0x4000, 0x7fff]) {
        foreach (b; [0, 0x7fff, 0x2aaa]) {
            immutable int[3] c = [a, b, 0x7fff - a];
            QuaternionKey k;
            pack(3, 1, c, k);
            int l, s;
            int[3] o;
            unpack(k, l, s, o);
            assert(o == c && l == 3 && s == 1);
        }
    }
    static assert(Float3Key.sizeof == 6 && QuaternionKey.sizeof == 6);
}
