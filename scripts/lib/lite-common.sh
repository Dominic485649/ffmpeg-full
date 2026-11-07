#!/usr/bin/env bash
# Shared Windows Lite build logic. Source after backend configuration.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-cache.sh"
declare -a LITE_EVENT_ROWS=() LITE_BUILT_STAGES=()
declare -A LITE_VALIDATED_STAGE=()
LITE_FFMPEG_BUILT=0

# Cache state is private to a profile, and native tools have a separate domain.
# Legacy, unrecorded staging/build trees are inputs to preserve, not to clean.
lite_cache_root() { printf '%s/.lite-cache/%s-lite\n' "$BUILDROOT" "$BACKEND"; }
lite_cache_state() { printf '%s/%s.state.json\n' "$(lite_cache_root)" "$1"; }
lite_cache_record() { printf '%s/%s.success.json\n' "$(lite_cache_root)" "$1"; }

lite_cache_python() {
  python3 -I - "$@" <<'PYLITECACHE'
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def load(path):
    with open(path) as stream:
        return json.load(stream)

def git(path, *args):
    result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(path), *args],
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(f'local git {args[0]} failed: {path}: {result.stderr.decode(errors="replace")}')
    return result.stdout.decode().strip()

def snapshot(root):
    root = Path(root).resolve()
    files, versions, tags = {}, {}, {}
    for base, dirs, names in os.walk(root, followlinks=False):
        base = Path(base)
        dirs.sort()
        if os.path.lexists(base / '.git'):
            if Path(git(base, 'rev-parse', '--show-toplevel')).resolve() != base:
                raise ValueError(f'not an independent source checkout: {base}')
            relative_repo = str(base.relative_to(root))
            versions[relative_repo] = git(base, 'describe', '--tags', '--always', '--dirty')
            tags[relative_repo] = git(base, 'for-each-ref', '--format=%(refname):%(objectname)', 'refs/tags')
        if '.git' in dirs:
            dirs.remove('.git')
        for name in sorted(dirs + names):
            if name == '.git':
                continue
            path = base / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            if path.is_symlink():
                target = path.resolve()
                if not target.is_relative_to(root):
                    raise ValueError(f'external source symlink is not safe to stage: {path}')
                if path.is_dir():
                    raise ValueError(f'directory source symlink is not supported: {path}')
                files[relative] = ['link', mode, os.path.relpath(target, path.parent)]
            elif path.is_file():
                h = hashlib.sha256()
                with path.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        h.update(chunk)
                files[relative] = ['file', mode, h.hexdigest()]
            elif path.is_dir():
                files[relative] = ['dir', mode]
            else:
                raise ValueError(f'unsupported source file: {path}')
    abi = {name: (value[:2] + ['implementation'] if value[0] == 'file'
                 and Path(name).suffix in {'.c', '.cc', '.cpp', '.cxx'} else value)
           for name, value in files.items()}
    return {'files': files, 'tree': digest([files, versions, tags]), 'abi': digest([abi, tags])}

def independent_git(source, target, history):
    temporary = Path(tempfile.mkdtemp(prefix='metadata.', dir=history))
    result = subprocess.run(['git', 'clone', '--no-hardlinks',
                             '--no-checkout', '--', str(source), str(temporary)],
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS='0'),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode or not (temporary / '.git').is_dir():
        raise ValueError(f'cannot create independent local staging metadata: {source}: '
                         + result.stderr.decode(errors='replace'))
    git(temporary, 'read-tree', 'HEAD')
    if os.path.lexists(target / '.git'):
        retained = history / ('retained.' + next(tempfile._get_candidate_names()))
        os.replace(target / '.git', retained)
    os.replace(temporary / '.git', target / '.git')
    temporary.rmdir()  # Only an empty temporary container, never an existing tree.

def file_identity(path):
    path = Path(path)
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return {'path': str(path.absolute()), 'size_bytes': path.stat().st_size, 'sha256': h.hexdigest()}

def backup_products(root, name, paths):
    paths = [Path(path) for path in paths]
    existing = [path for path in paths if os.path.lexists(path)]
    # Installers must not follow old aliases into canonical/other-profile data.
    # Refuse ambiguous symlinks or hardlinks rather than unlinking user files.
    for source in paths:
        for parent in (source, *source.parents):
            if parent.is_symlink():
                raise ValueError(f'refusing to install through an existing symlink: {parent}')
        candidates = [source]
        if source.is_dir():
            candidates = []
            for base, dirs, names in os.walk(source, followlinks=False):
                candidates.extend(Path(base) / child for child in dirs + names)
        for candidate in candidates:
            if candidate.is_symlink() or (candidate.is_file() and candidate.stat().st_nlink > 1):
                raise ValueError(f'refusing to overwrite an aliased installed artifact: {candidate}')
    if not existing:
        return
    if os.environ.get("FFBUILD_BACKUP_PRODUCTS", "1") == "0":
        return
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=name + '.', dir=root))
    entries = []
    for i, source in enumerate(existing):
        if source.is_symlink() and source.is_dir():
            raise ValueError(f'cannot safely retain a directory symlink before install: {source}')
        files = []
        if source.is_dir():
            for base, dirs, names in os.walk(source, followlinks=False):
                for child in dirs:
                    if (Path(base) / child).is_symlink():
                        raise ValueError(f'cannot retain a directory symlink: {Path(base) / child}')
                files.extend(Path(base) / child for child in names)
        else:
            files.append(source)
        identities = [file_identity(path) for path in sorted(files)]
        destination = backup / (f'{i:03d}-' + source.name)
        if source.is_dir():
            shutil.copytree(source, destination, symlinks=False)
        else:
            shutil.copy2(source, destination, follow_symlinks=True)
        for expected in identities:
            relative = Path(expected['path']).relative_to(source) if source.is_dir() else Path('.')
            copied = destination / relative if source.is_dir() else destination
            if file_identity(copied)['sha256'] != expected['sha256']:
                raise ValueError(f'retained artifact copy verification failed: {source}')
        entries.append({'original_path': str(source.absolute()), 'backup_path': str(destination), 'files': identities})
    atomic(backup / 'retained-products.json', {'schema': 1, 'stage': name, 'products': entries})

def retire_certificate(path, root):
    path, root = Path(path), Path(root)
    if not os.path.lexists(path):
        return
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'unsafe current build certificate: {path}')
    if os.environ.get("FFBUILD_BACKUP_PRODUCTS", "1") == "0":
        path.unlink()
        return
    root.mkdir(parents=True, exist_ok=True)
    retained = Path(tempfile.mkdtemp(prefix='previous-certificate.', dir=root))
    identity = file_identity(path)
    os.replace(path, retained / path.name)
    atomic(retained / 'retained-products.json', {'schema': 1, 'certificate': identity})

def reusable_timestamps(build):
    now = time.time_ns()
    for base, dirs, names in os.walk(build, followlinks=False):
        for name in names:
            path = Path(base) / name
            if path.is_file() and not path.is_symlink() and path.stat().st_mtime_ns > now:
                return False
    return True

def stage_source(source, candidate, current, previous, reuse, build, history):
    source, candidate, history = Path(source).resolve(), Path(candidate), Path(history)
    history.mkdir(parents=True, exist_ok=True)
    candidate.parent.mkdir(parents=True, exist_ok=True)
    old = load(previous) if reuse else {}
    if reuse:
        stage = Path(old['stage'])
        if stage.is_symlink() or not stage.is_dir() or stage.parent.resolve() != candidate.parent.resolve():
            raise ValueError('untrusted staged source path')
        if old['abi'] != current['abi']:
            raise ValueError('source layout or ABI changed during staging')
    elif not os.path.lexists(candidate):
        candidate.mkdir()
        stage = candidate
    else:
        stage = Path(tempfile.mkdtemp(prefix=candidate.name + '.lite-', dir=candidate.parent))
    # Changed files must be newer than retained objects, even if the canonical
    # edit kept its size/mtime or the old objects have a future timestamp.
    timestamp = time.time_ns()
    if reuse and build:
        for base, dirs, names in os.walk(build, followlinks=False):
            for name in names:
                path = Path(base) / name
                if path.is_file() and not path.is_symlink():
                    timestamp = max(timestamp, path.stat().st_mtime_ns + 1)
    old_files = old.get('files', {})
    for base, dirs, names in os.walk(source, followlinks=False):
        base = Path(base)
        relative_base = base.relative_to(source)
        target_base = stage / relative_base
        target_base.mkdir(parents=True, exist_ok=True)
        dirs.sort()
        if os.path.lexists(base / '.git'):
            independent_git(base, target_base, history)
        if '.git' in dirs:
            dirs.remove('.git')
        for name in sorted(dirs + names):
            if name == '.git':
                continue
            path = base / name
            relative = path.relative_to(source).as_posix()
            value = current['files'][relative]
            target = stage / relative
            if reuse and old_files.get(relative) == value:
                continue  # Preserve patched/generated files and their mtimes.
            if value[0] == 'dir':
                target.mkdir(parents=True, exist_ok=True)
                os.chmod(target, value[1])
            elif value[0] == 'link':
                if os.path.lexists(target):
                    raise ValueError(f'refusing to overwrite a staged symlink: {target}')
                target.symlink_to(value[2])
            else:
                if target.is_symlink():
                    raise ValueError(f'refusing to follow staged symlink: {target}')
                shutil.copy2(path, target)
                if reuse:
                    os.utime(target, ns=(timestamp, timestamp))
    return str(stage)

