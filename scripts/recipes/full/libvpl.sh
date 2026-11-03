#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake libvpl \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DINSTALL_EXAMPLES=OFF \
        -DENABLE_WARNINGS=OFF
