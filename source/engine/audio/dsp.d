/// Real-time POD DSP effect slots and chains for `AudioMixer` buses and voices.
/// All processing is `@safe nothrow @nogc` with zero heap allocations.
module engine.audio.dsp;

import core.stdc.math : cosf, sinf, tanhf;
import engine.core.pod : isPod;

@safe:

enum uint MAX_DSP_SLOTS = 4;

/// Supported real-time DSP effect types.
enum DspEffectType : ubyte {
    none = 0,
    biquadLowPass,
    biquadHighPass,
    biquadBandPass,
    waveshaper,
    staticHiss,
}

/// Biquad filter coefficients and per-channel Direct Form II Transposed delay state.
struct BiquadState {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;
    float[2] z1 = [0.0f, 0.0f];
    float[2] z2 = [0.0f, 0.0f];
}

/// Single POD DSP effect slot.
struct DspEffectSlot {
    DspEffectType type = DspEffectType.none;
    bool enabled = true;
    float param0 = 1000.0f; ///< Cutoff Hz (biquad), drive (waveshaper), noise level (staticHiss).
    float param1 = 0.707f;  ///< Q (biquad), hard-clip blend [0..1] (waveshaper), squelch threshold (staticHiss).
    float param2 = 1.0f;    ///< Makeup gain (waveshaper).
    uint rngState = 0x1234_5678u;
    BiquadState biquad;

    static DspEffectSlot lowPass(float cutoffHz, float q = 0.7071f, int sampleRate = 48_000) nothrow @nogc {
        return makeBiquad(DspEffectType.biquadLowPass, cutoffHz, q, sampleRate);
    }

    static DspEffectSlot highPass(float cutoffHz, float q = 0.7071f, int sampleRate = 48_000) nothrow @nogc {
        return makeBiquad(DspEffectType.biquadHighPass, cutoffHz, q, sampleRate);
    }

    static DspEffectSlot bandPass(float centerHz, float q = 1.0f, int sampleRate = 48_000) nothrow @nogc {
        return makeBiquad(DspEffectType.biquadBandPass, centerHz, q, sampleRate);
    }

    static DspEffectSlot waveshaper(float drive = 2.5f, float hardClipBlend = 0.5f, float makeupGain = 0.85f) pure nothrow @nogc {
        DspEffectSlot s;
        s.type = DspEffectType.waveshaper;
        s.enabled = true;
        s.param0 = drive > 0.1f ? drive : 0.1f;
        s.param1 = clamp01(hardClipBlend);
        s.param2 = makeupGain > 0.0f ? makeupGain : 1.0f;
        return s;
    }

    /// Band-limited radio static hiss. When `squelchThreshold > 0`, noise is gated by `hasSignal`.
    static DspEffectSlot staticHiss(float level = 0.035f, float squelchThreshold = 0.001f) pure nothrow @nogc {
        DspEffectSlot s;
        s.type = DspEffectType.staticHiss;
        s.enabled = true;
        s.param0 = level > 0.0f ? level : 0.0f;
        s.param1 = squelchThreshold >= 0.0f ? squelchThreshold : 0.0f;
        return s;
    }
}

/// Fixed-size 4-slot POD DSP chain attached to a bus or voice.
struct DspChain {
    DspEffectSlot[MAX_DSP_SLOTS] slots;

    /// Preset simulating a COPOM VHF police radio (800 Hz HPF + 3 kHz LPF + mild clip + static hiss).
    static DspChain vhfRadio(int sampleRate = 48_000) nothrow @nogc {
        DspChain chain;
        chain.slots[0] = DspEffectSlot.highPass(800.0f, 0.7071f, sampleRate);
        chain.slots[1] = DspEffectSlot.lowPass(3000.0f, 0.7071f, sampleRate);
        chain.slots[2] = DspEffectSlot.waveshaper(2.5f, 0.6f, 0.85f);
        chain.slots[3] = DspEffectSlot.staticHiss(0.035f, 0.001f);
        return chain;
    }
}

