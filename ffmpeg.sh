#!/usr/bin/env bash
# ==============================================================================
# FFmpeg 全功能交叉编译集成脚本 (MinGW-w64 x86_64-w64-mingw32)
# ==============================================================================
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=UTF-8
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
HOST_TOOLS="${HOST_TOOLS:-$BUILDROOT/host-tools}"
TARGET="${TARGET:-x86_64-w64-mingw32}"
TOOLCHAIN_FLAVOR="${TOOLCHAIN_FLAVOR:-llvm-mingw}"
# 全局安装到 /usr/local；可执行文件直接放到 /usr/local/bin，组件支持文件放到 /usr/local/<name>。
GLOBAL_TOOLCHAIN_ROOT="${GLOBAL_TOOLCHAIN_ROOT:-/usr/local}"
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$GLOBAL_TOOLCHAIN_ROOT}"
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-$TOOLCHAIN_ROOT/bin}"
XPACK_MINGW_ROOT="${XPACK_MINGW_ROOT:-$TOOLCHAIN_ROOT/xpack-mingw-w64-gcc}"
XPACK_MINGW_REPO="${XPACK_MINGW_REPO:-xpack-dev-tools/mingw-w64-gcc-xpack}"
XPACK_MINGW_VERSION="${XPACK_MINGW_VERSION:-latest}"
LLVM_MINGW_ROOT="${LLVM_MINGW_ROOT:-$TOOLCHAIN_ROOT/llvm-mingw}"
LLVM_MINGW_REPO="${LLVM_MINGW_REPO:-mstorsjo/llvm-mingw}"
LLVM_MINGW_VERSION="${LLVM_MINGW_VERSION:-latest}"
LLVM_MINGW_CRT="${LLVM_MINGW_CRT:-ucrt}"
LLVM_LINUX_ROOT="${LLVM_LINUX_ROOT:-$TOOLCHAIN_ROOT/llvm-linux}"
LLVM_LINUX_REPO="${LLVM_LINUX_REPO:-llvm/llvm-project}"
LLVM_LINUX_VERSION="${LLVM_LINUX_VERSION:-latest}"
CMAKE_ROOT="${CMAKE_ROOT:-$TOOLCHAIN_ROOT/cmake}"
CMAKE_REPO="${CMAKE_REPO:-Kitware/CMake}"
CMAKE_VERSION="${CMAKE_VERSION:-latest}"
NINJA_ROOT="${NINJA_ROOT:-$TOOLCHAIN_ROOT/ninja}"
NINJA_REPO="${NINJA_REPO:-ninja-build/ninja}"
NINJA_VERSION="${NINJA_VERSION:-latest}"
PYTOOLS_ROOT="${PYTOOLS_ROOT:-$TOOLCHAIN_ROOT/python-tools}"
NASM_ROOT="${NASM_ROOT:-$TOOLCHAIN_ROOT/nasm}"
NASM_REPO="${NASM_REPO:-https://github.com/netwide-assembler/nasm.git}"
NASM_VERSION="${NASM_VERSION:-latest}"
SEVENZIP_ROOT="${SEVENZIP_ROOT:-$TOOLCHAIN_ROOT/7zip}"
TOOLCHAIN_EXTRA_LIBS="${TOOLCHAIN_EXTRA_LIBS:-}"
JOBS="${JOBS:-$(nproc)}"
FFMPEG_JOBS="${FFMPEG_JOBS:-$JOBS}"
FFMPEG_REF="${FFMPEG_REF:-master}"
AUDIO_TOOLBOX_WRAPPER_REPO="${AUDIO_TOOLBOX_WRAPPER_REPO:-https://github.com/dantmnf/AudioToolboxWrapper.git}"
APPLE_ITUNES_URL="${APPLE_ITUNES_URL:-https://www.apple.com/itunes/download/win64/}"
APPLE_ITUNES_INSTALLER="${APPLE_ITUNES_INSTALLER:-$ROOT/toolchains/source-archives/iTunes64Setup.exe}"
APPLE_AUDIO_RUNTIME_DIR="${APPLE_AUDIO_RUNTIME_DIR:-$ROOT/toolchains/apple-application-support}"
SOURCE_FETCH_TIMEOUT="${SOURCE_FETCH_TIMEOUT:-30}"
SOURCE_DOWNLOAD_TIMEOUT="${SOURCE_DOWNLOAD_TIMEOUT:-600}"
INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-1}"

# 编译优化选项
BUILD_STARTED_AT=""
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O3 -pipe -DNDEBUG -funwind-tables -fexceptions}"
INLINE_ENABLE="${INLINE_ENABLE:-1}"
INLINE_FLAGS="${INLINE_FLAGS:--finline-functions}"
SECTION_GC_ENABLE="${SECTION_GC_ENABLE:-1}"
LTO_ENABLE="${LTO_ENABLE:-0}"
CFG_ENABLE="${CFG_ENABLE:-1}"
LTO_FLAGS="${LTO_FLAGS:--flto=auto}"
CPU_FLAGS="${CPU_FLAGS:--march=x86-64-v3 -mtune=generic}"

# CUDA/NVENC 配置
CUDA_ENABLE="${CUDA_ENABLE:-1}"
CUDA_REDIST_ROOT="${CUDA_REDIST_ROOT:-}"
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
  [jxrlib]="https://github.com/scrubbbbs/jxrlib-kif.git"
  [expat]="https://github.com/libexpat/libexpat.git"
  [brotli]="https://github.com/google/brotli.git"
  [dav1d]="https://code.videolan.org/videolan/dav1d.git"
  [svtav1]="https://gitlab.com/AOMediaCodec/SVT-AV1.git"
  [libvpl]="https://github.com/intel/libvpl.git"
  [vapoursynth]="https://github.com/vapoursynth/vapoursynth.git"
  [x264]="https://github.com/mirror/x264.git"
  [x265]="https://bitbucket.org/multicoreware/x265_git.git"
  [vmaf]="https://github.com/Netflix/vmaf.git"
  [vvenc]="https://github.com/fraunhoferhhi/vvenc.git"
  [vvdec]="https://github.com/fraunhoferhhi/vvdec.git"
  [sdl2]="https://github.com/libsdl-org/SDL.git"
  [zlib]="https://github.com/madler/zlib.git"
  [bzip2]="https://github.com/libarchive/bzip2.git"
  [lzma]="https://github.com/tukaani-project/xz.git"

  [libxml2]="https://github.com/GNOME/libxml2.git"
  [libmp3lame]="https://github.com/TimothyGu/lame.git"
  [libogg]="https://github.com/xiph/ogg.git"
  [libvorbis]="https://github.com/xiph/vorbis.git"
  [libsoxr]="https://github.com/chirlu/soxr.git"
  [fdk-aac]="https://github.com/mstorsjo/fdk-aac.git"
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
  [libssh]="https://git.libssh.org/projects/libssh.git"
  [opencl-headers]="https://github.com/KhronosGroup/OpenCL-Headers.git"
  [opencl-loader]="https://github.com/KhronosGroup/OpenCL-ICD-Loader.git"
  [libiconv]="https://github.com/winlibs/libiconv.git"
  [libpng]="https://github.com/pnggroup/libpng.git"
  [libsnappy]="https://github.com/google/snappy.git"
  [libtheora]="https://gitlab.xiph.org/xiph/theora.git"
  [libspeex]="https://github.com/xiph/speex.git"
  [libtwolame]="https://github.com/njh/twolame.git"
  [libmysofa]="https://github.com/hoene/libmysofa.git"
  [libopenmpt]="https://github.com/OpenMPT/openmpt.git"
  [libdvdread]="https://code.videolan.org/videolan/libdvdread.git"
  [libdvdnav]="https://code.videolan.org/videolan/libdvdnav.git"
  [chromaprint]="https://github.com/acoustid/chromaprint.git"
  [libzmq]="https://github.com/zeromq/libzmq.git"
  [libzvbi]="https://github.com/zapping-vbi/zvbi.git"
  [libgsm]="https://github.com/timothytylee/libgsm.git"
  [opencore-amr]="https://github.com/BelledonneCommunications/opencore-amr.git"
  [vo-amrwbenc]="https://github.com/mstorsjo/vo-amrwbenc.git"
  [AudioToolboxWrapper]="$AUDIO_TOOLBOX_WRAPPER_REPO"
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
  [jxrlib]='main|master'
  [expat]='^R_[0-9]+(_[0-9]+)+$'
  [brotli]='^v?[0-9]+(\.[0-9]+)*$'
  [dav1d]='^[0-9]+(\.[0-9]+)*$'
  [svtav1]='^v[0-9]+(\.[0-9]+)*$'
  [libvpl]='^v2\.[0-9]+(\.[0-9]+)*$'
  [vapoursynth]='^R[0-9]+(\.[0-9]+)*$'
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
  [fdk-aac]='^v?[0-9]+(\.[0-9]+)*$'
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
  [libssh]='^(libssh-)?v?[0-9]+(\.[0-9]+)+$'
  [opencl-headers]='^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}$'
  [opencl-loader]='^v[0-9]{4}\.[0-9]{2}\.[0-9]{2}$'
  [libiconv]='^libiconv-[0-9]+(\.[0-9]+)+$'
  [libpng]='^v?1\.[0-9]+\.[0-9]+$'
  [libsnappy]='^[0-9]+(\.[0-9]+)+$'
  [libtheora]='^v?[0-9]+(\.[0-9]+)+$'
  [libspeex]='^[Ss]peex-[0-9]+(\.[0-9]+)+$'
  [libtwolame]='^v?[0-9]+(\.[0-9]+)+$'
  [libmysofa]='^v?[0-9]+(\.[0-9]+)+$'
  [libopenmpt]='^libopenmpt-[0-9]+(\.[0-9]+)+$'
  [libdvdread]='^v?[0-9]+(\.[0-9]+)+$'
  [libdvdnav]='^v?[0-9]+(\.[0-9]+)+$'
  [chromaprint]='^v?[0-9]+(\.[0-9]+)+$'
  [libzmq]='master'
  [libzvbi]='^v?[0-9]+(\.[0-9]+)+$'
  [libgsm]='master'
  [opencore-amr]='^v?[0-9]+(\.[0-9]+)+$'
  [vo-amrwbenc]='^v?[0-9]+(\.[0-9]+)+$'
  [AudioToolboxWrapper]='master'
)

# 编译依赖阶段列表
STAGES=(
  "nv-codec-headers"
  "zlib"
  "bzip2"
  "lzma"
  "libiconv"
  "libpng"

  "libxml2"
  "libmp3lame"
  "libogg"
  "libvorbis"
  "libsoxr"
  "fdk-aac"
  "libaom"
  "libvpx"
  "libopenjpeg"
  "mbedtls"
  "libssh"
  "opencl-headers"
  "opencl-loader"
  "libsnappy"
  "libtheora"
  "libspeex"
  "libtwolame"
  "libmysofa"
  "libopenmpt"
  "libdvdread"
  "libdvdnav"
  "chromaprint"
  "libzmq"
  "libzvbi"
  "libgsm"
  "opencore-amr"
  "vo-amrwbenc"
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
  "jxrlib"
  "dav1d"
  "svtav1"
  "libvpl"
  "vapoursynth"
  "x264"
  "x265"
  "vmaf"
  "vvenc"
  "vvdec"
  "AudioToolboxWrapper"
  "sdl2"
  "amf"
  "avisynth"
  "ffmpeg"
)

# ==============================================================================
# 子模块 1: 环境与工具链检测 (原 tool.sh)
# ==============================================================================
as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return
  fi
  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return
  fi
  if [[ -n "${WSL_DISTRO_NAME:-}" && -x /mnt/c/Windows/System32/wsl.exe ]]; then
    local quoted="" arg
    for arg in "$@"; do
      printf -v quoted '%s%q ' "$quoted" "$arg"
    done
    /mnt/c/Windows/System32/wsl.exe -d "$WSL_DISTRO_NAME" -u root -- bash -lc "$quoted"
    return
  fi
  sudo -S -p '' "$@"
}

github_asset_url() {
  local repo="$1" version="$2" pattern="$3"
  python3 - "$repo" "$version" "$pattern" <<'PYGH'
import json, re, sys, time, urllib.request
repo, version, pattern = sys.argv[1:4]
api = f"https://api.github.com/repos/{repo}/releases/latest" if version == "latest" else f"https://api.github.com/repos/{repo}/releases/tags/{version}"
for attempt in range(4):
    try:
        with urllib.request.urlopen(api, timeout=60) as r:
            data = json.load(r)
        break
    except Exception:
        if attempt == 3:
            raise
        time.sleep(5 * (attempt + 1))
rx = re.compile(pattern)
for a in data.get("assets", []):
    name = a.get("name", "")
    if rx.search(name):
        print(a["browser_download_url"])
        raise SystemExit(0)
raise SystemExit(f"no release asset matched {pattern!r} in {repo} {data.get('tag_name', version)}")
PYGH
}

link_global_tool() {
  local src="$1" name="${2:-$(basename "$1")}"
  as_root mkdir -p "$TOOLCHAIN_BIN"
  as_root ln -sf "$src" "$TOOLCHAIN_BIN/$name"
  if [[ "$TOOLCHAIN_BIN" != "/usr/local/bin" ]]; then
    as_root mkdir -p /usr/local/bin
    as_root ln -sf "$TOOLCHAIN_BIN/$name" "/usr/local/bin/$name"
  fi
}

link_prefixed_tools() {
  local dir="$1" f name
  as_root mkdir -p "$TOOLCHAIN_BIN"
  for f in "$dir"/$TARGET-*; do
    [[ -x "$f" && -f "$f" ]] || continue
    name="$(basename "$f")"
    as_root ln -sf "$f" "$TOOLCHAIN_BIN/$name"
    if [[ "$TOOLCHAIN_BIN" != "/usr/local/bin" ]]; then
      as_root mkdir -p /usr/local/bin
      as_root ln -sf "$TOOLCHAIN_BIN/$name" "/usr/local/bin/$name"
    fi
  done
}

install_global_path_profile() {
  as_root mkdir -p "$TOOLCHAIN_BIN"
  as_root tee /etc/profile.d/ffmpeg-build-tools.sh >/dev/null <<EOF
# Installed by ffmpeg.sh tool
export PATH="$TOOLCHAIN_BIN:\$PATH"
EOF
  export PATH="$TOOLCHAIN_BIN:$PATH"
}

xpack_mingw_asset_url() {
  github_asset_url "$XPACK_MINGW_REPO" "$XPACK_MINGW_VERSION" '^xpack-mingw-w64-gcc-.*-linux-x64\.tar\.gz$'
}

install_xpack_mingw() {
  as_root mkdir -p "$TOOLCHAIN_ROOT"
  local asset_url marker tmp archive extract next_root found toolroot asset_file
  asset_url="$(xpack_mingw_asset_url)"
  marker="$XPACK_MINGW_ROOT/.asset_url"
  if [[ -x "$XPACK_MINGW_ROOT/bin/$TARGET-gcc" && -f "$marker" && "$(cat "$marker")" == "$asset_url" ]]; then
    echo "xPack MinGW-w64 GCC already current: $XPACK_MINGW_ROOT"
    link_prefixed_tools "$XPACK_MINGW_ROOT/bin"
    return 0
  fi

  tmp="$(mktemp -d)"
  archive="$tmp/xpack-mingw-w64-gcc.tar.gz"
  extract="$tmp/extract"
  next_root="$XPACK_MINGW_ROOT.tmp"
  asset_file="$tmp/.asset_url"
  echo "== Install xPack MinGW-w64 GCC latest stable globally =="
  echo "$asset_url"
  download_file_retry "$archive" "$asset_url"
  mkdir -p "$extract"
  tar -xzf "$archive" -C "$extract"
  found="$(find "$extract" -type f -path "*/bin/$TARGET-gcc" -perm -u+x | head -n 1)"
  [[ -n "$found" ]] || { echo "下载包里找不到 bin/$TARGET-gcc"; exit 1; }
  toolroot="$(cd "$(dirname "$found")/.." && pwd)"
  printf '%s\n' "$asset_url" > "$asset_file"
  as_root rm -rf "$next_root"
  as_root mkdir -p "$next_root"
  as_root cp -a "$toolroot/." "$next_root/"
  as_root cp "$asset_file" "$next_root/.asset_url"
  as_root rm -rf "$XPACK_MINGW_ROOT"
  as_root mv "$next_root" "$XPACK_MINGW_ROOT"
  rm -rf "$tmp"
  link_prefixed_tools "$XPACK_MINGW_ROOT/bin"
  "$XPACK_MINGW_ROOT/bin/$TARGET-gcc" --version | head -n 1
}


llvm_mingw_asset_url() {
  github_asset_url "$LLVM_MINGW_REPO" "$LLVM_MINGW_VERSION" "^llvm-mingw-.*-${LLVM_MINGW_CRT}-ubuntu-22\\.04-x86_64\\.tar\\.xz$"
}

install_llvm_mingw() {
  as_root mkdir -p "$TOOLCHAIN_ROOT"
  local asset_url marker tmp archive extract next_root found toolroot asset_file
  asset_url="$(llvm_mingw_asset_url)"
  marker="$LLVM_MINGW_ROOT/.asset_url"
  if [[ -x "$LLVM_MINGW_ROOT/bin/$TARGET-clang" && -f "$marker" && "$(cat "$marker")" == "$asset_url" ]]; then
    echo "llvm-mingw already current: $LLVM_MINGW_ROOT"
    link_prefixed_tools "$LLVM_MINGW_ROOT/bin"
    link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-ar" llvm-ar
    link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-ranlib" llvm-ranlib
    link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-strip" llvm-strip
    link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-objdump" llvm-objdump
    return 0
  fi

  tmp="$(mktemp -d)"
  archive="$tmp/llvm-mingw.tar.xz"
  extract="$tmp/extract"
  next_root="$LLVM_MINGW_ROOT.tmp"
  asset_file="$tmp/.asset_url"
  echo "== Install latest llvm-mingw/Clang globally =="
  echo "$asset_url"
  download_file_retry "$archive" "$asset_url"
  mkdir -p "$extract"
  tar -xJf "$archive" -C "$extract"
  found="$(find "$extract" -path "*/bin/$TARGET-clang" | head -n 1)"
  [[ -n "$found" ]] || { echo "下载包里找不到 bin/$TARGET-clang"; exit 1; }
  toolroot="$(cd "$(dirname "$found")/.." && pwd)"
  printf '%s\n' "$asset_url" > "$asset_file"
  as_root rm -rf "$next_root"
  as_root mkdir -p "$next_root"
  as_root cp -a "$toolroot/." "$next_root/"
  as_root cp "$asset_file" "$next_root/.asset_url"
  as_root rm -rf "$LLVM_MINGW_ROOT"
  as_root mv "$next_root" "$LLVM_MINGW_ROOT"
  rm -rf "$tmp"
  link_prefixed_tools "$LLVM_MINGW_ROOT/bin"
  link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-ar" llvm-ar
  link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-ranlib" llvm-ranlib
  link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-strip" llvm-strip
  link_global_tool "$LLVM_MINGW_ROOT/bin/llvm-objdump" llvm-objdump
  "$LLVM_MINGW_ROOT/bin/$TARGET-clang" --version | head -n 1
}

llvm_linux_release() {
  python3 - "$LLVM_LINUX_REPO" "$LLVM_LINUX_VERSION" <<'PYLLVM'
import json, re, sys, time, urllib.request
repo, version = sys.argv[1:3]
api = f"https://api.github.com/repos/{repo}/releases/latest" if version == "latest" else f"https://api.github.com/repos/{repo}/releases/tags/{version}"
for attempt in range(4):
    try:
        with urllib.request.urlopen(api, timeout=60) as r:
            tag = json.load(r)["tag_name"]
        break
    except Exception:
        if attempt == 3:
            raise
        time.sleep(5 * (attempt + 1))
m = re.fullmatch(r"llvmorg-(\d+)\.\d+\.\d+", tag)
if not m:
    raise SystemExit(f"unexpected LLVM stable tag: {tag}")
print(tag, m.group(1))
PYLLVM
}

