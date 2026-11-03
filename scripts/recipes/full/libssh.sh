#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      build_cmake libssh \
        -DWITH_MBEDTLS=ON \
        -DMBEDTLS_ROOT_DIR="$PREFIX" \
        -DWITH_GCRYPT=OFF \
        -DWITH_GSSAPI=OFF \
        -DWITH_NACL=OFF \
        -DWITH_FIDO2=OFF \
        -DWITH_PCAP=OFF \
        -DWITH_SERVER=OFF \
        -DWITH_SFTP=ON \
        -DWITH_EXAMPLES=OFF \
        -DUNIT_TESTING=OFF \
        -DCLIENT_TESTING=OFF \
        -DSERVER_TESTING=OFF \
        -DWITH_BENCHMARKS=OFF \
        -DWITH_SYMBOL_VERSIONING=OFF \
        -DWITH_ZLIB=ON
