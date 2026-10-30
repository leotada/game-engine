// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/base/encode/group_varint.cc @ 744eb9d (decode side only)
/// Group-varint (GV4) decoding: 4 `u32` values share one prefix byte holding 2 bits per value
/// (`byte count - 1`), followed by the values in little-endian order with that many bytes.
///
/// Upstream loads 4 bytes per value regardless of its width and relies on buffer padding. This
/// decoder reads exactly `k + 1` bytes per value, so it never reads past the input.
module engine.animation.io.group_varint;

@safe pure nothrow @nogc:

/// Decodes `output.length` values (a multiple of 4) from `input`. Returns the number of input
/// bytes consumed, or `size_t.max` if the input is too short.
size_t decodeGV4Stream(const(ubyte)[] input, uint[] output) {
    assert(output.length % 4 == 0);
    size_t pos = 0;
    for (size_t g = 0; g < output.length; g += 4) {
        if (pos >= input.length) return size_t.max;
        immutable prefix = input[pos++];
        foreach (i; 0 .. 4) {
            immutable n = ((prefix >> (2 * i)) & 3) + 1;
            if (input.length - pos < n) return size_t.max;
            uint v = 0;
            foreach (b; 0 .. n) v |= cast(uint) input[pos + b] << (8 * b);
            pos += n;
            output[g + i] = v;
        }
    }
    return pos;
}

unittest {
    // Prefix 0b11_10_01_00: widths 1, 2, 3, 4 bytes.
    static immutable ubyte[] enc =[0b11_10_01_00, 0x01, 0x02, 0x01, 0x03, 0x02, 0x01, 0x04, 0x03, 0x02, 0x01];
    uint[4] out_;
    assert(decodeGV4Stream(enc, out_[]) == enc.length);
    assert(out_ == [0x01, 0x0102, 0x010203, 0x01020304]);
}

unittest {
    // Two groups back to back; only the first group's bytes are consumed per group.
    static immutable ubyte[] enc =[0, 1, 2, 3, 4, 0, 5, 6, 7, 8];
    uint[8] out_;
    assert(decodeGV4Stream(enc, out_[]) == enc.length);
    assert(out_ == [1, 2, 3, 4, 5, 6, 7, 8]);
}

unittest {
    // Truncation at every length is detected, including inside the last value.
    static immutable ubyte[] enc =[0b11_10_01_00, 0x01, 0x02, 0x01, 0x03, 0x02, 0x01, 0x04, 0x03, 0x02, 0x01];
    uint[4] out_;
    foreach (n; 0 .. enc.length) {
        assert(decodeGV4Stream(enc[0 .. n], out_[]) == size_t.max);
    }
}
