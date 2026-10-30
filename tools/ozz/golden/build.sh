#!/bin/sh
# Builds the golden generator against an upstream ozz-animation checkout (pinned: 744eb9d).
# Usage: build.sh <ozz-animation-dir> <output-binary>
set -e
Z=$1
g++ -std=c++17 -O2 -w -I"$Z/include" -I"$Z/src" -o "$2" golden.cc \
  $(find "$Z/src/base" "$Z/src/animation/runtime" "$Z/src/geometry/runtime" -name '*.cc')
