#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage bld
      stage="$(stage_src "libaom")" || return 1
      local cmake_args=(
        -G Ninja
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        -DCMAKE_RC_COMPILER="$WINDRES"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DCONFIG_AV1_HIGHBITDEPTH=1
        -DCONFIG_AV1_ENCODER=1
        -DCONFIG_AV1_DECODER=0
        -DENABLE_APPS=OFF
        -DENABLE_EXAMPLES=OFF
        -DENABLE_TESTS=OFF
        -DENABLE_TOOLS=OFF
        -DENABLE_DOCS=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      bld="$(full_build_directory "$BUILDROOT/libaom" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
