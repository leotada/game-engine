/**
 * Shared sequence helpers for the ZSTD encoder and decoder.
 *
 * Holds the repeat-offset state machine so both directions use exactly
 * the same transitions (RFC 8878 §3.1.1.5).
 */
module zipd.compressor.zstd_sequences;

@safe:
nothrow:
@nogc:

/// A sequence as stored in the bitstream: literal run, match length
/// (>= 3) and the *coded* offset value (1..3 = repeat, else offset + 3).
struct ZstdSeq
{
    uint litLength;
    uint matchLength;
    uint offsetValue;
}

/// Initial repeat offsets at every frame start.
enum uint[3] initialRep = [1, 4, 8];

/// Decoder direction: turn a coded `offsetValue` into a real offset and
/// update `rep`. Returns false if the offset would be zero.
bool resolveOffset(uint offsetValue, uint litLen, ref uint[3] rep,
    out uint offset) pure nothrow @nogc
{
    if (offsetValue > 3)
    {
        offset = offsetValue - 3;
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
        return true;
    }
    const idx = offsetValue + (litLen == 0 ? 1 : 0);
    if (idx == 1)
        offset = rep[0];
    else if (idx == 2)
    {
        offset = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
    }
    else if (idx == 3)
    {
        offset = rep[2];
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
    }
    else
    {
        offset = rep[0] - 1;
        if (offset == 0)
            return false;
        rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = offset;
    }
    return true;
}

/// True if `offset` can be coded as a repeat offset for this `litLen`.
bool isRepeatOffset(uint litLen, uint offset, scope const ref uint[3] rep)
    pure nothrow @nogc
{
    if (litLen > 0)
        return offset == rep[0] || offset == rep[1] || offset == rep[2];
    return offset == rep[1] || offset == rep[2]
        || (rep[0] > 1 && offset == rep[0] - 1);
}

/// Encoder direction: pick the coded value for `offset` and update `rep`
/// exactly as `resolveOffset` will on the decoder side.
uint encodeOffset(uint litLen, uint offset, ref uint[3] rep) pure nothrow @nogc
{
    if (litLen > 0)
    {
        if (offset == rep[0])
            return 1;
        if (offset == rep[1])
        {
            rep[1] = rep[0];
            rep[0] = offset;
            return 2;
        }
        if (offset == rep[2])
        {
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
            return 3;
        }
    }
    else
    {
        if (offset == rep[1])
        {
            rep[1] = rep[0];
            rep[0] = offset;
            return 1;
        }
        if (offset == rep[2])
        {
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
            return 2;
        }
        if (rep[0] > 1 && offset == rep[0] - 1)
        {
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = offset;
            return 3;
        }
    }
    rep[2] = rep[1];
    rep[1] = rep[0];
    rep[0] = offset;
    return offset + 3;
}


