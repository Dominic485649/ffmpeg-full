#!/usr/bin/env bash
# ==============================================================================
# FFmpeg 全功能交叉编译集成脚本 (MinGW-w64 x86_64-w64-mingw32)
# ==============================================================================
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export PYTHONIOENCODING=UTF-8
set -Eeuo pipefail

# Paths are independent of the caller's working directory and delivery folders.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/workspace.sh"
source "$SCRIPT_DIR/../lib/build-cache.sh"
FULL_RECIPES_DIR="$SCRIPT_DIR/../recipes/full"

# Existing generated paths are deliberately retained for incremental cache compatibility.
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
VMAF_REF="${VMAF_REF:-master}"
SOURCE_FETCH_TIMEOUT="${SOURCE_FETCH_TIMEOUT:-600}"
SOURCE_DOWNLOAD_TIMEOUT="${SOURCE_DOWNLOAD_TIMEOUT:-600}"
INCREMENTAL_BUILD="${INCREMENTAL_BUILD:-1}"

# 编译优化选项
BUILD_STARTED_AT=""
OPT_CFLAGS_BASE="${OPT_CFLAGS_BASE:--O3 -pipe -DNDEBUG -funwind-tables -fexceptions}"
INLINE_ENABLE="${INLINE_ENABLE:-1}"
INLINE_FLAGS="${INLINE_FLAGS:--finline-functions}"
SECTION_GC_ENABLE="${SECTION_GC_ENABLE:-1}"
LTO_ENABLE="${LTO_ENABLE:-1}"
CFG_ENABLE="${CFG_ENABLE:-1}"
LTO_FLAGS="${LTO_FLAGS:--flto=thin}"
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
  [expat]="https://github.com/libexpat/libexpat.git"
  [brotli]="https://github.com/google/brotli.git"
  [dav1d]="https://code.videolan.org/videolan/dav1d.git"
  [svtav1]="https://gitlab.com/AOMediaCodec/SVT-AV1.git"
  [libvpl]="https://github.com/intel/libvpl.git"
  [x264]="https://github.com/mirror/x264.git"
  [x265]="https://bitbucket.org/multicoreware/x265_git.git"
  [vmaf]="https://github.com/Netflix/vmaf.git"
  [sdl2]="https://github.com/libsdl-org/SDL.git"
  [zlib]="https://github.com/madler/zlib.git"
  [bzip2]="https://github.com/libarchive/bzip2.git"
  [lzma]="https://github.com/tukaani-project/xz.git"

  [libxml2]="https://github.com/GNOME/libxml2.git"
  [libmp3lame]="https://github.com/TimothyGu/lame.git"
  [libsoxr]="https://github.com/chirlu/soxr.git"
  [libaom]="https://aomedia.googlesource.com/aom"
  [libvpx]="https://chromium.googlesource.com/webm/libvpx"
  [libopenjpeg]="https://github.com/uclouvain/openjpeg.git"
  [libsrt]="https://github.com/Haivision/srt.git"
  [librist]="https://code.videolan.org/rist/librist.git"
  [libbluray]="https://code.videolan.org/videolan/libbluray.git"
  [lcms2]="https://github.com/mm2/Little-CMS.git"
  [librubberband]="https://github.com/breakfastquay/rubberband.git"
  [libvidstab]="https://github.com/georgmartius/vid.stab.git"
  [libshaderc]="https://github.com/google/shaderc.git"
  [libplacebo]="https://github.com/haasn/libplacebo.git"
  [vulkan-headers]="https://github.com/KhronosGroup/Vulkan-Headers.git"
  [mbedtls]="https://github.com/Mbed-TLS/mbedtls.git"
  [avisynth]="https://github.com/AviSynth/AviSynthPlus.git"
  [libssh]="https://git.libssh.org/projects/libssh.git"
  [libiconv]="https://github.com/winlibs/libiconv.git"
  [libpng]="https://github.com/pnggroup/libpng.git"
  [libsnappy]="https://github.com/google/snappy.git"
  [libmysofa]="https://github.com/hoene/libmysofa.git"
  [libdvdread]="https://code.videolan.org/videolan/libdvdread.git"
  [libdvdnav]="https://code.videolan.org/videolan/libdvdnav.git"
  [chromaprint]="https://github.com/acoustid/chromaprint.git"
  [libzmq]="https://github.com/zeromq/libzmq.git"
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
  [svtav1]='^v[0-9]+(\.[0-9]+)*$'
  [libvpl]='^v2\.[0-9]+(\.[0-9]+)*$'
  [x264]='stable|master'
  [x265]='^[0-9]+\.[0-9]+(\.[0-9]+)*$|^v[0-9]+\.[0-9]+(\.[0-9]+)*$'
  [vmaf]='^v[0-9]+(\.[0-9]+)*$'
  [sdl2]='^release-2\.[0-9]+(\.[0-9]+)*$'
  [zlib]='^v[0-9]+(\.[0-9]+)*$'
  [bzip2]='^bzip2-[0-9]+(\.[0-9]+)*$'
  [lzma]='^v[0-9]+(\.[0-9]+)*$'

  [libxml2]='^v[0-9]+(\.[0-9]+)*$'
  [libmp3lame]='master'
  [libsoxr]='^v?[0-9]+(\.[0-9]+)*$'
  [libaom]='^v[0-9]+(\.[0-9]+)*$'
  [libvpx]='^v[0-9]+(\.[0-9]+)*$'
  [libopenjpeg]='^v[0-9]+(\.[0-9]+)*$'
  [libsrt]='^v[0-9]+(\.[0-9]+)*$'
  [librist]='^v[0-9]+(\.[0-9]+)*$'
  [libbluray]='^[0-9]+(\.[0-9]+)*$'
  [lcms2]='^lcms[0-9]+(\.[0-9]+)*$'
  [librubberband]='^v?[0-9]+(\.[0-9]+)*$'
  [libvidstab]='^v?[0-9]+(\.[0-9]+)*$'
  [libshaderc]='^v[0-9]+\.[0-9]+$'
  [libplacebo]='^v[0-9]+(\.[0-9]+)*$'
  [vulkan-headers]='^v[0-9]+(\.[0-9]+)*$'
  [mbedtls]='^v3\.[0-9]+(\.[0-9]+)*$'
  [avisynth]='^v[0-9]+(\.[0-9]+)*$'
  [libssh]='^(libssh-)?v?[0-9]+(\.[0-9]+)+$'
  [libiconv]='^libiconv-[0-9]+(\.[0-9]+)+$'
  [libpng]='^v?1\.[0-9]+\.[0-9]+$'
  [libsnappy]='^[0-9]+(\.[0-9]+)+$'
  [libmysofa]='^v?[0-9]+(\.[0-9]+)+$'
  [libdvdread]='^v?[0-9]+(\.[0-9]+)+$'
  [libdvdnav]='^v?[0-9]+(\.[0-9]+)+$'
  [chromaprint]='^v?[0-9]+(\.[0-9]+)+$'
  [libzmq]='master'
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
  "libsoxr"
  "libaom"
  "libvpx"
  "libopenjpeg"
  "mbedtls"
  "libssh"
  "libsnappy"
  "libmysofa"
  "libdvdread"
  "libdvdnav"
  "chromaprint"
  "libzmq"
  "libsrt"
  "librist"
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
  "libbluray"
  "libass"
  "libwebp"
  "brotli"
  "libjxl"
  "dav1d"
  "svtav1"
  "libvpl"
  "x264"
  "x265"
  "vmaf"
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
  local repo_dir="$1" canonical_url="$2" refspec="${3:?explicit upstream refspec required}"
  local expected="${4:?verified canonical object SHA required}" candidate mode old destination
  [[ "$expected" =~ ^[0-9a-fA-F]{40,64}$ && "$refspec" == *:* ]] || return 1
  destination="${refspec#*:}"
  old="$(git -C "$repo_dir" rev-parse --verify "$destination" 2>/dev/null || true)"
  if [[ "$destination" == refs/tags/* && -n "$old" && "$old" != "$expected" ]]; then
    echo "Local tag conflict preserved without force: $destination" >&2
    return 1
  fi
  # Canonical ls-remote already proved freshness. Existing verified objects need
  # no history transfer; mirrors may supply only that exact canonical SHA.
  if ! git -C "$repo_dir" cat-file -e "$expected^{object}" 2>/dev/null; then
    local fetched=0 attempt=0
    while IFS= read -r candidate; do
      for mode in proxy direct; do
        [[ "$mode" != proxy ]] || has_network_proxy || continue
        attempt=$((attempt + 1))
        echo "git fetch verified object $expected via $mode (attempt $attempt)"
        if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" \
          git -c http.version=HTTP/1.1 -C "$repo_dir" fetch --no-tags "$candidate" "$expected"; then
          if git -C "$repo_dir" cat-file -e "$expected^{object}"; then fetched=1; break 2; fi
        fi
        # Some servers refuse raw SHA wants. Fetch the named ref to FETCH_HEAD
        # only (no destination), then verify the canonical object before any
        # local tag/remote-tracking ref is installed.
        if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" \
          git -c http.version=HTTP/1.1 -C "$repo_dir" fetch --no-tags "$candidate" "${refspec%%:*}"; then
          if git -C "$repo_dir" cat-file -e "$expected^{object}"; then fetched=1; break 2; fi
        fi
      done
    done < <(git_url_variants "$canonical_url")
    [[ "$fetched" == 1 ]] || return 1
  fi
  if [[ "$destination" == refs/remotes/* && -n "$old" && "$old" != "$expected" ]]; then
    git -C "$repo_dir" merge-base --is-ancestor "$old" "$expected" || {
      echo "Remote-tracking ref is not a fast-forward; preserving $destination" >&2
      return 1
    }
  fi
  git -C "$repo_dir" update-ref "$destination" "$expected" "$old"
}

git_clone_retry() {
  local canonical_url="$1" dir="$2" ref="${3:-}" candidate mode attempt=0 attempt_dir
  local clone_args=(git -c http.version=HTTP/1.1 clone --filter=blob:none)
  if [[ -e "$dir" || -L "$dir" ]]; then
    echo "克隆目标已存在，拒绝删除或覆盖: $dir" >&2
    return 1
  fi
  mkdir -p "$(dirname "$dir")"
  if [[ -n "$ref" ]]; then
    clone_args+=(--depth 1 --branch "$ref")
  fi
  while IFS= read -r candidate; do
    for mode in proxy direct; do
      [[ "$mode" != proxy ]] || has_network_proxy || continue
      attempt=$((attempt + 1))
      attempt_dir="$(mktemp -d "$(dirname "$dir")/.$(basename "$dir").clone-XXXXXXXX")" || return 1
      echo "git clone: ${candidate%%:*} via $mode (attempt $attempt)"
      if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" \
        "${clone_args[@]}" "$candidate" "$attempt_dir"; then
        # Do not overwrite a destination created while the clone was running.
        if [[ ! -e "$dir" && ! -L "$dir" ]]; then
          mv -T -n -- "$attempt_dir" "$dir"
          [[ -e "$attempt_dir" ]] || return 0
        fi
        echo "克隆期间目标已被创建，保留已有内容: $dir" >&2
        rm -rf -- "$attempt_dir"
        return 1
      fi
      # Only this invocation's freshly created temporary directory is disposable.
      rm -rf -- "$attempt_dir"
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
    ffmpeg-source|vmaf) return 1 ;;
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
  local repo_dir
  repo_dir="$(ffbuild_source_dir "$name")"
  local url="${URLS[$name]}"

  if [[ ! -e "$repo_dir/.git" ]]; then
    if [[ -e "$repo_dir" || -L "$repo_dir" ]]; then
      echo "源码路径已存在但不是有效仓库，拒绝覆盖: $repo_dir" >&2
      return 1
    fi
    echo "===> clone $name from $url"
    git_clone_retry "$url" "$repo_dir"
  fi
}

latest_stable_tag() {
  local name="$1"
  local repo_dir
  repo_dir="$(ffbuild_source_dir "$name")"
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
  ffbuild_verify_source_clean "$@" || return 1
  local status
  status="$(GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false -C "$1" status --porcelain --untracked-files=all --ignore-submodules=none)" || return 1
  [[ -z "$status" ]] || {
    echo "源码或递归子模块含本地修改，保留并停止更新: $1" >&2
    printf '%s\n' "$status" >&2
    return 1
  }
}

full_ls_remote_retry() {
  local url="$1" mode
  shift
  # A mirror may lag. Only the official URL can establish "latest"; mirrors
  # are restricted to supplying objects for an already verified official SHA.
  for mode in proxy direct; do
    [[ "$mode" != proxy ]] || has_network_proxy || continue
    if run_network_command "$mode" "$SOURCE_FETCH_TIMEOUT" \
      git -c http.version=HTTP/1.1 ls-remote "$@" "$url"; then return 0; fi
    echo "canonical upstream ref listing failed ($mode): $url" >&2
  done
  return 1
}

full_latest_upstream_ref() {
  local name="$1" url="${URLS[$1]}" ref sha refs selected branch peeled regex="${TAG_REGEX[$1]}"
  if [[ "$name" == ffmpeg-source || "$name" == vmaf ]]; then
    if [[ "$name" == ffmpeg-source ]]; then ref="$FFMPEG_REF"; else ref="$VMAF_REF"; fi
    git check-ref-format --branch "$ref" >/dev/null || return 1
    refs="$(full_ls_remote_retry "$url" --heads --refs)" || return 1
    while IFS=$'\t' read -r sha branch; do
      if [[ "$branch" == "refs/heads/$ref" ]]; then printf 'branch\t%s\t%s\n' "$ref" "$sha"; return 0; fi
    done <<< "$refs"
    echo "Upstream branch not found: $name origin/$ref" >&2
    return 1
  fi
  # Query upstream, not the stale local tag list. Fetch only the selected tag,
  # avoiding hundreds of MB of unrelated history (notably libmysofa).
  refs="$(full_ls_remote_retry "$url" --tags)" || return 1
  selected="$(
    while IFS=$'\t' read -r sha ref; do
      [[ "$ref" == refs/tags/* && "$ref" != *'^{}' && "$sha" =~ ^[0-9a-fA-F]{40,64}$ ]] || continue
      ref="${ref#refs/tags/}"
      if [[ "$ref" =~ $regex ]]; then printf '%s\t%s\t%s\n' "$(normalize_version "$name" "$ref")" "$ref" "$sha"; fi
    done <<< "$refs" | sort -V | tail -n 1
  )" || return 1
  if [[ -n "$selected" ]]; then
    IFS=$'\t' read -r branch ref sha <<< "$selected"
    peeled="$sha"
    while IFS=$'\t' read -r branch selected; do
      if [[ "$selected" == "refs/tags/$ref^{}" ]]; then peeled="$branch"; break; fi
    done <<< "$refs"
    printf 'tag\t%s\t%s\t%s\n' "$ref" "$sha" "$peeled"
    return 0
  fi
  refs="$(full_ls_remote_retry "$url" --heads --refs)" || return 1
  for branch in stable master main; do
    [[ "$regex" == *"$branch"* ]] || continue
    while IFS=$'\t' read -r sha ref; do
      if [[ "$ref" == "refs/heads/$branch" ]]; then printf 'branch\t%s\t%s\n' "$branch" "$sha"; return 0; fi
    done <<< "$refs"
  done
  echo "No upstream stable ref matched for $name" >&2
  return 1
}

checkout_stable() {
  local name="$1"
  local repo_dir
  repo_dir="$(ffbuild_source_dir "$name")"
  local tag="$2" kind="${3:-}"
  local ver
  ver="$(normalize_version "$name" "$tag")"

  verify_source_repo_clean "$repo_dir" || return 1
  if [[ "$kind" != tag ]] && git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$tag"; then
    echo "     -> Fast-forward $name branch $tag..."
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$tag"; then
      git -C "$repo_dir" merge-base --is-ancestor "refs/heads/$tag" "refs/remotes/origin/$tag" || {
        echo "本地分支 $tag 含上游没有的提交，保留并停止更新: $repo_dir" >&2
        return 1
      }
      git -C "$repo_dir" switch "$tag" || return 1
    else
      git -C "$repo_dir" switch --create "$tag" --track "origin/$tag" || return 1
    fi
    git -C "$repo_dir" merge --ff-only "refs/remotes/origin/$tag" || return 1
  elif [[ "$name" == "ffmpeg-source" || "$name" == "vmaf" ]]; then
    echo "缺少所请求的上游分支 origin/$tag: $repo_dir" >&2
    return 1
  else
    git -C "$repo_dir" switch --detach "refs/tags/$tag" || return 1
  fi

  git_retry git -c "remote.origin.url=${URLS[$name]}" -C "$repo_dir" submodule update --init --recursive || return 1

  local commit_hash
  commit_hash="$(git -C "$repo_dir" rev-parse HEAD)"
  local remote_url
  remote_url="$(git -C "$repo_dir" remote get-url origin)"
  echo "     -> $name: source=$remote_url, ref=$tag, commit=$commit_hash"
}

update_one() {
  local name="$1"
  local repo_dir
  repo_dir="$(ffbuild_source_dir "$name")"

  # Check existing inputs before even cloning/fetching another repository.
  if [[ -e "$repo_dir" || -L "$repo_dir" ]]; then
    verify_source_repo_clean "$repo_dir" || return 1
  fi
  clone_if_missing "$name" || return 1

  echo "===> verify clean source tree $name"
  verify_source_repo_clean "$repo_dir" || return 1

  # Fetch canonical/mirror URLs explicitly; preserve the user's origin config.
  local url="${URLS[$name]}"

  echo "===> resolve latest upstream ref $name"
  local selection kind tag expected expected_commit refspec actual
  if ! selection="$(full_latest_upstream_ref "$name")"; then
    if [[ "${ALLOW_OFFLINE_STABLE_SOURCE:-0}" == 1 ]] && local_source_is_usable "$name" "$repo_dir"; then
      echo "$name: explicit offline mode; existing stable source is NOT claimed to be latest" >&2
      return 0
    fi
    echo "$name upstream Git unavailable; refusing to claim a stale local tag is latest" >&2
    return 1
  fi
  IFS=$'\t' read -r kind tag expected expected_commit <<< "$selection"
  if [[ "$kind" == branch ]]; then
    refspec="refs/heads/$tag:refs/remotes/origin/$tag"
  elif [[ "$kind" == tag ]]; then
    refspec="refs/tags/$tag:refs/tags/$tag"
  else
    echo "Invalid upstream selection for $name" >&2
    return 1
  fi
  echo "===> fetch $name $tag (only the selected upstream ref)"
  git_fetch_retry "$repo_dir" "$url" "$refspec" "$expected" || return 1
  if [[ "$kind" == branch ]]; then
    actual="$(git -C "$repo_dir" rev-parse "refs/remotes/origin/$tag")" || return 1
  else
    actual="$(git -C "$repo_dir" rev-parse "refs/tags/$tag")" || return 1
  fi
  [[ "$actual" == "$expected" ]] || {
    echo "Upstream ref changed during fetch for $name ($expected != $actual); retry without overwriting local refs" >&2
    return 1
  }
  if [[ "$kind" == tag ]]; then
    actual="$(git -C "$repo_dir" rev-parse --verify "refs/tags/$tag^{commit}")" || return 1
    [[ "$actual" == "$expected_commit" ]] || {
      echo "Annotated/lightweight tag commit disagrees with canonical upstream: $name $tag" >&2
      return 1
    }
  fi
  checkout_stable "$name" "$tag" "$kind"
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
    svtav1
    libvpl
    x264
    x265
    vmaf
    sdl2
    zlib
    bzip2
    lzma
    libiconv
    libpng

    libxml2
    libmp3lame
    libsoxr
    libaom
    libvpx
    libopenjpeg
    mbedtls
    libssh
    libsnappy
    libmysofa
    libdvdread
    libdvdnav
    chromaprint
    libzmq
    libsrt
    librist
    libbluray
    lcms2
    librubberband
    libvidstab
    libshaderc
    libplacebo
    vulkan-headers
    avisynth
  )

  local r repo_dir
  local -a requested_repos=()
  for r in "${repos[@]}"; do
    if [[ -n "$start" && "$seen" == "0" ]]; then
      [[ "$r" == "$start" ]] && seen=1 || continue
    fi
    requested_repos+=("$r")
  done
  [[ -z "$start" || "$seen" == "1" ]] || { echo "unknown update start repo: $start" >&2; return 1; }
  # Complete the selected scope's safety preflight before the first clone/fetch.
  for r in "${requested_repos[@]}"; do
    repo_dir="$(ffbuild_source_dir "$r")" || return 1
    if [[ -e "$repo_dir" || -L "$repo_dir" ]]; then verify_source_repo_clean "$repo_dir" || return 1; fi
  done
  for r in "${requested_repos[@]}"; do update_one "$r" || return 1; done

  echo
  echo "All source trees are updated successfully."
  echo
  echo "== Source version manifest =="
  for r in "${repos[@]}"; do
    printf '%-24s ref=%-24s commit=%s\n' \
      "$r" \
      "$(git -C "$(ffbuild_source_dir "$r")" describe --tags --always 2>/dev/null || echo unknown)" \
      "$(git -C "$(ffbuild_source_dir "$r")" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
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
    libsoxr|soxr) echo "libsoxr" ;;
    libaom|aom) echo "libaom" ;;
    libvpx|vpx) echo "libvpx" ;;
    libopenjpeg|openjpeg) echo "libopenjpeg" ;;
    mbedtls) echo "mbedtls" ;;
    libssh|ssh) echo "libssh" ;;
    libsnappy|snappy) echo "libsnappy" ;;
    libmysofa|mysofa) echo "libmysofa" ;;
    libdvdread|dvdread) echo "libdvdread" ;;
    libdvdnav|dvdnav) echo "libdvdnav" ;;
    chromaprint) echo "chromaprint" ;;
    libzmq|zmq|zeromq) echo "libzmq" ;;
    libsrt|srt) echo "libsrt" ;;
    librist|rist) echo "librist" ;;
    libbluray|bluray) echo "libbluray" ;;
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
    svtav1|svt-av1|svt) echo "svtav1" ;;
    libvpl|vpl) echo "libvpl" ;;
    x264) echo "x264" ;;
    x265) echo "x265" ;;
    vmaf) echo "vmaf" ;;
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
  local name="$1" repo_dir
  repo_dir="$(ffbuild_source_dir "$name")"
  [[ -d "$repo_dir" ]] || {
    echo "缺少源码目录: $repo_dir"
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

# Only successful, content-verified staged sources may be synchronized. Old
# unrecorded trees (including their patches/objects) remain completely untouched.
FULL_STAGE_COMPAT_KEY=""
FULL_STAGE_REPO=""
FULL_CACHE_TOOLCHAIN_KEY=""
FULL_CACHE_DRIVER_KEY=""
declare -A FULL_STAGE_IDENTITIES=()
FULL_SHADERC_DEP_DIRS=(third_party/abseil_cpp third_party/effcee third_party/glslang
  third_party/googletest third_party/re2 third_party/spirv-headers third_party/spirv-tools)

full_source_reusable() {
  case "$1" in
    ffmpeg-source|vmaf|x265|libaom|libjxl|libshaderc|libplacebo) return 0 ;;
  esac
  # Out-of-tree CMake/Meson recipes can detect changed source/header contents;
  # unverified in-tree autotools/custom builds start from a new independent copy.
  grep -Eq 'build_cmake|build_meson|cmake -S|meson setup' "$FULL_RECIPES_DIR/$1.sh"
}

stage_src() {
  local name="$1" src compat reuse=0
  local -a extra=()
  src="$(ffbuild_source_dir "$name")" || return 1
  [[ -d "$src" ]] || { echo "缺少原始源码: $src" >&2; return 1; }
  ffbuild_assert_staging_path "$BUILDROOT" "$BUILDROOT/_src/$name" "$src" || return 1
  if [[ "$name" == "$FULL_STAGE_REPO" && -n "$FULL_STAGE_COMPAT_KEY" ]]; then
    compat="$FULL_STAGE_COMPAT_KEY"
  else
    # Auxiliary sources never inherit another stage's compatibility namespace.
    compat="$(ffbuild_cache_hash full-auxiliary "$name" "$(ffbuild_cache_source_compat_key "$src")" \
      "${FULL_CACHE_TOOLCHAIN_KEY:-$(ffbuild_cache_toolchain_key)}" "$(ffbuild_cache_tree_key "${BASH_SOURCE[0]}" "$SCRIPT_DIR/../lib/build-cache.sh")")" || return 1
  fi
  [[ "$name" != libshaderc ]] || extra=("${FULL_SHADERC_DEP_DIRS[@]}")
  if [[ "$INCREMENTAL_BUILD" == 1 ]] && full_source_reusable "$name"; then reuse=1; fi
  if [[ "$INCREMENTAL_BUILD" != 1 ]]; then compat="$(ffbuild_cache_hash "$compat" force "$BASHPID" "$RANDOM")"; fi
  ffbuild_cache_stage "$src" "$BUILDROOT/_src/$name" "$compat" "$reuse" "${extra[@]}"
}

full_build_directory() {
  local candidate="${1:?build candidate required}" stage="${2:?source directory required}" kind="${3:?build kind required}"
  shift 3
  [[ "$candidate" == /* && "$stage" == /* ]] || { echo 'Full build paths must be absolute' >&2; return 1; }
  ffbuild_assert_generated_path "$candidate" || return 1
  local compat bld
  compat="$(ffbuild_cache_hash full-build-directory "$kind" "$stage" "${FULL_STAGE_COMPAT_KEY:-unconfigured}" "$@")" || return 1
  if [[ "$INCREMENTAL_BUILD" != 1 ]]; then compat="$(ffbuild_cache_hash "$compat" force "$BASHPID" "$RANDOM")"; fi
  bld="$(ffbuild_cache_build_dir "$candidate" "$compat")" || return 1
  if [[ -n "${FULL_STAGE_DIRECTORY_LOG:-}" ]]; then printf '%s\n' "$bld" >> "$FULL_STAGE_DIRECTORY_LOG" || return 1; fi
  printf '%s\n' "$bld"
}

full_prepare_shaderc_dependencies() {
  local stage="${1:?shaderc stage required}"
  if ffbuild_cache_shaderc_deps_key "$stage" >/dev/null 2>&1; then printf '%s\n' "$stage"; return 0; fi
  # Never let an upstream sync script alter an existing checkout/config. A
  # failed or unknown tree stays intact while acquisition uses a new copy.
  stage="$(ffbuild_cache__python stage-rotate-deps "$stage" "${FULL_SHADERC_DEP_DIRS[@]}")" || return 1
  if ffbuild_cache_shaderc_sync_deps "$stage" "$BUILDROOT" >/dev/null; then
    printf '%s\n' "$stage"
    return 0
  fi
  echo 'shaderc DEPS acquisition failed; attempts retained and no success cache written' >&2
  return 1
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
  local meson_lto=false meson_lto_mode=default
  local meson_cuda=""
  if [[ "$LTO_ENABLE" == "1" ]]; then meson_lto=true; meson_lto_mode=thin; fi
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
b_lto_mode = '$meson_lto_mode'

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

  make -j"$JOBS"
  make install
  popd >/dev/null
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
  local bld ipo=OFF
  [[ "$LTO_ENABLE" == "1" ]] && ipo=ON
  bld="$(full_build_directory "$BUILDROOT/$name" "$stage" cmake "$@" "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$ipo")"

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
  local bld cache_hit=0
  bld="$(full_build_directory "$BUILDROOT/$name" "$stage" meson "$@" --cross-file "$BUILDROOT/mingw-cross.txt" --prefix "$PREFIX")"

  if [[ "$name" == "libdvdread" ]]; then
    # Its optional ChangeLog target runs `git log` from the Meson build dir.
    # Hide the staged reflog so Meson omits that non-runtime artifact.
    rm -f "$stage/.git/logs/HEAD"
  fi

  if [[ -f "$bld/meson-private/coredata.dat" ]]; then cache_hit=1; fi

  if ((cache_hit)); then
    meson setup --clearcache --reconfigure "$bld" "$stage" \
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
  meson install --no-rebuild -C "$bld"
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

find_runtime_dll() {
  local dll="$1" dir found
  for dir in \
    "$PREFIX/bin" \
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
  local dst="${1:-$ROOT/full}" dump_tool tmp imports missing changed file dll src
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
    CONFIG_AAC_ENCODER CONFIG_LIBSOXR CONFIG_LIBSSH  CONFIG_D3D11VA CONFIG_D3D12VA
    CONFIG_LIBSNAPPY
    CONFIG_PNG_ENCODER CONFIG_PNG_DECODER CONFIG_APNG_ENCODER CONFIG_APNG_DECODER CONFIG_LIBMYSOFA  CONFIG_LIBDVDREAD CONFIG_LIBDVDNAV
    CONFIG_CHROMAPRINT CONFIG_LIBZMQ  
      
    CONFIG_ICONV CONFIG_LIBPLACEBO_FILTER CONFIG_VULKAN
    CONFIG_LIBVPL CONFIG_AV1_QSV_ENCODER CONFIG_HEVC_QSV_ENCODER
    CONFIG_LIBAOM_AV1_ENCODER CONFIG_LIBSVTAV1_ENCODER
    CONFIG_LIBX264_ENCODER CONFIG_LIBX264RGB_ENCODER CONFIG_LIBX265_ENCODER
    CONFIG_LIBVMAF_FILTER CONFIG_LIBJXL_DECODER CONFIG_LIBJXL_ANIM_DECODER
    CONFIG_LIBVPX_VP8_DECODER CONFIG_LIBVPX_VP9_DECODER
    CONFIG_AMF CONFIG_HEVC_AMF_ENCODER CONFIG_AV1_AMF_ENCODER CONFIG_H264_AMF_DECODER
    CONFIG_H264_QSV_ENCODER CONFIG_H264_MF_ENCODER CONFIG_H264_D3D12VA_ENCODER
    CONFIG_VVC_DECODER CONFIG_VVC_QSV_DECODER CONFIG_VP3_DECODER CONFIG_VP4_DECODER
    CONFIG_WEBP_DECODER CONFIG_LIBWEBP_ENCODER CONFIG_LIBWEBP_ANIM_ENCODER
    CONFIG_OGG_DEMUXER CONFIG_OGG_MUXER CONFIG_LIBOPUS_ENCODER
    CONFIG_AVS_DECODER CONFIG_CAVS_DECODER
    CONFIG_HEVC_DECODER CONFIG_AV1_DECODER CONFIG_LIBDAV1D_DECODER
    CONFIG_DOVI_RPUDEC CONFIG_DOVI_RPUENC CONFIG_DOVI_RPU_BSF CONFIG_DOVI_SPLIT_BSF
    CONFIG_MOV_DEMUXER CONFIG_MOV_MUXER CONFIG_MATROSKA_DEMUXER CONFIG_MATROSKA_MUXER
    CONFIG_MPEGTS_DEMUXER
    HAVE_STRUCT_MFXCONFIGINTERFACE
    
  )
  if [[ "$CUDA_ENABLE" == "1" ]]; then
    required+=(
      CONFIG_CUDA_NVCC CONFIG_NVDEC CONFIG_AV1_NVENC_ENCODER
      CONFIG_HEVC_NVENC_ENCODER CONFIG_SCALE_CUDA_FILTER
      
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
  grep -q 'ff_parse_itu_t_t35_to_dynamic_hdr_vivid' "$ff_stage/libavcodec/itut35.c" || {
    echo "FFmpeg mainline HDR Vivid T.35 parser is missing" >&2; exit 1;
  }
  grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_VIVID' "$ff_stage/libavcodec/hevc/hevcdec.c" || {
    echo "FFmpeg HEVC HDR Vivid frame metadata path is missing" >&2; exit 1;
  }
  python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" check-config "$cfg" || return 1
  for key in CONFIG_LIBDAVS2_DECODER CONFIG_LIBUAVS3D_DECODER CONFIG_LIBXAVS_ENCODER CONFIG_LIBXAVS2_ENCODER; do
    if grep -q "^$key=yes$" "$cfg"; then
      echo "External AVS2/3 decoder or AVS encoder unexpectedly enabled: $key"
      exit 1
    fi
  done
  if grep -Eq '^CONFIG_(CUVID|.*_CUVID_DECODER)=yes$' "$cfg"; then
    echo "FFmpeg legacy CUVID decoder is unexpectedly enabled"
    exit 1
  fi
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
  grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_PLUS' "$ff_stage/libavcodec/libaomenc.c" || {
    echo "FFmpeg libaom HDR10+ passthrough is missing"
    exit 1
  }
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

verify_encoder_bitdepths() {
  local ffmpeg="$1"
  echo "== Verify encoder bit-depth output =="
  local capabilities
  capabilities="$("$ffmpeg" -hide_banner -h encoder=libx264 2>&1)"
  ! grep -Eq 'Supported pixel formats:.*(10(le|be)|p010|p210|nv20)' <<<"$capabilities" || { echo "x264 still advertises 10-bit output" >&2; return 1; }
  capabilities="$("$ffmpeg" -hide_banner -h encoder=libx265 2>&1)"
  local formats
  formats="$(grep 'Supported pixel formats:' <<<"$capabilities")" || { echo "x265 pixel formats missing" >&2; return 1; }
  local format
  for format in ${formats#*:}; do
    [[ "$format" =~ 10(le|be)?$ ]] || { echo "x265 advertises a non-10-bit format: $format" >&2; return 1; }
  done
  encoder_bitdepth_smoke "$ffmpeg" libx264 yuv420p
  encoder_bitdepth_smoke "$ffmpeg" libx264 yuv422p
  encoder_bitdepth_smoke "$ffmpeg" libx264 yuv444p

  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv422p10le
  encoder_bitdepth_smoke "$ffmpeg" libx265 yuv444p10le

  encoder_bitdepth_smoke "$ffmpeg" libaom-av1 yuv420p
  encoder_bitdepth_smoke "$ffmpeg" libaom-av1 yuv420p10le
  encoder_bitdepth_smoke "$ffmpeg" libaom-av1 yuv420p12le
  encoder_bitdepth_smoke "$ffmpeg" libsvtav1 yuv420p
  encoder_bitdepth_smoke "$ffmpeg" libsvtav1 yuv420p10le
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

  for codec in avs cavs; do
    grep -Eq "[[:space:]]$codec([[:space:]]|$)" <<<"$decoders" || { echo "Native AVS1 decoder is missing: $codec" >&2; exit 1; }
  done
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
      echo "NVENC AV1 encoder is missing" >&2
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

verify_vmaf() {
  local ffmpeg="$1" filters
  echo "== Verify CPU VMAF default and v1 models =="
  filters="$("$ffmpeg" -hide_banner -filters 2>/dev/null)"
  grep -q 'libvmaf' <<<"$filters" || { echo "libvmaf filter is missing" >&2; exit 1; }
  "$ffmpeg" -hide_banner -loglevel error \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=1' \
    -f lavfi -i 'testsrc2=size=1920x1080:rate=1' \
    -filter_complex '[0:v][1:v]libvmaf=model=version=vmaf_v1.0.16_3d0h' \
    -frames:v 1 -f null - >/dev/null
  ! grep -q 'libvmaf_cuda' <<<"$filters" || { echo "libvmaf_cuda must be disabled" >&2; return 1; }
}

full_host_glslc_version() {
  local tool="$1" magic version
  [[ -x "$tool" ]] || return 1
  IFS= read -r -n 2 magic < "$tool" || return 1
  [[ "$magic" != MZ ]] || return 1
  version="$("$tool" --version 2>/dev/null)" || return 1
  [[ "$version" == *shaderc* || "$version" == *glslc* ]] || return 1
  printf '%s\n' "$version"
}

full_ensure_host_glslc_locked() {
  local canonical source_key source_compat native_key compat input_key deps_key stage bld version
  local candidate="$BUILDROOT/_src/libshaderc-host" owned_stage=0
  local record="$HOST_TOOLS/.full-glslc-cache.json" host_glslc="$HOST_TOOLS/bin/glslc"
  local -a host_env=(env -u CC -u CXX -u AR -u RANLIB -u STRIP -u RC -u WINDRES -u DLLTOOL
    -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR
    -u PKG_CONFIG_SYSROOT_DIR -u CMAKE_TOOLCHAIN_FILE -u CMAKE_PREFIX_PATH -u CMAKE_FIND_ROOT_PATH
    -u CMAKE_SYSROOT -u SYSROOT -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u LIBRARY_PATH)
  local -a args=(-G Ninja -DCMAKE_C_COMPILER=/usr/bin/cc -DCMAKE_CXX_COMPILER=/usr/bin/c++
    -DCMAKE_BUILD_TYPE=Release -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON
    -DSHADERC_ENABLE_EXECUTABLES=ON -DSHADERC_ENABLE_INSTALL=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
  canonical="$(ffbuild_source_dir libshaderc)" || return 1
  native_key="$(
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
    unset CMAKE_TOOLCHAIN_FILE CMAKE_PREFIX_PATH CMAKE_FIND_ROOT_PATH CMAKE_SYSROOT SYSROOT
    unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH NVCC
    CC=/usr/bin/cc CXX=/usr/bin/c++ AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip
    WINDRES='' DLLTOOL='' PKG_CONFIG=/usr/bin/pkg-config BACKEND=full-host
    TARGET="$(/usr/bin/cc -dumpmachine)"
    ffbuild_cache_toolchain_key
  )" || return 1
  source_compat="$(ffbuild_cache_source_compat_key "$canonical" "${FULL_SHADERC_DEP_DIRS[@]}")" || return 1
  compat="$(ffbuild_cache_hash full-host-glslc "$native_key" "$source_compat" "${args[@]}" \
    "$(ffbuild_cache_tree_key "$SCRIPT_DIR/full.sh" "$SCRIPT_DIR/../lib/build-cache.sh")")" || return 1
  # A successful Full target stage can seed native compilation, never another
  # profile's host executable or an unverified HEAD-only cache.
  stage="$(ffbuild_cache_stage_path "$BUILDROOT/_src/libshaderc" 2>/dev/null || true)"
  if [[ -n "$stage" ]] && ffbuild_cache_stage_valid "$BUILDROOT/_src/libshaderc" 2>/dev/null \
    && ffbuild_cache_shaderc_deps_key "$stage" >/dev/null 2>&1 \
    && [[ "$(ffbuild_cache__python stage-source-key "$BUILDROOT/_src/libshaderc")" == "$(ffbuild_cache_source_key "$canonical" "${FULL_SHADERC_DEP_DIRS[@]}")" ]]; then
    :
  else
    ffbuild_assert_staging_path "$BUILDROOT" "$candidate" "$canonical" || return 1
    stage="$(ffbuild_cache_stage "$canonical" "$candidate" "$compat" 1 "${FULL_SHADERC_DEP_DIRS[@]}")" || return 1
    stage="$(full_prepare_shaderc_dependencies "$stage")" || return 1
    owned_stage=1
  fi
  deps_key="$(ffbuild_cache_shaderc_deps_key "$stage")" || return 1
  source_key="$(ffbuild_cache_source_key "$stage" "${FULL_SHADERC_DEP_DIRS[@]}")" || return 1
  input_key="$(ffbuild_cache_hash "$compat" "$source_key" "$deps_key")" || return 1
  if [[ "$INCREMENTAL_BUILD" == 1 ]] && ffbuild_cache_hit "$record" "$input_key" \
    && full_host_glslc_version "$host_glslc" >/dev/null; then return 0; fi
  bld="$(ffbuild_cache_build_dir "$BUILDROOT/libshaderc-host" \
    "$(ffbuild_cache_hash "$compat" "$stage" "$deps_key")")" || return 1
  "${host_env[@]}" cmake -S "$stage" -B "$bld" "${args[@]}" || return 1
  "${host_env[@]}" cmake --build "$bld" --target glslc_exe --parallel "$JOBS" || return 1
  version="$(full_host_glslc_version "$bld/glslc/glslc")" || return 1
  mkdir -p "$HOST_TOOLS/bin" || return 1
  if [[ "${FFBUILD_BACKUP_PRODUCTS:-1}" != 0 && ( -e "$host_glslc" || -L "$host_glslc" ) ]]; then
    local backup
    backup="$(mktemp -d "$HOST_TOOLS/.preserved-glslc.XXXXXXXX")" || return 1
    cp -a -- "$host_glslc" "$backup/glslc" || return 1
  fi
  local temporary
  temporary="$(mktemp "$HOST_TOOLS/bin/.glslc.XXXXXXXX")" || return 1
  cp -- "$bld/glslc/glslc" "$temporary" || return 1
  chmod +x "$temporary" || return 1
  mv -f -- "$temporary" "$host_glslc" || return 1
  [[ "$owned_stage" == 0 ]] || ffbuild_cache_stage_commit "$candidate" >/dev/null || return 1
  ffbuild_cache_commit "$record" "$input_key" "$host_glslc"
}

ensure_host_glslc() {
  ffbuild_assert_generated_directory "$HOST_TOOLS" || return 1
  ffbuild_cache_lock "$HOST_TOOLS/.full-glslc.lock" full_ensure_host_glslc_locked
}

full_normalize_pkgconfig() {
  # These are build/link compatibility edits, not semantic hash normalization:
  # hash exactly the bytes consumers use, and write only when bytes change.
  python3 -I - "$PREFIX" <<'PYNORMALIZEPC'
from pathlib import Path
import re
import shutil
import sys
prefix = Path(sys.argv[1])
pcdir = prefix / 'lib/pkgconfig'
if not pcdir.is_dir():
    raise SystemExit(0)
if not pcdir.resolve().is_relative_to(prefix.resolve()):
    raise SystemExit('pkg-config directory points outside the Full prefix')
def field(text, name, value):
    pattern = r'^' + re.escape(name) + r':.*$'
    return re.sub(pattern, name + ': ' + value, text, flags=re.M) if re.search(pattern, text, re.M) else text.rstrip('\n') + '\n' + name + ': ' + value + '\n'
for path in sorted(pcdir.glob('*.pc')):
    if not path.is_file():
        continue
    if path.is_symlink() and not path.resolve().is_relative_to(prefix.resolve()):
        raise SystemExit('pkg-config file points outside the Full prefix: ' + str(path))
    old = path.read_text()
    text = old.replace('-l-lpthread', '-lpthread').replace('-l-pthread', '-lpthread')
    if path.name in {'srt.pc', 'haisrt.pc'}:
        for name in ('mbedtls', 'mbedcrypto', 'mbedx509'):
            text = text.replace(str(prefix / ('lib/lib' + name + '.a')), '-l' + name)
    if path.name == 'mbedcrypto.pc':
        text = field(text, 'Libs.private', '-lbcrypt')
    if path.name == 'libchromaprint.pc' and 'CHROMAPRINT_NODLL' not in text:
        text = re.sub(r'^(Cflags:.*)$', r'\1 -DCHROMAPRINT_NODLL', text, flags=re.M)
    if path.name == 'libssh.pc':
        if 'LIBSSH_STATIC' not in text:
            text = re.sub(r'^(Cflags:.*)$', r'\1 -DLIBSSH_STATIC', text, flags=re.M)
        text = field(text, 'Requires.private', 'mbedcrypto zlib')
        text = field(text, 'Libs.private', '-lpthread -liphlpapi -lws2_32 -Wl,--enable-stdcall-fixup')
    if path.name == 'libzmq.pc':
        if 'ZMQ_STATIC' not in text:
            text = re.sub(r'^(Cflags:.*)$', r'\1 -DZMQ_STATIC', text, flags=re.M)
        text = field(text, 'Libs.private', '-lstdc++ -lpthread -lws2_32 -lrpcrt4 -liphlpapi')
    if text != old:
        path.write_text(text)
PYNORMALIZEPC
}

full_stage_dependencies() {
  case "$1" in
    libpng) printf '%s\n' zlib ;;
    libxml2) printf '%s\n' zlib ;;
    libssh) printf '%s\n' mbedtls zlib ;;
    libmysofa) printf '%s\n' zlib ;;
    libdvdnav) printf '%s\n' libdvdread ;;
    libsrt|librist) printf '%s\n' mbedtls ;;
    libbluray) printf '%s\n' libxml2 freetype ;;
    harfbuzz) printf '%s\n' freetype ;;
    fontconfig) printf '%s\n' freetype expat libiconv ;;
    libass) printf '%s\n' freetype harfbuzz fribidi fontconfig ;;
    libjxl) printf '%s\n' brotli ;;
    libplacebo) printf '%s\n' libshaderc vulkan-headers lcms2 ;;
    vmaf) printf '%s\n' zimg ;;
    ffmpeg)
      local dep
      for dep in "${STAGES[@]}"; do [[ "$dep" == ffmpeg ]] || printf '%s\n' "$dep"; done ;;
  esac
  return 0
}

full_stage_outputs() (
  # Essential interfaces plus every recorded CMake/Meson installed file. Do not
  # claim unrelated prefix contents or user files in the delivery directory.
  local name="$1" lib="" pc="" header="" path log
  local -a outputs=() optional=()
  shopt -s nullglob
  case "$name" in
    nv-codec-headers) header=ffnvcodec; pc=ffnvcodec ;;
    zlib) lib=z; pc=zlib; header=zlib.h; outputs+=("$PREFIX/include/zconf.h") ;;
    bzip2) lib=bz2; header=bzlib.h ;;
    lzma) lib=lzma; pc=liblzma; header=lzma.h; outputs+=("$PREFIX/include/lzma") ;;
    libiconv) lib=iconv; header=iconv.h; optional+=("$PREFIX/lib/libcharset.a" "$PREFIX/include/libcharset.h" "$PREFIX/include/localcharset.h") ;;
    libpng) lib=png16; pc=libpng; header=libpng16; optional+=("$PREFIX/lib/libpng.a" "$PREFIX/lib/pkgconfig/libpng16.pc" "$PREFIX/include/png.h" "$PREFIX/include/pngconf.h" "$PREFIX/include/pnglibconf.h") ;;
    libxml2) lib=xml2; pc=libxml-2.0; header=libxml2 ;;
    libmp3lame) lib=mp3lame; header=lame ;;
    libsoxr) lib=soxr; pc=soxr; header=soxr.h; optional+=("$PREFIX/lib/libsoxr-lsr.a" "$PREFIX/include/soxr-lsr.h") ;;
    libaom) lib=aom; pc=aom; header=aom ;;
    libvpx) lib=vpx; pc=vpx; header=vpx ;;
    libopenjpeg) lib=openjp2; pc=libopenjp2; optional+=("$PREFIX/include/"openjpeg-*) ;;
    mbedtls) lib=mbedtls; pc=mbedtls; header=mbedtls; outputs+=("$PREFIX/lib/libmbedx509.a" "$PREFIX/lib/libmbedcrypto.a" "$PREFIX/lib/pkgconfig/mbedcrypto.pc" "$PREFIX/lib/pkgconfig/mbedx509.pc" "$PREFIX/include/psa") ;;
    libssh) lib=ssh; pc=libssh; header=libssh ;;
    libsnappy) lib=snappy; header=snappy.h; optional+=("$PREFIX/include/"snappy*.h) ;;
    libmysofa) lib=mysofa; pc=libmysofa; header=mysofa.h; optional+=("$PREFIX/include/mysofa_export.h") ;;
    libdvdread) lib=dvdread; pc=dvdread; header=dvdread ;;
    libdvdnav) lib=dvdnav; pc=dvdnav; header=dvdnav ;;
    chromaprint) lib=chromaprint; pc=libchromaprint; header=chromaprint.h ;;
    libzmq) lib=zmq; pc=libzmq; header=zmq.h; optional+=("$PREFIX/include/zmq_utils.h") ;;
    libsrt) lib=srt; pc=srt; header=srt; optional+=("$PREFIX/lib/pkgconfig/haisrt.pc") ;;
    librist) lib=rist; pc=librist; header=librist ;;
    libbluray) lib=bluray; pc=libbluray; header=libbluray ;;
    lcms2) lib=lcms2; pc=lcms2; header=lcms2.h; outputs+=("$PREFIX/include/lcms2_plugin.h") ;;
    librubberband) lib=rubberband; pc=rubberband; header=rubberband ;;
    libvidstab) lib=vidstab; pc=vidstab; header=vid.stab ;;
    libshaderc) lib=shaderc_combined; pc=shaderc; header=shaderc; outputs+=("$PREFIX/include/spirv"); optional+=("$PREFIX/lib/"libshaderc* "$PREFIX/lib/"libSPIRV*.a "$PREFIX/lib/"libglslang*.a "$PREFIX/lib/pkgconfig/"shaderc*.pc "$PREFIX/include/glslang" "$PREFIX/include/spirv-tools") ;;
    vulkan-headers) header=vulkan; pc=vulkan; outputs+=("$PREFIX/include/vk_video"); optional+=("$PREFIX/lib/"libvulkan*.a) ;;
    libplacebo) lib=placebo; pc=libplacebo; header=libplacebo ;;
    opus) lib=opus; pc=opus; header=opus ;;
    zimg) lib=zimg; pc=zimg; header=zimg.h; optional+=("$PREFIX/include/zimg++.hpp") ;;
    freetype) lib=freetype; pc=freetype2; header=freetype2 ;;
    harfbuzz) lib=harfbuzz; pc=harfbuzz; header=harfbuzz; optional+=("$PREFIX/lib/"libharfbuzz*.a "$PREFIX/lib/pkgconfig/"harfbuzz*.pc) ;;
    fribidi) lib=fribidi; pc=fribidi; header=fribidi ;;
    expat) lib=expat; pc=expat; header=expat.h; optional+=("$PREFIX/include/"expat*.h) ;;
    fontconfig) lib=fontconfig; pc=fontconfig; header=fontconfig ;;
    libass) lib=ass; pc=libass; header=ass ;;
    libwebp) lib=webp; pc=libwebp; header=webp; optional+=("$PREFIX/lib/"libwebp*.a "$PREFIX/lib/"libsharpyuv.a "$PREFIX/lib/pkgconfig/"libwebp*.pc "$PREFIX/lib/pkgconfig/libsharpyuv.pc") ;;
    brotli) lib=brotlidec; pc=libbrotlidec; header=brotli; outputs+=("$PREFIX/lib/libbrotlicommon.a" "$PREFIX/lib/pkgconfig/libbrotlicommon.pc") ;;
    libjxl) lib=jxl; pc=libjxl; header=jxl; outputs+=("$PREFIX/lib/libjxl_threads.a" "$PREFIX/lib/pkgconfig/libjxl_threads.pc"); optional+=("$PREFIX/lib/"libjxl*.a "$PREFIX/lib/libhwy.a" "$PREFIX/include/hwy" "$PREFIX/lib/pkgconfig/"libjxl*.pc "$PREFIX/lib/pkgconfig/libhwy.pc") ;;
    dav1d) lib=dav1d; pc=dav1d; header=dav1d ;;
    svtav1) lib=SvtAv1Enc; pc=SvtAv1Enc; header=svt-av1 ;;
    libvpl) lib=vpl; pc=vpl; header=vpl ;;
    x264) lib=x264; pc=x264; header=x264.h; outputs+=("$PREFIX/include/x264_config.h") ;;
    x265) lib=x265; pc=x265; header=x265.h; outputs+=("$PREFIX/include/x265_config.h") ;;
    vmaf) lib=vmaf; pc=libvmaf; header=libvmaf ;;
    sdl2) lib=SDL2; pc=sdl2; header=SDL2; outputs+=("$PREFIX/lib/libSDL2main.a") ;;
    amf) header=AMF ;;
    avisynth) header=avisynth ;;
    ffmpeg)
      python3 -I - "$ROOT/full" <<'PYFULLOUTPUTS'
import hashlib
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
manifest = root / '.ffbuild-artifacts.json'
if manifest.is_symlink():
    raise SystemExit('Full artifact manifest must not be a symlink')
value = json.loads(manifest.read_text())
if value.get('schema') != 1 or value.get('variant') != 'full' or not value.get('artifacts'):
    raise SystemExit('invalid Full artifact manifest')
required = {'ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe'}
seen = set()
for item in value['artifacts']:
    name = item['path']
    if not re.fullmatch(r'[A-Za-z0-9_.+-]+\.(?:exe|dll)', name, re.I) or name in seen:
        raise SystemExit('unsafe or duplicate Full artifact name')
    seen.add(name)
    path = root / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        raise SystemExit('missing Full artifact: ' + name)
    if path.stat().st_size != item['size'] or hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
        raise SystemExit('changed Full artifact: ' + name)
    sys.stdout.buffer.write(str(path).encode() + b'\0')
if not required.issubset(seen):
    raise SystemExit('Full manifest omits an executable')
sys.stdout.buffer.write(str(manifest).encode() + b'\0')
PYFULLOUTPUTS
      outputs+=("$PREFIX/bin/ffmpeg.exe" "$PREFIX/bin/ffprobe.exe" "$PREFIX/bin/ffplay.exe")
      optional+=("$PREFIX/bin/"{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale}-*.dll
        "$PREFIX/lib/"lib{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale}.dll.a
        "$PREFIX/include/"lib{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale}
        "$PREFIX/lib/pkgconfig/"lib{avcodec,avdevice,avfilter,avformat,avutil,swresample,swscale}.pc) ;;
    *) echo "No verified output contract for Full stage: $name" >&2; exit 1 ;;
  esac
  [[ -z "$lib" ]] || outputs+=("$PREFIX/lib/lib$lib.a")
  [[ -z "$pc" ]] || outputs+=("$PREFIX/lib/pkgconfig/$pc.pc")
  [[ -z "$header" ]] || outputs+=("$PREFIX/include/$header")
  for path in "${optional[@]}"; do [[ ! -e "$path" && ! -L "$path" ]] || outputs+=("$path"); done
  printf '%s\0' "${outputs[@]}"
  log="$BUILDROOT/.full-cache/directories/$name.list"
  if [[ -f "$log" ]]; then
    python3 -I - "$PREFIX" "$log" <<'PYINSTALLEDOUTPUTS'
import json
from pathlib import Path
import sys
prefix, log = map(Path, sys.argv[1:])
paths = set()
for name in log.read_text().splitlines():
    build = Path(name)
    cmake = build / 'install_manifest.txt'
    meson = build / 'meson-info/intro-installed.json'
    if cmake.is_file():
        paths.update(cmake.read_text().splitlines())
    if meson.is_file():
        value = json.loads(meson.read_text())
        for item in value.values():
            paths.update(item if isinstance(item, list) else [item])
for name in sorted(paths):
    path = Path(name)
    if not path.is_absolute() or not path.is_relative_to(prefix):
        raise SystemExit('install manifest escapes the prefix: ' + name)
    if path.is_file() and path.stat().st_size > 0:
        sys.stdout.buffer.write(str(path).encode() + b'\0')
PYINSTALLEDOUTPUTS
  fi
)

full_refresh_dependency_identity() {
  local dep="$1" list="$BUILDROOT/.full-cache/outputs/$1.list"
  local -a outputs=()
  mkdir -p "$(dirname "$list")"
  full_stage_outputs "$dep" > "$list" || return 1
  mapfile -d '' -t outputs < "$list"
  FULL_STAGE_IDENTITIES[$dep]="$(ffbuild_cache_tree_key "$BUILDROOT/.full-cache/success/$dep.json" "${outputs[@]}")" || return 1
}

full_source_recipe() {
  local stage="$1"
  local name="$stage"
  CURRENT_STAGE="$stage"
  is_known_stage "$stage" || { echo "未知编译阶段: $stage" >&2; return 1; }
  local _ffbuild_recipe_file="$FULL_RECIPES_DIR/$stage.sh"
  [[ -f "$_ffbuild_recipe_file" ]] || { echo "缺少构建配方: $_ffbuild_recipe_file" >&2; return 1; }
  # Keep positional arguments, `local`, `return`, and errexit in a normal
  # function scope. Never source a recipe as an if/&&/|| condition.
  source "$_ffbuild_recipe_file"
}

full_stage_external_key() {
  case "$1" in
    vmaf|brotli|libjxl) ffbuild_cache_tree_key "$SCRIPT_DIR/../lib/feature_policy.py" ;;
    libiconv)
      local source version
      source="$(ffbuild_source_dir libiconv)" || return 1
      version="$(normalize_version libiconv "$(git -C "$source" describe --tags --exact-match)")" || return 1
      [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
      ffbuild_cache_tree_key "$ROOT/toolchains/source-archives/libiconv-$version.tar.gz" "$BUILDROOT/_archive-src"
      ;;
    *) ffbuild_cache_hash no-external-inputs ;;
  esac
}

full_run_stage_locked() {
  local name="$1" repo="$1" source source_key source_compat dep dependency_key input_key record prepared_key=untrusted prepared_stage stage_trusted=0 external_key
  CURRENT_STAGE="$name"
  echo "===> $name"
  is_known_stage "$name" || { echo "未知编译阶段: $name" >&2; return 1; }
  local _ffbuild_recipe_file="$FULL_RECIPES_DIR/$name.sh"
  [[ -f "$_ffbuild_recipe_file" ]] || { echo "缺少构建配方: $_ffbuild_recipe_file" >&2; return 1; }
  [[ "$name" != ffmpeg ]] || repo=ffmpeg-source
  source="$(ffbuild_source_dir "$repo")" || return 1
  full_normalize_pkgconfig || return 1
  if [[ -z "$FULL_CACHE_TOOLCHAIN_KEY" ]]; then FULL_CACHE_TOOLCHAIN_KEY="$(ffbuild_cache_toolchain_key)" || return 1; fi
  if [[ -z "$FULL_CACHE_DRIVER_KEY" ]]; then
    FULL_CACHE_DRIVER_KEY="$(ffbuild_cache_tree_key "$SCRIPT_DIR/full.sh" "$SCRIPT_DIR/../lib/build-cache.sh" "$SCRIPT_DIR/../lib/workspace.sh")" || return 1
  fi
  local -a dependencies=() extra=()
  mapfile -t dependencies < <(full_stage_dependencies "$name")
  local -a dependency_keys=()
  for dep in "${dependencies[@]}"; do
    if [[ ! -v "FULL_STAGE_IDENTITIES[$dep]" ]]; then full_refresh_dependency_identity "$dep" || return 1; fi
    dependency_keys+=("$dep=${FULL_STAGE_IDENTITIES[$dep]}")
  done
  dependency_key="$(ffbuild_cache_hash "${dependency_keys[@]}")" || return 1
  [[ "$name" != libshaderc ]] || extra=("${FULL_SHADERC_DEP_DIRS[@]}")
  source_key="$(ffbuild_cache_source_key "$source" "${extra[@]}")" || return 1
  source_compat="$(ffbuild_cache_source_compat_key "$source" "${extra[@]}")" || return 1
  local patches=none host_key=none
  if [[ "$name" == ffmpeg ]]; then
    ensure_host_glslc
    patches="$(ffbuild_cache_tree_key "$ROOT/shared-patches" "$SCRIPT_DIR/../lib/feature_policy.py")" || return 1
    host_key="$(ffbuild_cache_tree_key "$HOST_TOOLS/.full-glslc-cache.json" "$HOST_TOOLS/bin/glslc")" || return 1
  fi
  FULL_STAGE_COMPAT_KEY="$(ffbuild_cache_hash full-stage-v3 "$name" "$TARGET" "$PREFIX" "$BUILDROOT" \
    "$FULL_CACHE_TOOLCHAIN_KEY" "$FULL_CACHE_DRIVER_KEY" "$dependency_key" "$source_compat" "$patches" "$host_key" \
    "$(ffbuild_cache_tree_key "$_ffbuild_recipe_file" "$BUILDROOT/mingw-cross.txt")")" || return 1
  FULL_STAGE_REPO="$repo"
  external_key="$(full_stage_external_key "$name")" || return 1
  if ffbuild_cache_stage_valid "$BUILDROOT/_src/$repo" 2>/dev/null; then
    prepared_stage="$(ffbuild_cache_stage_path "$BUILDROOT/_src/$repo")" || return 1
    prepared_key="$(ffbuild_cache_source_key "$prepared_stage" "${extra[@]}")" || return 1
    stage_trusted=1
  fi
  input_key="$(ffbuild_cache_hash "$FULL_STAGE_COMPAT_KEY" "$source_key" "$prepared_key" "$external_key")" || return 1
  record="$BUILDROOT/.full-cache/success/$name.json"
  if [[ "$INCREMENTAL_BUILD" == 1 && "$stage_trusted" == 1 ]] && ffbuild_cache_hit "$record" "$input_key"; then
    if [[ "$name" != libshaderc ]] || ffbuild_cache_shaderc_deps_key "$(ffbuild_cache_stage_path "$BUILDROOT/_src/$repo")" >/dev/null 2>&1; then
      echo "缓存命中 $name：输入和所有已登记安装产物内容一致，跳过编译"
      full_refresh_dependency_identity "$name" || return 1
      return 0
    fi
  fi
  FULL_STAGE_DIRECTORY_LOG="$BUILDROOT/.full-cache/directories/$name.list"
  mkdir -p "$(dirname "$FULL_STAGE_DIRECTORY_LOG")" "$(dirname "$record")"
  : > "$FULL_STAGE_DIRECTORY_LOG"
  # A failed configure/build/install/check never reaches stage/cache commit.
  full_source_recipe "$name"
  full_normalize_pkgconfig
  local list="$BUILDROOT/.full-cache/outputs/$name.list"
  local -a outputs=()
  mkdir -p "$(dirname "$list")"
  full_stage_outputs "$name" > "$list"
  mapfile -d '' -t outputs < "$list"
  prepared_stage="$(ffbuild_cache_stage_path "$BUILDROOT/_src/$repo")"
  prepared_key="$(ffbuild_cache_source_key "$prepared_stage" "${extra[@]}")"
  external_key="$(full_stage_external_key "$name")"
  input_key="$(ffbuild_cache_hash "$FULL_STAGE_COMPAT_KEY" "$source_key" "$prepared_key" "$external_key")"
  local pending
  pending="$(mktemp "$(dirname "$record")/.$name.success-XXXXXXXX")"
  ffbuild_cache_commit "$pending" "$input_key" "${outputs[@]}"
  ffbuild_cache_stage_commit "$BUILDROOT/_src/$repo" >/dev/null
  ffbuild_cache__python record-metadata "$pending" namespace full source_repo "$repo" stage "$prepared_stage" \
    commit "$(git -C "$prepared_stage" rev-parse --verify 'HEAD^{commit}')" source_key "$prepared_key"
  mv -f -- "$pending" "$record"
  full_refresh_dependency_identity "$name"
}

full_verified_stage_source() {
  local name="${1:?stage name required}" repo="$1"
  is_known_stage "$name" || return 1
  [[ "$name" != ffmpeg ]] || repo=ffmpeg-source
  ffbuild_cache__python successful-stage "$BUILDROOT/.full-cache/success/$name.json" "$BUILDROOT/_src/$repo" full
}

full_run_stage_entry_locked() {
  FULL_BUILD_LOCK_HELD=1
  full_initialize_profile || return 1
  full_run_stage_locked "$@"
}

run_stage() {
  if [[ "${FULL_BUILD_LOCK_HELD:-0}" == 1 ]]; then
    full_run_stage_locked "$@"
  else
    full_validate_roots || return 1
    ffbuild_cache_lock "$BUILDROOT/.ffbuild-build.lock" \
      ffbuild_cache_lock "$PREFIX/.ffbuild-build.lock" full_run_stage_entry_locked "$@"
  fi
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
  local stage repo source ffmpeg_source_stage
  ffmpeg_source_stage="$(ffbuild_cache_stage_path "$BUILDROOT/_src/ffmpeg-source" 2>/dev/null || ffbuild_source_dir ffmpeg-source)"
  for stage in "$@"; do
    if [[ "$stage" == "ffmpeg" ]]; then repo="ffmpeg-source"; else repo="$stage"; fi
    source="$(ffbuild_cache_stage_path "$BUILDROOT/_src/$repo" 2>/dev/null || ffbuild_source_dir "$repo")"
    if [[ ! -d "$source/.git" && ! -f "$source/.git" ]]; then source="$(ffbuild_source_dir "$repo")"; fi
    repo_args+=(--source-repo "$repo=$source" --built-stage "$stage")
  done

  manifest_args+=(--validate "Requested Full build scope completed: ${BUILT_STAGES[*]}")
  manifest_args+=(--skip "Non-upstream FFmpeg feature patches are not applied; only build/link compatibility patches are retained")
  manifest_args+=(--validate "Native AVS1 decoders included; external AVS2/3 codecs and AVS encoders remain disabled; Audio Vivid/AV3A is unavailable")
  manifest_args+=(--validate "FFmpeg mainline HEVC decoding includes ITU-T T.35 HDR Vivid frame metadata parsing; HDR Vivid generation/encoding is unavailable")
  if [[ "$ffmpeg_built" == "1" ]]; then
    manifest_args+=(--validate "FFmpeg stage configured, linked, and its runtime DLL closure was checked")
  else
    manifest_args+=(--skip "FFmpeg was not relinked; packaged executable/DLL hashes describe the pre-existing Full package, not this library-only build")
  fi
  if [[ "$ffmpeg_built" == "1" ]]; then
    manifest_args+=(--validate "Dolby Vision P8/P10 decoders, software encoders, RPU filter, and MOV/Matroska muxers passed runtime capability checks")
  fi
  manifest_args+=(
    --skip "No representative Dolby Vision Profile 8/10 media was available for a decode/encode/remux round-trip test"
    --skip "MPEG-TS Dolby Vision metadata descriptor output is not implemented; demux and decode input support remains enabled"
    --skip "P7 FEL reconstruction is not integrated or validated against a trusted reference; no FEL sample/reference or reconstructor is available"
    --skip "Audio Vivid/AV3A integration is unavailable; external AVS2/3 decoders and AVS encoders remain excluded"
    --skip "Audio Vivid decoder-only integration is unavailable: UWA AV3A source, FFmpeg demux/decode patch, model.bin, and usage/distribution authorization are absent; AV3A encoding is out of scope"
    --skip "av1_qsv HDR10+ metadata injection is not implemented; QSV dynamic-metadata paths are not runtime-verified"
  )
  if is_in_array x265 "$@"; then
    manifest_args+=(--validate "libx265 Main10 build used ENABLE_HDR10_PLUS=ON")
  fi
  python3 -I "$ROOT/build-manifests/write_manifest.py" \
    --root "$ROOT" \
    "${repo_args[@]}" \
    --build-name full \
    --build-mode "$build_mode" \
    --toolchain-flavor "$TOOLCHAIN_FLAVOR" \
    --incremental-build "$INCREMENTAL_BUILD" \
    --ffmpeg-built "$ffmpeg_built" \
    --prefix "$PREFIX" \
    --artifact-dir "$ROOT/full" \
    --configure-file "$ffmpeg_source_stage/ffbuild/config.log" \
    --config-mak "$ffmpeg_source_stage/ffbuild/config.mak" \
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

full_validate_roots() {
  local path build_path prefix_path
  build_path="$(realpath -m -- "$BUILDROOT")" || return 1
  prefix_path="$(realpath -m -- "$PREFIX")" || return 1
  if ffbuild__paths_overlap "$build_path" "$prefix_path"; then
    echo 'Full BUILDROOT and PREFIX must be separate non-overlapping directories' >&2
    return 1
  fi
  for path in "$BUILDROOT" "$PREFIX" "$BUILDROOT/.full-cache" "$BUILDROOT/.full-cache/success" \
    "$BUILDROOT/.full-cache/directories" "$BUILDROOT/.full-cache/outputs" \
    "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin"; do
    ffbuild_assert_generated_directory "$path" || return 1
  done
}

full_initialize_profile() {
  full_validate_roots || return 1
  local path marker resolved forbidden
  for path in "$BUILDROOT" "$PREFIX"; do
    ffbuild_assert_generated_directory "$path" || return 1
    resolved="$(realpath -m -- "$path")" || return 1
    for forbidden in "$ROOT/build_nvenc" "$ROOT/build_qsv" "$ROOT/bin_nvenc" "$ROOT/bin_qsv"; do
      [[ "$resolved" != "$(realpath -m -- "$forbidden")" ]] || {
        echo "Full cannot use a Lite build/prefix directory: $path" >&2
        return 1
      }
    done
    marker="$path/.ffbuild-profile"
    if [[ -L "$marker" || ( -f "$marker" && "$(<"$marker")" != full ) ]]; then
      echo "Build/prefix belongs to another target; refusing cross-profile reuse: $path" >&2
      return 1
    fi
  done
  # Prevalidate both roots before creating either ownership marker.
  for path in "$BUILDROOT" "$PREFIX"; do
    mkdir -p "$path" || return 1
    if [[ ! -e "$path/.ffbuild-profile" ]]; then printf '%s\n' full > "$path/.ffbuild-profile" || return 1; fi
  done
}

run_build() {
  parse_build_args "$@" || return 2
  full_validate_roots || return 2
  ffbuild_cache_lock "$BUILDROOT/.ffbuild-build.lock" \
    ffbuild_cache_lock "$PREFIX/.ffbuild-build.lock" full_run_build_locked "$@"
}

full_run_build_locked() {
  FULL_BUILD_LOCK_HELD=1
  parse_build_args "$@" || exit 2
  full_initialize_profile || return 1
  FULL_STAGE_IDENTITIES=()
  FULL_CACHE_TOOLCHAIN_KEY=""
  FULL_CACHE_DRIVER_KEY=""
  ffbuild_assert_generated_directory "$BUILDROOT" || exit 2
  ffbuild_assert_generated_directory "$PREFIX" || exit 2
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
    echo "保留现有 PREFIX；仅重新构建输入变化或安装产物未通过内容校验的阶段。"
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
  local path
  local -a roots=("$BUILDROOT" "$PREFIX" "$ROOT/_bundle")
  # Validate the entire operation before removing anything.
  for path in "${roots[@]}"; do
    ffbuild_assert_generated_directory "$path" || return 1
  done
  echo "===> [子命令: clean] 清理 Full 生成的构建缓存和依赖前缀..."
  ffbuild_remove_generated_tree "$BUILDROOT"
  for path in "$PREFIX/include" "$PREFIX/lib" "$PREFIX/share" "$PREFIX/bin" "$ROOT/_bundle"; do
    ffbuild_remove_generated_tree "$path"
  done
  echo "清理完毕；持久源码、补丁、归档、清单和其他配置产物均保留。"
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
  clean           仅清理 Full 构建缓存、依赖前缀和 _bundle；保留源码、补丁、清单与其他配置

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
