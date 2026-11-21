/// Audio engine built on SDL3's playback streams.
///
/// Usage:
///   auto audio = AudioEngine.create();
///   auto clip  = AudioClip.loadWav("sfx/click.wav");
///   audio.play(clip);
///   ...on shutdown...
///   clip.destroy();
///   audio.destroy();
///
/// Each `play()` queues a copy of the clip's raw PCM into the shared playback
/// stream. For multi-voice / mixing / streaming music, extend this with a
/// per-voice stream or an SDL audio mixer.
module engine.audio.engine;

import std.string : toStringz, fromStringz;

import bindings.sdl3;
import core.atomic : atomicLoad, MemoryOrder;
import engine.audio.dsp : DspChain, processDspChain;
import engine.audio.stream : AudioStream, PcmRingBuffer;
import engine.core.log;
import engine.core.gc : gcExcludeCurrentThread, gcIncludeCurrentThread, gcIsThreadExcluded;

@safe:

/// Exclude the calling audio or real-time streaming thread from GC STW pause handshakes.
void excludeAudioThreadFromGc() nothrow @nogc {
    gcExcludeCurrentThread();
}

/// Re-include the calling audio thread in GC STW pause handshakes.
void includeAudioThreadInGc() nothrow @nogc {
    gcIncludeCurrentThread();
}

/// Check if the calling thread is currently excluded from GC pauses.
bool isAudioThreadExcludedFromGc() nothrow @nogc {
    return gcIsThreadExcluded();
}

/// Raw PCM audio clip loaded from a WAV file. Owns SDL-allocated memory
/// that must be freed via `destroy()`.
struct AudioClip {
    SDL_AudioSpec spec;
    ubyte* data;
    uint   length;

    @disable this(this);

    static AudioClip loadWav(string path) @trusted {
        AudioClip clip;
        auto cPath = path.toStringz;
        if (!SDL_LoadWAV(cPath, &clip.spec, &clip.data, &clip.length)) {
            err("SDL_LoadWAV failed for '", path, "': ", fromStringz(SDL_GetError()));
            return clip; // data==null signals failure
        }
        info("Loaded WAV: ", path, " (", clip.length, " bytes, ",
             clip.spec.channels, " ch, ", clip.spec.freq, " Hz)");
        return clip;
    }

    bool isValid() const nothrow @nogc { return data !is null && length > 0; }

    /// Convert/resample a clip into another sample rate, channel count, and format (default 48kHz stereo F32LE).
    AudioClip convertTo(int sampleRate, int channels,
                        SDL_AudioFormat targetFormat = SDL_AudioFormat.SDL_AUDIO_F32LE) const @trusted {
        AudioClip dst;
        if (!isValid || sampleRate <= 0 || channels <= 0) return dst;

        SDL_AudioSpec dstSpec;
        dstSpec.format = targetFormat;
        dstSpec.channels = channels;
        dstSpec.freq = sampleRate;

        ubyte* dstData = null;
        int dstLen = 0;
        if (!SDL_ConvertAudioSamples(&spec, data, cast(int) length, &dstSpec, &dstData, &dstLen)
            || dstData is null || dstLen <= 0) {
            err("SDL_ConvertAudioSamples failed: ", fromStringz(SDL_GetError()));
            return dst;
        }
        dst.spec = dstSpec;
        dst.data = dstData;
        dst.length = cast(uint) dstLen;
        return dst;
    }

    /// Build a clip from interleaved float32 PCM (matches AudioEngine default format).
    /// `samples` length must be `frameCount * channels`. Copied into SDL-owned memory.
    static AudioClip fromInterleavedF32(const(float)[] samples,
                                        int sampleRate = 48000,
                                        int channels = 2) @trusted {
        AudioClip clip;
        if (samples.length == 0 || channels <= 0) {
            err("AudioClip.fromInterleavedF32: empty samples or invalid channels");
            return clip;
        }
        clip.spec.format = SDL_AudioFormat.SDL_AUDIO_F32LE;
        clip.spec.channels = channels;
        clip.spec.freq = sampleRate;
        clip.length = cast(uint)(samples.length * float.sizeof);
        clip.data = cast(ubyte*) SDL_malloc(clip.length);
        if (clip.data is null) {
            err("AudioClip.fromInterleavedF32: SDL_malloc failed");
            clip.length = 0;
            return clip;
        }
        import core.stdc.string : memcpy;
        memcpy(clip.data, samples.ptr, clip.length);
        return clip;
    }

    void destroy() @trusted nothrow @nogc {
        if (data !is null) {
            SDL_free(data);
            data = null;
            length = 0;
        }
    }
}

