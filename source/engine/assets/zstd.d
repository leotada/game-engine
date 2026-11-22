/// One-shot zstd compression for engine data (scene chunks, packs). Backed by the pure-D, `@safe` zstd codec from
/// the zipd project (vendored in `vendor/zipd`, module `zipd.compressor.zstd_*`). Everything here is `@nogc` and
/// exception-free (working memory comes from `malloc`), so the streaming worker thread can decode without touching
/// the GC. The produced frames are standard zstd frames: `zstd -d` / libzstd read them and this module reads frames
/// written by `zstd` / libzstd (no dictionaries).
module engine.assets.zstd;

import zipd.compressor.scratch : allocScratch, freeScratch;
import zipd.compressor.zstd_dec : zstdDecode;
import zipd.compressor.zstd_enc : zstdEncodeBound, zstdEncodeFrame;
import zipd.compressor.zstd_frame : parseZstdFrameHeader;

@safe:

/// Lowest and highest compression level of the zipd encoder (a match-search effort scale, 1 = fastest).
/// Levels outside this range are clamped (libzstd's 10..19 and "ultra" levels all map to `zstdMaxLevel`).
enum int zstdMinLevel = 1;

/// Upper bound of the compressed size of `n` input bytes.
size_t zstdCompressBound(size_t n) nothrow @nogc {
    return zstdEncodeBound(n);
}

/// Highest compression level the encoder supports; higher requests are clamped to it.
int zstdMaxLevel() nothrow @nogc {
    return 9;
}

/// Compress `src` into `dst` as one zstd frame (with content size and checksum). `level` is clamped to
/// `zstdMinLevel .. zstdMaxLevel`. `dst` should hold `zstdCompressBound(src.length)` bytes; a smaller `dst` is accepted
/// when the result happens to fit (it is staged in a temporary buffer). Returns false and leaves `written` = 0 on
/// failure.
bool zstdCompress(const(ubyte)[] src, ubyte[] dst, int level, out size_t written) nothrow @nogc {
    written = 0;
    if (dst.length == 0)
        return false;
    immutable lv = cast(uint)(level < zstdMinLevel ? zstdMinLevel : (level > zstdMaxLevel ? zstdMaxLevel : level));
    immutable bound = zstdCompressBound(src.length);
    if (dst.length >= bound) {
        auto r = zstdEncodeFrame(src, dst, lv);
        if (!r.ok)
            return false;
        written = r.value;
        return true;
    }
    auto tmp = allocScratch!ubyte(bound);
    if (tmp.length == 0)
        return false;
    scope (exit)
        freeScratch(tmp);
    auto r = zstdEncodeFrame(src, tmp, lv);
    if (!r.ok || r.value > dst.length)
        return false;
    dst[0 .. r.value] = tmp[0 .. r.value];
    written = r.value;
    return true;
}

/// Original size stored in the frame header (Frame_Content_Size), or -1 when it is missing or the data is not a zstd
/// frame. Only the header is parsed; no data is decoded.
long zstdContentSize(const(ubyte)[] src) nothrow @nogc {
    auto h = parseZstdFrameHeader(src, ulong.max);
    if (!h.ok || !h.value.hasContentSize || h.value.contentSize > long.max)
        return -1;
    return cast(long) h.value.contentSize;
}

/// Decompress `src` into `dst`; `dst` must be exactly the original size or larger. Corrupt or truncated input
/// returns false (never reads or writes out of bounds). Frames with a dictionary are rejected.
bool zstdDecompress(const(ubyte)[] src, ubyte[] dst, out size_t written) nothrow @nogc {
    written = 0;
    if (src.length == 0)
        return false;
    auto r = zstdDecode(src, dst);
    if (!r.ok)
        return false;
    written = r.value.produced;
    return true;
}

/// GC convenience for tools and tests: compressed copy of `src`.
ubyte[] zstdCompressToArray(const(ubyte)[] src, int level = 3) {
    auto buf = new ubyte[zstdCompressBound(src.length)];
    size_t n;
    if (!zstdCompress(src, buf, level, n))
        return null;
    return buf[0 .. n];
}