install_llvm_linux() {
  local release major marker tmp
  read -r release major <<< "$(llvm_linux_release)"
  marker="$TOOLCHAIN_ROOT/.llvm-linux-release"
  if [[ -x "/usr/bin/clang-$major" && -x "/usr/bin/ld.lld-$major" && -f "$marker" && "$(cat "$marker")" == "$release" ]]; then
    echo "Native LLVM already current: $release"
  else
    echo "== Install latest stable native LLVM/Clang/LLD from apt.llvm.org =="
    tmp="$(mktemp)"
    download_file_retry "$tmp" https://apt.llvm.org/llvm.sh
    chmod +x "$tmp"

    # apt.llvm.org python3-lldb-X packages intentionally conflict across major
    # versions. Remove only an installed older LLDB Python binding (and the two
    # packages that directly depend on it) before installing the new major.
    local old_lldb_pkg old_major
    while IFS= read -r old_lldb_pkg; do
      [[ -n "$old_lldb_pkg" && "$old_lldb_pkg" != "python3-lldb-$major" ]] || continue
      old_major="${old_lldb_pkg##*-}"
      [[ "$old_major" =~ ^[0-9]+$ ]] || continue
      echo "Remove conflicting old LLDB Python binding: $old_lldb_pkg"
      as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y --no-install-recommends \
        "$old_lldb_pkg" "lldb-$old_major" "liblldb-$old_major-dev"
    done < <(dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' 'python3-lldb-*' 2>/dev/null \
      | awk '$2 ~ /^ii/ {print $1}')

    as_root env DEBIAN_FRONTEND=noninteractive bash "$tmp" "$major" all
    rm -f "$tmp"
    printf '%s\n' "$release" | as_root tee "$marker" >/dev/null
  fi
  as_root ln -sfn "/usr/lib/llvm-$major" "$LLVM_LINUX_ROOT"
  link_global_tool "/usr/bin/clang-$major" clang-linux
  link_global_tool "/usr/bin/clang++-$major" clang++-linux
  link_global_tool "/usr/bin/ld.lld-$major" ld.lld-linux
  link_global_tool "/usr/bin/llvm-ar-$major" llvm-ar-linux
  link_global_tool "/usr/bin/llvm-ranlib-$major" llvm-ranlib-linux
  link_global_tool "/usr/bin/llvm-strip-$major" llvm-strip-linux
  "/usr/bin/clang-$major" --version | head -n 1
}

sevenzip_asset_url() {
  github_asset_url "ip7z/7zip" latest '^7z[0-9]+-linux-x64\.tar\.xz$'
}

install_7zip_latest() {
  local url marker tmp archive next_root
  url="$(sevenzip_asset_url)"
  marker="$SEVENZIP_ROOT/.asset_url"
  if [[ -x "$SEVENZIP_ROOT/bin/7zz" && -f "$marker" && "$(cat "$marker")" == "$url" ]]; then
    echo "7-Zip already current: $url"
  else
    tmp="$(mktemp -d)"
    archive="$tmp/7zip.tar.xz"
    next_root="$SEVENZIP_ROOT.tmp"
    echo "== Install latest stable 7-Zip globally =="
    download_file_retry "$archive" "$url"
    tar -xJf "$archive" -C "$tmp"
    [[ -x "$tmp/7zz" ]] || { echo "7-Zip archive does not contain 7zz"; exit 1; }
    as_root rm -rf "$next_root"
    as_root mkdir -p "$next_root/bin"
    as_root install -m 755 "$tmp/7zz" "$next_root/bin/7zz"
    printf '%s\n' "$url" > "$tmp/.asset_url"
    as_root install -m 644 "$tmp/.asset_url" "$next_root/.asset_url"
    as_root rm -rf "$SEVENZIP_ROOT"
    as_root mv "$next_root" "$SEVENZIP_ROOT"
    rm -rf "$tmp"
  fi
  link_global_tool "$SEVENZIP_ROOT/bin/7zz" 7zz
  link_global_tool "$SEVENZIP_ROOT/bin/7zz" 7z
  "$SEVENZIP_ROOT/bin/7zz" i | sed -n '1,2p'
}

cmake_asset_url() {
  github_asset_url "$CMAKE_REPO" "$CMAKE_VERSION" '^cmake-[0-9].*-linux-x86_64\.tar\.gz$'
}

install_cmake_latest() {
  as_root mkdir -p "$TOOLCHAIN_ROOT"
  local asset_url marker tmp archive extract found toolroot asset_file next_root
  asset_url="$(cmake_asset_url)"
  marker="$CMAKE_ROOT/.asset_url"
  if [[ -x "$CMAKE_ROOT/bin/cmake" && -f "$marker" && "$(cat "$marker")" == "$asset_url" ]]; then
    echo "CMake already current: $CMAKE_ROOT"
  else
    tmp="$(mktemp -d)"
    archive="$tmp/cmake.tar.gz"
    extract="$tmp/extract"
    asset_file="$tmp/.asset_url"
    next_root="$CMAKE_ROOT.tmp"
    echo "== Install latest stable CMake globally =="
    echo "$asset_url"
    download_file_retry "$archive" "$asset_url"
    mkdir -p "$extract"
    tar -xzf "$archive" -C "$extract"
    found="$(find "$extract" -type f -path "*/bin/cmake" -perm -u+x | head -n 1)"
    [[ -n "$found" ]] || { echo "下载包里找不到 bin/cmake"; exit 1; }
    toolroot="$(cd "$(dirname "$found")/.." && pwd)"
    printf '%s\n' "$asset_url" > "$asset_file"
    as_root rm -rf "$next_root"
    as_root mkdir -p "$next_root"
    as_root cp -a "$toolroot/." "$next_root/"
    as_root cp "$asset_file" "$next_root/.asset_url"
    as_root rm -rf "$CMAKE_ROOT"
    as_root mv "$next_root" "$CMAKE_ROOT"
    rm -rf "$tmp"
  fi
  link_global_tool "$CMAKE_ROOT/bin/cmake" cmake
  link_global_tool "$CMAKE_ROOT/bin/ctest" ctest
  link_global_tool "$CMAKE_ROOT/bin/cpack" cpack
  "$CMAKE_ROOT/bin/cmake" --version | head -n 1
}

ninja_asset_url() {
  github_asset_url "$NINJA_REPO" "$NINJA_VERSION" '^ninja-linux\.zip$'
}

install_ninja_latest() {
  as_root mkdir -p "$TOOLCHAIN_ROOT"
  local asset_url marker tmp archive extract asset_file next_root
  asset_url="$(ninja_asset_url)"
  marker="$NINJA_ROOT/.asset_url"
  if [[ -x "$NINJA_ROOT/bin/ninja" && -f "$marker" && "$(cat "$marker")" == "$asset_url" ]]; then
    echo "Ninja already current: $NINJA_ROOT"
  else
    tmp="$(mktemp -d)"
    archive="$tmp/ninja.zip"
    extract="$tmp/extract"
    asset_file="$tmp/.asset_url"
    next_root="$NINJA_ROOT.tmp"
    echo "== Install latest stable Ninja globally =="
    echo "$asset_url"
    download_file_retry "$archive" "$asset_url"
    mkdir -p "$extract"
    unzip -q "$archive" -d "$extract"
    [[ -x "$extract/ninja" ]] || { echo "下载包里找不到 ninja"; exit 1; }
    printf '%s\n' "$asset_url" > "$asset_file"
    as_root rm -rf "$next_root"
    as_root mkdir -p "$next_root/bin"
    as_root cp "$extract/ninja" "$next_root/bin/ninja"
    as_root chmod +x "$next_root/bin/ninja"
    as_root cp "$asset_file" "$next_root/.asset_url"
    as_root rm -rf "$NINJA_ROOT"
    as_root mv "$next_root" "$NINJA_ROOT"
    rm -rf "$tmp"
  fi
  link_global_tool "$NINJA_ROOT/bin/ninja" ninja
  "$NINJA_ROOT/bin/ninja" --version
}

install_python_tools_latest() {
  as_root mkdir -p "$TOOLCHAIN_ROOT"
  echo "== Install / update latest stable Meson + Python build helpers globally =="
  if [[ ! -x "$PYTOOLS_ROOT/bin/python" ]]; then
    as_root rm -rf "$PYTOOLS_ROOT"
    as_root python3 -m venv "$PYTOOLS_ROOT"
  fi
  as_root "$PYTOOLS_ROOT/bin/python" -m pip install -U pip setuptools wheel packaging meson
  link_global_tool "$PYTOOLS_ROOT/bin/meson" meson
  "$PYTOOLS_ROOT/bin/meson" --version
}

nasm_latest_tag() {
  if [[ "$NASM_VERSION" != "latest" ]]; then
    printf '%s\n' "$NASM_VERSION"
    return 0
  fi
  git ls-remote --tags --refs "$NASM_REPO" 'nasm-*' \
    | awk -F/ '{print $NF}' \
    | { grep -E '^nasm-[0-9]+(\.[0-9]+)*$' || true; } \
    | sed 's/^nasm-//' \
    | sort -V \
    | tail -n 1 \
    | sed 's/^/nasm-/'
}

install_nasm_latest() {
  as_root mkdir -p "$TOOLCHAIN_ROOT"
  local tag marker tmp src dest next_root
  tag="$(nasm_latest_tag)"
  [[ -n "$tag" ]] || { echo "无法解析 NASM 最新稳定 tag"; exit 1; }
  marker="$NASM_ROOT/.tag"
  if [[ -x "$NASM_ROOT/bin/nasm" && -f "$marker" && "$(cat "$marker")" == "$tag" ]]; then
    echo "NASM already current: $NASM_ROOT ($tag)"
  else
    tmp="$(mktemp -d)"
    src="$tmp/nasm"
    dest="$tmp/dest"
    next_root="$NASM_ROOT.tmp"
    echo "== Build/install latest stable NASM globally =="
    echo "$NASM_REPO $tag"
    git_clone_retry "$NASM_REPO" "$src" "$tag"
    pushd "$src" >/dev/null
    ./autogen.sh
    ./configure --prefix="$NASM_ROOT"
    make -j"$JOBS"
    # ponytail: FFmpeg only needs nasm/ndisasm; git builds may not generate nasm.1, so avoid fragile manpage install.
    mkdir -p "$dest$NASM_ROOT/bin"
    install -m 755 nasm "$dest$NASM_ROOT/bin/nasm"
    [[ -x ndisasm ]] && install -m 755 ndisasm "$dest$NASM_ROOT/bin/ndisasm"
    popd >/dev/null
    as_root rm -rf "$next_root"
    as_root mkdir -p "$next_root"
    as_root cp -a "$dest$NASM_ROOT/." "$next_root/"
    printf '%s\n' "$tag" > "$tmp/.tag"
    as_root cp "$tmp/.tag" "$next_root/.tag"
    as_root rm -rf "$NASM_ROOT"
    as_root mv "$next_root" "$NASM_ROOT"
    rm -rf "$tmp"
  fi
  link_global_tool "$NASM_ROOT/bin/nasm" nasm
  [[ -x "$NASM_ROOT/bin/ndisasm" ]] && link_global_tool "$NASM_ROOT/bin/ndisasm" ndisasm
  "$NASM_ROOT/bin/nasm" -v
}

first_tool() {
  local t
  for t in "$@"; do
    if command -v "$t" >/dev/null 2>&1; then
      command -v "$t"
      return 0
    fi
  done
  echo "找不到工具: $*" >&2
  exit 1
}

toolchain_ready() {
  local tool
  for tool in curl aria2c git cmake ninja meson nasm clang-linux 7z pkg-config; do
    command -v "$tool" >/dev/null 2>&1 || return 1
  done
  case "$TOOLCHAIN_FLAVOR" in
    llvm-mingw)
      [[ -x "$LLVM_MINGW_ROOT/bin/$TARGET-clang" && -x "$LLVM_MINGW_ROOT/bin/$TARGET-clang++" ]] || return 1
      ;;
    xpack-mingw64-gcc)
      [[ -x "$XPACK_MINGW_ROOT/bin/$TARGET-gcc" && -x "$XPACK_MINGW_ROOT/bin/$TARGET-g++" ]] || return 1
      ;;
    system)
      command -v "$TARGET-gcc" >/dev/null 2>&1 || return 1
      command -v "$TARGET-g++" >/dev/null 2>&1 || return 1
      ;;
    *) return 1 ;;
  esac
  [[ "$CUDA_ENABLE" != "1" ]] || command -v nvcc >/dev/null 2>&1
}

run_tool() {
  echo "===> [子命令: tool] 检测与安装构建工具链..."
  if [[ "${TOOLCHAIN_REFRESH:-1}" != "1" ]] && toolchain_ready; then
    echo "Reuse existing toolchain by request (TOOLCHAIN_REFRESH=0)."
    return
  fi

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

  echo "== Update apt bootstrap packages =="
  as_root apt update

  echo
  echo "== Install bootstrap packages (latest toolchains are downloaded below, not from apt) =="
  as_root apt install -y --no-install-recommends \
    build-essential \
    autoconf automake libtool make \
    pkg-config xxd \
    git curl aria2 ca-certificates tar xz-utils unzip \
    python3 python3-venv perl gnupg lsb-release \
    gettext autopoint gperf

  install_global_path_profile
  install_cmake_latest
  install_ninja_latest
  install_python_tools_latest
  install_nasm_latest
  install_xpack_mingw
  install_llvm_mingw
  install_llvm_linux
  install_7zip_latest

  if [[ "$TOOLCHAIN_FLAVOR" == "system" ]]; then
    as_root apt install -y --no-install-recommends \
      mingw-w64 mingw-w64-tools \
      binutils-mingw-w64-x86-64 \
      gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
      gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
      gcc-mingw-w64-x86-64-win32 g++-mingw-w64-x86-64-win32 \
      mingw-w64-x86-64-dev
  fi

  if [[ "$CUDA_TOOLKIT_ENABLE" == "1" ]]; then
    echo
    echo "== Install / update latest CUDA Toolkit for WSL =="
    if dpkg-query -W -f='${Status}' cuda-keyring 2>/dev/null | grep -q 'install ok installed'; then
      echo "Reuse installed cuda-keyring."
    else
      local tmpdeb
      tmpdeb="$(mktemp --suffix=.deb)"
      download_file_retry "$tmpdeb" "$CUDA_KEYRING"
      as_root dpkg -i "$tmpdeb"
      rm -f "$tmpdeb"
    fi

    as_root apt update

    echo
    echo "== CUDA package candidate =="
    apt-cache policy cuda-toolkit || true

    echo
    echo "== Upgrade latest nvcc / CUDA Toolkit =="
    as_root apt install -y --no-install-recommends cuda-toolkit

    echo
    echo "== Configure CUDA environment =="
    if [ -d /usr/local/cuda ]; then
      as_root tee /etc/profile.d/cuda.sh >/dev/null <<'EOF'
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
  echo "[Toolchain flavor] $TOOLCHAIN_FLAVOR"
  case "$TOOLCHAIN_FLAVOR" in
    llvm-mingw)
      "$LLVM_MINGW_ROOT/bin/$TARGET-clang" --version | head -n 1 || true
      "$LLVM_MINGW_ROOT/bin/$TARGET-clang++" --version | head -n 1 || true
      ;;
    xpack-mingw64-gcc)
      "$XPACK_MINGW_ROOT/bin/$TARGET-gcc" --version | head -n 1 || true
      "$XPACK_MINGW_ROOT/bin/$TARGET-g++" --version | head -n 1 || true
      ;;
    system)
      x86_64-w64-mingw32-gcc-win32 --version | head -n 1 || true
      x86_64-w64-mingw32-g++-win32 --version | head -n 1 || true
      ;;
  esac

  echo
  echo "[CMake]"
  cmake --version | head -n 1 || true

  echo
  echo "[Ninja]"
  ninja --version || true

  echo
  echo "[Meson]"
  meson --version || true

  echo
  echo "[NASM]"
  nasm -v || true

  echo
  echo "[Native LLVM]"
  clang-linux --version | head -n 1 || true

  echo
  echo "[7-Zip]"
  7zz i | head -n 2 || true

  echo
  echo "[pkg-config]"
  pkg-config --version || true

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
    libssh)
      tag="${tag#libssh-}"; echo "${tag#v}"
      ;;
    libspeex)
      tag="${tag#Speex-}"; tag="${tag#speex-}"; echo "$tag"
      ;;
    libopenmpt)
      echo "${tag#libopenmpt-}"
      ;;
    libiconv)
      echo "${tag#libiconv-}"
      ;;
    *)
      echo "${tag#v}"
      ;;
  esac
}

has_network_proxy() {
  [[ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}${all_proxy:-}" ]]
}

run_network_command() {
  local mode="$1" duration="$2"
  shift 2
  if [[ "$mode" == "proxy" ]]; then
    timeout "$duration" "$@"
  else
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
      timeout "$duration" "$@"
  fi
}

git_url_variants() {
  local url="$1" rest
  printf '%s\n' "$url"
  case "$url" in
    https://*)
      rest="${url#https://}"
      printf 'http://%s\ngit://%s\n' "$rest" "$rest"
      ;;
    http://*)
      rest="${url#http://}"
      printf 'https://%s\ngit://%s\n' "$rest" "$rest"
      ;;
    git://*)
      rest="${url#git://}"
      printf 'https://%s\nhttp://%s\n' "$rest" "$rest"
      ;;
  esac
}

archive_url_variants() {
  local url="$1" rest
  printf '%s\n' "$url"
  case "$url" in
    https://*) printf 'http://%s\n' "${url#https://}" ;;
    http://*) printf 'https://%s\n' "${url#http://}" ;;
  esac
}

git_retry() {
  local mode attempt=0
  for mode in proxy direct; do
    [[ "$mode" != proxy ]] || has_network_proxy || continue
    attempt=$((attempt + 1))
    if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" "$@"; then
      return 0
    fi
    echo "git command failed ($mode attempt $attempt), retrying..." >&2
    sleep 3
  done
  return 1
}

git_fetch_retry() {
  local repo_dir="$1" canonical_url="$2" candidate mode attempt=0
  while IFS= read -r candidate; do
    for mode in proxy direct; do
      [[ "$mode" != proxy ]] || has_network_proxy || continue
      attempt=$((attempt + 1))
      git -C "$repo_dir" remote set-url origin "$candidate"
      echo "git fetch: ${candidate%%:*} via $mode (attempt $attempt)"
      if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" \
        git -c http.version=HTTP/1.1 -C "$repo_dir" fetch --tags --prune --force origin; then
        git -C "$repo_dir" remote set-url origin "$canonical_url"
        return 0
      fi
      sleep 3
    done
  done < <(git_url_variants "$canonical_url")
  git -C "$repo_dir" remote set-url origin "$canonical_url" || true
  return 1
}

git_clone_retry() {
  local canonical_url="$1" dir="$2" ref="${3:-}" candidate mode attempt=0
  local clone_args=(git -c http.version=HTTP/1.1 clone --filter=blob:none)
  if [[ -n "$ref" ]]; then
    clone_args+=(--depth 1 --branch "$ref")
  fi
  while IFS= read -r candidate; do
    for mode in proxy direct; do
      [[ "$mode" != proxy ]] || has_network_proxy || continue
      attempt=$((attempt + 1))
      rm -rf "$dir"
      echo "git clone: ${candidate%%:*} via $mode (attempt $attempt)"
      if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" \
        "${clone_args[@]}" "$candidate" "$dir"; then
        git -C "$dir" remote set-url origin "$canonical_url"
        return 0
      fi
      sleep 3
    done
  done < <(git_url_variants "$canonical_url")
  return 1
}

download_file_retry() {
  local destination="$1" canonical_url="$2" temporary="${1}.part" candidate mode attempt=0
  mkdir -p "$(dirname "$destination")"
  rm -f "$temporary" "$temporary.aria2"

  while IFS= read -r candidate; do
    for mode in proxy direct; do
      [[ "$mode" != proxy ]] || has_network_proxy || continue
      attempt=$((attempt + 1))
      echo "aria2c download: $(basename "$destination") via ${candidate%%:*}/$mode (attempt $attempt)"
      if run_network_command "$mode" "$SOURCE_DOWNLOAD_TIMEOUT" \
        aria2c --allow-overwrite=true --auto-file-renaming=false --file-allocation=none \
          --max-connection-per-server=8 --split=8 --min-split-size=1M \
          --connect-timeout=15 --timeout=30 --max-tries=3 --retry-wait=3 --summary-interval=0 \
          --dir "$(dirname "$temporary")" --out "$(basename "$temporary")" "$candidate" \
        && [[ -s "$temporary" ]]; then
        mv -f -- "$temporary" "$destination"
        rm -f "$temporary.aria2"
        return 0
      fi
      rm -f "$temporary" "$temporary.aria2"
    done
  done < <(archive_url_variants "$canonical_url")

  while IFS= read -r candidate; do
    for mode in proxy direct; do
      [[ "$mode" != proxy ]] || has_network_proxy || continue
      echo "curl fallback: $(basename "$destination") via ${candidate%%:*}/$mode"
      if run_network_command "$mode" "$SOURCE_DOWNLOAD_TIMEOUT" \
        curl -fL --retry 3 --retry-all-errors --connect-timeout 15 --max-time "$SOURCE_DOWNLOAD_TIMEOUT" \
          -o "$temporary" "$candidate" \
        && [[ -s "$temporary" ]]; then
        mv -f -- "$temporary" "$destination"
        return 0
      fi
      rm -f "$temporary"
    done
  done < <(archive_url_variants "$canonical_url")
  return 1
}

local_source_is_usable() {
  local name="$1" repo_dir="$2" tag head upstream branch
  git -C "$repo_dir" diff --quiet && git -C "$repo_dir" diff --cached --quiet
  case "$name" in
    ffmpeg-source) return 1 ;;
    *)
      tag="$(git -C "$repo_dir" describe --tags --exact-match 2>/dev/null || true)"
      if [[ -n "$tag" && "$tag" =~ ${TAG_REGEX[$name]} ]]; then
        return 0
      fi
      head="$(git -C "$repo_dir" rev-parse HEAD)"
      for branch in master main; do
        upstream="$(git -C "$repo_dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null)" || continue
        [[ "$head" == "$upstream" ]] && return 0
      done
      return 1
      ;;
  esac
}

clone_if_missing() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local url="${URLS[$name]}"

  if [[ ! -e "$repo_dir/.git" ]]; then
    echo "===> clone $name from $url"
    git config --global http.version HTTP/1.1 || true
    git config --global http.postBuffer 1048576000 || true
    git_clone_retry "$url" "$repo_dir"
  fi
}

latest_stable_tag() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local regex="${TAG_REGEX[$name]}"
  local tag branch

  tag="$(git -C "$repo_dir" for-each-ref --format='%(refname:short)' refs/tags \
    | sed 's/\^{}$//' \
    | sort -u \
    | { grep -E "$regex" || true; } \
    | while read -r tag; do
        printf "%s	%s
" "$(normalize_version "$name" "$tag")" "$tag"
      done \
    | sort -V \
    | tail -n 1 \
    | cut -f2)"
  if [[ -n "$tag" ]]; then
    printf '%s
' "$tag"
    return 0
  fi

  # x264 publishes stable source as branches rather than version tags.
  for branch in stable master main; do
    if [[ "$regex" == *"$branch"* ]] \
      && git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      printf '%s
' "$branch"
      return 0
    fi
  done
}

verify_source_repo_clean() {
  local repo_dir="$1" status
  git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "无效的 Git 源码仓库: $repo_dir；为避免丢失内容，不会自动删除或重克隆" >&2
    return 1
  }
  status="$(git -C "$repo_dir" status --porcelain --untracked-files=normal)"
  if [[ -n "$status" ]]; then
    echo "源码仓库有本地修改，停止更新以保护现场: $repo_dir" >&2
    printf '%s\n' "$status" >&2
    return 1
  fi
}

checkout_stable() {
  local name="$1"
  local repo_dir="$ROOT/$name"
  local tag="$2"
  local ver
  ver="$(normalize_version "$name" "$tag")"

  if [[ "$name" == "ffmpeg-source" ]]; then
    echo "     -> Switching $name to branch $tag..."
    git -C "$repo_dir" checkout -B "$tag" "origin/$tag" 2>/dev/null || \
      git -C "$repo_dir" switch "$tag"
  elif git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$tag"; then
    echo "     -> Switching $name to branch $tag..."
    git -C "$repo_dir" checkout -B "$tag" "origin/$tag"
  else
    git -C "$repo_dir" switch --detach "$tag" 2>/dev/null || \
    git -C "$repo_dir" checkout --detach "$tag"
  fi

  git_retry git -C "$repo_dir" submodule update --init --recursive || true

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

  echo "===> verify clean source tree $name"
  verify_source_repo_clean "$repo_dir" || return 1

  # Keep the canonical URL after trying alternate transports below.
  local url="${URLS[$name]}"
  git -C "$repo_dir" remote set-url origin "$url" 2>/dev/null || true

  echo "===> fetch $name"
  if ! git_fetch_retry "$repo_dir" "$url"; then
    if [[ "${ALLOW_OFFLINE_STABLE_SOURCE:-0}" == "1" ]] \
      && local_source_is_usable "$name" "$repo_dir"; then
      echo "$name upstream Git unavailable; using existing verified stable source" >&2
    else
      echo "$name upstream Git unavailable; refusing to reuse a possibly stale source" >&2
      return 1
    fi
  fi

  local tag=""
  if [[ "$name" == "ffmpeg-source" ]]; then
    tag="$FFMPEG_REF"
  else
    tag="$(latest_stable_tag "$name")"
  fi

  if [[ -z "$tag" ]]; then
    echo "No stable release tag matched for $name; refusing to build an unversioned source" >&2
    return 1
  fi

  checkout_stable "$name" "$tag"
}

run_update() {
  local start="${1:-}" seen=0
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
    jxrlib
    expat
    brotli
    dav1d
    svtav1
    libvpl
    vapoursynth
    x264
    x265
    vmaf
    vvenc
    vvdec
    AudioToolboxWrapper
    sdl2
    zlib
    bzip2
    lzma
    libiconv
    libpng

    libxml2
    libmp3lame
    libogg
    libvorbis
    libsoxr
    fdk-aac
    libaom
    libvpx
    libopenjpeg
    mbedtls
    libssh
    opencl-headers
    opencl-loader
    libsnappy
    libtheora
    libspeex
    libtwolame
    libmysofa
    libopenmpt
    libdvdread
    libdvdnav
    chromaprint
    libzmq
    libzvbi
    libgsm
    opencore-amr
    vo-amrwbenc
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
    if [[ -n "$start" && "$seen" == "0" ]]; then
      [[ "$r" == "$start" ]] && seen=1 || continue
    fi
    update_one "$r"
  done

  [[ -z "$start" || "$seen" == "1" ]] || { echo "unknown update start repo: $start"; exit 1; }

  echo
  echo "All source trees are updated successfully."
  echo
  echo "== Source version manifest =="
  for r in "${repos[@]}"; do
    printf '%-24s ref=%-24s commit=%s\n' \
      "$r" \
      "$(git -C "$ROOT/$r" describe --tags --always 2>/dev/null || echo unknown)" \
      "$(git -C "$ROOT/$r" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  done
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
    libiconv|iconv) echo "libiconv" ;;
    libpng|png) echo "libpng" ;;

    libxml2|xml2) echo "libxml2" ;;
    libmp3lame|lame|mp3lame) echo "libmp3lame" ;;
    libogg|ogg) echo "libogg" ;;
    libvorbis|vorbis) echo "libvorbis" ;;
    libsoxr|soxr) echo "libsoxr" ;;
    fdk-aac|fdkaac|libfdk-aac|libfdk_aac|libfdk) echo "fdk-aac" ;;
    libaom|aom) echo "libaom" ;;
    libvpx|vpx) echo "libvpx" ;;
    libopenjpeg|openjpeg) echo "libopenjpeg" ;;
    mbedtls) echo "mbedtls" ;;
    libssh|ssh) echo "libssh" ;;
    opencl-headers|cl-headers) echo "opencl-headers" ;;
    opencl-loader|cl-loader|opencl) echo "opencl-loader" ;;
    libsnappy|snappy) echo "libsnappy" ;;
    libtheora|theora) echo "libtheora" ;;
    libspeex|speex) echo "libspeex" ;;
    libtwolame|twolame) echo "libtwolame" ;;
    libmysofa|mysofa) echo "libmysofa" ;;
    libopenmpt|openmpt) echo "libopenmpt" ;;
    libdvdread|dvdread) echo "libdvdread" ;;
    libdvdnav|dvdnav) echo "libdvdnav" ;;
    chromaprint) echo "chromaprint" ;;
    libzmq|zmq|zeromq) echo "libzmq" ;;
    libzvbi|zvbi) echo "libzvbi" ;;
    libgsm|gsm) echo "libgsm" ;;
    opencore-amr|opencore|amr) echo "opencore-amr" ;;
    vo-amrwbenc|voamrwbenc) echo "vo-amrwbenc" ;;
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
    jxrlib|jxr|jpegxr) echo "jxrlib" ;;
    dav1d) echo "dav1d" ;;
    svtav1|svt-av1|svt) echo "svtav1" ;;
    libvpl|vpl) echo "libvpl" ;;
    vapoursynth|vs) echo "vapoursynth" ;;
    x264) echo "x264" ;;
    x265) echo "x265" ;;
    vmaf) echo "vmaf" ;;
    vvenc) echo "vvenc" ;;
    vvdec) echo "vvdec" ;;
    audiotoolboxwrapper|audiotoolbox|atw) echo "AudioToolboxWrapper" ;;
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
  if [[ "$(printf '%s\n%s\n' "$req" "$have" | sort -V | head -n 1)" != "$req" ]]; then
    echo "Meson 版本过低: 当前 $have，需要 >= $req"
    echo "可先执行: ./ffmpeg.sh tool"
    exit 1
  fi
}

is_valid_cuda() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local found_cuda=0
  for h in "$dir/include/cuda.h" "$dir/targets/x86_64-linux/include/cuda.h"; do
    [[ -f "$h" ]] && found_cuda=1
  done
  [[ "$found_cuda" == "1" ]] || return 1
  return 0
}

