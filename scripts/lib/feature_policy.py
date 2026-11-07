#!/usr/bin/env python3
"""Shared, explicit feature policy for the three Windows FFmpeg profiles."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

DEFAULT_MODEL = 'vmaf_v0.6.1'
V1_MODELS = tuple(
    f'{family}_{variant}'
    for family in ('vmaf_v1.0.16', 'vmaf_v1.0.16_hfr',
                   'hdr_vmaf_v1.1.8', 'hdr_vmaf_v1.1.8_hfr')
    for variant in ('3d0h', '3d0h_2160', '5d0h', '1d5h_2160')
)
MODELS = (DEFAULT_MODEL, *V1_MODELS)
REMOVED_MODELS = (
    'vmaf_b_v0.6.3', 'vmaf_v0.6.1neg', 'vmaf_4k_v0.6.1', 'vmaf_4k_v0.6.1neg',
    'vmaf_float_v0.6.1neg', 'vmaf_float_v0.6.1', 'vmaf_float_b_v0.6.3',
    'vmaf_float_4k_v0.6.1',
)
REMOVED_LIBRARIES = (
    'LIBARIBCAPTION', 'LIBOPENMPT', 'LIBSPEEX', 'LIBTWOLAME', 'LIBZVBI',
    'LIBGSM', 'LIBOPENCORE_AMRNB', 'LIBOPENCORE_AMRWB', 'LIBVO_AMRWBENC',
    'VAPOURSYNTH', 'OPENCL', 'DXVA2', 'SWSCALE_VULKAN',
    'LIBVORBIS', 'LIBTHEORA', 'LIBVVENC',
)
REMOVED_ENCODERS = (
    'mp2', 'mp2fixed', 'h264_amf', 'libvpx_vp8', 'libvpx_vp9', 'vp9_qsv',
    'libvvenc', 'vorbis', 'libvorbis', 'libtheora', 'libjxl', 'libjxl_anim',
)
REMOVED_DECODERS = (
    'mp2', 'mp2float', 'speex', 'gsm', 'gsm_ms', 'amrnb', 'amrwb',
    'vorbis', 'libvorbis', 'theora', 'libaom_av1',
)
REMOVED_FILTERS = (
    'bm3d', 'libvmaf_cuda', 'vpp_amf', 'sr_amf', 'frc_amf', 'vqe_amf', 'amf_capture',
)


def regular(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'expected regular source/configuration file: {path}')
    return path


def replace_file(path, text):
    if path.read_text() == text:
        return
    mode = path.stat().st_mode & 0o777
    fd, name = tempfile.mkstemp(prefix='.ffbuild-policy-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(text)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def configure_flags(source):
    configure = regular(Path(source) / 'configure')
    flags = ['--disable-' + name.lower().replace('_', '-') for name in REMOVED_LIBRARIES]
    flags += [f'--disable-filter={name}' for name in REMOVED_FILTERS]
    flags += [f'--disable-encoder={name}' for name in REMOVED_ENCODERS]
    flags += [f'--disable-decoder={name}' for name in REMOVED_DECODERS]
    for category, option in (('encoders', 'encoder'), ('hwaccels', 'hwaccel'), ('filters', 'filter')):
        result = subprocess.run([str(configure), '--list-' + category], check=True,
                                capture_output=True, text=True)
        for name in result.stdout.split():
            if (name.endswith('_vulkan') or 'bm3d' in name.lower() or
                    (category == 'filters' and
                     (name.endswith(('_d3d11', '_d3d12', '_amf')) or name.startswith('amf_'))) or
                    (category == 'encoders' and
                     re.search(r'(?:^|_)(?:vp[3-9]|vvc|h266)(?:_|$)', name))):
                flags.append(f'--disable-{option}={name}')
    print('\n'.join(dict.fromkeys(flags)))


def check_config(path):
    enabled = set()
    for line in regular(path).read_text().splitlines():
        match = re.fullmatch(r'(CONFIG_[A-Z0-9_]+)=yes', line)
        if match:
            enabled.add(match[1])
    forbidden = {'CONFIG_' + name for name in REMOVED_LIBRARIES}
    forbidden |= {'CONFIG_LIBVMAF_CUDA_FILTER', 'CONFIG_OPENCLSRC_FILTER',
                  'CONFIG_LIBOPENMPT_DEMUXER', 'CONFIG_VAPOURSYNTH_DEMUXER'}
    forbidden |= {f'CONFIG_{name.upper()}_ENCODER' for name in REMOVED_ENCODERS}
    forbidden |= {f'CONFIG_{name.upper()}_DECODER' for name in REMOVED_DECODERS}
    forbidden |= {f'CONFIG_{name.upper()}_FILTER' for name in REMOVED_FILTERS}
    forbidden |= {name for name in enabled if 'BM3D' in name or name.endswith('_OPENCL_FILTER') or
                  re.fullmatch(r'CONFIG_.+_VULKAN_(?:ENCODER|DECODER|HWACCEL|FILTER)', name) or
                  name.endswith(('_DXVA2_HWACCEL', '_D3D11_FILTER', '_D3D12_FILTER', '_AMF_FILTER')) or
                  (name.startswith('CONFIG_AMF_') and name.endswith('_FILTER')) or
                  (name.endswith('_ENCODER') and
                   re.search(r'(?:^|_)(?:VP[3-9]|VVC|H266)(?:_|$)', name))}
    active = sorted(enabled & forbidden)
    if active:
        raise ValueError('pruned FFmpeg features unexpectedly enabled: ' + ', '.join(active))
    for required in ('CONFIG_VULKAN', 'CONFIG_LIBPLACEBO', 'CONFIG_LIBPLACEBO_FILTER'):
        if required not in enabled:
            raise ValueError('required libplacebo/Vulkan feature disabled: ' + required)
    print('Verified explicit feature policy; libplacebo/Vulkan retained')


def prune_ffmpeg_source(source):
    source = Path(source)
    configure = regular(source / 'configure')
    text = configure.read_text()
    # Upstream auto-detects this internal backend but does not expose its switch.
    # Expose just that switch; global Vulkan and unstable CPU scaling stay intact.
    blocks = list(re.finditer(r'^CMDLINE_SELECT="\n(.*?)^"\n', text, re.M | re.S))
    if len(blocks) != 1 or text.count('swscale_vulkan_deps="vulkan"') != 1:
        raise ValueError('unknown FFmpeg swscale Vulkan configuration; source left unchanged')
    block = blocks[0]
    options = block[1]
    if options.count('    $CONFIG_LIST\n') != 1 or options.count('    swscale_vulkan\n') > 1:
        raise ValueError('unknown FFmpeg command-line feature list; source left unchanged')
    if '    swscale_vulkan\n' not in options:
        text = text[:block.start(1)] + '    swscale_vulkan\n' + text[block.start(1):]
    paths = [source / 'libavfilter' / name for name in ('vf_bm3d.c', 'vf_bm3d.o', 'vf_bm3d.d')]
    existing = [path for path in paths if os.path.lexists(path)]
    for path in existing:
        regular(path)
    replace_file(configure, text)
    for path in existing:
        path.unlink()
    print(f'Verified swscale Vulkan policy switch; removed {len(existing)} standalone BM3D staged files')


def patch_x264_formats(source):
    path = regular(Path(source) / 'libavcodec/libx264.c')
    text = path.read_text()
    blocks = list(re.finditer(r'static const enum AVPixelFormat pix_fmts_all\[\] = \{\n(.*?)\n\};', text, re.S))
    if len(blocks) != 1:
        raise ValueError('unknown FFmpeg x264 pixel-format declaration; source left unchanged')
    block = blocks[0]
    body = block[1]
    formats = re.findall(r'AV_PIX_FMT_([A-Z0-9_]+)', body)
    retained = {'YUV420P', 'YUVJ420P', 'YUV422P', 'YUVJ422P', 'YUV444P', 'YUVJ444P',
                'NV12', 'NV16', 'NV21', 'GRAY8', 'NONE'}
    removed = {'YUV420P10', 'YUV422P10', 'YUV444P10', 'NV20', 'GRAY10'}
    if len(formats) != len(set(formats)) or set(formats) not in (retained, retained | removed):
        raise ValueError('changed FFmpeg x264 formats require review; source left unchanged')
    for name in removed:
        body = body.replace('    AV_PIX_FMT_' + name + ',\n', '')
    replace_file(path, text[:block.start(1)] + body + text[block.end(1):])
    print('Verified x264 8-bit-only capability table, including gray/NV21 formats')


def patch_x265_formats(source):
    path = regular(Path(source) / 'libavcodec/libx265.c')
    text = path.read_text()
    blocks = list(re.finditer(r'static const enum AVPixelFormat x265_csp_ten\[\] = \{\n(.*?)\n\};', text, re.S))
    if len(blocks) != 1:
        raise ValueError('unknown FFmpeg x265 pixel-format declaration; source left unchanged')
    block = blocks[0]
    body = block[1]
    formats = re.findall(r'AV_PIX_FMT_([A-Z0-9_]+)', body)
    retained = {'YUV420P10', 'YUV422P10', 'YUV444P10', 'GBRP10', 'GRAY10', 'YUVA420P10', 'NONE'}
    removed = {'YUV420P', 'YUVJ420P', 'YUV422P', 'YUVJ422P', 'YUV444P', 'YUVJ444P',
               'GBRP', 'GRAY8', 'YUVA420P'}
    if len(formats) != len(set(formats)) or set(formats) not in (retained, retained | removed):
        raise ValueError('changed FFmpeg x265 formats require review; source left unchanged')
    # This profile uses only the Main10 implementation; FFmpeg converts input as needed.
    for name in removed:
        body = body.replace('    AV_PIX_FMT_' + name + ',\n', '')
    replace_file(path, text[:block.start(1)] + body + text[block.end(1):])
    print('Verified x265 10-bit-only capability table, including gray/GBR/alpha formats')


def patch_amf(source):
    path = regular(Path(source) / 'libavutil/hwcontext_amf.c')
    text = path.read_text()
    start = text.index('static int amf_device_init(')
    end = text.index('\nstatic int amf_load_library(', start)
    body = text[start:end]
    marker = 'AMF requires D3D11 or D3D12; legacy fallbacks are disabled.'
    if marker in body:
        if body.count(marker) != 1 or 'InitDX9' in body or 'InitVulkan' in body:
            raise ValueError('partial or changed AMF feature-policy patch')
        return
    first = body.index('    res = AMF_IFACE_CALL(context, InitDX9, NULL);')
    if body.count('InitDX9, NULL') != 1 or body.count('InitVulkan, NULL') != 1:
        raise ValueError('unknown AMF fallback layout; source left unchanged')
    tail = ('#endif\n\n'
            f'    av_log(ctx, AV_LOG_ERROR, "{marker}\\n");\n'
            '    return AVERROR(ENOSYS);\n}\n')
    body = body[:first] + tail
    body = body.replace('    AMFContext1 *context1 = NULL;\n', '')
    body = body.replace('    AMFGuid guid1 = IID_AMFContext1();\n', '')
    replace_file(path, text[:start] + body + text[end:])
    print('Applied AMF D3D11/D3D12-only initialization policy')


def prune_vmaf(source):
    source = Path(source)
    meson = regular(source / 'libvmaf/src/meson.build')
    model = regular(source / 'libvmaf/src/model.c')
    build_text, model_text = meson.read_text(), model.read_text()
    registered = re.findall(r'\.version = "([^"]+)"', model_text)
    if (len(registered) != len(set(registered)) or
            set(registered) not in (set(MODELS), set(MODELS) | set(REMOVED_MODELS))):
        raise ValueError('unknown upstream VMAF model registry; review before changing models')
    for name in MODELS:
        if name == DEFAULT_MODEL:
            path = source / 'model' / (name + '.json')
        else:
            family = next(f for f in ('vmaf_v1.0.16_hfr', 'vmaf_v1.0.16',
                                     'hdr_vmaf_v1.1.8_hfr', 'hdr_vmaf_v1.1.8')
                          if name.startswith(f + '_'))
            path = source / 'model' / family / (name + '.json')
        regular(path)
    assignment = re.compile(r"        model_files = (?:\[\n.*?        \]|\['vmaf_v0\.6\.1\.json'\])\n", re.S)
    matches = list(assignment.finditer(build_text))
    if len(matches) != 1:
        raise ValueError('unknown VMAF Meson model-file declaration')
    build_text = assignment.sub("        model_files = ['vmaf_v0.6.1.json']\n", build_text, count=1)
    floating = re.compile(r"\n        if float_enabled\n            model_files \+= \[\n.*?        endif\n", re.S)
    build_text = floating.sub('', build_text, count=1)
    for name in REMOVED_MODELS:
        symbol = 'src_' + re.sub(r'[^A-Za-z0-9_]', '_', name) + '_json'
        model_text = re.sub(r'^extern const char ' + re.escape(symbol) + r'\[\];\n', '', model_text, flags=re.M)
        model_text = re.sub(r'^extern const int ' + re.escape(symbol) + r'_len;\n', '', model_text, flags=re.M)
        entry = re.compile(r'    \{\n        \.version = "' + re.escape(name) +
                           r'",\n        \.data = [^\n]+\n        \.data_len = [^\n]+\n    \},\n')
        model_text = entry.sub('', model_text)
    if set(re.findall(r'\.version = "([^"]+)"', model_text)) != set(MODELS):
        raise ValueError('VMAF model policy did not retain exactly default v0 + 16 v1 models')
    if any(name + '.json' in build_text for name in REMOVED_MODELS):
        raise ValueError('VMAF Meson still embeds a removed v0 model')
    removed = []
    for path in (source / 'model').rglob('*'):
        if '_v0.' in path.name and path.name != DEFAULT_MODEL + '.json':
            if path.is_symlink() or not path.resolve().is_relative_to(source.resolve()):
                raise ValueError('unsafe staged VMAF model path: ' + str(path))
            if path.is_file():
                removed.append(path)
    replace_file(meson, build_text)
    replace_file(model, model_text)
    for path in removed:
        path.unlink()
    print(f'VMAF model policy: default v0 + 16 v1 models; removed {len(removed)} staged legacy files')


def patch_source_files(source, label, changes, required, forbidden):
    """Validate every hunk before changing any staged build definition."""
    source = Path(source)
    marker = '# ffbuild: ' + label
    prepared = []
    for relative, edits in changes.items():
        path = regular(source / relative)
        text = path.read_text()
        patched = marker in text
        if patched and text.count(marker) != 1:
            raise ValueError(f'{label}: duplicate policy marker in {relative}')
        for old, new, count in edits:
            if patched:
                if old in text or (new and text.count(new) < count):
                    raise ValueError(f'{label}: partial or changed patch in {relative}')
            else:
                if text.count(old) != count:
                    raise ValueError(f'{label}: unknown upstream layout in {relative}')
                text = text.replace(old, new)
        if not patched:
            text = marker + '\n' + text
        if any(token not in text for token in required.get(relative, ())):
            raise ValueError(f'{label}: required decoder support missing in {relative}')
        if any(token in text for token in forbidden.get(relative, ())):
            raise ValueError(f'{label}: encoder dependency remains in {relative}')
        prepared.append((path, text))
    for path, text in prepared:
        replace_file(path, text)
    print('Verified staged ' + label)


def patch_brotli(source):
    path = 'CMakeLists.txt'
    changes = {path: (
        ('brotlienc brotlidec brotlicommon', 'brotlidec brotlicommon', 3),
        ('brotlienc-static brotlidec-static brotlicommon-static',
         'brotlidec-static brotlicommon-static', 1),
        ('file(GLOB_RECURSE BROTLI_ENC_SOURCES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} c/enc/*.c)\n', '', 1),
        ('add_library(brotlienc ${BROTLI_ENC_SOURCES})\n', '', 1),
        ('  add_library(brotlienc-static STATIC ${BROTLI_ENC_SOURCES})\n', '', 1),
        ('target_link_libraries(brotlienc brotlicommon)\n', '', 1),
        ('transform_pc_file("scripts/libbrotlienc.pc.in" "${CMAKE_CURRENT_BINARY_DIR}/libbrotlienc.pc" "${BROTLI_VERSION}")\n', '', 1),
        ('  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/libbrotlienc.pc"\n'
         '    DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig")\n', '', 1),
    )}
    patch_source_files(source, 'Brotli decoder/common only', changes,
                       {path: ('add_library(brotlidec ', 'add_library(brotlicommon ')},
                       {path: ('brotlienc', 'BROTLI_ENC_SOURCES')})


def patch_jxl(source):
    library = 'lib/jxl.cmake'
    finder = 'cmake/FindBrotli.cmake'
    changes = {
        library: (
            ('  brotlienc\n', '', 1),
            ('# Object library. This is used to hold the set of objects and properties.\n'
             'add_library(jxl_enc-obj OBJECT ${JPEGXL_INTERNAL_ENC_SOURCES})\n'
             'target_compile_options(jxl_enc-obj PRIVATE ${JPEGXL_INTERNAL_FLAGS})\n'
             'target_compile_options(jxl_enc-obj PUBLIC ${JPEGXL_COVERAGE_FLAGS})\n'
             'set_property(TARGET jxl_enc-obj PROPERTY POSITION_INDEPENDENT_CODE ON)\n'
             'target_include_directories(jxl_enc-obj BEFORE PUBLIC\n'
             '  ${PROJECT_SOURCE_DIR}\n'
             '  ${JXL_HWY_INCLUDE_DIRS}\n'
             '  $<TARGET_PROPERTY:brotlicommon,INTERFACE_INCLUDE_DIRECTORIES>\n'
             ')\n'
             'target_compile_definitions(jxl_enc-obj PUBLIC\n'
             '  ${OBJ_COMPILE_DEFINITIONS}\n'
             ')\n'
             'target_link_libraries(jxl_enc-obj PUBLIC jxl_base)\n', '', 1),
            ('set_target_properties(jxl_enc-obj PROPERTIES\n'
             '  CXX_VISIBILITY_PRESET hidden\n'
             '  VISIBILITY_INLINES_HIDDEN 1\n'
             '  DEFINE_SYMBOL JXL_INTERNAL_LIBRARY_BUILD\n'
             ')\n', '', 1),
            ('  $<TARGET_OBJECTS:jxl_enc-obj>\n', '', 1),
            ('"libhwy libbrotlienc libbrotlidec libjxl_cms"',
             '"libhwy libbrotlidec libjxl_cms"', 1),
        ),
        finder: (
            ('set(brlibs brotlicommon brotlienc brotlidec)',
             'set(brlibs brotlicommon brotlidec)', 1),
            ('if (BROTLICOMMON_FOUND AND BROTLIENC_FOUND AND BROTLIDEC_FOUND)',
             'if (BROTLICOMMON_FOUND AND BROTLIDEC_FOUND)', 1),
            ('    BROTLIENC_LIBRARY\n', '', 1),
            ('  BROTLIENC_LIBRARY\n', '', 1),
            ('${BROTLICOMMON_LIBRARY} ${BROTLIENC_LIBRARY} ${BROTLIDEC_LIBRARY}',
             '${BROTLICOMMON_LIBRARY} ${BROTLIDEC_LIBRARY}', 1),
        ),
    }
    patch_source_files(source, 'JPEG XL decoder only', changes,
                       {library: ('add_library(jxl_dec-obj ', 'target_link_libraries(jxl PUBLIC jxl_cms)')},
                       {library: ('jxl_enc-obj', 'brotlienc'), finder: ('BROTLIENC', 'brotlienc')})


def main():
    if sys.argv[1:] == ['models']:
        print(json.dumps(MODELS))
        return
    if len(sys.argv) != 3:
        raise ValueError('usage: feature_policy.py {ffmpeg-flags|ffmpeg-source|check-config|x264|x265|amf|vmaf|brotli|jxl} PATH; or models')
    mode, path = sys.argv[1:]
    if mode == 'ffmpeg-flags':
        configure_flags(path)
    elif mode == 'check-config':
        check_config(path)
    elif mode == 'ffmpeg-source':
        prune_ffmpeg_source(path)
    elif mode == 'x264':
        patch_x264_formats(path)
    elif mode == 'x265':
        patch_x265_formats(path)
    elif mode == 'amf':
        patch_amf(path)
    elif mode == 'vmaf':
        prune_vmaf(path)
    elif mode == 'brotli':
        patch_brotli(path)
    elif mode == 'jxl':
        patch_jxl(path)
    else:
        raise ValueError('unknown feature policy command: ' + mode)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
