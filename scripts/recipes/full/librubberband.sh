#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "librubberband")" || return 1
      local -a meson_args=(
        --cross-file "$BUILDROOT/mingw-cross.txt"
        --prefix "$PREFIX"
        --buildtype release
        --default-library=static
        -Dfft=builtin
        -Dresampler=builtin
        -Dtests=disabled
      )
      local bld
      bld="$(full_build_directory "$BUILDROOT/librubberband" "$stage" meson "${meson_args[@]}")" || return 1
      if [[ -f "$bld/meson-private/coredata.dat" ]]; then
        meson setup --clearcache --reconfigure "$bld" "$stage" "${meson_args[@]}"
      else
        meson setup "$bld" "$stage" "${meson_args[@]}"
      fi
      meson compile -C "$bld" -j "$JOBS"
      meson install --no-rebuild -C "$bld"
