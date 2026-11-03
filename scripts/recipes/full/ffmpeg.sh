#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      # Run the same idempotent normalization used before Full cache lookups.
      full_normalize_pkgconfig

      local ff_stage
      ff_stage="$(stage_src "ffmpeg-source")"
      "$ROOT/shared-patches/apply-ffmpeg-patches.sh" "$ff_stage" full
      python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" amf "$ff_stage" || return 1
      python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" ffmpeg-source "$ff_stage" || return 1
      python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" x264 "$ff_stage" || return 1
      # Keep the Full-only color opt-in independent of Lite cache identities.
      python3 -I - "$ff_stage/libavfilter/vf_libvmaf.c" <<'PYVMAFCOLORNEGOTIATION'
import os
from pathlib import Path
import stat
import sys
import tempfile

path = Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    raise SystemExit("Full VMAF negotiation patch requires a regular staged source file")
before = path.read_bytes()
source = before.decode("utf-8")
edits = [
    (
        "    unsigned bpc;\n#if CONFIG_LIBVMAF_CUDA_FILTER\n",
        "    unsigned bpc;\n    int independent_color;\n#if CONFIG_LIBVMAF_CUDA_FILTER\n",
    ),
    (
        '    {"feature",  "Set the feature to be used for computing vmaf.",                      OFFSET(feature_cfg), AV_OPT_TYPE_STRING, {.str=NULL}, 0, 1, FLAGS},\n    { NULL }\n',
        '    {"feature",  "Set the feature to be used for computing vmaf.",                      OFFSET(feature_cfg), AV_OPT_TYPE_STRING, {.str=NULL}, 0, 1, FLAGS},\n'
        '    {"independent_color", "Preserve independent source color metadata (CPU only).", OFFSET(independent_color), AV_OPT_TYPE_BOOL, {.i64=0}, 0, 1, FLAGS},\n'
        '    { NULL }\n',
    ),
    (
        "    AV_PIX_FMT_YUV444P16LE, AV_PIX_FMT_YUV422P16LE, AV_PIX_FMT_YUV420P16LE,\n"
        "    AV_PIX_FMT_NONE\n};\n\nstatic int config_input_ref(AVFilterLink *inlink)\n",
        "    AV_PIX_FMT_YUV444P16LE, AV_PIX_FMT_YUV422P16LE, AV_PIX_FMT_YUV420P16LE,\n"
        "    AV_PIX_FMT_NONE\n};\n\n"
        "static int query_formats(const AVFilterContext *ctx,\n"
        "                         AVFilterFormatsConfig **cfg_in,\n"
        "                         AVFilterFormatsConfig **cfg_out)\n"
        "{\n"
        "    const LIBVMAFContext *s = ctx->priv;\n"
        "    int ret;\n\n"
        "    ret = ff_set_pixel_formats_from_list2(ctx, cfg_in, cfg_out, pix_fmts);\n"
        "    if (ret < 0 || !s->independent_color)\n"
        "        return ret;\n\n"
        "    /* Default filling keeps only main and output color lists linked. */\n"
        "    ret = ff_formats_ref(ff_all_color_spaces(), &cfg_in[1]->color_spaces);\n"
        "    if (ret < 0)\n"
        "        return ret;\n"
        "    return ff_formats_ref(ff_all_color_ranges(), &cfg_in[1]->color_ranges);\n"
        "}\n\n"
        "static int config_input_ref(AVFilterLink *inlink)\n",
    ),
    (
        "    FILTER_INPUTS(libvmaf_inputs),\n    FILTER_OUTPUTS(libvmaf_outputs),\n    FILTER_PIXFMTS_ARRAY(pix_fmts),\n",
        "    FILTER_INPUTS(libvmaf_inputs),\n    FILTER_OUTPUTS(libvmaf_outputs),\n    FILTER_QUERY_FUNC2(query_formats),\n",
    ),
    (
        "static av_cold int init_cuda(AVFilterContext *ctx)\n{\n    LIBVMAFContext *s = ctx->priv;\n    s->fs.on_event = do_vmaf_cuda;\n    return 0;\n}\n",
        "static av_cold int init_cuda(AVFilterContext *ctx)\n{\n    LIBVMAFContext *s = ctx->priv;\n"
        "    if (s->independent_color) {\n"
        "        av_log(ctx, AV_LOG_ERROR,\n"
        '               "independent_color is supported only by CPU libvmaf.\\n");\n'
        "        return AVERROR(EINVAL);\n"
        "    }\n"
        "    s->fs.on_event = do_vmaf_cuda;\n    return 0;\n}\n",
    ),
]
original = all(source.count(old) == 1 and source.count(new) == 0 for old, new in edits)
patched = all(source.count(new) == 1 and source.count(old) == 0 for old, new in edits)
if not (original or patched):
    raise SystemExit("Full VMAF negotiation patch: unknown, partial or changed source; left unchanged")
