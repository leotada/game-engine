#!/bin/bash
# Build one benchmark with the collector compiled in (no card barrier: the concurrent mark uses the kernel
# tracker on Linux 6.7+; see ../guide/usage.md for the card barrier builds).
#
#   bench/build.sh PROGRAM.d [OUT]
#
#   DC=dmd|ldc2   compiler (default dmd)
#   SYMGC=DIR     the collector's source directory (default ../source)
#   EXTRA="..."   extra compiler flags
#
# The same binary runs with druntime's GC (no option) and with steadygc (--DRT-gcopt=gc:sdcq): see compare.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DC=${DC:-dmd}
SYMGC=${SYMGC:-$HERE/../source}
prog=$1
out=${2:-${prog%.d}}
[ -f "$prog" ] || prog=$HERE/$prog

extra_files=()
[ "$(basename "$prog")" = gcb.d ] && extra_files+=("$HERE/perfcount.d")
ext=${prog%.d}_ext.d
[ -f "$ext" ] && extra_files+=("$ext")

case $(basename "$DC") in
	ldc2|ldmd2*)
		$DC -O3 -release -d-version=Symgc_druntime_hooks -d-version=SymGC -I"$SYMGC" -I"$HERE" ${EXTRA:-} \
			-of="$out" "$prog" "${extra_files[@]}" $(find "$SYMGC" -name '*.d') ;;
	gdc*)
		$DC -O2 -frelease -fversion=Symgc_druntime_hooks -fversion=SymGC -I"$SYMGC" -I"$HERE" ${EXTRA:-} \
			-o "$out" "$prog" "${extra_files[@]}" $(find "$SYMGC" -name '*.d') ;;
	*)
		$DC -O -release -inline -version=Symgc_druntime_hooks -version=SymGC -I"$SYMGC" -I"$HERE" ${EXTRA:-} \
			-of="$out" "$prog" "${extra_files[@]}" $(find "$SYMGC" -name '*.d') ;;
esac
rm -f "$out.o"
echo "built $out"
