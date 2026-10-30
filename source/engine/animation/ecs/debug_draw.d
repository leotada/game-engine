/// Skeleton visualisation through any line sink (the engine's `GizmoRenderer`, or a test sink).
module engine.animation.ecs.debug_draw;

import engine.animation.math.matrix : translationOf, transformVector;
import engine.animation.math.simd;
import engine.animation.skeleton;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;

@safe:

/// Draws bone lines (parent to child) and a small axis triad on each joint. `Sink` needs
/// `line(Vec3, Vec3, Color4)`.
void drawSkeleton(Sink)(ref Sink sink, ref const Skeleton skeleton, const(Float4x4)[] model,
                        float axisScale = 0.05f,
                        Color4 boneColor = Color4(1, 0.85f, 0.2f, 1)) {
    foreach (i; 0 .. skeleton.numJoints) {
        immutable p = translationOf(model[i]);
        immutable parent = skeleton.parents[i];
        if (parent != kNoParent) sink.line(translationOf(model[parent]), p, boneColor);
        immutable x = transformVector(model[i], Vec3(axisScale, 0, 0));
        immutable y = transformVector(model[i], Vec3(0, axisScale, 0));
        immutable z = transformVector(model[i], Vec3(0, 0, axisScale));
        sink.line(p, Vec3(p.x + x.x, p.y + x.y, p.z + x.z), Color4(1, 0.2f, 0.2f, 1));
        sink.line(p, Vec3(p.x + y.x, p.y + y.y, p.z + y.z), Color4(0.2f, 1, 0.2f, 1));
        sink.line(p, Vec3(p.x + z.x, p.y + z.y, p.z + z.z), Color4(0.2f, 0.4f, 1, 1));
    }
}

unittest {
    import engine.animation.io.archive : InputArchive;
    import engine.animation.local_to_model;
    import engine.animation.testing : loadFixture;
    struct CountSink {
        int lines;
        void line(Vec3, Vec3, Color4) { ++lines; }
    }
    auto ar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton s;
    assert(loadSkeleton(ar, s));
    auto model = new Float4x4[s.numJoints];
    LocalToModelJob j;
    j.skeleton = &s;
    j.input = s.restPoses;
    j.output = model;
    assert(j.run());
    CountSink sink;
    drawSkeleton(sink, s, model);
    // One bone per non-root joint plus 3 axes per joint.
    int roots = 0;
    foreach (p; s.parents) if (p == kNoParent) ++roots;
    assert(sink.lines == (s.numJoints - roots) + 3 * s.numJoints);
}
