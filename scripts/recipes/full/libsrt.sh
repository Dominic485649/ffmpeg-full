#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "libsrt")" || return 1
      local -a cmake_args=(
        -G Ninja
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DENABLE_SHARED=OFF
        -DENABLE_STATIC=ON
        -DUSE_ENCLIB=mbedtls
        -DMBEDTLS_ROOT_DIR="$PREFIX"
        -DMBEDTLS_INCLUDE_DIR="$PREFIX/include"
        -DMBEDTLS_LIBRARY="$PREFIX/lib/libmbedtls.a"
        -DMBEDX509_LIBRARY="$PREFIX/lib/libmbedx509.a"
        -DMBEDCRYPTO_LIBRARY="$PREFIX/lib/libmbedcrypto.a"
        -DCMAKE_INCLUDE_PATH="$PREFIX/include"
        -DENABLE_APPS=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      local bld
      bld="$(full_build_directory "$BUILDROOT/libsrt" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      # 修复 srt.pc 和 haisrt.pc 中 mbedtls 的绝对路径导致 static 链接顺序错误的 Bug
      if [[ -f "$PREFIX/lib/pkgconfig/srt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/srt.pc"
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/srt.pc"
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/srt.pc"
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/haisrt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/haisrt.pc"
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/haisrt.pc"
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/haisrt.pc"
      fi