/// Single-stream audio engine. One shared playback stream; `play()` queues
/// PCM samples for immediate playback.
struct AudioEngine {
    private SDL_AudioStream* stream;
    private SDL_AudioSpec    openSpec;
    private bool _ready;

    @disable this(this);

    /// Open the default playback device with a sensible default format.
    /// Returns a zero-initialized engine (`isReady == false`) on failure.
    static AudioEngine create(int sampleRate = 48000, int channels = 2) @trusted {
        AudioEngine a;
        a.openSpec.format   = SDL_AudioFormat.SDL_AUDIO_F32LE;
        a.openSpec.channels = channels;
        a.openSpec.freq     = sampleRate;
        a.stream = SDL_OpenAudioDeviceStream(
            SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &a.openSpec, null, null);
        if (a.stream is null) {
            err("SDL_OpenAudioDeviceStream failed: ", fromStringz(SDL_GetError()));
            return a;
        }
        SDL_ResumeAudioStreamDevice(a.stream);
        a._ready = true;
        info("Audio engine online: ", sampleRate, "Hz, ", channels, " ch, F32LE");
        return a;
    }

    bool isReady() const nothrow @nogc { return _ready; }

    /// Queue an entire clip into the playback stream. SDL handles resampling
    /// from the clip's spec to the device format/rate.
    /// Returns true on success, false if engine not ready or clip invalid.
    bool play(ref const AudioClip clip) @trusted nothrow @nogc {
        if (!_ready || !clip.isValid) return false;
        // NOTE: SDL_PutAudioStreamData assumes the data matches the stream's
        // *input* format. Since we opened the stream with our engine spec, we
        // rely on callers to use matching-format clips, or extend to per-clip
        // streams. For v1 we accept mismatch risk & document the constraint.
        return SDL_PutAudioStreamData(stream, clip.data, cast(int) clip.length);
    }

    /// Stop all audio immediately and clear the playback queue.
    void stop() @trusted nothrow @nogc {
        if (_ready) SDL_ClearAudioStream(stream);
    }

    void destroy() @trusted nothrow @nogc {
        if (stream !is null) {
            SDL_DestroyAudioStream(stream);
            stream = null;
        }
        _ready = false;
    }
}

/// Bus groups for independent volume mixing and per-bus DSP processing.
enum AudioBus : ubyte {
    sfx     = 0,
    music   = 1,
    voice   = 2,
    radio   = 3,
    ambient = 4,
    ui      = 5,
    custom0 = 6,
    custom1 = 7,
}

enum uint MAX_AUDIO_BUSES = 8;

/// Generational handle identifying an active voice in `AudioMixer` (`0` = invalid).
alias VoiceId = ulong;

private enum uint MAX_AUDIO_VOICES = 32;

private struct MixerVoice {
    const(ubyte)* data = null;
    SDL_AudioFormat format = SDL_AudioFormat.SDL_AUDIO_F32LE;
    uint frameCount = 0;
    uint channels = 2;
    int  sampleRate = 48_000;
    double framePos = 0.0;

    // Optional streaming source (lock-free SPSC ring buffer).
    PcmRingBuffer* streamRing = null;
    shared(bool)* streamEof = null;
    double streamFrac = 0.0;
    float[2] streamPrev = [0.0f, 0.0f];
    float[2] streamCurr = [0.0f, 0.0f];
    bool streamPrimed = false;

    // Smoothed per-voice parameters (cur* ramps to target* per chunk to avoid zipper noise).
    float volume = 1.0f;
    float curVolume = 1.0f;
    float basePitch = 1.0f;
    float dopplerPitch = 1.0f;
    float curPitch = 1.0f;
    float pan = 0.0f; ///< -1 = full left, 0 = center, +1 = full right (stereo output only).
    float curPan = 0.0f;
    float spatialBlend = 0.0f; ///< 0 = preserve stereo, 1 = mono downmix + 3D pan.

    AudioBus bus = AudioBus.sfx;
    bool loop = false;
    bool paused = false;
    bool active = false;
    uint generation = 1;

    bool hasDsp = false;
    DspChain dsp;
}

/// Per-channel gains for a stereo balance pan in `[-1, 1]`.
/// Center is unity on both sides; the far side fades with a quarter-cosine
/// curve (equal-power feel, no gain boost, no clipping risk on one-shots).
void panGains(float pan, out float left, out float right) pure nothrow @nogc {
    import core.stdc.math : cosf;
    enum float HALF_PI = 1.57079632679f;
    immutable float p = pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan);
    left  = p > 0.0f ? cosf(p * HALF_PI) : 1.0f;
    right = p < 0.0f ? cosf(-p * HALF_PI) : 1.0f;
}

