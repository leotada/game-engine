/// 3D one-shot SFX helpers for `AudioMixer`: stereo panning from listener
/// orientation, logarithmic (inverse-distance) attenuation and pitch.
///
///   Listener3D ear = { position: cam.pos, right: cam.right };
///   play3D(mixer, glassBreak, hitPos, ear, SpatialParams(refDistance: 2, maxDistance: 40),
///          pitch: 0.95f + rnd * 0.1f);
///
/// Everything is `@nogc nothrow`; panning is applied per voice in the mixer
/// (`AudioMixer.setPan`), so no pre-panned clip copies are needed and a
/// moving emitter can keep updating its voice with `updateVoice3D`.
module engine.audio.spatial;

import engine.audio.engine;
import engine.audio.stream : AudioStream;
import engine.core.pod : isPod;
import engine.math.vec : Vec3;

@safe:

/// Listener pose (legacy lightweight form). `right` must be the unit vector pointing right.
struct Listener3D {
    Vec3 position = Vec3(0, 0, 0);
    Vec3 right    = Vec3(1, 0, 0);
}

/// Full 3D listener pose and velocity for spatialization + Doppler shift.
struct AudioListener3D {
    Vec3 position = Vec3(0, 0, 0);
    Vec3 forward  = Vec3(0, 0, -1);
    Vec3 up       = Vec3(0, 1, 0);
    Vec3 velocity = Vec3(0, 0, 0);

    Vec3 right() const pure nothrow @nogc {
        immutable r = forward.cross(up);
        immutable len = r.length();
        return len > 1e-5f ? (r / len) : Vec3(1, 0, 0);
    }

    Listener3D toListener3D() const pure nothrow @nogc {
        return Listener3D(position, right());
    }
}

/// POD 3D emitter descriptor with distance rolloff, Doppler factor, and spatial blend.
struct AudioSource3D {
    Vec3 position      = Vec3(0, 0, 0);
    Vec3 velocity      = Vec3(0, 0, 0);
    float refDistance  = 1.0f;
    float maxDistance  = 50.0f;
    float rolloffFactor = 1.0f;
    float dopplerFactor = 1.0f;
    float spatialBlend = 1.0f; ///< 0 = 2D/stereo untouched, 1 = mono downmix + 3D pan.
    float baseVolume   = 1.0f;
    float basePitch    = 1.0f;
    AudioBus bus       = AudioBus.sfx;

    SpatialParams spatialParams() const pure nothrow @nogc {
        return SpatialParams(refDistance, maxDistance, rolloffFactor);
    }
}

static assert(isPod!Listener3D);
static assert(isPod!AudioListener3D);
static assert(isPod!AudioSource3D);

/// Distance attenuation parameters (OpenAL-style inverse-distance model).
struct SpatialParams {
    /// Distance at which gain is 1.0 (closer is clamped to full volume).
    float refDistance = 1.0f;
    /// Beyond this distance the sound is inaudible and `play3D` skips the voice.
    float maxDistance = 50.0f;
    /// 1.0 = -6 dB per doubling of distance (physical); higher = faster falloff.
    float rolloff = 1.0f;
}

/// Logarithmic attenuation: `ref / (ref + rolloff * (d - ref))`, with a smooth
/// taper over the last 20 % of `maxDistance` so voices never cut off abruptly.
float distanceGain(float distance, in SpatialParams p) pure nothrow @nogc {
    immutable float ref_ = p.refDistance > 0.0001f ? p.refDistance : 0.0001f;
    if (distance >= p.maxDistance) return 0.0f;
    immutable float d = distance < ref_ ? ref_ : distance;
    float g = ref_ / (ref_ + (p.rolloff < 0 ? 0 : p.rolloff) * (d - ref_));
    immutable float taperStart = p.maxDistance * 0.8f;
    if (d > taperStart && p.maxDistance > taperStart) {
        immutable float t = (d - taperStart) / (p.maxDistance - taperStart);
        g *= 1.0f - t * t * (3.0f - 2.0f * t);
    }
    return g;
}

/// Stereo pan in `[-1, 1]` for an emitter relative to the listener
/// (`-1` fully to the left, `+1` fully to the right, `0` ahead/behind/on top).
float emitterPan(Vec3 emitter, in Listener3D l) pure nothrow @nogc {
    immutable Vec3 d = emitter - l.position;
    immutable float len = d.length();
    if (len < 0.0001f) return 0.0f;
    immutable float p = d.dot(l.right) / len;
    return p < -1.0f ? -1.0f : (p > 1.0f ? 1.0f : p);
}

/// Fire a positional one-shot. Returns the `VoiceId` (`0` when out of range,
/// silent, or no free voice). `volume` scales on top of distance attenuation.
VoiceId play3D(ref AudioMixer mixer, ref const AudioClip clip, Vec3 emitter,
               in Listener3D listener, in SpatialParams params = SpatialParams.init,
               float volume = 1.0f, float pitch = 1.0f,
               AudioBus bus = AudioBus.sfx) nothrow @nogc {
    immutable float g = distanceGain(emitter.distanceTo(listener.position), params) * volume;
    if (g <= 0.0005f) return 0;
    return mixer.play(clip, bus, g, pitch, false, emitterPan(emitter, listener));
}

/// Re-spatialize a live voice (moving emitter or turning listener).
void updateVoice3D(ref AudioMixer mixer, VoiceId id, Vec3 emitter,
                   in Listener3D listener, in SpatialParams params = SpatialParams.init,
                   float volume = 1.0f) nothrow @nogc {
    mixer.setVolume(id, distanceGain(emitter.distanceTo(listener.position), params) * volume);
    mixer.setPan(id, emitterPan(emitter, listener));
}

