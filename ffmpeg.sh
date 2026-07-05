#!/usr/bin/env bash
# ==============================================================================
# FFmpeg 全功能交叉编译集成脚本 (MinGW-w64 x86_64-w64-mingw32)
# ==============================================================================
set -Eeuo pipefail

# 1. 运行路径安全校验
# 必须在 full 目录下运行，如果不在，则自动复制自己到 full 目录并提示用户
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" != */full ]]; then
  mkdir -p "$SCRIPT_DIR/full"
  cp -f "$BASH_SOURCE" "$SCRIPT_DIR/full/ffmpeg.sh"
  chmod +x "$SCRIPT_DIR/full/ffmpeg.sh"
  echo "警告: 检测到当前不在 full 目录下运行！"
  echo "已将脚本自动复制到: $SCRIPT_DIR/full/ffmpeg.sh"
  echo "请切换目录并重新运行: cd \"$SCRIPT_DIR/full\" && ./ffmpeg.sh"
  exit 1
fi

# 2. 全局基础变量与编译配置定义
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PREFIX="${PREFIX:-$ROOT/bin}"
BUILDROOT="${BUILDROOT:-$ROOT/build}"
TARGET="${TARGET:-x86_64-w64-mingw32}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_JOBS="${FFMPEG_JOBS:-$JOBS}"
FFMPEG_REF="${FFMPEG_REF:-master}"

# 编译优化选项
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O3 -pipe -DNDEBUG -funwind-tables -fexceptions}"
INLINE_ENABLE="${INLINE_ENABLE:-1}"
INLINE_FLAGS="${INLINE_FLAGS:--finline-functions -finline-small-functions -findirect-inlining}"
SECTION_GC_ENABLE="${SECTION_GC_ENABLE:-1}"
LTO_ENABLE="${LTO_ENABLE:-0}"
LTO_FLAGS="${LTO_FLAGS:--flto=auto}"
CPU_FLAGS="${CPU_FLAGS:--march=x86-64-v3 -mtune=generic}"

# CUDA/NVENC 配置
CUDA_ENABLE="${CUDA_ENABLE:-1}"
CUDA_REDIST_ROOT="${CUDA_REDIST_ROOT:-$ROOT/toolchains/cuda-redist-13.3.0/install/linux}"
CUDA_HOME="${CUDA_HOME:-}"
NVCC="${NVCC:-}"
NVCC_GENCODE_FLAGS="${NVCC_GENCODE_FLAGS:--gencode arch=compute_75,code=sm_75 -gencode arch=compute_80,code=sm_80 -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89 -gencode arch=compute_120,code=sm_120 -gencode arch=compute_120,code=compute_120}"
NVCC_OPTFLAGS="${NVCC_OPTFLAGS:--O3 --extra-device-vectorization}"
NVCC_THREADS="${NVCC_THREADS:-0}"
NVCC_PTXAS_FLAGS="${NVCC_PTXAS_FLAGS:--O3}"
NVCC_FAST_MATH="${NVCC_FAST_MATH:-1}"

# Git 源码库 URL 映射
declare -A URLS=(
  [ffmpeg-source]="https://github.com/FFmpeg/FFmpeg.git"
  [nv-codec-headers]="https://github.com/FFmpeg/nv-codec-headers.git"
  [amf]="https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git"
  [opus]="https://github.com/xiph/opus.git"
  [libwebp]="https://github.com/webmproject/libwebp.git"
  [zimg]="https://github.com/sekrit-twc/zimg.git"
  [freetype]="https://github.com/freetype/freetype.git"
  [harfbuzz]="https://github.com/harfbuzz/harfbuzz.git"
  [fribidi]="https://github.com/fribidi/fribidi.git"
  [libass]="https://github.com/libass/libass.git"
  [fontconfig]="https://gitlab.freedesktop.org/fontconfig/fontconfig.git"
  [libjxl]="https://github.com/libjxl/libjxl.git"
  [expat]="https://github.com/libexpat/libexpat.git"
  [brotli]="https://github.com/google/brotli.git"
  [dav1d]="https://code.videolan.org/videolan/dav1d.git"
  [svtav1hdr]="https://github.com/juliobbv-p/svt-av1-hdr.git"
  [libvpl]="https://github.com/intel/libvpl.git"
  [vapoursynth]="https://github.com/vapoursynth/vapoursynth.git"
  [VapourSynth-BM3DCUDA]="https://github.com/WolframRhodium/VapourSynth-BM3DCUDA.git"
  [x264]="https://github.com/mirror/x264.git"
  [x265]="https://github.com/videolan/x265.git"
  [vmaf]="https://github.com/Netflix/vmaf.git"
  [vvenc]="https://github.com/fraunhoferhhi/vvenc.git"
  [vvdec]="https://github.com/fraunhoferhhi/vvdec.git"
  [sdl2]="https://github.com/libsdl-org/SDL.git"
  [zlib]="https://github.com/madler/zlib.git"
  [bzip2]="https://gitlab.com/bzip2/bzip2.git"
  [lzma]="https://github.com/tukaani-project/xz.git"

  [libxml2]="https://gitlab.gnome.org/GNOME/libxml2.git"
  [libmp3lame]="https://github.com/TimothyGu/lame.git"
  [libogg]="https://github.com/xiph/ogg.git"
  [libvorbis]="https://github.com/xiph/vorbis.git"
  [libsoxr]="https://github.com/chirlu/soxr.git"
  [libaom]="http://aomedia.googlesource.com/aom"
  [libvpx]="http://chromium.googlesource.com/webm/libvpx"
  [libopenjpeg]="https://github.com/uclouvain/openjpeg.git"
  [libsrt]="https://github.com/Haivision/srt.git"
  [librist]="https://code.videolan.org/rist/librist.git"
  [libbluray]="https://code.videolan.org/videolan/libbluray.git"
  [libaribcaption]="https://github.com/xqq/libaribcaption.git"
  [lcms2]="https://github.com/mm2/Little-CMS.git"
  [librubberband]="https://github.com/breakfastquay/rubberband.git"
  [libvidstab]="https://github.com/georgmartius/vid.stab.git"
  [libshaderc]="https://github.com/google/shaderc.git"
  [libplacebo]="https://github.com/haasn/libplacebo.git"
  [vulkan-headers]="https://github.com/KhronosGroup/Vulkan-Headers.git"
  [mbedtls]="https://github.com/Mbed-TLS/mbedtls.git"
  [avisynth]="https://github.com/AviSynth/AviSynthPlus.git"
)

# Git 源码版本 Tag 匹配正则
declare -A TAG_REGEX=(
  [ffmpeg-source]='master'
  [nv-codec-headers]='^n[0-9]+(\.[0-9]+)*$'
  [amf]='^v[0-9]+(\.[0-9]+)*$'
  [opus]='^v?[0-9]+(\.[0-9]+)*$'
  [libwebp]='^v[0-9]+(\.[0-9]+)*$'
  [zimg]='^release-[0-9]+(\.[0-9]+)*$'
  [freetype]='^(VER-[0-9]+(-[0-9]+)+|freetype-[0-9]+(\.[0-9]+)*)$'
  [harfbuzz]='^v?[0-9]+(\.[0-9]+)*$'
  [fribidi]='^v?[0-9]+(\.[0-9]+)*$'
  [libass]='^v?[0-9]+(\.[0-9]+)*$'
  [fontconfig]='^[0-9]+(\.[0-9]+)*$'
  [libjxl]='^v[0-9]+(\.[0-9]+)*$'
  [expat]='^R_[0-9]+(_[0-9]+)+$'
  [brotli]='^v?[0-9]+(\.[0-9]+)*$'
  [dav1d]='^[0-9]+(\.[0-9]+)*$'
  [svtav1hdr]='^v[0-9]+(\.[0-9]+)*$'
  [libvpl]='^v2\.[0-9]+(\.[0-9]+)*$'
  [vapoursynth]='^R[0-9]+(\.[0-9]+)*$'
  [VapourSynth-BM3DCUDA]='^R[0-9]+(\.[0-9]+)*$'
  [x264]='stable|master'
  [x265]='^[0-9]+\.[0-9]+(\.[0-9]+)*$|^v[0-9]+\.[0-9]+(\.[0-9]+)*$'
  [vmaf]='^v[0-9]+(\.[0-9]+)*$'
  [vvenc]='^v[0-9]+(\.[0-9]+)*$'
  [vvdec]='^v[0-9]+(\.[0-9]+)*$'
  [sdl2]='^release-2\.[0-9]+(\.[0-9]+)*$'
  [zlib]='^v[0-9]+(\.[0-9]+)*$'
  [bzip2]='^bzip2-[0-9]+(\.[0-9]+)*$'
  [lzma]='^v[0-9]+(\.[0-9]+)*$'

  [libxml2]='^v[0-9]+(\.[0-9]+)*$'
  [libmp3lame]='master'
  [libogg]='^v?[0-9]+(\.[0-9]+)*$'
  [libvorbis]='^v?[0-9]+(\.[0-9]+)*$'
  [libsoxr]='^v?[0-9]+(\.[0-9]+)*$'
  [libaom]='^v[0-9]+(\.[0-9]+)*$'
  [libvpx]='^v[0-9]+(\.[0-9]+)*$'
  [libopenjpeg]='^v[0-9]+(\.[0-9]+)*$'
  [libsrt]='^v[0-9]+(\.[0-9]+)*$'
  [librist]='^v[0-9]+(\.[0-9]+)*$'
  [libbluray]='^[0-9]+(\.[0-9]+)*$'
  [libaribcaption]='^v[0-9]+(\.[0-9]+)*$'
  [lcms2]='^lcms[0-9]+(\.[0-9]+)*$'
  [librubberband]='^v?[0-9]+(\.[0-9]+)*$'
  [libvidstab]='^v?[0-9]+(\.[0-9]+)*$'
  [libshaderc]='^v[0-9]+\.[0-9]+$'
  [libplacebo]='^v[0-9]+(\.[0-9]+)*$'
  [vulkan-headers]='^v[0-9]+(\.[0-9]+)*$'
  [mbedtls]='^v3\.[0-9]+(\.[0-9]+)*$'
  [avisynth]='^v[0-9]+(\.[0-9]+)*$'
)

