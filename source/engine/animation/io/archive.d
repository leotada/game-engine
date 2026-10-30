// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/base/io/archive.cc + include/ozz/base/io/archive.h @ 744eb9d (read side only)
/// Bounds-checked reader for ozz binary archives held in memory.
///
/// Framing: one endianness byte (0 = big, 1 = little), then objects, each made of a NUL-terminated
/// type tag, a `u32` version and a payload. Every multi-byte primitive uses the file's endianness;
/// values are assembled byte by byte so no native-endianness detection or unsafe casts are needed.
/// Reads never throw: a failed read sets `ok = false`, records `error`, and returns zero values.
module engine.animation.io.archive;

@safe pure nothrow:

private union FloatBits {
    uint u;
    float f;
}

struct InputArchive {
    @safe pure nothrow:

    private const(ubyte)[] data_;
    private size_t pos_;
    private bool littleEndian_ = true;
    bool ok = true;
    string error;

    this(const(ubyte)[] data) {
        data_ = data;
        if (data.length < 1) {
            fail("missing endianness byte");
            return;
        }
        immutable e = data[0];
        if (e > 1) {
            fail("invalid endianness byte");
            return;
        }
        littleEndian_ = e == 1;
        pos_ = 1;
    }

    size_t offset() const @nogc { return pos_; }
    size_t remaining() const @nogc { return data_.length - pos_; }
    bool empty() const @nogc { return pos_ >= data_.length; }

    void fail(string msg) @nogc {
        if (ok) {
            ok = false;
            error = msg;
        }
    }

    /// True if the next object has `tag` (which must include the terminating NUL, e.g.
    /// `"ozz-skeleton\0"`). Does not consume anything.
    bool nextIs(string tag) const @nogc {
        if (!ok || remaining() < tag.length) return false;
        foreach (i, c; tag) {
            if (data_[pos_ + i] != c) return false;
        }
        return true;
    }

    /// Consumes tag + version of the next object. Returns false (and sets the error) on mismatch.
    bool beginObject(string tag, out uint version_) @nogc {
        if (!nextIs(tag)) {
            fail("unexpected object tag");
            return false;
        }
        pos_ += tag.length;
        version_ = read!uint();
        return ok;
    }

    /// Reads one primitive (`ubyte`, `ushort`, `short`, `uint`, `int`, `float`).
    T read(T)() @nogc {
        enum n = T.sizeof;
        if (!ok || remaining() < n) {
            fail("unexpected end of archive");
            return T.init;
        }
        uint v = 0;
        foreach (i; 0 .. n) {
            immutable b = cast(uint) data_[pos_ + i];
            immutable shift = littleEndian_ ? 8 * i : 8 * (n - 1 - i);
            v |= b << shift;
        }
        pos_ += n;
        static if (is(T == float)) {
            FloatBits fb = {u: v};
            return fb.f;
        } else {
            return cast(T) v;
        }
    }

    /// Fills `dst` with consecutive primitives. Returns false on truncation.
    bool readArray(T)(scope T[] dst) @nogc {
        if (!ok) return false;
        if (remaining() / T.sizeof < dst.length) {
            fail("unexpected end of archive");
            return false;
        }
        foreach (ref e; dst) e = read!T();
        return ok;
    }

    /// Returns a view of the next `n` raw bytes and advances; empty slice + error on truncation.
    const(ubyte)[] readBytes(size_t n) @nogc {
        if (!ok || remaining() < n) {
            fail("unexpected end of archive");
            return null;
        }
        auto s = data_[pos_ .. pos_ + n];
        pos_ += n;
        return s;
    }
}

unittest {
    // Little-endian: endianness byte 1, then primitives.
    immutable ubyte[] le = [1, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x00, 0x00, 0x80, 0x3f];
    auto a = InputArchive(le);
    assert(a.ok);
    assert(a.read!ushort() == 0x1234);
    assert(a.read!uint() == 0x12345678);
    assert(a.read!float() == 1.0f);
    assert(a.empty && a.ok);
}

unittest {
    // Big-endian: same values, bytes reversed.
    immutable ubyte[] be = [0, 0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x3f, 0x80, 0x00, 0x00];
    auto a = InputArchive(be);
    assert(a.read!ushort() == 0x1234);
    assert(a.read!uint() == 0x12345678);
    assert(a.read!float() == 1.0f);
    assert(a.ok);
}

unittest {
    // Signed values and arrays.
    immutable ubyte[] le = [1, 0xff, 0xff, 0xfe, 0xff, 0xff, 0xff, 0x05];
    auto a = InputArchive(le);
    assert(a.read!short() == -1);
    assert(a.read!int() == -2);
    assert(a.read!ubyte() == 5);
}

unittest {
    immutable ubyte[] le = [1, 1, 0, 2, 0, 3, 0];
    auto a = InputArchive(le);
    ushort[3] out_;
    assert(a.readArray(out_[]));
    assert(out_ == [1, 2, 3]);
}

unittest {
    // Tags and versions.
    immutable ubyte[] file = [1, 'a', 'b', 0, 2, 0, 0, 0];
    auto a = InputArchive(file);
    assert(a.nextIs("ab\0"));
    assert(!a.nextIs("ac\0"));
    uint ver;
    assert(a.beginObject("ab\0", ver) && ver == 2);
    assert(a.empty);

    auto b = InputArchive(file);
    assert(!b.beginObject("zz\0", ver));
    assert(!b.ok);
}

unittest {
    // Truncation at every byte offset fails cleanly, never throws.
    immutable ubyte[] file = [1, 'a', 'b', 0, 2, 0, 0, 0, 1, 0, 2, 0];
    foreach (n; 0 .. file.length) {
        auto a = InputArchive(file[0 .. n]);
        uint ver;
        ushort[2] arr;
        bool good = a.beginObject("ab\0", ver) && a.readArray(arr[]);
        assert(good == (n == file.length));
    }
    auto bad = InputArchive([cast(ubyte) 7]);
    assert(!bad.ok);
}
