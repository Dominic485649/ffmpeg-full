# Third-party notices

## Git for Windows enhanced 7-Zip SFX

The Windows installers use the enhanced 7-Zip/7zS.sfx maintained in the
Git for Windows build-extra repository:

https://github.com/git-for-windows/build-extra

The exact source revision and SHA-256 are recorded in
tools/sfx/SOURCE.md. The pristine stub and the downloaded upstream
LICENSE.txt are kept under tools/sfx/. The final installer contains a
derived branded copy with the FFmpeg icon and a GUI manifest added by the
build process; it is not presented as an FFmpeg-authored SFX binary.

Redistribution must retain the upstream copyright and license terms. The
corresponding Git for Windows source repository and license are available at
the URLs above.

## JPEG XR reference library (Full)

The Full build statically links the JPEG XR reference library from
[scrubbbbs/jxrlib-kif](https://github.com/scrubbbbs/jxrlib-kif).
The source revision is recorded in the build manifest. The license below is
from the [upstream source headers](https://github.com/scrubbbbs/jxrlib-kif/blob/91ce33207ad2e7f8961e4fba5268f9ac8af8dc69/jxrgluelib/JXRGlue.h).

Copyright © Microsoft Corp. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
