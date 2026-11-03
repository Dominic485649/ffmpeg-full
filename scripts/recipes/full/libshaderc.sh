#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage bld
      stage="$(stage_src "libshaderc")" || return 1
      # The shared preparer verifies DEPS against actual clean dependency HEADs.
      # If they cannot be trusted, it preserves the old tree and returns a new
      # independent stage; never delete third_party as a sync retry mechanism.
      stage="$(full_prepare_shaderc_dependencies "$stage")" || return 1

      [[ -f "$stage/third_party/spirv-headers/include/spirv/unified1/spirv.h" ]] || {
        echo "shaderc 缺少 SPIR-V Headers"
        exit 1
      }
      cp -rf "$stage/third_party/spirv-headers/include/spirv" "$PREFIX/include/"

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
        -DSHADERC_ENABLE_SHARED_CRT=ON
        -DSHADERC_SKIP_TESTS=ON
        -DSHADERC_SKIP_EXAMPLES=ON
        -DSHADERC_SKIP_EXECUTABLES=ON
        -DSPIRV_SKIP_EXECUTABLES=ON
        -DENABLE_GLSLANG_BINARIES=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      bld="$(full_build_directory "$BUILDROOT/libshaderc" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
