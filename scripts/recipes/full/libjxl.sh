#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local jxl_stage bld
      jxl_stage="$(stage_src "libjxl")" || return 1
      jxl_stage="$(realpath -e -- "$jxl_stage")" || return 1

      # Only Highway and skcms are bundled for the options below. Never follow a
      # copied submodule gitfile back into the user's original repository, and
      # never check out over unknown local submodule edits.
      local jxl_module jxl_repo jxl_gitdir jxl_top jxl_status
      for jxl_module in '' third_party/highway third_party/skcms; do
        jxl_repo="$jxl_stage${jxl_module:+/$jxl_module}"
        if [[ -n "$jxl_module" && ! -e "$jxl_repo/.git" && ! -L "$jxl_repo/.git" ]]; then
          if [[ ! -e "$jxl_repo" && ! -L "$jxl_repo" ]]; then
            continue
          fi
          if [[ -L "$jxl_repo" || ! -d "$jxl_repo" ||
                "$(realpath -e -- "$jxl_repo")" != "$jxl_stage/"* ||
                -n "$(find "$jxl_repo" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
            echo "libjxl refuses to overwrite an unrecognized submodule tree: $jxl_repo" >&2
            return 1
          fi
          continue
        fi
        jxl_gitdir="$(git -C "$jxl_repo" rev-parse --absolute-git-dir)" || return 1
        jxl_gitdir="$(realpath -e -- "$jxl_gitdir")" || return 1
        jxl_top="$(git -C "$jxl_repo" rev-parse --show-toplevel)" || return 1
        if [[ "$jxl_gitdir" != "$jxl_stage/"* || "$jxl_top" != "$jxl_repo" ]]; then
          echo "libjxl requires independent staged submodule metadata: $jxl_repo" >&2
          return 1
        fi
        if [[ -n "$jxl_module" ]]; then
          FFBUILD_JXL_STAGE="$jxl_stage" git -C "$jxl_repo" submodule foreach --quiet --recursive '
            gitdir="$(git rev-parse --absolute-git-dir)" || exit 1
            gitdir="$(realpath -e -- "$gitdir")" || exit 1
            case "$gitdir" in "$FFBUILD_JXL_STAGE"/*) ;; *) exit 1 ;; esac
            test "$(git rev-parse --show-toplevel)" = "$PWD" || exit 1
            status="$(git status --porcelain --untracked-files=all --ignore-submodules=none)" || exit 1
            test -z "$status" || exit 1
          ' || {
            echo "libjxl nested submodules are not independent and clean; preserving them" >&2
            return 1
          }
        fi
      done
      jxl_status="$(git -C "$jxl_stage" status --porcelain --untracked-files=all \
        --ignore-submodules=none -- third_party/highway third_party/skcms)" || return 1
      [[ -z "$jxl_status" ]] || {
        echo "libjxl submodules have local changes; preserving them without update" >&2
        return 1
      }
      git -C "$jxl_stage" submodule update --init --recursive --checkout --depth 1 --recommend-shallow \
        -- third_party/highway third_party/skcms || {
          echo "libjxl required submodule initialization failed" >&2
          return 1
        }
      jxl_status="$(git -C "$jxl_stage" submodule status --recursive \
        -- third_party/highway third_party/skcms)" || return 1
      if [[ -z "$jxl_status" ]] || grep -Eq '^[-+U]' <<< "$jxl_status" ||
         [[ ! -f "$jxl_stage/third_party/highway/CMakeLists.txt" ||
            ! -f "$jxl_stage/third_party/skcms/skcms.h" ]]; then
        echo "libjxl required submodules are incomplete or not at their pinned revisions" >&2
        return 1
      fi

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
        -DCMAKE_PREFIX_PATH="$PREFIX"
        -DCMAKE_FIND_ROOT_PATH="$PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DBUILD_TESTING=OFF
        -DJPEGXL_TEST_TOOLS=OFF
        -DJPEGXL_FORCE_SYSTEM_BROTLI=ON
        -DJPEGXL_STATIC=ON
        -DJPEGXL_ENABLE_TOOLS=OFF
        -DJPEGXL_ENABLE_DEVTOOLS=OFF
        -DJPEGXL_ENABLE_DOXYGEN=OFF
        -DJPEGXL_ENABLE_MANPAGES=OFF
        -DJPEGXL_ENABLE_BENCHMARK=OFF
        -DJPEGXL_ENABLE_EXAMPLES=OFF
        -DJPEGXL_ENABLE_JNI=OFF
        -DJPEGXL_ENABLE_SJPEG=OFF
        -DJPEGXL_ENABLE_OPENEXR=OFF
        -DJPEGXL_ENABLE_VIEWERS=OFF
        -DJPEGXL_ENABLE_PLUGINS=OFF
        -DJPEGXL_ENABLE_JPEGLI=OFF
        -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF
        -DJPEGXL_ENABLE_SKCMS=ON
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )
      bld="$(full_build_directory "$BUILDROOT/libjxl" "$jxl_stage" cmake "${cmake_args[@]}")" || return 1
      cmake -S "$jxl_stage" -B "$bld" "${cmake_args[@]}"
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      if [[ -f "$PREFIX/lib/pkgconfig/libjxl_threads.pc" ]] &&
         grep -q '^Libs.private: -lm$' "$PREFIX/lib/pkgconfig/libjxl_threads.pc"; then
        sed -i 's/^Libs.private: -lm$/Libs.private: -lm -lwinpthread/' \
          "$PREFIX/lib/pkgconfig/libjxl_threads.pc"
      fi