base = source
if patched:
    for old, new in reversed(edits):
        base = base.replace(new, old, 1)
# Reject extra/tampered option or query fragments, even next to valid hunks.
if any(token in base for token in ("independent_color", "query_formats", "FILTER_QUERY_FUNC2")):
    raise SystemExit("Full VMAF negotiation patch: unexpected negotiation code; left unchanged")
if patched:
    print("Full VMAF independent-color negotiation patch is verified")
else:
    result = source
    for old, new in edits:
        result = result.replace(old, new, 1)
    snapshot = path.stat()
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".vf_libvmaf-color-", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), stat.S_IMODE(snapshot.st_mode))
            stream.write(result.encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        current = path.stat()
        if path.is_symlink() or (current.st_dev, current.st_ino) != (snapshot.st_dev, snapshot.st_ino) or path.read_bytes() != before:
            raise SystemExit("Full VMAF negotiation source changed during preflight; left unchanged")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Applied Full CPU VMAF independent-color negotiation patch")
PYVMAFCOLORNEGOTIATION
      patch_ffmpeg_libplacebo_vulkan_import "$ff_stage"
      patch_ffmpeg_cxx_runtime "$ff_stage"
      pushd "$ff_stage" >/dev/null
      # The Full cache wrapper selects a new staged tree when dependency,
      # toolchain or patch compatibility changes. Source-only compatible
      # updates keep configure's unchanged output and make's object cache.

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
      [[ -f "$PREFIX/include/libvmaf/picture.h" ]] &&
        grep -Fq 'VmafColor color;' "$PREFIX/include/libvmaf/picture.h" || {
          echo "Full HDR-VMAF requires rebuilding the vmaf stage with the upstream color API and zimg" >&2
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
        libssh theoraenc libmysofa dvdread dvdnav libchromaprint libzmq; do
        PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists "$required_pc" || {
          echo "缺少 pkg-config 依赖: $required_pc"
          exit 1
        }
      done
      [[ -f "$PREFIX/lib/libsnappy.a" || -f "$PREFIX/lib/libsnappy_static.a" ]] || {
        echo "缺少静态 libsnappy"
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

      local extra_cflags="-I$PREFIX/include"
      local extra_ldflags="-L$PREFIX/lib $LDFLAGS"
      # Subtitle character conversion must not rely on removed codecs pulling iconv in.
      local extra_libs="$TOOLCHAIN_EXTRA_LIBS -lvulkan-1 -liconv"
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

      local policy_flags_text
      policy_flags_text="$(python3 -I "$SCRIPT_DIR/../lib/feature_policy.py" ffmpeg-flags "$ff_stage")" || return 1
      local -a policy_flags=()
      mapfile -t policy_flags <<< "$policy_flags_text"
      ensure_host_glslc
      local host_glslc="$HOST_TOOLS/bin/glslc"
      [[ -x "$host_glslc" ]] || { echo "缺少 WSL 原生 glslc，请先编译 libshaderc 阶段" >&2; exit 1; }
      # 使用原生 C++ 链接驱动，保留 C++ 运行时与现有链接保护参数。

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
        --disable-cuvid \
        --disable-decoder=libdavs2 \
        --disable-decoder=libuavs3d \
        --disable-encoder=libxavs \
        --disable-encoder=libxavs2 \
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
        --enable-vulkan \
        --enable-vulkan-static \
        --glslc="$host_glslc" \
        --enable-libplacebo \
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
        --enable-lcms2 \
        --enable-librubberband \
        --enable-libvidstab \
        --enable-libssh \
        --enable-libsnappy \
        --enable-libtheora \
        --enable-libmysofa \
        --enable-libdvdread \
        --enable-libdvdnav \
        --enable-chromaprint \
        --enable-libzmq \
        --enable-iconv \
        "${lto_flags[@]}" \
        "${cuda_flags[@]}" \
        "${policy_flags[@]}" \
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
        --enable-encoder=libvpx_vp8 \
        --enable-encoder=libvpx_vp9 \
        --enable-encoder=aac

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

      # Assemble only the newly installed executables and their runtime DLL
      # closure. Never scan/delete old full/ binaries or user plugins. Failed
      # validation leaves both the old distribution and this candidate intact.
      local payload_root payload executable
      payload_root="$(mktemp -d "$BUILDROOT/.full-output.XXXXXXXX")"
      payload="$payload_root/full"
      mkdir "$payload"
      for executable in ffmpeg.exe ffprobe.exe ffplay.exe; do
        [[ -f "$PREFIX/bin/$executable" && ! -L "$PREFIX/bin/$executable" ]] || {
          echo "Missing installed Full executable: $executable" >&2
          exit 1
        }
        cp -p "$PREFIX/bin/$executable" "$payload/$executable"
        "$STRIP" "$payload/$executable" || true
      done
      copy_runtime_dll_closure "$payload"
      verify_encoder_bitdepths "$payload/ffmpeg.exe"
      verify_dolby_vision_support "$payload/ffmpeg.exe"
      verify_vmaf "$payload/ffmpeg.exe"

      # Install known payload files (optional backups), then atomically publish the
      # exact successful artifact allowlist. Publishing must use this manifest,
      # not glob the preserved user/old files in full/. No HDR runtime success
      # is implied: the explicit tests/windows/validate-hdr-vmaf.py is separate.
      # Obtain the VMAF tree associated with verified successful installed
      # outputs. Never create/restage a dependency here or label old binaries
      # with a canonical HEAD that may have advanced since their build.
      local vmaf_stage
      vmaf_stage="$(full_verified_stage_source vmaf)" || {
        echo "Cannot certify the installed VMAF source; rebuild the Full vmaf stage first" >&2
        exit 1
      }
      python3 -I - "$payload" "$ROOT/full" "$ROOT/logs/full-output-backups" "$ff_stage" "$vmaf_stage" <<'PYFULLINSTALL'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

payload, output, backup_root, ffmpeg_source, vmaf_source = map(Path, sys.argv[1:])


def source_commit(source, label):
    # Do not let Git discover an unrelated parent repository when staged
    # metadata is missing, or certify a caller-supplied abbreviated hash.
    if source.is_symlink() or not source.is_dir() or not (source / ".git").exists():
        raise SystemExit(f"Cannot read {label} staged Git commit: {source}")
    try:
        top = subprocess.run(["git", "-C", str(source), "rev-parse", "--show-toplevel"],
                             check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
        commit = subprocess.run(["git", "-C", str(source), "rev-parse", "--verify", "HEAD^{commit}"],
                                check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Cannot read {label} staged Git commit: {source}") from error
    if not top or Path(top).resolve() != source.resolve() or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", commit):
        raise SystemExit(f"Invalid {label} staged Git commit or repository root: {source}")
    return commit


# Resolve both actual staged HEADs before mkdir, backups or any output writes.
# The VMAF directory is provided by the driver's verified successful-install
# lookup, not a guessed _src path or an updated-but-not-built canonical HEAD.
ffmpeg_commit = source_commit(ffmpeg_source, "FFmpeg")
vmaf_commit = source_commit(vmaf_source, "VMAF")
manifest_name = ".ffbuild-artifacts.json"
if output.is_symlink() or (output / manifest_name).is_symlink():
    raise SystemExit("Refusing a symlink Full output directory or artifact manifest")
files = sorted(payload.iterdir(), key=lambda path: path.name.casefold())
if not files or any(path.is_symlink() or not path.is_file() or path.stat().st_size <= 0 or
                    not re.fullmatch(r"[A-Za-z0-9_.+-]+\.(?:exe|dll)", path.name, re.I) for path in files):
    raise SystemExit("Full payload must contain only nonempty regular top-level EXE/DLL files with safe basenames")
if len({path.name.casefold() for path in files}) != len(files):
    raise SystemExit("Full payload has case-insensitive filename collisions")
if not {"ffmpeg.exe", "ffprobe.exe", "ffplay.exe"}.issubset({path.name for path in files}):
    raise SystemExit("Full payload is missing a required executable")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


records = [dict(path=path.name, sha256=digest(path), size=path.stat().st_size) for path in files]
output.mkdir(parents=True, exist_ok=True)
existing = {}
for path in output.iterdir():
    existing.setdefault(path.name.casefold(), []).append(path.name)
names = [path.name for path in files] + [manifest_name]
for name in names:
    target = output / name
    if target.is_symlink() or (target.exists() and not target.is_file()):
        raise SystemExit(f"Refusing a non-regular Full output target: {target}")
    if existing.get(name.casefold(), [name]) != [name]:
        raise SystemExit(f"Resolve the case-insensitive Full output collision first: {name}")

backup = None
if os.environ.get("FFBUILD_BACKUP_PRODUCTS", "1") != "0":
    backup_root.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix="run-", dir=backup_root))
pending = Path(tempfile.mkdtemp(prefix=".full-install-", dir=output.parent))
installed = []
try:
    # Prepare and verify every new file before replacing the first old one.
    for source, record in zip(files, records):
        shutil.copy2(source, pending / source.name)
        if digest(pending / source.name) != record["sha256"]:
            raise RuntimeError(f"Payload changed while staging: {source}")
    (pending / manifest_name).write_text(json.dumps(
        dict(schema=1, variant="full", artifacts=records,
             ffmpeg_commit=ffmpeg_commit, vmaf_commit=vmaf_commit), indent=2) + "\n", encoding="utf-8")
    if backup is not None:
        for name in names:
            if (output / name).exists():
                shutil.copy2(output / name, backup / name)
    # Never leave an old completion certificate over partly replaced binaries.
    (output / manifest_name).unlink(missing_ok=True)
    for name in names:  # The manifest is intentionally last.
        os.replace(pending / name, output / name)
        installed.append(name)
except BaseException:
    # Rollback is possible only when backups were explicitly enabled.
    if backup is not None:
        for name in reversed(installed):
            if (backup / name).exists():
                shutil.copy2(backup / name, pending / name)
                os.replace(pending / name, output / name)
            else:
                (output / name).unlink(missing_ok=True)
        if (backup / manifest_name).exists():
            shutil.copy2(backup / manifest_name, output / manifest_name)
    else:
        (output / manifest_name).unlink(missing_ok=True)
    print(f"Full output update failed; backups={backup}, pending={pending}", file=sys.stderr)
    raise
else:
    pending.rmdir()
    print(f"Full output manifest: {output / manifest_name}; previous files: {backup}")
PYFULLINSTALL
      popd >/dev/null
