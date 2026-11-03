#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "lzma")" || return 1
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
        -DENABLE_NLS=OFF
        -DENABLE_THREADS=ON
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      local bld
      bld="$(full_build_directory "$BUILDROOT/lzma" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      # 强制手动复制头文件以防止交叉编译下 CMake 部署 0 字节文件
      mkdir -p "$PREFIX/include/lzma"
      cp -f "$stage/src/liblzma/api/lzma.h" "$PREFIX/include/"
      cp -rf "$stage/src/liblzma/api/lzma/"* "$PREFIX/include/lzma/"
      # 强制生成正确的 liblzma.pc 以防止 CMake 在交叉编译下输出 0 字节文件
      mkdir -p "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/liblzma.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: liblzma
Description: General purpose data compression library
URL: https://tukaani.org/xz/
Version: 5.8.3
Cflags: -I\${includedir}
Cflags.private: -DLZMA_API_STATIC
Libs: -L\${libdir} -llzma
Libs.private:
EOF
