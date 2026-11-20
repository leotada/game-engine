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
import engine.math.vec : Vec3;

@safe:

/// Listener pose. `right` must be the unit vector pointing to the listener's right ear.
struct Listener3D {
    Vec3 position = Vec3(0, 0, 0);
    Vec3 right    = Vec3(1, 0, 0);
}

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
}
