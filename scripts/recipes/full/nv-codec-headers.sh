#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local nv_stage nv_install
      nv_stage="$(stage_src "nv-codec-headers")"
      # Header-only upstream `make all/install` rewrites ffnvcodec.pc in place.
      # Generate it outside the source copy instead, preserving any unknown pc
      # file/symlink and avoiding timestamp-only edits to reusable sources.
      nv_install="$(mktemp -d "$BUILDROOT/.nv-codec-install.XXXXXXXX")"
      python3 -I - "$nv_stage/ffnvcodec.pc.in" "$PREFIX" "$nv_install/ffnvcodec.pc" <<'PYNVCODECPC'
from pathlib import Path
import sys
source, prefix, output = sys.argv[1:]
text = Path(source).read_text()
if '@@PREFIX@@' not in text:
    raise SystemExit('unrecognized ffnvcodec pkg-config template')
text = text.replace('@@PREFIX@@', prefix)
if '@@' in text:
    raise SystemExit('unresolved ffnvcodec pkg-config template token')
Path(output).write_text(text)
PYNVCODECPC
      install -d "$PREFIX/include/ffnvcodec" "$PREFIX/lib/pkgconfig"
      install -m644 "$nv_stage/include/ffnvcodec/"*.h "$PREFIX/include/ffnvcodec/"
      install -m644 "$nv_install/ffnvcodec.pc" "$PREFIX/lib/pkgconfig/ffnvcodec.pc"
      rm -rf -- "$nv_install"

      [[ -f "$PREFIX/lib/pkgconfig/ffnvcodec.pc" ]] || {
        echo "nv-codec-headers 安装后未找到: $PREFIX/lib/pkgconfig/ffnvcodec.pc"
        exit 1
      }

      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "pkg-config 无法识别 ffnvcodec"
        exit 1
      }
      local api_header="$PREFIX/include/ffnvcodec/nvEncodeAPI.h"
      local api_major api_minor
      api_major="$(sed -n 's/^#define NVENCAPI_MAJOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      api_minor="$(sed -n 's/^#define NVENCAPI_MINOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      ((api_major > 13 || (api_major == 13 && api_minor >= 1))) || {
        echo "NVENC API $api_major.$api_minor is below required 13.1"
        exit 1
      }

      if [[ "$CUDA_ENABLE" == "1" ]]; then
        local cuda_symbol
        for cuda_symbol in cuCtxSynchronize cuCtxGetStreamPriorityRange cuMemHostAlloc cuMemFreeHost cuMemFreeAsync cuStreamCreateWithPriority; do
          grep -q "$cuda_symbol" "$PREFIX/include/ffnvcodec/dynlink_loader.h" || {
            echo "nv-codec-headers 缺少 libvmaf CUDA 所需函数: $cuda_symbol"
            exit 1
          }
        done
      fi
