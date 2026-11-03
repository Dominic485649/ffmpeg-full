#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      # LLVM 23 libc++ no longer provides std::exception_ptr through zimg's
      # transitive <stdexcept> include; inject the standard owning header only
      # for zimg without changing its source/update policy.
      CXXFLAGS="$CXXFLAGS -include exception" build_autotools zimg --disable-openmp