private struct MixerState {
    MixerVoice[MAX_AUDIO_VOICES] voices;
    float[MAX_AUDIO_BUSES] busGains = [1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f, 1.0f];
    DspChain[MAX_AUDIO_BUSES] busDsp;
    bool[MAX_AUDIO_BUSES] busDspEnabled;
    float[1024][MAX_AUDIO_BUSES] busAccum = 0.0f;
    float[1024] voiceScratch = 0.0f;
    float masterGain = 1.0f;
    int outputRate = 48_000;
    int outputChannels = 2;
    bool audioThreadExcluded = false;
}

private float readSampleNorm(const(ubyte)* data, SDL_AudioFormat fmt,
                           uint frame, uint ch, uint channels) nothrow @nogc @trusted {
    immutable size_t idx = cast(size_t) frame * channels + ch;
    if (fmt == SDL_AudioFormat.SDL_AUDIO_S16LE) {
        return (cast(const(short)*) data)[idx] * (1.0f / 32768.0f);
    }
    return (cast(const(float)*) data)[idx];
}

private void resetVoice(ref MixerVoice v) nothrow @nogc {
    v.active = false;
    v.data = null;
    v.streamRing = null;
    v.streamEof = null;
    v.streamPrimed = false;
    v.hasDsp = false;
}