# 编译依赖阶段列表
STAGES=(
  "nv-codec-headers"
  "zlib"
  "bzip2"
  "lzma"

  "libxml2"
  "libmp3lame"
  "libogg"
  "libvorbis"
  "libsoxr"
  "libaom"
  "libvpx"
  "libopenjpeg"
  "mbedtls"
  "libsrt"
  "librist"
  "libbluray"
  "libaribcaption"
  "lcms2"
  "librubberband"
  "libvidstab"
  "libshaderc"
  "vulkan-headers"
  "libplacebo"
  "opus"
  "zimg"
  "freetype"
  "harfbuzz"
  "fribidi"
  "expat"
  "fontconfig"
  "libass"
  "libwebp"
  "brotli"
  "libjxl"
  "dav1d"
  "svtav1hdr"
  "libvpl"
  "vapoursynth"
  "VapourSynth-BM3DCUDA"
  "x264"
  "x265"
  "vmaf"
  "vvenc"
  "vvdec"
  "sdl2"
  "amf"
  "avisynth"
  "ffmpeg"
)

# ==============================================================================
# 子模块 1: 环境与工具链检测 (原 tool.sh)
# ==============================================================================
run_tool() {
  echo "===> [子命令: tool] 检测与安装构建工具链..."

  local IS_WSL=0
  if grep -qi wsl /proc/version 2>/dev/null; then
    IS_WSL=1
  fi

  local CUDA_REPO
  if [[ "$IS_WSL" == "1" ]]; then
    CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64"
  else
    local VERSION_ID="2204"
    if [ -f /etc/os-release ]; then
      VERSION_ID=$(. /etc/os-release && echo "${VERSION_ID:-22.04}" | tr -d '.')
    fi
    if [[ "$VERSION_ID" == "2404" ]]; then
      CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64"
    else
      CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64"
    fi
  fi
  local CUDA_KEYRING="${CUDA_REPO}/cuda-keyring_1.1-1_all.deb"
  local CUDA_TOOLKIT_ENABLE="${CUDA_TOOLKIT_ENABLE:-1}"

  echo "== Update apt =="
  sudo apt update
  sudo apt full-upgrade -y

  echo
  echo "== Install build toolchain =="
  sudo apt install -y --no-install-recommends \
    build-essential \
    autoconf automake libtool make cmake meson ninja-build \
    pkg-config nasm yasm xxd \
    git curl ca-certificates \
    python3 gettext autopoint gperf \
    mingw-w64 mingw-w64-tools \
    binutils-mingw-w64-x86-64 \
    gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
    gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
    mingw-w64-x86-64-dev

  if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
    echo
    echo "== Install / update latest CUDA Toolkit for WSL =="
    local tmpdeb
    tmpdeb="$(mktemp --suffix=.deb)"
    curl -fL --retry 3 -o "$tmpdeb" "$CUDA_KEYRING"
    sudo dpkg -i "$tmpdeb"
    rm -f "$tmpdeb"

    sudo apt update

    echo
    echo "== CUDA package candidate =="
    apt-cache policy cuda-toolkit || true

    echo
    echo "== Upgrade latest nvcc / CUDA Toolkit =="
    sudo apt install -y --no-install-recommends cuda-toolkit

    echo
    echo "== Configure CUDA environment =="
    if [ -d /usr/local/cuda ]; then
      sudo tee /etc/profile.d/cuda.sh >/dev/null <<'EOF'
export CUDA_HOME=/usr/local/cuda
export CUDA_PATH=/usr/local/cuda
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
EOF

      export CUDA_HOME=/usr/local/cuda
      export CUDA_PATH=/usr/local/cuda
      export PATH=/usr/local/cuda/bin:$PATH
      export LD_LIBRARY_PATH=/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    fi
  else
    echo
    echo "== Skip CUDA Toolkit =="
    echo "CUDA_TOOLKIT_ENABLE=$CUDA_TOOLKIT_ENABLE"
  fi

  echo
  echo "== Check versions =="
  echo "[MinGW GCC]"
  x86_64-w64-mingw32-gcc-posix --version | head -n 1 || true

  echo
  echo "[MinGW G++]"
  x86_64-w64-mingw32-g++-posix --version | head -n 1 || true

  echo
  echo "[CMake]"
  cmake --version | head -n 1 || true

  echo
  echo "[Meson]"
  meson --version || true

  echo
  echo "[NVCC]"
  if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
    nvcc --version || true
  else
    echo "skipped (CUDA_TOOLKIT_ENABLE=$CUDA_TOOLKIT_ENABLE)"
  fi

  echo
  echo "[NVIDIA-SMI]"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi
  elif [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    /usr/lib/wsl/lib/nvidia-smi
  else
    echo "nvidia-smi not found"
  fi

  echo
  echo "== CUDA disk usage =="
  if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
    du -sh /usr/local/cuda* 2>/dev/null || true
  else
    echo "skipped (CUDA_TOOLKIT_ENABLE=$CUDA_TOOLKIT_ENABLE)"
  fi

  echo
  echo "Toolchain check completed."
}

# ==============================================================================
# 子模块 2: 依赖源码克隆与检出 (原 update.sh)
# ==============================================================================
normalize_version() {
  local repo="$1"
  local tag="$2"

  case "$repo" in
    ffmpeg-source|nv-codec-headers)
      echo "${tag#n}"
      ;;
    zimg|sdl2)
      echo "${tag#release-}"
      ;;
    fontconfig)
      echo "${tag#upstream/}"
      ;;
    freetype)
      if [[ "$tag" == VER-* ]]; then
        echo "${tag#VER-}" | tr '-' '.'
      elif [[ "$tag" == freetype-* ]]; then
        echo "${tag#freetype-}"
      else
        echo "$tag"
      fi
      ;;
    expat)
      if [[ "$tag" == R_* ]]; then
        echo "${tag#R_}" | tr '_' '.'
      else
        echo "${tag#v}"
      fi
      ;;
    bzip2)
      echo "${tag#bzip2-}"
      ;;
    lcms2)
      echo "${tag#lcms}"
      ;;
    *)
      echo "${tag#v}"
      ;;
  esac
}

clone_if_missing() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local url="${URLS[$name]}"

  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "===> clone $name from $url"
    if [[ "$name" == "libaom" ]]; then
      mkdir -p "$repo_dir"
      local aom_ver="v3.12.0"
      echo "Downloading libaom archive $aom_ver..."
      curl -L -f -o "$repo_dir/aom.tar.gz" "https://aomedia.googlesource.com/aom/+archive/${aom_ver}.tar.gz"
      tar -C "$repo_dir" -xzf "$repo_dir/aom.tar.gz"
      rm -f "$repo_dir/aom.tar.gz"
      git -C "$repo_dir" init -b master
      git -C "$repo_dir" config user.email "build@example.com"
      git -C "$repo_dir" config user.name "Builder"
      git -C "$repo_dir" add .
      git -C "$repo_dir" commit -m "Import libaom $aom_ver"
      git -C "$repo_dir" tag "$aom_ver"
      git -C "$repo_dir" remote add origin "$url"
    elif [[ "$name" == "libvpx" ]]; then
      mkdir -p "$repo_dir"
      local vpx_ver="v1.15.0"
      echo "Downloading libvpx archive $vpx_ver..."
      curl -L -f -o "$repo_dir/vpx.tar.gz" "https://chromium.googlesource.com/webm/libvpx/+archive/${vpx_ver}.tar.gz"
      tar -C "$repo_dir" -xzf "$repo_dir/vpx.tar.gz"
      rm -f "$repo_dir/vpx.tar.gz"
      git -C "$repo_dir" init -b master
      git -C "$repo_dir" config user.email "build@example.com"
      git -C "$repo_dir" config user.name "Builder"
      git -C "$repo_dir" add .
      git -C "$repo_dir" commit -m "Import libvpx $vpx_ver"
      git -C "$repo_dir" tag "$vpx_ver"
      git -C "$repo_dir" remote add origin "$url"

    else
      git config --global http.version HTTP/1.1 || true
      git config --global http.postBuffer 1048576000 || true
      git clone --filter=blob:none "$url" "$repo_dir"
    fi
  fi
}

latest_stable_tag() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local regex="${TAG_REGEX[$name]}"

  git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/tags \
    | sed 's/\^{}$//' \
    | sort -u \
    | { grep -E "$regex" || true; } \
    | while read -r tag; do
        printf "%s\t%s\n" "$(normalize_version "$name" "$tag")" "$tag"
      done \
    | sort -V \
    | tail -n 1 \
    | cut -f2
}

