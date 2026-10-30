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
#include "ozz/animation/runtime/skeleton.h"
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
  if (argc > 3 && std::strcmp(argv[3], "--bench") == 0) {
    Bench("pab", "pab/skeleton.ozz", "pab/walk.ozz", "pab/jog.ozz", 1000, 300);
    Bench("ruby", "ruby_skeleton.ozz", "ruby_animation.ozz", "ruby_animation.ozz", 1000, 100);
  }
  return 0;
}
