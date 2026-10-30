// Golden-output generator for the D port of the ozz-animation runtime.
// Links against upstream ozz-animation (pinned at 744eb9d). Not built by dub. See README.md.
//
//   golden <ozz-media-dir> <output-dir>
//
// Output files are raw little-endian float32 arrays, read by `engine.animation.golden_tests`.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "ozz/animation/runtime/animation.h"
#include "ozz/animation/runtime/blending_job.h"
#include "ozz/animation/runtime/ik_aim_job.h"
#include "ozz/animation/runtime/ik_two_bone_job.h"
#include "ozz/animation/runtime/local_to_model_job.h"
#include "ozz/animation/runtime/sampling_job.h"
#include "ozz/animation/runtime/motion_blending_job.h"
#include "ozz/animation/runtime/skeleton.h"
#include "ozz/animation/runtime/track.h"
#include "ozz/animation/runtime/track_sampling_job.h"
#include "ozz/animation/runtime/track_triggering_job.h"
#include "ozz/base/maths/transform.h"
#include "ozz/geometry/runtime/skinning_job.h"
#include "ozz/base/io/archive.h"
#include "ozz/base/maths/simd_math.h"
#include "ozz/base/maths/simd_quaternion.h"
#include "ozz/base/maths/soa_transform.h"
#include "ozz/base/memory/unique_ptr.h"

using namespace ozz;

static std::string g_in, g_out;

static bool LoadSkeleton(const std::string& n, animation::Skeleton* s) {
  io::File f((g_in + "/" + n).c_str(), "rb");
  if (!f.opened()) { std::fprintf(stderr, "cannot open %s\n", n.c_str()); return false; }
  io::IArchive a(&f);
  a >> *s;
  return true;
}
static bool LoadAnimation(const std::string& n, animation::Animation* s) {
  io::File f((g_in + "/" + n).c_str(), "rb");
  if (!f.opened()) { std::fprintf(stderr, "cannot open %s\n", n.c_str()); return false; }
  io::IArchive a(&f);
  a >> *s;
  return true;
}

static void Dump(const std::string& name, const std::vector<float>& v) {
  std::FILE* f = std::fopen((g_out + "/" + name).c_str(), "wb");
  std::fwrite(v.data(), sizeof(float), v.size(), f);
  std::fclose(f);
}

static void Append(std::vector<float>& out, const math::SoaTransform* t, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    const math::SimdFloat4 v[10] = {t[i].translation.x, t[i].translation.y, t[i].translation.z,
                                    t[i].rotation.x, t[i].rotation.y, t[i].rotation.z, t[i].rotation.w,
                                    t[i].scale.x, t[i].scale.y, t[i].scale.z};
    for (const auto& c : v) {
      float f[4];
      math::StorePtrU(c, f);
      out.insert(out.end(), f, f + 4);
    }
  }
}

// Same sequence in the D test: forward sweep, seeks, backward sweep, ends.
static std::vector<float> Ratios() {
  std::vector<float> r;
  for (int i = 0; i <= 24; ++i) r.push_back(i / 24.f);       // 25 forward
  for (float v : {0.9f, 0.1f, 0.5f, 0.0f, 1.0f, 0.33f, 0.77f, 0.02f}) r.push_back(v);  // jumps
  for (int i = 20; i >= 0; --i) r.push_back(i / 20.f);       // 21 backward
  for (float v : {0.001f, 0.999f, 0.5f, 0.25f, 0.75f, 0.6f, 0.4f, 0.123f, 0.456f}) r.push_back(v);
  return r;
}

static void Sampling(const char* tag, const char* skel, const char* anim, size_t maxRatios = 1000) {
  animation::Skeleton s; animation::Animation a;
  if (!LoadSkeleton(skel, &s) || !LoadAnimation(anim, &a)) return;
  animation::SamplingJob::Context ctx(s.num_joints());
  std::vector<math::SoaTransform> out(s.num_soa_joints());
  std::vector<float> dump;
  size_t count = 0;
  for (float r : Ratios()) {
    if (count++ >= maxRatios) break;
    animation::SamplingJob j;
    j.animation = &a; j.context = &ctx; j.ratio = r; j.output = make_span(out);
    if (!j.Run()) std::fprintf(stderr, "sampling failed\n");
    Append(dump, out.data(), out.size());
  }
  Dump(std::string("sampling_") + tag + ".bin", dump);
}