sanitize_repo() {
  local repo_dir="$1"
  git -C "$repo_dir" reset --hard
  git -C "$repo_dir" clean -fdx
}

checkout_stable() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local tag="$2"
  local ver
  ver="$(normalize_version "$name" "$tag")"

  if [[ "$name" == "ffmpeg-source" ]]; then
    echo "     -> Switching $name to branch $tag..."
    git -C "$repo_dir" checkout "$tag" 2>/dev/null || git -C "$repo_dir" switch "$tag"
    git -C "$repo_dir" pull origin "$tag"
  else
    git -C "$repo_dir" switch --detach "$tag" 2>/dev/null || \
    git -C "$repo_dir" checkout --detach "$tag"
  fi

  git -C "$repo_dir" submodule update --init --recursive || true

  local commit_hash
  commit_hash="$(git -C "$repo_dir" rev-parse HEAD)"
  local remote_url
  remote_url="$(git -C "$repo_dir" remote get-url origin)"
  echo "     -> $name: source=$remote_url, ref=$tag, commit=$commit_hash"
}

update_one() {
  local name="$1"
  local repo_dir="$ROOT/$name"

  clone_if_missing "$name"

  if [[ "$name" == "libaom" || "$name" == "libvpx" ]]; then
    echo "     -> $name: source=${URLS[$name]}, ref=tarball, commit=initialized"
    return
  fi

  echo "===> sanitize $name"
  sanitize_repo "$repo_dir"

  # 强制使用 HTTPS 远程源以防 SSH 连接超时
  local url="${URLS[$name]}"
  git -C "$repo_dir" remote set-url origin "$url" 2>/dev/null || true

  echo "===> fetch $name"
  git -C "$repo_dir" fetch --tags --prune --force origin

  local tag=""
  if [[ "$name" == "ffmpeg-source" ]]; then
    tag="$FFMPEG_REF"
  else
    tag="$(latest_stable_tag "$name")"
  fi

  if [[ -z "$tag" ]]; then
    # 若无匹配 Tag，退回到 master/main 分支
    tag="master"
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$tag"; then
      tag="main"
    fi
    echo "No stable tag matched for $name, falling back to branch $tag"
  fi

  checkout_stable "$name" "$tag"
}

run_update() {
  echo "===> [子命令: update] 同步所有依赖库与 FFmpeg 源码..."
  mkdir -p "$ROOT"

  local repos=(
    ffmpeg-source
    nv-codec-headers
    amf
    opus
    libwebp
    zimg
    freetype
    harfbuzz
    fribidi
    libass
    fontconfig
    libjxl
    expat
    brotli
    dav1d
    svtav1hdr
    libvpl
    vapoursynth
    VapourSynth-BM3DCUDA
    x264
    x265
    vmaf
    vvenc
    vvdec
    sdl2
    zlib
    bzip2
    lzma

    libxml2
    libmp3lame
    libogg
    libvorbis
    libsoxr
    libaom
    libvpx
    libopenjpeg
    mbedtls
    libsrt
    librist
    libbluray
    libaribcaption
    lcms2
    librubberband
    libvidstab
    libshaderc
    libplacebo
    vulkan-headers
    avisynth
  )

  for r in "${repos[@]}"; do
    update_one "$r"
  done

  echo
  echo "All source trees are updated successfully."
}

# ==============================================================================
# 子模块 3: 库交叉编译与链接 (原 build.sh)
# ==============================================================================
normalize_stage() {
  local s="${1#--}"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    nv|nvcodec|nv-codec|nv-codec-headers|ffnvcodec) echo "nv-codec-headers" ;;
    zlib) echo "zlib" ;;
    bzip2|bzlib) echo "bzip2" ;;
    lzma|xz) echo "lzma" ;;

    libxml2|xml2) echo "libxml2" ;;
    libmp3lame|lame|mp3lame) echo "libmp3lame" ;;
    libogg|ogg) echo "libogg" ;;
    libvorbis|vorbis) echo "libvorbis" ;;
    libsoxr|soxr) echo "libsoxr" ;;
    libaom|aom) echo "libaom" ;;
    libvpx|vpx) echo "libvpx" ;;
    libopenjpeg|openjpeg) echo "libopenjpeg" ;;
    mbedtls) echo "mbedtls" ;;
    libsrt|srt) echo "libsrt" ;;
    librist|rist) echo "librist" ;;
    libbluray|bluray) echo "libbluray" ;;
    libaribcaption|aribcaption) echo "libaribcaption" ;;
    lcms2|lcms) echo "lcms2" ;;
    librubberband|rubberband) echo "librubberband" ;;
    libvidstab|vidstab) echo "libvidstab" ;;
    libshaderc|shaderc) echo "libshaderc" ;;
    vulkan-headers) echo "vulkan-headers" ;;
    libplacebo|placebo) echo "libplacebo" ;;
    opus) echo "opus" ;;
    zimg) echo "zimg" ;;
    freetype|ft) echo "freetype" ;;
    harfbuzz|hb) echo "harfbuzz" ;;
    fribidi|bidi) echo "fribidi" ;;
    expat|xml) echo "expat" ;;
    fontconfig|fc) echo "fontconfig" ;;
    libass|ass) echo "libass" ;;
    libwebp|webp) echo "libwebp" ;;
    brotli) echo "brotli" ;;
    libjxl|jxl) echo "libjxl" ;;
    dav1d) echo "dav1d" ;;
    svtav1hdr|svtav1|svt-av1|svt) echo "svtav1hdr" ;;
    libvpl|vpl) echo "libvpl" ;;
    vapoursynth|vs) echo "vapoursynth" ;;
    vapoursynth-bm3dcuda|bm3dcuda|bm3d) echo "VapourSynth-BM3DCUDA" ;;
    x264) echo "x264" ;;
    x265) echo "x265" ;;
    vmaf) echo "vmaf" ;;
    vvenc) echo "vvenc" ;;
    vvdec) echo "vvdec" ;;
    sdl2) echo "sdl2" ;;
    amf) echo "amf" ;;
    avisynth) echo "avisynth" ;;
    ffmpeg) echo "ffmpeg" ;;
    *) return 1 ;;
  esac
}

on_error() {
  local exit_code=$?
  FAILED_STAGE="${CURRENT_STAGE:-unknown}"
  echo
  echo "============================================================"
  echo "构建失败"
  echo "失败阶段: $FAILED_STAGE"
  echo "退出码: $exit_code"
  if [[ "${FULL_BUILD:-1}" -eq 1 && "$FAILED_STAGE" != "unknown" ]]; then
    local hint="$FAILED_STAGE"
    echo "修复后可从该阶段继续："
    echo "  ./ffmpeg.sh build --$hint"
  fi
  echo "============================================================"
  exit "$exit_code"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令: $1"
    exit 1
  }
}

need_repo() {
  local name="$1"
  [[ -d "$ROOT/$name" ]] || {
    echo "缺少源码目录: $ROOT/$name"
    echo "请先运行 ./ffmpeg.sh update"
    exit 1
  }
}

