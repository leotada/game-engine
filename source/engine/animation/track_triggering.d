// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/track_triggering_job.cc @ 744eb9d
/// Detects when a float track crosses a threshold between two ratios (events from a track).
/// Supports backward playback (`from > to`) and spans over several loops.
module engine.animation.track_triggering;

import engine.animation.track;
import std.math : floor;

@safe:

struct Edge {
    /// Position of the crossing in global ratio space (loop index + ratio).
    float ratio = 0;
    /// True for a rising edge in playback direction.
    bool rising;
}

/// Input range over the edges found between `from` and `to`.
struct EdgeRange {
    private TrackTriggeringJob job_; // copy: only holds a pointer to the track
    private bool done_ = true;
    private float outer_ = 0;
    private ptrdiff_t inner_ = 0;
    private Edge edge_;

    bool empty() const pure nothrow @nogc { return done_; }
    Edge front() const pure nothrow @nogc { return edge_; }
    void popFront() pure nothrow @nogc @trusted { advance(); }

    private this(TrackTriggeringJob job) pure nothrow @nogc @trusted {
        job_ = job;
        done_ = false;
        outer_ = floor(job.from);
        // Search starts from the track boundary: filtering by [from, to) below keeps forward and
        // backward triggering consistent despite float precision.
        inner_ = job.from < job.to ? 0 : cast(ptrdiff_t) job.track.ratios.length - 1;
        advance();
    }

    private void advance() pure nothrow @nogc @trusted {
        const ratios = job_.track.ratios;
        immutable numKeys = cast(ptrdiff_t) ratios.length;
        immutable from = job_.from, to = job_.to;
        if (to > from) {
            for (; outer_ < to; outer_ += 1.0f) {
                for (; inner_ < numKeys; ++inner_) {
                    immutable i0 = inner_ == 0 ? numKeys - 1 : inner_ - 1;
                    if (detectEdge(i0, inner_, true, job_, edge_)) {
                        edge_.ratio += outer_;
                        if (edge_.ratio >= from && (edge_.ratio < to || to >= 1.0f + outer_)) {
                            ++inner_;
                            return;
                        }
                        if (ratios[inner_] + outer_ >= to) break;
                    }
                }
                inner_ = 0;
            }
        } else {
            for (; outer_ + 1.0f > to; outer_ -= 1.0f) {
                for (; inner_ >= 0; --inner_) {
                    immutable i0 = inner_ == 0 ? numKeys - 1 : inner_ - 1;
                    if (detectEdge(i0, inner_, false, job_, edge_)) {
                        edge_.ratio += outer_;
                        if (edge_.ratio >= to && (edge_.ratio < from || from >= 1.0f + outer_)) {
                            --inner_;
                            return;
                        }
                    }
                    if (ratios[inner_] + outer_ <= to) break;
                }
                inner_ = numKeys - 1;
            }
        }
        done_ = true;
    }
}

private bool detectEdge(ptrdiff_t i0, ptrdiff_t i1, bool forward, ref const TrackTriggeringJob job,
                        ref Edge edge) pure nothrow @nogc {
    const values = job.track.values;
    immutable vk0 = values[i0];
    immutable vk1 = values[i1];
    bool detected = false;
    if (vk0 <= job.threshold && vk1 > job.threshold) {
        edge.rising = forward;
        detected = true;
    } else if (vk0 > job.threshold && vk1 <= job.threshold) {
        edge.rising = !forward;
        detected = true;
    }
    if (detected) {
        const ratios = job.track.ratios;
        if (job.track.isStep(i0)) {
            edge.ratio = ratios[i1];
        } else if (i1 == 0) {
            edge.ratio = 0.0f;
        } else {
            // Un-lerp: where does the segment cross the threshold?
            immutable alpha = (job.threshold - vk0) / (vk1 - vk0);
            edge.ratio = (ratios[i1] - ratios[i0]) * alpha + ratios[i0];
        }
    }
    return detected;
}

