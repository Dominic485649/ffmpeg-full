#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "x265")" || return 1
      stage+="/source"
      # 修复 CMake 4.x 下 CMP0025 和 CMP0054 的 OLD 行为被废弃的报错。
      # Do not touch CMakeLists.txt again when the staged patch is already applied.
      if grep -Eq 'cmake_policy\(SET CMP00(25|54) OLD\)' "$stage/CMakeLists.txt"; then
        sed -i \
          -e 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/g' \
          -e 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/g' \
          "$stage/CMakeLists.txt"
      fi
      local bld="$BUILDROOT/x265"
      local bld8 bld10
      local common_cmake_args=(
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
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      local cmake_args10=(
        "${common_cmake_args[@]}"
        -DEXPORT_C_API=OFF
        -DHIGH_BIT_DEPTH=ON
        -DENABLE_HDR10_PLUS=ON
      )
      local cmake_args8=(
        "${common_cmake_args[@]}"
        -DEXTRA_LIB=x265_main10.a
        -DEXTRA_LINK_FLAGS=-L.
        -DLINKED_10BIT=ON
        -DLINKED_12BIT=OFF
      )

      # Each bit depth has its own compatibility key. Unknown or incompatible
      # build directories are preserved; source-only edits can reuse Ninja objects.
      bld10="$(full_build_directory "$bld/10bit" "$stage" cmake "${cmake_args10[@]}")" || return 1
      cmake -S "$stage" -B "$bld10" "${cmake_args10[@]}"
      cmake --build "$bld10" --parallel "$JOBS"

      bld8="$(full_build_directory "$bld/8bit" "$stage" cmake "${cmake_args8[@]}")" || return 1
      # Avoid changing dependency timestamps on an otherwise unchanged rerun.
      cmp -s "$bld10/libx265.a" "$bld8/x265_main10.a" || cp -p "$bld10/libx265.a" "$bld8/x265_main10.a"
      cmake -S "$stage" -B "$bld8" "${cmake_args8[@]}"
      cmake --build "$bld8" --parallel "$JOBS"

      grep -q '^HIGH_BIT_DEPTH:BOOL=ON$' "$bld10/CMakeCache.txt"
      grep -q '^ENABLE_HDR10_PLUS:BOOL=ON$' "$bld10/CMakeCache.txt"
      grep -q '^LINKED_10BIT:BOOL=ON$' "$bld8/CMakeCache.txt"
      grep -q '^LINKED_12BIT:BOOL=OFF$' "$bld8/CMakeCache.txt"

      # Never rename or overwrite Ninja's real 8-bit output with the merged
      # archive: doing so would merge 10-bit members again on the next build.
      # Short local input names also keep MRI safe for build paths with spaces.
      local multilib
      multilib="$(mktemp -d "$bld/multilib.XXXXXX")" || return 1
      ln -s -- "$bld8/libx265.a" "$multilib/8bit.a"
      ln -s -- "$bld10/libx265.a" "$multilib/10bit.a"
      (
        cd "$multilib"
        "$AR" -M <<'EOF'
CREATE libx265.a
ADDLIB 8bit.a
ADDLIB 10bit.a
SAVE
END
EOF
      )
      [[ -s "$multilib/libx265.a" ]] || {
        echo "x265 multilib archive was not created" >&2
        exit 1
      }
      cmake --install "$bld8"
      install -m644 -- "$multilib/libx265.a" "$PREFIX/lib/libx265.a"
      # Only remove files in the private directory created by this invocation.
      rm -f -- "$multilib/8bit.a" "$multilib/10bit.a" "$multilib/libx265.a"
      rmdir -- "$multilib"
