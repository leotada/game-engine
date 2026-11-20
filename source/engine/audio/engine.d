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

/// Bus groups for independent SFX and music volume mixing.
enum AudioBus : ubyte {
    sfx   = 0,
    music = 1,
}

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
    float volume = 1.0f;
    float pitch = 1.0f;
    AudioBus bus = AudioBus.sfx;
    bool loop = false;
    bool paused = false;
    bool active = false;
    uint generation = 1;
    float pan = 0.0f; ///< -1 = full left, 0 = center, +1 = full right (stereo output only).
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
    float[2] busGains = [1.0f, 1.0f];
    float masterGain = 1.0f;
    int outputRate = 48_000;
    int outputChannels = 2;
}

private float readSampleNorm(const(ubyte)* data, SDL_AudioFormat fmt,
                           uint frame, uint ch, uint channels) nothrow @nogc @trusted {
    immutable size_t idx = cast(size_t) frame * channels + ch;
    if (fmt == SDL_AudioFormat.SDL_AUDIO_S16LE) {
        return (cast(const(short)*) data)[idx] * (1.0f / 32768.0f);
    }
    return (cast(const(float)*) data)[idx];
}

private void mixVoicesInto(ref MixerState state, float[] outInterleaved, uint outFrames) nothrow @nogc {
    immutable uint outCh = state.outputChannels > 0 ? cast(uint) state.outputChannels : 2;
    immutable size_t needed = cast(size_t) outFrames * outCh;
    if (outInterleaved.length < needed) return;
    outInterleaved[0 .. needed] = 0.0f;

    foreach (vi; 0 .. MAX_AUDIO_VOICES) {
        auto v = &state.voices[vi];
        if (!v.active || v.paused || v.data is null || v.frameCount == 0) continue;

        immutable float gain = v.volume * state.busGains[v.bus];
        immutable double safePitch = v.pitch > 0.01f ? v.pitch : 0.01f;
        immutable double step = (cast(double) v.sampleRate / cast(double) state.outputRate) * safePitch;
        immutable uint srcCh = v.channels > 0 ? v.channels : 1;
        float panL = 1.0f, panR = 1.0f;
        if (outCh == 2) panGains(v.pan, panL, panR);

        foreach (f; 0 .. outFrames) {
            if (v.framePos >= cast(double) v.frameCount) {
                if (v.loop) {
                    while (v.framePos >= cast(double) v.frameCount) {
                        v.framePos -= cast(double) v.frameCount;
                    }
                } else {
                    v.active = false;
                    v.data = null;
                    break;
                }
            }

            immutable uint f0 = cast(uint) v.framePos;
            immutable float frac = cast(float)(v.framePos - cast(double) f0);
            uint f1 = f0 + 1;
            if (f1 >= v.frameCount) {
                f1 = v.loop ? 0 : (v.frameCount - 1);
            }

            foreach (c; 0 .. outCh) {
                immutable uint sc = c < srcCh ? c : 0;
                immutable float s0 = readSampleNorm(v.data, v.format, f0, sc, srcCh);
                immutable float s1 = readSampleNorm(v.data, v.format, f1, sc, srcCh);
                immutable float cg = outCh == 2 ? (c == 0 ? panL : panR) : 1.0f;
                outInterleaved[cast(size_t) f * outCh + c] += (s0 + (s1 - s0) * frac) * gain * cg;
            }

            v.framePos += step;
        }
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
        float pan = 0.0f
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
                v.data = clip.data;
                v.format = clip.spec.format;
                v.frameCount = frames;
                v.channels = cast(uint) clip.spec.channels;
                v.sampleRate = clip.spec.freq;
                v.framePos = 0.0;
                v.volume = volume < 0 ? 0 : volume;
                v.pitch = pitch > 0.01f ? pitch : 0.01f;
                v.bus = bus;
                v.loop = loop;
                v.pan = pan < -1.0f ? -1.0f : (pan > 1.0f ? 1.0f : pan);
                v.paused = false;
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
            v.active = false;
            v.data = null;
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
        if (v.active && v.generation == gen) v.pitch = pitch > 0.01f ? pitch : 0.01f;
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
                state.voices[i].active = false;
                state.voices[i].data = null;
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
                state.voices[i].active = false;
                state.voices[i].data = null;
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

    () @trusted {
        st.voices[0] = MixerVoice(cast(const(ubyte)*) clipA.ptr, SDL_AudioFormat.SDL_AUDIO_F32LE, 4, 2, 48_000, 0.0, 1.0f, 1.0f, AudioBus.sfx, false, false, true, 1);
        st.voices[1] = MixerVoice(cast(const(ubyte)*) clipB.ptr, SDL_AudioFormat.SDL_AUDIO_S16LE, 2, 2, 48_000, 0.0, 1.0f, 1.0f, AudioBus.music, true, false, true, 1);
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
        sp.voices[0] = MixerVoice(cast(const(ubyte)*) mono.ptr, SDL_AudioFormat.SDL_AUDIO_F32LE, 4, 1, 48_000, 0.0, 1.0f, 1.0f, AudioBus.sfx, false, false, true, 1, 1.0f);
    }();
    float[4] pb = 0.0f;
    () @trusted { mixVoicesInto(sp, pb[], 2); }();
    assert(pb[0] < 0.001f && pb[1] > 0.999f);
    sp.voices[0].active = true; sp.voices[0].framePos = 0; sp.voices[0].pan = 0.0f;
    () @trusted { mixVoicesInto(sp, pb[], 2); }();
    assert(pb[0] > 0.999f && pb[1] > 0.999f);
}
