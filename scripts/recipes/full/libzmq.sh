#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake libzmq \
        -DZMQ_WIN32_WINNT=0x0A00 \
        -DZMQ_HAVE_IPC=OFF \
        -DBUILD_SHARED=OFF \
        -DBUILD_STATIC=ON \
        -DBUILD_TESTS=OFF \
        -DWITH_DOCS=OFF \
        -DWITH_PERF_TOOL=OFF \
        -DENABLE_DRAFTS=OFF \
        -DENABLE_WS=OFF \
        -DWITH_LIBSODIUM=OFF \
        -DENABLE_CURVE=OFF \
        -DWITH_OPENPGM=OFF \
        -DWITH_NORM=OFF \
        -DWITH_VMCI=OFF \
        -DENABLE_CPACK=OFF