try:
    mode, *args = sys.argv[1:]
    if mode == 'clean-source':
        root = Path(args[0]).resolve()
        for base, dirs, names in os.walk(root, followlinks=False,
                                         onerror=lambda error: (_ for _ in ()).throw(error)):
            base = Path(base)
            if os.path.lexists(base / '.git'):
                if Path(git(base, 'rev-parse', '--show-toplevel')).resolve() != base:
                    raise ValueError(f'not an independent source checkout: {base}')
                status = git(base, 'status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none')
                if status:
                    raise ValueError(f'源码或子模块有本地修改，保留并停止更新: {base}: {status}')
                submodules = git(base, 'submodule', 'status', '--recursive')
                if any(line.startswith(('+', 'U')) for line in submodules.splitlines()):
                    raise ValueError(f'子模块提交与父仓库不一致，保留并停止更新: {base}')
            if '.git' in dirs:
                dirs.remove('.git')
    elif mode == 'snapshot':
        value = snapshot(args[0])
        atomic(args[1], value)
        print(value['tree'])
        print(value['abi'])
    elif mode == 'backup':
        root, name, *paths = args
        backup_products(root, name, paths)
    elif mode == 'retire':
        retire_certificate(args[0], args[1])
    elif mode == 'certificate':
        path, variant, status, build_mode, key, source, staged, stage, build, exe, prefix_exe = args
        artifact, installed = file_identity(exe), file_identity(prefix_exe)
        if not artifact['size_bytes'] or artifact['sha256'] != installed['sha256']:
            raise ValueError('delivered FFmpeg does not match the installed verified artifact')
        artifact['name'] = Path(exe).name
        atomic(path, {'schema': 1, 'variant': variant, 'build_name': variant + '-lite',
                      'status': 'artifacts-verified', 'cache_status': status, 'build_mode': build_mode,
                      'source_commit': git(stage, 'rev-parse', 'HEAD'), 'source_path': stage, 'build_path': build,
                      'input_sha256': key, 'source_sha256': source, 'staged_source_sha256': staged,
                      'exe': artifact, 'prefix_exe': installed,
                      'verified_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')})
    elif mode == 'link-manifest':
        path, manifest = args
        value = load(path)
        payload = load(manifest)
        if payload['build_name'] != value['build_name']:
            raise ValueError('Lite manifest/certificate profile mismatch')
        event = next(row for row in payload['cache_stages'] if row['stage'] == 'ffmpeg')
        if event['input_sha256'] != value['input_sha256']:
            raise ValueError('Lite manifest/certificate input mismatch')
        if file_identity(value['exe']['path'])['sha256'] != value['exe']['sha256']:
            raise ValueError('FFmpeg changed before manifest completion')
        value['manifest'] = file_identity(manifest)
        value['status'] = 'complete'
        atomic(path, value)
    elif mode == 'reuse-safe':
        sys.exit(0 if reusable_timestamps(args[0]) else 1)
    elif mode == 'get':
        value = load(args[0])[args[1]]
        if not isinstance(value, str) or '\n' in value:
            raise ValueError('invalid Lite cache state field')
        print(value)
    elif mode == 'stage':
        source, candidate, current, previous, reuse, build, history = args
        print(stage_source(source, candidate, load(current), previous, reuse == '1', build, history))
    elif mode == 'state':
        current, output, key, source, config, stage, build, staged = args
        value = load(current)
        value.update(input=key, source=source, config=config, stage=stage, build=build, staged=staged)
        atomic(output, value)
    elif mode == 'manifest':
        path, build_mode, ffmpeg_built, *rows = args
        value = load(path)
        stages = []
        for i in range(0, len(rows), 7):
            name, status, key, source, staged, stage, build = rows[i:i + 7]
            stages.append(dict(stage=name, status=status, input_sha256=key, source_sha256=source,
                               staged_source_sha256=staged, source_path=stage, build_path=build))
        value['cache_stages'] = stages
        value['build_scope']['mode'] = build_mode
        value['build_scope']['partial'] = build_mode != 'full'
        value['ffmpeg_built_this_run'] = ffmpeg_built == '1'
        value['skipped_validations'] = [item for item in value.get('skipped_validations', [])
            if not item.startswith('This partial build reused previously installed PREFIX dependencies;')]
        if ffmpeg_built != '1':
            value['successful_validations'] = []
            value['skipped_validations'].append('FFmpeg config/runtime/hardware tests were not rerun; '
                'the cache verified previously successful artifacts and exact input identities only.')
        atomic(path, value)
    else:
        raise ValueError('unknown Lite cache operation')
except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
    print(f'Lite cache: {error}', file=sys.stderr)
    sys.exit(1)
PYLITECACHE
}

lite_state_get() { lite_cache_python get "$(lite_cache_state "$1")" "$2"; }

lite_cache_claim_profile() {
  local path owner marker base protected other parent resolved
  owner="${BACKEND}-lite"
  other=qsv; [[ "$BACKEND" != qsv ]] || other=nvenc
  if ffbuild__paths_overlap "$(realpath -m -- "$PREFIX")" "$(realpath -m -- "$BUILDROOT")" \
      || ffbuild__paths_overlap "$(realpath -m -- "$PREFIX")" "$(realpath -m -- "$HOST_TOOLS")"; then
    echo 'Lite host tools, target prefix and build root must not overlap' >&2; return 1
  fi
  for path in "$PREFIX" "$BUILDROOT" "$HOST_TOOLS"; do
    lite_assert_generated_directory "$path" || return 1
    resolved="$(realpath -m -- "$path")" || return 1
    for base in "$ROOT" "$FFBUILD_CODE_ROOT"; do
      for protected in "$base/bin" "$base/build" "$base/bin_$other" "$base/build_$other"; do
        if ffbuild__paths_overlap "$resolved" "$(realpath -m -- "$protected")"; then
          echo "Lite cannot use another profile's generated roots: $path" >&2; return 1
        fi
      done
    done
    parent="$resolved"
    while [[ "$parent" != / ]]; do
      marker="$parent/.ffbuild-profile"
      if [[ -e "$marker" || -L "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$owner" ]] || {
          echo "generated root belongs to a different build profile: $path" >&2; return 1;
        }
      fi
      parent="$(dirname "$parent")"
    done
  done
  for path in "$BUILDROOT/.lite-cache" "$(lite_cache_root)" "$(lite_cache_root)/retained-git" \
    "$(lite_cache_root)/retained-products" "$BUILDROOT/_src"; do
    lite_assert_generated_directory "$path" || return 1
    [[ ! -L "$path" && "$(realpath -m -- "$path")" == "$(realpath -m -- "$BUILDROOT")/"* ]] || {
      echo "unsafe Lite cache/staging container: $path" >&2; return 1;
    }
  done
  lite_assert_generated_file "$OUTPUT_DIR/.ffbuild-profile" || return 1
  marker="$OUTPUT_DIR/.ffbuild-profile"
  [[ ! -L "$marker" ]] || return 1
  if [[ -e "$marker" && "$(<"$marker")" != "$owner" ]]; then
    echo "artifact directory belongs to a different build profile: $OUTPUT_DIR" >&2; return 1
  fi
  for path in "$PREFIX" "$BUILDROOT" "$HOST_TOOLS" "$OUTPUT_DIR"; do
    mkdir -p -- "$path" || return 1
    printf '%s\n' "$owner" > "$path/.ffbuild-profile" || return 1
  done
}

lite_cache_lock() {
  local lock="$BUILDROOT/.ffbuild-build.lock"
  lite_assert_generated_directory "$BUILDROOT" || return 1
  lite_assert_generated_file "$lock" || return 1
  [[ ! -L "$lock" ]] || { echo "refusing a symlink build lock: $lock" >&2; return 1; }
  ffbuild_cache_lock "$lock" lite_with_cache_lock "$@"
}

lite_stage_source_key() {
  local path="$1" name="$2" key version
  local extras=()
  if [[ "$name" == libshaderc || "$name" == host-glslc ]]; then
    extras=(third_party/abseil_cpp third_party/effcee third_party/googletest third_party/glslang
      third_party/re2 third_party/spirv-headers third_party/spirv-tools)
  fi
  key="$(ffbuild_cache_source_key "$path" "${extras[@]}")" || return 1
  version="$(GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false -C "$path" describe --tags --always --dirty)" || return 1
  ffbuild_cache_hash "$key" "$version"
}

lite_stage_outputs() {
  local stage="$1" p
  case "$stage" in
    nv-codec-headers) printf '%s\n' "$PREFIX/include/ffnvcodec" "$PREFIX/lib/pkgconfig/ffnvcodec.pc" ;;
    opus) printf '%s\n' "$PREFIX/lib/libopus.a" "$PREFIX/include/opus" "$PREFIX/lib/pkgconfig/opus.pc" ;;
    libvpl) printf '%s\n' "$PREFIX/lib/libvpl.a" "$PREFIX/include/vpl" "$PREFIX/lib/pkgconfig/vpl.pc" ;;
    libsoxr) printf '%s\n' "$PREFIX/lib/libsoxr.a" "$PREFIX/include/soxr.h" "$PREFIX/lib/pkgconfig/soxr.pc" ;;
    libshaderc) printf '%s\n' "$PREFIX/lib/libshaderc_combined.a" "$PREFIX/include/shaderc" "$PREFIX/include/spirv" "$PREFIX/lib/pkgconfig/shaderc.pc" ;;
    vulkan-headers) printf '%s\n' "$PREFIX/include/vulkan" "$PREFIX/include/vk_video" "$PREFIX/lib/vulkan-1.def" \
      "$PREFIX/lib/libvulkan-1.dll.a" "$PREFIX/lib/libvulkan.dll.a" "$PREFIX/lib/libvulkan-1.a" "$PREFIX/lib/libvulkan.a" "$PREFIX/lib/pkgconfig/vulkan.pc" ;;
    libplacebo) printf '%s\n' "$PREFIX/lib/libplacebo.a" "$PREFIX/include/libplacebo" "$PREFIX/lib/pkgconfig/libplacebo.pc" ;;
    host-glslc) printf '%s\n' "$HOST_GLSLC" "$HOST_TOOLS/.glslc-stamp" ;;
    ffmpeg) printf '%s\n' "$PREFIX/bin/ffmpeg.exe" "$OUTPUT_DIR/ffmpeg.exe" "$BUILDROOT/ffmpeg-configure.args" ;;
    *) echo "unknown cached Lite stage: $stage" >&2; return 1 ;;
  esac
}

lite_backup_stage_outputs() {
  local text
  local -a paths=()
  text="$(lite_stage_outputs "$1")" || return 1
  mapfile -t paths <<< "$text"
  lite_cache_python backup "$(lite_cache_root)/retained-products" "$1" "${paths[@]}"
}

lite_write_delivery_certificate() {
  lite_assert_generated_file "$OUTPUT_DIR/.ffbuild-current.json" || return 1
  lite_cache_python certificate "$OUTPUT_DIR/.ffbuild-current.json" "$BACKEND" "$1" "${LITE_BUILD_MODE:-full}" \
    "$2" "$3" "$4" "$5" "$6" "$OUTPUT_DIR/ffmpeg.exe" "$PREFIX/bin/ffmpeg.exe"
}

lite_stage_dependencies() {
  case "$1" in
    libplacebo) printf '%s\n' libshaderc vulkan-headers ;;
    ffmpeg)
      local stage
      for stage in "${STAGES[@]}"; do [[ "$stage" == ffmpeg ]] || printf '%s\n' "$stage"; done
      printf '%s\n' host-glslc ;;
  esac
}

lite_dependency_key() {
  local stage="$1" dep key state record source current data=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    if [[ "$dep" == host-glslc && "$HOST_GLSLC" != "$HOST_TOOLS/bin/glslc" ]]; then
      data+=("external-host=$(ffbuild_cache_tree_key "$HOST_GLSLC")")
      continue
    fi
    state="$(lite_cache_state "$dep")"; record="$(lite_cache_record "$dep")"
    key="$(lite_state_get "$dep" input 2>/dev/null)" || {
      echo "uncertified Lite dependency $dep; run ./ffmpeg.sh build to validate prerequisites" >&2; return 1;
    }
    ffbuild_cache_hit "$record" "$key" || {
      echo "damaged/stale Lite dependency $dep; run ./ffmpeg.sh build" >&2; return 1;
    }
    [[ "${LITE_VALIDATED_STAGE[$dep]:-}" == "$key" ]] || {
      echo "prerequisite $dep was not validated for this configuration; run ./ffmpeg.sh build" >&2; return 1;
    }
    source="$dep"; [[ "$dep" != host-glslc ]] || source=libshaderc
    current="$(lite_stage_source_key "$(source_dir "$source")" "$dep")" || return 1
    [[ "$current" == "$(lite_state_get "$dep" source)" ]] || {
      echo "source changed for prerequisite $dep; run ./ffmpeg.sh build" >&2; return 1;
    }
    data+=("$dep=$key" "$(ffbuild_cache_tree_key "$record" "$state")")
  done < <(lite_stage_dependencies "$stage")
  ffbuild_cache_hash "${data[@]}"
}