struct TrackTriggeringJob {
    /// Ratio range to scan (can be outside [0, 1] and can span several loops).
    float from = 0, to = 0;
    /// Value crossing this threshold generates an edge.
    float threshold = 1.0f;
    const(FloatTrack)* track;

    bool validate() const scope pure nothrow @nogc { return track !is null; }

    /// Edges in playback order. Empty if `from == to`. The job must outlive the range.
    EdgeRange edges() const scope pure nothrow @nogc @trusted {
        if (from == to || track is null) return EdgeRange.init;
        // The range borrows `track`, which outlives the job by contract; launder the pointer so
        // DIP1000 does not tie the range to the (possibly stack-allocated) job itself.
        TrackTriggeringJob copy = this;
        copy.track = cast(const(FloatTrack)*) cast(size_t) track;
        return EdgeRange(copy);
    }
}

version (unittest) {
    private Edge[] collect(scope ref const TrackTriggeringJob job) {
        Edge[] r;
        foreach (e; job.edges) r ~= e;
        return r;
    }
    // Square wave: 0 until 0.25, 1 until 0.5 (step keys), 0 afterwards.
    private FloatTrack wave() {
        FloatTrack t;
        t.ratios = [0, 0.25f, 0.5f];
        t.values = [0, 1, 0];
        t.steps = [0b111];
        return t;
    }
}

unittest {
    import std.math : abs;
    auto t = wave();
    TrackTriggeringJob j;
    j.track = &t;
    j.threshold = 0.5f;
    // Empty ranges.
    j.from = j.to = 0.3f;
    assert(collect(j).length == 0);
    // Forward over one loop: rising at 0.25, falling at 0.5.
    j.from = 0; j.to = 1;
    auto e = collect(j);
    assert(e.length == 2);
    assert(abs(e[0].ratio - 0.25f) < 1e-6f && e[0].rising);
    assert(abs(e[1].ratio - 0.5f) < 1e-6f && !e[1].rising);
    // Sub range: [from, to).
    j.from = 0.3f; j.to = 0.9f;
    e = collect(j);
    assert(e.length == 1 && !e[0].rising);
    // Three loops forward: 6 edges, globally increasing.
    j.from = 0; j.to = 3;
    e = collect(j);
    assert(e.length == 6);
    foreach (i; 1 .. e.length) assert(e[i].ratio > e[i - 1].ratio);
    // Backward: edges reversed, rising/falling swapped relative to the track.
    j.from = 1; j.to = 0;
    e = collect(j);
    assert(e.length == 2);
    assert(abs(e[0].ratio - 0.5f) < 1e-6f && e[0].rising);
    assert(abs(e[1].ratio - 0.25f) < 1e-6f && !e[1].rising);
    // Forward and backward over the same span find the same crossings.
    j.from = -1.5f; j.to = 2.5f;
    auto fwd = collect(j);
    j.from = 2.5f; j.to = -1.5f;
    auto bwd = collect(j);
    assert(fwd.length == bwd.length && fwd.length == 8);
    foreach (i; 0 .. fwd.length) assert(abs(fwd[i].ratio - bwd[$ - 1 - i].ratio) < 1e-5f);
}

unittest {
    // Linear (non-step) crossing is un-lerped between keys.
    import std.math : abs;
    FloatTrack t;
    t.ratios = [0, 0.5f, 1];
    t.values = [0, 1, 0];
    t.steps = [0];
    TrackTriggeringJob j;
    j.track = &t;
    j.threshold = 0.5f;
    j.from = 0; j.to = 1;
    auto e = collect(j);
    assert(e.length == 2);
    assert(abs(e[0].ratio - 0.25f) < 1e-6f && e[0].rising);
    assert(abs(e[1].ratio - 0.75f) < 1e-6f && !e[1].rising);
    TrackTriggeringJob bad;
    assert(!bad.validate() && bad.edges.empty);
}
