#!/usr/bin/env bash
set -euo pipefail
stage="$1"
mode="${2:-lite}"
patchdir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/dolby-hdr"
patches=(
  0002-avfilter-add-hdr10plus-producer-filter.patch
  0004-avfilter-add-dovi-apply-curve-filter.patch
  0010-avfilter-setparams-add-max-cll-max-fall-options.patch
  0011-avfilter-setparams-add-master-display-mdvc-options.patch
  0012-avfilter-add-dovi-compose-dual-layer-fel.patch
  0013-avfilter-add-hlg2pq-picture-converter.patch
  0014-fel-pairing-safety.patch
)
case "$mode" in
  lite) ;;
  full) patches+=(iamf-object-position-v2.patch 0015-iamf-preserve-packet-side-data-values.patch 0016-iamf-init-audio-element-type-before-gotos.patch) ;;
  *) echo "Unknown patch mode: $mode" >&2; exit 2 ;;
esac
[[ -d "$stage/.git" || -f "$stage/.git" ]] || { echo "Not a Git worktree: $stage" >&2; exit 2; }
state="$stage/.ffmpeg-shared-patches-$mode"
fingerprint="$(git -C "$stage" rev-parse HEAD)"
for name in "${patches[@]}"; do
  patch="$patchdir/$name"
  [[ -f "$patch" ]] || { echo "Missing patch: $patch" >&2; exit 1; }
  fingerprint+="$(sha256sum "$patch" | cut -d ' ' -f1)"
done
if [[ -f "$state" ]] && [[ "$(cat "$state")" == "$fingerprint" ]]; then
  echo "Shared $mode patches already applied to $(git -C "$stage" rev-parse --short HEAD)"
  exit 0
fi
for name in "${patches[@]}"; do
  patch="$patchdir/$name"
  git -C "$stage" apply --check "$patch" || {
    echo "Patch does not match this FFmpeg source: $name" >&2
    exit 1
  }
  git -C "$stage" apply --whitespace=nowarn "$patch"
  echo "Applied: $name"
done
printf '%s' "$fingerprint" > "$state"
