#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake libsnappy \
        -DSNAPPY_BUILD_TESTS=OFF \
        -DSNAPPY_BUILD_BENCHMARKS=OFF \
        -DSNAPPY_FUZZING_BUILD=OFF \
        -DSNAPPY_INSTALL=ON
