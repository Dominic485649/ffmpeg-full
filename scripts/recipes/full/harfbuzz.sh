#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_meson harfbuzz \
        -Ddocs=disabled \
        -Dtests=disabled \
        -Dbenchmark=disabled \
        -Dutilities=disabled \
        -Dsubset=disabled \
        -Draster=disabled \
        -Dvector=disabled \
        -Dgpu=disabled \
        -Dgpu_demo=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dintrospection=disabled \
        -Dfreetype=enabled
