/**
 * ZSTD match finder and sequence parser.
 *
 * Hash-chain matcher over the whole input (so matches may reach back
 * across 128 KiB block boundaries up to the frame window), with
 * repeat-offset probing and optional one-step useLazy matching.
 */
module zipd.compressor.zstd_lz;

import core.bitop : bsr;

import zipd.compressor.scratch : allocScratch, freeScratch;
import zipd.compressor.zstd_sequences;

@safe:
nothrow:
@nogc:

private enum uint hashLog = 17;
private enum uint noPos = uint.max;

/// Result of a block parse.
struct ParseResult
{
    size_t nSeq;
    size_t nLit;
}

/// Effort settings for a compression level (1..9).
struct LevelParams
{
    uint chainDepth;
    bool useLazy;
}

/// Level table.
LevelParams levelParams(uint level) pure nothrow @nogc
{
    static immutable LevelParams[10] table = [
        LevelParams(1, false),    // 0 (unused)
        LevelParams(1, false),    // 1
        LevelParams(2, false),    // 2
        LevelParams(4, false),    // 3
        LevelParams(8, true),     // 4
        LevelParams(16, true),    // 5
        LevelParams(32, true),    // 6
        LevelParams(64, true),    // 7
        LevelParams(128, true),   // 8
        LevelParams(512, true),   // 9
    ];
    return table[level > 9 ? 9 : level];
}

private struct Candidate
{
    uint length;
    uint offset;
    int  score;
}

/// Hash-chain matcher bound to one input slice.
struct ZstdMatcher
{
    private const(ubyte)[] data;
    private uint[] head;
    private uint[] chain;
    private uint windowSize;
    private uint windowMask;
    private uint depth;
    private bool useLazy;
    /// True when `initWithBuffers` ran out of memory.
    bool allocFailed;

    /// Initialize matcher reusing caller-owned `headBuf` and `chainBuf`.
    /// Sets `allocFailed` (and leaves the matcher unusable) when a buffer
    /// could not be allocated.
    void initWithBuffers(return scope const(ubyte)[] input, uint windowLog,
        uint level, ref uint[] headBuf,
        ref uint[] chainBuf) @safe scope nothrow @nogc
    {
        data = input;
        windowSize = 1u << windowLog;
        windowMask = windowSize - 1;
        if (headBuf.length < (1u << hashLog))
        {
            freeScratch(headBuf);
            headBuf = allocScratch!uint(1u << hashLog);
            if (headBuf.length == 0)
            {
                allocFailed = true;
                return;
            }
        }
        head = headBuf[0 .. (1u << hashLog)];
        head[] = noPos;
        if (chainBuf.length < windowSize)
        {
            freeScratch(chainBuf);
            chainBuf = allocScratch!uint(windowSize);
            if (chainBuf.length == 0)
            {
                allocFailed = true;
                return;
            }
        }
        chain = chainBuf[0 .. windowSize];
        const p = levelParams(level);
        depth = p.chainDepth;
        useLazy = p.useLazy;
    }

    private uint hash4(size_t pos) const pure nothrow @nogc scope
    {
        const v = cast(uint) data[pos] | (cast(uint) data[pos + 1] << 8)
            | (cast(uint) data[pos + 2] << 16) | (cast(uint) data[pos + 3] << 24);
        return (v * 2654435761u) >> (32 - hashLog);
    }

    /// Add `pos` to the hash chains (no-op near the end of input).
    void insert(size_t pos) pure nothrow @nogc scope
    {
        if (pos + 4 > data.length)
            return;
        const h = hash4(pos);
        if (head[h] == pos)
            return;
        chain[pos & windowMask] = head[h];
        head[h] = cast(uint) pos;
    }

    private uint commonLen(size_t a, size_t b, size_t maxLen)
        const pure nothrow @nogc scope
    {
        uint k = 0;
        while (k + 16 <= maxLen)
        {
            if (data[a + k]      != data[b + k])      return k;
            if (data[a + k + 1]  != data[b + k + 1])  return k + 1;
            if (data[a + k + 2]  != data[b + k + 2])  return k + 2;
            if (data[a + k + 3]  != data[b + k + 3])  return k + 3;
            if (data[a + k + 4]  != data[b + k + 4])  return k + 4;
            if (data[a + k + 5]  != data[b + k + 5])  return k + 5;
            if (data[a + k + 6]  != data[b + k + 6])  return k + 6;
            if (data[a + k + 7]  != data[b + k + 7])  return k + 7;
            if (data[a + k + 8]  != data[b + k + 8])  return k + 8;
            if (data[a + k + 9]  != data[b + k + 9])  return k + 9;
            if (data[a + k + 10] != data[b + k + 10]) return k + 10;
            if (data[a + k + 11] != data[b + k + 11]) return k + 11;
            if (data[a + k + 12] != data[b + k + 12]) return k + 12;
            if (data[a + k + 13] != data[b + k + 13]) return k + 13;
            if (data[a + k + 14] != data[b + k + 14]) return k + 14;
            if (data[a + k + 15] != data[b + k + 15]) return k + 15;
            k += 16;
        }
        while (k + 4 <= maxLen)
        {
            if (data[a + k]     != data[b + k])     return k;
            if (data[a + k + 1] != data[b + k + 1]) return k + 1;
            if (data[a + k + 2] != data[b + k + 2]) return k + 2;
            if (data[a + k + 3] != data[b + k + 3]) return k + 3;
            k += 4;
        }
        while (k < maxLen && data[a + k] == data[b + k])
            k++;
        return k;
    }