static void BlendAndModel() {
  animation::Skeleton s; animation::Animation walk, jog;
  if (!LoadSkeleton("pab/skeleton.ozz", &s) || !LoadAnimation("pab/walk.ozz", &walk) ||
      !LoadAnimation("pab/jog.ozz", &jog)) return;
  animation::SamplingJob::Context c0(s.num_joints()), c1(s.num_joints());
  std::vector<math::SoaTransform> l0(s.num_soa_joints()), l1(s.num_soa_joints()), blended(s.num_soa_joints());
  std::vector<math::Float4x4> model(s.num_joints());
  std::vector<float> bl, md;
  for (float w : {0.f, 0.3f, 0.5f, 0.8f, 1.f}) {
    animation::SamplingJob a; a.animation = &walk; a.context = &c0; a.ratio = 0.37f; a.output = make_span(l0); a.Run();
    animation::SamplingJob b; b.animation = &jog; b.context = &c1; b.ratio = 0.62f; b.output = make_span(l1); b.Run();
    animation::BlendingJob::Layer layers[2];
    layers[0].transform = make_span(l0); layers[0].weight = 1.f - w;
    layers[1].transform = make_span(l1); layers[1].weight = w;
    animation::BlendingJob job;
    job.layers = layers; job.rest_pose = s.joint_rest_poses(); job.output = make_span(blended);
    if (!job.Run()) std::fprintf(stderr, "blending failed\n");
    Append(bl, blended.data(), blended.size());
    animation::LocalToModelJob l2m;
    l2m.skeleton = &s; l2m.input = make_span(blended); l2m.output = make_span(model);
    if (!l2m.Run()) std::fprintf(stderr, "l2m failed\n");
    for (const auto& m : model)
      for (int c = 0; c < 4; ++c) { float f[4]; math::StorePtrU(m.cols[c], f); md.insert(md.end(), f, f + 4); }
  }
  Dump("blend_pab.bin", bl);
  Dump("model_pab.bin", md);
}


template <typename T>
static bool LoadObject(const std::string& n, T* o) {
  io::File f((g_in + "/" + n).c_str(), "rb");
  if (!f.opened()) { std::fprintf(stderr, "cannot open %s\n", n.c_str()); return false; }
  io::IArchive a(&f);
  a >> *o;
  return true;
}

static void Tracks() {
  animation::Float3Track t3;
  if (LoadObject("pab/walk_motion_track.ozz", &t3)) {
    std::vector<float> out;
    for (int i = 0; i <= 40; ++i) {
      animation::Float3TrackSamplingJob j;
      math::Float3 r;
      j.track = &t3; j.result = &r; j.ratio = i / 40.f;
      j.Run();
      out.push_back(r.x); out.push_back(r.y); out.push_back(r.z);
    }
    Dump("track_float3_walk.bin", out);
  }
  animation::FloatTrack tf;
  if (LoadObject("robot_track_grasp.ozz", &tf)) {
    std::vector<float> out;
    for (int i = 0; i <= 40; ++i) {
      animation::FloatTrackSamplingJob j;
      float r = 0;
      j.track = &tf; j.result = &r; j.ratio = i / 40.f;
      j.Run();
      out.push_back(r);
    }
    Dump("track_float_grasp.bin", out);

    // Triggering: [from, to, threshold, n, (ratio, rising) * n] per range.
    std::vector<float> trig;
    const float ranges[][3] = {{0.f, 1.f, 0.5f}, {1.f, 0.f, 0.5f}, {0.1f, 0.9f, 0.2f}, {0.3f, 2.4f, 0.5f},
                               {2.4f, 0.3f, 0.5f}, {0.f, 1.f, 0.f}, {0.5f, 0.5f, 0.5f}, {0.f, 3.f, 0.8f}};
    for (const auto& r : ranges) {
      animation::TrackTriggeringJob job;
      animation::TrackTriggeringJob::Iterator it;
      job.track = &tf; job.from = r[0]; job.to = r[1]; job.threshold = r[2]; job.iterator = &it;
      job.Run();
      std::vector<float> edges;
      for (auto& i = it; i != job.end(); ++i) {
        edges.push_back(i->ratio); edges.push_back(i->rising ? 1.f : 0.f);
      }
      trig.insert(trig.end(), {r[0], r[1], r[2], float(edges.size() / 2)});
      trig.insert(trig.end(), edges.begin(), edges.end());
    }
    Dump("trigger_grasp.bin", trig);
  }
}