find_cuda_home() {
  if is_valid_cuda "$CUDA_REDIST_ROOT"; then
    CUDA_HOME="$CUDA_REDIST_ROOT"
    return 0
  fi

  if [[ -n "$CUDA_HOME" ]]; then
    is_valid_cuda "$CUDA_HOME" || {
      echo "CUDA_HOME 缺少 cuda.h: $CUDA_HOME"
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

  echo "未找到完整的 CUDA Toolkit（需要 cuda.h）。请检查 /usr/local/cuda"
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

  if [[ "$name" != "ffmpeg-source" && "$INCREMENTAL_BUILD" == "1" && -d "$stage" ]]; then
    # FFmpeg always gets a clean tree so stale objects cannot survive source or patch changes.
    # Other dependencies may reuse their build tree when they represent the same source commit.
    # Reset only tracked source edits; keep generated objects/caches for make/ninja.
    if [[ -d "$src/.git" && -d "$stage/.git" ]]; then
      local src_head stage_has_head
      src_head="$(git -C "$src" rev-parse HEAD 2>/dev/null || true)"
      stage_has_head="$(git -C "$stage" cat-file -t "$src_head" 2>/dev/null || true)"
      if [[ -n "$src_head" && "$stage_has_head" == "commit" ]]; then
        git -C "$stage" reset --hard "$src_head" >/dev/null
        echo "$stage"
        return 0
      fi
    fi
  fi

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
  local meson_cuda=""
  [[ "$LTO_ENABLE" == "1" ]] && meson_lto=true
  if [[ "$CUDA_ENABLE" == "1" ]]; then
    setup_cuda
    meson_cuda="cuda = '$NVCC'"
  fi

  cat > "$BUILDROOT/mingw-cross.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
$meson_cuda
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

  if [[ "$name" == "opencore-amr" ]]; then
    # Its generated configure and tracked ltmain.sh can use different libtool versions.
    autoreconf -fiv
  elif [[ ! -x ./configure ]]; then
    if [[ "$name" == "libtwolame" ]]; then
      # twolame's autogen.sh immediately configures in maintainer mode and then
      # requires asciidoc. Generate the release build system without that step.
      autoreconf -fiv
    elif [[ -x ./autogen.sh ]]; then
      if [[ "$name" == "opus" ]]; then
        # ponytail: opus autogen downloads optional DNN data; FFmpeg libopus does not need it.
        sed -i '/dnn\/download_model\.sh/d' ./autogen.sh
      fi
      ./autogen.sh
    elif [[ -f ./bootstrap ]]; then
      ./bootstrap
    elif [[ -f configure.ac || -f configure.in ]]; then
      autoreconf -fiv
    fi
  fi

  CPPFLAGS="${CPPFLAGS:-} -I$PREFIX/include" \
  LDFLAGS="$LDFLAGS -L$PREFIX/lib" \
  ./configure \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    "$@"

  if [[ "$name" == "libtwolame" ]]; then
    make -C libtwolame -j"$JOBS"
    make -C libtwolame install
    install -Dm644 twolame.pc "$PREFIX/lib/pkgconfig/twolame.pc"
  else
    make -j"$JOBS"
    make install
  fi
  popd >/dev/null
}

build_cache_fingerprint() {
  local name="$1" stage="$2" kind="$3"
  shift 3
  local key tool var file
  {
    printf 'kind=%s\nname=%s\nstage=%s\n' "$kind" "$name" "$stage"
    for key in "$@"; do printf 'arg=%s\n' "$key"; done
    for var in TARGET PREFIX CC CXX AR RANLIB STRIP WINDRES DLLTOOL CFLAGS CXXFLAGS LDFLAGS OPT_FLAGS CPU_FLAGS LTO_ENABLE; do
      declare -p "$var" 2>/dev/null || printf '%s=<unset>\n' "$var"
    done
    for tool in "$CC" "$CXX" "$AR" cmake ninja meson; do
      [[ -n "$tool" ]] || continue
      printf 'tool=%s\n' "$tool"
      command -v "$tool" 2>/dev/null || true
      "$tool" --version 2>/dev/null | head -n 1 || true
    done
    if [[ -f "$BUILDROOT/mingw-cross.txt" ]]; then sha256sum "$BUILDROOT/mingw-cross.txt"; fi
    if git -C "$stage" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "$stage" rev-parse HEAD
      git -C "$stage" diff --binary HEAD | sha256sum
      while IFS= read -r -d '' file; do
        [[ -f "$stage/$file" ]] && sha256sum "$stage/$file"
      done < <(git -C "$stage" ls-files --others --exclude-standard -z)
    else
      find "$stage" -type f -not -path "$stage/.git/*" -print0 | sort -z | xargs -0 -r sha256sum
    fi
  } | sha256sum | awk '{print $1}'
}

build_cmake() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"
  if [[ "$name" == "libvpl" ]]; then
    local vpl_defs="$stage/libvpl/src/windows/mfx_dispatcher_defs.h"
    python3 - "$vpl_defs" <<'PYVPLMINGW'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "#if _MSC_VER < 1400"
new = "#if defined(_MSC_VER) && _MSC_VER < 1400"
old_count = s.count(old)
new_count = s.count(new)
if old_count == 1 and new_count == 0:
    p.write_text(s.replace(old, new, 1))
elif old_count == 0 and new_count == 1:
    pass
else:
    raise SystemExit(f"{p}: unexpected oneVPL MinGW wcscpy_s guard state: old={old_count}, new={new_count}")
PYVPLMINGW
  fi
  local bld="$BUILDROOT/$name"
  local ipo=OFF cache_key cache_stamp
  [[ "$LTO_ENABLE" == "1" ]] && ipo=ON
  cache_stamp="$BUILDROOT/.cache-keys/$name.cmake.sha256"
  if [[ "$INCREMENTAL_BUILD" == "1" ]]; then
    cache_key="$(build_cache_fingerprint "$name" "$stage" cmake "$@")"
    if [[ -d "$bld" && -f "$cache_stamp" && "$(<"$cache_stamp")" == "$cache_key" ]]; then
      echo "复用 $name 的 CMake 缓存（源码、工具链、配置指纹一致）"
    else
      rm -rf "$bld"
      rm -f "$cache_stamp"
    fi
  else
    rm -rf "$bld"
    rm -f "$cache_stamp"
  fi

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
  if [[ "$INCREMENTAL_BUILD" == "1" ]]; then
    mkdir -p "$(dirname "$cache_stamp")"
    printf '%s\n' "$cache_key" >"$cache_stamp.tmp"
    mv -f "$cache_stamp.tmp" "$cache_stamp"
  fi
}

build_meson() {
  local name="$1"
  shift
  local stage
  stage="$(stage_src "$name")"
  local bld="$BUILDROOT/$name"
  local cache_key cache_stamp cache_hit=0

  if [[ "$name" == "libdvdread" ]]; then
    # Its optional ChangeLog target runs `git log` from the Meson build dir.
    # Hide the staged reflog so Meson omits that non-runtime artifact.
    rm -f "$stage/.git/logs/HEAD"
  fi

  cache_stamp="$BUILDROOT/.cache-keys/$name.meson.sha256"
  if [[ "$INCREMENTAL_BUILD" == "1" ]]; then
    cache_key="$(build_cache_fingerprint "$name" "$stage" meson "$@" --cross-file "$BUILDROOT/mingw-cross.txt" --prefix "$PREFIX")"
    if [[ -d "$bld" && -f "$cache_stamp" && "$(<"$cache_stamp")" == "$cache_key" ]]; then
      cache_hit=1
      echo "复用 $name 的 Meson 缓存（源码、工具链、配置指纹一致）"
    else
      rm -rf "$bld"
      rm -f "$cache_stamp"
    fi
  else
    rm -rf "$bld"
    rm -f "$cache_stamp"
  fi

  if ((cache_hit)); then
    meson setup --reconfigure "$bld" "$stage" \
      --cross-file "$BUILDROOT/mingw-cross.txt" \
      --prefix "$PREFIX" \
      --buildtype release \
      --default-library=static \
      -Doptimization=3 \
      "$@"
  else
    meson setup "$bld" "$stage" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
      --prefix "$PREFIX" \
      --buildtype release \
      --default-library=static \
      -Doptimization=3 \
      "$@"
  fi

  meson compile -C "$bld" -j "$JOBS"
  meson install -C "$bld"
  if [[ "$INCREMENTAL_BUILD" == "1" ]]; then
    mkdir -p "$(dirname "$cache_stamp")"
    printf '%s\n' "$cache_key" >"$cache_stamp.tmp"
    mv -f "$cache_stamp.tmp" "$cache_stamp"
  fi
}

setup_build_env() {
  export PATH="$TOOLCHAIN_BIN:$CMAKE_ROOT/bin:$NINJA_ROOT/bin:$PYTOOLS_ROOT/bin:$NASM_ROOT/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"
  case "$TOOLCHAIN_FLAVOR" in
    llvm-mingw) export PATH="$LLVM_MINGW_ROOT/bin:$PATH" ;;
    xpack-mingw64-gcc) export PATH="$XPACK_MINGW_ROOT/bin:$PATH" ;;
  esac

  need_cmd python3
  need_cmd git
  need_cmd cmake
  need_cmd meson
  need_cmd ninja
  need_cmd make
  need_cmd autoreconf
  need_cmd pkg-config

  case "$TOOLCHAIN_FLAVOR" in
    llvm-mingw)
      CC="$(canonical_tool "${CC:-${TARGET}-clang}")"
      CXX="$(canonical_tool "${CXX:-${TARGET}-clang++}")"
      AR="$(canonical_tool "${AR:-llvm-ar}")"
      RANLIB="$(canonical_tool "${RANLIB:-llvm-ranlib}")"
      STRIP="$(canonical_tool "${STRIP:-llvm-strip}")"
      if [[ -n "${WINDRES:-}" ]]; then WINDRES="$(canonical_tool "$WINDRES")"; else WINDRES="$(first_tool "${TARGET}-windres" llvm-windres)"; fi
      if [[ -n "${DLLTOOL:-}" ]]; then DLLTOOL="$(canonical_tool "$DLLTOOL")"; else DLLTOOL="$(first_tool "${TARGET}-dlltool" llvm-dlltool)"; fi
      TOOLCHAIN_EXTRA_LIBS="${TOOLCHAIN_EXTRA_LIBS:-}"
      ;;
    xpack-mingw64-gcc)
      CC="$(canonical_tool "${CC:-${TARGET}-gcc}")"
      CXX="$(canonical_tool "${CXX:-${TARGET}-g++}")"
      AR="$(canonical_tool "${AR:-${TARGET}-ar}")"
      RANLIB="$(canonical_tool "${RANLIB:-${TARGET}-ranlib}")"
      STRIP="$(canonical_tool "${STRIP:-${TARGET}-strip}")"
      WINDRES="$(canonical_tool "${WINDRES:-${TARGET}-windres}")"
      DLLTOOL="$(canonical_tool "${DLLTOOL:-${TARGET}-dlltool}")"
      TOOLCHAIN_EXTRA_LIBS="${TOOLCHAIN_EXTRA_LIBS:--lstdc++ -lgcc}"
      ;;
    system)
      CC="$(canonical_tool "${CC:-${TARGET}-gcc-win32}")"
      CXX="$(canonical_tool "${CXX:-${TARGET}-g++-win32}")"
      AR="$(canonical_tool "${AR:-${TARGET}-ar}")"
      RANLIB="$(canonical_tool "${RANLIB:-${TARGET}-ranlib}")"
      STRIP="$(canonical_tool "${STRIP:-${TARGET}-strip}")"
      WINDRES="$(canonical_tool "${WINDRES:-${TARGET}-windres}")"
      DLLTOOL="$(canonical_tool "${DLLTOOL:-${TARGET}-dlltool}")"
      TOOLCHAIN_EXTRA_LIBS="${TOOLCHAIN_EXTRA_LIBS:--lstdc++ -lgcc}"
      ;;
    *)
      echo "未知 TOOLCHAIN_FLAVOR: $TOOLCHAIN_FLAVOR"
      exit 1
      ;;
  esac
  PKG_CONFIG="$(canonical_tool "${PKG_CONFIG:-pkg-config}")"

  export CC CXX AR RANLIB STRIP WINDRES PKG_CONFIG DLLTOOL TOOLCHAIN_EXTRA_LIBS
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
  # Control Flow Guard: -mguard=cf emits the guard tables, the linker flag sets
  # IMAGE_DLLCHARACTERISTICS_GUARD_CF so the loader validates indirect calls.
  if [[ "$CFG_ENABLE" == "1" && "$TOOLCHAIN_FLAVOR" == "llvm-mingw" ]]; then
    COMMON_OPT_FLAGS+=" -mguard=cf"
    LDFLAGS_BASE+=" -Wl,/guard:cf"
  fi
  if [[ "$TOOLCHAIN_FLAVOR" == "llvm-mingw" ]]; then
    LDFLAGS_BASE+=" -fuse-ld=lld"
  fi

  export CFLAGS="${CFLAGS:-$COMMON_OPT_FLAGS}"
  export CXXFLAGS="${CXXFLAGS:-$COMMON_OPT_FLAGS}"
  export LDFLAGS="${LDFLAGS:-$LDFLAGS_BASE}"

  mkdir -p "$BUILDROOT"
  write_meson_cross
}


is_system_runtime_dll() {
  local u="${1^^}"
  case "$u" in
    API-MS-WIN-*.DLL|EXT-MS-*.DLL|KERNEL32.DLL|NTDLL.DLL|UCRTBASE.DLL|VCRUNTIME*.DLL|MSVCRT.DLL) return 0 ;;
    USER32.DLL|GDI32.DLL|ADVAPI32.DLL|SHELL32.DLL|OLE32.DLL|OLEAUT32.DLL|COMDLG32.DLL|COMCTL32.DLL) return 0 ;;
    WS2_32.DLL|CRYPT32.DLL|BCRYPT.DLL|VERSION.DLL|SHLWAPI.DLL|SECUR32.DLL|IPHLPAPI.DLL|NCRYPT.DLL) return 0 ;;
    CFGMGR32.DLL|RUNTIMEOBJECT.DLL|RPCRT4.DLL) return 0 ;;
    D3D*.DLL|D2D1.DLL|DWRITE.DLL|DXGI.DLL|MF*.DLL|EVR.DLL|AVRT.DLL|PROPSYS.DLL|RTWORKQ.DLL) return 0 ;;
    AVICAP32.DLL|IMM32.DLL|SETUPAPI.DLL|WINMM.DLL|DSOUND.DLL|NVCUDA.DLL|NVENCODEAPI64.DLL|VULKAN-1.DLL) return 0 ;;
  esac
  return 1
}

require_wsl_tool() {
  local tool="$1" path
  path="$(type -P "$tool" || true)"
  [[ -n "$path" ]] || { echo "缺少 WSL 原生命令: $tool" >&2; exit 1; }
  case "$(realpath "$path")" in
    /mnt/*|*.exe) echo "$tool 必须是 WSL 原生程序: $path" >&2; exit 1 ;;
  esac
}

download_apple_installer() {
  local url="$1" installer="$2"
  [[ -s "$installer" ]] && 7z t "$installer" >/dev/null 2>&1 && return 0
  rm -f -- "$installer"
  download_file_retry "$installer" "$url"
  7z t "$installer" >/dev/null
}

extract_apple_audio_runtime() {
  local installer="$1" tmp msi core file dll_name target
  tmp="$(mktemp -d)"
  if ! 7z x -y "-o$tmp/itunes" "$installer" >/dev/null; then
    rm -rf -- "$tmp"
    return 1
  fi
  while IFS= read -r -d '' msi; do
    rm -rf -- "$tmp/apple"
    mkdir -p "$tmp/apple"
    7z x -y "-o$tmp/apple" "$msi" >/dev/null || continue
    while IFS= read -r -d '' file; do
      if ! llvm-objdump -f "$file" 2>/dev/null | grep 'file format coff-x86-64' >/dev/null; then
        continue
      fi
      dll_name="$(llvm-objdump -p "$file" 2>/dev/null | sed -n 's/^[[:space:]]*DLL name: //p' || true)"
      [[ "$dll_name" =~ ^[A-Za-z0-9._-]+\.dll$ ]] || continue
      target="$(dirname "$file")/$dll_name"
      [[ "$target" == "$file" ]] && continue
      if [[ -e "$target" ]]; then
        # ponytail: 7z exposes duplicate MSI streams without component paths; keep the first x64 DLL and let the AAC smoke test reject an incompatible duplicate.
        cmp -s "$file" "$target" || echo "保留首个 x64 Apple DLL: $dll_name" >&2
        rm -f -- "$file"
      else
        mv -f -- "$file" "$target"
      fi
    done < <(find "$tmp/apple" -type f -name 'fil*' -print0)
    core="$(find "$tmp/apple" -type f -iname 'CoreAudioToolbox.dll' -print -quit)"
    [[ -n "$core" ]] || continue
    rm -rf -- "$APPLE_AUDIO_RUNTIME_DIR"
    mkdir -p "$APPLE_AUDIO_RUNTIME_DIR"
    find "$tmp/apple" -type f -iname '*.dll' -exec cp -a {} "$APPLE_AUDIO_RUNTIME_DIR/" \;
    rm -rf -- "$tmp"
    return 0
  done < <(find "$tmp/itunes" -type f \( -iname 'AppleApplicationSupport*.msi' -o -iname 'iTunes*.msi' \) -print0)
  rm -rf -- "$tmp"
  return 1
}

prepare_apple_audio_runtime() {
  [[ "$APPLE_AUDIO_RUNTIME_DIR" == "$ROOT/toolchains/"* ]] || {
    echo "APPLE_AUDIO_RUNTIME_DIR 必须位于 $ROOT/toolchains" >&2
    exit 1
  }
  if find "$APPLE_AUDIO_RUNTIME_DIR" -type f -iname 'CoreAudioToolbox.dll' -print -quit 2>/dev/null | grep -q .; then
    return
  fi

  require_wsl_tool curl
  require_wsl_tool 7z
  mkdir -p "$(dirname "$APPLE_ITUNES_INSTALLER")"
  download_apple_installer "$APPLE_ITUNES_URL" "$APPLE_ITUNES_INSTALLER"
  extract_apple_audio_runtime "$APPLE_ITUNES_INSTALLER" || {
    echo "Apple Application Support 中未找到 CoreAudioToolbox.dll" >&2
    exit 1
  }
}

seed_apple_audio_runtime() {
  local core
  prepare_apple_audio_runtime
  core="$(find "$APPLE_AUDIO_RUNTIME_DIR" -type f -iname 'CoreAudioToolbox.dll' -print -quit)"
  [[ -n "$core" ]] || { echo "缺少 CoreAudioToolbox.dll" >&2; exit 1; }
  cp -f -- "$core" "$ROOT/full/"
}

is_apple_audio_runtime_dll() {
  [[ "$1" == "$APPLE_AUDIO_RUNTIME_DIR/"* ]]
}

find_runtime_dll() {
  local dll="$1" dir found
  for dir in \
    "$ROOT/full" "$APPLE_AUDIO_RUNTIME_DIR" "$PREFIX/bin" \
    "$LLVM_MINGW_ROOT/bin" "$LLVM_MINGW_ROOT/$TARGET/bin" "$(dirname "$CC")"; do
    [[ -d "$dir" ]] || continue
    if [[ "$dir" == "$APPLE_AUDIO_RUNTIME_DIR" ]]; then
      found="$(find "$dir" -type f -iname "$dll" -print -quit 2>/dev/null || true)"
    else
      found="$(find "$dir" -maxdepth 1 -type f -iname "$dll" -print -quit 2>/dev/null || true)"
    fi
    if [[ -n "$found" ]]; then
      printf '%s\n' "$found"
      return 0
    fi
  done
  return 1
}

copy_runtime_dll_closure() {
  local dst="$ROOT/full" dump_tool tmp imports missing changed file dll src
  mkdir -p "$dst"
  dump_tool="$(command -v llvm-objdump || command -v "$TARGET-objdump" || command -v objdump || true)"
  [[ -n "$dump_tool" ]] || { echo "找不到 objdump/llvm-objdump，无法检查 DLL 依赖"; exit 1; }

  tmp="$(mktemp -d)"
  # ponytail: RETURN trap leaks into later functions under set -u; clean up explicitly.
  changed=1
  while [[ "$changed" == "1" ]]; do
    changed=0
    : > "$tmp/imports"
    while IFS= read -r file; do
      "$dump_tool" -p "$file" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p' >> "$tmp/imports" || true
    done < <(find "$dst" -type f \( -iname '*.exe' -o -iname '*.dll' \) -print)
    sort -fu "$tmp/imports" > "$tmp/imports.sorted"
    while IFS= read -r dll; do
      [[ -n "$dll" ]] || continue
      is_system_runtime_dll "$dll" && continue
      if find "$dst" -maxdepth 1 -type f -iname "$dll" -print -quit | grep -q .; then
        continue
      fi
      src="$(find_runtime_dll "$dll" || true)"
      if [[ -n "$src" ]]; then
        cp -f "$src" "$dst/"
        is_apple_audio_runtime_dll "$src" || "$STRIP" "$dst/$(basename "$src")" 2>/dev/null || true
        changed=1
      else
        printf '%s\n' "$dll" >> "$tmp/missing"
      fi
    done < "$tmp/imports.sorted"
  done

  if [[ -s "$tmp/missing" ]]; then
    echo "缺少非系统运行时 DLL:" >&2
    sort -fu "$tmp/missing" >&2
    exit 1
  fi
  rm -rf "$tmp"
}


write_jxrlib_cmake() {
  local stage="$1"
  cat > "$stage/CMakeLists.txt" <<'JXR_CMAKE'
cmake_minimum_required(VERSION 3.13)
project(jxrlib C)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(JXR_INC common/include image/sys jxrgluelib jxrtestlib)
set(JXR_SYS
  image/sys/adapthuff.c image/sys/image.c image/sys/strcodec.c
  image/sys/strPredQuant.c image/sys/strTransform.c image/sys/perfTimerANSI.c)
set(JXR_DEC
  image/decode/decode.c image/decode/postprocess.c image/decode/segdec.c
  image/decode/strdec.c image/decode/strdec_x86.c image/decode/strInvTransform.c
  image/decode/strPredQuantDec.c image/decode/JXRTranscode.c)
set(JXR_ENC
  image/encode/encode.c image/encode/segenc.c image/encode/strenc.c
  image/encode/strenc_x86.c image/encode/strFwdTransform.c image/encode/strPredQuantEnc.c)
set(JXR_GLUE
  jxrgluelib/JXRGlue.c jxrgluelib/JXRMeta.c
  jxrgluelib/JXRGluePFC.c jxrgluelib/JXRGlueJxr.c)
set(JXR_TEST
  jxrtestlib/JXRTest.c jxrtestlib/JXRTestBmp.c jxrtestlib/JXRTestHdr.c
  jxrtestlib/JXRTestPnm.c jxrtestlib/JXRTestTif.c jxrtestlib/JXRTestYUV.c)
add_library(jpegxr STATIC ${JXR_SYS} ${JXR_DEC} ${JXR_ENC})
target_include_directories(jpegxr PRIVATE ${JXR_INC})
target_compile_definitions(jpegxr PRIVATE __ANSI__ DISABLE_PERF_MEASUREMENT)
add_library(jxrglue STATIC ${JXR_GLUE} ${JXR_TEST})
target_include_directories(jxrglue PRIVATE ${JXR_INC})
target_compile_definitions(jxrglue PRIVATE __ANSI__ DISABLE_PERF_MEASUREMENT)
target_link_libraries(jxrglue PRIVATE jpegxr)
install(TARGETS jpegxr jxrglue ARCHIVE DESTINATION lib)
install(FILES
  jxrgluelib/JXRGlue.h jxrgluelib/JXRMeta.h jxrtestlib/JXRTest.h
  image/sys/windowsmediaphoto.h DESTINATION include/jxrlib)
install(DIRECTORY common/include/ DESTINATION include/jxrlib FILES_MATCHING PATTERN "*.h")
JXR_CMAKE
}

build_jxrlib() {
  local stage bld
  stage="$(stage_src jxrlib)"
  python3 - "$stage/image/sys/strcodec.c" <<'PYJXRLIST'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_bytes()
old = b"    FailIf(pWS->state.buf.cbBuf < pWS->state.buf.cbCur + cb, WMP_errBufferOverflow);\n"
new = (b"    /* WriteWS_List allocates the next PACKETLENGTH buffer on demand in\n"
       b"       the loop below, so rejecting a write against the already\n"
       b"       allocated total dropped every packet after the first and\n"
       b"       silently truncated any image larger than one packet. */\n")
start = s.index(b"ERR WriteWS_List(")
end = s.index(b"\n}\n", start)
body = s[start:end]
old_count = body.count(old)
new_count = body.count(new)
if old_count == 1 and new_count == 0:
    s = s[:start] + body.replace(old, new, 1) + s[end:]
elif old_count == 0 and new_count == 1:
    pass
else:
    raise SystemExit(f"{p}: unexpected WriteWS_List capacity-check state: old={old_count}, new={new_count}")
p.write_bytes(s)
PYJXRLIST
  rm -f "$stage/common/include/guiddef.h"
  write_jxrlib_cmake "$stage"
  bld="$BUILDROOT/jxrlib"
  rm -rf "$bld"
  cmake -S "$stage" -B "$bld" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows \
    -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_AR="$AR" \
    -DCMAKE_RANLIB="$RANLIB" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$bld" --parallel "$JOBS"
  cmake --install "$bld"
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/libjxr.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/jxrlib

Name: libjxr
Description: JPEG XR reference codec library
Version: 1.1
Libs: -L\${libdir} -ljxrglue -ljpegxr
Libs.private: -lm
Cflags: -I\${includedir}
EOF
  PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists libjxr || {
    echo "libjxr pkg-config validation failed" >&2
    exit 1
  }
}

