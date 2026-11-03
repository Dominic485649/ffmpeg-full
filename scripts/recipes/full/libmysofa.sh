#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake libmysofa \
        -DBUILD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DZLIB_ROOT="$PREFIX" \
        -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="$PREFIX/include"