static void Motion() {
  std::vector<float> out;
  struct Case { float w[3]; math::Transform d[3]; };
  auto T = [](float x, float y, float z, float qx, float qy, float qz, float qw) {
    math::Transform t = math::Transform::identity();
    t.translation = math::Float3(x, y, z);
    t.rotation = math::Quaternion(qx, qy, qz, qw);
    return t;
  };
  const float s = 0.70710678f;
  Case cases[] = {
      {{1.f, 0.f, 0.f}, {T(1, 2, 3, 0, 0, 0, 1), T(0, 0, 0, 0, 0, 0, 1), T(0, 0, 0, 0, 0, 0, 1)}},
      {{0.5f, 0.5f, 0.f}, {T(1, 0, 0, 0, 0, 0, 1), T(0, 0, 2, 0, s, 0, s), T(0, 0, 0, 0, 0, 0, 1)}},
      {{0.2f, 0.3f, 0.5f}, {T(1, 2, 3, 0, 0, s, s), T(-1, 0.5f, 2, 0, 0, -s, -s), T(0.3f, 0.2f, 0.1f, s, 0, 0, s)}},
      {{0.f, 0.f, 0.f}, {T(1, 0, 0, 0, 0, 0, 1), T(1, 0, 0, 0, 0, 0, 1), T(1, 0, 0, 0, 0, 0, 1)}},
  };
  for (auto& c : cases) {
    animation::MotionBlendingJob::Layer layers[3];
    for (int i = 0; i < 3; ++i) { layers[i].weight = c.w[i]; layers[i].delta = &c.d[i]; }
    math::Transform o;
    animation::MotionBlendingJob job;
    job.layers = layers; job.output = &o;
    job.Run();
    for (int i = 0; i < 3; ++i) {
      out.push_back(c.w[i]);
      out.insert(out.end(), {c.d[i].translation.x, c.d[i].translation.y, c.d[i].translation.z,
                             c.d[i].rotation.x, c.d[i].rotation.y, c.d[i].rotation.z, c.d[i].rotation.w});
    }
    out.insert(out.end(), {o.translation.x, o.translation.y, o.translation.z, o.rotation.x, o.rotation.y,
                           o.rotation.z, o.rotation.w});
  }
  Dump("motion.bin", out);
}

// Deterministic pseudo-random in [-1, 1).
static float Rnd(unsigned& s) { s = s * 1664525u + 1013904223u; return ((s >> 8) & 0xffff) / 32768.f - 1.f; }

