#!/usr/bin/env bash
# Shared workspace paths and safety checks. Sourcing this file never changes files.

FFBUILD_CODE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="${ROOT:-$FFBUILD_CODE_ROOT}"
ROOT="$(cd "$ROOT" && pwd)"
SOURCE_ROOT="${SOURCE_ROOT:-$ROOT/sources}"
[[ "$SOURCE_ROOT" == /* ]] || SOURCE_ROOT="$ROOT/$SOURCE_ROOT"

ffbuild_source_dir() {
  local name="${1:?source name required}" candidate override_var override
  [[ "$name" =~ ^[[:alnum:]][[:alnum:]_.+-]*$ ]] || {
    echo "无效源码名称: $name" >&2
    return 1
  }
  override_var="FFBUILD_SOURCE_DIR_${name^^}"
  override_var="${override_var//[-.+]/_}"
  override="${!override_var:-}"
  if [[ -n "$override" ]]; then
    [[ "$override" == /* ]] || override="$ROOT/$override"
    printf '%s\n' "$override"
    return 0
  fi
  # Prefer the organized layout. The legacy fallback also supports external workspaces.
  for candidate in "$SOURCE_ROOT/$name" "$ROOT/$name"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # New clones always belong in SOURCE_ROOT, never in the project root.
  printf '%s\n' "$SOURCE_ROOT/$name"
}

ffbuild_verify_source_clean() {
  local repo_dir="${1:?source directory required}" status top
  [[ -e "$repo_dir/.git" ]] || {
    echo "无效的 Git 源码仓库: $repo_dir；不会自动删除或重克隆" >&2
    return 1
  }
  top="$(git -C "$repo_dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ "$(realpath -- "$top")" == "$(realpath -- "$repo_dir")" ]] || {
    echo "路径不是独立源码仓库: $repo_dir" >&2
    return 1
  }
  status="$(GIT_OPTIONAL_LOCKS=0 git -c core.fsmonitor=false -C "$repo_dir" status --porcelain --untracked-files=normal)" || return 1
  if [[ -n "$status" ]]; then
    echo "源码仓库有本地修改，停止更新以保护现场: $repo_dir" >&2
    printf '%s\n' "$status" >&2
    return 1
  fi
}

ffbuild__paths_overlap() {
  [[ "$1" == "$2" || "$1" == "$2/"* || "$2" == "$1/"* ]]
}

ffbuild_assert_generated_path() {
  local raw="${1:-}" path root code_root base protected candidate
  [[ -n "$raw" ]] || { echo '拒绝清理空路径' >&2; return 1; }
  path="$(realpath -m -- "$raw")" || return 1
  root="$(realpath -m -- "$ROOT")" || return 1
  code_root="$(realpath -m -- "$FFBUILD_CODE_ROOT")" || return 1
  case "$path" in
    /|/home|/root|/tmp|/var|/var/tmp|/usr|/usr/local|/opt|/etc|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys|/run|/mnt|/media|"${HOME:-/nonexistent}")
      echo "拒绝清理系统或用户根目录: $path" >&2
      return 1 ;;
  esac
  # ROOT and SOURCE_ROOT overrides must not unprotect the actual code checkout,
  # the default sources directory, or a legacy flat-layout source repository.
  for base in "$root" "$code_root"; do
    for protected in "$base" "$base/full" "$base/nvenc" "$base/qsv" "$base/nmr"; do
      if [[ "$path" == "$protected" || "$protected" == "$path/"* ]]; then
        echo "拒绝清理项目或兼容入口目录: $path" >&2
        return 1
      fi
    done
    for protected in "$base/sources" "$base/.git" "$base/.claude" "$base/.github" \
      "$base/scripts" "$base/tools" "$base/toolchains" "$base/shared-patches" \
      "$base/packaging" "$base/tests" "$base/docs" "$base/archive" "$base/build-manifests"; do
      protected="$(realpath -m -- "$protected")" || return 1
      if ffbuild__paths_overlap "$path" "$protected"; then
        echo "拒绝清理持久源码、工具或记录: $path" >&2
        return 1
      fi
    done
    for candidate in "$base"/*; do
      [[ -e "$candidate/.git" || -L "$candidate/.git" ]] || continue
      protected="$(realpath -m -- "$candidate")" || return 1
      if ffbuild__paths_overlap "$path" "$protected"; then
        echo "拒绝清理原始 Git 源码仓库: $path" >&2
        return 1
      fi
    done
  done
  protected="$(realpath -m -- "$SOURCE_ROOT")" || return 1
  if ffbuild__paths_overlap "$path" "$protected"; then
    echo "拒绝清理自定义源码目录: $path" >&2
    return 1
  fi
  local override_var override
  for override_var in ${!FFBUILD_SOURCE_DIR_@}; do
    override="${!override_var:-}"
    [[ -n "$override" ]] || continue
    [[ "$override" == /* ]] || override="$root/$override"
    protected="$(realpath -m -- "$override")" || return 1
    if ffbuild__paths_overlap "$path" "$protected"; then
      echo "拒绝清理单库源码覆盖路径: $path" >&2
      return 1
    fi
  done
  return 0
}

ffbuild_assert_generated_directory() {
  local path="${1:?generated directory required}"
  ffbuild_assert_generated_path "$path" || return 1
  if [[ -e "$path" && ! -d "$path" ]]; then
    echo "拒绝将文件当作构建目录清理: $path" >&2
    return 1
  fi
  if [[ -e "$path/.git" ]]; then
    echo "拒绝清理独立 Git 源码仓库: $path" >&2
    return 1
  fi
}

ffbuild_assert_staging_path() {
  local buildroot="${1:?build root required}" stage="${2:?staging path required}" src="${3:-}"
  local build_path staging_root stage_path src_path metadata
  ffbuild_assert_generated_directory "$buildroot" || return 1
  build_path="$(realpath -m -- "$buildroot")" || return 1
  staging_root="$(realpath -m -- "$buildroot/_src")" || return 1
  stage_path="$(realpath -m -- "$stage")" || return 1
  [[ "$staging_root" == "$build_path/"* && "$stage_path" == "$staging_root/"* ]] || {
    echo "构建副本必须位于当前 BUILDROOT/_src 内: $stage" >&2
    return 1
  }
  ffbuild_assert_generated_path "$staging_root" || return 1
  ffbuild_assert_generated_path "$stage_path" || return 1
  [[ ! -e "$buildroot/_src/.git" && ! -L "$buildroot/_src/.git" ]] || {
    echo "构建副本容器不能是源码仓库: $buildroot/_src" >&2
    return 1
  }
  if [[ -n "$src" ]]; then
    src_path="$(realpath -m -- "$src")" || return 1
    if ffbuild__paths_overlap "$stage_path" "$src_path"; then
      echo "构建副本与原始源码路径重叠: $stage" >&2
      return 1
    fi
  fi
  if [[ -e "$stage/.git" || -L "$stage/.git" ]]; then
    metadata="$(realpath -m -- "$stage/.git")" || return 1
    [[ -d "$stage/.git" && "$metadata" == "$stage_path/"* ]] || {
      echo "构建副本不能引用外部 Git 元数据: $stage/.git" >&2
      return 1
    }
  fi
  return 0
}

ffbuild_remove_generated_tree() {
  local path="${1:?generated directory required}"
  ffbuild_assert_generated_directory "$path" || return 1
  rm -rf -- "$path"
}
