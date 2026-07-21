#pragma once

// Must match the libbox3d.a build configuration.
// Default integration: single precision, SIMD enabled, Release assertions off.
#define _Float128 long double
#define NDEBUG 1

#pragma attribute(push, nogc, nothrow)
#include <stdint.h>
#include <stdbool.h>
#include <box3d/box3d.h>
#pragma attribute(pop)