patch_ffmpeg_jxr() {
  local ff_stage="$1"
  python3 - "$ff_stage" <<'PYJXR'
from pathlib import Path
import sys
root = Path(sys.argv[1])

def replace_once(rel, old, new):
    path = root / rel
    text = path.read_text()
    old = old.replace(r"\n", "\n")
    new = new.replace(r"\n", "\n")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{rel}: JXR patch anchor count={count}, expected 1")
    path.write_text(text.replace(old, new, 1))

replace_once("configure",
    "  --enable-libjxl          enable JPEG XL de/encoding via libjxl [no]\\n",
    "  --enable-libjxl          enable JPEG XL de/encoding via libjxl [no]\\n"
    "  --enable-libjxr          enable JPEG XR de/encoding via jxrlib [no]\\n")
replace_once("configure", "    libjxl\\n", "    libjxl\\n    libjxr\\n")
replace_once("configure",
    'libjxl_encoder_deps="libjxl libjxl_threads"\\n',
    'libjxl_encoder_deps="libjxl libjxl_threads"\\n'
    'libjxr_decoder_deps="libjxr"\\n'
    'libjxr_encoder_deps="libjxr"\\n')
replace_once("configure",
    'enabled libjxl            && require_pkg_config libjxl "libjxl >= 0.7.0" jxl/decode.h JxlDecoderVersion &&\\n'
    '                             require_pkg_config libjxl_threads "libjxl_threads >= 0.7.0" jxl/thread_parallel_runner.h JxlThreadParallelRunner\\n',
    'enabled libjxl            && require_pkg_config libjxl "libjxl >= 0.7.0" jxl/decode.h JxlDecoderVersion &&\\n'
    '                             require_pkg_config libjxl_threads "libjxl_threads >= 0.7.0" jxl/thread_parallel_runner.h JxlThreadParallelRunner\\n'
    'enabled libjxr            && require_pkg_config libjxr libjxr JXRGlue.h PKCreateCodecFactory\\n')
replace_once("libavcodec/codec_id.h",
    "    AV_CODEC_ID_ASTC,\\n\\n    /* various PCM \"codecs\" */\\n    AV_CODEC_ID_FIRST_AUDIO = 0x10000,     ///< A dummy id pointing at the start of audio codecs",
    "    AV_CODEC_ID_ASTC,\\n    AV_CODEC_ID_JPEGXR = 0x7F00,\\n\\n"
    "    /* various PCM \"codecs\" */\\n    AV_CODEC_ID_FIRST_AUDIO = 0x10000,     ///< A dummy id pointing at the start of audio codecs")
replace_once("libavcodec/codec_desc.c",
    '    /* various PCM "codecs" */\\n',
    '''    {
        .id        = AV_CODEC_ID_JPEGXR,
        .type      = AVMEDIA_TYPE_VIDEO,
        .name      = "jpegxr",
        .long_name = NULL_IF_CONFIG_SMALL("JPEG XR"),
        .props     = AV_CODEC_PROP_INTRA_ONLY | AV_CODEC_PROP_LOSSY |
                     AV_CODEC_PROP_LOSSLESS,
        .mime_types= MT("image/jxr", "image/vnd.ms-photo"),
    },

    /* various PCM "codecs" */
''')
replace_once("libavcodec/allcodecs.c",
    "extern const FFCodec ff_libjxl_encoder;\\n",
    "extern const FFCodec ff_libjxl_encoder;\\n"
    "extern const FFCodec ff_libjxr_decoder;\\n"
    "extern const FFCodec ff_libjxr_encoder;\\n")
replace_once("libavcodec/Makefile",
    "OBJS-$(CONFIG_LIBJXL_ENCODER)             += libjxlenc.o libjxl.o\\n",
    "OBJS-$(CONFIG_LIBJXL_ENCODER)             += libjxlenc.o libjxl.o\\n"
    "OBJS-$(CONFIG_LIBJXR_DECODER)             += libjxrdec.o\\n"
    "OBJS-$(CONFIG_LIBJXR_ENCODER)             += libjxrenc.o\\n")
replace_once("libavformat/img2.c",
    "    TAG(JPEGXS,          jxs      )",
    "    TAG(JPEGXR,          jxr      ) " + chr(92) + "\n"
    "    TAG(JPEGXR,          wdp      ) " + chr(92) + "\n"
    "    TAG(JPEGXR,          hdp      ) " + chr(92) + "\n"
    "    TAG(JPEGXS,          jxs      )")
replace_once("libavformat/img2enc.c",
    '    .p.extensions   = "bmp,dpx,exr,jls,jpeg,jpg,jxs,jxl,ljpg,pam,pbm,pcx,pfm,pgm,pgmyuv,phm,"\\n',
    '    .p.extensions   = "bmp,dpx,exr,jls,jpeg,jpg,jxs,jxl,jxr,ljpg,pam,pbm,pcx,pfm,pgm,pgmyuv,phm,"\\n')

(root / "libavcodec/libjxrenc.c").write_text(r'''/*
 * JPEG XR encoding support via jxrlib.
 * Generated in the staged FFmpeg tree by ffmpeg.sh.
 */
#include <limits.h>
#include "libavutil/pixdesc.h"
#include "avcodec.h"
#include "codec_internal.h"
#include "encode.h"
#include <JXRGlue.h>

extern ERR CreateWS_List(struct WMPStream **ppWS);

static int libjxr_pixfmt_to_guid(enum AVPixelFormat fmt,
                                 PKPixelFormatGUID *guid, int *has_alpha)
{
    *has_alpha = 0;
    switch (fmt) {
    case AV_PIX_FMT_GRAY8:    *guid = GUID_PKPixelFormat8bppGray; return 0;
    case AV_PIX_FMT_GRAY16LE: *guid = GUID_PKPixelFormat16bppGray; return 0;
    case AV_PIX_FMT_RGB24:    *guid = GUID_PKPixelFormat24bppRGB; return 0;
    case AV_PIX_FMT_BGR24:    *guid = GUID_PKPixelFormat24bppBGR; return 0;
    case AV_PIX_FMT_RGBA:     *guid = GUID_PKPixelFormat32bppRGBA; *has_alpha = 1; return 0;
    case AV_PIX_FMT_BGRA:     *guid = GUID_PKPixelFormat32bppBGRA; *has_alpha = 1; return 0;
    case AV_PIX_FMT_RGB48LE:  *guid = GUID_PKPixelFormat48bppRGB; return 0;
    case AV_PIX_FMT_RGBA64LE: *guid = GUID_PKPixelFormat64bppRGBA; *has_alpha = 1; return 0;
    case AV_PIX_FMT_RGBAF16LE: *guid = GUID_PKPixelFormat64bppRGBAHalf; *has_alpha = 1; return 0;
    case AV_PIX_FMT_RGBF16LE:  *guid = GUID_PKPixelFormat48bppRGBHalf; return 0;
    case AV_PIX_FMT_RGBAF32LE: *guid = GUID_PKPixelFormat128bppRGBAFloat; *has_alpha = 1; return 0;
    case AV_PIX_FMT_GRAYF16LE: *guid = GUID_PKPixelFormat16bppGrayHalf; return 0;
    case AV_PIX_FMT_GRAYF32LE: *guid = GUID_PKPixelFormat32bppGrayFloat; return 0;
    default: return AVERROR(EINVAL);
    }
}

static int libjxr_encode_frame(AVCodecContext *avctx, AVPacket *pkt,
                               const AVFrame *frame, int *got_packet)
{
    PKCodecFactory *factory = NULL;
    PKImageEncode *encoder = NULL;
    struct WMPStream *stream = NULL;
    PKPixelFormatGUID guid;
    CWMIStrCodecParam params = { 0 };
    size_t output_size = 0;
    int has_alpha = 0, ret;
    ERR jerr = WMP_errSuccess;

    if (frame->linesize[0] < 0)
        return AVERROR(EINVAL);
    ret = libjxr_pixfmt_to_guid(avctx->pix_fmt, &guid, &has_alpha);
    if (ret < 0) {
        av_log(avctx, AV_LOG_ERROR, "Unsupported JPEG XR pixel format: %s\\n",
               av_get_pix_fmt_name(avctx->pix_fmt));
        return ret;
    }

    params.bVerbose = FALSE;
    params.cfColorFormat = YUV_444;
    params.bdBitDepth = BD_LONG;
    params.bfBitstreamFormat = FREQUENCY;
    params.bProgressiveMode = TRUE;
    params.olOverlap = OL_ONE;
    params.sbSubband = SB_ALL;
    params.uAlphaMode = has_alpha ? 2 : 0;
    params.uiDefaultQPIndex = 1;
    params.uiDefaultQPIndexAlpha = 1;

    if ((jerr = CreateWS_List(&stream)) != WMP_errSuccess ||
        (jerr = PKCreateCodecFactory(&factory, WMP_SDK_VERSION)) != WMP_errSuccess ||
        (jerr = factory->CreateCodec(&IID_PKImageWmpEncode, (void **)&encoder)) != WMP_errSuccess ||
        (jerr = encoder->Initialize(encoder, stream, &params, sizeof(params))) != WMP_errSuccess ||
        (jerr = encoder->SetPixelFormat(encoder, guid)) != WMP_errSuccess ||
        (jerr = encoder->SetSize(encoder, avctx->width, avctx->height)) != WMP_errSuccess ||
        (jerr = encoder->SetResolution(encoder, 96.0f, 96.0f)) != WMP_errSuccess ||
        (jerr = encoder->WritePixels(encoder, avctx->height, frame->data[0],
                                     frame->linesize[0])) != WMP_errSuccess) {
        ret = AVERROR_EXTERNAL;
        goto fail;
    }

    if (encoder->WMP.nOffImage < 0 || encoder->WMP.nCbImage <= 0 ||
        encoder->WMP.nOffImage > INT_MAX - encoder->WMP.nCbImage) {
        av_log(avctx, AV_LOG_ERROR, "Invalid JPEG XR image extent\\n");
        ret = AVERROR_INVALIDDATA;
        goto cleanup;
    }
    output_size = (size_t)encoder->WMP.nOffImage + (size_t)encoder->WMP.nCbImage;

    if (has_alpha && params.uAlphaMode == 2) {
        size_t alpha_end;
        if (encoder->WMP.nOffAlpha < 0 || encoder->WMP.nCbAlpha <= 0 ||
            encoder->WMP.nOffAlpha > INT_MAX - encoder->WMP.nCbAlpha) {
            av_log(avctx, AV_LOG_ERROR, "Invalid JPEG XR alpha extent\\n");
            ret = AVERROR_INVALIDDATA;
            goto cleanup;
        }
        alpha_end = (size_t)encoder->WMP.nOffAlpha + (size_t)encoder->WMP.nCbAlpha;
        if (alpha_end > output_size)
            output_size = alpha_end;
    }

    if (!output_size || output_size > INT_MAX ||
        (jerr = stream->SetPos(stream, 0)) != WMP_errSuccess) {
        ret = AVERROR_EXTERNAL;
        goto fail;
    }

    if ((ret = ff_alloc_packet(avctx, pkt, (int)output_size)) < 0)
        goto cleanup;
    if ((jerr = stream->Read(stream, pkt->data, output_size)) != WMP_errSuccess) {
        av_packet_unref(pkt);
        ret = AVERROR_EXTERNAL;
        goto fail;
    }
    *got_packet = 1;
    ret = 0;
    goto cleanup;

fail:
    av_log(avctx, AV_LOG_ERROR, "jxrlib JPEG XR encode failed (error=%d)\\n", (int)jerr);
cleanup:
    if (encoder) {
        if (encoder->pStream)
            stream = NULL;
        encoder->Release(&encoder);
    }
    if (stream)
        stream->Close(&stream);
    if (factory)
        factory->Release(&factory);
    return ret;
}

const FFCodec ff_libjxr_encoder = {
    .p.name = "libjxr",
    CODEC_LONG_NAME("JPEG XR via jxrlib"),
    .p.type = AVMEDIA_TYPE_VIDEO,
    .p.id = AV_CODEC_ID_JPEGXR,
    .p.capabilities = AV_CODEC_CAP_DR1 | AV_CODEC_CAP_ENCODER_REORDERED_OPAQUE,
    FF_CODEC_ENCODE_CB(libjxr_encode_frame),
    CODEC_PIXFMTS(AV_PIX_FMT_GRAY8, AV_PIX_FMT_GRAY16LE,
                  AV_PIX_FMT_RGB24, AV_PIX_FMT_BGR24,
                  AV_PIX_FMT_RGBA, AV_PIX_FMT_BGRA,
                  AV_PIX_FMT_RGB48LE, AV_PIX_FMT_RGBA64LE,
                  AV_PIX_FMT_RGBAF16LE, AV_PIX_FMT_RGBF16LE,
                  AV_PIX_FMT_RGBAF32LE, AV_PIX_FMT_GRAYF16LE,
                  AV_PIX_FMT_GRAYF32LE),
    .p.wrapper_name = "libjxr",
};
''')

(root / "libavcodec/libjxrdec.c").write_text(r'''/*
 * JPEG XR decoding support via jxrlib.
 * Generated in the staged FFmpeg tree by ffmpeg.sh.
 */
#include "avcodec.h"
#include "codec_internal.h"
#include "decode.h"
#include <JXRGlue.h>

static enum AVPixelFormat libjxr_guid_to_pixfmt(const PKPixelFormatGUID *guid,
                                                 int *bits)
{
    *bits = 8;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat8bppGray)) return AV_PIX_FMT_GRAY8;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat16bppGray)) { *bits = 16; return AV_PIX_FMT_GRAY16LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat24bppRGB)) return AV_PIX_FMT_RGB24;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat24bppBGR)) return AV_PIX_FMT_BGR24;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppRGBA)) return AV_PIX_FMT_RGBA;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppBGRA)) return AV_PIX_FMT_BGRA;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat48bppRGB)) { *bits = 16; return AV_PIX_FMT_RGB48LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat64bppRGBA)) { *bits = 16; return AV_PIX_FMT_RGBA64LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat64bppRGBAHalf)) { *bits = 16; return AV_PIX_FMT_RGBAF16LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat48bppRGBHalf)) { *bits = 16; return AV_PIX_FMT_RGBF16LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat128bppRGBAFloat)) { *bits = 32; return AV_PIX_FMT_RGBAF32LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppPRGBA)) return AV_PIX_FMT_RGBA;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppBGR)) return AV_PIX_FMT_BGR0;
    if (IsEqualGUID(guid, &GUID_PKPixelFormat32bppGrayFloat)) { *bits = 32; return AV_PIX_FMT_GRAYF32LE; }
    if (IsEqualGUID(guid, &GUID_PKPixelFormat16bppGrayHalf)) { *bits = 16; return AV_PIX_FMT_GRAYF16LE; }
    return AV_PIX_FMT_NONE;
}

static int libjxr_decode_frame(AVCodecContext *avctx, AVFrame *frame,
                               int *got_frame, AVPacket *pkt)
{
    PKFactory *factory = NULL;
    PKCodecFactory *codec_factory = NULL;
    PKImageDecode *decoder = NULL;
    struct WMPStream *stream = NULL;
    PKPixelFormatGUID guid;
    PKRect rect = { 0, 0, 0, 0 };
    enum AVPixelFormat pix_fmt;
    I32 width = 0, height = 0;
    int bits = 0, ret = AVERROR_INVALIDDATA;
    ERR jerr = WMP_errSuccess;

    if (pkt->size <= 0)
        return AVERROR_INVALIDDATA;
    if ((jerr = PKCreateFactory(&factory, PK_SDK_VERSION)) != WMP_errSuccess ||
        (jerr = factory->CreateStreamFromMemory(&stream, pkt->data, pkt->size)) != WMP_errSuccess ||
        (jerr = PKCreateCodecFactory(&codec_factory, WMP_SDK_VERSION)) != WMP_errSuccess ||
        (jerr = codec_factory->CreateCodec(&IID_PKImageWmpDecode, (void **)&decoder)) != WMP_errSuccess ||
        (jerr = decoder->Initialize(decoder, stream)) != WMP_errSuccess ||
        (jerr = decoder->GetSize(decoder, &width, &height)) != WMP_errSuccess ||
        width <= 0 || height <= 0 ||
        (jerr = decoder->GetPixelFormat(decoder, &guid)) != WMP_errSuccess)
        goto fail;

    pix_fmt = libjxr_guid_to_pixfmt(&guid, &bits);
    if (pix_fmt == AV_PIX_FMT_NONE) {
        av_log(avctx, AV_LOG_ERROR, "Unsupported JPEG XR pixel format GUID\\n");
        ret = AVERROR(ENOSYS);
        goto cleanup;
    }
    if ((ret = ff_set_dimensions(avctx, width, height)) < 0)
        goto cleanup;
    avctx->pix_fmt = pix_fmt;
    avctx->bits_per_raw_sample = bits;
    if ((ret = ff_get_buffer(avctx, frame, 0)) < 0)
        goto cleanup;

    rect.Width = width;
    rect.Height = height;
    if ((jerr = decoder->Copy(decoder, &rect, frame->data[0],
                              frame->linesize[0])) != WMP_errSuccess)
        goto fail;
    *got_frame = 1;
    ret = pkt->size;
    goto cleanup;

fail:
    av_log(avctx, AV_LOG_ERROR, "jxrlib JPEG XR decode failed (error=%d)\\n", (int)jerr);
cleanup:
    if (decoder)
        decoder->Release(&decoder);
    if (stream)
        stream->Close(&stream);
    if (codec_factory)
        codec_factory->Release(&codec_factory);
    if (factory)
        factory->Release(&factory);
    return ret;
}

const FFCodec ff_libjxr_decoder = {
    .p.name = "libjxr",
    CODEC_LONG_NAME("JPEG XR via jxrlib"),
    .p.type = AVMEDIA_TYPE_VIDEO,
    .p.id = AV_CODEC_ID_JPEGXR,
    .p.capabilities = AV_CODEC_CAP_DR1,
    FF_CODEC_DECODE_CB(libjxr_decode_frame),
    .p.wrapper_name = "libjxr",
};
''')
PYJXR
}

verify_jxr_binary() {
  local exe="$1" test_dir="${2:-$BUILDROOT/jxr-validation}"
  local encoders decoders win_test_dir
  encoders="$("$exe" -hide_banner -encoders 2>/dev/null | tr -d '\r')"
  decoders="$("$exe" -hide_banner -decoders 2>/dev/null | tr -d '\r')"
  grep -q '[[:space:]]libjxr[[:space:]]' <<<"$encoders" || { echo "libjxr encoder missing" >&2; exit 1; }
  grep -q '[[:space:]]libjxr[[:space:]]' <<<"$decoders" || { echo "libjxr decoder missing" >&2; exit 1; }
  rm -rf "$test_dir"
  mkdir -p "$test_dir"
  win_test_dir="$(wslpath -w "$test_dir")"
  python3 - "$test_dir/input.rgb" <<'PYRGB'
from pathlib import Path
import sys
w = h = 16
buf = bytearray()
for y in range(h):
    for x in range(w):
        buf += bytes(((x * 17) & 255, (y * 17) & 255, ((x ^ y) * 17) & 255))
Path(sys.argv[1]).write_bytes(buf)
PYRGB
  "$exe" -hide_banner -loglevel error \
    -f rawvideo -pixel_format rgb24 -video_size 16x16 -i "$win_test_dir/input.rgb" \
    -frames:v 1 -c:v libjxr "$win_test_dir/test.jxr"
  "$exe" -hide_banner -loglevel error \
    -i "$win_test_dir/test.jxr" -frames:v 1 -pix_fmt rgb24 -f rawvideo "$win_test_dir/output.rgb"
  cmp -s "$test_dir/input.rgb" "$test_dir/output.rgb" || {
    echo "JPEG XR lossless RGB24 round-trip mismatch" >&2
    exit 1
  }
  echo "JPEG XR libjxr lossless RGB24 encode/decode: OK"
}

patch_ffmpeg_libplacebo_vulkan_import() {
  local ff_stage="$1" cfg="$PREFIX/include/libplacebo/config.h" api
  [[ -f "$cfg" ]] || return 0
  api="$(sed -n 's/^#define PL_API_VER[[:space:]]\+\([0-9]\+\).*/\1/p' "$cfg" | head -n1)"
  [[ -n "$api" ]] || return 0
  if (( api >= 365 )); then
    return 0
  fi

  echo "== Patch FFmpeg Vulkan queue import for libplacebo API $api < 365 =="
  # ponytail: libplacebo API 360 cannot import FFmpeg Vulkan queues created with
  # VK_KHR_internally_synchronized_queues flags. Disable that optional extension
  # so FFmpeg falls back to its own queue locks and vf_libplacebo can import it.
  perl -0pi -e 's/#ifdef VK_KHR_internally_synchronized_queues\n([[:space:]]*\{ VK_KHR_INTERNALLY_SYNCHRONIZED_QUEUES_EXTENSION_NAME,[[:space:]]*FF_VK_EXT_INTERNAL_QUEUE_SYNC[[:space:]]*\},\n)#endif/#if 0 \&\& defined(VK_KHR_internally_synchronized_queues)\n$1#endif/g' \
    "$ff_stage/libavutil/hwcontext_vulkan.c" \
    "$ff_stage/libavutil/vulkan_loader.h"
}

patch_ffmpeg_cxx_runtime() {
  local ff_stage="$1"
  [[ "$TOOLCHAIN_FLAVOR" == "llvm-mingw" ]] || return 0
  # FFmpeg's configure assumes GNU libstdc++; llvm-mingw ships libc++.
  sed -i 's/-lstdc++/-lc++/g' "$ff_stage/configure"
}

patch_ffmpeg_nvenc_hdr10plus() {
  local ff_stage="$1"
  local nvenc_c="$ff_stage/libavcodec/nvenc.c"

  if grep -q 'nvenc_alloc_hdr10_plus_payload' "$nvenc_c"; then
    echo "FFmpeg NVENC HDR10+ passthrough patch already applied"
    return 0
  fi
  if grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$nvenc_c"; then
    echo "FFmpeg NVENC already contains HDR10+ side-data handling; skip local patch"
    return 0
  fi

  echo "== Patch FFmpeg NVENC HDR10+ passthrough =="
  git -C "$ff_stage" apply --recount --whitespace=nowarn <<'PATCH_NVENC_HDR10PLUS'
diff --git a/libavcodec/nvenc.c b/libavcodec/nvenc.c
index 5ea094e095..0b138e1ccd 100644
--- a/libavcodec/nvenc.c
+++ b/libavcodec/nvenc.c
@@ -31,6 +31,7 @@
 #include "libavutil/hwcontext_cuda.h"
 #include "libavutil/hwcontext.h"
 #include "libavutil/cuda_check.h"
+#include "libavutil/hdr_dynamic_metadata.h"
 #include "libavutil/imgutils.h"
 #include "libavutil/mem.h"
 #include "libavutil/pixdesc.h"
@@ -40,9 +41,11 @@
 #include "libavutil/stereo3d.h"
 #include "libavutil/tdrdi.h"
 #include "atsc_a53.h"
+#include "bytestream.h"
 #include "codec_desc.h"
 #include "encode.h"
 #include "internal.h"
+#include "itut35.h"
 
 #define CHECK_CU(x) FF_CUDA_CHECK_DL(avctx, dl_fn->cuda_dl, x)
 
@@ -2723,6 +2726,47 @@ static int output_ready(AVCodecContext *avctx, int flush)
     return (nb_ready > 0) && (nb_ready + nb_pending >= ctx->async_depth);
 }
 
+static int nvenc_alloc_hdr10_plus_payload(const AVFrame *frame, uint8_t **data, size_t *size)
+{
+    const AVFrameSideData *side_data =
+        av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
+    const AVDynamicHDRPlus *hdr_plus;
+    uint8_t *payload;
+    size_t payload_size;
+    int ret;
+
+    if (!side_data) {
+        *data = NULL;
+        *size = 0;
+        return 0;
+    }
+
+    hdr_plus = (const AVDynamicHDRPlus *)side_data->data;
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, NULL, &payload_size);
+    if (ret < 0)
+        return ret;
+
+    *size = payload_size + 6;
+    *data = av_malloc(*size);
+    if (!*data)
+        return AVERROR(ENOMEM);
+
+    payload = *data;
+    bytestream_put_byte(&payload, ITU_T_T35_COUNTRY_CODE_US);
+    bytestream_put_be16(&payload, ITU_T_T35_PROVIDER_CODE_SAMSUNG);
+    bytestream_put_be16(&payload, 0x0001);
+    bytestream_put_byte(&payload, 0x04);
+
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, &payload, &payload_size);
+    if (ret < 0) {
+        av_freep(data);
+        *size = 0;
+        return ret;
+    }
+
+    return 1;
+}
+
 static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)
 {
     NvencContext *ctx = avctx->priv_data;
@@ -2797,6 +2841,43 @@ static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)
         }
     }
 
+    if (avctx->codec->id == AV_CODEC_ID_HEVC
+#if CONFIG_AV1_NVENC_ENCODER
+        || avctx->codec->id == AV_CODEC_ID_AV1
+#endif
+    ) {
+        uint8_t *hdr_plus_data = NULL;
+        size_t hdr_plus_size = 0;
+
+        res = nvenc_alloc_hdr10_plus_payload(frame, &hdr_plus_data, &hdr_plus_size);
+        if (res < 0) {
+            av_log(ctx, AV_LOG_ERROR, "Error serializing HDR10+ metadata\n");
+            goto error;
+        }
+
+        if (res > 0) {
+            void *tmp = av_fast_realloc(ctx->sei_data,
+                                        &ctx->sei_data_size,
+                                        (sei_count + 1) * sizeof(*ctx->sei_data));
+            if (!tmp) {
+                av_free(hdr_plus_data);
+                res = AVERROR(ENOMEM);
+                goto error;
+            }
+
+            ctx->sei_data = tmp;
+            ctx->sei_data[sei_count].payloadSize = (uint32_t)hdr_plus_size;
+            ctx->sei_data[sei_count].payload = hdr_plus_data;
+#if CONFIG_AV1_NVENC_ENCODER
+            if (avctx->codec->id == AV_CODEC_ID_AV1)
+                ctx->sei_data[sei_count].payloadType = AV1_METADATA_TYPE_ITUT_T35;
+            else
+#endif
+                ctx->sei_data[sei_count].payloadType = SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;
+            sei_count++;
+        }
+    }
+
     if (!ctx->udu_sei)
         return sei_count;