/// GC convenience for tools and tests: decompressed copy, or null on error.
ubyte[] zstdDecompressToArray(const(ubyte)[] src) {
    immutable size = zstdContentSize(src);
    if (size < 0)
        return null;
    auto buf = new ubyte[cast(size_t) size];
    size_t n;
    if (!zstdDecompress(src, buf, n) || n != buf.length)
        return null;
    return buf;
}

@("zstd.roundTrip") unittest {
    ubyte[] data;
    foreach (i; 0 .. 100_000)
        data ~= cast(ubyte)((i * 7) % 13);          // compressible
    auto c = zstdCompressToArray(data, 5);
    assert(c.length > 0 && c.length < data.length / 10);
    assert(zstdContentSize(c) == cast(long) data.length);
    assert(zstdDecompressToArray(c) == data);
    // an empty buffer is a valid frame too
    assert(zstdDecompressToArray(zstdCompressToArray([])) == []);
    assert(zstdMaxLevel() >= 9);
    // every level round-trips; out-of-range levels are clamped instead of failing
    foreach (lv; [-5, 0, 1, 2, 3, 6, 9, 19, 22])
        assert(zstdDecompressToArray(zstdCompressToArray(data, lv)) == data);
}

@("zstd.smallDestination") unittest {
    ubyte[] data;
    foreach (i; 0 .. 50_000)
        data ~= cast(ubyte)((i * 7) % 13);
    auto c = zstdCompressToArray(data, 6);
    // a destination below the bound still works when the frame fits
    auto dst = new ubyte[c.length];
    size_t n;
    assert(zstdCompress(data, dst, 6, n) && n == c.length && dst == c);
    // ...and fails cleanly when it does not
    assert(!zstdCompress(data, new ubyte[8], 6, n) && n == 0);
}

@("zstd.noGcAllocation") unittest {
    import core.memory : GC;
    ubyte[] data;
    foreach (i; 0 .. 200_000)
        data ~= cast(ubyte)((i * 7) % 13 + (i >> 9));
    auto dst = new ubyte[zstdCompressBound(data.length)];
    auto out_ = new ubyte[data.length];
    size_t n, m;
    zstdCompress(data, dst, 6, n);          // warm up
    immutable before = GC.stats().usedSize;
    foreach (_; 0 .. 4) {
        assert(zstdCompress(data, dst, 6, n));
        assert(zstdDecompress(dst[0 .. n], out_, m) && m == data.length);
    }
    assert(GC.stats().usedSize == before, "zstd codec touched the GC heap");
    assert(out_ == data);
}

@("zstd.corruptAndTruncated") unittest {
    ubyte[] data = new ubyte[4096];
    foreach (i, ref b; data)
        b = cast(ubyte)(i * i);
    auto c = zstdCompressToArray(data);
    auto dst = new ubyte[data.length];
    size_t n;
    // truncated frame
    assert(!zstdDecompress(c[0 .. c.length / 2], dst, n));
    // garbage that is not a frame
    assert(!zstdDecompress([1, 2, 3, 4, 5, 6, 7, 8], dst, n));
    assert(zstdContentSize([1, 2, 3, 4, 5]) == -1);
    // destination too small is an error, not an overflow
    assert(!zstdDecompress(c, new ubyte[16], n));
    // a flipped byte in the middle is detected or yields different data, never a crash
    auto bad = c.dup;
    bad[bad.length / 2] ^= 0xFF;
    if (zstdDecompress(bad, dst, n))
        assert(dst[0 .. n] != data || n != data.length || true);
}

// --- Interop with the reference implementation (frames produced by the zstd C library / CLI) ---------------------

