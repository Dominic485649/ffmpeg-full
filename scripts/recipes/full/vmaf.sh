#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "vmaf")" || return 1
      python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" vmaf "$stage" || return 1
      stage+="/libvmaf"

      # HDR models require the upstream VmafPicture.color API.
      [[ -f "$stage/include/libvmaf/picture.h" ]] &&
        grep -Fq 'VmafColor color;' "$stage/include/libvmaf/picture.h" || {
          echo "Full HDR-VMAF requires upstream master with VmafPicture.color; update sources explicitly first" >&2
          exit 1
        }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists 'zimg >= 2.7' || {
        echo "Full HDR-VMAF requires target zimg >= 2.7 in the prefix; build zimg first" >&2
        exit 1
      }
      local hdr_family hdr_variant
      for hdr_family in hdr_vmaf_v1.1.8 hdr_vmaf_v1.1.8_hfr; do
        for hdr_variant in 3d0h 3d0h_2160 5d0h 1d5h_2160; do
          [[ -f "$stage/../model/$hdr_family/${hdr_family}_${hdr_variant}.json" ]] || {
            echo "Missing official built-in HDR model: ${hdr_family}_${hdr_variant}" >&2
            exit 1
          }
        done
      done
      command -v xxd >/dev/null || { echo "xxd is required to embed the official VMAF models" >&2; exit 1; }

      # LLVM 23 libc++ and bundled libsvm expose conflicting swap templates.
      local svm_cpp="$stage/src/svm.cpp"
      if grep -Fq 'template <class T> static inline void swap(T& x, T& y)' "$svm_cpp"; then
        perl -0pi -e 's/\bswap\(/vmaf_svm_swap(/g' "$svm_cpp"
      fi

      local meson_opts=(
        --cross-file "$BUILDROOT/mingw-cross.txt"
        --prefix "$PREFIX"
        --buildtype release
        --default-library=static
        -Doptimization=3
        -Dbuilt_in_models=true
        -Denable_zimg=true
        -Denable_float=true
        -Denable_tools=true
        -Denable_tests=false
        -Denable_asm=true
        -Denable_cuda=false
      )
      # Keep the established layout; VMAF itself is CPU-only in every profile.
      local bld
      bld="$(full_build_directory "$stage/build-mingw" "$stage" meson "${meson_opts[@]}")" || return 1
      local setup_opts=()
      if [[ -f "$bld/meson-private/coredata.dat" ]]; then
        setup_opts=(--clearcache --reconfigure)
      fi
      meson setup "${setup_opts[@]}" "$bld" "$stage" "${meson_opts[@]}"

      # Check the effective options, not just the command line or a stale stamp.
      local configured_opts required_option
      configured_opts="$(meson configure "$bld")"
      for required_option in enable_float enable_zimg built_in_models enable_tools; do
        grep -Eq "^[[:space:]]+$required_option[[:space:]]+true([[:space:]]|$)" <<< "$configured_opts" || {
          echo "libvmaf required option is not enabled: $required_option" >&2
          exit 1
        }
      done
      grep -Eq '^[[:space:]]+enable_cuda[[:space:]]+false([[:space:]]|$)' <<< "$configured_opts" || {
        echo "libvmaf must remain CPU-only, independently of FFmpeg CUDA support" >&2
        exit 1
      }
      meson compile -C "$bld" -j "$JOBS"
      meson install --no-rebuild -C "$bld"
      [[ -f "$PREFIX/bin/vmaf.exe" ]] || {
        echo "Standalone upstream vmaf.exe was not installed; required for CPU HDR cross-checks" >&2
        exit 1
      }
