#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage bld
      stage="$(stage_src jxrlib)" || return 1
      # The historical SDK header duplicates MinGW's GUID declarations. Only
      # the disposable staged tree is adjusted; the original checkout is clean.
      rm -f -- "$stage/common/include/guiddef.h"
      cp -- "$FULL_RECIPES_DIR/jxrlib.cmake" "$stage/CMakeLists.txt"
      local -a cmake_args=(
        -G Ninja
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_C_FLAGS_RELEASE="$CFLAGS"
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
      )
      bld="$(full_build_directory "$BUILDROOT/jxrlib" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      mkdir -p -- "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/libjxr.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include/jxrlib

Name: libjxr
Description: JPEG XR reference library
Version: 1.1
Libs: -L\${libdir} -ljxrglue -ljpegxr
Libs.private: -lm
Cflags: -I\${includedir}
EOF
      "$PKG_CONFIG" --static --exists libjxr
