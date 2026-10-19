#!/bin/bash
# Build and run a D program with DMD's GC write barrier (-preview=gcbarrier) and steadygc in card mode.
#
#   DMD_REPO=<dmd checkout> PHOBOS=<phobos checkout> bench/dmd_gcbarrier.sh libs
#   DMD_REPO=<dmd checkout> PHOBOS=<phobos checkout> bench/dmd_gcbarrier.sh build OUT FILE.d [extra dmd flags]
#
# DMD_REPO is a checkout of this project's dmd (the one with -preview=gcbarrier), already built
# (generated/linux/release/64/dmd and libdruntime.a); PHOBOS is a Phobos checkout built against it.
# `libs` builds an instrumented druntime and Phobos into generated/gcb of each, leaving the normal ones alone.
#
# The barrier has to be in everything that stores pointers into the GC heap, so druntime and Phobos are built with the
# flag too. Programs built without it lose memory under a concurrent mark: mark_race.d shows it.
# Run the result with --DRT-gcopt=gc:sdcq.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
: "${DMD_REPO:?set DMD_REPO to the checkout of the dmd of this project}"
: "${PHOBOS:?set PHOBOS to a Phobos checkout}"
SYMGC_SRC=${SYMGC_SRC:-$HERE/../source}
DMD=${DMD:-$DMD_REPO/generated/linux/release/64/dmd}
GCB_DRT=$DMD_REPO/generated/gcb/linux/release/64
GCB_PHO=$PHOBOS/generated/gcb/linux/release/64

libs() {
	make -C "$DMD_REPO/druntime" -j"$(nproc)" ROOT_OF_THEM_ALL=../generated/gcb OBJDIR=obj/gcb \
		DFLAGS="-conf= -Isrc -Iimport -w -de -preview=dip1000 -preview=fieldwise -m64 -fPIC -preview=dtorfields -O -release -inline -preview=gcbarrier" \
		../generated/gcb/linux/release/64/libdruntime.a || return 1
	make -C "$PHOBOS" -j"$(nproc)" BUILD=release ROOT_OF_THEM_ALL=generated/gcb DMDEXTRAFLAGS=-preview=gcbarrier \
		generated/gcb/linux/release/64/libphobos2.a
}

build() {
	local out=$1 file=$2; shift 2
	$DMD -conf= -I"$DMD_REPO/druntime/import" -I"$PHOBOS" -fPIC -O -release -inline -preview=gcbarrier \
		-version=Symgc_druntime_hooks -version=Symgc_cards -version=Symgc_druntime_cards \
		-I"$SYMGC_SRC" -I"$HERE" -defaultlib= "$@" \
		-of="$out" "$file" $(find "$SYMGC_SRC" -name '*.d') \
		"$GCB_PHO/libphobos2.a" -L-L"$GCB_DRT" -L-ldruntime -L-lpthread -L-lm -L-ldl -L-lz
}

case "${1:-}" in
	libs) libs ;;
	build) shift; build "$@" ;;
	*) sed -n 2,5p "$0"; exit 2 ;;
esac
