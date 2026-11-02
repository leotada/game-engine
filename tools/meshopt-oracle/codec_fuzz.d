// libFuzzer harness for the meshopt decoders and filters. Meshlets are M9.
// Build: dub build --config=meshopt-fuzz --compiler=ldc2
module codec_fuzz;

import engine.meshopt.codec.filter;
import engine.meshopt.codec.index;
import engine.meshopt.codec.vertex;

private ubyte[66 * 32] gVert;
private ushort[66] gI16;
private uint[66] gI32;
private ubyte[1 << 20] gEnc;
private ubyte[1024 * 32] gBack;

extern (C) int LLVMFuzzerTestOneInput(const(ubyte)* data, size_t size) {
    const(ubyte)[] src = data[0 .. size];
    enum size_t count = 66;
    decodeIndexBuffer(gI16[], src);
    decodeIndexBuffer(gI32[], src);
    decodeIndexSequence(gI16[], src);
    decodeIndexSequence(gI32[], src);

    foreach (stride; [4, 16, 24, 32])
        decodeVertexBuffer(gVert[0 .. count * stride], count, stride, src);

    ubyte lead = size ? src[0] : 0;
    int level = lead % 4;
    int ver = (size > 1 && src[1] % 2 == 0) ? 0 : 1;
    fuzzRoundtrip(src, 4, level, ver);
    fuzzRoundtrip(src, 16, level, ver);
    fuzzRoundtrip(src, 32, level, ver);

    if (size >= 4) {
        size_t n = 4 + (src[0] % 28);
        ubyte[] oct = gBack[0 .. n * 4];
        oct[] = 0;
        size_t take = n * 4 < size ? n * 4 : size;
        oct[0 .. take] = src[0 .. take];
        decodeFilterOct(oct, n, 4);
        decodeFilterColor(oct, n, 4);
        decodeFilterExp(oct, n, 4);
        ubyte[] wide = gBack[0 .. n * 8];
        wide[] = 0;
        size_t take8 = n * 8 < size ? n * 8 : size;
        wide[0 .. take8] = src[0 .. take8];
        decodeFilterOct(wide, n, 8);
        decodeFilterQuat(wide, n, 8);
        decodeFilterColor(wide, n, 8);
        decodeFilterExp(wide, n, 8);
    }
    return 0;
}

private void fuzzRoundtrip(const(ubyte)[] src, size_t stride, int level, int ver) {
    if (src.length < stride || stride % 4 != 0)
        return;
    size_t count = src.length / stride;
    if (count > 1024)
        count = 1024;
    const(ubyte)[] verts = src[0 .. count * stride];
    size_t bound = encodeVertexBufferBound(count, stride);
    if (bound > gEnc.length || count * stride > gBack.length)
        return;
    ubyte[] enc = gEnc[0 .. bound];
    size_t n = encodeVertexBufferLevel(enc, verts, count, stride, level, ver);
    if (n == 0 || n > bound)
        return;
    ubyte[] back = gBack[0 .. count * stride];
    if (decodeVertexBuffer(back, count, stride, enc[0 .. n]) != 0)
        return;
    foreach (i; 0 .. back.length)
        if (back[i] != verts[i])
            assert(0);
}