private void mixVoicesInto(ref MixerState state, float[] outInterleaved, uint outFrames) nothrow @nogc @trusted {
    immutable uint outCh = state.outputChannels > 0 ? cast(uint) state.outputChannels : 2;
    immutable size_t needed = cast(size_t) outFrames * outCh;
    if (outInterleaved.length < needed || needed > 1024 || outFrames == 0)
        return;

    outInterleaved[0 .. needed] = 0.0f;

    bool[MAX_AUDIO_BUSES] busActive = false;
    foreach (bi; 0 .. MAX_AUDIO_BUSES) {
        if (state.busDspEnabled[bi])
            state.busAccum[bi][0 .. needed] = 0.0f;
    }

    immutable float invFrames = 1.0f / cast(float) outFrames;

    foreach (vi; 0 .. MAX_AUDIO_VOICES) {
        auto v = &state.voices[vi];
        immutable bool isStream = v.streamRing !is null;
        if (!v.active || v.paused) continue;
        if (!isStream && (v.data is null || v.frameCount == 0)) continue;

        immutable uint busIdx = v.bus < MAX_AUDIO_BUSES ? v.bus : 0;
        if (!busActive[busIdx]) {
            if (!state.busDspEnabled[busIdx])
                state.busAccum[busIdx][0 .. needed] = 0.0f;
            busActive[busIdx] = true;
        }

        float[] targetBuf = v.hasDsp
            ? state.voiceScratch[0 .. needed]
            : state.busAccum[busIdx][0 .. needed];
        if (v.hasDsp)
            targetBuf[0 .. needed] = 0.0f;

        immutable float busG = state.busGains[busIdx];
        immutable float volStart = v.curVolume * busG;
        immutable float volEnd = v.volume * busG;
        immutable float volStep = (volEnd - volStart) * invFrames;

        immutable float targetPitch = v.basePitch * v.dopplerPitch;
        immutable float clampedTargetPitch = targetPitch > 0.01f ? targetPitch : 0.01f;
        immutable float pitchStart = v.curPitch > 0.01f ? v.curPitch : clampedTargetPitch;
        immutable float pitchStep = (clampedTargetPitch - pitchStart) * invFrames;

        immutable float panStart = v.curPan;
        immutable float panStep = (v.pan - panStart) * invFrames;

        immutable uint srcCh = v.channels > 0 ? v.channels : 1;
        immutable double rateRatio = cast(double) v.sampleRate / cast(double) state.outputRate;
        immutable float sb = v.spatialBlend < 0.0f ? 0.0f : (v.spatialBlend > 1.0f ? 1.0f : v.spatialBlend);

        float curVol = volStart;
        float curP = pitchStart;
        float curPanVal = panStart;

        if (isStream) {
            if (!v.streamPrimed) {
                if (v.streamRing.popFrame(v.streamPrev)) {
                    if (!v.streamRing.popFrame(v.streamCurr))
                        v.streamCurr = v.streamPrev;
                    v.streamFrac = 0.0;
                    v.streamPrimed = true;
                } else {
                    if (v.streamEof !is null && atomicLoad!(MemoryOrder.acq)(*v.streamEof)) {
                        resetVoice(*v);
                    }
                    continue;
                }
            }

            foreach (f; 0 .. outFrames) {
                immutable double step = rateRatio * cast(double) curP;
                v.streamFrac += step;
                while (v.streamFrac >= 1.0) {
                    float[2] nextFrame = void;
                    if (v.streamRing.popFrame(nextFrame)) {
                        v.streamPrev = v.streamCurr;
                        v.streamCurr = nextFrame;
                        v.streamFrac -= 1.0;
                    } else {
                        if (v.streamEof !is null && atomicLoad!(MemoryOrder.acq)(*v.streamEof)) {
                            resetVoice(*v);
                        }
                        v.streamFrac = 1.0;
                        break;
                    }
                }
                if (!v.active) break;

                float panL = 1.0f, panR = 1.0f;
                if (outCh == 2) panGains(curPanVal, panL, panR);

                immutable float frac = cast(float) v.streamFrac;
                immutable float sL = v.streamPrev[0] + (v.streamCurr[0] - v.streamPrev[0]) * frac;
                immutable float sR = srcCh > 1
                    ? (v.streamPrev[1] + (v.streamCurr[1] - v.streamPrev[1]) * frac)
                    : sL;
                immutable float mono = (sL + sR) * 0.5f;

                foreach (c; 0 .. outCh) {
                    immutable float raw = c == 0 ? sL : sR;
                    immutable float sample = raw + (mono - raw) * sb;
                    immutable float cg = outCh == 2 ? (c == 0 ? panL : panR) : 1.0f;
                    targetBuf[cast(size_t) f * outCh + c] += sample * curVol * cg;
                }

                curVol += volStep;
                curP += pitchStep;
                curPanVal += panStep;
            }
        } else {
            foreach (f; 0 .. outFrames) {
                if (v.framePos >= cast(double) v.frameCount) {
                    if (v.loop) {
                        while (v.framePos >= cast(double) v.frameCount) {
                            v.framePos -= cast(double) v.frameCount;
                        }
                    } else {
                        resetVoice(*v);
                        break;
                    }
                }

                immutable uint f0 = cast(uint) v.framePos;
                immutable float frac = cast(float)(v.framePos - cast(double) f0);
                uint f1 = f0 + 1;
                if (f1 >= v.frameCount) {
                    f1 = v.loop ? 0 : (v.frameCount - 1);
                }

                float panL = 1.0f, panR = 1.0f;
                if (outCh == 2) panGains(curPanVal, panL, panR);

                immutable float s0L = readSampleNorm(v.data, v.format, f0, 0, srcCh);
                immutable float s1L = readSampleNorm(v.data, v.format, f1, 0, srcCh);
                immutable float vL = s0L + (s1L - s0L) * frac;

                float vR = vL;
                if (srcCh > 1) {
                    immutable float s0R = readSampleNorm(v.data, v.format, f0, 1, srcCh);
                    immutable float s1R = readSampleNorm(v.data, v.format, f1, 1, srcCh);
                    vR = s0R + (s1R - s0R) * frac;
                }
                immutable float mono = (vL + vR) * 0.5f;

                foreach (c; 0 .. outCh) {
                    immutable float raw = c == 0 ? vL : vR;
                    immutable float sample = raw + (mono - raw) * sb;
                    immutable float cg = outCh == 2 ? (c == 0 ? panL : panR) : 1.0f;
                    targetBuf[cast(size_t) f * outCh + c] += sample * curVol * cg;
                }

                v.framePos += rateRatio * cast(double) curP;
                curVol += volStep;
                curP += pitchStep;
                curPanVal += panStep;
            }
        }

        if (v.active) {
            v.curVolume = v.volume;
            v.curPitch = clampedTargetPitch;
            v.curPan = v.pan;
        }

        if (v.hasDsp) {
            processDspChain(v.dsp, targetBuf, outFrames, outCh, true);
            foreach (i; 0 .. needed)
                state.busAccum[busIdx][i] += targetBuf[i];
        }
    }

    // Apply per-bus DSP chains and sum active buses into master output.
    foreach (bi; 0 .. MAX_AUDIO_BUSES) {
        immutable bool activeBus = busActive[bi];
        immutable bool dspOn = state.busDspEnabled[bi];
        if (!activeBus && !dspOn)
            continue;
        if (dspOn)
            processDspChain(state.busDsp[bi], state.busAccum[bi][0 .. needed], outFrames, outCh, activeBus);
        foreach (i; 0 .. needed)
            outInterleaved[i] += state.busAccum[bi][i];
    }

    // Clamp master output softly to [-1, 1]
    foreach (i; 0 .. needed) {
        float s = outInterleaved[i];
        if (s > 1.0f) s = 1.0f;
        else if (s < -1.0f) s = -1.0f;
        outInterleaved[i] = s;
    }
}