PATCH_NVENC_HDR10PLUS
}

patch_ffmpeg_nvenc_dovi_p8_p10() {
  local ff_stage="$1"
  local nvenc_c="$ff_stage/libavcodec/nvenc.c"
  local nvenc_h="$ff_stage/libavcodec/nvenc.h"

  if grep -q 'nvenc_alloc_dovi_payload' "$nvenc_c"; then
    echo "FFmpeg NVENC HEVC Profile 8 / AV1 Profile 10 Dolby Vision RPU patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg NVENC HEVC P8 / AV1 P10 Dolby Vision RPU injection =="
  python3 - "$nvenc_h" "$nvenc_c" <<'PYDOVINVENC'
from pathlib import Path
import sys

header, source = map(Path, sys.argv[1:])

def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"{path}: expected one patch anchor, found {text.count(old)}: {old[:72]!r}")
    path.write_text(text.replace(old, new, 1))

replace_once(
    header,
    '#include "avcodec.h"\n',
    '#include "avcodec.h"\n#include "dovi_rpu.h"\n',
)
replace_once(
    header,
    '    NV_ENC_SEI_PAYLOAD *sei_data;\n    int sei_data_size;\n',
    '    NV_ENC_SEI_PAYLOAD *sei_data;\n    int sei_data_size;\n    DOVIContext dovi;\n',
)
replace_once(
    source,
    '    int i, res;\n\n    if (ctx->a53_cc && av_frame_get_side_data(frame, AV_FRAME_DATA_A53_CC)) {\n',
    r'''    int i, res;

#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
    if (avctx->codec->id == AV_CODEC_ID_AV1 ||
        avctx->codec->id == AV_CODEC_ID_HEVC) {
        uint8_t *dovi_data = NULL;
        int dovi_size = 0;

        res = nvenc_alloc_dovi_payload(avctx, ctx, frame, &dovi_data, &dovi_size);
        if (res < 0)
            goto error;
        if (dovi_data) {
            void *tmp;
            if (dovi_size <= 0) {
                av_free(dovi_data);
                res = AVERROR_INVALIDDATA;
                goto error;
            }
            tmp = av_fast_realloc(ctx->sei_data, &ctx->sei_data_size,
                                  (sei_count + 1) * sizeof(*ctx->sei_data));
            if (!tmp) {
                av_free(dovi_data);
                res = AVERROR(ENOMEM);
                goto error;
            }
            ctx->sei_data = tmp;
            ctx->sei_data[sei_count].payloadSize = (uint32_t)dovi_size;
            if (avctx->codec->id == AV_CODEC_ID_AV1)
                ctx->sei_data[sei_count].payloadType = AV1_METADATA_TYPE_ITUT_T35;
            else
                ctx->sei_data[sei_count].payloadType = SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;
            ctx->sei_data[sei_count].payload = dovi_data;
            sei_count++;
        }
    }
#endif

    if (!ctx->extra_sei)
        return sei_count;

    if (ctx->a53_cc && av_frame_get_side_data(frame, AV_FRAME_DATA_A53_CC)) {
''',
)
replace_once(
    source,
    'static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)\n',
    r'''#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
static int nvenc_alloc_dovi_payload(AVCodecContext *avctx, NvencContext *ctx,
                                        const AVFrame *frame, uint8_t **data,
                                        int *size)
{
    const AVFrameSideData *sd =
        av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);

    *data = NULL;
    *size = 0;
    if (!sd)
        return 0;
    if (!ctx->dovi.cfg.dv_profile) {
        av_log(avctx, AV_LOG_ERROR,
               "Dolby Vision metadata is present, but a valid Dolby Vision codec configuration "
               "could not be derived. Preserve 10-bit 4:2:0 and the source color tags.\n");
        return AVERROR_INVALIDDATA;
    }

    return ff_dovi_rpu_generate(&ctx->dovi,
                                (const AVDOVIMetadata *)sd->data,
                                FF_DOVI_WRAP_T35, data, size);
}
#endif

static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)
''',
)
replace_once(
    source,
    '        if (ctx->extra_sei) {\n            res = prepare_sei_data_array(avctx, frame);\n',
    r'''        if (ctx->extra_sei
#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
            || ((avctx->codec->id == AV_CODEC_ID_AV1 ||
                 avctx->codec->id == AV_CODEC_ID_HEVC) &&
                av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA))
#endif
        ) {
            res = prepare_sei_data_array(avctx, frame);
''',
)
replace_once(
    source,
    '    NvencContext *ctx = avctx->priv_data;\n    int ret;\n\n    if (IS_HWACCEL(avctx->pix_fmt)) {\n',
    r'''    NvencContext *ctx = avctx->priv_data;
    int ret;

#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER
    if (avctx->codec->id == AV_CODEC_ID_AV1 ||
        avctx->codec->id == AV_CODEC_ID_HEVC) {
        const enum AVPixelFormat pix_fmt = avctx->pix_fmt;

        ctx->dovi.logctx = avctx;
        ctx->dovi.enable = FF_DOVI_AUTOMATIC;
        if (ctx->data_pix_fmt == AV_PIX_FMT_P010)
            avctx->pix_fmt = AV_PIX_FMT_YUV420P10;
        ret = ff_dovi_configure(&ctx->dovi, avctx);
        avctx->pix_fmt = pix_fmt;
        if (ret < 0)
            return ret;
    }
#endif

    if (IS_HWACCEL(avctx->pix_fmt)) {
''',
)
replace_once(
    source,
    '    int i, res;\n\n    /* the encoder has to be flushed before it can be closed */\n',
    '    int i, res;\n\n#if CONFIG_AV1_NVENC_ENCODER || CONFIG_HEVC_NVENC_ENCODER\n    ff_dovi_ctx_unref(&ctx->dovi);\n#endif\n\n    /* the encoder has to be flushed before it can be closed */\n',
)
PYDOVINVENC
}

patch_ffmpeg_libx265_hdr10plus() {
  local ff_stage="$1"
  local x265_c="$ff_stage/libavcodec/libx265.c"

  if grep -q 'libx265_add_hdr10_plus' "$x265_c"; then
    echo "FFmpeg libx265 HDR10+ passthrough patch already applied"
    return 0
  fi
  if grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$x265_c"; then
    echo "FFmpeg libx265 already contains HDR10+ side-data handling; skip local patch"
    return 0
  fi

  echo "== Patch FFmpeg libx265 HDR10+ passthrough =="
  git -C "$ff_stage" apply --recount --whitespace=nowarn <<'PATCH_LIBX265_HDR10PLUS'
diff --git a/libavcodec/libx265.c b/libavcodec/libx265.c
index c5e6b8c150..913927e7e1 100644
--- a/libavcodec/libx265.c
+++ b/libavcodec/libx265.c
@@ -29,17 +29,20 @@
 
 #include "libavutil/avassert.h"
 #include "libavutil/buffer.h"
+#include "libavutil/hdr_dynamic_metadata.h"
 #include "libavutil/internal.h"
 #include "libavutil/mastering_display_metadata.h"
 #include "libavutil/mem.h"
 #include "libavutil/opt.h"
 #include "libavutil/pixdesc.h"
 #include "avcodec.h"
+#include "bytestream.h"
 #include "codec_internal.h"
 #include "dovi_rpu.h"
 #include "encode.h"
 #include "atsc_a53.h"
 #include "sei.h"
+#include "itut35.h"
 
 #if defined(X265_ENABLE_ALPHA) && MAX_LAYERS > 2
 #define FF_X265_MAX_LAYERS MAX_LAYERS
@@ -698,6 +701,71 @@ static av_cold int libx265_encode_set_roi(libx265Context *ctx, const AVFrame *fr
     return 0;
 }
 
+static int libx265_add_hdr10_plus(AVCodecContext *avctx, const AVFrame *frame,
+                                  x265_picture *pic)
+{
+    libx265Context *ctx = avctx->priv_data;
+    const AVFrameSideData *side_data;
+    const AVDynamicHDRPlus *hdr_plus;
+    x265_sei *sei = &pic->userSEI;
+    x265_sei_payload *sei_payload;
+    uint8_t *hdr_plus_buf, *payload;
+    size_t payload_size, hdr_plus_size;
+    void *tmp;
+    int ret;
+
+    /* An explicit x265 JSON source takes precedence over frame side data. */
+    if (av_dict_get(ctx->x265_opts, "dhdr10-info", NULL, 0))
+        return 0;
+
+    side_data = av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
+    if (!side_data)
+        return 0;
+
+    hdr_plus = (const AVDynamicHDRPlus *)side_data->data;
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, NULL, &payload_size);
+    if (ret < 0) {
+        av_log(avctx, AV_LOG_ERROR, "Error finding the size of HDR10+ metadata\n");
+        return ret;
+    }
+
+    hdr_plus_size = payload_size + 6;
+    hdr_plus_buf = av_malloc(hdr_plus_size);
+    if (!hdr_plus_buf)
+        return AVERROR(ENOMEM);
+
+    payload = hdr_plus_buf;
+    bytestream_put_byte(&payload, ITU_T_T35_COUNTRY_CODE_US);
+    bytestream_put_be16(&payload, ITU_T_T35_PROVIDER_CODE_SAMSUNG);
+    bytestream_put_be16(&payload, 0x0001);
+    bytestream_put_byte(&payload, 0x04);
+
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, &payload, &payload_size);
+    if (ret < 0) {
+        av_free(hdr_plus_buf);
+        av_log(avctx, AV_LOG_ERROR, "Error serializing HDR10+ metadata\n");
+        return ret;
+    }
+
+    tmp = av_fast_realloc(ctx->sei_data, &ctx->sei_data_size,
+                          (sei->numPayloads + 1) * sizeof(*sei_payload));
+    if (!tmp) {
+        av_free(hdr_plus_buf);
+        return AVERROR(ENOMEM);
+    }
+
+    ctx->sei_data = tmp;
+    sei->payloads = ctx->sei_data;
+    sei_payload = &sei->payloads[sei->numPayloads];
+    sei_payload->payload = hdr_plus_buf;
+    sei_payload->payloadSize = (int)hdr_plus_size;
+    sei_payload->payloadType =
+        (SEIPayloadType)SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;
+    sei->numPayloads++;
+
+    return 0;
+}
+
 static void free_picture(libx265Context *ctx, x265_picture *pic)
 {
     x265_sei *sei = &pic->userSEI;
@@ -813,6 +881,12 @@ static int libx265_encode_frame(AVCodecContext *avctx, AVPacket *pkt,
             }
         }
 
