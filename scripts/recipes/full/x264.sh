#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "x264")"
      pushd "$stage" >/dev/null
      ./configure \
        --host="$TARGET" \
        --cross-prefix="$TARGET-" \
        --prefix="$PREFIX" \
        --enable-static \
        --enable-pic \
        --disable-cli \
        --bit-depth=8 \
        --extra-cflags="$CFLAGS" \
        --extra-ldflags="$LDFLAGS"
      make -j"$JOBS"
      make install
      popd >/dev/null
