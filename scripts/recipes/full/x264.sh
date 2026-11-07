#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "x264")"
      pushd "$stage" >/dev/null
      # PREALLOC updates typed pointers through byte-pointer aliases under ThinLTO.
      ./configure \
        --host="$TARGET" \
        --cross-prefix="$TARGET-" \
        --prefix="$PREFIX" \
        --enable-static \
        --enable-pic \
        --disable-cli \
        --bit-depth=8 \
        --extra-cflags="$CFLAGS -fno-strict-aliasing" \
        --extra-ldflags="$LDFLAGS"
      if [[ "$LTO_ENABLE" == 1 && "$CFLAGS" == *-flto=thin* ]]; then
        # Match FFmpeg's Win64 ABI metadata. x86inc/osdep realign wider SIMD locals.
        python3 -I - "$stage" <<'PYX264STACK'
from pathlib import Path
import sys

root = Path(sys.argv[1])
changes = {
    'config.mak': (('-mstack-alignment=64', '-mstack-alignment=16'),
                   ('-DSTACK_ALIGNMENT=64', '-DSTACK_ALIGNMENT=16')),
    'config.h': (('#define STACK_ALIGNMENT 64\n', '#define STACK_ALIGNMENT 16\n'),),
}
pending = {}
for name, replacements in changes.items():
    path = root / name
    if path.is_symlink() or not path.is_file():
        raise SystemExit('x264 stack compatibility requires regular generated configuration files')
    text = path.read_text()
    if all(text.count(new) == 1 and old not in text for old, new in replacements):
        continue
    if not all(text.count(old) == 1 and new not in text for old, new in replacements):
        raise SystemExit('unknown x264 stack-alignment configuration; files left unchanged')
    for old, new in replacements:
        text = text.replace(old, new)
    pending[path] = text
for path, text in pending.items():
    path.write_text(text)
PYX264STACK
      fi
      make -j"$JOBS"
      make install
      popd >/dev/null