static assert(isPod!BiquadState);
static assert(isPod!DspEffectSlot);
static assert(isPod!DspChain);

/// Process `frames` interleaved samples (`channels` <= 2) through `chain` in place.
void processDspChain(ref DspChain chain,
                     scope float[] interleaved,
                     uint frames,
                     uint channels,
                     bool hasSignal) nothrow @nogc {
    immutable uint ch = channels == 1 ? 1 : 2;
    immutable size_t count = cast(size_t) frames * ch;
    if (interleaved.length < count || count == 0)
        return;

    foreach (si; 0 .. MAX_DSP_SLOTS) {
        auto slot = &chain.slots[si];
        if (!slot.enabled || slot.type == DspEffectType.none)
            continue;

        final switch (slot.type) {
            case DspEffectType.none:
                break;
            case DspEffectType.biquadLowPass:
            case DspEffectType.biquadHighPass:
            case DspEffectType.biquadBandPass:
                processBiquad(*slot, interleaved[0 .. count], frames, ch);
                break;
            case DspEffectType.waveshaper:
                processWaveshaper(*slot, interleaved[0 .. count]);
                break;
            case DspEffectType.staticHiss:
                processStaticHiss(*slot, interleaved[0 .. count], frames, ch, hasSignal);
                break;
        }
    }
}

private DspEffectSlot makeBiquad(DspEffectType type, float freqHz, float q, int sampleRate) nothrow @nogc {
    enum float TWO_PI = 6.28318530718f;
    immutable float sr = sampleRate > 1000 ? cast(float) sampleRate : 48_000.0f;
    immutable float maxFreq = sr * 0.45f;
    immutable float fc = freqHz < 10.0f ? 10.0f : (freqHz > maxFreq ? maxFreq : freqHz);
    immutable float safeQ = q > 0.05f ? q : 0.05f;

    immutable float w0 = TWO_PI * fc / sr;
    immutable float cosW0 = cosf(w0);
    immutable float sinW0 = sinf(w0);
    immutable float alpha = sinW0 / (2.0f * safeQ);

    float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f;
    if (type == DspEffectType.biquadLowPass) {
        b0 = (1.0f - cosW0) * 0.5f;
        b1 = 1.0f - cosW0;
        b2 = (1.0f - cosW0) * 0.5f;
    } else if (type == DspEffectType.biquadHighPass) {
        b0 = (1.0f + cosW0) * 0.5f;
        b1 = -(1.0f + cosW0);
        b2 = (1.0f + cosW0) * 0.5f;
    } else {
        b0 = alpha;
        b1 = 0.0f;
        b2 = -alpha;
    }

    immutable float a0 = 1.0f + alpha;
    immutable float a1 = -2.0f * cosW0;
    immutable float a2 = 1.0f - alpha;
    immutable float invA0 = 1.0f / a0;

    DspEffectSlot s;
    s.type = type;
    s.enabled = true;
    s.param0 = fc;
    s.param1 = safeQ;
    s.biquad.b0 = b0 * invA0;
    s.biquad.b1 = b1 * invA0;
    s.biquad.b2 = b2 * invA0;
    s.biquad.a1 = a1 * invA0;
    s.biquad.a2 = a2 * invA0;
    return s;
}

private void processBiquad(ref DspEffectSlot slot, scope float[] samples, uint frames, uint ch) pure nothrow @nogc {
    immutable b0 = slot.biquad.b0;
    immutable b1 = slot.biquad.b1;
    immutable b2 = slot.biquad.b2;
    immutable a1 = slot.biquad.a1;
    immutable a2 = slot.biquad.a2;

    foreach (c; 0 .. ch) {
        float z1 = slot.biquad.z1[c];
        float z2 = slot.biquad.z2[c];
        foreach (f; 0 .. frames) {
            immutable idx = cast(size_t) f * ch + c;
            immutable x = samples[idx];
            immutable y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            samples[idx] = y;
        }
        slot.biquad.z1[c] = z1;
        slot.biquad.z2[c] = z2;
    }
}