lite_record_event() {
  local stage="$1" status="$2" key="$3" source="$4" staged="$5" path="$6" build="$7"
  if [[ "${LITE_VALIDATED_STAGE[$stage]:-}" != "$key" || "$status" != reused ]]; then
    LITE_EVENT_ROWS+=("$stage" "$status" "$key" "$source" "$staged" "$path" "$build")
  fi
  LITE_VALIDATED_STAGE[$stage]="$key"
  if [[ "$status" != reused ]]; then LITE_BUILT_STAGES+=("$stage"); fi
  if [[ "$stage" == ffmpeg ]]; then
    FFMPEG_BUILD_DIR="$build"
    [[ "$status" == reused ]] || LITE_FFMPEG_BUILT=1
  fi
}

lite_run_stage_cached() {
  local name="$1" source_name="$1" domain=target source state record pending keys tree abi
  local source_key config input deps recipe toolchain previous='' old_build='' path build='' staged outputs_text
  local reuse=0 previous_valid=0 compat status=built
  [[ "$name" != ffmpeg ]] || source_name=ffmpeg-source
  [[ "$name" != host-glslc ]] || { source_name=libshaderc; domain=host; }
  source="$(source_dir "$source_name")" || { need_repo "$source_name"; return 1; }
  mkdir -p "$(lite_cache_root)" || return 1
  state="$(lite_cache_state "$name")"; record="$(lite_cache_record "$name")"
  pending="$(mktemp "$(lite_cache_root)/.$name.snapshot.XXXXXX")" || return 1
  keys="$(lite_cache_python snapshot "$source" "$pending")" || return 1
  tree="${keys%%$'\n'*}"; abi="${keys#*$'\n'}"
  source_key="$(lite_stage_source_key "$source" "$name")" || return 1
  deps="$(lite_dependency_key "$name")" || return 1
  recipe="$(ffbuild_cache_tree_key "$LITE_RECIPE_SCRIPT" "$LITE_SCRIPT_DIR/../lib/lite-common.sh" \
    "$LITE_SCRIPT_DIR/../lib/workspace.sh" "$LITE_SCRIPT_DIR/../lib/build-cache.sh" "$LITE_SCRIPT_DIR/../lib/feature_policy.py" "$FFBUILD_CODE_ROOT/shared-patches")" || return 1
  if [[ "$domain" == host ]]; then
    toolchain="${LITE_HOST_TOOLCHAIN_KEY:-}"
    [[ -n "$toolchain" ]] || toolchain="$(lite_host_toolchain_key)" || return 1
    LITE_HOST_TOOLCHAIN_KEY="$toolchain"
  else
    toolchain="${LITE_TARGET_TOOLCHAIN_KEY:-}"
    [[ -n "$toolchain" ]] || toolchain="$(ffbuild_cache_toolchain_key)" || return 1
  fi
  config="$(ffbuild_cache_hash "$BACKEND-lite-$domain" "$TARGET" "$PREFIX" "$BUILDROOT" "$HOST_TOOLS" "$OUTPUT_DIR" \
    "$source" "$recipe" "$toolchain" "$deps" "LIBS=${LIBS-}" "HOST_GLSLC=$HOST_GLSLC")" || return 1
  if [[ "$name" == libplacebo ]]; then
    [[ -s "$BUILDROOT/mingw-cross.txt" ]] || { echo 'missing Lite Meson cross file' >&2; return 1; }
    config="$(ffbuild_cache_hash "$config" "$(ffbuild_cache_tree_key "$BUILDROOT/mingw-cross.txt")")" || return 1
  fi
  if [[ "$name" == ffmpeg && "$BACKEND" == nvenc ]]; then
    config="$(ffbuild_cache_hash "$config" "$(ffbuild_cache_tree_key "$CUDA_HOME/include" \
      "$CUDA_HOME/targets/x86_64-linux/include" "$CUDA_HOME/nvvm/libdevice" "$CUDA_HOME/version.json")")" || return 1
  fi
  input="$(ffbuild_cache_hash "$config" "$source_key" "$tree")" || return 1
  if [[ -f "$state" ]]; then
    previous="$(lite_state_get "$name" input)" || previous=''
    if [[ -n "$previous" ]] && ffbuild_cache_hit "$record" "$previous"; then previous_valid=1; fi
  fi
  if (( previous_valid )) && [[ "$input" == "$previous" ]]; then
    path="$(lite_state_get "$name" stage)" || return 1
    build="$(lite_state_get "$name" build)" || return 1
    staged="$(lite_stage_source_key "$path" "$name")" || return 1
    if [[ "$staged" == "$(lite_state_get "$name" staged)" ]]; then
      [[ "$name" != host-glslc ]] || host_glslc_version "$HOST_GLSLC" >/dev/null || return 1
      echo "===> $name (content-verified cache hit)"
      if [[ "$name" == ffmpeg ]]; then
        lite_write_delivery_certificate reused "$input" "$source_key" "$staged" "$path" "$build" || return 1
      fi
      lite_record_event "$name" reused "$input" "$source_key" "$staged" "$path" "$build"
      rm -f -- "$pending"
      return 0
    fi
    previous_valid=0
  fi
  # Only existing C/C++ implementation edits are verified as ABI-compatible.
  # Header/config/layout/dependency changes, failures and corrupted outputs all
  # get new siblings; no unrecorded directory is modified or deleted.
  case "$name" in
    libvpl|libsoxr|libplacebo|ffmpeg)
      if (( previous_valid )) && [[ "$config" == "$(lite_state_get "$name" config)" \
          && "$abi" == "$(lite_state_get "$name" abi)" ]]; then
        old_build="$(lite_state_get "$name" build)" || return 1
        if lite_cache_python reuse-safe "$old_build"; then reuse=1; status=source-incremental; fi
      fi ;;
  esac
  local stage_label="$source_name"
  [[ "$domain" != host ]] || stage_label=libshaderc-host
  ffbuild_assert_staging_path "$BUILDROOT" "$BUILDROOT/_src/$stage_label" "$source" || return 1
  path="$(lite_cache_python stage "$source" "$BUILDROOT/_src/$stage_label" "$pending" "$state" \
    "$reuse" "$old_build" "$(lite_cache_root)/retained-git")" || return 1
  compat="$(ffbuild_cache_hash "$config" "$abi" "$path")" || return 1
  if (( ! reuse )); then compat="$(ffbuild_cache_hash "$compat" "$pending")" || return 1; fi
  case "$name" in
    libvpl|libsoxr|libshaderc|libplacebo|ffmpeg|host-glslc)
      if (( reuse )); then
        lite_assert_generated_directory "$old_build" || return 1
        [[ "$(realpath -m -- "$old_build")" == "$(realpath -m -- "$BUILDROOT")/"* ]] || return 1
        build="$old_build"
      else
        build="$(ffbuild_cache_build_dir "$BUILDROOT/$name" "$compat")" || return 1
      fi ;;
  esac
  # Retain all selected old installed products before make/install/strip/copy
  # can overwrite them. A backup failure aborts without touching those products.
  lite_backup_stage_outputs "$name" || return 1
  # Retire the old success certificate before the first mutating build step.
  # A failure never leaves a valid completion stamp for partially written output.
  if [[ -f "$record" ]]; then
    if [[ "${FFBUILD_BACKUP_PRODUCTS:-1}" == 0 ]]; then rm -- "$record" || return 1
    else mv -- "$record" "$record.retained.$(date +%s%N)" || return 1; fi
  fi
  local LITE_ACTIVE_SOURCE_NAME="$source_name" LITE_ACTIVE_STAGE="$path" LITE_ACTIVE_BUILD_DIR="$build"
  local LITE_REUSE_OBJECTS="$reuse" LITE_DEPENDENCIES_CHANGED=1
  if (( previous_valid )) && [[ "$config" == "$(lite_state_get "$name" config)" ]]; then
    LITE_DEPENDENCIES_CHANGED=0
  fi
  echo "===> $name ($status; preserved prior trees)"
  if [[ "$name" == host-glslc ]]; then
    build_host_glslc_from_source "$path" || return 1
  else
    run_stage_recipe "$name" || return 1
  fi
  if [[ "$name" == libshaderc || "$name" == host-glslc ]]; then shaderc_dependencies_ready "$path" || return 1; fi
  # Refuse to certify a build if inputs changed concurrently during execution.
  local checked_toolchain
  if [[ "$domain" == host ]]; then checked_toolchain="$(lite_host_toolchain_key)" || return 1
  else checked_toolchain="$(ffbuild_cache_toolchain_key)" || return 1; fi
  [[ "$checked_toolchain" == "$toolchain" ]] || {
    echo "Lite toolchain changed during $name; no success record written" >&2; return 1;
  }
  keys="$(lite_cache_python snapshot "$source" "$pending.check")" || return 1
  [[ "${keys%%$'\n'*}" == "$tree" && "$(lite_stage_source_key "$source" "$name")" == "$source_key" ]] || {
    echo "Lite source changed during $name; no success record written" >&2; return 1;
  }
  staged="$(lite_stage_source_key "$path" "$name")" || return 1
  lite_cache_python state "$pending" "$state" "$input" "$source_key" "$config" "$path" "$build" "$staged" || return 1
  outputs_text="$(lite_stage_outputs "$name")" || return 1
  local -a outputs=()
  mapfile -t outputs <<< "$outputs_text"
  outputs+=("$state" "$path")
  [[ -z "$build" ]] || outputs+=("$build")
  ffbuild_cache_commit "$record" "$input" "${outputs[@]}" || return 1
  if [[ "$name" == ffmpeg ]]; then
    lite_write_delivery_certificate "$status" "$input" "$source_key" "$staged" "$path" "$build" || return 1
  fi
  lite_record_event "$name" "$status" "$input" "$source_key" "$staged" "$path" "$build"
  rm -f -- "$pending" "$pending.check"
}

lite_with_cache_lock() {
  local LITE_CACHE_LOCKED=1
  lite_cache_claim_profile || return 1
  "$@"
}

run_stage() {
  if [[ "${LITE_CACHE_LOCKED:-0}" != 1 ]]; then
    lite_assert_generated_directory "$BUILDROOT" || return 1
    lite_cache_lock run_stage "$@"
    return $?
  fi
  local stage="$1"
  CURRENT_STAGE="$stage"
  # Resolve host/CUDA inputs before calculating the FFmpeg cache identity.
  if [[ "$stage" == ffmpeg ]]; then
    [[ "$BACKEND" != nvenc ]] || setup_cuda || return 1
    ensure_host_glslc || return 1
  fi
  lite_run_stage_cached "$stage" || return 1
  [[ "$stage" != libshaderc ]] || ensure_host_glslc
}
# Validate the complete set before deleting any path. Also protect the code
# checkout when ROOT points at a separate workspace, and legacy source fallbacks.
lite_assert_generated_path() {
  local raw="${1:-}" path name protected
  ffbuild_assert_generated_path "$raw" || return 1
  SOURCE_ROOT="$ROOT/sources" ffbuild_assert_generated_path "$raw" || return 1
  ROOT="$FFBUILD_CODE_ROOT" SOURCE_ROOT="$FFBUILD_CODE_ROOT/sources" \
    ffbuild_assert_generated_path "$raw" || return 1
  path="$(realpath -m -- "$raw")" || return 1
  for name in "${!URLS[@]}"; do
    protected="$(ffbuild_source_dir "$name")" || return 1
    protected="$(realpath -m -- "$protected")" || return 1
    if [[ "$path" == "$protected" || "$path" == "$protected/"* || "$protected" == "$path/"* ]]; then
      echo "refusing to remove canonical source: $path ($name)" >&2
      return 1
    fi
  done
}

lite_assert_generated_directory() {
  lite_assert_generated_path "${1:-}" || return 1
  ffbuild_assert_generated_directory "$1"
}

