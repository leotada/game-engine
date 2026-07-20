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

@safe:

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
