#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake brotli \
        -DBROTLI_BUILD_TOOLS=OFF