    private static int score(uint len, uint offset, bool rep)
        pure nothrow @nogc
    {
        const cost = rep ? 3 : cast(int) bsr(offset) + 6;
        return cast(int) len * 8 - cost;
    }

    private Candidate findBest(size_t pos, size_t end, uint litLen,
        scope const ref uint[3] rep) pure nothrow @nogc scope
    {
        Candidate best;
        best.score = int.min;
        const maxLen = end - pos;
        if (maxLen < 3)
            return best;

        const ubyte p0 = data[pos];
        const ubyte p1 = data[pos + 1];
        const ubyte p2 = data[pos + 2];

        foreach (r; rep)
        {
            if (r == 0 || r > pos || r > windowSize)
                continue;
            const size_t matchPos = pos - r;
            if (data[matchPos] != p0 ||
                data[matchPos + 1] != p1 ||
                data[matchPos + 2] != p2)
                continue;
            const len = 3 + commonLen(matchPos + 3, pos + 3, maxLen - 3);
            const sc = score(len, r, isRepeatOffset(litLen, r, rep));
            if (sc > best.score)
            {
                best = Candidate(len, r, sc);
                if (len >= 128 || len >= maxLen)
                    break;
            }
        }

        if (maxLen >= 4 && pos + 4 <= data.length)
        {
            const h = hash4(pos);
            uint cand = head[h];
            chain[pos & windowMask] = cand;
            head[h] = cast(uint) pos;

            if (best.length < 128 && best.length < maxLen)
            {
                const ubyte p3 = data[pos + 3];
                ubyte pBest = best.length >= 4 ? data[pos + best.length] : 0;
                const limit = pos > windowSize ? pos - windowSize : 0;
                uint walks = 0;
                while (cand != noPos && cand < pos && cand >= limit && walks < depth)
                {
                    if (best.length >= 4 && data[cand + best.length] != pBest)
                    {
                        const next = chain[cand & windowMask];
                        if (next >= cand) break;
                        cand = next;
                        walks++;
                        continue;
                    }

                    if (data[cand] != p0 ||
                        data[cand + 1] != p1 ||
                        data[cand + 2] != p2 ||
                        data[cand + 3] != p3)
                    {
                        const next = chain[cand & windowMask];
                        if (next >= cand) break;
                        cand = next;
                        walks++;
                        continue;
                    }

                    const len = 4 + commonLen(cand + 4, pos + 4, maxLen - 4);
                    const off = cast(uint)(pos - cand);
                    if (!(len == 4 && off >= (1u << 16)))
                    {
                        const sc = score(len, off, isRepeatOffset(litLen, off, rep));
                        if (sc > best.score)
                        {
                            best = Candidate(len, off, sc);
                            if (len >= 128 || len >= maxLen)
                                break;
                            pBest = data[pos + best.length];
                        }
                    }

                    const next = chain[cand & windowMask];
                    if (next >= cand)
                        break;
                    cand = next;
                    walks++;
                }
            }
        }
        else
        {
            insert(pos);
        }

        if (best.score == int.min)
            best.length = 0;
        return best;
    }

    /// Parse `[start, end)` into sequences and a literal buffer. `rep`
    /// is updated as the decoder will update it. `seqs` must hold at
    /// least `(end - start) / 3 + 1` entries and `lits` at least
    /// `end - start` bytes.
    ParseResult parseBlock(size_t start, size_t end, ref uint[3] rep,
        scope ZstdSeq[] seqs, scope ubyte[] lits) pure nothrow @nogc scope
    {
        ParseResult r;
        size_t pos = start;
        size_t anchor = start;
        uint misses = 0;

        while (pos + 3 <= end)
        {
            uint litLen = cast(uint)(pos - anchor);
            auto c = findBest(pos, end, litLen, rep);
            if (c.length == 0)
            {
                misses++;
                pos += 1 + (misses >> 5);
                continue;
            }
            misses = 0;
            if (useLazy && c.length < 32 && pos + 4 <= end)
            {
                auto c2 = findBest(pos + 1, end, litLen + 1, rep);
                if (c2.length != 0 && c2.score > c.score + 4)
                {
                    pos++;
                    litLen++;
                    c = c2;
                }
            }
            const nl = pos - anchor;
            lits[r.nLit .. r.nLit + nl] = data[anchor .. pos];
            r.nLit += nl;
            const ov = encodeOffset(litLen, c.offset, rep);
            seqs[r.nSeq++] = ZstdSeq(litLen, c.length, ov);

            const matchEnd = pos + c.length;
            if (c.length <= 32)
            {
                foreach (p; pos + 1 .. matchEnd)
                    insert(p);
            }
            else
            {
                const pLimit = pos + 4 < matchEnd ? pos + 4 : matchEnd;
                foreach (p; pos + 1 .. pLimit)
                    insert(p);
                for (size_t p = pos + 4; p + 2 < matchEnd; p += 8)
                    insert(p);
                if (matchEnd > 2)
                    insert(matchEnd - 2);
                if (matchEnd > 1)
                    insert(matchEnd - 1);
            }
            pos = matchEnd;
            anchor = pos;
        }
        const tail = end - anchor;
        lits[r.nLit .. r.nLit + tail] = data[anchor .. end];
        r.nLit += tail;
        return r;
    }
}

