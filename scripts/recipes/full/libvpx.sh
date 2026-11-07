#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "libvpx")"
      pushd "$stage" >/dev/null
      ./configure \
        --target=x86_64-win64-gcc \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-examples \
        --disable-unit-tests \
        --disable-tools \
        --disable-docs \
        --as=yasm \
        --enable-vp9-highbitdepth \
        --disable-vp8-encoder \
        --disable-vp9-encoder
      # Upstream's GNU-strip rule cannot read LLVM bitcode archive members.
      local -a vpx_make_args=()
      [[ "$LTO_ENABLE" != 1 ]] || vpx_make_args+=(HAVE_GNU_STRIP=no)
      make -j"$JOBS" "${vpx_make_args[@]}"
      make "${vpx_make_args[@]}" install
      popd >/dev/null
