#!/usr/bin/env bash
# Full Windows build recipe, sourced inside run_stage().
      local iconv_stage iconv_canonical iconv_tag iconv_version iconv_archive iconv_cache
      # Keep the ordinary independent Git stage for Full's source-success record.
      # Release archives must never replace that stage or the canonical checkout.
      iconv_stage="$(stage_src "libiconv")" || return 1
      iconv_canonical="$(ffbuild_source_dir libiconv)" || return 1
      ffbuild_verify_source_clean "$iconv_canonical" || return 1
      iconv_tag="$(GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false -C "$iconv_canonical" \
        describe --tags --exact-match --match 'libiconv-[0-9]*' HEAD)" || {
          echo 'libiconv canonical source must be at an exact clean release tag' >&2
          return 1
        }
      [[ "$iconv_tag" =~ ^libiconv-([0-9]+(\.[0-9]+)+)$ ]] || {
        echo "libiconv source is not pinned to an exact release tag: $iconv_tag" >&2
        return 1
      }
      iconv_version="${BASH_REMATCH[1]}"
      iconv_cache="$ROOT/toolchains/source-archives"
      iconv_archive="$iconv_cache/libiconv-$iconv_version.tar.gz"
      local iconv_publish='' iconv_download iconv_source iconv_sources="$BUILDROOT/_archive-src"
      if [[ ! -e "$iconv_archive" && ! -L "$iconv_archive" ]]; then
        [[ ! -L "$ROOT/toolchains" && ! -L "$iconv_cache" ]] || {
          echo "libiconv refuses a symlinked archive cache: $iconv_cache" >&2
          return 1
        }
        mkdir -p -- "$iconv_cache"
        iconv_download="$(mktemp -d "$iconv_cache/.libiconv-$iconv_version.download.XXXXXX")" || return 1
        iconv_publish="$iconv_archive"
        iconv_archive="$iconv_download/libiconv-$iconv_version.tar.gz"
        download_file_retry "$iconv_archive" \
          "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$iconv_version.tar.gz" || {
            echo "Unable to download libiconv $iconv_version; download directory retained: $iconv_download" >&2
            return 1
          }
      fi
      ffbuild_assert_generated_directory "$iconv_sources" || return 1
      # Validate before extracting, write only into a new empty directory, and
      # attest the complete extracted source only after extraction succeeds.
      # Existing archives and unknown/modified source directories are read-only.
      iconv_source="$(python3 -I - "$iconv_archive" "$iconv_version" "$iconv_sources" "$iconv_publish" <<'PYICONVSOURCE'
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import sys
import tarfile
import tempfile

MARKER = '.ffbuild-libiconv-source.json'
LIMIT = 1024 * 1024 * 1024

def digest_stream(stream):
    result = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(block)
    return result.hexdigest()

def digest_file(path):
    with open(path, 'rb') as stream:
        return digest_stream(stream)

def tree_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()

