#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local stage
      stage="$(stage_src "bzip2")"
      pushd "$stage" >/dev/null
      "$CC" -O3 -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
      "$AR" rcs libbz2.a blocksort.o huffman.o crctable.o randtable.o compress.o decompress.o bzlib.o
      "$RANLIB" libbz2.a
      mkdir -p "$PREFIX/include" "$PREFIX/lib"
      cp -f bzlib.h "$PREFIX/include/"
      cp -f libbz2.a "$PREFIX/lib/"
      popd >/dev/null
