#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_autotools libtheora \
        --disable-examples \
        --disable-doc \
        --disable-spec
