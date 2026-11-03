#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_autotools libass

      [[ -f "$PREFIX/lib/pkgconfig/libass.pc" ]] || {
        echo "libass 安装后未找到: $PREFIX/lib/pkgconfig/libass.pc"
        exit 1
      }

      PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists 'libass >= 0.11.0' || {
        echo "pkg-config 无法识别交叉编译版 libass"
        exit 1
      }