private void processWaveshaper(ref const DspEffectSlot slot, scope float[] samples) nothrow @nogc {
    immutable drive = slot.param0;
    immutable hardBlend = slot.param1;
    immutable softBlend = 1.0f - hardBlend;
    immutable gain = slot.param2;

    foreach (ref s; samples) {
        immutable x = s * drive;
        immutable soft = tanhf(x);
        immutable hard = x > 1.0f ? 1.0f : (x < -1.0f ? -1.0f : x);
        s = (soft * softBlend + hard * hardBlend) * gain;
    }
}

private void processStaticHiss(ref DspEffectSlot slot,
                               scope float[] samples,
                               uint frames,
                               uint ch,
                               bool hasSignal) pure nothrow @nogc {
    if (slot.param0 <= 0.0f)
        return;
    if (slot.param1 > 0.0f && !hasSignal)
        return;

    uint rng = slot.rngState != 0 ? slot.rngState : 0x9E37_79B9u;
    immutable float level = slot.param0;
    // Simple 1-pole high-pass difference on noise for crisp VHF static texture.
    float prevNoise = 0.0f;

    foreach (f; 0 .. frames) {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        immutable float white = (cast(int)(rng & 0xFFFF) / 32768.0f) - 1.0f;
        immutable float crisp = (white - prevNoise * 0.5f) * level;
        prevNoise = white;
        foreach (c; 0 .. ch) {
            samples[cast(size_t) f * ch + c] += crisp;
        }
    }
    slot.rngState = rng;
}

private float clamp01(float v) pure nothrow @nogc {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

@safe nothrow @nogc unittest {
    static assert(isPod!DspChain);
    import core.stdc.math : fabsf;

    enum int SR = 48_000;
    enum int N = 2048;
    float[N] buf;

    // 100 Hz sine attenuated heavily by 800 Hz HPF.
    DspChain hpfChain;
    hpfChain.slots[0] = DspEffectSlot.highPass(800.0f, 0.7071f, SR);
    foreach (i; 0 .. N)
        buf[i] = sinf(2.0f * 3.14159265f * 100.0f * cast(float) i / SR);
    processDspChain(hpfChain, buf[], N, 1, true);
    float peak100 = 0.0f;
    foreach (i; N / 2 .. N) {
        immutable a = fabsf(buf[i]);
        if (a > peak100) peak100 = a;
    }
    assert(peak100 < 0.05f);

    // 1.5 kHz sine passes through VHF radio band (800 Hz .. 3000 Hz).
    DspChain vhf = DspChain.vhfRadio(SR);
    foreach (i; 0 .. N)
        buf[i] = 0.5f * sinf(2.0f * 3.14159265f * 1500.0f * cast(float) i / SR);
    processDspChain(vhf, buf[], N, 1, true);
    float peak1500 = 0.0f;
    foreach (i; N / 2 .. N) {
        immutable a = fabsf(buf[i]);
        if (a > peak1500) peak1500 = a;
    }
    assert(peak1500 > 0.25f);

    // 12 kHz sine attenuated heavily by 3 kHz LPF.
    DspChain lpfChain;
    lpfChain.slots[0] = DspEffectSlot.lowPass(3000.0f, 0.7071f, SR);
    foreach (i; 0 .. N)
        buf[i] = sinf(2.0f * 3.14159265f * 12_000.0f * cast(float) i / SR);
    processDspChain(lpfChain, buf[], N, 1, true);
    float peak12k = 0.0f;
    foreach (i; N / 2 .. N) {
        immutable a = fabsf(buf[i]);
        if (a > peak12k) peak12k = a;
    }
    assert(peak12k < 0.12f);
}
