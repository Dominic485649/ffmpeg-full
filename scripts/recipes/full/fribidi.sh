#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_meson fribidi \
        -Ddocs=false \
        -Dbin=false \
        -Dtests=false