static void Skinning() {
  const int kJoints = 8, kVerts = 64, kInf = 4;
  unsigned seed = 12345;
  std::vector<math::Float4x4> m(kJoints), it(kJoints);
  for (int j = 0; j < kJoints; ++j) {
    const float a = Rnd(seed) * 3.f, b = Rnd(seed) * 3.f;
    const math::SimdFloat4 axis = math::simd_float4::Load(Rnd(seed), Rnd(seed) + 2.f, Rnd(seed), 0.f);
    m[j] = math::Float4x4::FromAxisAngle(math::Normalize3(axis), math::simd_float4::Load1(a)) *
           math::Float4x4::Scaling(math::simd_float4::Load(1.f + 0.2f * b, 1.f, 1.f - 0.1f * b, 0.f));
    m[j].cols[3] = math::simd_float4::Load(Rnd(seed), Rnd(seed), Rnd(seed), 1.f);
    it[j] = Transpose(Invert(m[j]));
  }
  std::vector<float> pos(kVerts * 3), nrm(kVerts * 3), tan(kVerts * 3), w(kVerts * (kInf - 1));
  std::vector<uint16_t> idx(kVerts * kInf);
  for (auto& v : pos) v = Rnd(seed) * 2.f;
  for (int i = 0; i < kVerts; ++i) {
    float n[3] = {Rnd(seed), Rnd(seed), Rnd(seed) + 1.5f};
    const float l = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    for (int k = 0; k < 3; ++k) { nrm[i * 3 + k] = n[k] / l; tan[i * 3 + k] = Rnd(seed); }
    float rest = 1.f;
    for (int k = 0; k < kInf - 1; ++k) { const float x = (Rnd(seed) * 0.5f + 0.5f) * rest * 0.8f; w[i * (kInf - 1) + k] = x; rest -= x; }
    for (int k = 0; k < kInf; ++k) idx[i * kInf + k] = uint16_t((i + k * 3) % kJoints);
  }
  std::vector<float> op(kVerts * 3), on(kVerts * 3), ot(kVerts * 3);
  {
    geometry::SkinningJob job;
    job.vertex_count = kVerts; job.influences_count = kInf;
    job.joint_matrices = make_span(m); job.joint_inverse_transpose_matrices = make_span(it);
    job.joint_indices = make_span(idx); job.joint_indices_stride = sizeof(uint16_t) * kInf;
    job.joint_weights = make_span(w); job.joint_weights_stride = sizeof(float) * (kInf - 1);
    job.in_positions = make_span(pos); job.in_positions_stride = sizeof(float) * 3;
    job.in_normals = make_span(nrm); job.in_normals_stride = sizeof(float) * 3;
    job.in_tangents = make_span(tan); job.in_tangents_stride = sizeof(float) * 3;
    job.out_positions = make_span(op); job.out_positions_stride = sizeof(float) * 3;
    job.out_normals = make_span(on); job.out_normals_stride = sizeof(float) * 3;
    job.out_tangents = make_span(ot); job.out_tangents_stride = sizeof(float) * 3;
    if (!job.Run()) std::fprintf(stderr, "skinning failed\n");
  }
  // Layout: matrices, inverse transposes (16 floats each), positions, normals, tangents,
  // indices (as floats), weights (3 per vertex), out positions, out normals, out tangents.
  std::vector<float> out;
  for (int pass = 0; pass < 2; ++pass)
    for (int j = 0; j < kJoints; ++j)
      for (int c = 0; c < 4; ++c) { float f[4]; math::StorePtrU((pass ? it[j] : m[j]).cols[c], f); out.insert(out.end(), f, f + 4); }
  out.insert(out.end(), pos.begin(), pos.end());
  out.insert(out.end(), nrm.begin(), nrm.end());
  out.insert(out.end(), tan.begin(), tan.end());
  for (auto i : idx) out.push_back(float(i));
  out.insert(out.end(), w.begin(), w.end());
  out.insert(out.end(), op.begin(), op.end());
  out.insert(out.end(), on.begin(), on.end());
  out.insert(out.end(), ot.begin(), ot.end());
  Dump("skinning.bin", out);
}

static math::Float4x4 Translate(float x, float y, float z) {
  math::Float4x4 m = math::Float4x4::identity();
  m.cols[3] = math::simd_float4::Load(x, y, z, 1.f);
  return m;
}

static void Ik() {
  std::vector<float> out;
  const math::Float4x4 start = Translate(0, 0, 0), mid = Translate(0.3f, 1, 0), end = Translate(0, 2, 0);
  const float targets[][3] = {{0.5f, 1.2f, 0.3f}, {0.f, 3.f, 0.f}, {1.f, 0.5f, -0.4f}};
  for (const auto& t : targets) {
    math::SimdQuaternion qs, qm; bool reached = false;
    animation::IKTwoBoneJob job;
    job.target = math::simd_float4::Load(t[0], t[1], t[2], 0.f);
    job.pole_vector = math::simd_float4::y_axis();
    job.mid_axis = math::simd_float4::z_axis();
    job.start_joint = &start; job.mid_joint = &mid; job.end_joint = &end;
    job.start_joint_correction = &qs; job.mid_joint_correction = &qm; job.reached = &reached;
    job.Run();
    float f[4];
    math::StorePtrU(qs.xyzw, f); out.insert(out.end(), f, f + 4);
    math::StorePtrU(qm.xyzw, f); out.insert(out.end(), f, f + 4);
    out.push_back(reached ? 1.f : 0.f);
  }
  const math::Float4x4 joint = Translate(0, 0, 0);
  const float aims[][3] = {{1.f, 2.f, 3.f}, {-2.f, 0.5f, 1.f}};
  for (const auto& t : aims) {
    math::SimdQuaternion q; bool reached = false;
    animation::IKAimJob job;
    job.target = math::simd_float4::Load(t[0], t[1], t[2], 0.f);
    job.forward = math::simd_float4::z_axis();
    job.up = math::simd_float4::y_axis();
    job.pole_vector = math::simd_float4::y_axis();
    job.joint = &joint; job.joint_correction = &q; job.reached = &reached;
    job.Run();
    float f[4];
    math::StorePtrU(q.xyzw, f); out.insert(out.end(), f, f + 4);
    out.push_back(reached ? 1.f : 0.f);
  }
  Dump("ik.bin", out);
}