+        ret = libx265_add_hdr10_plus(avctx, pic, &x265pic);
+        if (ret < 0) {
+            free_picture(ctx, &x265pic);
+            return ret;
+        }
+
         if (ctx->udu_sei) {
             for (i = 0; i < pic->nb_side_data; i++) {
                 AVFrameSideData *side_data = pic->side_data[i];
PATCH_LIBX265_HDR10PLUS
}

patch_ffmpeg_svtav1_hdr10plus() {
  local ff_stage="$1"
  local svt_c="$ff_stage/libavcodec/libsvtav1.c"

  if grep -q 'add_hdr_plus' "$svt_c"; then
    echo "FFmpeg libsvtav1 HDR10+ passthrough patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg libsvtav1 HDR10+ passthrough =="
  git -C "$ff_stage" apply --recount --whitespace=nowarn <<'PATCH_SVTAV1_HDR10PLUS'
--- a/libavcodec/libsvtav1.c
+++ b/libavcodec/libsvtav1.c
@@ -42,6 +42,7 @@
 #include "dovi_rpu.h"
 #include "encode.h"
 #include "avcodec.h"
+#include "bytestream.h"
 #include "profiles.h"
 
 typedef enum eos_status {
@@ -146,6 +147,15 @@
 
 }
 
+
+/* HDR10+ dynamic metadata (SMPTE ST 2094-40) carried in an AV1 T35 metadata
+ * OBU, per "HDR10+ AV1 Metadata Handling Specification" v1.0.1, section 2.1. */
+#define ITU_T_T35_COUNTRY_CODE_US        0xB5
+#define ITU_T_T35_PROVIDER_CODE_SAMSUNG  0x003C
+#define HDR10PLUS_PROVIDER_ORIENTED_CODE  0x0001
+#define HDR10PLUS_APPLICATION_IDENTIFIER  0x04
+#define HDR10PLUS_T35_HEADER_SIZE         6
+
 static void handle_mdcv(struct EbSvtAv1MasteringDisplayInfo *dst,
                         const AVMasteringDisplayMetadata *mdcv)
 {
@@ -182,6 +192,59 @@
                 av_rescale_q(1, mdcv->min_luminance,
                              (AVRational){ 1, (1 << 14) }));
     }
+}
+
+
+static int add_hdr_plus(AVCodecContext *avctx, EbBufferHeaderType *headerPtr,
+                        const AVFrame *frame)
+{
+    const AVFrameSideData *sd = av_frame_get_side_data(frame,
+                                                       AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
+    const AVDynamicHDRPlus *hdr_plus;
+    uint8_t *buf, *payload;
+    size_t payload_size;
+    int ret;
+
+    if (!sd)
+        return 0;
+
+    hdr_plus = (const AVDynamicHDRPlus *)sd->data;
+
+    /* First call with data == NULL only queries the serialized size. */
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, NULL, &payload_size);
+    if (ret < 0) {
+        av_log(avctx, AV_LOG_ERROR, "Error finding the size of HDR10+\n");
+        return ret;
+    }
+
+    buf = av_malloc(payload_size + HDR10PLUS_T35_HEADER_SIZE);
+    if (!buf)
+        return AVERROR(ENOMEM);
+
+    payload = buf;
+    bytestream_put_byte(&payload, ITU_T_T35_COUNTRY_CODE_US);
+    bytestream_put_be16(&payload, ITU_T_T35_PROVIDER_CODE_SAMSUNG);
+    bytestream_put_be16(&payload, HDR10PLUS_PROVIDER_ORIENTED_CODE);
+    bytestream_put_byte(&payload, HDR10PLUS_APPLICATION_IDENTIFIER);
+
+    /* With *data non-NULL to_t35 writes in place; size is in/out and must
+     * already hold the capacity. */
+    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, &payload, &payload_size);
+    if (ret < 0) {
+        av_free(buf);
+        av_log(avctx, AV_LOG_ERROR, "Error encoding HDR10+ from side data\n");
+        return ret;
+    }
+
+    ret = svt_add_metadata(headerPtr, EB_AV1_METADATA_TYPE_ITUT_T35, buf,
+                           payload_size + HDR10PLUS_T35_HEADER_SIZE);
+    av_free(buf);
+    if (ret < 0) {
+        av_log(avctx, AV_LOG_ERROR, "Error adding HDR10+ to SVT-AV1 buffer\n");
+        return AVERROR(ENOMEM);
+    }
+
+    return 0;
 }
 
 static void handle_side_data(AVCodecContext *avctx,
@@ -594,6 +657,11 @@
 
     if (avctx->gop_size == 1)
         headerPtr->pic_type = EB_AV1_KEY_PICTURE;
+
+    ret = add_hdr_plus(avctx, headerPtr, frame);
+    if (ret < 0)
+        return ret;
+
 
     sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
     if (svt_enc->dovi.cfg.dv_profile && sd) {
PATCH_SVTAV1_HDR10PLUS

  # The patch's new code needs AVDynamicHDRPlus / av_dynamic_hdr_plus_to_t35.
  # libaomenc.c includes this header explicitly and no libavcodec header pulls it
  # in transitively, so the patch as shipped does not compile without it.
  python3 - "$svt_c" <<'PYSVTINC'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '#include "libavutil/mastering_display_metadata.h"\n'
new = old + '#include "libavutil/hdr_dynamic_metadata.h"\n'
if s.count(new) == 1:
    pass
elif s.count(old) == 1:
    p.write_text(s.replace(old, new, 1))
else:
    raise SystemExit(f"{p}: unexpected mastering_display include state")
PYSVTINC
}

patch_ffmpeg_libaom_hdr_static() {
  local ff_stage="$1"
  local aom_c="$ff_stage/libavcodec/libaomenc.c"

  if grep -q 'add_hdr_static' "$aom_c"; then
    echo "FFmpeg libaom static HDR10 (MDCV/CLL) patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg libaom static HDR10 (MDCV/CLL) =="
  python3 - "$aom_c" <<'PYAOMSTATIC'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

inc_old = '#include "libavutil/hdr_dynamic_metadata.h"\n'
inc_new = inc_old + '#include "libavutil/mastering_display_metadata.h"\n'
if inc_new not in s:
    if s.count(inc_old) != 1:
        raise SystemExit(f"{p}: hdr_dynamic_metadata include anchor not unique")
    s = s.replace(inc_old, inc_new, 1)

helper = r"""/* Static HDR10 metadata (AV1 metadata OBUs 1/2). libaomenc.c had no MDCV/CLL
 * path at all, so HDR10+ output lost the HDR10 fallback that non-HDR10+
 * players need. Payload layout and scaling follow vaapi_encode_av1.c. */
static int add_hdr_static(AVCodecContext *avctx, struct aom_image *img,
                          const AVFrame *frame)
{
    const AVFrameSideData *sd_mdcv =
        av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    const AVFrameSideData *sd_cll =
        av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);

    if (sd_mdcv) {
        const AVMasteringDisplayMetadata *mdm =
            (const AVMasteringDisplayMetadata *)sd_mdcv->data;
        if (mdm->has_primaries && mdm->has_luminance) {
            const int chroma_den = 1 << 16, max_luma_den = 1 << 8, min_luma_den = 1 << 14;
            uint8_t payload[24], *q = payload;
            int i;
            for (i = 0; i < 3; i++) {
                bytestream_put_be16(&q, av_rescale(mdm->display_primaries[i][0].num, chroma_den, mdm->display_primaries[i][0].den));
                bytestream_put_be16(&q, av_rescale(mdm->display_primaries[i][1].num, chroma_den, mdm->display_primaries[i][1].den));
            }
            bytestream_put_be16(&q, av_rescale(mdm->white_point[0].num, chroma_den, mdm->white_point[0].den));
            bytestream_put_be16(&q, av_rescale(mdm->white_point[1].num, chroma_den, mdm->white_point[1].den));
            bytestream_put_be32(&q, av_rescale(mdm->max_luminance.num, max_luma_den, mdm->max_luminance.den));
            bytestream_put_be32(&q, av_rescale(mdm->min_luminance.num, min_luma_den, mdm->min_luminance.den));
            if (aom_img_add_metadata(img, OBU_METADATA_TYPE_HDR_MDCV, payload,
                                     sizeof(payload), AOM_MIF_KEY_FRAME) != AOM_CODEC_OK) {
                av_log(avctx, AV_LOG_ERROR, "Error adding HDR MDCV to aom_img\n");
                return AVERROR(ENOMEM);
            }
        }
    }

    if (sd_cll) {
        const AVContentLightMetadata *cll = (const AVContentLightMetadata *)sd_cll->data;
        uint8_t payload[4], *q = payload;
        bytestream_put_be16(&q, cll->MaxCLL);
        bytestream_put_be16(&q, cll->MaxFALL);
        if (aom_img_add_metadata(img, OBU_METADATA_TYPE_HDR_CLL, payload,
                                 sizeof(payload), AOM_MIF_KEY_FRAME) != AOM_CODEC_OK) {
            av_log(avctx, AV_LOG_ERROR, "Error adding HDR CLL to aom_img\n");
            return AVERROR(ENOMEM);
        }
    }

    return 0;
}

"""

anchor = 'static int add_hdr_plus(AVCodecContext *avctx, struct aom_image *img, const AVFrame *frame)'
if s.count(anchor) != 1:
    raise SystemExit(f"{p}: add_hdr_plus anchor not unique")
s = s.replace(anchor, helper + anchor, 1)

call_old = '        aom_img_remove_metadata(rawimg);\n'
call_new = ('        aom_img_remove_metadata(rawimg);\n'
            '        if ((res = add_hdr_static(avctx, rawimg, frame)) < 0)\n'
            '            return res;\n')
if s.count(call_old) != 1:
    raise SystemExit(f"{p}: dovi call anchor not unique")
s = s.replace(call_old, call_new, 1)

p.write_text(s)
PYAOMSTATIC
}

patch_ffmpeg_nvenc_hdr_static() {
  local ff_stage="$1"
  local nvenc_c="$ff_stage/libavcodec/nvenc.c"

  if grep -q 'nvenc_alloc_hdr_static_payload' "$nvenc_c"; then
    echo "FFmpeg NVENC static HDR10 (MDCV/CLL) patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg NVENC static HDR10 (MDCV/CLL) =="
  python3 - "$nvenc_c" <<'PYNVENCSTATIC'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

helper = r"""/* Static HDR10 metadata for AV1. NVENC's AV1 encoder ignores
 * NV_ENC_CONFIG_AV1.outputMasteringDisplay / outputMaxCll - hevc_nvenc writes
 * MDCV/CLL, av1_nvenc does not - so push them through the AV1 OBU payload
 * array, which nvenc.c already feeds from ctx->sei_data. */
static int nvenc_alloc_hdr_static_payload(const AVFrame *frame, int metadata_type,
                                          uint8_t **data, size_t *size)
{
    const AVFrameSideData *sd_mdcv =
        av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    const AVFrameSideData *sd_cll =
        av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);

    *data = NULL;
    *size = 0;

    if (metadata_type == AV1_METADATA_TYPE_HDR_MDCV && sd_mdcv) {
        const AVMasteringDisplayMetadata *mdm = (const AVMasteringDisplayMetadata *)sd_mdcv->data;
        const int chroma_den = 1 << 16, max_luma_den = 1 << 8, min_luma_den = 1 << 14;
        uint8_t *buf, *q;
        int i;

        if (!mdm->has_primaries || !mdm->has_luminance)
            return 0;

        buf = q = av_malloc(24);
        if (!buf)
            return AVERROR(ENOMEM);

        for (i = 0; i < 3; i++) {
            bytestream_put_be16(&q, av_rescale(mdm->display_primaries[i][0].num, chroma_den, mdm->display_primaries[i][0].den));
            bytestream_put_be16(&q, av_rescale(mdm->display_primaries[i][1].num, chroma_den, mdm->display_primaries[i][1].den));
        }
        bytestream_put_be16(&q, av_rescale(mdm->white_point[0].num, chroma_den, mdm->white_point[0].den));
        bytestream_put_be16(&q, av_rescale(mdm->white_point[1].num, chroma_den, mdm->white_point[1].den));
        bytestream_put_be32(&q, av_rescale(mdm->max_luminance.num, max_luma_den, mdm->max_luminance.den));
        bytestream_put_be32(&q, av_rescale(mdm->min_luminance.num, min_luma_den, mdm->min_luminance.den));

        *data = buf;
        *size = 24;
        return 1;
    }

    if (metadata_type == AV1_METADATA_TYPE_HDR_CLL && sd_cll) {
        const AVContentLightMetadata *cll = (const AVContentLightMetadata *)sd_cll->data;
        uint8_t *buf, *q;

        buf = q = av_malloc(4);
        if (!buf)
            return AVERROR(ENOMEM);

        bytestream_put_be16(&q, cll->MaxCLL);
        bytestream_put_be16(&q, cll->MaxFALL);

        *data = buf;
        *size = 4;
        return 1;
    }

    return 0;
}

"""

anchor = 'static int prepare_sei_data_array(AVCodecContext *avctx, const AVFrame *frame)'
if s.count(anchor) != 1:
    raise SystemExit(f"{p}: prepare_sei_data_array anchor not unique")
s = s.replace(anchor, helper + anchor, 1)

call_old = '    if (!ctx->udu_sei)\n        return sei_count;\n'
call_new = r"""    if (avctx->codec->id == AV_CODEC_ID_AV1) {
        static const int hdr_static_types[] = {
            AV1_METADATA_TYPE_HDR_MDCV, AV1_METADATA_TYPE_HDR_CLL,
        };
        size_t t;

        for (t = 0; t < FF_ARRAY_ELEMS(hdr_static_types); t++) {
            uint8_t *payload_data = NULL;
            size_t payload_size = 0;
            void *tmp;

            res = nvenc_alloc_hdr_static_payload(frame, hdr_static_types[t],
                                                 &payload_data, &payload_size);
            if (res < 0)
                goto error;
            if (res == 0)
                continue;

            tmp = av_fast_realloc(ctx->sei_data, &ctx->sei_data_size,
                                  (sei_count + 1) * sizeof(*ctx->sei_data));
            if (!tmp) {
                av_free(payload_data);
                res = AVERROR(ENOMEM);
                goto error;
            }

            ctx->sei_data = tmp;
            ctx->sei_data[sei_count].payloadSize = (uint32_t)payload_size;
            ctx->sei_data[sei_count].payload = payload_data;
            ctx->sei_data[sei_count].payloadType = hdr_static_types[t];
            sei_count++;
        }
    }

""" + call_old
if s.count(call_old) != 1:
    raise SystemExit(f"{p}: udu_sei anchor not unique")
s = s.replace(call_old, call_new, 1)

p.write_text(s)
PYNVENCSTATIC
}

patch_ffmpeg_qsv_hdr10plus() {
  local ff_stage="$1"
  local qsv_c="$ff_stage/libavcodec/qsvenc.c"

  if grep -q 'set_hdr10plus_payload' "$qsv_c"; then
    echo "FFmpeg QSV HDR10+ payload patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg QSV HDR10+ payload =="
  python3 - "$qsv_c" <<'PYQSVHDR10PLUS'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

inc_anchor = '#include "qsvenc.h"\n'
inc_new = (inc_anchor +
           '#include "libavutil/hdr_dynamic_metadata.h"\n'
           '#include "bytestream.h"\n'
           '#include "itut35.h"\n'
           '#include "sei.h"\n')
if '#include "itut35.h"' not in s:
    if s.count(inc_anchor) != 1:
        raise SystemExit(f"{p}: qsvenc.h include anchor not unique")
    s = s.replace(inc_anchor, inc_new, 1)

helper = r"""/* HDR10+ (SMPTE ST 2094-40) through the oneVPL per-frame payload channel.
 * mfxPayload's per-codec support table (mfxstructures.h) lists MPEG2/AVC/HEVC,
 * with HEVC accepting all payload types; AV1 has neither a payload channel nor
 * an AV1 metadata extension buffer, so av1_qsv cannot carry HDR10+. */
static int set_hdr10plus_payload(AVCodecContext *avctx, const AVFrame *frame,
                                 mfxEncodeCtrl *enc_ctrl)
{
    const AVFrameSideData *sd;
    const AVDynamicHDRPlus *hdr_plus;
    mfxPayload *payload;
    uint8_t *buf, *q;
    size_t payload_size, t35_len;
    int ret;

    if (avctx->codec_id != AV_CODEC_ID_HEVC)
        return 0;
    if (enc_ctrl->NumPayload >= QSV_MAX_ENC_PAYLOAD)
        return 0;

    sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
    if (!sd)
        return 0;
    hdr_plus = (const AVDynamicHDRPlus *)sd->data;

    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, NULL, &payload_size);
    if (ret < 0) {
        av_log(avctx, AV_LOG_ERROR, "Error finding the size of HDR10+\n");
        return ret;
    }

    t35_len = payload_size + 6;
    if (t35_len > 255) {
        av_log(avctx, AV_LOG_ERROR,
               "HDR10+ T35 payload too large for the oneVPL SEI channel (%zu)\n", t35_len);
        return 0;
    }

    /* oneVPL wants the SEI header inside Data: the payload type byte, then the
     * payload size byte, then the payload. qsvenc_h264.c's A53 caption payload
     * does the same, and without the header the runtime drops the payload. */
    buf = av_mallocz(t35_len + 2);
    if (!buf)
        return AVERROR(ENOMEM);

    q = buf;
    bytestream_put_byte(&q, SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35);
    bytestream_put_byte(&q, (uint8_t)t35_len);
    bytestream_put_byte(&q, ITU_T_T35_COUNTRY_CODE_US);
    bytestream_put_be16(&q, ITU_T_T35_PROVIDER_CODE_SAMSUNG);
    bytestream_put_be16(&q, 0x0001);
    bytestream_put_byte(&q, 0x04);

    ret = av_dynamic_hdr_plus_to_t35(hdr_plus, &q, &payload_size);
    if (ret < 0) {
        av_free(buf);
        av_log(avctx, AV_LOG_ERROR, "Error serializing HDR10+ metadata\n");
        return ret;
    }

    payload = av_mallocz(sizeof(*payload));
    if (!payload) {
        av_free(buf);
        return AVERROR(ENOMEM);
    }
    payload->Data    = buf;
    payload->BufSize = t35_len + 2;
    payload->NumBit  = payload->BufSize * 8;
    payload->Type    = SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;

    /* Filled into QSVFrame.payloads; free_encoder_ctrl() releases it. */
    enc_ctrl->Payload[enc_ctrl->NumPayload++] = payload;

    return 0;
}

"""

helper_anchor = 'static int set_roi_encode_ctrl(AVCodecContext *avctx, const AVFrame *frame,'
if s.count(helper_anchor) != 1:
    raise SystemExit(f"{p}: set_roi_encode_ctrl anchor not unique")
s = s.replace(helper_anchor, helper + helper_anchor, 1)

call_anchor = '        set_skip_frame_encode_ctrl(avctx, frame, enc_ctrl);\n'
call_new = (call_anchor +
            '\n'
            '    if (enc_ctrl) {\n'
            '        ret = set_hdr10plus_payload(avctx, frame, enc_ctrl);\n'
            '        if (ret < 0)\n'
            '            goto free;\n'
            '    }\n')
if s.count(call_anchor) != 1:
    raise SystemExit(f"{p}: skip_frame call anchor not unique")
s = s.replace(call_anchor, call_new, 1)

p.write_text(s)
PYQSVHDR10PLUS

  grep -q 'set_hdr10plus_payload(avctx, frame, enc_ctrl)' "$qsv_c" || {
    echo "FFmpeg QSV HDR10+ payload injection is missing"
    exit 1
  }
}


patch_ffmpeg_qsv_dovi_p8() {
  local ff_stage="$1"
  local qsv_c="$ff_stage/libavcodec/qsvenc.c"
  local qsv_h="$ff_stage/libavcodec/qsvenc.h"

  if grep -q 'set_dovi_rpu_payload' "$qsv_c"; then
    grep -q 'DOVIContext dovi;' "$qsv_h" || { echo "Partial QSV Dolby Vision patch detected"; exit 1; }
    echo "FFmpeg QSV HEVC Dolby Vision P8 patch already applied"
    return 0
  fi

  echo "== Patch FFmpeg QSV HEVC Dolby Vision P8 payload =="
  python3 - "$qsv_c" "$qsv_h" <<'PYQSVDOVI'
from pathlib import Path
import sys

c_path, h_path = map(Path, sys.argv[1:])
s = c_path.read_text()
hs = h_path.read_text()

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: patch anchor count={count}, expected 1")
    return text.replace(old, new, 1)

if '#include "dovi_rpu.h"' not in hs:
    hs = replace_once(hs, '#include "qsv_internal.h"\n',
                      '#include "qsv_internal.h"\n#include "dovi_rpu.h"\n', h_path)
if '    DOVIContext dovi;\n' not in hs:
    hs = replace_once(hs, '    int a53_cc;\n',
                      '    int a53_cc;\n    DOVIContext dovi;\n', h_path)

helper = r"""static int set_dovi_rpu_payload(AVCodecContext *avctx, const AVFrame *frame,
                                 QSVEncContext *q, mfxEncodeCtrl *enc_ctrl)
{
    const AVFrameSideData *sd;
    mfxPayload *payload;
    uint8_t *rpu = NULL, *buf, *dst;
    size_t rpu_size, size_bytes, total;
    int rpu_size_int, ret;

    if (avctx->codec_id != AV_CODEC_ID_HEVC)
        return 0;
    sd = av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
    if (!sd)
        return 0;
    if (!q->dovi.cfg.dv_profile) {
        av_log(avctx, AV_LOG_ERROR,
               "Dolby Vision metadata is present, but no HEVC Dolby Vision configuration is available\n");
        return AVERROR_INVALIDDATA;
    }
    if (enc_ctrl->NumPayload >= QSV_MAX_ENC_PAYLOAD) {
        av_log(avctx, AV_LOG_ERROR, "No oneVPL payload slot remains for the Dolby Vision RPU\n");
        return AVERROR(ENOSPC);
    }

    ret = ff_dovi_rpu_generate(&q->dovi, (const AVDOVIMetadata *)sd->data,
                               FF_DOVI_WRAP_T35, &rpu, &rpu_size_int);
    if (ret < 0)
        return ret;
    if (rpu_size_int <= 0) {
        av_free(rpu);
        return AVERROR_INVALIDDATA;
    }

    rpu_size = rpu_size_int;
    size_bytes = rpu_size / 255 + 1;
    total = 1 + size_bytes + rpu_size;
    if (total > UINT16_MAX) {
        av_free(rpu);
        av_log(avctx, AV_LOG_ERROR, "Dolby Vision RPU exceeds the oneVPL payload limit\n");
        return AVERROR(EINVAL);
    }

    buf = av_malloc(total);
    payload = av_mallocz(sizeof(*payload));
    if (!buf || !payload) {
        av_free(buf);
        av_free(payload);
        av_free(rpu);
        return AVERROR(ENOMEM);
    }

    dst = buf;
    bytestream_put_byte(&dst, SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35);
    while (rpu_size >= 255) {
        bytestream_put_byte(&dst, 0xFF);
        rpu_size -= 255;
    }
    bytestream_put_byte(&dst, (uint8_t)rpu_size);
    bytestream_put_buffer(&dst, rpu, rpu_size_int);
    av_free(rpu);

    payload->Data    = buf;
    payload->BufSize = (mfxU16)total;
    payload->NumBit  = (mfxU32)(total * 8);
    payload->Type    = SEI_TYPE_USER_DATA_REGISTERED_ITU_T_T35;
    enc_ctrl->Payload[enc_ctrl->NumPayload++] = payload;
    return 0;
}

"""

helper_anchor = 'static int set_roi_encode_ctrl(AVCodecContext *avctx, const AVFrame *frame,'
s = replace_once(s, helper_anchor, helper + helper_anchor, c_path)

init_anchor = '    q->param.AsyncDepth = q->async_depth;\n'
init_code = """    if (avctx->codec_id == AV_CODEC_ID_HEVC) {
        q->dovi.logctx = avctx;
        q->dovi.enable = FF_DOVI_AUTOMATIC;
        ret = ff_dovi_configure(&q->dovi, avctx);
        if (ret < 0)
            return ret;
    }

"""
s = replace_once(s, init_anchor, init_code + init_anchor, c_path)

close_anchor = '    av_freep(&q->extparam);\n\n    return 0;\n'
s = replace_once(s, close_anchor,
                 '    av_freep(&q->extparam);\n    ff_dovi_ctx_unref(&q->dovi);\n\n    return 0;\n', c_path)

call_anchor = ('        ret = set_hdr10plus_payload(avctx, frame, enc_ctrl);\n'
               '        if (ret < 0)\n'
               '            goto free;\n')
call_code = (call_anchor +
             '        ret = set_dovi_rpu_payload(avctx, frame, q, enc_ctrl);\n'
             '        if (ret < 0)\n'
             '            goto free;\n')
s = replace_once(s, call_anchor, call_code, c_path)

c_path.write_text(s)
h_path.write_text(hs)
PYQSVDOVI

  grep -q 'set_dovi_rpu_payload(avctx, frame, q, enc_ctrl)' "$qsv_c" || {
    echo "FFmpeg QSV HEVC Dolby Vision P8 RPU injection is missing"
    exit 1
  }
}

patch_ffmpeg_encoder_params() {
  local ff_stage="$1"
  echo "== Patch FFmpeg encoder parameter handling =="
  git -C "$ff_stage" apply --whitespace=nowarn <<'PATCH'
diff --git a/libavcodec/libsvtav1.c b/libavcodec/libsvtav1.c
--- a/libavcodec/libsvtav1.c
+++ b/libavcodec/libsvtav1.c
@@ -348,19 +348,15 @@ static int config_enc_params(EbSvtAv1EncConfiguration *param,
     while ((en = av_dict_iterate(svt_enc->svtav1_opts, en))) {
         EbErrorType ret = svt_av1_enc_parse_parameter(param, en->key, en->value);
         if (ret != EB_ErrorNone) {
-            int level = (avctx->err_recognition & AV_EF_EXPLODE) ? AV_LOG_ERROR : AV_LOG_WARNING;
-            av_log(avctx, level, "Error parsing option %s: %s.\n", en->key, en->value);
-            if (avctx->err_recognition & AV_EF_EXPLODE)
-                return AVERROR(EINVAL);
+            av_log(avctx, AV_LOG_ERROR, "Error parsing option %s: %s.\n", en->key, en->value);
+            return AVERROR(EINVAL);
         }
     }
 #else
     if (av_dict_count(svt_enc->svtav1_opts)) {
-        int level = (avctx->err_recognition & AV_EF_EXPLODE) ? AV_LOG_ERROR : AV_LOG_WARNING;
-        av_log(avctx, level, "svt-params needs libavcodec to be compiled with SVT-AV1 "
+        av_log(avctx, AV_LOG_ERROR, "svt-params needs libavcodec to be compiled with SVT-AV1 "
                              "headers >= 0.9.1.\n");
-        if (avctx->err_recognition & AV_EF_EXPLODE)
-            return AVERROR(ENOSYS);
+        return AVERROR(ENOSYS);
     }
 #endif
     if (avctx->flags & AV_CODEC_FLAG_PASS2) {
diff --git a/libavcodec/libx264.c b/libavcodec/libx264.c
--- a/libavcodec/libx264.c
+++ b/libavcodec/libx264.c
@@ -1382,13 +1382,14 @@ static av_cold int X264_init(AVCodecContext *avctx)
         const AVDictionaryEntry *en = NULL;
         while (en = av_dict_iterate(x4->x264_params, en)) {
            if ((ret = x264_param_parse(&x4->params, en->key, en->value)) < 0) {
-               av_log(avctx, AV_LOG_WARNING,
+               av_log(avctx, AV_LOG_ERROR,
                       "Error parsing option '%s = %s'.\n",
                        en->key, en->value);
 #if X264_BUILD >= 161
                if (ret == X264_PARAM_ALLOC_FAILED)
                    return AVERROR(ENOMEM);
 #endif
+               return AVERROR(EINVAL);
            }
         }
     }
diff --git a/libavcodec/libx265.c b/libavcodec/libx265.c
--- a/libavcodec/libx265.c
+++ b/libavcodec/libx265.c
@@ -536,13 +536,13 @@ static av_cold int libx265_encode_init(AVCodecContext *avctx)
             parse_ret = ctx->api->param_parse(ctx->params, en->key, en->value);
             switch (parse_ret) {
             case X265_PARAM_BAD_NAME:
-                av_log(avctx, AV_LOG_WARNING,
+                av_log(avctx, AV_LOG_ERROR,
                       "Unknown option: %s.\n", en->key);
-                break;
+                return AVERROR(EINVAL);
             case X265_PARAM_BAD_VALUE:
-                av_log(avctx, AV_LOG_WARNING,
+                av_log(avctx, AV_LOG_ERROR,
                       "Invalid value for %s: %s.\n", en->key, en->value);
-                break;
+                return AVERROR(EINVAL);
             default:
                 break;
             }
PATCH
}

verify_full_ffmpeg_config() {
  local cfg="$1" ff_stage="$2" key
  local required=(
    CONFIG_AAC_ENCODER CONFIG_AUDIOTOOLBOX CONFIG_AAC_AT_ENCODER CONFIG_LIBSOXR CONFIG_LIBSSH CONFIG_OPENCL CONFIG_D3D12VA
    CONFIG_OPENGL CONFIG_LIBSNAPPY CONFIG_LIBTHEORA CONFIG_LIBSPEEX CONFIG_LIBTWOLAME
    CONFIG_LIBMYSOFA CONFIG_LIBOPENMPT CONFIG_LIBDVDREAD CONFIG_LIBDVDNAV
    CONFIG_CHROMAPRINT CONFIG_LIBZMQ CONFIG_LIBZVBI CONFIG_LIBGSM
    CONFIG_LIBOPENCORE_AMRNB CONFIG_LIBOPENCORE_AMRWB CONFIG_LIBVO_AMRWBENC
    CONFIG_ICONV CONFIG_LIBPLACEBO_FILTER CONFIG_VULKAN
    CONFIG_LIBJXR CONFIG_LIBJXR_ENCODER CONFIG_LIBJXR_DECODER
    CONFIG_LIBVPL CONFIG_AV1_QSV_ENCODER CONFIG_HEVC_QSV_ENCODER
    CONFIG_LIBAOM_AV1_ENCODER CONFIG_LIBSVTAV1_ENCODER
    CONFIG_LIBX264_ENCODER CONFIG_LIBX265_ENCODER CONFIG_LIBVVENC_ENCODER
    CONFIG_LIBVMAF_FILTER
    CONFIG_HEVC_DECODER CONFIG_AV1_DECODER CONFIG_LIBDAV1D_DECODER
    CONFIG_DOVI_RPUDEC CONFIG_DOVI_RPUENC CONFIG_DOVI_RPU_BSF CONFIG_DOVI_SPLIT_BSF
    CONFIG_MOV_DEMUXER CONFIG_MOV_MUXER CONFIG_MATROSKA_DEMUXER CONFIG_MATROSKA_MUXER
    CONFIG_MPEGTS_DEMUXER
    HAVE_STRUCT_MFXCONFIGINTERFACE
    CONFIG_VAPOURSYNTH_DEMUXER
  )
  if [[ "$CUDA_ENABLE" == "1" ]]; then
    required+=(
      CONFIG_CUDA_NVCC CONFIG_NVDEC CONFIG_AV1_NVENC_ENCODER
      CONFIG_HEVC_NVENC_ENCODER CONFIG_SCALE_CUDA_FILTER
      CONFIG_LIBVMAF_CUDA_FILTER
      CONFIG_AV1_NVDEC_HWACCEL CONFIG_H264_NVDEC_HWACCEL
      CONFIG_HEVC_NVDEC_HWACCEL CONFIG_MJPEG_NVDEC_HWACCEL
      CONFIG_MPEG1_NVDEC_HWACCEL CONFIG_MPEG2_NVDEC_HWACCEL
      CONFIG_MPEG4_NVDEC_HWACCEL CONFIG_VC1_NVDEC_HWACCEL
      CONFIG_VP8_NVDEC_HWACCEL CONFIG_VP9_NVDEC_HWACCEL
    )
  fi
  for key in "${required[@]}"; do
    grep -q "^$key=yes$" "$cfg" || { echo "FFmpeg required feature disabled: $key"; exit 1; }
  done
  if grep -Eq '^CONFIG_(CUVID|.*_CUVID_DECODER)=yes$' "$cfg"; then
    echo "FFmpeg legacy CUVID decoder is unexpectedly enabled"
    exit 1
  fi
  grep -q 'nvenc_alloc_dovi_payload' "$ff_stage/libavcodec/nvenc.c" || {
    echo "FFmpeg NVENC Dolby Vision HEVC P8 / AV1 P10 injection is missing"
    exit 1
  }
  grep -q 'set_dovi_rpu_payload(avctx, frame, q, enc_ctrl)' "$ff_stage/libavcodec/qsvenc.c" || {
    echo "FFmpeg QSV HEVC Dolby Vision Profile 8 injection is missing"
    exit 1
  }
  grep -q 'DOVIContext dovi;' "$ff_stage/libavcodec/qsvenc.h" || {
    echo "FFmpeg QSV Dolby Vision state is missing"
    exit 1
  }
  grep -q 'ff_dovi_rpu_parse' "$ff_stage/libavcodec/hevc/hevcdec.c" || {
    echo "FFmpeg HEVC Dolby Vision RPU decoding is missing"
    exit 1
  }
  grep -q 'ff_itut_t35_parse_payload_to_frame' "$ff_stage/libavcodec/libdav1d.c" || {
    echo "FFmpeg AV1 Dolby Vision metadata decoding is missing"
    exit 1
  }
  grep -Rqs '"aac_nmr_speed"' "$ff_stage/libavcodec" || {
    echo "FFmpeg source does not contain the NMR AAC speed option"
    exit 1
  }
  grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$ff_stage/libavcodec/nvenc.c" || {
    echo "FFmpeg NVENC HDR10+ passthrough is missing"
    exit 1
  }
  grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$ff_stage/libavcodec/libx265.c" || {
    echo "FFmpeg libx265 HDR10+ passthrough is missing"
    exit 1
  }
  grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$ff_stage/libavcodec/libaomenc.c" || {
    echo "FFmpeg libaom HDR10+ passthrough is missing"
    exit 1
  }
  grep -q 'svt_add_metadata(headerPtr, EB_AV1_METADATA_TYPE_ITUT_T35' "$ff_stage/libavcodec/libsvtav1.c" || {
    echo "FFmpeg libsvtav1 HDR10+ passthrough is missing"
    exit 1
  }
  grep -q 'add_hdr_static(avctx, rawimg, frame)' "$ff_stage/libavcodec/libaomenc.c" || {
    echo "FFmpeg libaom static HDR10 (MDCV/CLL) passthrough is missing"
    exit 1
  }
  grep -q 'nvenc_alloc_hdr_static_payload' "$ff_stage/libavcodec/nvenc.c" || {
    echo "FFmpeg NVENC static HDR10 (MDCV/CLL) injection is missing"
    exit 1
  }
}

encoder_smoke() {
  local ffmpeg="$1"
  shift
  "$ffmpeg" -hide_banner -loglevel error \
    -f lavfi -i "color=c=black:s=64x64:r=1" -frames:v 1 \
    "$@" -f null - >/dev/null 2>&1
}

encoder_bitdepth_smoke() {
  local ffmpeg="$1" encoder="$2" pix_fmt="$3"
  local ffprobe actual muxer=matroska
  [[ "$encoder" == libaom-av1 ]] && muxer=nut
  ffprobe="$(dirname "$ffmpeg")/ffprobe.exe"
  [[ -x "$ffprobe" ]] || {
    echo "ffprobe is missing beside $ffmpeg" >&2
    exit 1
  }

  actual="$(
    "$ffmpeg" -hide_banner -loglevel error \
      -f lavfi -i "testsrc2=size=192x108:rate=1,format=$pix_fmt" \
      -frames:v 2 -an -c:v "$encoder" -pix_fmt "$pix_fmt" \
      -f "$muxer" - |
    "$ffprobe" -hide_banner -v error -select_streams v:0 \
      -show_entries stream=pix_fmt -of csv=p=0 -
  )" || {
    echo "$encoder failed $pix_fmt encode" >&2
    exit 1
  }
  actual="${actual//$'\r'/}"
  [[ "$actual" == "$pix_fmt" ]] || {
    echo "$encoder produced $actual instead of $pix_fmt" >&2
    exit 1
  }
}

expect_encoder_param_rejected() {
  local ffmpeg="$1" encoder="$2" option="$3"
  shift 3
  if encoder_smoke "$ffmpeg" "$@" -c:v "$encoder" "$option" definitely_invalid=1; then
    echo "$encoder silently accepted an invalid $option value"
    exit 1
  fi
}

verify_encoder_params() {
  local ffmpeg="$1"
  echo "== Verify encoder parameter forwarding =="
  encoder_smoke "$ffmpeg" -c:v libaom-av1 -b:v 0 -crf 30 -aom-params tune=iq
  encoder_smoke "$ffmpeg" -c:v libsvtav1 -svtav1-params tune=0
  encoder_smoke "$ffmpeg" -c:v libx264 -x264-params keyint=1
  encoder_smoke "$ffmpeg" -c:v libx265 -x265-params keyint=1
  encoder_smoke "$ffmpeg" -pix_fmt yuv420p10le -c:v libvvenc -vvenc-params QP=32

  expect_encoder_param_rejected "$ffmpeg" libaom-av1 -aom-params
  expect_encoder_param_rejected "$ffmpeg" libsvtav1 -svtav1-params
  expect_encoder_param_rejected "$ffmpeg" libx264 -x264-params
  expect_encoder_param_rejected "$ffmpeg" libx265 -x265-params
  expect_encoder_param_rejected "$ffmpeg" libvvenc -vvenc-params -pix_fmt yuv420p10le
}

verify_encoder_bitdepths() {
  local ffmpeg="$1"
  echo "== Verify encoder bit-depth output =="
  encoder_bitdepth_smoke "$ffmpeg" libx264 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libx264 yuv422p10le
  encoder_bitdepth_smoke "$ffmpeg" libx264 yuv444p10le

  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv422p10le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv444p10le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv420p12le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv422p12le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv444p12le

  encoder_bitdepth_smoke "$ffmpeg" libvpx-vp9 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libvpx-vp9 yuv420p12le
  encoder_bitdepth_smoke "$ffmpeg" libaom-av1 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libaom-av1 yuv420p12le
  encoder_bitdepth_smoke "$ffmpeg" libsvtav1 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libvvenc yuv420p10le
}

verify_dolby_vision_support() {
  local ffmpeg="$1" decoders encoders bsfs muxers filters codec help
  echo "== Verify Dolby Vision Profile 8/10 support surfaces =="
  decoders="$("$ffmpeg" -hide_banner -decoders 2>&1 | tr -d '\r')" || {
    echo "Cannot query FFmpeg decoders" >&2
    exit 1
  }
  encoders="$("$ffmpeg" -hide_banner -encoders 2>&1 | tr -d '\r')" || {
    echo "Cannot query FFmpeg encoders" >&2
    exit 1
  }
  bsfs="$("$ffmpeg" -hide_banner -bsfs 2>&1 | tr -d '\r')" || {
    echo "Cannot query FFmpeg bitstream filters" >&2
    exit 1
  }
  muxers="$("$ffmpeg" -hide_banner -muxers 2>&1 | tr -d '\r')" || {
    echo "Cannot query FFmpeg muxers" >&2
    exit 1
  }
  filters="$("$ffmpeg" -hide_banner -filters 2>&1 | tr -d '\r')" || {
    echo "Cannot query FFmpeg filters" >&2
    exit 1
  }

  for codec in hevc av1 libdav1d; do
    grep -Eq "[[:space:]]$codec([[:space:]]|$)" <<<"$decoders" || {
      echo "Dolby Vision decoder path is missing: $codec" >&2
      exit 1
    }
  done
  for codec in libx265 libaom-av1 libsvtav1; do
    grep -Eq "[[:space:]]$codec([[:space:]]|$)" <<<"$encoders" || {
      echo "Dolby Vision software encoder path is missing: $codec" >&2
      exit 1
    }
    help="$("$ffmpeg" -hide_banner -h "encoder=$codec" 2>&1)" || {
      echo "Cannot query encoder options: $codec" >&2
      exit 1
    }
    grep -q -- "-dolbyvision" <<<"$help" || {
      echo "Dolby Vision RPU option is missing: $codec" >&2
      exit 1
    }
  done
  grep -Eq "[[:space:]]libplacebo([[:space:]]|$)" <<<"$filters" || {
    echo "Dolby Vision libplacebo filter is missing" >&2
    exit 1
  }
  help="$("$ffmpeg" -hide_banner -h filter=libplacebo 2>&1)" || {
    echo "Cannot query libplacebo Dolby Vision options" >&2
    exit 1
  }
  grep -q 'apply_dolbyvision' <<<"$help" || {
    echo "libplacebo Dolby Vision metadata application is missing" >&2
    exit 1
  }
  for bsf in dovi_rpu dovi_split; do
    grep -Eq "(^|[[:space:]])$bsf([[:space:]]|$)" <<<"$bsfs" || {
      echo "Dolby Vision bitstream filter is missing: $bsf" >&2
      exit 1
    }
  done
  for codec in mp4 matroska; do
    grep -Eq "[[:space:]]$codec([[:space:]]|$)" <<<"$muxers" || {
      echo "Dolby Vision container muxer is missing: $codec" >&2
      exit 1
    }
  done
  if grep -Eq "[[:space:]]hevc_nvenc([[:space:]]|$)" <<<"$encoders"; then
    grep -Eq "[[:space:]]av1_nvenc([[:space:]]|$)" <<<"$encoders" || {
      echo "NVENC AV1 Profile 10 encoder is missing" >&2
      exit 1
    }
    for codec in hevc_nvenc av1_nvenc; do
      "$ffmpeg" -hide_banner -h "encoder=$codec" >/dev/null 2>&1 || {
        echo "Cannot query $codec options" >&2
        exit 1
      }
    done
  fi
  echo "Dolby Vision Profile 8/10 capability surfaces passed"
}

verify_aac_at() {
  local ffmpeg="$1" encoders
  [[ -f "$(dirname "$ffmpeg")/CoreAudioToolbox.dll" ]] || {
    echo "CoreAudioToolbox.dll is missing beside ffmpeg.exe" >&2
    exit 1
  }
  encoders="$("$ffmpeg" -hide_banner -encoders 2>/dev/null)"
  grep -q 'aac_at' <<<"$encoders" || { echo "aac_at encoder is missing" >&2; exit 1; }
  "$ffmpeg" -hide_banner -h encoder=aac_at >/dev/null
  "$ffmpeg" -hide_banner -loglevel error -f lavfi -i 'sine=frequency=1000:sample_rate=48000' \
    -t 0.25 -c:a aac_at -b:a 128k -f null - >/dev/null
}

verify_vmaf() {
  local ffmpeg="$1" filters
  echo "== Verify VMAF v1 and CUDA =="
  filters="$("$ffmpeg" -hide_banner -filters 2>/dev/null)"
  grep -q 'libvmaf' <<<"$filters" || { echo "libvmaf filter is missing" >&2; exit 1; }
  "$ffmpeg" -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=1' \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=1' \
    -filter_complex '[0:v][1:v]libvmaf=model=version=vmaf_v1.0.16_3d0h' \
    -frames:v 1 -f null - >/dev/null
  if [[ "$CUDA_ENABLE" == "1" ]]; then
    grep -q 'libvmaf_cuda' <<<"$filters" || { echo "libvmaf_cuda filter is missing" >&2; exit 1; }
    "$ffmpeg" -hide_banner -loglevel error \
      -init_hw_device cuda=vmaf:0 -filter_hw_device vmaf \
      -f lavfi -i 'color=c=black:s=320x180:r=1' \
      -f lavfi -i 'color=c=black:s=320x180:r=1' \
      -filter_complex '[0:v]format=yuv420p,hwupload_cuda[dist];[1:v]format=yuv420p,hwupload_cuda[ref];[dist][ref]libvmaf_cuda' \
      -frames:v 1 -f null - >/dev/null
  fi
}

ensure_host_glslc() {
  local stage="$BUILDROOT/_src/libshaderc"
  local host_bld="$BUILDROOT/libshaderc-host"
  local host_glslc="$HOST_TOOLS/bin/glslc"
  local stamp="$HOST_TOOLS/.shaderc-host-commit"
  local src_head=""

  # Prefer the already-staged shaderc tree because git-sync-deps has populated
  # its third_party dependencies during previous Full/NVENC builds.
  if [[ ! -d "$stage/third_party/glslang" || ! -d "$stage/third_party/spirv-tools/external/spirv-headers" ]]; then
    stage="$(stage_src "libshaderc")"
    pushd "$stage" >/dev/null
    python3 utils/git-sync-deps
    popd >/dev/null
  fi

  src_head="$(git -C "$stage" rev-parse HEAD 2>/dev/null || true)"
  if [[ -x "$host_glslc" && -n "$src_head" && -f "$stamp" && "$(cat "$stamp")" == "$src_head" ]]; then
    return 0
  fi

  # Reuse the NVENC host tool when it was built from the exact same shaderc commit.
  local nvenc_stage="$ROOT/build_nvenc/_src/libshaderc"
  local nvenc_glslc="$ROOT/build_nvenc/host-tools/bin/glslc"
  local nvenc_head=""
  if [[ -x "$nvenc_glslc" && -d "$nvenc_stage/.git" && -n "$src_head" ]]; then
    nvenc_head="$(git -C "$nvenc_stage" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$nvenc_head" == "$src_head" ]]; then
      mkdir -p "$HOST_TOOLS/bin"
      cp -f "$nvenc_glslc" "$host_glslc"
      chmod +x "$host_glslc"
      printf '%s\n' "$src_head" > "$stamp"
      return 0
    fi
  fi

  # Keep the host build tree: CMake/Ninja will rebuild only changed objects.
  env -u CC -u CXX -u AR -u RANLIB -u STRIP -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    cmake -S "$stage" -B "$host_bld" -G Ninja \
      -DCMAKE_C_COMPILER=/usr/bin/cc \
      -DCMAKE_CXX_COMPILER=/usr/bin/c++ \
      -DCMAKE_BUILD_TYPE=Release \
      -DSHADERC_SKIP_TESTS=ON \
      -DSHADERC_SKIP_EXAMPLES=ON \
      -DSHADERC_ENABLE_EXECUTABLES=ON \
      -DSHADERC_ENABLE_INSTALL=OFF \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$host_bld" --target glslc_exe --parallel "$JOBS"
  mkdir -p "$HOST_TOOLS/bin"
  cp -f "$host_bld/glslc/glslc" "$host_glslc"
  chmod +x "$host_glslc"
  [[ -n "$src_head" ]] && printf '%s\n' "$src_head" > "$stamp"
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
      local api_header="$PREFIX/include/ffnvcodec/nvEncodeAPI.h"
      local api_major api_minor
      api_major="$(sed -n 's/^#define NVENCAPI_MAJOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      api_minor="$(sed -n 's/^#define NVENCAPI_MINOR_VERSION[[:space:]]\+\([0-9]\+\).*/\1/p' "$api_header")"
      ((api_major > 13 || (api_major == 13 && api_minor >= 1))) || {
        echo "NVENC API $api_major.$api_minor is below required 13.1"
        exit 1
      }

      if [[ "$CUDA_ENABLE" == "1" ]]; then
        local cuda_symbol
        for cuda_symbol in cuCtxSynchronize cuCtxGetStreamPriorityRange cuMemHostAlloc cuMemFreeHost cuMemFreeAsync cuStreamCreateWithPriority; do
          grep -q "$cuda_symbol" "$PREFIX/include/ffnvcodec/dynlink_loader.h" || {
            echo "nv-codec-headers 缺少 libvmaf CUDA 所需函数: $cuda_symbol"
            exit 1
          }
        done
      fi
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

    libiconv)
      local iconv_stage iconv_version iconv_archive iconv_cache
      iconv_stage="$(stage_src "libiconv")"
      iconv_version="$(normalize_version libiconv "$(git -C "$iconv_stage" describe --tags --always)")"
      [[ "$iconv_version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || {
        echo "libiconv source is not pinned to an exact release tag: $iconv_version" >&2
        exit 1
      }
      iconv_cache="$ROOT/toolchains/source-archives"
      iconv_archive="$iconv_cache/libiconv-$iconv_version.tar.gz"
      if [[ -f "$iconv_archive" ]] && ! tar -tzf "$iconv_archive" >/dev/null 2>&1; then
        echo "Discarding invalid cached libiconv archive: $iconv_archive" >&2
        rm -f "$iconv_archive"
      fi
      if [[ ! -f "$iconv_archive" ]]; then
        mkdir -p "$iconv_cache"
        download_file_retry "$iconv_archive" \
          "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$iconv_version.tar.gz" \
          || { echo "Unable to download libiconv $iconv_version" >&2; exit 1; }
        tar -tzf "$iconv_archive" >/dev/null 2>&1 || {
          echo "Downloaded libiconv archive is invalid: $iconv_archive" >&2
          rm -f "$iconv_archive"
          exit 1
        }
      fi
      rm -rf "$iconv_stage"
      mkdir -p "$iconv_stage"
      tar -xzf "$iconv_archive" -C "$iconv_stage" --strip-components=1
      pushd "$iconv_stage" >/dev/null
      ./configure \
        --host="$TARGET" \
        --prefix="$PREFIX" \
        --disable-shared \
        --enable-static \
        --disable-nls
      make -j"$JOBS"
      make install
      popd >/dev/null
      ;;

    libpng)
      build_cmake libpng \
        -DPNG_SHARED=OFF \
        -DPNG_STATIC=ON \
        -DPNG_TESTS=OFF \
        -DPNG_TOOLS=OFF \
        -DPNG_FRAMEWORK=OFF \
        -DZLIB_ROOT="$PREFIX" \
        -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="$PREFIX/include"
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

    fdk-aac)
      build_autotools fdk-aac
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
        -DCONFIG_AV1_HIGHBITDEPTH=1 \
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
      # libssh's mbedTLS backend requires a real mutex implementation. llvm-mingw
      # provides winpthreads; keep this change confined to the staged source.
      sed -i \
        -e 's|^//#define MBEDTLS_THREADING_PTHREAD$|#define MBEDTLS_THREADING_PTHREAD|' \
        -e 's|^//#define MBEDTLS_THREADING_C$|#define MBEDTLS_THREADING_C|' \
        "$stage/include/mbedtls/mbedtls_config.h"
      grep -q '^#define MBEDTLS_THREADING_PTHREAD$' "$stage/include/mbedtls/mbedtls_config.h"
      grep -q '^#define MBEDTLS_THREADING_C$' "$stage/include/mbedtls/mbedtls_config.h"
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

    libssh)
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
      ;;

    opencl-headers)
      build_cmake opencl-headers \
        -DBUILD_TESTING=OFF \
        -DOPENCL_HEADERS_BUILD_TESTING=OFF \
        -DOPENCL_HEADERS_BUILD_CXX_TESTS=OFF
      ;;

    opencl-loader)
      build_cmake opencl-loader \
        -DBUILD_TESTING=OFF \
        -DOPENCL_ICD_LOADER_HEADERS_DIR="$PREFIX/include" \
        -DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=OFF \
        -DOPENCL_ICD_LOADER_BUILD_TESTING=OFF \
        -DENABLE_OPENCL_LAYERS=OFF \
        -DENABLE_OPENCL_LAYERINFO=OFF
      ;;

    libsnappy)
      build_cmake libsnappy \
        -DSNAPPY_BUILD_TESTS=OFF \
        -DSNAPPY_BUILD_BENCHMARKS=OFF \
        -DSNAPPY_FUZZING_BUILD=OFF \
        -DSNAPPY_INSTALL=ON
      ;;

    libtheora)
      build_autotools libtheora \
        --disable-examples \
        --disable-doc \
        --disable-spec
      ;;

    libspeex)
      build_autotools libspeex \
        --disable-binaries \
        --disable-examples
      ;;

    libtwolame)
      build_autotools libtwolame \
        --disable-sndfile
      ;;

    libmysofa)
      build_cmake libmysofa \
        -DBUILD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_STATIC_LIBS=ON \
        -DZLIB_ROOT="$PREFIX" \
        -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
        -DZLIB_INCLUDE_DIR="$PREFIX/include"
      ;;

    libopenmpt)
      local openmpt_stage
      openmpt_stage="$(stage_src "libopenmpt")"
      pushd "$openmpt_stage" >/dev/null
      make clean CONFIG=mingw-w64 WINDOWS_ARCH=amd64 WINDOWS_CRT=ucrt MINGW_COMPILER=clang 2>/dev/null || true
      local openmpt_args=(
        CONFIG=mingw-w64 WINDOWS_ARCH=amd64 WINDOWS_CRT=ucrt MINGW_COMPILER=clang
        CC="$CC" CXX="$CXX" LD="$CXX" AR="$AR" PKG_CONFIG="$PKG_CONFIG"
        OVERWRITE_CFLAGS="$CFLAGS" OVERWRITE_CXXFLAGS="$CXXFLAGS"
        CXXSTDLIB_PCLIBSPRIVATE=-lc++
        DYNLINK=0 SHARED_LIB=0 STATIC_LIB=1 EXAMPLES=0 OPENMPT123=0 TEST=0
        OPTIMIZE=none OPTIMIZE_LTO=0
        NO_ZLIB=1 NO_MPG123=1 NO_OGG=1 NO_VORBIS=1 NO_VORBISFILE=1
      )
      make -j"$JOBS" "${openmpt_args[@]}"
      make install PREFIX="$PREFIX" "${openmpt_args[@]}"
      popd >/dev/null
      ;;

    libdvdread)
      build_meson libdvdread \
        -Denable_docs=false \
        -Dlibdvdcss=disabled \
        -Ddlfcn=builtin
      ;;

    libdvdnav)
      build_meson libdvdnav \
        -Denable_docs=false \
        -Denable_examples=false
      ;;

    chromaprint)
      build_cmake chromaprint \
        -DBUILD_TOOLS=OFF \
        -DBUILD_TESTS=OFF \
        -DUSE_INTERNAL_AVRESAMPLE=ON \
        -DFFT_LIB=kissfft
      ;;

    libzmq)
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
      ;;

    libzvbi)
      build_autotools libzvbi \
        --disable-tests \
        --disable-examples \
        --disable-nls \
        --with-libiconv-prefix="$PREFIX" \
        --without-x
      ;;

    libgsm)
      local gsm_stage gsm_bld gsm_src obj
      gsm_stage="$(stage_src "libgsm")"
      gsm_bld="$BUILDROOT/libgsm"
      rm -rf "$gsm_bld"
      mkdir -p "$gsm_bld" "$PREFIX/include/gsm" "$PREFIX/lib"
      local gsm_sources=(
        add code debug decode long_term lpc preprocess rpe gsm_destroy gsm_decode
        gsm_encode gsm_explode gsm_implode gsm_create gsm_print gsm_option short_term table
      )
      local gsm_objects=()
      for gsm_src in "${gsm_sources[@]}"; do
        obj="$gsm_bld/$gsm_src.o"
        "$CC" $CFLAGS -DSASR -DWAV49 -DNeedFunctionPrototypes=1 \
          -I"$gsm_stage/inc" -c "$gsm_stage/src/$gsm_src.c" -o "$obj"
        gsm_objects+=("$obj")
      done
      "$AR" rcs "$PREFIX/lib/libgsm.a" "${gsm_objects[@]}"
      "$RANLIB" "$PREFIX/lib/libgsm.a"
      cp -f "$gsm_stage/inc/gsm.h" "$PREFIX/include/gsm.h"
      cp -f "$gsm_stage/inc/gsm.h" "$PREFIX/include/gsm/gsm.h"
      ;;

    opencore-amr)
      build_autotools opencore-amr \
        --disable-examples
      ;;

    vo-amrwbenc)
      build_autotools vo-amrwbenc
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
        -Dhave_mingw_pthreads=true \
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
      if [[ ! -d third_party/glslang || ! -d third_party/spirv-tools/external/spirv-headers ]]; then
        # ponytail: GitHub is flaky here; retry the official sync instead of vendoring deps in this script.
        for i in 1 2 3 4 5; do
          python3 utils/git-sync-deps && break
          rm -rf third_party/spirv-headers third_party/spirv-tools/external/spirv-headers third_party/googletest
          echo "shaderc deps sync failed, retry $i/5..."
          sleep 10
          [[ "$i" != "5" ]] || exit 1
        done
      fi
      popd >/dev/null

      [[ -f "$stage/third_party/spirv-headers/include/spirv/unified1/spirv.h" ]] || {
        echo "shaderc 缺少 SPIR-V Headers"
        exit 1
      }
      cp -rf "$stage/third_party/spirv-headers/include/spirv" "$PREFIX/include/"

      local bld="$BUILDROOT/libshaderc"
      if [[ "$INCREMENTAL_BUILD" != "1" ]]; then
        rm -rf "$bld"
      fi
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
      local vk_version
      vk_version="$(git -C "$stage" describe --tags --always 2>/dev/null | sed 's/^v//' | sed 's/-.*//')"
      mkdir -p "$PREFIX/include" "$PREFIX/lib" "$PREFIX/lib/pkgconfig"
      cp -rf "$stage/include/"* "$PREFIX/include/"

      # ponytail: enough for MinGW to link Windows' system Vulkan loader (vulkan-1.dll); build full Vulkan-Loader only if this import lib stops working.
      cat > "$PREFIX/lib/vulkan-1.def" <<EOF
