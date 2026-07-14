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

# 编译优化选项
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O3 -pipe -DNDEBUG -funwind-tables -fexceptions}"
INLINE_ENABLE="${INLINE_ENABLE:-1}"
INLINE_FLAGS="${INLINE_FLAGS:--finline-functions}"
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
  [x264]="https://github.com/mirror/x264.git"
  [x265]="https://github.com/videolan/x265.git"
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
  [libiconv]="https://git.savannah.gnu.org/git/libiconv.git"
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
  [libiconv]='^v?[0-9]+(\.[0-9]+)+$'
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
  [libzmq]='^v?[0-9]+(\.[0-9]+)+$'
  [libzvbi]='^v?[0-9]+(\.[0-9]+)+$'
  [libgsm]='^v?[0-9]+(\.[0-9]+)*([_-]pl[0-9]+)?$'
  [opencore-amr]='^v?[0-9]+(\.[0-9]+)+$'
  [vo-amrwbenc]='^v?[0-9]+(\.[0-9]+)+$'
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
  "dav1d"
  "svtav1hdr"
  "libvpl"
  "vapoursynth"
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
as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
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
  curl -fL --retry 3 -o "$archive" "$asset_url"
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
  curl -fL --retry 3 -o "$archive" "$asset_url"
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
    curl -fsSL --retry 3 -o "$tmp" https://apt.llvm.org/llvm.sh
    chmod +x "$tmp"
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
    curl -fL --retry 3 -o "$archive" "$url"
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
  "$SEVENZIP_ROOT/bin/7zz" i | head -n 2
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
    curl -fL --retry 3 -o "$archive" "$asset_url"
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
    curl -fL --retry 3 -o "$archive" "$asset_url"
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
    git clone --depth 1 --branch "$tag" "$NASM_REPO" "$src"
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

  echo "== Update apt bootstrap packages =="
  sudo apt update

  echo
  echo "== Install bootstrap packages (latest toolchains are downloaded below, not from apt) =="
  sudo apt install -y --no-install-recommends \
    build-essential \
    autoconf automake libtool make \
    pkg-config xxd \
    git curl ca-certificates tar xz-utils unzip \
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
    sudo apt install -y --no-install-recommends \
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
      curl -fL --retry 3 --retry-all-errors --connect-timeout 20 \
        -o "$tmpdeb" "$CUDA_KEYRING"
      sudo dpkg -i "$tmpdeb"
      rm -f "$tmpdeb"
    fi

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
    *)
      echo "${tag#v}"
      ;;
  esac
}

git_retry() {
  local attempt
  for attempt in 1 2 3 4; do
    if (( attempt % 2 == 1 )); then
      "$@" && return 0
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy "$@" && return 0
    fi
    echo "git command failed (attempt $attempt/4), retrying..." >&2
    sleep "$((attempt * 5))"
  done
  return 1
}

git_clone_retry() {
  local url="$1" dir="$2" attempt
  for attempt in 1 2 3 4; do
    rm -rf "$dir"
    if (( attempt % 2 == 1 )); then
      git clone --filter=blob:none "$url" "$dir" && return 0
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
        git clone --filter=blob:none "$url" "$dir" && return 0
    fi
    echo "git clone failed (attempt $attempt/4), retrying..." >&2
    sleep "$((attempt * 5))"
  done
  return 1
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
      git_clone_retry "$url" "$repo_dir"
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
    git_retry git -C "$repo_dir" pull --ff-only origin "$tag"
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

  echo "===> sanitize $name"
  if ! sanitize_repo "$repo_dir"; then
    echo "incomplete source tree detected, recloning $name"
    rm -rf "$repo_dir"
    clone_if_missing "$name"
  fi

  # 强制使用 HTTPS 远程源以防 SSH 连接超时
  local url="${URLS[$name]}"
  git -C "$repo_dir" remote set-url origin "$url" 2>/dev/null || true

  echo "===> fetch $name"
  git_retry git -C "$repo_dir" fetch --tags --prune --force origin

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
    expat
    brotli
    dav1d
    svtav1hdr
    libvpl
    vapoursynth
    x264
    x265
    vmaf
    vvenc
    vvdec
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
    dav1d) echo "dav1d" ;;
    svtav1hdr|svtav1|svt-av1|svt) echo "svtav1hdr" ;;
    libvpl|vpl) echo "libvpl" ;;
    vapoursynth|vs) echo "vapoursynth" ;;
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

  if [[ "$name" == "libdvdread" ]]; then
    # Its optional ChangeLog target runs `git log` from the Meson build dir.
    # Hide the staged reflog so Meson omits that non-runtime artifact.
    rm -f "$stage/.git/logs/HEAD"
  fi

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
    AVICAP32.DLL|IMM32.DLL|SETUPAPI.DLL|WINMM.DLL|NVCUDA.DLL|NVENCODEAPI64.DLL|VULKAN-1.DLL) return 0 ;;
  esac
  return 1
}