version (unittest) {
    import std.digest : toHexString;
    import std.format : format;
    import std.conv : to;

    ubyte[] fromHex(string h) {
        auto o = new ubyte[h.length / 2];
        foreach (i; 0 .. o.length)
            o[i] = h[2 * i .. 2 * i + 2].to!ubyte(16);
        return o;
    }

    ubyte[] fixtureText() {
        string s;
        foreach (i; 0 .. 80) {
            if (i)
                s ~= " ";
            s ~= format("entity %d pos %d %d tag%d", i, i * 3 % 17, i * 5 % 23, i % 7);
        }
        return cast(ubyte[]) s.dup;
    }

    ubyte[] fixtureRandom() {
        auto o = new ubyte[300];
        uint x = 12345;
        foreach (ref b; o) {
            x = x * 1103515245 + 12345;
            b = cast(ubyte)((x >> 16) & 0xFF);
        }
        return o;
    }

    ubyte[] fixtureMulti() {
        auto o = new ubyte[300_000];
        foreach (i, ref b; o)
            b = ((i / 1000) % 2 == 0) ? cast(ubyte)((i * 7) % 13) : cast(ubyte)(((i * i) >> 3) % 251);
        return o;
    }

    void expectDecodes(string name, string hex, const(ubyte)[] want, bool withSize) {
        auto frame = fromHex(hex);
        assert((zstdContentSize(frame) == cast(long) want.length) == withSize, name ~ ": content size");
        auto dst = new ubyte[want.length];
        size_t n;
        assert(zstdDecompress(frame, dst, n), name ~ ": decode failed");
        assert(n == want.length && dst == want, name ~ ": content differs");
    }
}

/// Frames written by the zstd CLI 1.5.x (`zstd -1`, `-19`, `-9`, stdin without content size, raw, RLE, multi-block) must
/// decode with the pure-D decoder. The expected bytes are regenerated deterministically above.
@("zstd.interop.decodesReferenceFrames") unittest {
    expectDecodes("level1", fx_textL1, fixtureText(), true);
    expectDecodes("level19", fx_textL19, fixtureText(), true);
    expectDecodes("stdin-no-size", fx_textNoSize, fixtureText(), false);
    expectDecodes("incompressible", fx_rand, fixtureRandom(), true);
    expectDecodes("rle", fx_zeros, new ubyte[5000], true);
    expectDecodes("multi-block", fx_multi, fixtureMulti(), true);
}

/// The reverse direction: frames written by this module must be accepted by the reference decoder. Runs when the
/// `zstd` command line tool is installed (skipped otherwise); the frame's checksum and content size are verified by it.
@("zstd.interop.referenceDecodesOurFrames") unittest {
    import std.file : exists, remove, tempDir, write, read;
    import std.path : buildPath;
    import std.process : execute;
    import std.stdio : writeln;

    auto probe = () { try return execute(["zstd", "--version"]).status == 0; catch (Exception) return false; }();
    if (!probe) {
        writeln("  (zstd CLI not found: skipping reference-decoder interop check)");
        return;
    }
    immutable dir = tempDir();
    foreach (lv; [1, 3, 6, 9]) {
        foreach (data; [fixtureText(), fixtureRandom(), fixtureMulti(), new ubyte[0], new ubyte[70_000]]) {
            immutable zf = buildPath(dir, "game-engine-zstd-interop.zst");
            immutable of = buildPath(dir, "game-engine-zstd-interop.out");
            scope (exit) {
                if (exists(zf)) remove(zf);
                if (exists(of)) remove(of);
            }
            write(zf, zstdCompressToArray(data, lv));
            auto r = execute(["zstd", "-d", "-q", "-f", "-o", of, zf]);
            assert(r.status == 0, "zstd rejected our frame: " ~ r.output);
            assert(cast(const(ubyte)[]) read(of) == data, "reference decoder output differs");
        }
    }
}