lite_assert_generated_file() {
  lite_assert_generated_path "${1:-}" || return 1
  if [[ -d "$1" || -L "$1" ]]; then
    echo "refusing to treat a directory or symlink as an output file: $1" >&2
    return 1
  fi
}

lite_remove_generated_trees() {
  local path
  for path in "$@"; do
    lite_assert_generated_directory "$path" || return 1
  done
  for path in "$@"; do
    ffbuild_remove_generated_tree "$path" || return 1
  done
}

lite_remove_generated_files() {
  local path
  for path in "$@"; do
    lite_assert_generated_file "$path" || return 1
  done
  rm -f -- "$@"
}

# Staged repositories deliberately retain .git for source-version queries.
# This exception never accepts canonical inputs or arbitrary Git directories:
# every path must resolve strictly inside the guarded BUILDROOT/_src tree.
lite_remove_staged_trees() {
  local path resolved staged_root
  lite_assert_generated_directory "$BUILDROOT" || return 1
  lite_assert_generated_directory "$BUILDROOT/_src" || return 1
  staged_root="$(realpath -m -- "$BUILDROOT/_src")" || return 1
  for path in "$@"; do
    lite_assert_generated_path "$path" || return 1
    resolved="$(realpath -m -- "$path")" || return 1
    [[ "$resolved" == "$staged_root/"* ]] || {
      echo "refusing to remove a repository outside staging: $path" >&2
      return 1
    }
    [[ ! -e "$path" || -d "$path" ]] || {
      echo "refusing to treat a file as a staged source directory: $path" >&2
      return 1
    }
  done
  rm -rf -- "$@"
}

run_clean() {
  # Validate directories AND the output file before removing the first path.
  lite_assert_generated_directory "$PREFIX" || return 1
  lite_assert_generated_directory "$BUILDROOT" || return 1
  lite_assert_generated_file "$OUTPUT_DIR/ffmpeg.exe" || return 1
  lite_remove_generated_trees "$PREFIX" "$BUILDROOT" || return 1
  lite_remove_generated_files "$OUTPUT_DIR/ffmpeg.exe"
}

