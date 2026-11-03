#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_meson libdvdnav \
        -Denable_docs=false \
        -Denable_examples=false
