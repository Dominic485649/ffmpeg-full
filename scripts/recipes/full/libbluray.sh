#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_meson libbluray -Denable_examples=false -Dbdj_jar=disabled -Denable_tools=false