usage() {
  cat <<EOF
Usage:
  ./ffmpeg.sh                    update sources, then build
  ./ffmpeg.sh all                update sources, then build
  ./ffmpeg.sh build              build $BACKEND lite ffmpeg.exe from local sources
  ./ffmpeg.sh build ffmpeg       rebuild from ffmpeg stage
  ./ffmpeg.sh update             update only the source repos used by this backend
  ./ffmpeg.sh clean              remove $PREFIX and $BUILDROOT

Output:
  $OUTPUT_DIR/ffmpeg.exe

Build paths:
  workspace: $ROOT
  sources: $SOURCE_ROOT
  prefix: $PREFIX
  build: $BUILDROOT
  host glslc: $HOST_GLSLC

Native AAC NMR:
  -c:a aac -profile:a aac_low -aac_coder nmr -aac_nmr_speed 0

External Opus:
  -c:a libopus; native opus decoder remains enabled
EOF
}
on_error() {
  local code=$?
  echo
  echo "============================================================"
  echo "Build failed: ${CURRENT_STAGE:-unknown} (exit=$code)"
  [[ -n "${CURRENT_STAGE:-}" ]] && echo "Resume with: ./ffmpeg.sh build $CURRENT_STAGE"
  echo "============================================================"
  exit "$code"
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1"; exit 1; }; }
git_retry() {
  local attempt
  for attempt in 1 2 3 4; do
    if (( attempt % 2 == 1 )); then
      "$@" && return 0
    else
      env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy "$@" && return 0
    fi
    echo "git command failed ($attempt/4), retrying..." >&2
    sleep "$((attempt * 5))"
  done
  return 1
}
canonical_tool() {
  local v="$1"
  if [[ "$v" == */* ]]; then
    [[ -x "$v" ]] || { echo "tool not executable: $v"; exit 1; }
    printf '%s\n' "$v"
  else
    command -v "$v" >/dev/null 2>&1 || { echo "tool not found: $v"; exit 1; }
    command -v "$v"
  fi
}
first_tool() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 && { command -v "$t"; return 0; }
  done
  echo "tool not found: $*" >&2
  exit 1
}
lite_latest_mingw_asset_url() {
  # gh uses its own existing authentication. Never read credentials, request a
  # token, or print its stderr; failed authentication can safely use public API.
  python3 -I - <<'PYMINGWRELEASE'
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

endpoint = 'repos/mstorsjo/llvm-mingw/releases/latest'
public_url = 'https://api.github.com/' + endpoint
asset_root = 'https://github.com/mstorsjo/llvm-mingw/releases/download/'
asset_name = re.compile(r'llvm-mingw-[^\s/]+-ucrt-ubuntu-22\.04-x86_64\.tar\.xz')

def select_asset(data):
    if not isinstance(data, dict) or not isinstance(data.get('assets'), list):
        raise ValueError('invalid release metadata')
    matches = []
    for asset in data['assets']:
        if not isinstance(asset, dict):
            continue
        name, url = asset.get('name'), asset.get('browser_download_url')
        if (isinstance(name, str) and asset_name.fullmatch(name) and isinstance(url, str)
                and url.startswith(asset_root) and url.rsplit('/', 1)[-1] == name
                and not any(character.isspace() for character in url)):
            matches.append(url)
    if len(matches) != 1:
        raise ValueError('latest release does not identify one matching Linux asset')
    return matches[0]

gh = shutil.which('gh')
if gh:
    try:
        response = subprocess.run([gh, 'api', '--hostname', 'github.com', endpoint],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  timeout=60, check=True)
        print(select_asset(json.loads(response.stdout)))
        sys.exit(0)
    except (OSError, subprocess.SubprocessError, ValueError):
        print('gh GitHub release query unavailable; trying unauthenticated API', file=sys.stderr)

for attempt in range(4):
    try:
        with urllib.request.urlopen(public_url, timeout=60) as response:
            data = json.load(response)
        print(select_asset(data))
        sys.exit(0)
    except urllib.error.HTTPError as error:
        # Authentication/rate-limit/not-found responses cannot improve by
        # retrying the same unauthenticated request immediately.
        if 400 <= error.code < 500 or attempt == 3:
            print(f'Unauthenticated GitHub release query failed (HTTP {error.code})', file=sys.stderr)
            sys.exit(1)
    except (urllib.error.URLError, TimeoutError, OSError):
        if attempt == 3:
            print('Unauthenticated GitHub release query unavailable', file=sys.stderr)
            sys.exit(1)
    except (ValueError, TypeError):
        print('Unable to identify the latest llvm-mingw asset from GitHub metadata', file=sys.stderr)
        sys.exit(1)
    time.sleep(5 * (attempt + 1))
PYMINGWRELEASE
}

lite_verify_managed_build_tool_markers() {
  [[ -f /usr/local/cmake/.asset_url && -f /usr/local/ninja/.asset_url && -f /usr/local/nasm/.tag ]] || {
    echo "managed CMake/Ninja/NASM markers are missing; run $FFBUILD_CODE_ROOT/full/ffmpeg.sh tool" >&2
    return 1
  }
}

verify_managed_toolchain() {
  local marker="$LLVM_MINGW_ROOT/.asset_url" expected installed
  [[ -f "$marker" ]] || {
    echo "managed llvm-mingw missing; run $FFBUILD_CODE_ROOT/full/ffmpeg.sh tool" >&2
    return 1
  }
  if [[ "${TOOLCHAIN_REFRESH:-1}" == 0 ]]; then
    installed="$(<"$marker")" || return 1
    [[ -n "$installed" ]] || { echo 'managed llvm-mingw asset identity is empty' >&2; return 1; }
    local tool
    for tool in "$TARGET-clang" "$TARGET-clang++" llvm-ar llvm-ranlib llvm-strip; do
      [[ -x "$LLVM_MINGW_ROOT/bin/$tool" ]] || {
        echo "managed llvm-mingw tool missing: $tool" >&2
        return 1
      }
    done
    [[ -x "$LLVM_MINGW_ROOT/bin/$TARGET-windres" || -x "$LLVM_MINGW_ROOT/bin/llvm-windres" ]] || return 1
    [[ -x "$LLVM_MINGW_ROOT/bin/$TARGET-dlltool" || -x "$LLVM_MINGW_ROOT/bin/llvm-dlltool" ]] || return 1
    lite_verify_managed_build_tool_markers || return 1
    echo 'Reuse installed llvm-mingw by request (TOOLCHAIN_REFRESH=0); latest-release check skipped.'
    return 0
  fi
  expected="$(lite_latest_mingw_asset_url)" || {
    echo 'Unable to verify the latest llvm-mingw release; toolchain age is unknown, refusing to continue' >&2
    return 1
  }
  [[ -n "$expected" ]] || {
    echo 'Unable to verify the latest llvm-mingw release: empty asset identity, refusing to continue' >&2
    return 1
  }
  installed="$(<"$marker")" || { echo "Unable to read managed llvm-mingw marker: $marker" >&2; return 1; }
  [[ "$installed" == "$expected" ]] || {
    echo "llvm-mingw is stale; run $FFBUILD_CODE_ROOT/full/ffmpeg.sh tool" >&2
    return 1
  }
  lite_verify_managed_build_tool_markers
}
source_dir() {
  local dir
  dir="$(ffbuild_source_dir "$1")" || return 1
  [[ -d "$dir" && -e "$dir/.git" ]] || return 1
  printf '%s\n' "$dir"
}
need_repo() {
  source_dir "$1" >/dev/null || {
    echo "missing source repo: $1 under $SOURCE_ROOT (or legacy $ROOT); run ./ffmpeg.sh update first" >&2
    return 1
  }
}
normalize_version() {
  local repo="$1" tag="$2"
  case "$repo" in
    ffmpeg-source|nv-codec-headers) echo "${tag#n}" ;;
    *) echo "${tag#v}" ;;
  esac
}
lite_verify_source_clean() {
  ffbuild_verify_source_clean "$1" || return 1
  lite_cache_python clean-source "$1"
}

lite_latest_upstream_ref() {
  local name="$1" url="${URLS[$1]}" regex="${TAG_REGEX[$1]}" listing selected sha ref peeled branch
  if [[ "$name" == ffmpeg-source ]]; then
    ref="$FFMPEG_REF"
    git check-ref-format --branch "$ref" >/dev/null || return 1
    listing="$(git_retry git ls-remote --heads "$url" "refs/heads/$ref")" || return 1
    while IFS=$'\t' read -r sha branch; do
      if [[ "$branch" == "refs/heads/$ref" && "$sha" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
        printf 'branch\t%s\t%s\t%s\n' "$ref" "$sha" "$sha"
        return 0
      fi
    done <<< "$listing"
    echo "official upstream branch not found: $name $ref" >&2
    return 1
  fi
  # Resolve freshness only from the configured official URL, never local tags
  # or a user-owned origin. Annotated tag objects and peeled commits both matter.
  listing="$(git_retry git ls-remote --tags "$url")" || return 1
  selected="$(
    while IFS=$'\t' read -r sha ref; do
      [[ "$ref" == refs/tags/* && "$ref" != *'^{}' && "$sha" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || continue
      ref="${ref#refs/tags/}"
      if [[ "$ref" =~ $regex ]]; then printf '%s\t%s\t%s\n' "$(normalize_version "$name" "$ref")" "$ref" "$sha"; fi
    done <<< "$listing" | sort -V | tail -n 1
  )" || return 1
  if [[ -n "$selected" ]]; then
    IFS=$'\t' read -r branch ref sha <<< "$selected"
    git check-ref-format "refs/tags/$ref" || return 1
    peeled="$sha"
    while IFS=$'\t' read -r branch selected; do
      [[ "$selected" != "refs/tags/$ref^{}" ]] || { peeled="$branch"; break; }
    done <<< "$listing"
    [[ "$peeled" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]] || return 1
    printf 'tag\t%s\t%s\t%s\n' "$ref" "$sha" "$peeled"
    return 0
  fi
  listing="$(git_retry git ls-remote --heads "$url")" || return 1
  for branch in stable master main; do
    [[ "$regex" == *"$branch"* ]] || continue
    while IFS=$'\t' read -r sha ref; do
      if [[ "$ref" == "refs/heads/$branch" && "$sha" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
        printf 'branch\t%s\t%s\t%s\n' "$branch" "$sha" "$sha"
        return 0
      fi
    done <<< "$listing"
  done
  echo "no official stable tag/branch matched for $name" >&2
  return 1
}

latest_stable_tag() {
  local selected kind ref rest
  selected="$(lite_latest_upstream_ref "$1")" || return 1
  IFS=$'\t' read -r kind ref rest <<< "$selected"
  printf '%s\n' "$ref"
}

clone_if_missing() {
  local name="$1" selection="${2:-}" dir kind ref expected commit attempt temporary actual
  dir="$(ffbuild_source_dir "$name")" || return 1
  if [[ -e "$dir" || -L "$dir" ]]; then
    [[ -d "$dir" && -e "$dir/.git" ]] || {
      echo "invalid source repo: $dir; refusing to delete or reclone it" >&2; return 1;
    }
    lite_verify_source_clean "$dir"
    return $?
  fi
  [[ -n "$selection" ]] || selection="$(lite_latest_upstream_ref "$name")" || return 1
  IFS=$'\t' read -r kind ref expected commit <<< "$selection"
  mkdir -p "$(dirname "$dir")" || return 1
  for attempt in 1 2 3 4; do
    temporary="$(mktemp -d "$(dirname "$dir")/.$name.clone.XXXXXXXX")" || return 1
    echo "===> clone $name $ref into independent directory $temporary"
    if git clone --filter=blob:none --no-tags --single-branch --branch "$ref" -- "${URLS[$name]}" "$temporary"; then
      actual="$(git -C "$temporary" rev-parse HEAD)" || return 1
      [[ "$actual" == "$commit" ]] || {
        echo "upstream changed during clone; preserving new attempt $temporary" >&2; return 1;
      }
      if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        mv -T -n -- "$temporary" "$dir" || return 1
        [[ -e "$temporary" ]] || return 0
      fi
      echo "clone destination appeared; preserving it and new attempt $temporary" >&2
      return 1
    fi
    echo "clone failed; preserved attempt $temporary ($attempt/4)" >&2
    [[ "$attempt" == 4 ]] || sleep "$((attempt * 5))"
  done
  return 1
}

update_one() {
  local name="$1" dir selection kind ref expected expected_commit upstream_ref old actual
  dir="$(ffbuild_source_dir "$name")" || return 1
  if [[ -e "$dir" || -L "$dir" ]]; then lite_verify_source_clean "$dir" || return 1; fi
  selection="$(lite_latest_upstream_ref "$name")" || return 1
  IFS=$'\t' read -r kind ref expected expected_commit <<< "$selection"
  clone_if_missing "$name" "$selection" || return 1
  lite_verify_source_clean "$dir" || return 1
  case "$kind" in
    tag)
      upstream_ref="refs/tags/$ref"
      old="$(git -C "$dir" rev-parse --verify "$upstream_ref" 2>/dev/null || true)"
      [[ -z "$old" || "$old" == "$expected" ]] || {
        echo "local tag conflict preserved without force: $name $ref" >&2; return 1;
      } ;;
    branch) upstream_ref="refs/heads/$ref" ;;
    *) echo "invalid official ref selection for $name" >&2; return 1 ;;
  esac
  # No destination refspec, no auto-tags/submodule recursion, no force/prune:
  # transfer only the selected official ref into FETCH_HEAD before verification.
  git_retry git -C "$dir" fetch --no-auto-maintenance --no-tags --no-recurse-submodules "${URLS[$name]}" "$upstream_ref" || return 1
  actual="$(git -C "$dir" rev-parse --verify FETCH_HEAD)" || return 1
  [[ "$actual" == "$expected" ]] || {
    echo "official ref changed during fetch; local refs preserved: $name $ref" >&2; return 1;
  }
  actual="$(git -C "$dir" rev-parse --verify 'FETCH_HEAD^{commit}')" || return 1
  [[ "$actual" == "$expected_commit" ]] || {
    echo "official tag peel/commit mismatch: $name $ref" >&2; return 1;
  }
  lite_verify_source_clean "$dir" || return 1
  if [[ "$kind" == tag ]]; then
    if [[ -z "$old" ]]; then git -C "$dir" update-ref "$upstream_ref" "$expected" '' || return 1; fi
    git -C "$dir" switch --no-overwrite-ignore --detach "$upstream_ref" || return 1
  elif [[ "$name" == ffmpeg-source ]]; then
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$ref"; then
      git -C "$dir" merge-base --is-ancestor "refs/heads/$ref" "$expected_commit" || {
        echo "local FFmpeg branch diverged or is ahead; preserving $ref" >&2; return 1;
      }
      git -C "$dir" switch --no-overwrite-ignore "$ref" || return 1
      git -C "$dir" merge --ff-only --no-overwrite-ignore "$expected_commit" || return 1
    else
      git -C "$dir" switch --no-overwrite-ignore --no-track --create "$ref" "$expected_commit" || return 1
    fi
  else
    # Libraries published as rolling branches are detached at the authenticated
    # commit; user branches and remote-tracking refs remain untouched.
    git -C "$dir" switch --no-overwrite-ignore --detach "$expected_commit" || return 1
  fi
  actual="$(git -C "$dir" rev-parse HEAD)" || return 1
  [[ "$actual" == "$expected_commit" ]] || { echo "checkout commit changed unexpectedly: $name" >&2; return 1; }
  if [[ "$kind" == tag ]]; then
    actual="$(git -C "$dir" rev-parse --verify "$upstream_ref")" || return 1
    [[ "$actual" == "$expected" ]] || { echo "local tag changed during update: $name $ref" >&2; return 1; }
  fi
  git -c "remote.origin.url=${URLS[$name]}" -C "$dir" submodule update --init --recursive || return 1
  lite_verify_source_clean "$dir" || return 1
  echo "     -> $name $ref $expected_commit"
}

run_update() {
  local r dir repos=(ffmpeg-source "${STAGES[@]}")
  # Preflight every existing input before fetching or cloning any repository.
  for r in "${repos[@]}"; do
    [[ "$r" == "ffmpeg" ]] && continue
    dir="$(ffbuild_source_dir "$r")" || return 1
    if [[ -e "$dir" || -L "$dir" ]]; then
      lite_verify_source_clean "$dir" || return 1
    fi
  done
  for r in "${repos[@]}"; do
    [[ "$r" == "ffmpeg" ]] && continue
    update_one "$r" || return 1
  done
  echo "== Source version manifest =="
  for r in "${repos[@]}"; do
    [[ "$r" == "ffmpeg" ]] && continue
    dir="$(source_dir "$r")" || return 1
    printf '%-24s ref=%-20s commit=%s\n' "$r" \
      "$(git -C "$dir" describe --tags --always)" \
      "$(git -C "$dir" rev-parse --short=12 HEAD)"
  done
}
meson_quote_array() {
  local flags="$1" arr=() f first=1
  read -r -a arr <<< "$flags"
  printf '['
  for f in "${arr[@]}"; do
    [[ -z "$f" ]] && continue
    f="${f//\\/\\\\}"; f="${f//\'/\\\'}"
    [[ "$first" -eq 0 ]] && printf ', '
    printf "'%s'" "$f"
    first=0
  done
  printf ']'
}
write_meson_cross() {
  local meson_lto=false meson_lto_mode=default cross="$BUILDROOT/mingw-cross.txt" pending
  if [[ "$LTO_ENABLE" == "1" ]]; then meson_lto=true; meson_lto_mode=thin; fi
  lite_assert_generated_file "$cross" || return 1
  lite_assert_generated_directory "$(lite_cache_root)" || return 1
  mkdir -p "$(lite_cache_root)" || return 1
  pending="$(mktemp "$(lite_cache_root)/.mingw-cross.XXXXXX")" || return 1
  cat > "$pending" <<EOF || return 1
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
windres = '$WINDRES'
pkg-config = '$PKG_CONFIG'

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
  if [[ -f "$cross" ]] && cmp -s -- "$pending" "$cross"; then
    rm -f -- "$pending"
    return 0
  fi
  lite_cache_python backup "$(lite_cache_root)/retained-products" meson-cross "$cross" || return 1
  mv -- "$pending" "$cross"
}
setup_build_env() {
  export PATH="$LLVM_MINGW_ROOT/bin:/usr/local/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"
  need_cmd git; need_cmd cmake; need_cmd meson; need_cmd ninja; need_cmd make; need_cmd pkg-config; need_cmd python3
  verify_managed_toolchain || return 1
  CC="$(canonical_tool "${CC:-$TARGET-clang}")" || return 1
  CXX="$(canonical_tool "${CXX:-$TARGET-clang++}")" || return 1
  AR="$(canonical_tool "${AR:-llvm-ar}")" || return 1
  RANLIB="$(canonical_tool "${RANLIB:-llvm-ranlib}")" || return 1
  STRIP="$(canonical_tool "${STRIP:-llvm-strip}")" || return 1
  WINDRES="$(first_tool "${WINDRES:-$TARGET-windres}" llvm-windres)" || return 1
  DLLTOOL="$(first_tool "${DLLTOOL:-$TARGET-dlltool}" llvm-dlltool)" || return 1
  PKG_CONFIG="$(canonical_tool "${PKG_CONFIG:-pkg-config}")" || return 1

  local opt="$OPT_CFLAGS_BASE $CPU_FLAGS -ffunction-sections -fdata-sections"
  local ld="-static -Wl,--gc-sections -fuse-ld=lld"
  if [[ "$LTO_ENABLE" == "1" ]]; then
    opt+=" $LTO_FLAGS"
    ld+=" $LTO_FLAGS"
  fi
  if [[ "$CFG_ENABLE" == "1" ]]; then
    opt+=" -mguard=cf"
    ld+=" -Wl,/guard:cf"
  fi
  export CC CXX AR RANLIB STRIP WINDRES DLLTOOL PKG_CONFIG
  export CFLAGS="${CFLAGS:-$opt}"
  export CXXFLAGS="${CXXFLAGS:-$opt}"
  export LDFLAGS="${LDFLAGS:-$ld}"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

  mkdir -p "$BUILDROOT" "$PREFIX"
  write_meson_cross
}
stage_src() {
  local name="$1" src pending
  if [[ "${LITE_ACTIVE_SOURCE_NAME:-}" == "$name" && -n "${LITE_ACTIVE_STAGE:-}" ]]; then
    printf '%s\n' "$LITE_ACTIVE_STAGE"
    return 0
  fi
  src="$(source_dir "$name")" || { need_repo "$name"; return 1; }
  lite_assert_generated_directory "$BUILDROOT" || return 1
  ffbuild_assert_staging_path "$BUILDROOT" "$BUILDROOT/_src/$name" "$src" || return 1
  lite_assert_generated_directory "$(lite_cache_root)" || return 1
  mkdir -p "$(lite_cache_root)" || return 1
  pending="$(mktemp "$(lite_cache_root)/.$name.standalone.XXXXXX")" || return 1
  lite_cache_python snapshot "$src" "$pending" >/dev/null || return 1
  lite_cache_python stage "$src" "$BUILDROOT/_src/$name" "$pending" /dev/null 0 '' \
    "$(lite_cache_root)/retained-git" || return 1
  rm -f -- "$pending"
}

lite_assert_installed_copy() {
  local built="$1" installed="$2"
  [[ -s "$built" && -s "$installed" ]] && cmp -s -- "$built" "$installed" || {
    echo "installed artifact is not the current build output: $installed (expected $built)" >&2
    return 1
  }
}

lite_build_directory() {
  if [[ -n "${LITE_ACTIVE_BUILD_DIR:-}" ]]; then
    printf '%s\n' "$LITE_ACTIVE_BUILD_DIR"
  else
    ffbuild_cache_build_dir "$BUILDROOT/$1" "$(ffbuild_cache_hash "$BACKEND-standalone" "$1" "$(date +%s%N)" "$BASHPID")"
  fi
}
build_cmake() {
  local name="$1" stage bld ipo=OFF
  shift
  stage="$(stage_src "$name")" || return 1
  if [[ "$name" == "libvpl" ]]; then
    local vpl_defs="$stage/libvpl/src/windows/mfx_dispatcher_defs.h"
    python3 -I - "$vpl_defs" <<'PYVPLMINGW' || return 1
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
  bld="$(lite_build_directory "$name")" || return 1
  [[ "$LTO_ENABLE" == "1" ]] && ipo=ON
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
    "$@" || return 1
  cmake --build "$bld" --parallel "$JOBS" || return 1
  cmake --install "$bld" || return 1
  case "$name" in
    libsoxr)
      lite_assert_installed_copy "$bld/src/libsoxr.a" "$PREFIX/lib/libsoxr.a" || return 1
      lite_assert_installed_copy "$stage/src/soxr.h" "$PREFIX/include/soxr.h" || return 1 ;;
    libvpl)
      lite_assert_installed_copy "$bld/libvpl.a" "$PREFIX/lib/libvpl.a" || return 1
      lite_assert_installed_copy "$stage/api/vpl/mfx.h" "$PREFIX/include/vpl/mfx.h" || return 1 ;;
  esac
}
build_opus() {
  local stage
  stage="$(stage_src opus)" || return 1
  pushd "$stage" >/dev/null || return 1
  if [[ ! -x ./configure ]]; then
    if [[ -x ./autogen.sh ]]; then
      sed -i '/dnn\/download_model\.sh/d' ./autogen.sh || return 1
      ./autogen.sh || return 1
    else
      autoreconf -fiv || return 1
    fi
  fi
  CPPFLAGS="-I$PREFIX/include" \
  LDFLAGS="$LDFLAGS -L$PREFIX/lib" \
  ./configure \
    --host="$TARGET" \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --disable-extra-programs \
    --disable-deep-plc \
    --disable-dred \
    --disable-osce || return 1
  make -j"$JOBS" || return 1
  make -j"$JOBS" install || return 1
  lite_assert_installed_copy "$stage/.libs/libopus.a" "$PREFIX/lib/libopus.a" || return 1
  lite_assert_installed_copy "$stage/include/opus.h" "$PREFIX/include/opus/opus.h" || return 1
  popd >/dev/null || return 1
  [[ -f "$PREFIX/lib/pkgconfig/opus.pc" && -f "$PREFIX/include/opus/opus.h" && -f "$PREFIX/lib/libopus.a" ]] || {
    echo "libopus static install is incomplete"
    exit 1
  }
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    "$PKG_CONFIG" --exists opus || { echo "pkg-config cannot find target libopus"; exit 1; }
  [[ "$("$PKG_CONFIG" --variable=prefix opus)" == "$PREFIX" ]] || {
    echo "pkg-config resolved libopus outside the Lite PREFIX"
    exit 1
  }
}
have_config_item() {
  local ff_stage="$1" list_cmd="$2" name="$3"
  "$ff_stage/configure" "$list_cmd" | tr '[:space:]' '\n' | grep -Fx "$name" >/dev/null
}
add_if_exists() {
  local ff_stage="$1" list_cmd="$2" name="$3" flag="$4"
  if have_config_item "$ff_stage" "$list_cmd" "$name"; then
    configure_cmd+=("$flag=$name")
  else
    SKIPPED_ITEMS+=("$name ($list_cmd)")
    echo "WARNING: $name not found in $list_cmd, skipping"
  fi
}
find_cuda_home() {
  if [[ -n "${CUDA_HOME:-}" && -f "$CUDA_HOME/include/cuda.h" ]]; then return 0; fi
  if [[ -d /usr/local/cuda && -f /usr/local/cuda/include/cuda.h ]]; then CUDA_HOME=/usr/local/cuda; return 0; fi
  local latest
  latest="$(find /usr/local -maxdepth 1 -type d -name 'cuda-*' 2>/dev/null | sort -V | tail -n 1 || true)"
  [[ -n "$latest" && -f "$latest/include/cuda.h" ]] && { CUDA_HOME="$latest"; return 0; }
  echo "CUDA toolkit not found. Set CUDA_HOME=/usr/local/cuda or install cuda-toolkit."
  exit 1
}
setup_cuda() {
  [[ "$BACKEND" == "nvenc" && "$CUDA_ENABLE" == "1" ]] || return 0
  find_cuda_home
  export CUDA_HOME PATH="$CUDA_HOME/bin:$PATH"
  NVCC="$(canonical_tool "${NVCC:-$CUDA_HOME/bin/nvcc}")"
  "$NVCC" --version >/dev/null
  export NVCC
}
make_nvccflags() {
  local flags="$NVCC_GENCODE_FLAGS $NVCC_OPTFLAGS"
  [[ -n "$NVCC_THREADS" ]] && flags+=" --threads=$NVCC_THREADS"
  [[ -n "$NVCC_PTXAS_FLAGS" ]] && flags+=" -Xptxas=$NVCC_PTXAS_FLAGS"
  [[ "$NVCC_FAST_MATH" == "1" ]] && flags+=" --use_fast_math"
  printf '%s\n' "$flags"
}
write_soxr_pc() {
  mkdir -p "$PREFIX/lib/pkgconfig"
  cat > "$PREFIX/lib/pkgconfig/soxr.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: soxr
Description: SoX Resampler library
Version: 0.1.3
Libs: -L\${libdir} -lsoxr
Cflags: -I\${includedir}
EOF
}
write_shaderc_pc() {
  local combined="$PREFIX/lib/pkgconfig/shaderc_combined.pc" target="$PREFIX/lib/pkgconfig/shaderc.pc"
  [[ -s "$combined" && ! -L "$combined" && ! -L "$target" ]] || {
    echo 'shaderc requires regular upstream-generated static combined pkg-config metadata' >&2
    return 1
  }
  # Keep the source-derived version instead of a stale hard-coded release number.
  cmp -s "$combined" "$target" || cp -p -- "$combined" "$target"
}
seed_shaderc_from_common() {
  # Full and Lite have different configuration/toolchain/prefix identities.
  # There is no certified cross-profile export contract: presence, version and
  # an archive hash alone cannot establish ABI/dependency equivalence.
  echo 'Full shaderc seed disabled: no complete cross-profile identity certificate' >&2
  return 1
}
# This verifier only parses data; never exec() a checkout's DEPS file. Keep it
# independent of Lite globals so the shared cache can use the same contract.
ffbuild_lite_shaderc_deps_key() { ffbuild_cache_shaderc_deps_key "$@"; }

shaderc_dependencies_ready() {
  ffbuild_lite_shaderc_deps_key "$1" >/dev/null
}

prepare_shaderc_dependencies() {
  local stage="$1"
  lite_assert_generated_path "$stage" || return 1
  shaderc_dependencies_ready "$stage" 2>/dev/null && return 0
  # Shared pin synchronization refuses dirty/wrong existing checkouts. Optional
  # verified source seeds supply independent Git clones, never compiled products.
  # No upstream git-sync-deps (which rewrites remotes/checkouts) is executed.
  ffbuild_cache_shaderc_sync_deps "$stage" "$BUILDROOT" >/dev/null || return 1
  shaderc_dependencies_ready "$stage"
}

host_glslc_version() {
  local tool="$1" magic version
  [[ -x "$tool" ]] || return 1
  magic="$(head -c 2 -- "$tool")" || return 1
  # WSL can execute PE programs, but a target Windows glslc is not a host tool.
  [[ "$magic" != MZ ]] || return 1
  version="$("$tool" --version 2>/dev/null)" || return 1
  [[ "$version" == *shaderc* || "$version" == *glslc* ]] || return 1
  printf '%s\n' "$version"
}

lite_host_toolchain_key() (
  unset CC CXX AR RANLIB STRIP RC WINDRES DLLTOOL PKG_CONFIG NVCC CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR CMAKE_TOOLCHAIN_FILE CMAKE_PREFIX_PATH CMAKE_FIND_ROOT_PATH
  unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH SYSROOT CMAKE_SYSROOT
  unset LLVM_MINGW_ROOT CPU_FLAGS LTO_ENABLE LTO_FLAGS CFG_ENABLE CUDA_ENABLE CUDA_HOME
  unset NVCC_GENCODE_FLAGS NVCC_OPTFLAGS NVCC_THREADS NVCC_PTXAS_FLAGS NVCC_FAST_MATH
  CC=/usr/bin/cc CXX=/usr/bin/c++ AR=/usr/bin/ar RANLIB=/usr/bin/ranlib STRIP=/usr/bin/strip
  TARGET="$(uname -m)-$(uname -s)" PREFIX="$HOST_TOOLS"
  ffbuild_cache_toolchain_key
)

host_glslc_source_stamp() {
  local source key="${LITE_HOST_TOOLCHAIN_KEY:-}"
  source="$(source_dir libshaderc)" || return 1
  [[ -n "$key" ]] || key="$(lite_host_toolchain_key)" || return 1
  ffbuild_cache_hash "$BACKEND-lite-host-glslc" "$(lite_stage_source_key "$source" host-glslc)" "$key"
}

build_host_glslc_from_source() {
  local stage="$1" bld version stamp
  bld="$(lite_build_directory host-glslc)" || return 1
  local host_env=(env -u CC -u CXX -u AR -u RANLIB -u STRIP -u RC -u WINDRES -u DLLTOOL \
    -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR \
    -u CMAKE_TOOLCHAIN_FILE -u CMAKE_PREFIX_PATH -u CMAKE_FIND_ROOT_PATH -u SYSROOT -u CMAKE_SYSROOT \
    -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH -u LIBRARY_PATH -u PKG_CONFIG_SYSROOT_DIR)
  lite_assert_generated_directory "$HOST_TOOLS" || return 1
  lite_assert_generated_directory "$HOST_TOOLS/bin" || return 1
  lite_assert_generated_file "$HOST_TOOLS/bin/glslc" || return 1
  prepare_shaderc_dependencies "$stage" || return 1
  "${host_env[@]}" cmake -S "$stage" -B "$bld" -G Ninja \
    -DCMAKE_C_COMPILER=/usr/bin/cc \
    -DCMAKE_CXX_COMPILER=/usr/bin/c++ \
    -DCMAKE_AR=/usr/bin/ar \
    -DCMAKE_RANLIB=/usr/bin/ranlib \
    -DCMAKE_BUILD_TYPE=Release \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_ENABLE_EXECUTABLES=ON \
    -DSHADERC_ENABLE_INSTALL=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 || return 1
  "${host_env[@]}" cmake --build "$bld" --target glslc_exe --parallel "$JOBS" || return 1
  version="$(host_glslc_version "$bld/glslc/glslc")" || {
    echo "native glslc build did not produce a usable host executable" >&2
    return 1
  }
  stamp="$(host_glslc_source_stamp)" || return 1
  mkdir -p "$HOST_TOOLS/bin" || return 1
  cp -f "$bld/glslc/glslc" "$HOST_TOOLS/bin/glslc" || return 1
  chmod +x "$HOST_TOOLS/bin/glslc" || return 1
  printf '%s\n%s\n' "$stamp" "$version" > "$HOST_TOOLS/.glslc-stamp"
}

ensure_host_glslc() {
  if [[ "$HOST_GLSLC" != "$HOST_TOOLS/bin/glslc" ]]; then
    host_glslc_version "$HOST_GLSLC" >/dev/null || {
      echo "HOST_GLSLC is not a usable native host glslc: $HOST_GLSLC" >&2
      return 1
    }
    return 0
  fi
  if [[ "${LITE_CACHE_LOCKED:-0}" != 1 ]]; then
    lite_assert_generated_directory "$BUILDROOT" || return 1
    lite_cache_lock ensure_host_glslc
  else
    lite_run_stage_cached host-glslc
  fi
}
build_shaderc_from_source() {
  local stage bld
  stage="$(stage_src libshaderc)" || return 1
  # No uncertified Full target seed or host tool crosses this profile boundary.
  prepare_shaderc_dependencies "$stage" || return 1
  bld="$(lite_build_directory libshaderc)" || return 1
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
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHADERC_SKIP_TESTS=ON \
    -DSHADERC_SKIP_EXAMPLES=ON \
    -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSPIRV_SKIP_EXECUTABLES=ON \
    -DENABLE_GLSLANG_BINARIES=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 || return 1
  cmake --build "$bld" --parallel "$JOBS" || return 1
  cmake --install "$bld" || return 1
  [[ -s "$bld/libshaderc/libshaderc_combined.a" ]] || { echo 'shaderc combined archive was not built' >&2; return 1; }
  cp -f "$bld/libshaderc/libshaderc_combined.a" "$PREFIX/lib/" || return 1
  [[ -d "$stage/third_party/spirv-headers/include/spirv" ]] || { echo "shaderc SPIR-V headers missing"; return 1; }
  cp -a "$stage/third_party/spirv-headers/include/spirv" "$PREFIX/include/" || return 1
  write_shaderc_pc
}
patch_ffmpeg_libplacebo_vulkan_import() {
  local ff_stage="$1" cfg="$PREFIX/include/libplacebo/config.h" api
  sed -i 's/-lstdc++/-lc++/g' "$ff_stage/configure"
  [[ -f "$cfg" ]] || return 0
  api="$(sed -n 's/^#define PL_API_VER[[:space:]]\+\([0-9]\+\).*/\1/p' "$cfg" | head -n1)"
  [[ -n "$api" ]] || return 0
  if (( api >= 365 )); then return 0; fi
  echo "Patch FFmpeg Vulkan queue import for libplacebo API $api"
  perl -0pi -e 's/#ifdef VK_KHR_internally_synchronized_queues\n([[:space:]]*\{ VK_KHR_INTERNALLY_SYNCHRONIZED_QUEUES_EXTENSION_NAME,[[:space:]]*FF_VK_EXT_INTERNAL_QUEUE_SYNC[[:space:]]*\},\n)#endif/#if 0 \&\& defined(VK_KHR_internally_synchronized_queues)\n$1#endif/g' \
    "$ff_stage/libavutil/hwcontext_vulkan.c" \
    "$ff_stage/libavutil/vulkan_loader.h"
}
validate_config() {
  local config_mak="$1" config_h="$2" ff_stage="${3:-.}" unexpected allowed filter_line filter_name filter_lower f found feature
  python3 -I "$FFBUILD_CODE_ROOT/scripts/lib/feature_policy.py" check-config "$config_mak" || return 1
  local allowed_filters=("${COMMON_FILTERS[@]}")
  if [[ "$BACKEND" == "nvenc" ]]; then
    allowed_filters+=("${NVENC_FILTERS[@]}")
  else
    allowed_filters+=("${QSV_FILTERS[@]}")
  fi
  [[ "$LTO_ENABLE" != "1" ]] || grep -Eq -- '-flto(=thin|=auto)?' "$config_mak" || { echo "LTO not found in config.mak"; exit 1; }
  grep -q '^CONFIG_AAC_ENCODER=yes$' "$config_mak" || { echo "native AAC encoder disabled"; exit 1; }
  grep -q '^CONFIG_LIBOPUS=yes$' "$config_mak" || { echo "libopus disabled"; exit 1; }
  grep -q '^CONFIG_LIBOPUS_ENCODER=yes$' "$config_mak" || { echo "libopus encoder disabled"; exit 1; }
  grep -q '^CONFIG_OPUS_DECODER=yes$' "$config_mak" || { echo "native Opus decoder disabled"; exit 1; }
  grep -q '^CONFIG_LIBSOXR=yes$' "$config_mak" || { echo "libsoxr disabled"; exit 1; }
  grep -q '^CONFIG_ARESAMPLE_FILTER=yes$' "$config_mak" || { echo "aresample filter disabled"; exit 1; }
  grep -q '^CONFIG_LIBPLACEBO_FILTER=yes$' "$config_mak" || { echo "libplacebo filter disabled"; exit 1; }
  grep -q "^CONFIG_AVS_DECODER=yes$" "$config_mak" || { echo "native AVS decoder disabled"; exit 1; }
  grep -q "^CONFIG_CAVS_DECODER=yes$" "$config_mak" || { echo "native CAVS decoder disabled"; exit 1; }
  grep -q "^CONFIG_CAVSVIDEO_PARSER=yes$" "$config_mak" || { echo "native CAVS parser disabled"; exit 1; }
  for feature in CONFIG_LIBDAVS2_DECODER CONFIG_LIBUAVS3D_DECODER CONFIG_LIBXAVS_ENCODER CONFIG_LIBXAVS2_ENCODER; do
    if grep -q "^$feature=yes$" "$config_mak"; then echo "External AVS2/3 decoder or AVS encoder unexpectedly enabled: $feature"; exit 1; fi
  done
  grep -q '^CONFIG_VULKAN=yes$' "$config_mak" || { echo "Vulkan disabled"; exit 1; }
  for feature in CONFIG_HEVC_DECODER CONFIG_AV1_DECODER CONFIG_DOVI_RPUDEC CONFIG_DOVI_RPUENC CONFIG_DOVI_RPU_BSF CONFIG_DOVI_SPLIT_BSF CONFIG_MOV_DEMUXER CONFIG_MOV_MUXER CONFIG_MATROSKA_DEMUXER CONFIG_MATROSKA_MUXER CONFIG_MPEGTS_DEMUXER CONFIG_MPEGTS_MUXER; do
    grep -q "^$feature=yes$" "$config_mak" || { echo "Dolby Vision feature disabled: $feature"; exit 1; }
  done
  grep -q 'ff_parse_itu_t_t35_to_dynamic_hdr_vivid' "$ff_stage/libavcodec/itut35.c" || { echo "FFmpeg mainline HDR Vivid T.35 parser is missing" >&2; exit 1; }
  grep -q 'AV_FRAME_DATA_DYNAMIC_HDR_VIVID' "$ff_stage/libavcodec/hevc/hevcdec.c" || { echo "FFmpeg HEVC HDR Vivid frame metadata path is missing" >&2; exit 1; }
  [[ -s "$PREFIX/lib/libshaderc_combined.a" && -d "$PREFIX/include/shaderc" ]] || { echo "libshaderc static library or headers missing"; exit 1; }
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" "$PKG_CONFIG" --exists shaderc || { echo "shaderc.pc is not usable"; exit 1; }

  if [[ "$BACKEND" == "nvenc" ]]; then
    grep -q '^CONFIG_AV1_NVENC_ENCODER=yes$' "$config_mak" || { echo "av1_nvenc disabled"; exit 1; }
    grep -q '^CONFIG_HEVC_NVENC_ENCODER=yes$' "$config_mak" || { echo "hevc_nvenc disabled"; exit 1; }
    grep -q '^CONFIG_CUDA_NVCC=yes$' "$config_mak" || { echo "cuda-nvcc disabled"; exit 1; }
    allowed='CONFIG_(HEVC_NVENC|AV1_NVENC|AAC|LIBOPUS|RAWVIDEO)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
    grep -q 'nonfree' "$config_h" || { echo "NVENC build is expected to be nonfree"; exit 1; }
  else
    grep -q '^CONFIG_AV1_QSV_ENCODER=yes$' "$config_mak" || { echo "av1_qsv disabled"; exit 1; }
    grep -q '^CONFIG_HEVC_QSV_ENCODER=yes$' "$config_mak" || { echo "hevc_qsv disabled"; exit 1; }
    grep -q '^CONFIG_LIBVPL=yes$' "$config_mak" || { echo "libvpl disabled"; exit 1; }
    allowed='CONFIG_(HEVC_QSV|AV1_QSV|AAC|LIBOPUS|RAWVIDEO)_ENCODER=yes|CONFIG_FRAME_THREAD_ENCODER=yes'
  fi
  unexpected="$(grep -E '^CONFIG_.*_ENCODER=yes$' "$config_mak" | grep -Ev "$allowed" || true)"
  [[ -z "$unexpected" ]] || { echo "unexpected encoders:"; printf '%s\n' "$unexpected"; exit 1; }
  if grep -q '^CONFIG_WRAPPED_AVFRAME_ENCODER=yes$' "$config_mak"; then
    echo "wrapped_avframe should stay disabled"
    exit 1
  fi

  while read -r filter_line; do
    [[ "$filter_line" =~ ^CONFIG_([A-Za-z0-9_]+)_FILTER=yes$ ]] || continue
    filter_name="${BASH_REMATCH[1]}"
    filter_lower="$(printf '%s' "$filter_name" | tr '[:upper:]' '[:lower:]')"
    found=0
    for f in "${allowed_filters[@]}"; do
      [[ "$f" == "$filter_lower" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || { echo "unexpected filter: $filter_lower"; exit 1; }
  done < "$config_mak"
}
is_system_dll() {
  local u="${1^^}"
  case "$u" in
    API-MS-WIN-*.DLL|EXT-MS-*.DLL|KERNEL32.DLL|NTDLL.DLL|UCRTBASE.DLL|MSVCRT.DLL|VCRUNTIME*.DLL) return 0 ;;
    USER32.DLL|GDI32.DLL|ADVAPI32.DLL|SHELL32.DLL|OLE32.DLL|OLEAUT32.DLL|COMDLG32.DLL|COMCTL32.DLL) return 0 ;;
    WS2_32.DLL|CRYPT32.DLL|BCRYPT.DLL|VERSION.DLL|SHLWAPI.DLL|SECUR32.DLL|IPHLPAPI.DLL|NCRYPT.DLL) return 0 ;;
    SETUPAPI.DLL|CFGMGR32.DLL|IMM32.DLL|WINMM.DLL|NORMALIZ.DLL|D3D*.DLL|DXGI.DLL|VULKAN-1.DLL) return 0 ;;
    NVCUDA.DLL|NVENCODEAPI64.DLL) return 0 ;;
  esac
  return 1
}
check_single_file_imports() {
  local exe="$1" dump imports bad dll
  dump="$(first_tool llvm-objdump "$TARGET-objdump" objdump)"
  imports="$($dump -p "$exe" 2>/dev/null | sed -n 's/^[[:space:]]*DLL Name: //p' | sort -fu)"
  bad=""
  while IFS= read -r dll; do
    [[ -z "$dll" ]] && continue
    is_system_dll "$dll" || bad+="$dll"$'\n'
  done <<< "$imports"
  if [[ -n "$bad" ]]; then
    echo "non-system DLL imports found:"
    printf '%s' "$bad"
    exit 1
  fi
  echo "DLL imports are system-only."
}
verify_lite_binary() {
  local exe="$1" output filters hwaccels decoders bsfs muxers placebo_help name
  local names=()
  output="$("$exe" -hide_banner -encoders 2>/dev/null | tr -d '\r')"
  mapfile -t names < <(awk '$1 ~ /^[VAS][A-Z.]{5}$/ && $2 != "=" { print $2 }' <<< "$output")
  for name in "${names[@]}"; do
    case "$BACKEND:$name" in
      nvenc:aac|nvenc:hevc_nvenc|nvenc:av1_nvenc|nvenc:libopus|nvenc:rawvideo|qsv:aac|qsv:hevc_qsv|qsv:av1_qsv|qsv:libopus|qsv:rawvideo) ;;
      *) echo "unexpected runtime encoder: $name"; exit 1 ;;
    esac
  done
  grep -q '[[:space:]]libopus[[:space:]]' <<< "$output" || { echo "libopus missing"; exit 1; }
  grep -q '[[:space:]]opus[[:space:]]' <<< "$("$exe" -hide_banner -decoders 2>/dev/null)" || { echo "native opus decoder missing"; exit 1; }
  grep -q 'nmr' <<< "$("$exe" -hide_banner -h encoder=aac 2>&1)" || { echo "NMR AAC coder missing"; exit 1; }
  placebo_help="$("$exe" -hide_banner -h filter=libplacebo 2>&1)"
  grep -q 'libplacebo' <<< "$placebo_help" || { echo "libplacebo filter help failed"; exit 1; }
  grep -q 'apply_dolbyvision' <<< "$placebo_help" || { echo "libplacebo Dolby Vision metadata application missing"; exit 1; }
  decoders="$("$exe" -hide_banner -decoders 2>/dev/null | tr -d '\r')"
  for name in hevc av1; do
    grep -Eq "[[:space:]]$name([[:space:]]|$)" <<< "$decoders" || { echo "Dolby Vision base codec decoder missing: $name"; exit 1; }
  done
  bsfs="$("$exe" -hide_banner -bsfs 2>/dev/null | tr -d '\r')"
  for name in dovi_rpu dovi_split; do
    grep -Eq "(^|[[:space:]])$name([[:space:]]|$)" <<< "$bsfs" || { echo "Dolby Vision bitstream filter missing: $name"; exit 1; }
  done
  muxers="$("$exe" -hide_banner -muxers 2>/dev/null | tr -d '\r')"
  for name in mov matroska; do
    grep -Eq "[[:space:]]$name([[:space:]]|$)" <<< "$muxers" || { echo "Dolby Vision container muxer missing: $name"; exit 1; }
  done
  filters="$("$exe" -hide_banner -filters 2>/dev/null | tr -d '\r')"
  for name in avs cavs; do
    grep -Eq "[[:space:]]$name([[:space:]]|$)" <<<"$decoders" || { echo "Native AVS1 decoder missing: $name"; exit 1; }
  done
  for name in libdavs2 libuavs3d; do
    if grep -Eq "[[:space:]]$name([[:space:]]|$)" <<<"$decoders"; then echo "External AVS2/3 decoder unexpectedly present: $name"; exit 1; fi
  done
  hwaccels="$("$exe" -hide_banner -hwaccels 2>/dev/null | tr -d '\r')"
  if [[ "$BACKEND" == "nvenc" ]]; then
    grep -q '[[:space:]]av1_nvenc[[:space:]]' <<< "$output" || { echo "av1_nvenc missing"; exit 1; }
    grep -Eq 'b_ref_mode|hierarchical.*[Bb]|[Bb].*hierarchical' <<< "$("$exe" -hide_banner -h encoder=av1_nvenc 2>&1)" || {
      echo "av1_nvenc hierarchical B-reference option missing"
      exit 1
    }
    grep -q '[[:space:]]scale_cuda[[:space:]]' <<< "$filters" || { echo "scale_cuda missing"; exit 1; }
    grep -qx 'cuda' <<< "$hwaccels" || { echo "CUDA hwaccel missing"; exit 1; }
  else
    grep -q '[[:space:]]av1_qsv[[:space:]]' <<< "$output" || { echo "av1_qsv missing"; exit 1; }
    grep -q '[[:space:]]scale_qsv[[:space:]]' <<< "$filters" || { echo "scale_qsv missing"; exit 1; }
    grep -Eq '^(d3d11va|dxva2)$' <<< "$hwaccels" || { echo "QSV Windows hwaccel missing"; exit 1; }
  fi
}
verify_opus_roundtrip() {
  local exe="$1" test_dir
  local input_file output_file decoded_file
  lite_assert_generated_directory "$BUILDROOT" || return 1
  mkdir -p "$BUILDROOT" || return 1
  test_dir="$(mktemp -d "$BUILDROOT/opus-validation.XXXXXX")" || return 1
  dd if=/dev/zero of="$test_dir/input.s16" bs=192000 count=1 status=none || return 1
  input_file="$test_dir/input.s16"
  output_file="$test_dir/test.ogg"
  decoded_file="$test_dir/decoded.ogg"
  # WSL 内调用 Windows FFmpeg 时，文件参数必须转换为 Windows 路径。
  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    input_file="$(wslpath -w "$input_file")"
    output_file="$(wslpath -w "$output_file")"
    decoded_file="$(wslpath -w "$decoded_file")"
  fi
  "$exe" -nostdin -hide_banner -loglevel error \
    -f s16le -ar 48000 -ac 2 -i "$input_file" \
    -c:a libopus -b:a 96k -ar 48000 -ac 2 -f ogg "$output_file" || return 1
  "$exe" -nostdin -hide_banner -loglevel error \
    -i "$output_file" -map 0:a:0 -c:a libopus -b:a 96k -ar 48000 -ac 2 -f ogg "$decoded_file" || return 1
  [[ -s "$test_dir/test.ogg" && -s "$test_dir/decoded.ogg" ]] || {
    echo "libopus encode/decode output is empty"
    exit 1
  }
  echo "Opus 48 kHz stereo encode/decode: OK"
}
run_build() {
  local generated
  for generated in "$PREFIX" "$BUILDROOT" "$HOST_TOOLS"; do
    lite_assert_generated_directory "$generated" || return 1
  done
  lite_assert_generated_file "$OUTPUT_DIR/ffmpeg.exe" || return 1
  lite_cache_lock lite_run_build_locked "$@"
}

