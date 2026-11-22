/**
 * XXH64 (seed-configurable), used for the ZSTD frame content checksum.
 *
 * RFC 8878 stores the low 32 bits of XXH64(content, seed = 0) in
 * little-endian order after the last block of a frame.
 */
module zipd.compressor.xxhash;

import core.bitop : rol;

@safe:
nothrow:
@nogc:

private enum ulong prime1 = 0x9E3779B185EBCA87UL;
private enum ulong prime2 = 0xC2B2AE3D27D4EB4FUL;
private enum ulong prime3 = 0x165667B19E3779F9UL;
private enum ulong prime4 = 0x85EBCA77C2B2AE63UL;
private enum ulong prime5 = 0x27D4EB2F165667C5UL;

private ulong rd64(scope const(ubyte)[] p) pure nothrow @nogc
{
    return cast(ulong) p[0]
        | (cast(ulong) p[1] << 8)
        | (cast(ulong) p[2] << 16)
        | (cast(ulong) p[3] << 24)
        | (cast(ulong) p[4] << 32)
        | (cast(ulong) p[5] << 40)
        | (cast(ulong) p[6] << 48)
        | (cast(ulong) p[7] << 56);
}

private ulong rd32(scope const(ubyte)[] p) pure nothrow @nogc
{
    return cast(ulong) p[0]
        | (cast(ulong) p[1] << 8)
        | (cast(ulong) p[2] << 16)
        | (cast(ulong) p[3] << 24);
}

private ulong round(ulong acc, ulong input) pure nothrow @nogc
{
    acc += input * prime2;
    acc = rol(acc, 31);
    return acc * prime1;
}

private ulong mergeRound(ulong acc, ulong val) pure nothrow @nogc
{
    acc ^= round(0, val);
    return acc * prime1 + prime4;
}

/// Streaming XXH64 accumulator. Chunk boundaries do not affect the result.
struct Xxh64
{
    private ulong[4] v;
    private ubyte[32] tail;
    private size_t tailLen;
    private ulong total;
    private ulong seed;

    /// Reset with `seed`.
    void reset(ulong seed = 0) pure nothrow @nogc
    {
        this.seed = seed;
        v[0] = seed + prime1 + prime2;
        v[1] = seed + prime2;
        v[2] = seed;
        v[3] = seed - prime1;
        tailLen = 0;
        total = 0;
    }

    /// Consume `data`.
    void put(scope const(ubyte)[] data) pure nothrow @nogc
    {
        if (total == 0 && tailLen == 0 && v[0] == 0 && v[1] == 0
            && v[2] == 0 && v[3] == 0)
            reset(seed); // default-initialised struct
        total += data.length;
        if (tailLen + data.length < 32)
        {
            tail[tailLen .. tailLen + data.length] = data[];
            tailLen += data.length;
            return;
        }
        if (tailLen > 0)
        {
            const fill = 32 - tailLen;
            tail[tailLen .. 32] = data[0 .. fill];
            consumeStripe(tail[]);
            data = data[fill .. $];
            tailLen = 0;
        }
        while (data.length >= 32)
        {
            consumeStripe(data[0 .. 32]);
            data = data[32 .. $];
        }
        tail[0 .. data.length] = data[];
        tailLen = data.length;
    }

    private void consumeStripe(scope const(ubyte)[] s) pure nothrow @nogc
    {
        v[0] = round(v[0], rd64(s[0 .. 8]));
        v[1] = round(v[1], rd64(s[8 .. 16]));
        v[2] = round(v[2], rd64(s[16 .. 24]));
        v[3] = round(v[3], rd64(s[24 .. 32]));
    }

    /// Final 64-bit hash (does not modify the accumulator).
    ulong finish() const pure nothrow @nogc
    {
        Xxh64 self = this;
        if (self.total == 0 && self.tailLen == 0 && self.v[0] == 0
            && self.v[1] == 0 && self.v[2] == 0 && self.v[3] == 0)
            self.reset(self.seed);
        ulong h;
        if (self.total >= 32)
        {
            h = rol(self.v[0], 1) + rol(self.v[1], 7)
                + rol(self.v[2], 12) + rol(self.v[3], 18);
            h = mergeRound(h, self.v[0]);
            h = mergeRound(h, self.v[1]);
            h = mergeRound(h, self.v[2]);
            h = mergeRound(h, self.v[3]);
        }
        else
            h = self.seed + prime5;
        h += self.total;

        const(ubyte)[] p = self.tail[0 .. self.tailLen];
        while (p.length >= 8)
        {
            h ^= round(0, rd64(p));
            h = rol(h, 27) * prime1 + prime4;
            p = p[8 .. $];
        }
        if (p.length >= 4)
        {
            h ^= rd32(p) * prime1;
            h = rol(h, 23) * prime2 + prime3;
            p = p[4 .. $];
        }
        foreach (b; p)
        {
            h ^= b * prime5;
            h = rol(h, 11) * prime1;
        }
        h ^= h >> 33;
        h *= prime2;
        h ^= h >> 29;
        h *= prime3;
        h ^= h >> 32;
        return h;
    }

    /// Low 32 bits of the hash, as stored in a ZSTD frame trailer.
    uint finishLow32() const pure nothrow @nogc
    {
        return cast(uint)(finish() & 0xFFFF_FFFFu);
    }
}

/// One-shot XXH64.
ulong xxh64(scope const(ubyte)[] data, ulong seed = 0) pure nothrow @nogc
{
    Xxh64 x;
    x.reset(seed);
    x.put(data);
    return x.finish();
}

/// One-shot low 32 bits of XXH64 (seed 0).
uint xxh64Low32(scope const(ubyte)[] data) pure nothrow @nogc
{
    return cast(uint)(xxh64(data) & 0xFFFF_FFFFu);
}