def actual_tree(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError('not an independent extracted source directory')
    result = {'.': {'kind': 'dir', 'mode': stat.S_IMODE(root.stat().st_mode)}}
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(base) / name
            relative = path.relative_to(root).as_posix()
            if relative == MARKER:
                continue
            if name == '.git':
                raise ValueError('Git metadata is not release archive source')
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError('extracted source contains an external symlink')
                result[relative] = {'kind': 'link', 'target': os.readlink(path)}
                if name in dirs:
                    dirs.remove(name)
            elif stat.S_ISDIR(info.st_mode):
                result[relative] = {'kind': 'dir', 'mode': stat.S_IMODE(info.st_mode)}
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                result[relative] = {'kind': 'file', 'mode': stat.S_IMODE(info.st_mode),
                                    'size': info.st_size, 'sha256': digest_file(path), 'mtime_ns': info.st_mtime_ns}
            else:
                raise ValueError('extracted source contains a special file or external hardlink')
    return result

def main():
    archive_path, version, sources, publish = sys.argv[1:]
    archive_path, sources = Path(archive_path), Path(sources)
    if archive_path.is_symlink() or not archive_path.is_file():
        raise ValueError('archive must be a regular, non-symlink file: ' + str(archive_path))
    top = 'libiconv-' + version
    def relative(name):
        parts = name.rstrip('/').split('/')
        if (not parts or parts[0] != top or any(part in {'', '.', '..', '.git'} for part in parts)
                or '\\' in name or '\x00' in name or ':' in name):
            raise ValueError('unsafe archive member: ' + repr(name))
        result = '/'.join(parts[1:])
        if result == MARKER:
            raise ValueError('archive contains reserved extraction metadata')
        return result
    with open(archive_path, 'rb') as raw:
        archive_sha = digest_stream(raw)
        raw.seek(0)
        # Read gzip to EOF too: tar's end marker alone does not verify the
        # compressed stream's trailer/checksum or reject trailing corruption.
        with gzip.GzipFile(fileobj=raw, mode='rb') as compressed:
            expanded_size = 0
            for block in iter(lambda: compressed.read(1024 * 1024), b''):
                expanded_size += len(block)
                if expanded_size > LIMIT + 64 * 1024 * 1024:
                    raise ValueError('archive exceeds safe extraction limits')
        raw.seek(0)
        with tarfile.open(fileobj=raw, mode='r:gz') as archive:
            members, total = {}, 0
            for member in archive:
                name = relative(member.name)
                if name in members or member.type not in {tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE,
                                                         tarfile.SYMTYPE, tarfile.LNKTYPE}:
                    raise ValueError('duplicate or special archive member: ' + member.name)
                total += member.size
                if len(members) >= 50000 or member.size < 0 or total > LIMIT:
                    raise ValueError('archive exceeds safe extraction limits')
                members[name] = member
            if '' not in members or not members[''].isdir():
                raise ValueError('archive is missing the expected release root')
            if 'configure' not in members or not members['configure'].isreg() or not members['configure'].mode & 0o100:
                raise ValueError('archive is missing its executable release configure script')
            for name, member in members.items():
                parts = name.split('/')
                for end in range(1, len(parts)):
                    ancestor = '/'.join(parts[:end])
                    if ancestor in members and not members[ancestor].isdir():
                        raise ValueError('archive writes through a link or non-directory: ' + name)
                if member.issym():
                    target = member.linkname
                    if not target or target.startswith('/') or '\\' in target or '\x00' in target or ':' in target:
                        raise ValueError('unsafe archive symlink: ' + name)
            def resolve_link(parts):
                current, pending, links = [], list(parts), 0
                while pending:
                    part = pending.pop(0)
                    if part in {'', '.'}:
                        continue
                    if part == '..':
                        if not current:
                            raise ValueError('archive symlink escapes release root')
                        current.pop()
                        continue
                    current.append(part)
                    entry = members.get('/'.join(current))
                    if entry is not None and entry.issym():
                        links += 1
                        if links > len(members):
                            raise ValueError('cyclic archive symlink')
                        current.pop()
                        pending = entry.linkname.split('/') + pending
                return '/'.join(current)
            def regular_target(name, seen=()):
                if name in seen or name not in members:
                    raise ValueError('missing or cyclic archive hardlink target')
                entry = members[name]
                if entry.isreg():
                    return entry
                if entry.islnk():
                    return regular_target(relative(entry.linkname), (*seen, name))
                raise ValueError('archive hardlink does not target a regular archive file')
            expected = {'.': {'kind': 'dir', 'mode': 0o755}}
            expanded = 0
            for name, member in members.items():
                if not name:
                    continue
                for end in range(1, len(name.split('/'))):
                    expected['/'.join(name.split('/')[:end])] = {'kind': 'dir', 'mode': 0o755}
                if member.isdir():
                    expected[name] = {'kind': 'dir', 'mode': 0o755}
                elif member.issym():
                    resolve_link(name.split('/'))
                    expected[name] = {'kind': 'link', 'target': member.linkname}
                else:
                    target = regular_target(name)
                    expanded += target.size
                    if expanded > LIMIT or not math.isfinite(float(member.mtime)):
                        raise ValueError('archive exceeds safe extraction limits')
                    mtime = int(float(member.mtime) * 1000000000)
                    if not 0 <= mtime < 2 ** 63:
                        raise ValueError('unsafe archive timestamp')
                    with archive.extractfile(target) as stream:
                        content_sha = digest_stream(stream)
                    expected[name] = {'kind': 'file', 'mode': (member.mode & 0o755) | 0o600,
                                      'size': target.size, 'sha256': content_sha, 'mtime_ns': mtime}
            if digest_file(archive_path) != archive_sha:
                raise ValueError('archive changed during validation')
            # Publish validated downloads without ever replacing an existing cache.
            if publish:
                destination = Path(publish)
                try:
                    os.link(archive_path, destination, follow_symlinks=False)
                except FileExistsError:
                    if destination.is_symlink() or not destination.is_file() or digest_file(destination) != archive_sha:
                        raise ValueError('another archive occupies the cache path; both archives were retained')
            if sources.is_symlink():
                raise ValueError('archive source container must not be a symlink')
            sources.mkdir(parents=True, exist_ok=True)
            candidate = sources / (top + '-' + archive_sha)
            credential = {'schema': 1, 'version': version, 'archive_sha256': archive_sha,
                          'source_digest': tree_digest(expected)}
            siblings = sorted(sources.glob(candidate.name + '.ffbuild-*'))
            for source in [candidate, *siblings]:
                marker = source / MARKER
                try:
                    if marker.is_symlink() or marker.stat().st_size > 8192:
                        continue
                    if (json.loads(marker.read_text()) == dict(credential, path=str(source))
                            and actual_tree(source) == expected):
                        print(source)
                        return
                except (OSError, ValueError, RuntimeError):
                    pass
            try:
                candidate.mkdir(mode=0o755)
                source = candidate
            except FileExistsError:
                source = Path(tempfile.mkdtemp(prefix=candidate.name + '.ffbuild-', dir=sources))
            source.chmod(0o755)
            # Directories and regular files first; links are created only after
            # all writes, so extraction can never follow an archive symlink.
            for name, entry in sorted(expected.items(), key=lambda item: (item[0].count('/'), item[0])):
                if name != '.' and entry['kind'] == 'dir':
                    directory = source / name
                    directory.mkdir(mode=0o755)
                    directory.chmod(0o755)  # mkdir's mode is otherwise masked by the caller's umask.
            for name, member in members.items():
                if name and (member.isreg() or member.islnk()):
                    target = source / name
                    with archive.extractfile(regular_target(name)) as stream, open(target, 'xb') as output:
                        shutil.copyfileobj(stream, output)
                    target.chmod(expected[name]['mode'])
                    mtime = expected[name]['mtime_ns']
                    os.utime(target, ns=(mtime, mtime))
            for name, member in members.items():
                if member.issym():
                    (source / name).symlink_to(member.linkname)
            if digest_file(archive_path) != archive_sha or actual_tree(source) != expected:
                raise ValueError('archive/source changed during extraction; incomplete tree retained without credential')
            fd, temporary = tempfile.mkstemp(prefix=MARKER + '.tmp-', dir=source)
            with os.fdopen(fd, 'w') as output:
                json.dump(dict(credential, path=str(source)), output, sort_keys=True)
                output.write('\n')
            os.replace(temporary, source / MARKER)
            print(source)

try:
    main()
except (OSError, EOFError, ValueError, RuntimeError, tarfile.TarError) as error:
    raise SystemExit('libiconv archive/source cache: ' + str(error))
PYICONVSOURCE
      )" || return 1

      local iconv_bld iconv_config_key iconv_config_stamp iconv_config_tmp iconv_configured=0
      local iconv_configure_args=(
        --host="$TARGET"
        --prefix="$PREFIX"
        --disable-shared
        --enable-static
        --disable-nls
      )
      iconv_bld="$(full_build_directory "$BUILDROOT/libiconv" "$iconv_source" make "${iconv_configure_args[@]}")" || return 1
      iconv_config_stamp="$iconv_bld/.ffbuild-libiconv-configured.sha256"
      if [[ -f "$iconv_config_stamp" && ! -L "$iconv_config_stamp" &&
            -x "$iconv_bld/config.status" && -s "$iconv_bld/Makefile" ]]; then
        iconv_config_key="$(ffbuild_cache_tree_key "$iconv_bld/config.status" "$iconv_bld/Makefile")" || return 1
        [[ "$(<"$iconv_config_stamp")" != "$iconv_config_key" ]] || iconv_configured=1
      fi
      if (( ! iconv_configured )); then
        (cd "$iconv_bld" && "$iconv_source/configure" "${iconv_configure_args[@]}")
        [[ -x "$iconv_bld/config.status" && -s "$iconv_bld/Makefile" ]] || {
          echo 'libiconv configure did not create a complete out-of-tree configuration' >&2
          return 1
        }
        iconv_config_key="$(ffbuild_cache_tree_key "$iconv_bld/config.status" "$iconv_bld/Makefile")" || return 1
        iconv_config_tmp="$(mktemp "$iconv_bld/.ffbuild-libiconv-configured.XXXXXX")" || return 1
        printf '%s\n' "$iconv_config_key" > "$iconv_config_tmp"
        mv -f -- "$iconv_config_tmp" "$iconv_config_stamp"
      fi
      make -C "$iconv_bld" -j"$JOBS"
      make -C "$iconv_bld" install
