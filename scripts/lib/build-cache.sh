#!/usr/bin/env bash
# Content-verified, target-scoped build-cache primitives. Sourcing is read-only.
# Records are data (JSON), never shell code. Callers include their target namespace
# and dependency identities in input/compatibility keys and hold a build lock.

ffbuild_cache_hash() {
  printf '%s\0' 'ffbuild-cache-v3' "$@" | sha256sum | cut -d ' ' -f 1
}

ffbuild_cache__python() {
  python3 -I - "$@" <<'PYFFBUILDCACHE'
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time

SCHEMA = 3

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()

def file_hash(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def entry(path, seen=None):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {'kind': 'missing'}
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        value = {'kind': 'link', 'target': os.readlink(path)}
        # A changed referent must not validate an otherwise unchanged symlink.
        if path.is_file():
            value['sha256'] = file_hash(path)
            value['size'] = path.stat().st_size
            value['mode'] = stat.S_IMODE(path.stat().st_mode)
        elif path.is_dir():
            value['referent'] = tree(path.resolve(), seen)
        elif not path.exists():
            value['broken'] = True
        return value
    if stat.S_ISREG(info.st_mode):
        return {'kind': 'file', 'mode': mode, 'size': info.st_size, 'sha256': file_hash(path)}
    if stat.S_ISDIR(info.st_mode):
        return {'kind': 'dir', 'mode': mode}
    raise ValueError(f'unsupported cache input: {path}')

def tree(path, seen=None):
    path = Path(path)
    seen = set() if seen is None else seen
    real = str(path.resolve())
    if real in seen:
        raise ValueError(f'cyclic directory symlink cache input: {path}')
    ancestors = seen | {real}
    values = {'.': entry(path, seen)}
    if path.is_dir() and not path.is_symlink():
        for base, dirs, files in os.walk(path, followlinks=False):
            dirs.sort()
            for name in sorted(dirs + files):
                child = Path(base) / name
                if name == '.git':
                    if name in dirs:
                        dirs.remove(name)
                    continue
                values[child.relative_to(path).as_posix()] = entry(child, ancestors)
    return values

def git(path, *args, check=True):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS='0')
    result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(path), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if check and result.returncode:
        raise ValueError(f'git {args[0]} failed for {path}: {result.stderr.decode(errors="replace").strip()}')
    return result.stdout

def source(path, extras=(), seen=None):
    path = Path(path).absolute()
    seen = set() if seen is None else seen
    real = str(path.resolve())
    if real in seen:
        raise ValueError(f'cyclic source/submodule: {path}')
    seen = seen | {real}
    if not path.is_dir():
        return {'missing': str(path)}
    if not os.path.lexists(path / '.git'):
        value = {'tree': tree(path)}
    else:
        top = git(path, 'rev-parse', '--show-toplevel').decode().strip()
        if Path(top).resolve() != path.resolve():
            raise ValueError(f'not an independent source repository: {path}')
        head = git(path, 'rev-parse', 'HEAD').decode().strip()
        files = git(path, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')
        values = {}
        for raw in sorted(set(files)):
            if not raw:
                continue
            relative = os.fsdecode(raw)
            target = path / relative
            if target.is_symlink():
                values[relative] = entry(target)
            elif target.is_dir() and os.path.lexists(target / '.git'):
                values[relative] = {'submodule': source(target, (), seen)}
            elif target.is_dir():
                # Uninitialized gitlinks are represented by HEAD's tree plus this
                # marker, rather than accidentally hashing a parent repository.
                values[relative] = {'kind': 'uninitialized-directory'}
            else:
                values[relative] = entry(target)
        value = {'head': head, 'index': hashlib.sha256(git(path, 'ls-files', '--stage', '-z')).hexdigest(),
                 'describe': git(path, 'describe', '--always', '--tags', '--long').decode().strip(),
                 'tags': hashlib.sha256(git(path, 'for-each-ref', '--format=%(refname):%(objectname)', 'refs/tags')).hexdigest(),
                 'files': values}
    value['extras'] = {str(item): source(path / item, (), seen) for item in extras}
    return value

def has_nonempty_file(values):
    for item in values.values():
        if item.get('size', 0) > 0 and item.get('sha256'):
            return True
        if item.get('referent') and has_nonempty_file(item['referent']):
            return True
    return False

def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True, separators=(',', ':'))
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def read_json(path):
    with open(path) as stream:
        return json.load(stream)

def record_hit(path, key):
    value = read_json(path)
    if value.get('schema') != SCHEMA or value.get('key') != key or not value.get('outputs'):
        return False
    for name, expected in value['outputs'].items():
        current = tree(name)
        if current != expected:
            return False
    return True

def build_dir(candidate, key):
    candidate = Path(candidate).absolute()
    index = Path(str(candidate) + '.ffbuild-directory.json')
    try:
        value = read_json(index)
        directory = Path(value['path'])
        marker = read_json(directory / '.ffbuild-directory.json')
        if (value.get('schema') == SCHEMA and value.get('key') == key and
                marker == value and directory.is_dir() and not directory.is_symlink() and
                not os.path.lexists(directory / '.git')):
            return str(directory)
    except (OSError, ValueError, KeyError, TypeError):
        pass
    candidate.parent.mkdir(parents=True, exist_ok=True)
    # Existing directories, including old unrecorded caches, are user data.
    # Never erase/rename them just because this helper cannot prove provenance.
    if not os.path.lexists(candidate):
        candidate.mkdir()
        directory = candidate
    else:
        directory = Path(tempfile.mkdtemp(prefix=candidate.name + '.ffbuild-', dir=candidate.parent))
    value = {'schema': SCHEMA, 'key': key, 'path': str(directory)}
    atomic_json(directory / '.ffbuild-directory.json', value)
    atomic_json(index, value)
    return str(directory)

def source_compat(path, extras):
    value = source(path, extras)
    reusable = {'.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.s', '.S', '.asm'}
    def normalize(item, filename=''):
        if isinstance(item, dict):
            result = {key: normalize(child, key) for key, child in item.items() if key not in {'head', 'index', 'describe'}}
            if Path(filename).suffix in reusable and result.get('kind') == 'file':
                result.pop('sha256', None)
                result.pop('size', None)
            return result
        return item
    normalized = normalize(value)
    if os.path.lexists(Path(path) / '.git'):
        # Submodule revision changes need a fresh independent copy; syncing a
        # parent gitlink must not leave an old child HEAD/version behind.
        normalized['gitlinks'] = [os.fsdecode(line) for line in git(path, 'ls-files', '--stage', '-z').split(b'\0') if line.startswith(b'160000 ')]
    return digest(normalized)

def source_entries(path):
    """Only source-owned paths; generated/ignored objects are never overwritten."""
    path = Path(path)
    result = {}
    if os.path.lexists(path / '.git'):
        files = git(path, 'ls-files', '--cached', '--others', '--exclude-standard', '-z').split(b'\0')
        for raw in sorted(set(files)):
            if not raw:
                continue
            name = os.fsdecode(raw)
            target = path / name
            if target.is_symlink():
                result[name] = entry(target)
            elif target.is_dir() and os.path.lexists(target / '.git'):
                for child, value in source_entries(target).items():
                    result[name + '/' + child] = value
            elif not target.is_dir():
                result[name] = entry(target)
    else:
        result = {name: value for name, value in tree(path).items() if name != '.' and value['kind'] != 'dir'}
    return result

def stage_git_state(path):
    if not os.path.lexists(Path(path) / '.git'):
        return None
    return {'head': git(path, 'rev-parse', 'HEAD').decode().strip(),
            'index': hashlib.sha256(git(path, 'ls-files', '--stage', '-z')).hexdigest(),
            'tags': hashlib.sha256(git(path, 'for-each-ref', '--format=%(refname):%(objectname)', 'refs/tags')).hexdigest()}

def stage_valid(value):
    stage = Path(value['path'])
    if value.get('schema') != SCHEMA or not value.get('success') or not stage.is_dir() or stage.is_symlink():
        return False
    if stage_git_state(stage) != value.get('git'):
        return False
    if source_entries(stage) != value.get('expected'):
        return False
    for relative, expected in value.get('extras', {}).items():
        if source(stage / relative) != expected:
            return False
    return True

def localize_gitfiles(stage, original):
    stage, original = Path(stage), Path(original)
    # Absolute source links must not keep pointing into canonical inputs after
    # copying. Localize internal links; reject external links rather than let a
    # patch/configure command write through them into the user's worktree.
    for base, dirs, files in os.walk(stage, followlinks=False):
        for name in dirs + files:
            child = Path(base) / name
            if not child.is_symlink():
                continue
            target = child.resolve()
            if target.is_relative_to(original.resolve()):
                target = stage / target.relative_to(original.resolve())
                child.unlink()
                child.symlink_to(os.path.relpath(target, child.parent))
            elif not target.is_relative_to(stage.resolve()):
                raise ValueError(f'external link in staged source: {child}')
    for base, dirs, files in os.walk(stage, followlinks=False):
        if '.git' in dirs:
            metadata_dir = Path(base) / '.git'
            if metadata_dir.is_symlink():
                raise ValueError(f'external staged Git metadata: {metadata_dir}')
            config = metadata_dir / 'config'
            if config.is_symlink():
                raise ValueError(f'external staged Git config: {config}')
            result = subprocess.run(['git', 'config', '--file', str(config), '--get', 'core.worktree'],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                worktree = (metadata_dir / result.stdout.decode().strip()).resolve()
                if worktree != Path(base).resolve():
                    raise ValueError(f'external staged core.worktree; provide an independent source copy: {metadata_dir}')
            dirs.remove('.git')
        if '.git' not in files:
            continue
        metadata = Path(base) / '.git'
        line = metadata.read_text().strip()
        if not line.startswith('gitdir: '):
            raise ValueError(f'invalid gitfile in staged source: {metadata}')
        target = (metadata.parent / line[8:]).resolve()
        if target.is_relative_to(original.resolve()):
            target = stage / target.relative_to(original.resolve())
            metadata.write_text('gitdir: ' + os.path.relpath(target, metadata.parent) + '\n')
        if not target.is_relative_to(stage.resolve()) or not target.is_dir():
            raise ValueError(f'staged gitfile references external metadata: {metadata}')
        config = target / 'config'
        if config.is_symlink():
            raise ValueError(f'external staged Git config: {config}')
        result = subprocess.run(['git', 'config', '--file', str(config), '--get', 'core.worktree'],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            worktree = (target / result.stdout.decode().strip()).resolve()
            if worktree != metadata.parent.resolve():
                raise ValueError(f'external staged core.worktree; provide an independent source copy: {metadata}')

def sync_source(original, stage, previous):
    original, stage = Path(original), Path(stage)
    current = source_entries(original)
    old = previous['source_files']
    expected = previous['expected']
    # Check every path BEFORE changing any path. Unknown collisions choose a new
    # tree rather than overwriting a user's staged edits, even for ignored files.
    for name in set(old) | set(current):
        target = stage / name
        if name in old:
            if entry(target) != expected.get(name, {'kind': 'missing'}):
                return False
        elif os.path.lexists(target):
            return False
        parent = target.parent
        while parent != stage:
            if parent.is_symlink():
                return False
            parent = parent.parent
    # Import commits without reset/checkout or changing canonical source bytes.
    # The index/HEAD were checked against the last successful staged snapshot.
    if os.path.lexists(original / '.git'):
        head = git(original, 'rev-parse', 'HEAD').decode().strip()
        git(stage, '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', 'fetch', '--no-tags',
            '--no-write-fetch-head', '--no-recurse-submodules', str(original), head)
        git(stage, 'update-ref', '--no-deref', 'HEAD', head)
        git(stage, 'read-tree', head)
    for name in sorted(set(old) - set(current), reverse=True):
        target = stage / name
        if target.is_file() or target.is_symlink():
            target.unlink()
    for name, desired in current.items():
        target = stage / name
        if entry(target) == desired:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            if target.is_dir() and not target.is_symlink():
                return False
            target.unlink()
        if desired['kind'] == 'missing':
            continue
        if desired['kind'] == 'link':
            target.symlink_to(os.readlink(original / name))
        else:
            shutil.copyfile(original / name, target)
            os.chmod(target, desired['mode'])
            # copy2 would preserve an old canonical mtime and make Ninja miss a
            # same-size source edit. Only changed contents receive a new mtime.
            now = time.time_ns()
            os.utime(target, ns=(now, now))
    localize_gitfiles(stage, original)
    return True

def prepare_stage(original, candidate, compat, allow_reuse, extras):
    original, candidate = Path(original).absolute(), Path(candidate).absolute()
    if os.path.lexists(original / '.git') and ((original / '.git').is_symlink() or not (original / '.git').is_dir()):
        raise ValueError(f'copy source with external root git metadata independently first: {original}')
    key = digest(source(original, extras))
    index = Path(str(candidate) + '.ffbuild-stage-index.json')
    try:
        previous = read_json(index)
        stage = Path(previous['path'])
        value = read_json(str(stage) + '.ffbuild-stage.json')
        if (previous == value and value.get('source') == str(original) and value.get('compat') == compat
                and stage_valid(value)):
            if value.get('source_key') == key:
                return str(stage)
            if allow_reuse == '1' and sync_source(original, stage, value):
                value.update(source_key=key, source_files=source_entries(original), success=False)
                atomic_json(str(stage) + '.ffbuild-stage.json', value)
                atomic_json(index, value)
                return str(stage)
    except (OSError, ValueError, KeyError, TypeError):
        pass
    candidate.parent.mkdir(parents=True, exist_ok=True)
    if not os.path.lexists(candidate):
        stage = candidate
    else:
        stage = Path(tempfile.mkdtemp(prefix=candidate.name + '.ffbuild-', dir=candidate.parent))
        # copytree below requires a fresh, empty destination, not an existing tree.
        stage.rmdir()
    shutil.copytree(original, stage, symlinks=True)
    localize_gitfiles(stage, original)
    value = {'schema': SCHEMA, 'source': str(original), 'candidate': str(candidate), 'path': str(stage), 'compat': compat,
             'source_key': key, 'source_files': source_entries(original), 'success': False,
             'extra_paths': list(extras)}
    atomic_json(str(stage) + '.ffbuild-stage.json', value)
    atomic_json(index, value)
    return str(stage)

def rotate_stage_dependencies(stage, exclusions):
    stage = Path(stage).absolute()
    value = read_json(str(stage) + '.ffbuild-stage.json')
    if value.get('schema') != SCHEMA or value.get('path') != str(stage):
        raise ValueError(f'unowned staged source: {stage}')
    candidate = Path(value['candidate'])
    replacement = Path(tempfile.mkdtemp(prefix=candidate.name + '.ffbuild-', dir=candidate.parent))
    replacement.rmdir()
    excluded = set(exclusions)
    def ignore(base, names):
        return [name for name in names if (Path(base) / name).relative_to(stage).as_posix() in excluded]
    shutil.copytree(stage, replacement, symlinks=True, ignore=ignore)
    localize_gitfiles(replacement, stage)
    value.update(path=str(replacement), success=False)
    atomic_json(str(replacement) + '.ffbuild-stage.json', value)
    atomic_json(str(candidate) + '.ffbuild-stage-index.json', value)
    return str(replacement)

def commit_stage(candidate):
    index = Path(str(candidate) + '.ffbuild-stage-index.json')
    value = read_json(index)
    stage = Path(value['path'])
    value.update(success=True, expected=source_entries(stage), git=stage_git_state(stage),
                 extras={name: source(stage / name) for name in value.get('extra_paths', [])})
    atomic_json(str(stage) + '.ffbuild-stage.json', value)
    atomic_json(index, value)
    return str(stage)

def toolchain(arguments):
    variables = dict(item.split('=', 1) for item in arguments)
    commands = ['CC', 'CXX', 'AR', 'RANLIB', 'STRIP', 'WINDRES', 'DLLTOOL', 'PKG_CONFIG', 'NVCC']
    tools = [variables.get(name, '') for name in commands]
    tools += ['cmake', 'meson', 'ninja', 'make', 'nasm', 'yasm', 'python3', 'autoconf', 'automake', 'libtoolize', 'ld', 'ld.lld']
    identities = {}
    directories = set()
    for command in tools:
        if not command:
            continue
        # Canonical compiler/tool paths may contain spaces; do not mistake a
        # single existing executable pathname for a launcher plus arguments.
        words = [command] if Path(command).is_file() else shlex.split(command)
        executable = shutil.which(words[0])
        if executable is None:
            identities[command] = {'missing': True}
            continue
        executable = str(Path(executable).resolve())
        try:
            version = subprocess.run([executable, *words[1:], '--version'], stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, timeout=15).stdout.decode(errors='replace')
        except (OSError, subprocess.TimeoutExpired) as error:
            version = str(error)
        identities[command] = {'path': executable, 'file': entry(Path(executable)), 'version': version}
        if command in [variables.get('CC'), variables.get('CXX')]:
            # Include the real headers/runtime, not merely a compiler --version.
            for option in ['-print-sysroot', '-print-resource-dir', '-print-file-name=include', '-print-file-name=include-fixed',
                           '-print-file-name=libgcc.a', '-print-file-name=libstdc++.a', '-print-file-name=libstdc++.so.6',
                           '-print-file-name=libgcc_s.so.1', '-print-file-name=libc.so.6', '-print-file-name=libm.so.6']:
                try:
                    result = subprocess.run([executable, *words[1:], option], stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, timeout=15)
                    answer = result.stdout.decode(errors='replace').strip()
                    if result.returncode == 0 and answer and Path(answer).is_absolute() and Path(answer).exists():
                        directories.add(answer)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            root = Path(executable).parent.parent
            target = variables.get('TARGET', '')
            for item in [root / target, root / 'generic-w64-mingw32', root / 'lib' / 'clang', root / 'include']:
                if item.is_dir():
                    directories.add(str(item))
    for name in ['SYSROOT', 'CMAKE_SYSROOT', 'CMAKE_TOOLCHAIN_FILE']:
        if variables.get(name) not in {None, '', '<unset>'}:
            directories.add(variables[name])
    for name in ['CUDA_HOME', 'CUDA_REDIST_ROOT']:
        if variables.get(name) in {None, '', '<unset>'}:
            continue
        cuda = Path(variables[name])
        for relative in ['include', 'nvvm/libdevice', 'bin/ptxas', 'bin/nvlink', 'bin/fatbinary']:
            item = cuda / relative
            if item.exists():
                directories.add(str(item))
        for pattern in ['lib64/libcuda*', 'lib64/libcudart*', 'lib64/libcudadevrt*', 'lib64/stubs/libcuda*']:
            directories.update(str(item) for item in cuda.glob(pattern))
    return {'schema': SCHEMA, 'variables': variables, 'tools': identities,
            'sysroots': {name: tree(name) for name in sorted(directories)}}

try:
    mode, *args = sys.argv[1:]
    if mode == 'source':
        print(digest(source(args[0], args[1:])))
    elif mode == 'source-compat':
        print(source_compat(args[0], args[1:]))
    elif mode == 'stage':
        print(prepare_stage(args[0], args[1], args[2], args[3], args[4:]))
    elif mode == 'stage-rotate-deps':
        print(rotate_stage_dependencies(args[0], args[1:]))
    elif mode == 'stage-commit':
        print(commit_stage(args[0]))
    elif mode == 'stage-valid':
        value = read_json(str(args[0]) + '.ffbuild-stage-index.json')
        sys.exit(0 if stage_valid(value) else 1)
    elif mode == 'stage-path':
        value = read_json(str(args[0]) + '.ffbuild-stage-index.json')
        print(value['path'])
    elif mode == 'stage-source-key':
        value = read_json(str(args[0]) + '.ffbuild-stage-index.json')
        print(value['source_key'])
    elif mode == 'tree':
        print(digest({str(Path(name).absolute()): tree(name) for name in args}))
    elif mode == 'toolchain':
        print(digest(toolchain(args)))
    elif mode == 'hit':
        sys.exit(0 if record_hit(args[0], args[1]) else 1)
    elif mode == 'commit':
        path, key, *outputs = args
        if not outputs:
            raise ValueError('a successful cache record requires installed outputs')
        values = {str(Path(name).absolute()): tree(name) for name in sorted(set(outputs))}
        for name, values_for_path in values.items():
            if values_for_path['.']['kind'] == 'missing':
                raise ValueError(f'missing installed output: {name}')
            if not has_nonempty_file(values_for_path):
                raise ValueError(f'empty installed output: {name}')
        atomic_json(path, {'schema': SCHEMA, 'key': key, 'outputs': values})
    elif mode == 'record-metadata':
        value = read_json(args[0])
        value['metadata'] = dict(zip(args[1::2], args[2::2]))
        atomic_json(args[0], value)
    elif mode == 'successful-stage':
        record, candidate, namespace = args
        value = read_json(record)
        metadata = value.get('metadata', {})
        stage_value = read_json(str(candidate) + '.ffbuild-stage-index.json')
        stage = Path(metadata['stage'])
        if (metadata.get('namespace') != namespace or stage_value['path'] != str(stage)
                or not record_hit(record, value['key']) or not stage_valid(stage_value)
                or metadata.get('commit') != git(stage, 'rev-parse', 'HEAD').decode().strip()
                or metadata.get('source_key') != digest(source(stage, stage_value.get('extra_paths', [])))):
            raise ValueError('successful stage provenance does not match installed outputs')
        print(stage)
    elif mode == 'directory':
        print(build_dir(args[0], args[1]))
    else:
        raise ValueError(f'unknown cache operation: {mode}')
except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
    if sys.argv[1] != 'hit':
        print(f'ffbuild cache: {error}', file=sys.stderr)
    sys.exit(1)
PYFFBUILDCACHE
}

ffbuild_cache_source_key() { ffbuild_cache__python source "$@"; }
ffbuild_cache_tree_key() { ffbuild_cache__python tree "$@"; }
ffbuild_cache_hit() { ffbuild_cache__python hit "$@"; }
ffbuild_cache_commit() { ffbuild_cache__python commit "$@"; }
ffbuild_cache_build_dir() { ffbuild_cache__python directory "$@"; }
ffbuild_cache_source_compat_key() { ffbuild_cache__python source-compat "$@"; }
ffbuild_cache_stage() { ffbuild_cache__python stage "$@"; }
ffbuild_cache_stage_commit() { ffbuild_cache__python stage-commit "$@"; }
ffbuild_cache_stage_valid() { ffbuild_cache__python stage-valid "$@"; }
ffbuild_cache_stage_path() { ffbuild_cache__python stage-path "$@"; }

ffbuild_cache_toolchain_key() {
  local name
  local -a values=()
  for name in TARGET BACKEND PREFIX BUILDROOT HOST_TOOLS TOOLCHAIN_FLAVOR TOOLCHAIN_ROOT LLVM_MINGW_ROOT \
    XPACK_MINGW_ROOT TOOLCHAIN_BIN CC CXX AR RANLIB STRIP WINDRES DLLTOOL PKG_CONFIG NVCC \
    CFLAGS CXXFLAGS CPPFLAGS LDFLAGS OPT_FLAGS CPU_FLAGS LTO_ENABLE LTO_FLAGS CFG_ENABLE \
    CUDA_ENABLE CUDA_HOME CUDA_REDIST_ROOT NVCC_GENCODE_FLAGS NVCC_OPTFLAGS \
    NVCC_PTXAS_FLAGS NVCC_FAST_MATH TOOLCHAIN_EXTRA_LIBS SYSROOT CMAKE_SYSROOT CMAKE_TOOLCHAIN_FILE \
    CMAKE_PREFIX_PATH CMAKE_FIND_ROOT_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
    CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH SDKROOT MACOSX_DEPLOYMENT_TARGET; do
    values+=("$name=${!name-<unset>}")
  done
  ffbuild_cache__python toolchain "${values[@]}"
}

ffbuild_cache_lock() (
  local lockfile="${1:?lock file required}"
  shift
  mkdir -p -- "$(dirname "$lockfile")" || exit 1
  command -v flock >/dev/null 2>&1 || { printf '%s\n' 'ffbuild cache requires flock' >&2; exit 1; }
  local lockfd
  if [[ -L "$lockfile" || ( -e "$lockfile" && ! -f "$lockfile" ) ]]; then
    printf '%s\n' "ffbuild cache lock is not a regular file: $lockfile" >&2
    exit 1
  fi
  # Append-open never truncates an existing file, even if a concurrent rename
  # races the conservative symlink check above.
  exec {lockfd}>>"$lockfile" || exit 1
  flock -x "$lockfd" || exit 1
  "$@"
)

# Shared, data-only DEPS parsing and controlled acquisition. Never execute a
# checkout's git-sync-deps; it can rewrite origin and existing worktrees.
ffbuild_cache__shaderc_python() {
  python3 -I - "$@" <<'PYSHADERCDEPS'
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

OFFICIAL = {
    'third_party/abseil_cpp': 'https://github.com/abseil/abseil-cpp.git',
    'third_party/effcee': 'https://github.com/google/effcee.git',
    'third_party/glslang': 'https://github.com/KhronosGroup/glslang.git',
    'third_party/googletest': 'https://github.com/google/googletest.git',
    'third_party/re2': 'https://github.com/google/re2.git',
    'third_party/spirv-headers': 'https://github.com/KhronosGroup/SPIRV-Headers.git',
    'third_party/spirv-tools': 'https://github.com/KhronosGroup/SPIRV-Tools.git',
}
TIMEOUT = 600

def git(path, *args, check=True):
    result = subprocess.run(['git', '-c', 'core.fsmonitor=false', '-C', str(path), *args],
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0'),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT)
    if check and result.returncode:
        raise ValueError(f'git {args[0]} failed for {path}: {result.stderr.decode(errors="replace").strip()}')
    return result.stdout.decode().strip(), result.returncode

def output(path, *args):
    return git(path, *args)[0]

def parse(root):
    values = {}
    def evaluate(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, (str, bool)):
            return node.value
        if isinstance(node, ast.Dict):
            result = {}
            for key, value in zip(node.keys, node.values):
                if key is None:
                    raise ValueError('DEPS dictionary expansion is not supported')
                key = evaluate(key)
                if key in result:
                    raise ValueError('duplicate shaderc DEPS dictionary key')
                result[key] = evaluate(value)
            return result
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            left, right = evaluate(node.left), evaluate(node.right)
            if isinstance(left, str) and isinstance(right, str):
                return left + right
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == 'Var' and len(node.args) == 1 and not node.keywords):
            result = values.get('vars', {})[evaluate(node.args[0])]
            if isinstance(result, str):
                return result
        raise ValueError('unsupported executable or nonliteral shaderc DEPS expression')
    deps_file = root / 'DEPS'
    if not deps_file.resolve().is_relative_to(root):
        raise ValueError('shaderc DEPS points outside its source tree')
    raw = deps_file.read_bytes()
    for statement in ast.parse(raw, filename=str(deps_file)).body:
        if not isinstance(statement, ast.Assign) or len(statement.targets) != 1:
            raise ValueError('shaderc DEPS must contain literal assignments only')
        target = statement.targets[0]
        if not isinstance(target, ast.Name) or target.id not in {'vars', 'deps', 'use_relative_paths'}:
            raise ValueError('unsupported shaderc DEPS assignment')
        if target.id in values:
            raise ValueError('duplicate shaderc DEPS assignment')
        values[target.id] = evaluate(statement.value)
    dependencies = values.get('deps')
    if not isinstance(dependencies, dict) or not dependencies:
        raise ValueError('shaderc DEPS has no pinned dependencies')
    pins = []
    for relative, address in sorted(dependencies.items()):
        if not isinstance(relative, str) or not isinstance(address, str):
            raise ValueError('invalid shaderc dependency')
        parts = Path(relative).parts
        if (not parts or parts[0] != 'third_party' or Path(relative).is_absolute()
                or any(part in {'.', '..', '.git'} for part in parts)):
            raise ValueError(f'unsafe shaderc dependency path: {relative}')
        url, separator, revision = address.rpartition('@')
        if not separator or not url or not re.fullmatch(r'[0-9a-fA-F]{40}', revision):
            raise ValueError(f'dependency must have a full commit pin: {relative}')
        pins.append((relative, url, revision.lower(), address))
    return raw, pins

def checked_path(root, relative):
    path = root / relative
    parent = path
    while parent != root:
        if parent.is_symlink():
            raise ValueError(f'symlink in shaderc dependency path: {path}')
        parent = parent.parent
    if not path.resolve().is_relative_to(root):
        raise ValueError(f'external shaderc dependency: {relative}')
    return path

def independent(path):
    if not (path / '.git').exists() or Path(output(path, 'rev-parse', '--show-toplevel')).resolve() != path.resolve():
        raise ValueError(f'not an independent dependency checkout: {path}')

def clean(path):
    if output(path, 'status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'):
        raise ValueError(f'dirty shaderc dependency: {path}')

def validate_dependency(root, pin):
    relative, url, revision, address = pin
    path = checked_path(root, relative)
    if not path.is_dir():
        raise ValueError(f'missing shaderc dependency: {relative}')
    independent(path)
    actual = output(path, 'rev-parse', '--verify', 'HEAD^{commit}')
    if actual.lower() != revision:
        raise ValueError(f'shaderc dependency pin mismatch: {relative}: {actual} != {revision}')
    clean(path)
    submodules = output(path, 'submodule', 'status', '--recursive')
    if any(line and line[0] in '-+U' for line in submodules.splitlines()):
        raise ValueError(f'uninitialized or mismatched dependency submodule: {relative}')
    return [relative, address, actual, submodules]

def identity(root):
    raw, pins = parse(root)
    identities = [validate_dependency(root, pin) for pin in pins]
    return hashlib.sha256(json.dumps([hashlib.sha256(raw).hexdigest(), identities],
                                    sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def sync(root, buildroot, seed):
    staging = buildroot / '_src'
    if (not root.is_dir() or root.is_symlink() or not staging.is_dir()
            or not root.is_relative_to(staging.resolve()) or root == staging.resolve()
            or staging.is_symlink() or not (root / '.git').is_dir() or (root / '.git').is_symlink()):
        raise ValueError('shaderc acquisition is restricted to an independent BUILDROOT/_src tree')
    independent(root)
    raw, pins = parse(root)
    # Validate the entire plan before creating any directory or running a clone.
    existing, missing = [], []
    for pin in pins:
        relative, url, revision, address = pin
        if OFFICIAL.get(relative) != url:
            raise ValueError(f'unreviewed shaderc dependency official URL: {relative}: {url}')
        path = checked_path(root, relative)
        if os.path.lexists(path):
            validate_dependency(root, pin)  # Existing worktrees are read-only.
            existing.append(pin)
        else:
            missing.append(pin)
    if seed is not None:
        independent(seed)
        clean(seed)
        seed_raw, seed_pins = parse(seed)
        if (seed_raw != raw or seed_pins != pins
                or output(seed, 'rev-parse', '--verify', 'HEAD^{commit}') != output(root, 'rev-parse', '--verify', 'HEAD^{commit}')):
            raise ValueError('shaderc source seed does not match the exact main commit and DEPS')
        identity(seed)  # All pins/dirty/submodule checks precede the first clone.
    for pin in missing:
        relative, url, revision, address = pin
        destination = checked_path(root, relative)
        attempt = Path(tempfile.mkdtemp(prefix='.shaderc-' + destination.name + '-', dir=staging))
        clone_source = str(seed / relative) if seed is not None else url
        print(f'shaderc acquire {relative}: ' + ('verified source seed' if seed is not None else url), file=sys.stderr)
        try:
            # Git itself creates origin naturally; no config/remote changes.
            # A clone copies only tracked source/Git objects, never ignored
            # objects/archives from a seed's prior compiler invocation.
            output(staging, 'clone', '--no-hardlinks', '--dissociate', '--no-recurse-submodules', '--', clone_source, str(attempt))
            if not (attempt / '.git').is_dir() or (attempt / '.git').is_symlink():
                raise ValueError('new dependency clone has external Git metadata')
            independent(attempt)
            clean(attempt)
            if git(attempt, 'cat-file', '-e', revision + '^{commit}', check=False)[1]:
                if seed is not None:
                    raise ValueError('verified shaderc seed lost its pinned object during cloning')
                output(attempt, 'fetch', '--no-tags', url, revision)
            if output(attempt, 'rev-parse', '--verify', revision + '^{commit}').lower() != revision:
                raise ValueError('fetched shaderc object is not the pinned commit')
            clean(attempt)
            # No --force: a hook or concurrent local edit must fail, not vanish.
            output(attempt, 'switch', '--detach', revision)
            independent(attempt)
            clean(attempt)
            if output(attempt, 'rev-parse', '--verify', 'HEAD^{commit}').lower() != revision:
                raise ValueError('new shaderc dependency did not select its exact pin')
            nested = output(attempt, 'submodule', 'status', '--recursive')
            if nested:
                raise ValueError('nested shaderc dependency submodules require reviewed explicit acquisition')
            if (attempt / '.git/objects/info/alternates').exists():
                raise ValueError('new shaderc clone still borrows external Git objects')
            destination.parent.mkdir(parents=True, exist_ok=True)
            checked_path(root, relative)
            if os.path.lexists(destination):
                raise ValueError(f'dependency destination was created concurrently: {destination}')
            # GNU mv -n does not replace even a racing empty directory. A
            # failed/raced attempt remains available for inspection.
            subprocess.run(['mv', '-T', '-n', '--', str(attempt), str(destination)], check=True)
            if attempt.exists():
                raise ValueError(f'dependency destination raced acquisition: {destination}')
            validate_dependency(root, pin)
        except Exception:
            print(f'shaderc acquisition retained attempt: {attempt}', file=sys.stderr)
            raise
    return identity(root)

try:
    mode = sys.argv[1]
    if mode == 'key':
        print(identity(Path(sys.argv[2]).resolve()))
    elif mode == 'sync':
        raw_root = Path(sys.argv[2]).absolute()
        if raw_root.is_symlink():
            raise ValueError('shaderc acquisition cannot target a symlink')
        root, buildroot = raw_root.resolve(), Path(sys.argv[3]).resolve()
        seed = Path(sys.argv[4]).resolve() if sys.argv[4] else None
        TIMEOUT = int(sys.argv[5])
        if TIMEOUT <= 0:
            raise ValueError('shaderc acquisition timeout must be positive')
        print(sync(root, buildroot, seed))
    else:
        raise ValueError('unknown shaderc DEPS operation')
except (OSError, ValueError, KeyError, TypeError, SyntaxError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
    print(f'shaderc DEPS {sys.argv[1]}: {error}', file=sys.stderr)
    sys.exit(1)
PYSHADERCDEPS
}

ffbuild_cache_shaderc_deps_key() {
  ffbuild_cache__shaderc_python key "${1:?shaderc source required}"
}

ffbuild_cache_shaderc_sync_deps() {
  local stage="${1:?shaderc staging directory required}" buildroot="${2:?build root required}"
  local seed="${3-${FFBUILD_SHADERC_SOURCE_SEED:-}}"
  [[ "$stage" == /* && "$buildroot" == /* ]] || { printf '%s\n' 'shaderc acquisition requires absolute paths' >&2; return 1; }
  if declare -F ffbuild_assert_staging_path >/dev/null; then
    ffbuild_assert_staging_path "$buildroot" "$stage" || return 1
  fi
  ffbuild_cache__shaderc_python sync "$stage" "$buildroot" "$seed" "${SOURCE_FETCH_TIMEOUT:-600}"
}
