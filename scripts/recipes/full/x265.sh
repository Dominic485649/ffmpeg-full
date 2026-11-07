#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "x265")" || return 1
      stage+="/source"
      if grep -Eq 'cmake_policy\(SET CMP00(25|54) OLD\)' "$stage/CMakeLists.txt"; then
        sed -i \
          -e 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/g' \
          -e 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/g' \
          "$stage/CMakeLists.txt"
      fi
      local bld
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
        -DENABLE_SHARED=OFF
        -DENABLE_CLI=OFF
        -DEXPORT_C_API=ON
        -DHIGH_BIT_DEPTH=ON
        -DMAIN12=OFF
        -DENABLE_HDR10_PLUS=ON
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      bld="$(full_build_directory "$BUILDROOT/x265/10bit" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      grep -q '^HIGH_BIT_DEPTH:BOOL=ON$' "$bld/CMakeCache.txt"
      grep -q '^EXPORT_C_API:BOOL=ON$' "$bld/CMakeCache.txt"
      grep -q '^MAIN12:BOOL=OFF$' "$bld/CMakeCache.txt"
      grep -q '^ENABLE_HDR10_PLUS:BOOL=ON$' "$bld/CMakeCache.txt"
      cmake --install "$bld"
