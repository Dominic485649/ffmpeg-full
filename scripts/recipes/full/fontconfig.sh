#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      need_meson_min 1.6.1
      local stage bld
      stage="$(stage_src fontconfig)" || return 1
      python3 -I - "$stage/src/meson.build" <<'PYFONTCONFIGAPPS'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    raise SystemExit('Fontconfig application policy requires a regular staged build definition')
text = path.read_text()
blocks = list(re.finditer(r"^fcarch = executable\(\n  'fcarch',\n.*?^\)\n", text, re.M | re.S))
if len(blocks) != 1:
    raise SystemExit('unknown Fontconfig fcarch target; source left unchanged')
block = blocks[0]
body = block[0]
option = '  build_by_default: false,\n'
if body.count('  install: false,\n') != 1:
    raise SystemExit('unknown Fontconfig fcarch installation policy; source left unchanged')
if 'build_by_default' not in body:
    body = body.replace('  install: false,\n', option + '  install: false,\n')
    path.write_text(text[:block.start()] + body + text[block.end():])
elif body.count(option) != 1 or body.count('build_by_default') != 1:
    raise SystemExit('changed Fontconfig fcarch build policy; source left unchanged')
PYFONTCONFIGAPPS
      local meson_args=(
        --cross-file "$BUILDROOT/mingw-cross.txt"
        --prefix "$PREFIX"
        --buildtype release
        --default-library=static
        -Doptimization=3
        -Ddoc=disabled
        -Dnls=disabled
        -Dtests=disabled
        -Dtools=disabled
      )
      bld="$(full_build_directory "$BUILDROOT/fontconfig" "$stage" meson "${meson_args[@]}")" || return 1
      if [[ -f "$bld/meson-private/coredata.dat" ]]; then
        meson setup --clearcache --reconfigure "$bld" "$stage" "${meson_args[@]}"
      else
        meson setup "$bld" "$stage" "${meson_args[@]}"
      fi
      # Keep generated font configuration data, but not the unused fcarch program.
      meson compile -C "$bld" -j "$JOBS"
      [[ ! -e "$bld/src/fcarch.exe" ]] || { echo 'Unexpected optional Fontconfig fcarch program' >&2; return 1; }
      meson install --no-rebuild -C "$bld"
