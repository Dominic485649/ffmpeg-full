#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake chromaprint \
        -DBUILD_TOOLS=OFF \
        -DBUILD_TESTS=OFF \
        -DUSE_INTERNAL_AVRESAMPLE=ON \
        -DFFT_LIB=kissfft
