#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage bld
      stage="$(stage_src "libplacebo")" || return 1
      # This target is static; PL_EXPORT would leak placebo symbols from avfilter.dll.
      # Only write the patch when needed, preserving timestamps on cache hits.
      python3 -I - "$stage/src/meson.build" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "  c_args: ['-DPL_EXPORT'],"
new = "  c_args: ['-DPL_STATIC'],"
static = "  c_static_args: ['-DPL_STATIC'],"
shared = "  c_shared_args: ['-DPL_EXPORT'],"
marker = "lib = library('placebo', sources,"
if s.count(marker) != 1:
    raise SystemExit(f"unexpected libplacebo export definition in {p}")
start = s.index(marker)
end = s.find('\n)', start)
if end < 0:
    raise SystemExit(f"unexpected libplacebo export definition in {p}")
body = s[start:end]
counts = tuple(body.count(value) for value in (old, new, static, shared))
if (counts != tuple(s.count(value) for value in (old, new, static, shared)) or
        body.count('-DPL_EXPORT') != counts[0] + counts[3] or
        body.count('-DPL_STATIC') != counts[1] + counts[2]):
    raise SystemExit(f"unexpected libplacebo export definition in {p}")
if counts == (1, 0, 0, 0):
    p.write_text(s[:start] + body.replace(old, new, 1) + s[end:])
elif counts not in ((0, 1, 0, 0), (0, 0, 1, 1)):
    raise SystemExit(f"unexpected libplacebo export definition in {p}")
PY
      local meson_args=(
        --cross-file "$BUILDROOT/mingw-cross.txt"
        --prefix "$PREFIX"
        --buildtype release
        --default-library=static
        -Ddemos=false
        -Dtests=false
        -Dvulkan=enabled
        -Dshaderc=enabled
        -Dopengl=disabled
        -Dlcms=enabled
        -Ddovi=enabled
        -Dlibdovi=disabled
      )
      bld="$(full_build_directory "$BUILDROOT/libplacebo" "$stage" meson "${meson_args[@]}")" || return 1
      local setup_args=()
      if [[ -f "$bld/meson-private/coredata.dat" ]]; then
        setup_args=(--clearcache --reconfigure)
      fi
      meson setup "${setup_args[@]}" "$bld" "$stage" "${meson_args[@]}"
      meson compile -C "$bld" -j "$JOBS"
      meson install --no-rebuild -C "$bld"
      grep -q '^#define PL_HAVE_DOVI 1$' "$PREFIX/include/libplacebo/config.h" || {
        echo "libplacebo Dolby Vision support is disabled"
        exit 1
      }
      # Consume all strings: grep -q could hide a match behind SIGPIPE under pipefail.
      if strings "$PREFIX/lib/libplacebo.a" | grep -E '(/EXPORT:pl_|-export:pl_)' >/dev/null; then
        echo "静态 libplacebo 仍包含 DLL 导出指令，不能安全链接到 FFmpeg DLL" >&2
        exit 1
      fi
      grep -q '^pl_has_vk_proc_addr=1' "$PREFIX/lib/pkgconfig/libplacebo.pc" || {
        echo "libplacebo 未链接 Windows Vulkan loader 的 vkGetInstanceProcAddr"
        exit 1
      }
