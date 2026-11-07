#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage bld
      stage="$(stage_src "brotli")" || return 1
      python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" brotli "$stage" || return 1
      local cmake_args=(
        -G Ninja
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DBROTLI_BUILD_TOOLS=OFF
        -DBROTLI_DISABLE_TESTS=ON
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      bld="$(full_build_directory "$BUILDROOT/brotli" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
