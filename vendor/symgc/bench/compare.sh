#!/bin/bash
# Build a benchmark once and run it under three collectors, printing its statistics line and the peak memory.
#
#   bench/compare.sh PROGRAM.d [ARGS...]
#
#   bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256     # a shooter with a lot of garbage
#   bench/compare.sh aaa_sim.d city 60 2048 6 0 500000                # a city builder, six job threads
#   bench/compare.sh entity_init.d 30 1024 20000 2000 60              # a scene of 10 million linked entities
#
# Runs: druntime's GC; steadygc with a stop-the-world mark; steadygc with the concurrent mark. A frame-based program
# prints frame_p50_us=... p99=... p999=... max=... over16ms=...: compare "max" first, it is the frame that was
# missed. Environment: DC, SYMGC, EXTRA as for build.sh; WORK is the directory for the binary.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
prog=$1; shift
WORK=${WORK:-$(mktemp -d)}
bin=$WORK/$(basename "${prog%.d}")

"$HERE/build.sh" "$prog" "$bin" >/dev/null

run() {
	local label=$1; shift
	local err; err=$(mktemp)
	local line
	line=$( { /usr/bin/time -f "peak_rss_mb=%M" "$@" 2>"$err" ; } | grep -E "frame_p50|RESULT|OK|ok" | tail -1 || true)
	local rss; rss=$(grep -o 'peak_rss_mb=[0-9]*' "$err" | tail -1 | cut -d= -f2)
	printf '%-28s %s  peak_rss=%s MB\n' "$label" "$line" "$((${rss:-0} / 1024))"
	rm -f "$err"
}

run "druntime GC"        "$bin" "$@"
run "steadygc, STW mark"   env SYMGC_CONCURRENT_MARK=0 "$bin" "$@" --DRT-gcopt=gc:sdcq
run "steadygc, concurrent" "$bin" "$@" --DRT-gcopt=gc:sdcq
