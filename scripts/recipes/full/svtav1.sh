#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake svtav1 \
        -DENABLE_AVX512=ON \
        -DBUILD_DEC=ON \
        -DBUILD_ENC=ON \
        -DBUILD_SHARED_LIBS=OFF