lite_run_build_locked() {
  local s start="${1:-}" start_seen=0 found=0
  LITE_BUILD_MODE=full
  LITE_EVENT_ROWS=(); LITE_BUILT_STAGES=(); LITE_VALIDATED_STAGE=()
  LITE_FFMPEG_BUILT=0
  LITE_HOST_TOOLCHAIN_KEY=''
  BUILD_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ -n "$start" ]]; then
    LITE_BUILD_MODE=resume
    for s in "${STAGES[@]}"; do [[ "$s" != "$start" ]] || found=1; done
    [[ "$found" == 1 ]] || { echo "unknown stage: $start" >&2; return 1; }
  fi
  # Retiring this small certificate does not affect the content cache. A failed
  # attempt leaves old executables intact, but cannot present them as this run.
  lite_assert_generated_file "$OUTPUT_DIR/.ffbuild-current.json" || return 1
  lite_cache_python retire "$OUTPUT_DIR/.ffbuild-current.json" "$(lite_cache_root)/retained-products" || return 1
  setup_build_env || return 1
  [[ "$BACKEND" != nvenc ]] || setup_cuda || return 1
  LITE_TARGET_TOOLCHAIN_KEY="$(ffbuild_cache_toolchain_key)" || return 1
  need_repo ffmpeg-source || return 1
  mkdir -p "$PREFIX" "$OUTPUT_DIR" || return 1
  # Resume still verifies every prerequisite against this configuration. Stale
  # prerequisites are rebuilt, never silently linked from an unrelated PREFIX.
  for s in "${STAGES[@]}"; do
    if [[ -n "$start" && "$start_seen" == 0 ]]; then
      if [[ "$s" == "$start" ]]; then start_seen=1
      else echo "Validate resume prerequisite: $s"; fi
    fi
    [[ "$s" == ffmpeg ]] || need_repo "$s" || return 1
    run_stage "$s" || return 1
  done
  [[ "$(ffbuild_cache_toolchain_key)" == "$LITE_TARGET_TOOLCHAIN_KEY" ]] || {
    echo 'Lite target toolchain changed during the run; delivery is not certified' >&2; return 1;
  }
  if [[ -n "${LITE_HOST_TOOLCHAIN_KEY:-}" ]]; then
    [[ "$(lite_host_toolchain_key)" == "$LITE_HOST_TOOLCHAIN_KEY" ]] || {
      echo 'Lite native toolchain changed during the run; delivery is not certified' >&2; return 1;
    }
  fi
  echo "Built or content-verified: $OUTPUT_DIR/ffmpeg.exe"
  write_build_manifest || return 1
  if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
    echo "Skipped unsupported items:"
    printf ' - %s\n' "${SKIPPED_ITEMS[@]}"
  fi
}