canonical_tool() {
  local val="$1"
  if [[ -z "$val" ]]; then
    return 1
  fi
  if [[ "$val" == */* ]]; then
    [[ -x "$val" ]] || {
      echo "工具不存在或不可执行: $val"
      exit 1
    }
    printf '%s\n' "$val"
  else
    command -v "$val" >/dev/null 2>&1 || {
      echo "找不到工具: $val"
      exit 1
    }
    command -v "$val"
  fi
}

need_meson_min() {
  local req="$1"
  local have
  have="$(meson --version)"
  if ! python3 - "$have" "$req" <<'PY'
import sys
from packaging.version import Version
sys.exit(0 if Version(sys.argv[1].strip()) >= Version(sys.argv[2].strip()) else 1)
PY
  then
    echo "Meson 版本过低: 当前 $have，需要 >= $req"
    echo '可先执行: python3 -m pip install --user -U meson packaging'
    echo '并确保 ~/.local/bin 在 PATH 前面'
    exit 1
  fi
}

is_valid_cuda() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  # 检查 cuda.h
  local found_cuda=0
  for h in "$dir/include/cuda.h" "$dir/targets/x86_64-linux/include/cuda.h"; do
    [[ -f "$h" ]] && found_cuda=1
  done
  [[ "$found_cuda" == "1" ]] || return 1
  # 检查 nvrtc.h
  local found_nvrtc=0
  for h in "$dir/include/nvrtc.h" "$dir/targets/x86_64-linux/include/nvrtc.h"; do
    [[ -f "$h" ]] && found_nvrtc=1
  done
  [[ "$found_nvrtc" == "1" ]] || return 1
  return 0
}

find_cuda_home() {
  if is_valid_cuda "$CUDA_REDIST_ROOT"; then
    CUDA_HOME="$CUDA_REDIST_ROOT"
    return 0
  fi

  if [[ -n "$CUDA_HOME" ]]; then
    is_valid_cuda "$CUDA_HOME" || {
      echo "CUDA_HOME 缺少头文件(cuda.h/nvrtc.h): $CUDA_HOME"
      exit 1
    }
    return 0
  fi

  if is_valid_cuda "/usr/local/cuda"; then
    CUDA_HOME="/usr/local/cuda"
    return 0
  fi

  local dir
  for dir in $(find /usr/local -maxdepth 1 -type d -name 'cuda-*' 2>/dev/null | sort -V -r); do
    if is_valid_cuda "$dir"; then
      CUDA_HOME="$dir"
      return 0
    fi
  done

  echo "未找到完整的 CUDA Toolkit（需要 cuda.h 和 nvrtc.h）。请检查 /usr/local/cuda"
  exit 1
}

setup_cuda() {
  if [[ "$CUDA_ENABLE" != "1" ]]; then
    echo "CUDA 支持已禁用: CUDA_ENABLE=$CUDA_ENABLE"
    return 0
  fi

  find_cuda_home
  export CUDA_HOME
  export PATH="$CUDA_HOME/bin:$PATH"

  if [[ -z "$NVCC" ]]; then
    NVCC="$CUDA_HOME/bin/nvcc"
  fi
  NVCC="$(canonical_tool "$NVCC")"

  [[ -f "$CUDA_HOME/include/cuda.h" ]] || {
    echo "缺少 CUDA 头文件: $CUDA_HOME/include/cuda.h"
    exit 1
  }

  "$NVCC" --version >/dev/null || {
    echo "nvcc 无法运行: $NVCC"
    exit 1
  }

  export NVCC
}

make_nvccflags() {
  local flags="$NVCC_GENCODE_FLAGS $NVCC_OPTFLAGS"
  if [[ -n "$NVCC_THREADS" ]]; then
    flags+=" --threads=$NVCC_THREADS"
  fi
  if [[ -n "$NVCC_PTXAS_FLAGS" ]]; then
    flags+=" -Xptxas=$NVCC_PTXAS_FLAGS"
  fi
  if [[ "$NVCC_FAST_MATH" == "1" ]]; then
    flags+=" --use_fast_math"
  fi
  printf '%s\n' "$flags"
}

stage_src() {
  local name="$1"
  local src="$ROOT/$name"
  local stage="$BUILDROOT/_src/$name"
  rm -rf "$stage"
  mkdir -p "$(dirname "$stage")"
  cp -a "$src" "$stage"
  echo "$stage"
}

meson_quote_array() {
  local flags="$1"
  local arr=()
  local f
  read -r -a arr <<< "$flags"
  printf '['
  local first=1
  for f in "${arr[@]}"; do
    [[ -z "$f" ]] && continue
    f="${f//\\/\\\\}"
    f="${f//\'/\\\'}"
    if [[ "$first" -eq 0 ]]; then
      printf ', '
    fi
    printf "'%s'" "$f"
    first=0
  done
  printf ']'
}

write_meson_cross() {
  local meson_lto=false
  [[ "$LTO_ENABLE" == "1" ]] && meson_lto=true

  cat > "$BUILDROOT/mingw-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
windres = '$WINDRES'
pkg-config = '$PKG_CONFIG'
dlltool = '$DLLTOOL'

[built-in options]
c_args = $(meson_quote_array "$CFLAGS -I$PREFIX/include")
cpp_args = $(meson_quote_array "$CXXFLAGS -I$PREFIX/include")
c_link_args = $(meson_quote_array "$LDFLAGS -L$PREFIX/lib")
cpp_link_args = $(meson_quote_array "$LDFLAGS -L$PREFIX/lib")
optimization = '3'
b_lto = $meson_lto

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
}

build_autotools() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"

  pushd "$stage" >/dev/null

  if [[ ! -x ./configure ]]; then
    if [[ -x ./autogen.sh ]]; then
      ./autogen.sh
    elif [[ -f ./bootstrap ]]; then
      ./bootstrap
    elif [[ -f configure.ac || -f configure.in ]]; then
      autoreconf -fiv
    fi
  fi

  ./configure \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    "$@"

  make -j"$JOBS"
  make install
  popd >/dev/null
}

build_cmake() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"
  local bld="$BUILDROOT/$name"
  local ipo=OFF
  [[ "$LTO_ENABLE" == "1" ]] && ipo=ON

  rm -rf "$bld"

  cmake -S "$stage" -B "$bld" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_RC_COMPILER="$WINDRES" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS_RELEASE="$CFLAGS" \
    -DCMAKE_CXX_FLAGS_RELEASE="$CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION="$ipo" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "$@"

  cmake --build "$bld" --parallel "$JOBS"
  cmake --install "$bld"
}

build_meson() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"
  local bld="$BUILDROOT/$name"

  rm -rf "$bld"

  meson setup "$bld" "$stage" \
    --cross-file "$BUILDROOT/mingw-cross.txt" \
    --prefix "$PREFIX" \
    --buildtype release \
    --default-library=static \
    -Doptimization=3 \
    "$@"

  meson compile -C "$bld" -j "$JOBS"
  meson install -C "$bld"
}

setup_build_env() {
  export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"

  need_cmd python3
  need_cmd git
  need_cmd cmake
  need_cmd meson
  need_cmd ninja
  need_cmd make
  need_cmd autoreconf
  need_cmd pkg-config

  CC="$(canonical_tool "${CC:-${TARGET}-gcc-posix}")"
  CXX="$(canonical_tool "${CXX:-${TARGET}-g++-posix}")"
  AR="$(canonical_tool "${AR:-${TARGET}-ar}")"
  RANLIB="$(canonical_tool "${RANLIB:-${TARGET}-ranlib}")"
  STRIP="$(canonical_tool "${STRIP:-${TARGET}-strip}")"
  WINDRES="$(canonical_tool "${WINDRES:-${TARGET}-windres}")"
  PKG_CONFIG="$(canonical_tool "${PKG_CONFIG:-pkg-config}")"
  DLLTOOL="$(canonical_tool "${DLLTOOL:-${TARGET}-dlltool}")"

  export CC CXX AR RANLIB STRIP WINDRES PKG_CONFIG DLLTOOL
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

  # 优化参数整合
  COMMON_OPT_FLAGS="$OPT_CFLAGS_BASE"
  if [[ "$INLINE_ENABLE" == "1" ]]; then
    COMMON_OPT_FLAGS+=" $INLINE_FLAGS"
  fi
  if [[ -n "$CPU_FLAGS" ]]; then
    COMMON_OPT_FLAGS+=" $CPU_FLAGS"
  fi
  if [[ "$SECTION_GC_ENABLE" == "1" ]]; then
    COMMON_OPT_FLAGS+=" -ffunction-sections -fdata-sections"
    LDFLAGS_BASE="-Wl,--gc-sections"
  else
    LDFLAGS_BASE=""
  fi
  if [[ "$LTO_ENABLE" == "1" ]]; then
    COMMON_OPT_FLAGS+=" $LTO_FLAGS"
    LDFLAGS_BASE+=" $LTO_FLAGS"
  fi

  export CFLAGS="${CFLAGS:-$COMMON_OPT_FLAGS}"
  export CXXFLAGS="${CXXFLAGS:-$COMMON_OPT_FLAGS}"
  export LDFLAGS="${LDFLAGS:-$LDFLAGS_BASE}"

  mkdir -p "$BUILDROOT"
  write_meson_cross
}

run_stage() {
  local stage="$1"
  CURRENT_STAGE="$stage"
  echo "===> $stage"

  case "$stage" in
    nv-codec-headers)
      local nv_stage
      nv_stage="$(stage_src "nv-codec-headers")"
      rm -f "$nv_stage/ffnvcodec.pc"
      make -C "$nv_stage" PREFIX="$PREFIX"
      make -C "$nv_stage" PREFIX="$PREFIX" install

      [[ -f "$PREFIX/lib/pkgconfig/ffnvcodec.pc" ]] || {
        echo "nv-codec-headers 安装后未找到: $PREFIX/lib/pkgconfig/ffnvcodec.pc"
        exit 1
      }

      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "pkg-config 无法识别 ffnvcodec"
        exit 1
      }
      ;;

    zlib)
      local stage
      stage="$(stage_src "zlib")"
      local bld="$BUILDROOT/zlib"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      # zlib CMake 在 Windows 下安装为 libzlibstatic.a，必须创建 libz.a 以兼容下游依赖
      local zlib_static=""
      for name in libzlibstatic.a libzlib.a libzs.a libz.a; do
        if [[ -f "$PREFIX/lib/$name" ]]; then
          zlib_static="$PREFIX/lib/$name"
          break
        fi
      done
      if [[ -n "$zlib_static" && "$zlib_static" != "$PREFIX/lib/libz.a" ]]; then
        cp -f "$zlib_static" "$PREFIX/lib/libz.a"
        echo "zlib: created $PREFIX/lib/libz.a from $zlib_static"
      fi
      # 强制移除动态库，防止下游依赖动态链接
      rm -f "$PREFIX/bin/libz.dll" "$PREFIX/bin/libzlib.dll" \
             "$PREFIX/lib/libzlib.dll.a" "$PREFIX/lib/libz.dll.a" 2>/dev/null || true
      ;;

    bzip2)
      local stage
      stage="$(stage_src "bzip2")"
      pushd "$stage" >/dev/null
      rm -f *.o *.a
      "$CC" -O3 -c blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
      "$AR" rcs libbz2.a blocksort.o huffman.o crctable.o randtable.o compress.o decompress.o bzlib.o
      "$RANLIB" libbz2.a
      mkdir -p "$PREFIX/include" "$PREFIX/lib"
      cp -f bzlib.h "$PREFIX/include/"
      cp -f libbz2.a "$PREFIX/lib/"
      popd >/dev/null
      ;;

    lzma)
      local stage
      stage="$(stage_src "lzma")"
      local bld="$BUILDROOT/lzma"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_NLS=OFF \
        -DENABLE_THREADS=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      # 强制手动复制头文件以防止交叉编译下 CMake 部署 0 字节文件
      mkdir -p "$PREFIX/include/lzma"
      cp -f "$stage/src/liblzma/api/lzma.h" "$PREFIX/include/"
      cp -rf "$stage/src/liblzma/api/lzma/"* "$PREFIX/include/lzma/"
      # 强制生成正确的 liblzma.pc 以防止 CMake 在交叉编译下输出 0 字节文件
      mkdir -p "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/liblzma.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: liblzma
Description: General purpose data compression library
URL: https://tukaani.org/xz/
Version: 5.8.3
Cflags: -I\${includedir}
Cflags.private: -DLZMA_API_STATIC
Libs: -L\${libdir} -llzma
Libs.private:
EOF
      ;;



    libxml2)
      local stage
      stage="$(stage_src "libxml2")"
      local bld="$BUILDROOT/libxml2"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLIBXML2_WITH_PYTHON=OFF \
        -DLIBXML2_WITH_LZMA=ON \
        -DLIBXML2_WITH_ZLIB=ON \
        -DLIBXML2_WITH_ICONV=OFF \
        -DLIBXML2_WITH_ICU=OFF \
        -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="$PREFIX/include" \
        -DLibLZMA_LIBRARY="$PREFIX/lib/liblzma.a" \
        -DLibLZMA_INCLUDE_DIR="$PREFIX/include" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;


    libmp3lame)
      build_autotools libmp3lame --disable-frontend --disable-nls
      ;;

    libogg)
      local stage
      stage="$(stage_src "libogg")"
      local bld="$BUILDROOT/libogg"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    libvorbis)
      local stage
      stage="$(stage_src "libvorbis")"
      local bld="$BUILDROOT/libvorbis"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DOGG_ROOT="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    libsoxr)
      local stage
      stage="$(stage_src "libsoxr")"
      local bld="$BUILDROOT/libsoxr"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWITH_OPENMP=OFF \
        -DBUILD_TESTS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      # 即使在 Windows 目标下也强制安装 soxr.pc 以便 pkg-config 校验
      mkdir -p "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/soxr.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: soxr
Description: High quality, one-dimensional sample-rate conversion library
Version: 0.1.3
Libs: -L\${libdir} -lsoxr
Cflags: -I\${includedir}
EOF
      ;;

    libaom)
      local stage
      stage="$(stage_src "libaom")"
      local bld="$BUILDROOT/libaom"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_TOOLS=OFF \
        -DENABLE_DOCS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    libvpx)
      local stage
      stage="$(stage_src "libvpx")"
      pushd "$stage" >/dev/null
      ./configure \
        --target=x86_64-win64-gcc \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-examples \
        --disable-unit-tests \
        --disable-tools \
        --disable-docs \
        --as=yasm \
        --enable-vp9-highbitdepth
      make -j"$JOBS"
      make install
      popd >/dev/null
      ;;

    libopenjpeg)
      local stage
      stage="$(stage_src "libopenjpeg")"
      local bld="$BUILDROOT/libopenjpeg"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_CODEC=OFF \
        -DBUILD_TESTING=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    mbedtls)
      local stage
      stage="$(stage_src "mbedtls")"
      local bld="$BUILDROOT/mbedtls"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_TESTING=OFF \
        -DENABLE_PROGRAMS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    libsrt)
      local stage
      stage="$(stage_src "libsrt")"
      local bld="$BUILDROOT/libsrt"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_SHARED=OFF \
        -DENABLE_STATIC=ON \
        -DUSE_ENCLIB=mbedtls \
        -DMBEDTLS_ROOT_DIR="$PREFIX" \
        -DMBEDTLS_INCLUDE_DIR="$PREFIX/include" \
        -DMBEDTLS_LIBRARY="$PREFIX/lib/libmbedtls.a" \
        -DMBEDX509_LIBRARY="$PREFIX/lib/libmbedx509.a" \
        -DMBEDCRYPTO_LIBRARY="$PREFIX/lib/libmbedcrypto.a" \
        -DCMAKE_INCLUDE_PATH="$PREFIX/include" \
        -DENABLE_APPS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      # 修复 srt.pc 和 haisrt.pc 中 mbedtls 的绝对路径导致 static 链接顺序错误的 Bug
      if [[ -f "$PREFIX/lib/pkgconfig/srt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/srt.pc"
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/srt.pc"
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/srt.pc"
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/haisrt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/haisrt.pc"
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/haisrt.pc"
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/haisrt.pc"
      fi
      ;;

    librist)
      local stage
      stage="$(stage_src "librist")"
      local bld="$BUILDROOT/librist"
      rm -rf "$bld"
      meson setup "$bld" "$stage" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
        --prefix "$PREFIX" \
        --buildtype release \
        --default-library=static \
        -Dbuilt_tools=false \
        -Dtest=false
      meson compile -C "$bld" -j "$JOBS"
      meson install -C "$bld"
      ;;


    libbluray)
      build_meson libbluray -Denable_examples=false -Dbdj_jar=disabled -Denable_tools=false
      ;;


    libaribcaption)
      local stage
      stage="$(stage_src "libaribcaption")"
      local bld="$BUILDROOT/libaribcaption"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DARIBCAPTION_SHARED=OFF \
        -DARIBCAPTION_STATIC=ON \
        -DARIBCAPTION_WITH_FREETYPE=ON \
        -DARIBCAPTION_WITH_FONTCONFIG=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    lcms2)
      local stage
      stage="$(stage_src "lcms2")"
      local bld="$BUILDROOT/lcms2"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DLCMS2_BUILD_SHARED=OFF \
        -DLCMS2_BUILD_STATIC=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    librubberband)
      local stage
      stage="$(stage_src "librubberband")"
      local bld="$BUILDROOT/librubberband"
      rm -rf "$bld"
      meson setup "$bld" "$stage" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
        --prefix "$PREFIX" \
        --buildtype release \
        --default-library=static \
        -Dfft=builtin \
        -Dresampler=builtin \
        -Dtests=disabled
      meson compile -C "$bld" -j "$JOBS"
      meson install -C "$bld"
      ;;

    libvidstab)
      local stage
      stage="$(stage_src "libvidstab")"
      local bld="$BUILDROOT/libvidstab"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    libshaderc)
      local stage
      stage="$(stage_src "libshaderc")"
      pushd "$stage" >/dev/null
      if [ ! -d third_party/glslang ]; then
        python3 utils/git-sync-deps
      fi
      popd >/dev/null

      local bld="$BUILDROOT/libshaderc"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DSHADERC_ENABLE_SHARED_CRT=ON \
        -DSHADERC_SKIP_TESTS=ON \
        -DSHADERC_SKIP_EXAMPLES=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    vulkan-headers)
      local stage
      stage="$(stage_src "vulkan-headers")"
      mkdir -p "$PREFIX/include"
      cp -rf "$stage/include/"* "$PREFIX/include/"
      ;;

    libplacebo)
      local stage
      stage="$(stage_src "libplacebo")"
      local bld="$BUILDROOT/libplacebo"
      rm -rf "$bld"
      meson setup "$bld" "$stage" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
        --prefix "$PREFIX" \
        --buildtype release \
        --default-library=static \
        -Ddemos=false \
        -Dtests=false \
        -Dvulkan=enabled \
        -Dshaderc=enabled \
        -Dopengl=disabled \
        -Dlcms=enabled
      meson compile -C "$bld" -j "$JOBS"
      meson install -C "$bld"
      ;;

    opus)
      build_autotools opus
      ;;

    zimg)
      build_autotools zimg --disable-openmp
      ;;

    freetype)
      build_cmake freetype \
        -DFT_DISABLE_ZLIB=TRUE \
        -DFT_DISABLE_BZIP2=TRUE \
        -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_BROTLI=TRUE \
        -DFT_DISABLE_HARFBUZZ=TRUE
      ;;

    harfbuzz)
      build_meson harfbuzz \
        -Ddocs=disabled \
        -Dtests=disabled \
        -Dbenchmark=disabled \
        -Dutilities=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dintrospection=disabled \
        -Dfreetype=enabled
      ;;

    fribidi)
      build_meson fribidi \
        -Ddocs=false \
        -Dbin=false \
        -Dtests=false
      ;;

    expat)
      local expat_stage
      expat_stage="$(stage_src "expat")"
      rm -rf "$BUILDROOT/expat"
      cmake -S "$expat_stage/expat" -B "$BUILDROOT/expat" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DEXPAT_BUILD_DOCS=OFF \
        -DEXPAT_BUILD_EXAMPLES=OFF \
        -DEXPAT_BUILD_TESTS=OFF \
        -DEXPAT_BUILD_TOOLS=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$BUILDROOT/expat" --parallel "$JOBS"
      cmake --install "$BUILDROOT/expat"
      ;;

    fontconfig)
      need_meson_min 1.6.1
      build_meson fontconfig \
        -Ddoc=disabled \
        -Dnls=disabled \
        -Dtests=disabled \
        -Dtools=disabled
      ;;

    libass)
      build_autotools libass

      [[ -f "$PREFIX/lib/pkgconfig/libass.pc" ]] || {
        echo "libass 安装后未找到: $PREFIX/lib/pkgconfig/libass.pc"
        exit 1
      }

      PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists 'libass >= 0.11.0' || {
        echo "pkg-config 无法识别交叉编译版 libass"
        exit 1
      }
      ;;

    libwebp)
      build_cmake libwebp \
        -DWEBP_BUILD_CWEBP=OFF \
        -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF \
        -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF \
        -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_ANIM_UTILS=OFF
      ;;

    brotli)
      build_cmake brotli \
        -DBROTLI_BUILD_TOOLS=OFF
      ;;

    libjxl)
      local jxl_stage
      jxl_stage="$(stage_src "libjxl")"
      pushd "$jxl_stage" >/dev/null
      git submodule set-url third_party/highway https://github.com/google/highway.git 2>/dev/null || true
      git submodule set-url third_party/skcms   https://github.com/google/skcms.git   2>/dev/null || true
      git submodule update --init --depth 1 --recommend-shallow \
        third_party/highway \
        third_party/skcms || true
      popd >/dev/null

      rm -rf "$BUILDROOT/libjxl"
      cmake -S "$jxl_stage" -B "$BUILDROOT/libjxl" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DJPEGXL_TEST_TOOLS=OFF \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
        -DJPEGXL_STATIC=ON \
        -DJPEGXL_ENABLE_TOOLS=OFF \
        -DJPEGXL_ENABLE_DEVTOOLS=OFF \
        -DJPEGXL_ENABLE_DOXYGEN=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF \
        -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_JNI=OFF \
        -DJPEGXL_ENABLE_SJPEG=OFF \
        -DJPEGXL_ENABLE_OPENEXR=OFF \
        -DJPEGXL_ENABLE_VIEWERS=OFF \
        -DJPEGXL_ENABLE_PLUGINS=OFF \
        -DJPEGXL_ENABLE_JPEGLI=OFF \
        -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF \
        -DJPEGXL_ENABLE_SKCMS=ON \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$BUILDROOT/libjxl" --parallel "$JOBS"
      cmake --install "$BUILDROOT/libjxl"
      if [[ -f "$PREFIX/lib/pkgconfig/libjxl_threads.pc" ]]; then
        sed -i 's/^Libs.private: -lm$/Libs.private: -lm -lwinpthread/' \
          "$PREFIX/lib/pkgconfig/libjxl_threads.pc"
      fi
      ;;

    dav1d)
      build_meson dav1d \
        -Denable_tools=false \
        -Denable_tests=false \
        -Denable_examples=false \
        -Denable_asm=true
      ;;

    svtav1hdr)
      build_cmake svtav1hdr \
        -DENABLE_AVX512=ON \
        -DBUILD_DEC=ON \
        -DBUILD_ENC=ON \
        -DBUILD_SHARED_LIBS=OFF
      ;;

    libvpl)
      build_cmake libvpl \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DINSTALL_EXAMPLES=OFF \
        -DENABLE_WARNINGS=OFF
      ;;

    vapoursynth)
      local vs_stage
      vs_stage="$(stage_src "vapoursynth")"
      mkdir -p "$PREFIX/include"
      cp -f "$vs_stage/include/VapourSynth.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VapourSynth4.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSScript4.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSHelper.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSHelper4.h" "$PREFIX/include/"

      mkdir -p "$PREFIX/include/vapoursynth"
      cp -f "$vs_stage/include/VapourSynth.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VapourSynth4.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSScript4.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSHelper.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSHelper4.h" "$PREFIX/include/vapoursynth/"

      # 动态生成 .pc 规避 FFmpeg 检测
      mkdir -p "$PREFIX/lib/pkgconfig"
      cat > "$PREFIX/lib/pkgconfig/vapoursynth.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: vapoursynth
Description: VapourSynth scripting library
Version: 77
Libs:
Cflags: -I\${includedir}
EOF
      cp -f "$PREFIX/lib/pkgconfig/vapoursynth.pc" "$PREFIX/lib/pkgconfig/VapourSynth.pc"
      ;;

    VapourSynth-BM3DCUDA)
      local vs_stage
      vs_stage="$(stage_src "VapourSynth-BM3DCUDA")"
      local bld="$BUILDROOT/VapourSynth-BM3DCUDA"
      rm -rf "$bld"
      mkdir -p "$bld"
      mkdir -p "$PREFIX/bin"  # 确保 bin 文件夹存在
      pushd "$bld" >/dev/null

      echo "==> Generating CUDA/NVRTC stub import libraries"
      cat > cuda.def <<'EOF'
LIBRARY nvcuda
EXPORTS
cuInit
cuDeviceGet
cuDeviceGetCount
cuDeviceGetAttribute
cuDevicePrimaryCtxRetain
cuDevicePrimaryCtxRelease
cuDevicePrimaryCtxRelease_v2
cuCtxPushCurrent
cuCtxPushCurrent_v2
cuCtxPopCurrent
cuCtxPopCurrent_v2
cuMemAlloc
cuMemAlloc_v2
cuMemAllocPitch
cuMemAllocPitch_v2
cuMemAllocHost
cuMemAllocHost_v2
cuMemFree
cuMemFree_v2
cuMemFreeHost
cuModuleLoadData
cuModuleUnload
cuModuleGetFunction
cuStreamCreate
cuStreamDestroy
cuStreamDestroy_v2
cuStreamSynchronize
cuGetErrorString
cuGraphCreate
cuGraphDestroy
cuGraphAddKernelNode
cuGraphAddKernelNode_v2
cuGraphAddMemcpyNode
cuGraphAddMemsetNode
cuGraphInstantiate
cuGraphInstantiateWithFlags
cuGraphLaunch
cuGraphExecDestroy
EOF
      "$TARGET-dlltool" -d cuda.def -l libcuda.a

      cat > nvrtc.def <<'EOF'
LIBRARY nvrtc
EXPORTS
nvrtcCompileProgram
nvrtcCreateProgram
nvrtcDestroyProgram
nvrtcGetCUBIN
nvrtcGetCUBINSize
nvrtcGetErrorString
nvrtcGetNumSupportedArchs
nvrtcGetProgramLog
nvrtcGetProgramLogSize
nvrtcGetPTX
nvrtcGetPTXSize
nvrtcGetSupportedArchs
EOF
      "$TARGET-dlltool" -d nvrtc.def -l libnvrtc.a

      echo "==> Compiling VapourSynth-BM3DCPU"
      "$CXX" -shared -O3 -std=c++20 -static-libgcc -static-libstdc++ -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic $CXXFLAGS \
        -I"$PREFIX/include" \
        "$vs_stage/cpu_source/source.cpp" \
        -o "$PREFIX/bin/bm3dcpu.dll"

      if [[ "$CUDA_ENABLE" == "1" ]]; then
        setup_cuda
        echo "==> Compiling VapourSynth-BM3DCUDA_RTC"
        "$CXX" -shared -O3 -std=c++20 -static-libgcc -static-libstdc++ -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic $CXXFLAGS \
          -I"$PREFIX/include" -I"$CUDA_HOME/include" -I"$CUDA_HOME/targets/x86_64-linux/include" \
          "$vs_stage/rtc_source/source.cpp" \
          -L. -lcuda -lnvrtc -lws2_32 \
          -o "$PREFIX/bin/bm3dcuda_rtc.dll"
      fi

      popd >/dev/null

      mkdir -p "$PREFIX/bin/plugins"
      cp -f "$PREFIX/bin/bm3dcpu.dll" "$PREFIX/bin/plugins/" 2>/dev/null || true
      if [[ "$CUDA_ENABLE" == "1" ]]; then
        cp -f "$PREFIX/bin/bm3dcuda_rtc.dll" "$PREFIX/bin/plugins/" 2>/dev/null || true
      fi
      ;;

    x264)
      local stage
      stage="$(stage_src "x264")"
      pushd "$stage" >/dev/null
      make distclean 2>/dev/null || true
      ./configure \
        --host="$TARGET" \
        --cross-prefix="$TARGET-" \
        --prefix="$PREFIX" \
        --enable-static \
        --enable-pic \
        --disable-cli \
        --extra-cflags="$CFLAGS" \
        --extra-ldflags="$LDFLAGS"
      make -j"$JOBS"
      make install
      popd >/dev/null
      ;;

    x265)
      local stage
      stage="$(stage_src "x265")/source"
      # 修复 CMake 4.x 下 CMP0025 和 CMP0054 的 OLD 行为被废弃的报错
      sed -i 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/g' "$stage/CMakeLists.txt"
      sed -i 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/g' "$stage/CMakeLists.txt"
      local bld="$BUILDROOT/x265"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    vmaf)
      local stage
      stage="$(stage_src "vmaf")/libvmaf"
      local bld="$BUILDROOT/vmaf"
      rm -rf "$bld"

      local extra_opts=("-Denable_cuda=false")

      meson setup "$bld" "$stage" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
        --prefix "$PREFIX" \
        --buildtype release \
        --default-library=static \
        -Doptimization=3 \
        -Dbuilt_in_models=true \
        -Denable_tests=false \
        -Denable_asm=true \
        "${extra_opts[@]}"

      meson compile -C "$bld" -j "$JOBS"
      meson install -C "$bld"
      ;;

    vvenc)
      local stage
      stage="$(stage_src "vvenc")"
      local bld="$BUILDROOT/vvenc"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DVVENC_ENABLE_LINK_TIME_OPT=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    vvdec)
      local stage
      stage="$(stage_src "vvdec")"
      local bld="$BUILDROOT/vvdec"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DVVDEC_ENABLE_LINK_TIME_OPT=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    sdl2)
      local stage
      stage="$(stage_src "sdl2")"
      local bld="$BUILDROOT/sdl2"
      rm -rf "$bld"
      cmake -S "$stage" -B "$bld" -G Ninja \
        -DCMAKE_SYSTEM_NAME=Windows \
        -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_RC_COMPILER="$WINDRES" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_RANLIB="$RANLIB" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DBUILD_SHARED_LIBS=OFF \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_TEST=OFF \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      cmake --build "$bld" --parallel "$JOBS"
      cmake --install "$bld"
      ;;

    amf)
      # AMD AMF SDK 仅需复制头文件即可使用
      local stage
      stage="$(stage_src "amf")"
      mkdir -p "$PREFIX/include/AMF"
      cp -rf "$stage/amf/public/include/"* "$PREFIX/include/AMF/"
      echo "AMF Headers successfully copied to $PREFIX/include/AMF/"
      ;;

    avisynth)
      # AviSynth+ 仅需要复制其 C 头文件即可使用
      local stage
      stage="$(stage_src "avisynth")"
      mkdir -p "$PREFIX/include/avisynth/avs"
      cp -rf "$stage/avs_core/include/avisynth_c.h" "$PREFIX/include/avisynth/"
      cp -rf "$stage/avs_core/include/avs/"* "$PREFIX/include/avisynth/avs/"
      
      # 动态生成 avs/version.h 以便满足 FFmpeg 版本的 CPP 校验
      cat > "$PREFIX/include/avisynth/avs/version.h" <<'EOF'
#ifndef _AVS_VERSION_H_
#define _AVS_VERSION_H_

#define       AVS_PPSTR_(x)    	#x
#define       AVS_PPSTR(x)    	AVS_PPSTR_(x)

#define       AVS_PROJECT       AviSynth+
#define       AVS_MAJOR_VER     3
#define       AVS_MINOR_VER     7
#define       AVS_BUGFIX_VER    3
#define       RELEASE_TARBALL
#define       AVS_FULLVERSION	AVS_PPSTR(AVS_PROJECT) " " AVS_PPSTR(AVS_MAJOR_VER) "." AVS_PPSTR(AVS_MINOR_VER) "." AVS_PPSTR(AVS_BUGFIX_VER) " (x86_64)"

#endif  //  _AVS_VERSION_H_
EOF
      echo "AviSynth Headers successfully copied to $PREFIX/include/avisynth/"
      ;;

    ffmpeg)
      # 自动修复 srt.pc 和 haisrt.pc 中可能存在的 mbedtls 绝对路径导致 static 链接失败的 Bug
      if [[ -f "$PREFIX/lib/pkgconfig/srt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || true
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/haisrt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/haisrt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/haisrt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/haisrt.pc" 2>/dev/null || true
      fi

      local ff_stage
      ff_stage="$(stage_src "ffmpeg-source")"
      pushd "$ff_stage" >/dev/null
      rm -f config.h config.mak config.log

      # 前置依赖校验
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "缺少 ffnvcodec，请先编译 nv-codec-headers 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists SvtAv1Enc || {
        echo "缺少 SvtAv1Enc，请先编译 svtav1hdr 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists x264 || {
        echo "缺少 x264，请先编译 x264 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists x265 || {
        echo "缺少 x265，请先编译 x265 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libvmaf || {
        echo "缺少 vmaf，请先编译 vmaf 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libvvenc || {
        echo "缺少 vvenc，请先编译 vvenc 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists sdl2 || {
        echo "缺少 sdl2，请先编译 sdl2 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libxml-2.0 || {
        echo "缺少 libxml2，请先编译 libxml2 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ogg vorbis || {
        echo "缺少 ogg/vorbis，请先编译 libvorbis 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists soxr || {
        echo "缺少 soxr，请先编译 libsoxr 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists aom || {
        echo "缺少 aom，请先编译 libaom 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vpx || {
        echo "缺少 vpx，请先编译 libvpx 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libopenjp2 || {
        echo "缺少 openjpeg，请先编译 libopenjpeg 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists srt || {
        echo "缺少 srt，请先编译 libsrt 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists librist || {
        echo "缺少 rist，请先编译 librist 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libbluray || {
        echo "缺少 libbluray，请先编译 libbluray 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libaribcaption || {
        echo "缺少 libaribcaption，请先编译 libaribcaption 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists lcms2 || {
        echo "缺少 lcms2，请先编译 lcms2 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists rubberband || {
        echo "缺少 rubberband，请先编译 librubberband 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vidstab || {
        echo "缺少 vidstab，请先编译 libvidstab 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists shaderc || {
        echo "缺少 shaderc，请先编译 libshaderc 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libplacebo || {
        echo "缺少 libplacebo，请先编译 libplacebo 阶段"
        exit 1
      }
      [[ -f "$PREFIX/include/AMF/core/Version.h" ]] || {
        echo "缺少 AMF 头文件，请先编译 amf 阶段"
        exit 1
      }
      [[ -f "$PREFIX/include/avisynth/avisynth_c.h" && -f "$PREFIX/include/avisynth/avs/version.h" ]] || {
        echo "缺少 AviSynth 头文件，请先编译 avisynth 阶段"
        exit 1
      }

      local extra_cflags="-I$PREFIX/include"
      local extra_ldflags="-L$PREFIX/lib -Wl,--allow-multiple-definition $LDFLAGS"
      local extra_libs="-lstdc++ -lgcc"
      local cuda_flags=()

      if [[ "$CUDA_ENABLE" == "1" ]]; then
        setup_cuda
        extra_cflags+=" -I$CUDA_HOME/include -I$CUDA_HOME/targets/x86_64-linux/include"
        # 对于 FFmpeg，由于它使用 -ptx 模式编译，nvcc 不允许指定多个 -gencode 目标。
        # 我们过滤掉其他 -gencode 并使用单个通用的 compute_75 虚拟架构。
        local ffmpeg_nvccflags
        ffmpeg_nvccflags="$(make_nvccflags | sed 's/-gencode arch=[^ ]*,code=[^ ]*//g' | xargs) -gencode arch=compute_75,code=compute_75"
        cuda_flags=(
          --enable-cuda-nvcc
          --enable-cuda
          --disable-cuda-llvm
          --nvcc="$NVCC"
          --nvccflags="$ffmpeg_nvccflags"
        )
      fi

      local lto_flags=()
      if [[ "$LTO_ENABLE" == "1" ]]; then
        lto_flags=(--enable-lto=auto)
      fi

      local vs_flags=(--enable-vapoursynth)

      ./configure \
        --prefix="$PREFIX" \
        --bindir="$PREFIX/bin" \
        --arch=x86_64 \
        --target-os=mingw32 \
        --cross-prefix="$TARGET-" \
        --enable-cross-compile \
        --cc="$CC" \
        --cxx="$CXX" \
        --ld="$CXX" \
        --ar="$AR" \
        --ranlib="$RANLIB" \
        --pkg-config="$PKG_CONFIG" \
        --pkg-config-flags=--static \
        --optflags="$CFLAGS" \
        --extra-cflags="$extra_cflags" \
        --extra-cxxflags="$CXXFLAGS" \
        --extra-ldflags="$extra_ldflags" \
        --extra-libs="$extra_libs" \
        --disable-autodetect \
        --enable-gpl \
        --enable-nonfree \
        --enable-version3 \
        --enable-w32threads \
        --disable-pthreads \
        --disable-static \
        --enable-shared \
        --disable-debug \
        --disable-doc \
        --enable-ffplay \
        --enable-sdl2 \
        --enable-ffprobe \
        --enable-ffmpeg \
        --enable-ffnvcodec \
        --enable-nvenc \
        --enable-nvdec \
        --enable-libopus \
        --enable-libass \
        --enable-libfreetype \
        --enable-libharfbuzz \
        --enable-libfontconfig \
        --enable-libfribidi \
        --enable-libzimg \
        --enable-libwebp \
        --enable-libjxl \
        --enable-libdav1d \
        --enable-libsvtav1 \
        --enable-libvpl \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvmaf \
        --enable-libvvenc \
        --enable-schannel \
        --enable-d3d11va \
        --disable-d3d12va \
        --enable-mediafoundation \
        --enable-amf \
        --enable-avisynth \
        --enable-dxva2 \
        --enable-vulkan \
        --disable-opencl \
        --enable-libplacebo \
        --enable-libshaderc \
        --enable-zlib \
        --enable-bzlib \
        --enable-lzma \
        --enable-libxml2 \
        --enable-libmp3lame \
        --enable-libvorbis \
        --enable-libsoxr \
        --enable-libaom \
        --enable-libvpx \
        --enable-libopenjpeg \
        --enable-libsrt \
        --enable-librist \
        --enable-libbluray \
        --enable-libaribcaption \
        --enable-lcms2 \
        --enable-librubberband \
        --enable-libvidstab \
        "${lto_flags[@]}" \
        "${cuda_flags[@]}" \
        "${vs_flags[@]}" \
        --enable-encoder=wrapped_avframe \
        --enable-encoder=h264_nvenc \
        --enable-encoder=hevc_nvenc \
        --enable-encoder=av1_nvenc \
        --enable-encoder=hevc_qsv \
        --enable-encoder=av1_qsv \
        --enable-encoder=h264_qsv \
        --enable-encoder=libx264 \
        --enable-encoder=libx265 \
        --enable-encoder=libvvenc \
        --enable-encoder=libmp3lame \
        --enable-encoder=libvorbis \
        --enable-encoder=libaom \
        --enable-encoder=libvpx_vp8 \
        --enable-encoder=libvpx_vp9 \
        --enable-encoder=aac

      make -j"$FFMPEG_JOBS"
      make install
      popd >/dev/null

      # 拷贝编译好的可执行文件至 full 目录并剥离调试信息
      "$STRIP" "$PREFIX/bin/ffmpeg.exe" || true
      "$STRIP" "$PREFIX/bin/ffprobe.exe" || true
      "$STRIP" "$PREFIX/bin/ffplay.exe" || true
      "$STRIP" "$PREFIX/bin/"*.dll 2>/dev/null || true
      
      # 仅拷贝到 full 目录与安装前缀 bin 目录中，不污染根目录，不需要别名
      mkdir -p "$ROOT/full"
      cp -f "$PREFIX/bin/ffmpeg.exe" "$ROOT/full/ffmpeg.exe"
      cp -f "$PREFIX/bin/ffprobe.exe" "$ROOT/full/ffprobe.exe" 2>/dev/null || true
      cp -f "$PREFIX/bin/ffplay.exe" "$ROOT/full/ffplay.exe" 2>/dev/null || true
      cp -f "$PREFIX/bin/"*.dll "$ROOT/full/" 2>/dev/null || true

      # 拷贝编译器必要的 runtime DLLs 至 full 目录与前缀目录中，确保独立运行
      local winpthread_dll gcc_dll stdc_dll gomp_dll
      winpthread_dll="$("$CC" -print-file-name=libwinpthread-1.dll)"
      if [[ -f "$winpthread_dll" ]]; then
        cp -f "$winpthread_dll" "$ROOT/full/"
        cp -f "$winpthread_dll" "$PREFIX/bin/"
        "$STRIP" "$ROOT/full/libwinpthread-1.dll" 2>/dev/null || true
        "$STRIP" "$PREFIX/bin/libwinpthread-1.dll" 2>/dev/null || true
      fi

      gcc_dll="$("$CC" -print-file-name=libgcc_s_seh-1.dll)"
      if [[ -f "$gcc_dll" ]]; then
        cp -f "$gcc_dll" "$ROOT/full/"
        cp -f "$gcc_dll" "$PREFIX/bin/"
        "$STRIP" "$ROOT/full/libgcc_s_seh-1.dll" 2>/dev/null || true
        "$STRIP" "$PREFIX/bin/libgcc_s_seh-1.dll" 2>/dev/null || true
      fi

      stdc_dll="$("$CXX" -print-file-name=libstdc++-6.dll)"
      if [[ -f "$stdc_dll" ]]; then
        cp -f "$stdc_dll" "$ROOT/full/"
        cp -f "$stdc_dll" "$PREFIX/bin/"
        "$STRIP" "$ROOT/full/libstdc++-6.dll" 2>/dev/null || true
        "$STRIP" "$PREFIX/bin/libstdc++-6.dll" 2>/dev/null || true
      fi

      gomp_dll="$("$CC" -print-file-name=libgomp-1.dll)"
      if [[ -f "$gomp_dll" ]]; then
        cp -f "$gomp_dll" "$ROOT/full/"
        cp -f "$gomp_dll" "$PREFIX/bin/"
        "$STRIP" "$ROOT/full/libgomp-1.dll" 2>/dev/null || true
        "$STRIP" "$PREFIX/bin/libgomp-1.dll" 2>/dev/null || true
      fi
      
      # 运行时已静态链接，无需拷贝 GCC 运行时 DLL
      ;;

    *)
      echo "未知编译阶段: $stage"
      exit 1
      ;;
  esac
}

is_in_array() {
  local element="$1"
  shift
  local el
  for el in "$@"; do
    [[ "$el" == "$element" ]] && return 0
  done
  return 1
}

run_build() {
  local start_arg="${1:-}"
  shift || true
  local only_args=("$@")
  local START_STAGE=""
  local only_stages=()
  local FULL_BUILD=1

  if [[ ${#only_args[@]} -gt 0 ]]; then
    local arg
    for arg in "${only_args[@]}"; do
      local norm
      norm="$(normalize_stage "$arg")" || {
        echo "未知编译阶段参数: $arg"
        exit 1
      }
      only_stages+=("$norm")
    done
    FULL_BUILD=0
  elif [[ -n "$start_arg" ]]; then
    START_STAGE="$(normalize_stage "$start_arg")" || {
      echo "未知编译阶段参数: $start_arg"
      exit 1
    }
    FULL_BUILD=0
  fi

  echo "===> [子命令: build] 开始编译与链接依赖阶段..."
  setup_build_env

  # 构建报错捕获
  trap on_error ERR

  if [[ "$FULL_BUILD" -eq 1 ]]; then
    echo "清理前一次 of prefix 安装产物..."
    rm -rf "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin"
  fi

  # 依赖库源码目录校验
  for repo in "${STAGES[@]}"; do
    if [[ ${#only_stages[@]} -gt 0 ]]; then
      if ! is_in_array "$repo" "${only_stages[@]}"; then
        continue
      fi
    fi
    if [[ "$repo" == "ffmpeg" ]]; then
      need_repo "ffmpeg-source"
    else
      need_repo "$repo"
    fi
  done

  local RUN=0
  for stage in "${STAGES[@]}"; do
    if [[ ${#only_stages[@]} -gt 0 ]]; then
      if is_in_array "$stage" "${only_stages[@]}"; then
        run_stage "$stage"
      fi
    else
      if [[ "$FULL_BUILD" -eq 1 ]]; then
        RUN=1
      elif [[ "$stage" == "$START_STAGE" ]]; then
        RUN=1
      fi

      if [[ "$RUN" -eq 1 ]]; then
        run_stage "$stage"
      fi
    fi
  done

  CURRENT_STAGE=""
  echo
  echo "============================================================"
  if [[ ${#only_stages[@]} -gt 0 ]]; then
    local list_str
    list_str="$(IFS=', '; echo "${only_stages[*]}")"
    echo "成功编译了: $list_str"
  else
    echo "构建完成"
    echo "最终输出: $ROOT/full/ffmpeg.exe, $ROOT/full/ffprobe.exe, $ROOT/full/ffplay.exe"
  fi
  echo "============================================================"
}

# ==============================================================================
# 子命令 4: 清理临时文件 (原 clean 行为与要求 6 规范)
# ==============================================================================
run_clean() {
  echo "===> [子命令: clean] 正在清理临时编译文件与历史缓存..."
  rm -rf "$BUILDROOT"
  rm -rf "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin"
  rm -rf "$ROOT/_bundle"
  rm -f "$ROOT"/*.patch
  echo "清理完毕。"
}

# ==============================================================================
# 脚本入口与子命令调度分发
# ==============================================================================
show_help() {
  cat <<EOF
全功能 FFmpeg 交叉编译集成脚本 (全功能整合版)

用法:
  $0 <command> [options]

命令:
  all             顺序执行完整构建流程: tool -> update -> build (默认)
  tool            仅安装本地构建环境与工具链 (包括 MinGW 和 CUDA)
  update          仅从官方源或镜像克隆/更新所有依赖库源码
  build [stage]   执行依赖库和 FFmpeg 静态交叉编译构建。可选 [stage] 参数指定起始阶段
  build --only [stages...]  仅编译指定的一个或多个库（用空格或逗号分隔，不构建后续依赖，且仅校验对应源码）
  clean           清理编译缓存和旧的编译产物，并删除 patch 临时包与 _bundle/ 目录

常见示例:
  $0 all
  $0 tool
  $0 update
  $0 build
  $0 build --ffmpeg
  $0 build --only libsoxr libxml2
  $0 clean
EOF
}

cmd="${1:-all}"
shift || true

case "$cmd" in
  all)
    run_tool
    run_update
    run_build ""
    ;;
  tool)
    run_tool
    ;;
  update)
    run_update
    ;;
  build)
    only_stages=()
    start_stage=""
    if [[ "${1:-}" == "--only" ]]; then
      shift
      while [[ $# -gt 0 ]]; do
        only_stages+=("$1")
        shift
      done
    elif [[ "${1:-}" =~ ^--only=(.*)$ ]]; then
      IFS=',' read -r -a only_stages <<< "${BASH_REMATCH[1]}"
      shift || true
    else
      start_stage="${1:-}"
      shift || true
    fi
    run_build "$start_stage" "${only_stages[@]}"
    ;;
  clean)
    run_clean
    ;;
  -h|--help|help)
    show_help
    ;;
  *)
    echo "错误: 未知子命令 '$cmd'"
    show_help
    exit 1
    ;;
esac