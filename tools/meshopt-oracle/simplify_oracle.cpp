// Oracle for the simplifier golden. Not part of the engine link.
// clang++ -O2 -ffp-contract=off -Iref/meshoptimizer/src tools/meshopt-oracle/simplify_oracle.cpp -Llibs -lmeshoptimizer_ref -lstdc++ -o /tmp/simplify_oracle
#include "meshoptimizer.h"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

static void writeU32(FILE* f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void writeF32(FILE* f, float v) { fwrite(&v, 4, 1, f); }

static void emit(FILE* f, const char* name, const std::vector<unsigned>& idx, float error) {
    writeU32(f, (uint32_t)std::strlen(name));
    fwrite(name, 1, std::strlen(name), f);
    writeU32(f, (uint32_t)idx.size());
    writeF32(f, error);
    if (!idx.empty())
        fwrite(idx.data(), 4, idx.size(), f);
}

int main() {
    const int n = 8;
    const int vc = (n + 1) * (n + 1);
    std::vector<float> pos(vc * 3), attr(vc * 5);
    std::vector<unsigned> idx(n * n * 6);
    for (int z = 0; z <= n; ++z)
        for (int x = 0; x <= n; ++x) {
            int i = z * (n + 1) + x;
            pos[i * 3 + 0] = (float)x;
            pos[i * 3 + 1] = 0;
            pos[i * 3 + 2] = (float)z;
            attr[i * 5 + 0] = 0;
            attr[i * 5 + 1] = 1;
            attr[i * 5 + 2] = 0;
            attr[i * 5 + 3] = (float)x / n;
            attr[i * 5 + 4] = (float)z / n;
        }
    size_t t = 0;
    for (int z = 0; z < n; ++z)
        for (int x = 0; x < n; ++x) {
            unsigned a = (unsigned)(z * (n + 1) + x);
            unsigned b = a + 1, c = a + n + 1, d = c + 1;
            idx[t++] = a; idx[t++] = c; idx[t++] = b;
            idx[t++] = b; idx[t++] = c; idx[t++] = d;
        }
    float w[5] = {0.5f, 0.5f, 0.5f, 0.25f, 0.25f};
    FILE* f = fopen("tests/meshopt/golden/simplify.bin", "wb");
    if (!f) return 1;
    fwrite("MOPTGLD1", 1, 8, f);
    writeU32(f, 1030);
    writeU32(f, 6);

    auto run = [&](const char* name, size_t target, float terr, unsigned opt, bool attrs) {
        std::vector<unsigned> dst = idx;
        float error = -1;
        size_t nidx;
        if (attrs)
            nidx = meshopt_simplifyWithAttributes(dst.data(), idx.data(), idx.size(), pos.data(), vc, 12, attr.data(), 20, w, 5, nullptr, target, terr, opt, &error);
        else
            nidx = meshopt_simplify(dst.data(), idx.data(), idx.size(), pos.data(), vc, 12, target, terr, opt, &error);
        dst.resize(nidx);
        emit(f, name, dst, error);
        std::printf("%s %zu err %g\n", name, nidx, error);
    };
    run("simplify", idx.size() / 2, 0.05f, 0, false);
    run("lockBorder", idx.size() / 4, 0.05f, meshopt_SimplifyLockBorder, false);
    run("attributes", idx.size() / 2, 0.05f, 0, true);
    std::vector<unsigned> sloppy = idx;
    float se = 0;
    size_t sn = meshopt_simplifySloppy(sloppy.data(), idx.data(), idx.size(), pos.data(), vc, 12, nullptr, idx.size() / 4, 0.05f, &se);
    sloppy.resize(sn);
    emit(f, "sloppy", sloppy, se);
    std::printf("sloppy %zu err %g\n", sn, se);
    std::vector<unsigned> pruned = idx;
    size_t pn = meshopt_simplifyPrune(pruned.data(), idx.data(), idx.size(), pos.data(), vc, 12, 0.02f);
    pruned.resize(pn);
    emit(f, "prune", pruned, 0);
    std::printf("prune %zu\n", pn);
    float scale = meshopt_simplifyScale(pos.data(), vc, 12);
    emit(f, "scale", {}, scale);
    std::printf("scale %g\n", scale);
    fclose(f);
    return 0;
}
