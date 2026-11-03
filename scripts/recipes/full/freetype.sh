#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake freetype \
        -DFT_DISABLE_ZLIB=TRUE \
        -DFT_DISABLE_BZIP2=TRUE \
        -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_BROTLI=TRUE \
        -DFT_DISABLE_HARFBUZZ=TRUE