LIBRARY vulkan-1.dll
EXPORTS
vkGetInstanceProcAddr
EOF
      "$DLLTOOL" -d "$PREFIX/lib/vulkan-1.def" -l "$PREFIX/lib/libvulkan-1.dll.a" -D vulkan-1.dll
      cp -f "$PREFIX/lib/libvulkan-1.dll.a" "$PREFIX/lib/libvulkan.dll.a"

      cat > "$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Vulkan-Loader
Description: Windows Vulkan loader import library
Version: $vk_version
Libs: -L\${libdir} -lvulkan-1
Cflags: -I\${includedir}
EOF
      ;;

    libplacebo)
      local stage
      stage="$(stage_src "libplacebo")"
      # This target is static; PL_EXPORT would leak placebo symbols from avfilter.dll.
      python3 - "$stage/src/meson.build" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = "  c_args: ['-DPL_EXPORT'],"
new = "  c_args: ['-DPL_STATIC'],"
if s.count(old) == 1:
    p.write_text(s.replace(old, new, 1))
elif s.count(new) != 1:
    raise SystemExit(f"unexpected libplacebo export definition in {p}")
PY
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
        -Dlcms=enabled \
        -Ddovi=enabled \
        -Dlibdovi=disabled
      meson compile -C "$bld" -j "$JOBS"
      meson install -C "$bld"
      grep -q '^#define PL_HAVE_DOVI 1$' "$PREFIX/include/libplacebo/config.h" || {
        echo "libplacebo Dolby Vision support is disabled"
        exit 1
      }
      if strings "$PREFIX/lib/libplacebo.a" | grep -Eq '(/EXPORT:pl_|-export:pl_)'; then
        echo "静态 libplacebo 仍包含 DLL 导出指令，不能安全链接到 FFmpeg DLL" >&2
        exit 1
      fi
      grep -q '^pl_has_vk_proc_addr=1' "$PREFIX/lib/pkgconfig/libplacebo.pc" || {
        echo "libplacebo 未链接 Windows Vulkan loader 的 vkGetInstanceProcAddr"
        exit 1
      }
      ;;

    opus)
      build_autotools opus --disable-extra-programs --disable-deep-plc --disable-dred --disable-osce
      ;;

    zimg)
      # LLVM 23 libc++ no longer provides std::exception_ptr through zimg's
      # transitive <stdexcept> include; inject the standard owning header only
      # for zimg without changing its source/update policy.
      CXXFLAGS="$CXXFLAGS -include exception" build_autotools zimg --disable-openmp
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

    jxrlib)
      build_jxrlib
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

    svtav1)
      build_cmake svtav1 \
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
      cp -f "$vs_stage/include/VapourSynth4.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSScript4.h" "$PREFIX/include/"
      cp -f "$vs_stage/include/VSHelper4.h" "$PREFIX/include/"

      mkdir -p "$PREFIX/include/vapoursynth"
      cp -f "$vs_stage/include/VapourSynth4.h" "$PREFIX/include/vapoursynth/"
      cp -f "$vs_stage/include/VSScript4.h" "$PREFIX/include/vapoursynth/"
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
        --bit-depth=all \
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
      local bld8="$bld/8bit"
      local bld10="$bld/10bit"
      local bld12="$bld/12bit"
      local common_cmake_args=(
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        -DCMAKE_RC_COMPILER="$WINDRES"
        -DCMAKE_AR="$AR"
        -DCMAKE_RANLIB="$RANLIB"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
        -DBUILD_SHARED_LIBS=OFF
        -DENABLE_SHARED=OFF
        -DENABLE_CLI=OFF
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
      )

      # x265's FFmpeg integration needs one archive containing the 8/10/12-bit
      # implementations. Building only the default 8-bit library makes FFmpeg
      # silently convert high-bit-depth input back to 8-bit.
      cmake -S "$stage" -B "$bld12" -G Ninja \
        "${common_cmake_args[@]}" \
        -DEXPORT_C_API=OFF \
        -DHIGH_BIT_DEPTH=ON \
        -DMAIN12=ON
      cmake --build "$bld12" --parallel "$JOBS"

      cmake -S "$stage" -B "$bld10" -G Ninja \
        "${common_cmake_args[@]}" \
        -DEXPORT_C_API=OFF \
        -DHIGH_BIT_DEPTH=ON \
        -DENABLE_HDR10_PLUS=ON
      cmake --build "$bld10" --parallel "$JOBS"

      mkdir -p "$bld8"
      cp -f "$bld10/libx265.a" "$bld8/x265_main10.a"
      cp -f "$bld12/libx265.a" "$bld8/x265_main12.a"
      cmake -S "$stage" -B "$bld8" -G Ninja \
        "${common_cmake_args[@]}" \
        -DEXTRA_LIB='x265_main10.a;x265_main12.a' \
        -DEXTRA_LINK_FLAGS=-L. \
        -DLINKED_10BIT=ON \
        -DLINKED_12BIT=ON
      cmake --build "$bld8" --parallel "$JOBS"

      mv "$bld8/libx265.a" "$bld8/libx265_main.a"
      "$AR" -M <<EOF
