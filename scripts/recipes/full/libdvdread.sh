#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_meson libdvdread \
        -Denable_docs=false \
        -Dlibdvdcss=disabled \
        -Ddlfcn=builtin
