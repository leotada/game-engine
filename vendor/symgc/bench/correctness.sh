#!/bin/bash
# Build and run the correctness battery against steadygc (the setup without a card barrier).
#
#   bench/correctness.sh [SECONDS=20]
#
# Environment: DC, SYMGC, EXTRA as for build.sh. Exit status is 0 only if every test prints its OK line.
# The tests that need the card barrier (cards_window.d, cards_precision.d) are described in ../guide/testing.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
secs=${1:-20}
WORK=${WORK:-$(mktemp -d)}
fail=0

check() {
	local name=$1; shift
	"$HERE/build.sh" "$name.d" "$WORK/$name" >/dev/null 2>"$WORK/$name.build" || {
		echo "FAIL  $name: does not build (see $WORK/$name.build)"; fail=1; return; }
	local out
	out=$(timeout 600 "$WORK/$name" "$@" --DRT-gcopt=gc:sdcq 2>&1); local rc=$?
	if [ $rc -eq 0 ] && echo "$out" | grep -q " OK"; then
		echo "ok    $name: $(echo "$out" | tail -1 | cut -c1-110)"
	else
		echo "FAIL  $name (exit $rc): $(echo "$out" | tail -3 | cut -c1-110)"; fail=1
	fi
}

check mark_race "$secs"
check mark_race_glue "$secs"
check finalizer_order "$secs"
check thread_exit_race

exit $fail
