#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_meson dav1d \
        -Denable_tools=false \
        -Denable_tests=false \
        -Denable_examples=false \
        -Denable_asm=true