private extern(C) void mixerStreamCallback(
    void* userdata,
    SDL_AudioStream* stream,
    int additionalAmount,
    int totalAmount
) nothrow @nogc @trusted {
    if (userdata is null || stream is null || additionalAmount <= 0) return;
    auto state = cast(MixerState*) userdata;
    if (!state.audioThreadExcluded) {
        excludeAudioThreadFromGc();
        state.audioThreadExcluded = true;
    }
    immutable uint ch = state.outputChannels > 0 ? cast(uint) state.outputChannels : 2;
    immutable uint bytesPerFrame = ch * cast(uint) float.sizeof;
    if (bytesPerFrame == 0) return;

    float[1024] scratch = void;
    immutable uint maxFramesPerChunk = cast(uint)(scratch.length / ch);
    int remainingBytes = additionalAmount;

    while (remainingBytes > 0) {
        uint frames = cast(uint)(remainingBytes / bytesPerFrame);
        if (frames == 0) frames = 1;
        if (frames > maxFramesPerChunk) frames = maxFramesPerChunk;

        immutable uint sampleCount = frames * ch;
        mixVoicesInto(*state, scratch[0 .. sampleCount], frames);
        SDL_PutAudioStreamData(stream, scratch.ptr, cast(int)(sampleCount * float.sizeof));
        remainingBytes -= cast(int)(frames * bytesPerFrame);
    }
}

/// Multi-voice polyphonic audio mixer (32 simultaneous voices, loop, pitch, SFX/Music buses)
/// driven asynchronously by an SDL3 audio stream callback with mutex locking.
/// Callers must keep played `AudioClip` buffers valid until the voice stops or `stopAll()` is called.
struct AudioMixer {
    private SDL_AudioStream* stream;
    private MixerState* state;
    private bool _ready;

    @disable this(this);

    /// Open a real-time polyphonic mixer on the default playback device.
    static AudioMixer create(int sampleRate = 48_000, int channels = 2) @trusted {
        import core.stdc.stdlib : calloc, free;
        import core.stdc.string : memset;

        AudioMixer m;
        auto st = cast(MixerState*) calloc(1, MixerState.sizeof);
        if (st is null) {
            err("AudioMixer: out of memory");
            return m;
        }
        *st = MixerState.init;
        st.outputRate = sampleRate > 0 ? sampleRate : 48_000;
        st.outputChannels = channels > 0 ? channels : 2;
        foreach (i; 0 .. MAX_AUDIO_VOICES) {
            st.voices[i].generation = 1;
        }

        SDL_AudioSpec spec;
        spec.format = SDL_AudioFormat.SDL_AUDIO_F32LE;
        spec.channels = st.outputChannels;
        spec.freq = st.outputRate;

        m.stream = SDL_OpenAudioDeviceStream(
            SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &spec,
            &mixerStreamCallback,
            st
        );
        if (m.stream is null) {
            err("AudioMixer: SDL_OpenAudioDeviceStream failed: ", fromStringz(SDL_GetError()));
            free(st);
            return m;
        }
        m.state = st;
        SDL_ResumeAudioStreamDevice(m.stream);
        m._ready = true;
        info("AudioMixer online: ", st.outputRate, "Hz, ", st.outputChannels, " ch, ", MAX_AUDIO_VOICES, " voices");
        return m;
    }

    bool isReady() const nothrow @nogc { return _ready && state !is null; }

    private bool resolveVoice(VoiceId id, out uint idx, out uint gen) const nothrow @nogc pure {
        if (id == 0) return false;
        idx = cast(uint)(id & 0xFFFF_FFFFu) - 1u;
        gen = cast(uint)(id >> 32);
        return idx < MAX_AUDIO_VOICES;
    }

