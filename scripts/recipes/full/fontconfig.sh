#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      need_meson_min 1.6.1
      build_meson fontconfig \
        -Ddoc=disabled \
        -Dnls=disabled \
        -Dtests=disabled \
        -Dtools=disabled
