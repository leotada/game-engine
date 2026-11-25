/// Reader for 3D color tables in the `.cube` text format.
module engine.assets.cube_lut;

import std.ascii : isDigit;

@safe:

/// A 3D color table: `size`^3 RGB entries, red changes fastest.
struct CubeLut {
    uint size;
    float[3] domainMin = [0, 0, 0];
    float[3] domainMax = [1, 1, 1];
    float[] rgb;

    bool valid() const pure nothrow @nogc {
        return size >= 2 && size <= 64 && rgb.length == cast(size_t) size * size * size * 3;
    }

    /// Table that changes nothing.
    static CubeLut identity(uint size) {
        CubeLut l;
        l.size = size;
        l.rgb.reserve(size * size * size * 3);
        foreach (b; 0 .. size) foreach (g; 0 .. size) foreach (r; 0 .. size)
            l.rgb ~= [r / (size - 1.0f), g / (size - 1.0f), b / (size - 1.0f)];
        return l;
    }
}

/// Parse a `.cube` text. Only 3D tables of 2 to 64 entries per side are
/// accepted. On failure the result is not `valid` and `error` says why.
CubeLut parseCubeLut(const(char)[] text, out string error) {
    import std.algorithm.searching : startsWith;
    import std.array : split;
    import std.conv : to;
    import std.math : isFinite;
    import std.string : lineSplitter, strip;

    CubeLut l;
    float[3] three(const(char)[][] f) {
        float[3] v;
        foreach (i; 0 .. 3) {
            v[i] = f[i].to!float;
            if (!isFinite(v[i])) throw new Exception("not a number");
        }
        return v;
    }
    size_t lineNo;
    foreach (raw; text.lineSplitter) {
        lineNo++;
        auto line = raw.strip;
        if (line.length == 0 || line[0] == '#') continue;
        auto f = line.split;
        try {
            immutable c = line[0];
            if (c.isDigit || c == '-' || c == '+' || c == '.') {
                if (l.size == 0) { error = "data before LUT_3D_SIZE"; return CubeLut.init; }
                if (f.length != 3) throw new Exception("3 values expected");
                l.rgb ~= three(f)[];
                if (l.rgb.length > cast(size_t) l.size * l.size * l.size * 3) { error = "too many entries"; return CubeLut.init; }
            } else if (f[0] == "LUT_3D_SIZE" && f.length == 2) {
                l.size = f[1].to!uint;
                if (l.size < 2 || l.size > 64) { error = "LUT_3D_SIZE must be 2 to 64"; return CubeLut.init; }
                l.rgb.reserve(cast(size_t) l.size * l.size * l.size * 3);
            } else if (f[0] == "LUT_1D_SIZE") {
                error = "1D tables are not supported";
                return CubeLut.init;
            } else if (f[0] == "DOMAIN_MIN" && f.length == 4) l.domainMin = three(f[1 .. $]);
            else if (f[0] == "DOMAIN_MAX" && f.length == 4) l.domainMax = three(f[1 .. $]);
            // TITLE and unknown keywords are ignored.
        } catch (Exception e) {
            error = "line " ~ lineNo.to!string ~ ": " ~ e.msg;
            return CubeLut.init;
        }
    }
    foreach (i; 0 .. 3)
        if (!(l.domainMax[i] > l.domainMin[i])) { error = "empty domain"; return CubeLut.init; }
    if (!l.valid) { error = l.size == 0 ? "no LUT_3D_SIZE" : "missing entries"; return CubeLut.init; }
    return l;
}

/// Read a `.cube` file.
CubeLut loadCubeLut(scope const(char)[] path, out string error) @trusted {
    import std.file : readText;
    try return parseCubeLut(readText(path.idup), error);
    catch (Exception e) {
        error = e.msg;
        return CubeLut.init;
    }
}

@("cubeLut.parse") unittest {
    string e;
    auto l = parseCubeLut("# comment\nTITLE \"x\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n"
        ~ "0 0 0\n1 0 0\r\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1.0 1 1e0\n", e);
    assert(l.valid && e.length == 0);
    assert(l.domainMax == [2.0f, 2.0f, 2.0f]);
    assert(l.rgb == CubeLut.identity(2).rgb);
    foreach (bad; ["", "0 0 0\n", "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n", "LUT_3D_SIZE 2\n0 0 0\n", "LUT_3D_SIZE 1\n",
                   "LUT_3D_SIZE 99\n", "LUT_3D_SIZE 2\n0 0\n", "LUT_3D_SIZE x\n", "LUT_3D_SIZE 2\n0 nan 0\n", "LUT_3D_SIZE 2\n0.1 -nan 0\n",
                   "LUT_3D_SIZE 2\nDOMAIN_MAX 0 1 1\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"]) {
        assert(!parseCubeLut(bad, e).valid && e.length, bad);
    }
    assert(!loadCubeLut("/nonexistent.cube", e).valid && e.length);
}