// Same scenario as `dub run --config=anim`'s pab case, single thread: ns per character per stage.
static void Bench(const char* tag, const char* skel, const char* a0, const char* a1, int n, int frames) {
  animation::Skeleton s; animation::Animation A, B;
  if (!LoadSkeleton(skel, &s) || !LoadAnimation(a0, &A) || !LoadAnimation(a1, &B)) return;
  struct C {
    animation::SamplingJob::Context c0, c1;
    std::vector<math::SoaTransform> l0, l1, bl;
    std::vector<math::Float4x4> model;
  };
  std::vector<C> cs(n);
  for (auto& c : cs) {
    c.c0.Resize(s.num_joints()); c.c1.Resize(s.num_joints());
    c.l0.resize(s.num_soa_joints()); c.l1 = c.l0; c.bl = c.l0; c.model.resize(s.num_joints());
  }
  double ts = 0, tb = 0, tl = 0;
  using clk = std::chrono::steady_clock;
  for (int f = 0; f < frames + 5; ++f) {
    const bool timed = f >= 5;
    auto t0 = clk::now();
    for (int i = 0; i < n; ++i) {
      float ra = std::fmod(float(i) / n + f / 60.f / A.duration(), 1.f), rb = std::fmod(float(n - i) / n + f / 60.f / B.duration(), 1.f);
      animation::SamplingJob a; a.animation = &A; a.context = &cs[i].c0; a.ratio = ra; a.output = make_span(cs[i].l0); a.Run();
      animation::SamplingJob b; b.animation = &B; b.context = &cs[i].c1; b.ratio = rb; b.output = make_span(cs[i].l1); b.Run();
    }
    auto t1 = clk::now();
    for (int i = 0; i < n; ++i) {
      animation::BlendingJob::Layer layers[2];
      layers[0].transform = make_span(cs[i].l0); layers[0].weight = 0.5f;
      layers[1].transform = make_span(cs[i].l1); layers[1].weight = 0.5f;
      animation::BlendingJob job; job.layers = layers; job.rest_pose = s.joint_rest_poses(); job.output = make_span(cs[i].bl); job.Run();
    }
    auto t2 = clk::now();
    for (int i = 0; i < n; ++i) {
      animation::LocalToModelJob j; j.skeleton = &s; j.input = make_span(cs[i].bl); j.output = make_span(cs[i].model); j.Run();
    }
    auto t3 = clk::now();
    if (timed) {
      ts += std::chrono::duration<double, std::micro>(t1 - t0).count();
      tb += std::chrono::duration<double, std::micro>(t2 - t1).count();
      tl += std::chrono::duration<double, std::micro>(t3 - t2).count();
    }
  }
  std::printf("%s joints=%d characters=%d: sample %.2f  blend %.2f  local2model %.2f  (us/character)\n", tag,
              s.num_joints(), n, ts / frames / n, tb / frames / n, tl / frames / n);
}

int main(int argc, char** argv) {
  if (argc < 3) { std::fprintf(stderr, "usage: golden <media-dir> <out-dir>\n"); return 1; }
  g_in = argv[1]; g_out = argv[2];
  Sampling("pab_walk", "pab/skeleton.ozz", "pab/walk.ozz");
  Sampling("pab_jog", "pab/skeleton.ozz", "pab/jog.ozz");
  Sampling("ruby", "ruby_skeleton.ozz", "ruby_animation.ozz", 12);  // 368 joints: keep the fixture small
  BlendAndModel();
  Ik();
  Tracks();
  Motion();
  Skinning();
  if (argc > 3 && std::strcmp(argv[3], "--bench") == 0) {
    Bench("pab", "pab/skeleton.ozz", "pab/walk.ozz", "pab/jog.ozz", 1000, 300);
    Bench("ruby", "ruby_skeleton.ozz", "ruby_animation.ozz", "ruby_animation.ozz", 1000, 100);
  }
  return 0;
}
