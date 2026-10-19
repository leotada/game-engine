#!/bin/bash
# Run the paced engine GC benchmark under druntime and steadygc (separate binaries).
#
#   bench/engine_gc_compare.sh [FRAMES=600] [REPEATS=5]
#
# Environment: DC, SYMGC, EXTRA as for engine_gc_build.sh; WORK for binaries.
# Prints median mean/p50/p99/worst/over16ms-sum and /usr/bin/time user/sys/faults/RSS.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FRAMES=${1:-600}
REPEATS=${2:-5}
WORK=${WORK:-$(mktemp -d)}
SCENARIOS=(--worst --openworld --worst-safe)

"$HERE/engine_gc_build.sh" "$WORK"

median() {
	sort -n | awk '{ a[NR]=$1 } END {
		if (NR == 0) { print "nan"; exit }
		if (NR % 2) print a[(NR+1)/2]
		else print a[NR/2]
	}'
}

sum_ints() { awk '{s+=$1} END {print s+0}'; }

echo "engine_gc_compare: frames=$FRAMES repeats=$REPEATS work=$WORK"
echo "uname=$(uname -r) cores=$(nproc) DC=$(basename "${DC:-auto}")"

run_case() {
	# Usage: run_case LABEL SCENARIO -- cmd...
	local label=$1
	local sc=$2
	shift 2
	[ "$1" = -- ] && shift

	local means=() p50s=() p99s=() worsts=() overs=()
	local users=() syss=() flts=() rsss=()

	local i
	for ((i=1; i<=REPEATS; i++)); do
		local err out
		err=$(mktemp)
		out=$(mktemp)
		set +e
		/usr/bin/time -f "TIME user=%U sys=%S minflt=%R rss_kb=%M" \
			"$@" >"$out" 2>"$err"
		local rc=$?
		set -e
		local result time_line
		result=$(grep '^RESULT ' "$out" | tail -1 || true)
		time_line=$(grep '^TIME ' "$err" | tail -1 || true)
		if [ $rc -ne 0 ] || [ -z "$result" ]; then
			echo "FAIL $label $sc run=$i rc=$rc" >&2
			tail -30 "$out" >&2 || true
			tail -10 "$err" >&2 || true
			rm -f "$err" "$out"
			exit 1
		fi
		local mean p50 p99 worst over
		mean=$(echo "$result" | sed -n 's/.*mean_ms=\([0-9.]*\).*/\1/p')
		p50=$(echo "$result"  | sed -n 's/.*p50_ms=\([0-9.]*\).*/\1/p')
		p99=$(echo "$result"  | sed -n 's/.*p99_ms=\([0-9.]*\).*/\1/p')
		worst=$(echo "$result"| sed -n 's/.*worst_ms=\([0-9.]*\).*/\1/p')
		over=$(echo "$result" | sed -n 's/.*over16ms=\([0-9]*\).*/\1/p')
		means+=("$mean"); p50s+=("$p50"); p99s+=("$p99"); worsts+=("$worst"); overs+=("${over:-0}")
		local u s f r
		u=$(echo "$time_line" | sed -n 's/.*user=\([0-9.]*\).*/\1/p')
		s=$(echo "$time_line" | sed -n 's/.*sys=\([0-9.]*\).*/\1/p')
		f=$(echo "$time_line" | sed -n 's/.*minflt=\([0-9]*\).*/\1/p')
		r=$(echo "$time_line" | sed -n 's/.*rss_kb=\([0-9]*\).*/\1/p')
		users+=("${u:-0}"); syss+=("${s:-0}"); flts+=("${f:-0}"); rsss+=("${r:-0}")
		printf '  run %d %s %s mean=%s worst=%s over=%s\n' \
			"$i" "$label" "$sc" "$mean" "$worst" "$over"
		rm -f "$err" "$out"
	done

	local med_mean med_p50 med_p99 med_worst sum_over med_user med_sys med_flt med_rss rss_mb
	med_mean=$(printf '%s\n' "${means[@]}" | median)
	med_p50=$(printf '%s\n' "${p50s[@]}" | median)
	med_p99=$(printf '%s\n' "${p99s[@]}" | median)
	med_worst=$(printf '%s\n' "${worsts[@]}" | median)
	sum_over=$(printf '%s\n' "${overs[@]}" | sum_ints)
	med_user=$(printf '%s\n' "${users[@]}" | median)
	med_sys=$(printf '%s\n' "${syss[@]}" | median)
	med_flt=$(printf '%s\n' "${flts[@]}" | median)
	med_rss=$(printf '%s\n' "${rsss[@]}" | median)
	rss_mb=$(( ${med_rss%.*} / 1024 ))

	printf 'MEDIAN %-10s %-12s mean=%s p50=%s p99=%s worst=%s over16_sum=%s user=%ss sys=%ss minflt=%s rss=%sMB\n' \
		"$label" "$sc" "$med_mean" "$med_p50" "$med_p99" "$med_worst" \
		"$sum_over" "$med_user" "$med_sys" "$med_flt" "$rss_mb"
}

# Selecting gc:sdcq must be done with --DRT-gcopt= (DRT_GCOPT=gc:sdcq is ignored
# by this druntime). precise:1 for druntime works as DRT_GCOPT.
for sc in "${SCENARIOS[@]}"; do
	run_case druntime "$sc" -- env DRT_GCOPT=precise:1 \
		"$WORK/gcb_druntime" default "$FRAMES" "$sc"
	run_case steadygc "$sc" -- \
		"$WORK/gcb_steady" --DRT-gcopt=gc:sdcq default "$FRAMES" "$sc"
done