lite_manifest_args() {
  local stage source
  args+=(--build-mode "${LITE_BUILD_MODE:-full}" --incremental-build 1 --ffmpeg-built "$LITE_FFMPEG_BUILT")
  for stage in "${LITE_BUILT_STAGES[@]}"; do args+=(--built-stage "$stage"); done
  for stage in "${STAGES[@]}"; do
    source="$(lite_state_get "$stage" stage)" || return 1
    [[ "$stage" != ffmpeg ]] || stage=ffmpeg-source
    args+=(--source-repo "$stage=$source")
  done
}

lite_finish_manifest() {
  lite_cache_python manifest "$1" "${LITE_BUILD_MODE:-full}" "$LITE_FFMPEG_BUILT" "${LITE_EVENT_ROWS[@]}" || return 1
  lite_cache_python link-manifest "$OUTPUT_DIR/.ffbuild-current.json" "$1"
}
# Libraries may be sourced for offline tests without executing a command.
lite_main() {
  local cmd="${1:-all}"
  if [[ $# -gt 0 ]]; then shift; fi
  trap on_error ERR
  case "$cmd" in
    all) run_update; run_build ;;
    build) run_build "${1:-}" ;;
    update) run_update ;;
    clean) run_clean ;;
    help|-h|--help) usage ;;
    *) usage; return 1 ;;
  esac
}
