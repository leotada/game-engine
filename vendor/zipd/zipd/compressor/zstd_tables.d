/**
 * RFC 8878 code tables for ZSTD sequences.
 *
 * Literal-length (LL), match-length (ML) and offset (OF) code baselines,
 * extra-bit counts, the predefined FSE distributions, and the reverse
 * mappings (value -> code) needed by the encoder.
 */
module zipd.compressor.zstd_tables;

import core.bitop : bsr;

@safe:
nothrow:
@nogc:

/// Maximum symbol (code) values.
enum uint maxLlCode = 35;
enum uint maxMlCode = 52;
enum uint maxOfCode = 31;

/// Number of symbols in each alphabet.
enum uint llSymbolCount = maxLlCode + 1; // 36
enum uint mlSymbolCount = maxMlCode + 1; // 53
enum uint ofSymbolCount = maxOfCode + 1; // 32

/// Maximum FSE accuracy logs permitted by RFC 8878 for each table.
enum uint maxLlAccuracyLog = 9;
enum uint maxMlAccuracyLog = 9;
enum uint maxOfAccuracyLog = 8;

/// Accuracy logs of the predefined distributions.
enum uint predefinedLlAccuracyLog = 6;
enum uint predefinedMlAccuracyLog = 6;
enum uint predefinedOfAccuracyLog = 5;

/// Literal length baselines per code.
static immutable uint[36] llBase = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512,
    1024, 2048, 4096, 8192, 16384, 32768, 65536
];

/// Literal length extra bits per code.
static immutable ubyte[36] llExtraBits = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
    13, 14, 15, 16
];

/// Match length baselines per code.
static immutable uint[53] mlBase = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
    19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
    35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515,
    1027, 2051, 4099, 8195, 16387, 32771, 65539
];

/// Match length extra bits per code.
static immutable ubyte[53] mlExtraBits = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
    12, 13, 14, 15, 16
];

/// Predefined normalized distribution for literal lengths (accuracy 6).
/// A value of -1 is the "less than 1" probability.
static immutable short[36] llDefaultNorm = [
    4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1
];

/// Predefined normalized distribution for match lengths (accuracy 6).
static immutable short[53] mlDefaultNorm = [
    1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1
];

/// Predefined normalized distribution for offsets (accuracy 5).
static immutable short[29] ofDefaultNorm = [
    1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1
];

/// Lookup table for `llCode(litLength)` when `litLength < 64`.
private static immutable ubyte[64] llCodeSmall = [
     0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
    16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 20, 20, 21, 21, 21, 21,
    22, 22, 22, 22, 22, 22, 22, 22, 23, 23, 23, 23, 23, 23, 23, 23,
    24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24, 24
];

/// Lookup table for `mlCode(matchLength)` when `matchLength - 3 < 128`.
private static immutable ubyte[128] mlCodeSmall = [
     0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
    32, 32, 33, 33, 34, 34, 35, 35, 36, 36, 36, 36, 37, 37, 37, 37,
    38, 38, 38, 38, 38, 38, 38, 38, 39, 39, 39, 39, 39, 39, 39, 39,
    40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40, 40,
    41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41, 41,
    42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42,
    42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42
];

/// Literal-length code for `litLength`.
uint llCode(uint litLength) pure nothrow @nogc
{
    if (litLength < 64)
        return llCodeSmall[litLength];
    if (litLength >= 65536)
        return maxLlCode;
    return cast(uint) bsr(litLength) + 19;
}

/// Match-length code for `matchLength` (must be >= 3).
uint mlCode(uint matchLength) pure nothrow @nogc
in (matchLength >= 3)
{
    const uint d = matchLength - 3;
    if (d < 128)
        return mlCodeSmall[d];
    if (d >= 65536)
        return maxMlCode;
    return cast(uint) bsr(d) + 36;
}

/// Offset code for an offset *value* (>= 1): its highest set bit.
uint ofCode(uint offsetValue) pure nothrow @nogc
in (offsetValue >= 1)
{
    return cast(uint) bsr(offsetValue);
}