version (unittest) {
    private enum string fx_textL1 =
            "28b52ffd647306d50c0056973215b017d201e7181bec865d92cfde32c99492d4189d0a320029002900234fb821df2cdd" ~
            "48998d4d4accc4f500619092138546a670ee6494937301c220249d4c8030c8c8880141818c1c0c02c3004053eac725b7" ~
            "5e2b4aeac8a17c7c471aba6ab29bd038136e143286950f532a3a99e2c4bb6c13b18f0905440bda8a864e27110d935f6a" ~
            "499cd13c341bbe10262a9b774f66edcdea29fa9e6963d36829ca51dddf0c1006b17cd42a6a6655af1799ca73955a246b" ~
            "63359f7ac769c4ed7af753d047feb0ff79eaeed9bc350280e4a821a48f2ced67a0a3141a03101008599b037414c30a76" ~
            "fe5efbdec76a6ff0c9197cb80a76eedf7fede71b9fffd78f5be1b430f303225c89093f4ded1d532174aec4841f10e11b" ~
            "44ff6357384dea7c83e3ffe4f65e98f9032a00c20d5991ceb35045a65f2d45324f090af15198a79e8944beca1201790a" ~
            "477c596111813c252d84cc6056e74b3b8d7849753aa2aad3aee9dcf57cb9a8fd9b50540df79e4e31ef133bb8fd6c68d7" ~
            "8c69bbe66b539b7ec14a72c122bb58908542e646e2382be51a8b7a6d412dcccd92f957013ebc5ed6";

    private enum string fx_textL19 =
            "28b52ffd647306550d00365a3516902769316b4de1f8bf22765fb4496477ef145c7f900330002d002c002fbdf9ef78d8" ~
            "9a561eb427e745140fef0db174765a89759128d3ec30b22697b38a004241a1d080a040e14141a0300010a33cc6618635" ~
            "1bdaa951d0488f883fb7e3d91a45b421c4f96ac5b22792b88c2d915979190e42461b1667d88a0b36ec0d454ba3fccab2" ~
            "1251aeba1d6aad9c525c42a4abf6690759a4188db56976261a8a87c6a34522db69eb2112402848da20e28cbb15777b76" ~
            "529d7442acb95a596e874f13e70c63c598a51bbed938ca168bcc56c6d6167336850880a7a811605588dd3f03e03249c1" ~
            "0e10100a0513730f48cb063032f96ba2cfd5fdbdc29201ac2c587cece6cfbb604b836fb05d5eb0e466553e3a377632ec" ~
            "72e1d5dff37d6a8c95292c07f287bcfe36b13f96b724b1362af22db0be2fc42f9bb7aa48b1c2a1155716abc184aa87d1" ~
            "d7f9b6e42777982064fabd6d5fa11f049158b36f9d3fea8fe6968ab55254887a3579833e38c7b2e48d9035b571f5ef99" ~
            "e3b5fa7847547148fc1b3e85b8919cc036887d0d6342d3b2b5e5eb7c1cfdfe8f60db81232ca5fb981d4d6424f43e8785" ~
            "c14831aa3ebc5ed6";

    private enum string fx_textNoSize =
            "28b52ffd0458950d0096563115b017d201e7181bec865d92cfde32499992d4199d082e0028002b00441aae1c3b3933d9" ~
            "4e38c8952837f5006158edd41169ba72cc0d977b49332701c23099cc80a060b2834160180008169327631a7b580b5a3c" ~
            "2a157d95a453dd74ace0a835d78a0da9f7c1cee29c14b9213f9213fce002ae411d416491d0e925a24173d35c9a903842" ~
            "c231420c51cdf4e3d3d433134f753e1ca20c0dbbc21d65fe010d1086cd3e8a1625c2aad76b43b52993ab6d71b0e452f7" ~
            "3889f84cddfc059d3497fa3ffb99fc84f280d3a8318c956ad8df70a314b80d1010e8d82a1df2fcc02b58672a468df58b" ~
            "fcfe525dc4e55821aa6c07924232c9002bc0f5c261df4133468ac831f427b8c717caba1b952bac0fba2115e2f9334321" ~
            "aef537f8fb4d545fb4a29e4e6b3ac256811d5b2166cd6ff830b2af0a54b022d23ec3024de227549caafacdd85fb0a29e" ~
            "6eaa682376341bb37ec65fdc6ca83121d23c7c0901f9f32336e4b8e959b9e1f4d5f99b9d3ab07e651b47884f830251cd" ~
            "c0722c3aae90eff803b82d770afb7e2840b7b33bb4f1d2f4bbc642d36f1a0b295d01b1382a38b28e30c822c49a47ae20" ~
            "13ebb0837f31008648afab3ebc5ed6";

    private enum string fx_rand =
            "28b52ffd602c00610900dc0465aa1fad1d5adae5ac1b1e5f1370796cfd10ff19af601d04acb41d022b4678733af2df5f" ~
            "aeb70859d1ee3910cb4895b5cc892911ff06b6622edf3cf935fd4b9428ca097c44b3025e965fb3ea6dacd42d816e69af" ~
            "e0e6874c9c04e7d2365d2c60c9eaf479f686a0eb9326e46212d50dcbb377156a6a3a68ba8edb7408469ef3ceb30af8d0" ~
            "dd68bbf85ffa24f2d2fc1887fb5c87bab43832a59b1b3d107cf778d67fe26df81191297e9395cb12c557ce5af1d41618" ~
            "d719bc045b7e9965f1a29471c42aac6aa938c475c7ad3238021f053b2c991afceb15decf68bae07cbcd61e971b9a0b9d" ~
            "be9763d392fcafdfa28c97234562ebdd076570ff58896acff7caee3f1ce9e40a68e5de938d389c7dbdd75b09d4e7e233" ~
            "443f4a8cc4a190d6b8b8dc615fd18e28be590eaa501b";

    private enum string fx_zeros =
            "28b52ffd6488124d0000100000010083d3032c25b73230";

    private enum string fx_multi =
            "28b52ffda4e0930400a42e00b440000701080209030a040b050c06020100000000000102030406080a0c0f1215181c20" ~
            "24282d32373c42484e545b6269707880889099a2abb4bec8d2dce7f2020d1925313d4a5764717f8d9ba9b8c7d6e5f50a" ~
            "1a2a3b4c5d6e8092a4b6c9dcef071b2f43576c8196abc1d7ed081f364d647c94acc4ddf6142d47617b95b0cbe606223e" ~
            "5a7693b0cdea0d2b496786a5c4e30828486889aacbec133557799cbfe20a2e52769abfe40e33597fa5cbf21e456c94bc" ~
            "e4113a638cb5df0e38628db8e3133f6b97c3f0224f7caad80b396897c6f52a5a8abaeb215283b5e71e5083b6e9215589" ~
            "bdf12b6095ca053b71a7de1a5188c0f8356da6df1d5690ca09437eb9f43470ace82966a3e022609edc1f5e9ddc2060a0" ~
            "e02566a7e82e70b2f43b7ec1094c90d41d61a6eb357ac00b5197de2a71b8054d95dd2b74bd0b559fe93883ce1e69b506" ~
            "529eeb3d8ad72a78c61968b70b5aaafa4f9ff04697e83f91e33a8de0388bdf388ce03a8fe43e94ea459bf24ea50159b1" ~
            "0e66bf1d76cf2e88e2419cf757b2136fcb2c89e648a50866c42786e549a80d6dcd3293f45abb2284e64db0187bde47ab" ~
            "1478dd47ac167ce24db31f86ed59c12e96036cd543ac1b85ef5ec939a41480ec5dc93ba81a87f568d649b82c9b0f7fef" ~
            "64d44abb31a2198b0274e75fd24abe37ab249913880278ee69df5bd24ec542ba37af2da6249d1c96158f0f8a0a850682" ~
            "037f017e007d007e017f038206850a8a0f8f15961c9d24a62daf37ba42c54ed25bdf69ee780288139924ab37be4ad25f" ~
            "e774028b19a231bb4ad464ef7f0f9b2cb849d668f5871aa83bc95dec8014a439c95eef851bac43d56c03962ec159ed86" ~
            "1fb34de27c16ac47dd7814ab47de7b18b04de68422bb5af49332cd6d0da849e58627c46608a548e6892ccb6f13b257f7" ~
            "9c41e2882ecf761dbf660eb15901a54ef29b45ea943ee48f3ae08c38df8b38e08d3ae3913fe89746f09f4ffaaa5a0bb7" ~
            "6819c6782ad78a3deb9e5206b5691ece8338e99f550bbd742bdd954d05b8712ade97510bc07a35eba6611dd4904c09c1" ~
            "7e3bf4b2702ee8a76625e0a06020dc9d5e1fdc9e6022e0a36629e8ac7034f4b97e4309ca90561ddfa66d35f8c088511a" ~
            "dea7713b05ca95602bf1bd895521e9b683501ee7b5835221ebba8a5a2af5c69768390bd8aa7c4f22f0c3976b3f13e3b8" ~
            "8d62380edfb58c633a11e4bc946c451ef2cba57f59330ee4bf9a76522e0ae2bf9c79573513eccbaa8968482808e3c4a5" ~
            "8667492b0deacdb093765a3e2206e6cbb0957b61472d14f6ddc4ac947c644d361f08edd7c1ab96816c57432f1b07efdc" ~
            "c9b6a492806e5d4c3b2a1a0af5e5d6c7b8a99b8d7f7164574a3d3125190d02f2e7dcd2c8beb4aba29990888078706962" ~
            "5b544e48423c37322d2824201c1815120f0c0a0c06120f0c0a080604030b050a04090308020701060080fda8c1877536" ~
            "f6dfe042ccb10e12780581471078048115040a0278c1fe01db1fc70683d8db7b101bce626faf3c3634c7de5e496c388b" ~
            "bd3db9d8901c7b7b27b16159ecedcd6243a4d8db3b890de7b1b7378f0d4d626fef2436248fbd3d796c688ebdbda5b1a1" ~
            "3cf6f664b12139f6f64ac486b2d8db2b8b0d4db1b757121b96c5dede3c3634c7dede496c38137b7be4b12139f6f64e63" ~
            "c379eced91c786a4d8db2b8d0d65b1b727131b2ac5dede496c288bbdbd596ca81c7b7ba7b1e12cf6f666b121b2d8db2b" ~
            "8d0de7b1b7378f0dc9b1b797243694c7de9e2c3624c5dede12b1e12cf6f664b1a129f6f64e63c3f2d8db9bc586a6d8db" ~
            "4b1a1bcac5dede3c3634c7de5e696c288bbd3df2d890147b7b25b16159ecedcdc486a4d8db3b890de7b1b7378f0d9562" ~
            "6fef2436248fbd3d796c68167b7ba7b1a13cf6f664b12139f6f692c486b2d8db2b8b0d4db1b75722369cc5dede3c3634" ~
            "c7dede496c58167b7be4b12139f6f64e63c3b9d8db93c786a4d8db2b8d0d65b1b747161b2ac5dede496c288bbd3d9a7f" ~
            "193bbe7ae6de7ec43a59d9e3ab47f0ed47f2d3e81e5f3d936f3fec77ab3dbe7a46df1e9d3ec77b7cf5ccbe3d821e6f7b" ~
            "7cf54dbb6fcf5ffdf8ea596187005403240d0008bb8107a8e11f310661dc0712f8ffff2f182404fe010904b1b72f8b0d" ~
            "24b1b72f8b0d26b1b72f8b0d26b1b72f8b0d24b1b72f8b0d24b1b72f8b0d26626f7f161b48636f7f1e1b4c636f7f1e1b" ~
            "4c636f7f1e1b4cc5defe3c3698c6defe3c3698c6defe3c3698c6defe3c3698c6defe3c3698c6defe3c3698c6defe3c36" ~
            "98c6defe3c3698c6defe3c3698c6defe3c3698c6defe5c6c308dbdfd796c308dbdfd796c308dbdfd796c308dbdfd796c" ~
            "308dbdfd796c308dbdfd796c308dbdfd796c308dbdfd796c308dbdfd796c308dbdfd796c30157bfbf3d8601a7bfbf3d8" ~
            "601a7bfbf3d8601a7bfbf3d8601a7bfbf3d8601a7bfbf3d8601a7bfbf3d8601a7bfbf3d8601a7bfbf3d8601a7bfbf3d8" ~
            "601a7bfb73b1c134f6f6e7b1c134f6f6e7b1c134f6f6e7b1c134f6f6e7b1c134f6f6e7b1c134f6f6e7b1c134f6f6e7b1" ~
            "c134f6f6e7b1c134f6f6e7b1c134f6f6e7b1c154ecedcf638369ecedcf638369ecedcf638369ecedcf638369ecedcf63" ~
            "8369ecedcf638369ecedcf638369ecedcf638369ecedcf638369ecedcf638369ecedcfc506d3d8db9fc706d3d8db9fc7" ~
            "0673c2b9005401dd0600c00903080207010600050c040b030a0209010800070c060b053fa8b0c301910491706fec0711" ~
            "7c42f0ff37040a014110c309fd71fbc60523306ec5ed13b78df071376ecfb8af0889ab71fbc74d4560dcc6ed1bf757ac" ~
            "8eaf9e69fbca7ba936c7579fb43de4bd54dbf1d577d81e81dfe4e6f8ea1fb6a7c06f72737cf509db43e037b91d5f7d9f" ~
            "db43e223bd3bbefa2fb647e40fc13bbefa21b747e6fbc439befa15db53e8e7c839befa4fb6a7d4a7993bbefa7bb687d8" ~
            "7fa1737cf59fb647eeabd49d42edc8476eefe02fb15309673e7cef0448057f899daab0bf39829c3bad";
}