    /// Start playing `clip` on a free voice slot. Returns a `VoiceId` (or `0` if full/unsupported).
    VoiceId play(
        ref const AudioClip clip,
        AudioBus bus = AudioBus.sfx,
        float volume = 1.0f,
        float pitch = 1.0f,
        bool loop = false,
        float pan = 0.0f,
        float spatialBlend = 0.0f
    ) @trusted nothrow @nogc {
        if (!isReady || !clip.isValid) return 0;
        if (clip.spec.format != SDL_AudioFormat.SDL_AUDIO_F32LE
            && clip.spec.format != SDL_AudioFormat.SDL_AUDIO_S16LE) {
            return 0;
        }
        if (clip.spec.channels <= 0 || clip.spec.freq <= 0) return 0;

        immutable uint sampleBytes = clip.spec.format == SDL_AudioFormat.SDL_AUDIO_S16LE ? 2 : 4;
        immutable uint bytesPerFrame = sampleBytes * cast(uint) clip.spec.channels;
        if (bytesPerFrame == 0) return 0;
        immutable uint frames = clip.length / bytesPerFrame;
        if (frames == 0) return 0;

        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);

        foreach (uint i; 0 .. MAX_AUDIO_VOICES) {
            if (!state.voices[i].active) {
                auto v = &state.voices[i];
                immutable uint gen = v.generation == 0 ? 1 : v.generation;
                immutable float vol = volume < 0 ? 0 : volume;
                immutable float bp = pitch > 0.01f ? pitch : 0.01f;
                immutable float clPan = pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan);

                v.data = clip.data;
                v.format = clip.spec.format;
                v.frameCount = frames;
                v.channels = cast(uint) clip.spec.channels;
                v.sampleRate = clip.spec.freq;
                v.framePos = 0.0;
                v.streamRing = null;
                v.streamEof = null;
                v.streamPrimed = false;
                v.volume = vol;
                v.curVolume = vol;
                v.basePitch = bp;
                v.dopplerPitch = 1.0f;
                v.curPitch = bp;
                v.pan = clPan;
                v.curPan = clPan;
                v.spatialBlend = spatialBlend < 0 ? 0 : (spatialBlend > 1 ? 1 : spatialBlend);
                v.bus = bus;
                v.loop = loop;
                v.paused = false;
                v.hasDsp = false;
                v.generation = gen;
                v.active = true;
                return (cast(VoiceId) gen << 32) | cast(VoiceId)(i + 1);
            }
        }
        return 0;
    }

    /// Start playing a compressed `AudioStream` on a free voice slot.
    /// Caller must keep `streamSource` alive and call `streamSource.pump()` periodically.
    VoiceId playStream(
        ref AudioStream streamSource,
        AudioBus bus = AudioBus.music,
        float volume = 1.0f,
        float pitch = 1.0f,
        float pan = 0.0f,
        float spatialBlend = 0.0f
    ) @trusted nothrow @nogc {
        if (!isReady || !streamSource.isValid()) return 0;

        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);

        foreach (uint i; 0 .. MAX_AUDIO_VOICES) {
            if (!state.voices[i].active) {
                auto v = &state.voices[i];
                immutable uint gen = v.generation == 0 ? 1 : v.generation;
                immutable float vol = volume < 0 ? 0 : volume;
                immutable float bp = pitch > 0.01f ? pitch : 0.01f;
                immutable float clPan = pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan);

                v.data = null;
                v.format = SDL_AudioFormat.SDL_AUDIO_F32LE;
                v.frameCount = 0;
                v.channels = cast(uint) streamSource.channels();
                v.sampleRate = streamSource.sampleRate();
                v.framePos = 0.0;
                v.streamRing = &streamSource._ring;
                v.streamEof = &streamSource._eof;
                v.streamFrac = 0.0;
                v.streamPrimed = false;
                v.volume = vol;
                v.curVolume = vol;
                v.basePitch = bp;
                v.dopplerPitch = 1.0f;
                v.curPitch = bp;
                v.pan = clPan;
                v.curPan = clPan;
                v.spatialBlend = spatialBlend < 0 ? 0 : (spatialBlend > 1 ? 1 : spatialBlend);
                v.bus = bus;
                v.loop = false;
                v.paused = false;
                v.hasDsp = false;
                v.generation = gen;
                v.active = true;
                return (cast(VoiceId) gen << 32) | cast(VoiceId)(i + 1);
            }
        }
        return 0;
    }

    /// Stop a single voice immediately.
    void stop(VoiceId id) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen) {
            resetVoice(*v);
            v.generation++;
        }
    }

    void setPaused(VoiceId id, bool paused) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen) v.paused = paused;
    }

    void setVolume(VoiceId id, float volume) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen) v.volume = volume < 0 ? 0 : volume;
    }

    void setPitch(VoiceId id, float pitch) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen) v.basePitch = pitch > 0.01f ? pitch : 0.01f;
    }

    /// Set the Doppler pitch multiplier (multiplied with `basePitch`) for a voice.
    void setDopplerPitch(VoiceId id, float dopplerPitch) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen)
            v.dopplerPitch = dopplerPitch > 0.01f ? dopplerPitch : 0.01f;
    }

    void setSpatialBlend(VoiceId id, float spatialBlend) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen)
            v.spatialBlend = spatialBlend < 0.0f ? 0.0f : (spatialBlend > 1.0f ? 1.0f : spatialBlend);
    }

    /// Attach or replace a per-voice real-time DSP chain.
    void setVoiceDsp(VoiceId id, in DspChain chain) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen) {
            v.dsp = chain;
            v.hasDsp = true;
        }
    }

    void clearVoiceDsp(VoiceId id) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen)
            v.hasDsp = false;
    }

    /// Attach or replace a real-time DSP chain for an entire `AudioBus` (e.g., `DspChain.vhfRadio()`).
    void setBusDsp(AudioBus bus, in DspChain chain) @trusted nothrow @nogc {
        if (!isReady) return;
        SDL_LockAudioStream(stream);
        state.busDsp[bus] = chain;
        state.busDspEnabled[bus] = true;
        SDL_UnlockAudioStream(stream);
    }

    void clearBusDsp(AudioBus bus) @trusted nothrow @nogc {
        if (!isReady) return;
        SDL_LockAudioStream(stream);
        state.busDspEnabled[bus] = false;
        SDL_UnlockAudioStream(stream);
    }

    /// Set stereo pan for a voice: `-1` full left, `0` center, `+1` full right.
    /// Mono sources are placed in the stereo field; stereo sources get balance.
    /// Values are clamped; has no effect on non-stereo mixer outputs.
    void setPan(VoiceId id, float pan) @trusted nothrow @nogc {
        if (!isReady) return;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        if (v.active && v.generation == gen) v.pan = pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan);
    }

    bool isPlaying(VoiceId id) @trusted nothrow @nogc {
        if (!isReady) return false;
        uint idx, gen;
        if (!resolveVoice(id, idx, gen)) return false;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        auto v = &state.voices[idx];
        return v.active && v.generation == gen && !v.paused;
    }

    /// Set overall master hardware output gain (default `1.0`).
    bool setMasterGain(float gain) @trusted nothrow @nogc {
        if (!isReady) return false;
        immutable float g = gain < 0 ? 0 : gain;
        state.masterGain = g;
        return SDL_SetAudioStreamGain(stream, g);
    }

    float masterGain() const @trusted nothrow @nogc {
        if (!isReady) return 0.0f;
        return SDL_GetAudioStreamGain(cast(SDL_AudioStream*) stream);
    }

    /// Set volume multiplier for an entire bus (`AudioBus.sfx` or `AudioBus.music`).
    void setBusGain(AudioBus bus, float gain) @trusted nothrow @nogc {
        if (!isReady) return;
        SDL_LockAudioStream(stream);
        state.busGains[bus] = gain < 0 ? 0 : gain;
        SDL_UnlockAudioStream(stream);
    }

    float busGain(AudioBus bus) const nothrow @nogc {
        if (state is null) return 0.0f;
        return () @trusted { return state.busGains[bus]; }();
    }

    void stopBus(AudioBus bus) @trusted nothrow @nogc {
        if (!isReady) return;
        SDL_LockAudioStream(stream);
        foreach (i; 0 .. MAX_AUDIO_VOICES) {
            if (state.voices[i].active && state.voices[i].bus == bus) {
                resetVoice(state.voices[i]);
                state.voices[i].generation++;
            }
        }
        SDL_UnlockAudioStream(stream);
    }

    void stopAll() @trusted nothrow @nogc {
        if (!isReady) return;
        SDL_LockAudioStream(stream);
        foreach (i; 0 .. MAX_AUDIO_VOICES) {
            if (state.voices[i].active) {
                resetVoice(state.voices[i]);
                state.voices[i].generation++;
            }
        }
        SDL_UnlockAudioStream(stream);
        SDL_ClearAudioStream(stream);
    }

    uint activeVoiceCount() @trusted nothrow @nogc {
        if (!isReady) return 0;
        SDL_LockAudioStream(stream);
        scope(exit) SDL_UnlockAudioStream(stream);
        uint count = 0;
        foreach (i; 0 .. MAX_AUDIO_VOICES) {
            if (state.voices[i].active) count++;
        }
        return count;
    }

    void destroy() @trusted nothrow @nogc {
        import core.stdc.stdlib : free;
        if (stream !is null) {
            SDL_DestroyAudioStream(stream);
            stream = null;
        }
        if (state !is null) {
            free(state);
            state = null;
        }
        _ready = false;
    }

    ~this() @trusted nothrow @nogc { destroy(); }
}