/// Compute Doppler pitch multiplier from relative radial velocity (`speedOfSound` in m/s).
/// Approaching emitters raise pitch (> 1.0); receding emitters lower pitch (< 1.0).
float dopplerPitch(Vec3 emitterPos,
                   Vec3 emitterVel,
                   in AudioListener3D listener,
                   float dopplerFactor = 1.0f,
                   float speedOfSound = 343.0f) pure nothrow @nogc {
    if (dopplerFactor <= 0.0f || speedOfSound <= 1.0f)
        return 1.0f;

    immutable Vec3 delta = emitterPos - listener.position;
    immutable float dist = delta.length();
    if (dist < 1e-4f)
        return 1.0f;

    immutable Vec3 dir = delta / dist;
    immutable float maxV = speedOfSound * 0.9f;
    immutable float vL = clampFloat(listener.velocity.dot(dir) * dopplerFactor, -maxV, maxV);
    immutable float vS = clampFloat(emitterVel.dot(dir) * dopplerFactor, -maxV, maxV);

    immutable float ratio = (speedOfSound + vL) / (speedOfSound + vS);
    return clampFloat(ratio, 0.25f, 4.0f);
}

/// Play a `AudioClip` using full `AudioSource3D` + `AudioListener3D` (attenuation, pan, Doppler).
VoiceId play3D(ref AudioMixer mixer,
               ref const AudioClip clip,
               in AudioSource3D source,
               in AudioListener3D listener,
               bool loop = false) nothrow @nogc {
    immutable float g = distanceGain(source.position.distanceTo(listener.position), source.spatialParams()) * source.baseVolume;
    if (!loop && g <= 0.0005f) return 0;

    immutable l3 = listener.toListener3D();
    immutable float p = emitterPan(source.position, l3) * clampFloat(source.spatialBlend, 0.0f, 1.0f);
    immutable VoiceId id = mixer.play(clip, source.bus, g, source.basePitch, loop, p, source.spatialBlend);
    if (id != 0)
        mixer.setDopplerPitch(id, dopplerPitch(source.position, source.velocity, listener, source.dopplerFactor));
    return id;
}

/// Play an `AudioStream` using full `AudioSource3D` + `AudioListener3D`.
VoiceId playStream3D(ref AudioMixer mixer,
                     ref AudioStream streamSource,
                     in AudioSource3D source,
                     in AudioListener3D listener) nothrow @nogc {
    immutable float g = distanceGain(source.position.distanceTo(listener.position), source.spatialParams()) * source.baseVolume;
    immutable l3 = listener.toListener3D();
    immutable float p = emitterPan(source.position, l3) * clampFloat(source.spatialBlend, 0.0f, 1.0f);
    immutable VoiceId id = mixer.playStream(streamSource, source.bus, g, source.basePitch, p, source.spatialBlend);
    if (id != 0)
        mixer.setDopplerPitch(id, dopplerPitch(source.position, source.velocity, listener, source.dopplerFactor));
    return id;
}

/// Update volume, pan, spatial blend, and Doppler pitch of a live 3D voice.
void updateSource3D(ref AudioMixer mixer,
                    VoiceId id,
                    in AudioSource3D source,
                    in AudioListener3D listener) nothrow @nogc {
    immutable float g = distanceGain(source.position.distanceTo(listener.position), source.spatialParams()) * source.baseVolume;
    immutable l3 = listener.toListener3D();
    immutable float p = emitterPan(source.position, l3) * clampFloat(source.spatialBlend, 0.0f, 1.0f);
    mixer.setVolume(id, g);
    mixer.setPan(id, p);
    mixer.setSpatialBlend(id, source.spatialBlend);
    mixer.setDopplerPitch(id, dopplerPitch(source.position, source.velocity, listener, source.dopplerFactor));
}

private float clampFloat(float v, float lo, float hi) pure nothrow @nogc {
    return v < lo ? lo : (v > hi ? hi : v);
}

unittest {
    SpatialParams p; p.refDistance = 2; p.maxDistance = 100;
    assert(distanceGain(1, p) == 1.0f);                 // inside ref: full
    assert(distanceGain(2, p) == 1.0f);
    immutable g4 = distanceGain(4, p), g8 = distanceGain(8, p);
    assert(g4 > 0.49f && g4 < 0.51f);                   // ~ -6 dB per doubling
    assert(g8 < g4);
    assert(distanceGain(100, p) == 0.0f);

    Listener3D l;
    assert(emitterPan(Vec3(5, 0, 0), l) > 0.99f);
    assert(emitterPan(Vec3(-5, 0, 0), l) < -0.99f);
    assert(emitterPan(Vec3(0, 0, 5), l) == 0.0f);
    assert(emitterPan(Vec3(0, 0, 0), l) == 0.0f);

    // Doppler shift: approaching emitter raises pitch; receding lowers pitch.
    AudioListener3D ear;
    ear.position = Vec3(0, 0, 0);
    ear.velocity = Vec3(0, 0, 0);
    immutable float dApproach = dopplerPitch(Vec3(10, 0, 0), Vec3(-30, 0, 0), ear);
    immutable float dRecede   = dopplerPitch(Vec3(10, 0, 0), Vec3(30, 0, 0), ear);
    assert(dApproach > 1.08f && dApproach < 1.12f);
    assert(dRecede < 0.93f && dRecede > 0.90f);
}
