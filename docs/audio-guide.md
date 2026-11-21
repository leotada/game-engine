# Audio Guide (`engine.audio`)

This guide covers the engine's SDL3-backed audio subsystem: 8-bus polyphonic mixing, real-time `@nogc` DSP chains (biquad filters & VHF police radio preset), 3D spatialization with Doppler shift, and lock-free OGG Vorbis streaming via `stb_vorbis`.

> **Real-time safety:** All mixer callbacks, DSP processing, 3D spatial helpers, and ring-buffer reads run `@safe nothrow @nogc` with zero heap allocations on the audio thread. Call `excludeAudioThreadFromGc()` in any custom audio callback if you bypass `AudioMixer`.

---

## 1. Architecture Overview

| Module | Purpose |
|---|---|
| `engine.audio.engine` | `AudioClip` (WAV / F32 PCM), `AudioEngine` (simple one-shots), `AudioMixer` (polyphonic voices, 8 buses, DSP, pan, pitch, streaming) |
| `engine.audio.dsp` | `DspChain` (4-slot POD chain), `DspEffectSlot` (`lowPass`, `highPass`, `bandPass`, `waveshaper`, `staticHiss`, `DspChain.vhfRadio()`) |
| `engine.audio.spatial` | `Listener3D`, `AudioListener3D`, `AudioSource3D`, `SpatialParams`, `play3D`, `playStream3D`, `updateVoice3D`, `updateSource3D`, `dopplerPitch` |
| `engine.audio.stream` | `PcmRingBuffer` (lock-free SPSC), `AudioStream` (OGG Vorbis file/memory decoding via `stb_vorbis`), `AudioStreamDecoder` |

Re-exported from `import engine;` or `import engine.audio;`.

---

## 2. `AudioMixer` & the 8 Audio Buses

`AudioMixer` mixes up to 32 polyphonic voices at 48 kHz stereo F32 into an SDL3 audio stream. Every voice is routed into one of 8 independent buses (`AudioBus`):

| Bus | Typical Usage |
|---|---|
| `AudioBus.sfx` | Gameplay sound effects, impacts, footsteps |
| `AudioBus.music` | Background music / dynamic stems |
| `AudioBus.voice` | Character dialogue |
| `AudioBus.radio` | Police/tactical radio chatter (often paired with `DspChain.vhfRadio()`) |
| `AudioBus.ambient` | Environmental beds, wind, city hum |
| `AudioBus.ui` | Menu clicks and HUD notifications |
| `AudioBus.custom0` | Game-specific bus |
| `AudioBus.custom1` | Game-specific bus |

### Basic Playback & Bus Control

```d
import engine.audio;

auto mixer = AudioMixer.create();
scope(exit) mixer.destroy();

auto click = AudioClip.loadWav("assets/sfx/click.wav");
scope(exit) click.destroy();

mixer.setMasterGain(0.9f);
mixer.setBusGain(AudioBus.sfx, 0.8f);

VoiceId v = mixer.play(click, AudioBus.sfx, volume: 1.0f, pitch: 1.05f, loop: false, pan: 0.0f);
if (mixer.isPlaying(v)) {
    mixer.setVolume(v, 0.5f);
    mixer.setPan(v, -0.4f); // -1.0 = left, +1.0 = right
}
```

- `VoiceId` (`ulong`) is a generational handle (`0` = invalid / skipped).
- Call `mixer.stop(v)` or `mixer.setPaused(v, true/false)` to control live voices.

---

## 3. Real-Time Bus & Voice DSP (`engine.audio.dsp`)

Each bus and each voice can run a fixed-size 4-slot POD `DspChain` (`MAX_DSP_SLOTS = 4`) processed in-place on the audio thread.

### Available Effects (`DspEffectSlot`)

- `DspEffectSlot.lowPass(cutoffHz, q = 0.7071f, sampleRate = 48_000)`
- `DspEffectSlot.highPass(cutoffHz, q = 0.7071f, sampleRate = 48_000)`
- `DspEffectSlot.bandPass(centerHz, q = 1.0f, sampleRate = 48_000)`
- `DspEffectSlot.waveshaper(drive = 2.5f, hardClipBlend = 0.5f, makeupGain = 0.85f)`
- `DspEffectSlot.staticHiss(level = 0.035f, squelchThreshold = 0.001f)` — gates noise by signal presence when `squelchThreshold > 0`.

