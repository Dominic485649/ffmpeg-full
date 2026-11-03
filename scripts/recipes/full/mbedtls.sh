#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "mbedtls")" || return 1
      # LibSSH needs public pthread settings; use its latest compatible Mbed TLS 3.6 LTS line.
      # Do not retouch an already patched header and invalidate unrelated objects.
      if grep -Eq '^//#define MBEDTLS_THREADING_(PTHREAD|C)$' "$stage/include/mbedtls/mbedtls_config.h"; then
        sed -i \
          -e 's|^//#define MBEDTLS_THREADING_PTHREAD$|#define MBEDTLS_THREADING_PTHREAD|' \
          -e 's|^//#define MBEDTLS_THREADING_C$|#define MBEDTLS_THREADING_C|' \
          "$stage/include/mbedtls/mbedtls_config.h"
      fi
      grep -q '^#define MBEDTLS_THREADING_PTHREAD$' "$stage/include/mbedtls/mbedtls_config.h"
      grep -q '^#define MBEDTLS_THREADING_C$' "$stage/include/mbedtls/mbedtls_config.h"
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
        -DENABLE_TESTING=OFF
        -DENABLE_PROGRAMS=OFF
        -DLINK_WITH_PTHREAD=ON
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      local bld
      bld="$(full_build_directory "$BUILDROOT/mbedtls" "$stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
