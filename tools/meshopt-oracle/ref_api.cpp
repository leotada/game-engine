// Exports the header-only quantize helpers. The rest of the C API is already extern "C".
#include "meshoptimizer.h"

extern "C" int meshopt_ref_quantizeUnorm(float v, int N)
{
	return meshopt_quantizeUnorm(v, N);
}

extern "C" int meshopt_ref_quantizeSnorm(float v, int N)
{
	return meshopt_quantizeSnorm(v, N);
}