### Preset: VHF Police Radio (`DspChain.vhfRadio`)

`DspChain.vhfRadio()` combines an 800 Hz high-pass filter, 3 kHz low-pass filter, mild waveshaper saturation, and squelched static hiss:

```d
mixer.setBusDsp(AudioBus.radio, DspChain.vhfRadio());
mixer.play(dispatchClip, AudioBus.radio);

// Per-voice override (e.g., muffled underwater or interior occlusion):
DspChain muffled;
muffled.slots[0] = DspEffectSlot.lowPass(650.0f);
mixer.setVoiceDsp(voiceId, muffled);

// Remove DSP later:
mixer.clearBusDsp(AudioBus.radio);
```

---

## 4. 3D Spatial Audio & Doppler Shift (`engine.audio.spatial`)

### Lightweight One-Shots (`Listener3D` + `SpatialParams`)

`distanceGain` implements OpenAL-style inverse-distance attenuation (`ref / (ref + rolloff * (d - ref))`) with a smoothstep taper over the final 20% of `maxDistance`.

```d
Listener3D ear = { position: camPos, right: camRight };
VoiceId v = play3D(mixer, impactClip, hitPos, ear,
                   SpatialParams(refDistance: 2.0f, maxDistance: 60.0f, rolloff: 1.0f),
                   volume: 1.0f, pitch: 0.95f);

// Keep updating a moving emitter:
updateVoice3D(mixer, v, newPos, ear, SpatialParams(2.0f, 60.0f));
```

### Full Velocity & Doppler (`AudioListener3D` + `AudioSource3D`)

Use `AudioListener3D` and `AudioSource3D` for vehicles, sirens, and moving sources that need Doppler pitch shifts and `spatialBlend` (`0.0` = 2D stereo, `1.0` = mono downmix + 3D pan):

```d
AudioListener3D listener = {
    position: playerPos,
    forward:  camForward,
    up:       Vec3(0, 1, 0),
    velocity: playerVel,
};

AudioSource3D siren = {
    position:      carPos,
    velocity:      carVel,
    refDistance:   4.0f,
    maxDistance:   120.0f,
    rolloffFactor: 1.0f,
    dopplerFactor: 1.0f,
    spatialBlend:  1.0f,
    baseVolume:    0.9f,
    basePitch:     1.0f,
    bus:           AudioBus.sfx,
};

VoiceId sirenVoice = play3D(mixer, sirenClip, siren, listener, loop: true);

// Each frame:
updateSource3D(mixer, sirenVoice, siren, listener);
```

- `dopplerPitch(emitterPos, emitterVel, listener, dopplerFactor = 1.0f, speedOfSound = 343.0f)` clamps radial velocities to `0.9 * speedOfSound` and outputs a pitch multiplier in `[0.25, 4.0]`.

---

## 5. OGG Vorbis Streaming (`engine.audio.stream`)

`AudioStream` decodes `.ogg` Vorbis files or in-memory OGG buffers via vendored `stb_vorbis` into a lock-free SPSC `PcmRingBuffer`. The audio thread consumes frames with zero allocations; your main/loader thread feeds the ring buffer by calling `pump()` once per frame.

```d
auto music = AudioStream.openOggFile("assets/audio/chase_theme.ogg", loop: true);
scope(exit) music.close();

if (music.isValid()) {
    VoiceId musicVoice = mixer.playStream(music, AudioBus.music, volume: 0.65f);

    // Every frame on the main thread:
    music.pump(4096);
}
```

- **In-memory streams:** `AudioStream.openOggMemory(oggBytes, loop: false, bufferFrames: 32_768)`.
- **3D streams:** `playStream3D(mixer, stream, source3D, listener3D)` + `updateSource3D(...)`.
- **Seeking:** `stream.seekStart()` rewinds to the beginning of the OGG stream.
- **Custom decoders:** Implement `AudioStreamDecoder` if you want to feed `PcmRingBuffer` from another codec.
