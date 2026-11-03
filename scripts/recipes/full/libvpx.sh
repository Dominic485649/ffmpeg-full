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
        --enable-vp9-highbitdepth
      make -j"$JOBS"
      make install
      popd >/dev/null