unittest {
    // Verify thread exclusion calls are safe no-ops or active depending on runtime
    excludeAudioThreadFromGc();
    includeAudioThreadInGc();

    // Verify pure software mixer math (polyphonic mix, bus gain, loop wrap, one-shot completion)
    MixerState st;
    st.outputRate = 48_000;
    st.outputChannels = 2;
    st.busGains[AudioBus.sfx] = 0.5f;
    st.busGains[AudioBus.music] = 0.25f;

    static immutable float[8] clipA = [0.4f, 0.4f, 0.4f, 0.4f, 0.4f, 0.4f, 0.4f, 0.4f];
    static immutable short[4] clipB = [16384, -16384, 16384, -16384]; // +/- 0.5 in S16LE

    static MixerVoice makeClipVoice(const(ubyte)* data, SDL_AudioFormat fmt, uint frames,
                                    uint ch, AudioBus bus, bool loop, float pan = 0.0f) nothrow @nogc @trusted {
        MixerVoice v;
        v.data = data;
        v.format = fmt;
        v.frameCount = frames;
        v.channels = ch;
        v.sampleRate = 48_000;
        v.bus = bus;
        v.loop = loop;
        v.pan = pan;
        v.curPan = pan;
        v.active = true;
        return v;
    }

    () @trusted {
        st.voices[0] = makeClipVoice(cast(const(ubyte)*) clipA.ptr, SDL_AudioFormat.SDL_AUDIO_F32LE, 4, 2, AudioBus.sfx, false);
        st.voices[1] = makeClipVoice(cast(const(ubyte)*) clipB.ptr, SDL_AudioFormat.SDL_AUDIO_S16LE, 2, 2, AudioBus.music, true);
    }();
    float[12] outBuf = 0.0f;
    () @trusted {
        mixVoicesInto(st, outBuf[], 6);
    }();
    // Frame 0: L = 0.4*0.5 + 0.5*0.25 = 0.325; R = 0.4*0.5 - 0.5*0.25 = 0.075
    assert(outBuf[0] > 0.32f && outBuf[0] < 0.33f);
    assert(outBuf[1] > 0.07f && outBuf[1] < 0.08f);
    // Voice 0 (4 frames, non-looping) finished; Voice 1 (2 frames, looping) kept running
    assert(!st.voices[0].active);
    assert(st.voices[1].active);

    // Pan: mono source, hard right silences left, center keeps unity.
    static immutable float[4] mono = [1.0f, 1.0f, 1.0f, 1.0f];
    MixerState sp;
    sp.outputRate = 48_000;
    sp.outputChannels = 2;
    () @trusted {
        sp.voices[0] = makeClipVoice(cast(const(ubyte)*) mono.ptr, SDL_AudioFormat.SDL_AUDIO_F32LE, 4, 1, AudioBus.sfx, false, 1.0f);
    }();
    float[4] pb = 0.0f;
    () @trusted { mixVoicesInto(sp, pb[], 2); }();
    assert(pb[0] < 0.001f && pb[1] > 0.999f);
    sp.voices[0].active = true; sp.voices[0].framePos = 0; sp.voices[0].pan = 0.0f; sp.voices[0].curPan = 0.0f;
    () @trusted { mixVoicesInto(sp, pb[], 2); }();
    assert(pb[0] > 0.999f && pb[1] > 0.999f);

    // Radio bus DSP + stream ring buffer mixing (zero GC).
    MixerState sr;
    sr.outputRate = 48_000;
    sr.outputChannels = 2;
    sr.busDsp[AudioBus.radio] = DspChain.vhfRadio(48_000);
    sr.busDspEnabled[AudioBus.radio] = true;

    PcmRingBuffer ring;
    assert(ring.init(1, 64));
    float[16] tone;
    foreach (i; 0 .. 16)
        tone[i] = 0.5f;
    assert(ring.pushFrames(tone.ptr, 16) == 16);
    shared bool eofFlag = true;
    () @trusted {
        sr.voices[0].streamRing = &ring;
        sr.voices[0].streamEof = &eofFlag;
        sr.voices[0].channels = 1;
        sr.voices[0].sampleRate = 48_000;
        sr.voices[0].bus = AudioBus.radio;
        sr.voices[0].active = true;
        float[16] mixOut = 0.0f;
        mixVoicesInto(sr, mixOut[], 8);
        assert(mixOut[0] != 0.0f);
    }();
}