find_runtime_dll() {
  local dll="$1" dir found
  for dir in \
    "$ROOT/full" "$PREFIX/bin" \
    "$LLVM_MINGW_ROOT/bin" "$LLVM_MINGW_ROOT/$TARGET/bin" "$(dirname "$CC")"; do
    [[ -d "$dir" ]] || continue
    found="$(find "$dir" -maxdepth 1 -type f -iname "$dll" -print -quit 2>/dev/null || true)"
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
        "$STRIP" "$dst/$(basename "$src")" 2>/dev/null || true
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

verify_full_ffmpeg_config() {
  local cfg="$1" ff_stage="$2" key
  local required=(
    CONFIG_AAC_ENCODER CONFIG_LIBSOXR CONFIG_LIBSSH CONFIG_OPENCL CONFIG_D3D12VA
    CONFIG_OPENGL CONFIG_LIBSNAPPY CONFIG_LIBTHEORA CONFIG_LIBSPEEX CONFIG_LIBTWOLAME
    CONFIG_LIBMYSOFA CONFIG_LIBOPENMPT CONFIG_LIBDVDREAD CONFIG_LIBDVDNAV
    CONFIG_CHROMAPRINT CONFIG_LIBZMQ CONFIG_LIBZVBI CONFIG_LIBGSM
    CONFIG_LIBOPENCORE_AMRNB CONFIG_LIBOPENCORE_AMRWB CONFIG_LIBVO_AMRWBENC
    CONFIG_ICONV CONFIG_LIBPLACEBO_FILTER CONFIG_VULKAN
    CONFIG_LIBVPL CONFIG_AV1_QSV_ENCODER CONFIG_HEVC_QSV_ENCODER
    CONFIG_VAPOURSYNTH_DEMUXER
  )
  if [[ "$CUDA_ENABLE" == "1" ]]; then
    required+=(
      CONFIG_CUDA_NVCC CONFIG_CUVID CONFIG_AV1_NVENC_ENCODER
      CONFIG_HEVC_NVENC_ENCODER CONFIG_SCALE_CUDA_FILTER
      CONFIG_AV1_CUVID_DECODER CONFIG_H264_CUVID_DECODER
      CONFIG_HEVC_CUVID_DECODER CONFIG_MJPEG_CUVID_DECODER
      CONFIG_MPEG1_CUVID_DECODER CONFIG_MPEG2_CUVID_DECODER
      CONFIG_MPEG4_CUVID_DECODER CONFIG_VC1_CUVID_DECODER
      CONFIG_VP8_CUVID_DECODER CONFIG_VP9_CUVID_DECODER
    )
  fi
  for key in "${required[@]}"; do
    grep -q "^$key=yes$" "$cfg" || { echo "FFmpeg required feature disabled: $key"; exit 1; }
  done
  grep -Rqs '"aac_nmr_speed"' "$ff_stage/libavcodec" || {
    echo "FFmpeg source does not contain the NMR AAC speed option"
    exit 1
  }
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

    libiconv)
      local iconv_stage iconv_version iconv_archive iconv_cache
      iconv_stage="$(stage_src "libiconv")"
      iconv_version="$(git -C "$iconv_stage" describe --tags --always | sed 's/^v//')"
      iconv_cache="$ROOT/toolchains/source-archives"
      iconv_archive="$iconv_cache/libiconv-$iconv_version.tar.gz"
      if [[ ! -f "$iconv_archive" ]]; then
        mkdir -p "$iconv_cache"
        curl -fL --connect-timeout 15 -o "$iconv_archive.tmp" \
          "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$iconv_version.tar.gz" || \
          env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy \
            curl -fL --retry 4 --retry-all-errors --connect-timeout 20 \
              -o "$iconv_archive.tmp" \
              "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$iconv_version.tar.gz"
        mv "$iconv_archive.tmp" "$iconv_archive"
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
      grep -q '^pl_has_vk_proc_addr=1' "$PREFIX/lib/pkgconfig/libplacebo.pc" || {
        echo "libplacebo 未链接 Windows Vulkan loader 的 vkGetInstanceProcAddr"
        exit 1
      }
      ;;

    opus)
      build_autotools opus --disable-extra-programs --disable-deep-plc --disable-dred --disable-osce
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
      patch_ffmpeg_libplacebo_vulkan_import "$ff_stage"
      patch_ffmpeg_cxx_runtime "$ff_stage"
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
      local extra_ldflags="-L$PREFIX/lib -Wl,--allow-multiple-definition $LDFLAGS"
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
        --enable-cuvid \
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
        --enable-d3d12va \
        --enable-mediafoundation \
        --enable-amf \
        --enable-avisynth \
        --enable-dxva2 \
        --enable-vulkan \
        --enable-vulkan-static \
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
        --enable-encoder=aac

      verify_full_ffmpeg_config ffbuild/config.mak "$ff_stage"
      make -j"$FFMPEG_JOBS"
      make install
      popd >/dev/null

      # 拷贝编译好的可执行文件至 full 目录并剥离调试信息
      "$STRIP" "$PREFIX/bin/ffmpeg.exe" || true
      "$STRIP" "$PREFIX/bin/ffprobe.exe" || true
      "$STRIP" "$PREFIX/bin/ffplay.exe" || true
      "$STRIP" "$PREFIX/bin/"*.dll 2>/dev/null || true
      
      # 仅拷贝 FFmpeg 程序和运行时 DLL。
      mkdir -p "$ROOT/full"
      find "$ROOT/full" -maxdepth 1 -type f \( -iname "*.exe" -o -iname "*.dll" \) -delete
      rm -rf "$ROOT/full/plugins"
      cp -f "$PREFIX/bin/ffmpeg.exe" "$ROOT/full/ffmpeg.exe"
      cp -f "$PREFIX/bin/ffprobe.exe" "$ROOT/full/ffprobe.exe" 2>/dev/null || true
      cp -f "$PREFIX/bin/ffplay.exe" "$ROOT/full/ffplay.exe" 2>/dev/null || true
      find "$PREFIX/bin" -maxdepth 1 -type f -iname "*.dll" -exec cp -f {} "$ROOT/full/" \;

      # 递归补齐非系统 DLL 依赖，覆盖 Clang/GCC 运行时和第三方 DLL。
      copy_runtime_dll_closure
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
    run_update "${1:-}"
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