CREATE $bld8/libx265.a
ADDLIB $bld8/libx265_main.a
ADDLIB $bld8/x265_main10.a
ADDLIB $bld8/x265_main12.a
SAVE
END
EOF

      grep -q '^HIGH_BIT_DEPTH:BOOL=ON$' "$bld10/CMakeCache.txt"
      grep -q '^ENABLE_HDR10_PLUS:BOOL=ON$' "$bld10/CMakeCache.txt"
      grep -q '^HIGH_BIT_DEPTH:BOOL=ON$' "$bld12/CMakeCache.txt"
      grep -q '^MAIN12:BOOL=ON$' "$bld12/CMakeCache.txt"
      grep -q '^LINKED_10BIT:BOOL=ON$' "$bld8/CMakeCache.txt"
      grep -q '^LINKED_12BIT:BOOL=ON$' "$bld8/CMakeCache.txt"
      [[ -s "$bld8/libx265.a" ]] || {
        echo "x265 multilib archive was not created" >&2
        exit 1
      }
      cmake --install "$bld8"
      ;;

    vmaf)
      local stage
      stage="$(stage_src "vmaf")/libvmaf"

      # LLVM 23 libc++ performs unqualified swap() calls in vector internals.
      # libvmaf 3.2.0's bundled libsvm also defines a global swap() template,
      # which becomes an ambiguous ADL candidate. Rename only that private
      # helper in the staged copy; keep the upstream source/update policy intact.
      local svm_cpp="$stage/src/svm.cpp"
      if grep -Fq 'template <class T> static inline void swap(T& x, T& y)' "$svm_cpp"; then
        perl -0pi -e 's/\bswap\(/vmaf_svm_swap(/g' "$svm_cpp"
      fi

      # Upstream CUDA custom targets use paths relative to libvmaf/build/src.
      local bld="$stage/build-mingw"
      rm -rf "$bld"

      local extra_opts=("-Denable_cuda=false")
      if [[ "$CUDA_ENABLE" == "1" ]]; then
        setup_cuda
        extra_opts=("-Denable_cuda=true" "-Denable_nvcc=true")
      fi

      meson setup "$bld" "$stage" \
        --cross-file "$BUILDROOT/mingw-cross.txt" \
        --prefix "$PREFIX" \
        --buildtype release \
        --default-library=static \
        -Doptimization=3 \
        -Dbuilt_in_models=true \
        -Denable_float=true \
        -Denable_tests=false \
        -Denable_asm=true \
        "${extra_opts[@]}"

      meson compile -C "$bld" -j "$JOBS"
      meson install -C "$bld"
      meson configure "$bld" | grep -Eq '^  enable_float +true ' || {
        echo "libvmaf floating-point features are not enabled" >&2
        exit 1
      }
      if [[ "$CUDA_ENABLE" == "1" ]]; then
        [[ -f "$PREFIX/include/libvmaf/libvmaf_cuda.h" ]] || {
          echo "libvmaf CUDA 头文件未安装"
          exit 1
        }
      fi
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
        -DVVENC_ENABLE_WERROR=OFF \
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
        -DVVDEC_ENABLE_WERROR=OFF \
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

    AudioToolboxWrapper)
      prepare_apple_audio_runtime
      build_cmake AudioToolboxWrapper
      [[ -f "$PREFIX/lib/libAudioToolboxWrapper.a" ]] || {
        echo "缺少 AudioToolboxWrapper 静态库" >&2
        exit 1
      }
      [[ -x "$PREFIX/bin/atw_ldwrapper" ]] || {
        echo "缺少 atw_ldwrapper" >&2
        exit 1
      }
      ;;

    ffmpeg)
      # 自动修复 srt.pc 和 haisrt.pc 中可能存在的 mbedtls 绝对路径导致 static 链接失败的 Bug
      if [[ -f "$PREFIX/lib/pkgconfig/srt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/srt.pc" 2>/dev/null || true
      fi
      # ponytail: some CMake projects write "-l-lpthread" into .pc under llvm-mingw; normalize before FFmpeg checks.
      sed -i 's/-l-lpthread/-lpthread/g; s/-l-pthread/-lpthread/g' "$PREFIX/lib/pkgconfig/"*.pc 2>/dev/null || true

      if [[ -f "$PREFIX/lib/pkgconfig/haisrt.pc" ]]; then
        sed -i "s|$PREFIX/lib/libmbedtls.a|-lmbedtls|g" "$PREFIX/lib/pkgconfig/haisrt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedcrypto.a|-lmbedcrypto|g" "$PREFIX/lib/pkgconfig/haisrt.pc" 2>/dev/null || true
        sed -i "s|$PREFIX/lib/libmbedx509.a|-lmbedx509|g" "$PREFIX/lib/pkgconfig/haisrt.pc" 2>/dev/null || true
      fi

      # OpenCL CMake installs its header metadata and MinGW archive under names
      # that pkg-config/-lOpenCL do not search in this static cross build.
      if [[ -f "$PREFIX/share/pkgconfig/OpenCL-Headers.pc" ]]; then
        install -m 644 "$PREFIX/share/pkgconfig/OpenCL-Headers.pc" "$PREFIX/lib/pkgconfig/OpenCL-Headers.pc"
      fi
      if [[ -f "$PREFIX/lib/OpenCL.a" && ! -e "$PREFIX/lib/libOpenCL.a" ]]; then
        ln -s OpenCL.a "$PREFIX/lib/libOpenCL.a"
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/OpenCL.pc" ]]; then
        if grep -q '^Libs\.private:' "$PREFIX/lib/pkgconfig/OpenCL.pc"; then
          sed -i 's/^Libs\.private:.*/Libs.private: -lcfgmgr32 -lruntimeobject -lole32/' "$PREFIX/lib/pkgconfig/OpenCL.pc"
        else
          printf '%s\n' 'Libs.private: -lcfgmgr32 -lruntimeobject -lole32' >> "$PREFIX/lib/pkgconfig/OpenCL.pc"
        fi
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/libchromaprint.pc" ]] &&
         ! grep -q 'CHROMAPRINT_NODLL' "$PREFIX/lib/pkgconfig/libchromaprint.pc"; then
        sed -i '/^Cflags:/ s/$/ -DCHROMAPRINT_NODLL/' "$PREFIX/lib/pkgconfig/libchromaprint.pc"
      fi

      # libssh 0.12 omits its static CMake interface from libssh.pc. Without
      # these flags its headers request dllimport symbols and FFmpeg's probe
      # cannot link libssh.a. Mbed TLS also omits its Windows RNG dependency.
      if [[ -f "$PREFIX/lib/pkgconfig/mbedcrypto.pc" ]]; then
        if grep -q '^Libs\.private:' "$PREFIX/lib/pkgconfig/mbedcrypto.pc"; then
          sed -i 's/^Libs\.private:.*/Libs.private: -lbcrypt/' "$PREFIX/lib/pkgconfig/mbedcrypto.pc"
        else
          printf '%s\n' 'Libs.private: -lbcrypt' >> "$PREFIX/lib/pkgconfig/mbedcrypto.pc"
        fi
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/libssh.pc" ]]; then
        grep -q 'LIBSSH_STATIC' "$PREFIX/lib/pkgconfig/libssh.pc" ||
          sed -i '/^Cflags:/ s/$/ -DLIBSSH_STATIC/' "$PREFIX/lib/pkgconfig/libssh.pc"
        sed -i 's/^Requires\.private:.*/Requires.private: mbedcrypto zlib/' "$PREFIX/lib/pkgconfig/libssh.pc"
        if grep -q '^Libs\.private:' "$PREFIX/lib/pkgconfig/libssh.pc"; then
          sed -i 's/^Libs\.private:.*/Libs.private: -lpthread -liphlpapi -lws2_32 -Wl,--enable-stdcall-fixup/' "$PREFIX/lib/pkgconfig/libssh.pc"
        else
          printf '%s\n' 'Libs.private: -lpthread -liphlpapi -lws2_32 -Wl,--enable-stdcall-fixup' >> "$PREFIX/lib/pkgconfig/libssh.pc"
        fi
      fi
      if [[ -f "$PREFIX/lib/pkgconfig/libzmq.pc" ]]; then
        grep -q 'ZMQ_STATIC' "$PREFIX/lib/pkgconfig/libzmq.pc" ||
          sed -i '/^Cflags:/ s/$/ -DZMQ_STATIC/' "$PREFIX/lib/pkgconfig/libzmq.pc"
        if grep -q '^Libs\.private:' "$PREFIX/lib/pkgconfig/libzmq.pc"; then
          sed -i 's/^Libs\.private:.*/Libs.private: -lstdc++ -lpthread -lws2_32 -lrpcrt4 -liphlpapi/' "$PREFIX/lib/pkgconfig/libzmq.pc"
        else
          printf '%s\n' 'Libs.private: -lstdc++ -lpthread -lws2_32 -lrpcrt4 -liphlpapi' >> "$PREFIX/lib/pkgconfig/libzmq.pc"
        fi
      fi

      local ff_stage
      ff_stage="$(stage_src "ffmpeg-source")"
      "$ROOT/shared-patches/apply-ffmpeg-patches.sh" "$ff_stage" full
      patch_ffmpeg_jxr "$ff_stage"
      patch_ffmpeg_libplacebo_vulkan_import "$ff_stage"
      patch_ffmpeg_cxx_runtime "$ff_stage"
      patch_ffmpeg_nvenc_hdr10plus "$ff_stage"
      patch_ffmpeg_nvenc_dovi_p8_p10 "$ff_stage"
      patch_ffmpeg_libx265_hdr10plus "$ff_stage"
      patch_ffmpeg_svtav1_hdr10plus "$ff_stage"
      patch_ffmpeg_libaom_hdr_static "$ff_stage"
      patch_ffmpeg_nvenc_hdr_static "$ff_stage"
      patch_ffmpeg_qsv_hdr10plus "$ff_stage"
      patch_ffmpeg_qsv_dovi_p8 "$ff_stage"
      patch_ffmpeg_encoder_params "$ff_stage"
      pushd "$ff_stage" >/dev/null
      rm -f config.h config.mak config.log

      # 前置依赖校验
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists ffnvcodec || {
        echo "缺少 ffnvcodec，请先编译 nv-codec-headers 阶段"
        exit 1
      }
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists SvtAv1Enc || {
        echo "缺少 SvtAv1Enc，请先编译 svtav1 阶段"
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
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists fdk-aac || {
        echo "缺少 fdk-aac，请先编译 fdk-aac 阶段"
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
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists vulkan || {
        echo "缺少 vulkan.pc，请先编译 vulkan-headers 阶段"
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
      local required_pc
      for required_pc in \
        libssh OpenCL theoraenc speex libmysofa libopenmpt dvdread dvdnav \
        libchromaprint libzmq zvbi-0.2 opencore-amrnb opencore-amrwb vo-amrwbenc; do
        PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists "$required_pc" || {
          echo "缺少 pkg-config 依赖: $required_pc"
          exit 1
        }
      done
      [[ -f "$PREFIX/lib/libsnappy.a" || -f "$PREFIX/lib/libsnappy_static.a" ]] || {
        echo "缺少静态 libsnappy"
        exit 1
      }
      [[ -f "$PREFIX/lib/libtwolame.a" && -f "$PREFIX/lib/libgsm.a" ]] || {
        echo "缺少静态 twolame/gsm"
        exit 1
      }
      [[ -f "$PREFIX/lib/libiconv.a" ]] || {
        echo "缺少静态 libiconv"
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

      local extra_cflags="-I$PREFIX/include -DLIBTWOLAME_STATIC"
      local extra_ldflags="-L$PREFIX/lib $LDFLAGS"
      local extra_libs="$TOOLCHAIN_EXTRA_LIBS -lvulkan-1"
      if [[ "$TOOLCHAIN_FLAVOR" == "llvm-mingw" ]]; then
        # ponytail: librist uses mingw clock_gettime inline, which resolves to winpthread clock_gettime64.
        extra_libs+=" -lpthread"
      fi
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
      ensure_host_glslc
      local atw_ld="$PREFIX/bin/atw_ldwrapper"
      local host_glslc="$HOST_TOOLS/bin/glslc"
      [[ -x "$atw_ld" ]] || { echo "缺少 atw_ldwrapper" >&2; exit 1; }
      [[ -x "$host_glslc" ]] || { echo "缺少 WSL 原生 glslc，请先编译 libshaderc 阶段" >&2; exit 1; }
      export ATW_TRUELD="$CXX"

      ./configure \
        --prefix="$PREFIX" \
        --bindir="$PREFIX/bin" \
        --arch=x86_64 \
        --target-os=mingw32 \
        --cross-prefix="$TARGET-" \
        --enable-cross-compile \
        --cc="$CC" \
        --cxx="$CXX" \
        --ld="$atw_ld" \
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
        --disable-cuvid \
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
        --enable-libjxr \
        --enable-libdav1d \
        --enable-libsvtav1 \
        --enable-libvpl \
        --enable-libx264 \
        --enable-libx265 \
        --enable-libvmaf \
        --enable-libvvenc \
        --enable-schannel \
        --enable-d3d11va \
        --enable-d3d12va \
        --enable-mediafoundation \
        --enable-amf \
        --enable-avisynth \
        --enable-dxva2 \
        --enable-vulkan \
        --enable-vulkan-static \
        --glslc="$host_glslc" \
        --enable-opencl \
        --enable-opengl \
        --enable-libplacebo \
        --enable-zlib \
        --enable-bzlib \
        --enable-lzma \
        --enable-libxml2 \
        --enable-libmp3lame \
        --enable-libvorbis \
        --enable-libsoxr \
        --enable-libfdk-aac \
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
        --enable-libssh \
        --enable-libsnappy \
        --enable-libtheora \
        --enable-libspeex \
        --enable-libtwolame \
        --enable-libmysofa \
        --enable-libopenmpt \
        --enable-libdvdread \
        --enable-libdvdnav \
        --enable-chromaprint \
        --enable-libzmq \
        --enable-libzvbi \
        --enable-libgsm \
        --enable-libopencore-amrnb \
        --enable-libopencore-amrwb \
        --enable-libvo-amrwbenc \
        --enable-iconv \
        --enable-audiotoolbox \
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
        --enable-encoder=libfdk_aac \
        --enable-encoder=libvpx_vp8 \
        --enable-encoder=libvpx_vp9 \
        --enable-encoder=aac \
        --enable-encoder=aac_at

      verify_full_ffmpeg_config ffbuild/config.mak "$ff_stage"
      make -j"$FFMPEG_JOBS"
      local avfilter_import_lib="$ff_stage/libavfilter/libavfilter.dll.a"
      [[ -f "$avfilter_import_lib" ]] || {
        echo "找不到 libavfilter 导入库，无法验证 libplacebo 导出边界" >&2
        exit 1
      }
      local llvm_nm leaked_placebo_symbols
      llvm_nm="$(first_tool "$LLVM_MINGW_ROOT/bin/llvm-nm" llvm-nm)"
      leaked_placebo_symbols="$("$llvm_nm" "$avfilter_import_lib" | awk '$NF ~ /^pl_[[:alnum:]_]+$/ { print $NF }')"
      [[ -z "$leaked_placebo_symbols" ]] || {
        printf 'libavfilter 导入库仍导出 libplacebo 符号:\n%s\n' "$leaked_placebo_symbols" >&2
        exit 1
      }
      make install
      # Stage the exact packaged runtime before executing the Windows binaries.

      "$STRIP" "$PREFIX/bin/ffmpeg.exe" || true
      "$STRIP" "$PREFIX/bin/ffprobe.exe" || true
      "$STRIP" "$PREFIX/bin/ffplay.exe" || true
      "$STRIP" "$PREFIX/bin/"*.dll 2>/dev/null || true
      
      mkdir -p "$ROOT/full"
      find "$ROOT/full" -maxdepth 1 -type f \( -iname "*.exe" -o -iname "*.dll" \) -delete
      rm -rf "$ROOT/full/plugins"
      cp -f "$PREFIX/bin/ffmpeg.exe" "$ROOT/full/ffmpeg.exe"
      cp -f "$PREFIX/bin/ffprobe.exe" "$ROOT/full/ffprobe.exe" 2>/dev/null || true
      cp -f "$PREFIX/bin/ffplay.exe" "$ROOT/full/ffplay.exe" 2>/dev/null || true
      find "$PREFIX/bin" -maxdepth 1 -type f -iname "*.dll" -exec cp -f {} "$ROOT/full/" \;

      seed_apple_audio_runtime
      copy_runtime_dll_closure
      verify_encoder_params "$ROOT/full/ffmpeg.exe"
      verify_encoder_bitdepths "$ROOT/full/ffmpeg.exe"
      verify_dolby_vision_support "$ROOT/full/ffmpeg.exe"
      verify_vmaf "$ROOT/full/ffmpeg.exe"
      popd >/dev/null
      verify_aac_at "$ROOT/full/ffmpeg.exe"
      verify_jxr_binary "$ROOT/full/ffmpeg.exe" "$BUILDROOT/jxr-validation"
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

write_full_manifest() {
  local build_mode="$1" ffmpeg_built="$2"
  shift 2
  local -a repo_args=() manifest_args=()
  local stage repo source
  for stage in "$@"; do
    if [[ "$stage" == "ffmpeg" ]]; then repo="ffmpeg-source"; else repo="$stage"; fi
    source="$BUILDROOT/_src/$repo"
    if [[ ! -d "$source/.git" && ! -f "$source/.git" ]]; then source="$ROOT/$repo"; fi
    repo_args+=(--source-repo "$repo=$source" --built-stage "$stage")
  done

  manifest_args+=(--validate "Requested Full build scope completed: ${BUILT_STAGES[*]}")
  if [[ "$ffmpeg_built" == "1" ]]; then
    manifest_args+=(--validate "FFmpeg stage configured, linked, and its runtime DLL closure was checked")
  else
    manifest_args+=(--skip "FFmpeg was not relinked; packaged executable/DLL hashes describe the pre-existing Full package, not this library-only build")
  fi
  if [[ "$ffmpeg_built" == "1" ]]; then
    manifest_args+=(--validate "Dolby Vision P8/P10 decoders, software encoders, RPU filter, and MOV/Matroska muxers passed runtime capability checks")
    if [[ "$CUDA_ENABLE" == "1" ]]; then
      manifest_args+=(--skip "NVENC HEVC P8 / AV1 P10 RPU injection was not round-trip tested on compatible hardware with Dolby Vision samples")
    fi
  fi
  manifest_args+=(
    --skip "No representative Dolby Vision Profile 8/10 media was available for a decode/encode/remux round-trip test"
    --skip "QSV HEVC P8 RPU injection was compiled but not round-trip tested on compatible hardware"
    --validate "NVENC HEVC Profile 8 and AV1 Profile 10 per-frame Dolby Vision RPU injection patches are present in the compiled source; hardware round-trip remains unverified"
    --validate "QSV HEVC Profile 8 per-frame Dolby Vision RPU injection patch is present in the compiled source; hardware round-trip remains unverified"
    --skip "QSV AV1 Profile 10 Dolby Vision RPU injection is not implemented: oneVPL has no AV1 payload channel, and a packet-PTS OBU path still needs Intel hardware round-trip validation"
    --skip "MPEG-TS Dolby Vision metadata descriptor output is not implemented; demux and decode input support remains enabled"
    --skip "No changing-scene HDR10+ HEVC/AV1 bitstream round-trip was run; compile-time path presence does not prove per-frame metadata survived encoding"
    --skip "P7 FEL reconstruction is not integrated or validated against a trusted reference; no FEL sample/reference or reconstructor is available"
    --skip "Dolby Vision-to-HDR10+ regeneration is unavailable: no authorized frame-analysis generator is installed; hdr10plus_tool only edits or injects existing metadata"
    --skip "Audio Vivid decoder-only integration is unavailable: UWA AV3A source, FFmpeg demux/decode patch, model.bin, and usage/distribution authorization are absent; AV3A encoding is out of scope"
    --skip "av1_qsv HDR10+ metadata injection is not implemented; QSV dynamic-metadata paths are not runtime-verified"
  )
  if [[ "$ffmpeg_built" == "1" ]] && is_in_array jxrlib "$@"; then
    manifest_args+=(--validate "JPEG XR jxrlib lossless RGB24 round-trip passed")
  fi
  if is_in_array x265 "$@"; then
    manifest_args+=(--validate "libx265 Main10 build used ENABLE_HDR10_PLUS=ON")
  fi
  python3 "$ROOT/build-manifests/write_manifest.py" \
    --root "$ROOT" \
    "${repo_args[@]}" \
    --build-name full \
    --build-mode "$build_mode" \
    --toolchain-flavor "$TOOLCHAIN_FLAVOR" \
    --incremental-build "$INCREMENTAL_BUILD" \
    --ffmpeg-built "$ffmpeg_built" \
    --prefix "$PREFIX" \
    --artifact-dir "$ROOT/full" \
    --configure-file "$BUILDROOT/_src/ffmpeg-source/ffbuild/config.log" \
    --config-mak "$BUILDROOT/_src/ffmpeg-source/ffbuild/config.mak" \
    --started "$BUILD_STARTED_AT" \
    --target-platform "Windows x86_64 via $TARGET" \
    --cpu-minimum "$CPU_FLAGS" \
    "${manifest_args[@]}"
  echo "Build source manifest written for full ($build_mode; stages: ${BUILT_STAGES[*]})"
}

is_known_stage() {
  local candidate="$1" stage
  for stage in "${STAGES[@]}"; do [[ "$stage" == "$candidate" ]] && return 0; done
  return 1
}

BUILD_START_STAGE=""
BUILD_ONLY_STAGES=()
BUILD_FULL_BUILD=0
BUILD_MODE="selective"
BUILT_STAGES=()

parse_only_build_args() {
  local arg piece normalized
  for arg in "$@"; do
    [[ -n "$arg" && "$arg" != ,* && "$arg" != *, && "$arg" != *,,* ]] || {
      echo "--only 的阶段列表为空或包含空项: $arg" >&2
      return 1
    }
    [[ "$arg" != --* ]] || { echo "--only 后不接受选项: $arg" >&2; return 1; }
    local -a pieces=()
    IFS=',' read -r -a pieces <<<"$arg"
    for piece in "${pieces[@]}"; do
      piece="${piece//[[:space:]]/}"
      [[ -n "$piece" ]] || { echo "--only 的阶段列表包含空项" >&2; return 1; }
      normalized="$(normalize_stage "$piece")" || {
        echo "未知编译阶段参数: $piece" >&2
        return 1
      }
      is_known_stage "$normalized" || {
        echo "未知编译阶段参数: $piece" >&2
        return 1
      }
      is_in_array "$normalized" "${BUILD_ONLY_STAGES[@]}" && {
        echo "--only 阶段重复: $normalized" >&2
        return 1
      }
      BUILD_ONLY_STAGES+=("$normalized")
    done
  done
  [[ ${#BUILD_ONLY_STAGES[@]} -gt 0 ]] || {
    echo "--only 至少需要指定一个编译阶段" >&2
    return 1
  }
  BUILD_MODE="selective"
}

parse_build_args() {
  BUILD_START_STAGE=""
  BUILD_ONLY_STAGES=()
  BUILD_FULL_BUILD=0
  BUILD_MODE="selective"
  if [[ $# -eq 0 ]]; then
    BUILD_FULL_BUILD=1
    BUILD_MODE="full"
    return 0
  fi

  case "$1" in
    --only)
      shift
      parse_only_build_args "$@" || return 1
      ;;
    --only=*)
      local list="${1#--only=}"
      [[ -n "$list" ]] || { echo "--only= 后必须指定阶段" >&2; return 1; }
      shift
      parse_only_build_args "$list" "$@" || return 1
      ;;
    *)
      [[ $# -eq 1 ]] || { echo "build [stage] 仅接受一个起始阶段；多个阶段请用 --only" >&2; return 1; }
      BUILD_START_STAGE="$(normalize_stage "$1")" || {
        echo "未知编译阶段参数: $1" >&2
        return 1
      }
      is_known_stage "$BUILD_START_STAGE" || {
        echo "未知编译阶段参数: $1" >&2
        return 1
      }
      BUILD_MODE="resume"
      ;;
  esac
}

run_build() {
  parse_build_args "$@" || exit 2
  BUILD_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local START_STAGE="$BUILD_START_STAGE"
  local FULL_BUILD="$BUILD_FULL_BUILD"
  local -a only_stages=("${BUILD_ONLY_STAGES[@]}")
  local BUILT_FFMPEG=0
  BUILT_STAGES=()

  # Preflight only requested source trees before toolchain setup or prefix cleanup.
  local stage repo include=0 start_reached=0
  for repo in "${STAGES[@]}"; do
    include=0
    if [[ "$FULL_BUILD" -eq 1 ]]; then
      include=1
    elif [[ ${#only_stages[@]} -gt 0 ]]; then
      is_in_array "$repo" "${only_stages[@]}" && include=1
    elif [[ -n "$START_STAGE" ]]; then
      [[ "$repo" == "$START_STAGE" ]] && start_reached=1
      ((start_reached)) && include=1
    fi
    ((include)) || continue
    if [[ "$repo" == "ffmpeg" ]]; then need_repo "ffmpeg-source"; else need_repo "$repo"; fi
  done

  echo "===> [子命令: build] 开始编译与链接依赖阶段..."
  setup_build_env
  trap on_error ERR

  if [[ "$FULL_BUILD" -eq 1 ]]; then
    echo "清理前一次 of prefix 安装产物..."
    rm -rf "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin"
  fi

  local RUN=0
  for stage in "${STAGES[@]}"; do
    if [[ ${#only_stages[@]} -gt 0 ]]; then
      if is_in_array "$stage" "${only_stages[@]}"; then
        run_stage "$stage"
        BUILT_STAGES+=("$stage")
        [[ "$stage" == "ffmpeg" ]] && BUILT_FFMPEG=1
      fi
    else
      if [[ "$FULL_BUILD" -eq 1 ]]; then
        RUN=1
      elif [[ "$stage" == "$START_STAGE" ]]; then
        RUN=1
      fi
      if [[ "$RUN" -eq 1 ]]; then
        run_stage "$stage"
        BUILT_STAGES+=("$stage")
        [[ "$stage" == "ffmpeg" ]] && BUILT_FFMPEG=1
      fi
    fi
  done

  CURRENT_STAGE=""
  write_full_manifest "$BUILD_MODE" "$BUILT_FFMPEG" "${BUILT_STAGES[@]}"
  echo
  echo "============================================================"
  if [[ ${#only_stages[@]} -gt 0 ]]; then
    local list_str
    list_str="$(IFS=', '; echo "${only_stages[*]}")"
    echo "成功编译了: $list_str"
  elif [[ -n "$START_STAGE" ]]; then
    echo "从 $START_STAGE 起的构建阶段已完成"
    echo "最终输出: $ROOT/full/ffmpeg.exe, $ROOT/full/ffprobe.exe, $ROOT/full/ffplay.exe"
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
  build [stage]   执行构建；可选 [stage] 从该阶段继续，仅接受一个起始阶段
  build --only stage[,stage...]  仅构建明确列出的库，不自动补齐依赖、不清空安装前缀
  --only 支持空格或逗号分隔；空列表、空项、重复项、未知阶段和多余参数都会在构建前拒绝
  clean           清理编译缓存和旧的编译产物，并删除 patch 临时包与 _bundle/ 目录

工具链:
  默认 TOOLCHAIN_FLAVOR=llvm-mingw：下载 llvm-mingw 最新 release，使用最新版 Clang/LLVM + UCRT
  全局安装目录：${GLOBAL_TOOLCHAIN_ROOT:-/usr/local}；可执行文件在 /usr/local/bin
  同步安装最新稳定版 CMake / Ninja / Meson / NASM；apt 只安装 bootstrap 依赖
  可选 GCC：TOOLCHAIN_FLAVOR=system 使用 apt win32；TOOLCHAIN_FLAVOR=xpack-mingw64-gcc 使用 xPack GCC
  跳过 CUDA Toolkit：CUDA_TOOLKIT_ENABLE=0 ./ffmpeg.sh tool


常见示例:
  $0 all
  $0 tool
  $0 update
  $0 build
  $0 build --ffmpeg
  $0 build --only libsoxr,libxml2
  $0 build --only x265
  $0 clean
EOF
}

if [[ "${FFMPEG_TEST_PARSE_BUILD_ARGS:-0}" == "1" ]]; then
  [[ "${1:-}" == "build" ]] || { echo "测试入口只接受 build" >&2; exit 2; }
  shift
  parse_build_args "$@" || exit 2
  printf 'full=%s;start=%s;only=%s\n' \
    "$BUILD_FULL_BUILD" "$BUILD_START_STAGE" "$(IFS=,; echo "${BUILD_ONLY_STAGES[*]}")"
  exit 0
fi

cmd="${1:-all}"
shift || true

case "$cmd" in
  all)
    run_tool
    run_update
    run_build
    ;;
  tool)
    run_tool
    ;;
  update)
    run_update "${1:-}"
    ;;
  build)
    run_build "$@"
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
