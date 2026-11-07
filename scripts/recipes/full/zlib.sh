#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local -a zlib_dynamic_paths=(
        "$PREFIX/bin/libz.dll" "$PREFIX/bin/libzlib.dll"
        "$PREFIX/lib/libzlib.dll.a" "$PREFIX/lib/libz.dll.a"
      )
      local zlib_dynamic
      for zlib_dynamic in "${zlib_dynamic_paths[@]}"; do
        if [[ -e "$zlib_dynamic" || -L "$zlib_dynamic" ]]; then
          printf 'zlib: conflicting dynamic-link path exists; preserved without building: %s\n' "$zlib_dynamic" >&2
          return 1
        fi
      done
      local stage
      stage="$(stage_src "zlib")" || return 1
      local -a cmake_args=(
        -G Ninja
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DZLIB_BUILD_SHARED=OFF
        -DZLIB_BUILD_STATIC=ON
        -DZLIB_BUILD_TESTING=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      local bld
      bld="$(full_build_directory "$BUILDROOT/zlib" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      for zlib_dynamic in "${zlib_dynamic_paths[@]}"; do
        if [[ -e "$zlib_dynamic" || -L "$zlib_dynamic" ]]; then
          printf 'zlib: unexpected dynamic-link output; preserved for inspection: %s\n' "$zlib_dynamic" >&2
          return 1
        fi
      done
      # zlib CMake 在 Windows 下安装为 libzlibstatic.a，必须创建 libz.a 以兼容下游依赖
      local zlib_static="" zlib_name
      for zlib_name in libzlibstatic.a libzlib.a libzs.a libz.a; do
        if [[ -f "$PREFIX/lib/$zlib_name" ]] && grep -Fxq -- "$PREFIX/lib/$zlib_name" "$bld/install_manifest.txt"; then
          zlib_static="$PREFIX/lib/$zlib_name"
          break
        fi
      done
      [[ -n "$zlib_static" ]] || { echo 'zlib: installed static archive not found in CMake manifest' >&2; return 1; }
      if [[ "$zlib_static" != "$PREFIX/lib/libz.a" ]]; then
        cp -f "$zlib_static" "$PREFIX/lib/libz.a"
        echo "zlib: created $PREFIX/lib/libz.a from $zlib_static"
      fi
