/// Headless animation demo and benchmark: N characters, per-stage timings, optional GC assertion.
///
///   dub run --config=anim -- --headless-frames=600 --assert-no-gc [--characters=1000] [--skeleton=ruby]
module demo.anim_demo;

import core.memory : GC;
import std.conv : to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.stdio : writefln, writeln;

import engine.animation;
import engine.animation.ecs;
import engine.ecs.world : World;
import engine.math.vec : Vec3;

alias AnimWorld = World!(AnimSkeleton, AnimPlayback, AnimBlend2, AnimAdditive, AnimLookAt, AnimTwoBoneIK);

private enum string fixtures = "assets/animation/test/";

void main(string[] args) {
    uint frames = 600;
    uint characters = 100;
    bool assertNoGc;
    string skelName = "pab";
    foreach (a; args[1 .. $]) {
        if (a == "--assert-no-gc") assertNoGc = true;
        else if (a.length > 18 && a[0 .. 18] == "--headless-frames=") frames = to!uint(a[18 .. $]);
        else if (a.length > 13 && a[0 .. 13] == "--characters=") characters = to!uint(a[13 .. $]);
        else if (a.length > 11 && a[0 .. 11] == "--skeleton=") skelName = a[11 .. $];
    }

    string skelFile, clipA, clipB;
    if (skelName == "ruby") { skelFile = "ruby_skeleton.ozz"; clipA = "ruby_animation.ozz"; clipB = clipA; }
    else { skelFile = "pab/skeleton.ozz"; clipA = "pab/walk.ozz"; clipB = "pab/jog.ozz"; }

    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtures ~ skelFile, err);
    auto a = loadAnimationFile(assets.animations, fixtures ~ clipA, err);
    auto b = loadAnimationFile(assets.animations, fixtures ~ clipB, err);
    if (sk.isNull || a.isNull || b.isNull) {
        writeln("failed to load assets: ", err);
        assert(false);
    }
    immutable joints = assets.skeletons.get(sk).numJoints;
    immutable dur = assets.animations.get(a).duration;

    foreach (i; 0 .. characters) {
        immutable e = world.spawn();
        world.set(e, AnimSkeleton(sk, pool.acquire(joints)));
        world.set(e, AnimBlend2(a, b, (i % 10) / 10.0f, dur * i / characters, dur * (characters - i) / characters, 1.0f));
        if (i % 8 == 0)
            world.set(e, AnimLookAt(joints / 2, Vec3(1, 2, 3), 1.0f, Vec3(0, 0, 1), Vec3(0, 1, 0)));
    }

    long tAdvance, tSample, tBlend, tL2M, tLook, tPalette;
    void frame(bool timed) {
        enum dt = 1.0f / 60;
        StopWatch sw;
        void lap(ref long acc) { if (timed) { acc += sw.peek.total!"usecs"; sw.reset(); } }
        sw = StopWatch(AutoStart.yes);
        advancePlaybackSystem(world, assets, dt); lap(tAdvance);
        sampleSystem(world, assets, pool); lap(tSample);
        blendSystem(world, assets, pool); lap(tBlend);
        localToModelSystem(world, assets, pool); lap(tL2M);
        lookAtSystem(world, assets, pool); lap(tLook);
        skinPaletteSystem(world, assets, pool); lap(tPalette);
    }

    foreach (_; 0 .. 5) frame(false); // warm-up
    size_t before;
    if (assertNoGc) before = GC.stats().usedSize;
    foreach (_; 0 .. frames) frame(true);

    writefln("skeleton=%s joints=%d characters=%d frames=%d", skelName, joints, characters, frames);
    void report(string name, long us) {
        writefln("  %-10s %8.1f us/frame  %6.2f us/character", name, cast(double) us / frames,
                 cast(double) us / frames / characters);
    }
    report("advance", tAdvance); report("sample", tSample); report("blend", tBlend);
    report("local2model", tL2M); report("lookat", tLook); report("palette", tPalette);
    immutable total = tAdvance + tSample + tBlend + tL2M + tLook + tPalette;
    writefln("  %-10s %8.1f us/frame", "total", cast(double) total / frames);

    if (assertNoGc) {
        immutable delta = GC.stats().usedSize - before;
        writefln("GC allocations over %u frames: %u bytes", frames, delta);
        assert(delta == 0, "GC allocations detected in animation frame path!");
    }
}
